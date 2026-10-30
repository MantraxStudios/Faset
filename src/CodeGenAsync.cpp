// Faset - generación de C para async / await (ver Async.cpp para el análisis semántico).
//
// Un método async  'async Task<int> F(int x)'  se emite así:
//
//     typedef struct fs_aN_fr { int32_t fs_st; <self>; <campos> } fs_aN_fr;   // el MARCO
//     T* F(int32_t p_x) {                 // la función original: crea el marco y arranca
//         fs_aN_fr* fs_fr = faset_gc_alloc(sizeof *fs_fr);  fs_fr->p_x = p_x;
//         return fs_aN_start(fs_fr);
//     }
//     #define p_x (fs_fr->p_x)            // cada variable del cuerpo es un campo del marco
//     ...
//     static T* fs_aN_start(fs_aN_fr* fs_fr) {   // <cont> = Action(fs_aN_step, marco); <task> = new Task<int>()
//         ...; fs_aN_step(fs_fr); return tarea;
//     }
//     static void fs_aN_step(void* p) {    // la función de paso: un trozo del cuerpo por llamada
//         faset_exc_frame fs_top;  FASET_TRY(fs_top) {
//             switch (fs_fr->fs_st) { case 1: goto fs_aw1; ... }   // reanudación
//             ...cuerpo...
//                 <aw> = <op>.GetAwaiter();
//                 if (!<aw>.IsCompleted) { fs_fr->fs_st = 1; <aw>.OnCompleted(<cont>); return; fs_aw1: ; }
//                 <r> = <aw>.GetResult();
//             ...
//             fs_done: <task>.SetResult(<res>);
//         } else <task>.SetException(fs_top.obj);    // excepción no atrapada: la tarea falla
//     }
//     #undef p_x ...
//
// Todas las variables locales, parámetros, temporales del azúcar y marcos de 'try' son campos del
// marco (las macros #define hacen que el código de siempre los use sin cambios); así nada de lo que
// vive entre dos 'await' está en la pila de C. Tras 'OnCompleted' la función de paso no toca el
// marco (la continuación puede estar ya corriendo en otro hilo).
//
// try / catch / finally alrededor de un 'await'
//   Los marcos de excepción (faset_exc_frame, con su jmp_buf) se enlazan en una pila por hilo y
//   setjmp guarda el contexto de la pila de C actual, que deja de existir al suspender. Por eso:
//    - al suspender, se desapilan todos los marcos de la función (faset_exc_top vuelve al valor que
//      tenía al entrar en la función de paso): ni catch ni finally se ejecutan;
//    - el propio marco (obj, tipo, jmp_buf) y fs_whyN (qué hacer al terminar el finally) son campos
//      del marco del método, así que sobreviven;
//    - al reanudar, la función de paso NO salta directamente al 'await': salta a la etiqueta de
//      reentrada del 'try' más externo que lo contiene, justo antes de FASET_TRY, que vuelve a
//      enlazar el marco y a llamar a setjmp en la pila nueva; dentro, un 'switch' sobre el estado
//      salta al siguiente 'try' interior o al punto del 'await'. Cada 'try' queda partido en tramos
//      (uno por reanudación) con su marco restablecido en cada uno;
//    - un 'await' dentro de un 'catch' o de un 'finally' no necesita reentrada de ese 'try' (su
//      marco ya estaba desapilado): 'throw;' usa el marco guardado y 'finally' sigue con fs_whyN.
//   Una excepción lanzada después de la reanudación la atrapa el mismo catch/finally de siempre;
//   si nadie la atrapa, el marco exterior de la función de paso la guarda en la tarea (Task.Exception)
//   y 'await' o .Result la vuelven a lanzar. En 'async void' no hay tarea: la excepción sigue su
//   camino hasta quien ejecutó la continuación (como en C#, termina el programa si nadie la atrapa).
#include "CodeGen.h"

namespace {
std::string lamName(LambdaExpr* l) { return "fs_lam" + std::to_string(l->id); }
bool needsEnv(LambdaExpr* l) { return l->usesThis || !l->captures.empty(); }
}  // namespace

// ------------------------------------------------------------------ declaraciones y campos

void CodeGen::asyncField(const std::string& ct, const std::string& name) {
    if (asyncFieldNames_.insert(name).second) asyncFields_.push_back({ct, name});
}

void CodeGen::emitLocalDecl(const std::string& ct, const std::string& name, const std::string& init, const std::string& qual) {
    if (!async_) {
        line(ct + qual + name + (init.empty() ? "" : " = " + init) + ";");
        // Una variable 'volatile' (modificada dentro de un 'try') puede cambiar a través de un puntero
        // no volatile (argumento 'ref'/'out'); si su dirección no escapa, clang -O2 borra esas
        // escrituras antes del longjmp al integrar la función llamada.
        if (qual.find("volatile") != std::string::npos) line("FASET_ESCAPE(&" + name + ");");
        return;
    }
    asyncField(ct, name);
    if (init.empty()) return;
    if (init == "{0}") line(name + " = (" + ct + "){0};");
    else line(name + " = " + init + ";");
}

std::string CodeGen::asyncDispatch(const std::vector<std::pair<int, std::string>>& d) {
    std::string s = "switch (fs_fr->fs_st) {";
    for (auto& [st, label] : d) s += " case " + std::to_string(st) + ": goto " + label + ";";
    return s + " default: break; }";
}

void CodeGen::emitTryOpen(TryStmt* t, char kind, const std::string& frame) {
    auto it = async_ ? asyncRegions_.find({t, kind}) : asyncRegions_.end();
    if (it == asyncRegions_.end()) {
        line("FASET_TRY(" + frame + ") {");
        return;
    }
    // Reentrada: tras una suspensión se vuelve aquí para enlazar otra vez el marco y llamar a
    // setjmp en la pila actual; después se sigue hacia el 'await' (o el 'try' interior) pendiente.
    line(it->second.label + ": ;");
    line("FASET_TRY(" + frame + ") {");
    line("    " + asyncDispatch(it->second.dispatch));
}

// ------------------------------------------------------------------ análisis: estados y zonas

void CodeGen::asyncAnalyze(Stmt* s, std::vector<std::pair<const TryStmt*, char>>& chain, int& states) {
    if (!s) return;
    if (s->lowered) {
        asyncAnalyze(s->lowered, chain, states);
        return;
    }
    switch (s->kind) {
        case SK::Block:
            for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) asyncAnalyze(c, chain, states);
            break;
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            asyncAnalyze(is->then, chain, states);
            asyncAnalyze(is->els, chain, states);
            break;
        }
        case SK::While: asyncAnalyze(static_cast<WhileStmt*>(s)->body, chain, states); break;
        case SK::DoWhile: asyncAnalyze(static_cast<DoWhileStmt*>(s)->body, chain, states); break;
        case SK::For: {
            auto* fs = static_cast<ForStmt*>(s);
            asyncAnalyze(fs->initDecl, chain, states);
            asyncAnalyze(fs->body, chain, states);
            break;
        }
        case SK::Switch:
            for (auto& sec : static_cast<SwitchStmt*>(s)->sections)
                for (Stmt* b : sec.body) asyncAnalyze(b, chain, states);
            break;
        case SK::Using: {
            auto* u = static_cast<UsingStmt*>(s);
            asyncAnalyze(u->decl, chain, states);
            asyncAnalyze(u->body, chain, states);
            break;
        }
        case SK::Try: {
            // Igual que emitTry: try/catch/finally = finally { catch { cuerpo } }; las cláusulas
            // catch corren dentro del marco del finally y el bloque finally fuera de los dos.
            auto* t = static_cast<TryStmt*>(s);
            bool fin = t->finallyBody != nullptr, cat = !t->catches.empty();
            if (fin) chain.push_back({t, 'F'});
            if (cat) chain.push_back({t, 'C'});
            asyncAnalyze(t->body, chain, states);
            if (cat) chain.pop_back();
            for (auto& c : t->catches) asyncAnalyze(c.body, chain, states);
            if (fin) chain.pop_back();
            asyncAnalyze(t->finallyBody, chain, states);
            break;
        }
        case SK::Await:
        case SK::Yield: {  // 'yield' de un iterador: otro punto de suspensión (CodeGenIterators.cpp)
            if (s->kind == SK::Yield && static_cast<YieldStmt*>(s)->isBreak) break;
            int k = ++states;
            asyncStates_[s] = k;
            std::string target = (s->kind == SK::Yield ? "fs_yd" : "fs_aw") + std::to_string(k);
            for (size_t i = chain.size(); i-- > 0;) {
                AsyncRegion& r = asyncRegions_[chain[i]];
                if (r.label.empty()) r.label = "fs_ar" + std::to_string(asyncRegions_.size());
                r.dispatch.push_back({k, target});
                target = r.label;
            }
            asyncTop_.push_back({k, target});
            break;
        }
        default: break;
    }
}

// ------------------------------------------------------------------ sentencias

void CodeGen::emitAwait(AwaitStmt* s) {
    AwaitExpr* aw = s->aw;
    int k = asyncStates_.count(s) ? asyncStates_[s] : 0;
    line(aw->opVar->cname + " = " + expr(aw->operand) + ";");
    line(aw->awVar->cname + " = " + expr(aw->getAwaiter) + ";");
    line("if (!(" + expr(aw->isCompleted) + ")) {");
    indent_++;
    line("fs_fr->fs_st = " + std::to_string(k) + ";");
    line(expr(aw->onCompleted) + ";");  // desde aquí la continuación puede correr en otro hilo:
    line("faset_exc_top = fs_entry_top;");  // no se vuelve a tocar el marco
    line("return;");
    line("fs_aw" + std::to_string(k) + ": ;");
    line("fs_fr->fs_st = 0;");
    indent_--;
    line("}");
    if (s->result) line(s->result->cname + " = " + expr(aw->getResult) + ";");
    else line(expr(aw->getResult) + ";");
}

void CodeGen::emitAsyncReturn(ReturnStmt* rs) {
    line("{");
    indent_++;
    if (rs->value) {
        if (rs->value->type && rs->value->type->isVoid()) line(expr(rs->value) + ";");  // async () => Accion()
        else if (async_->res) line(async_->res->cname + " = " + expr(rs->value) + ";");
        else line("(void)(" + expr(rs->value) + ");");
    }
    if (!excRegions_.empty() && excRegions_.back().method == curMethod_) {
        emitExcJumpChain(2, (int)excRegions_.size());  // libera los 'using' entre los finally (Exceptions.cpp)
    } else {
        if (std::string clean = usingCleanup(-1); !clean.empty()) line(clean);
        line("goto fs_done;");
    }
    indent_--;
    line("}");
}

// ------------------------------------------------------------------ funciones

void CodeGen::emitAsyncMethod(MethodDecl* m) {
    curMethod_ = m;
    curClass_ = m->owner;
    std::string selfType, selfInit;
    if (!m->isStatic()) {
        selfType = m->owner->cname + "*";
        selfInit = m->objSelf ? "(" + selfType + ")faset_self" : "self";
    }
    std::vector<VarInfo*> params;
    for (Param& p : m->params) params.push_back(p.var);
    emitAsyncMachine(m->async, signature(m), selfType, selfInit, params, m->body);
    curMethod_ = nullptr;
}

void CodeGen::emitAsyncLambda(LambdaExpr* l) {
    std::vector<VarInfo*> params;
    for (auto& p : l->params) params.push_back(p.var);
    std::string selfType = l->usesThis ? l->ownerClass->cname + "*" : "";
    emitAsyncMachine(l->fn->async, "static " + lambdaSig(l), selfType, "", params, l->blockBody);
}

void CodeGen::emitAsyncMachine(AsyncInfo* a, const std::string& entrySig, const std::string& selfType,
                               const std::string& selfInit, const std::vector<VarInfo*>& params, BlockStmt* body) {
    if (a->iterKind) {  // iterador con 'yield' (CodeGenIterators.cpp)
        emitIterMachine(a, entrySig, selfType, selfInit, params, body);
        return;
    }
    LambdaExpr* lam = a->lambda;
    std::string n = "fs_a" + std::to_string(++asyncCounter_);
    std::string frT = n + "_fr";
    async_ = a;
    asyncFields_.clear();
    asyncFieldNames_.clear();
    asyncRegions_.clear();
    asyncTop_.clear();
    asyncStates_.clear();
    // Campos: todas las variables del cuerpo (y sus cajas si alguna lambda las captura).
    for (VarInfo* v : a->vars) {
        std::string ct = ctype(v->type);
        asyncField(v->isRef ? ct + "*" : ct, v->cname);
        if (v->captured) asyncField(ct + "*", v->cname + "_bx");
    }
    std::vector<std::pair<const TryStmt*, char>> chain;
    int states = 0;
    asyncAnalyze(body, chain, states);

    // 1) El cuerpo de la función de paso (descubre los campos de los temporales y de los 'try').
    std::ostringstream saved;
    saved.swap(out_);
    indent_ = 2;
    usings_.push_back({});
    if (lam) {
        std::vector<VarInfo*> ps = params;
        boxParams(ps);  // parámetros capturados por lambdas: en el prólogo (solo la primera vez)
    } else {
        boxParams(params);
    }
    setLoc(body->loc);
    for (Stmt* s : body->stmts) emitStmt(s);
    if (std::string clean = usingCleanup(0); !clean.empty()) line(clean);
    usings_.pop_back();
    std::string bodyCode = out_.str();
    out_.str("");
    out_.clear();
    out_.swap(saved);

    // 2) El marco.
    bool hasTask = a->task != nullptr;
    std::string retC = hasTask ? ctype(a->ret) : "void";
    resetLoc();
    out_ << "typedef struct " << frT << " {\n    int32_t fs_st;\n";
    if (!selfType.empty()) out_ << "    " << selfType << " fs_self;\n";
    if (lam) out_ << "    void* fs_envp;\n";
    for (auto& [ct, name] : asyncFields_) out_ << "    " << ct << " " << name << ";\n";
    out_ << "} " << frT << ";\n";
    out_ << "static void " << n << "_step(void* fs_p);\n";
    out_ << "static " << retC << " " << n << "_start(" << frT << "* fs_fr);\n";

    // 3) La función original: crea el marco, copia 'this' y los parámetros, y arranca.
    out_ << entrySig << " {\n";
    if (lam) out_ << "    (void)fs_envp;\n";
    out_ << "    " << frT << "* fs_fr = (" << frT << "*)faset_gc_alloc((int64_t)sizeof(" << frT << "));\n";
    if (!selfType.empty()) out_ << "    fs_fr->fs_self = " << (lam ? "((" + lamName(lam) + "_env*)fs_envp)->self" : selfInit) << ";\n";
    if (lam) out_ << "    fs_fr->fs_envp = fs_envp;\n";
    for (VarInfo* v : params)
        if (v) out_ << "    fs_fr->" << v->cname << " = " << v->cname << ";\n";
    out_ << "    " << (hasTask ? "return " : "") << n << "_start(fs_fr);\n}\n";

    // 4) Las variables del cuerpo se refieren a los campos del marco.
    for (auto& f : asyncFields_) out_ << "#define " << f.second << " (fs_fr->" << f.second << ")\n";

    // 5) Arranque: continuación, tarea y primer paso (hasta el primer 'await' pendiente).
    out_ << "static " << retC << " " << n << "_start(" << frT << "* fs_fr) {\n";
    indent_ = 1;
    line(a->cont->cname + " = faset_dlg_new((faset_fnptr)" + n + "_step, fs_fr);");
    if (hasTask) {
        line(expr(a->newTask) + ";");
        line(retC + " fs_task = " + a->task->cname + ";");
    }
    line(n + "_step(fs_fr);");
    if (hasTask) line("return fs_task;");
    out_ << "}\n";

    // 6) La función de paso.
    out_ << "static void " << n << "_step(void* fs_p) {\n";
    out_ << "    " << frT << "* fs_fr = (" << frT << "*)fs_p;\n";
    if (!selfType.empty()) out_ << "    " << selfType << " self = fs_fr->fs_self;\n    (void)self;\n";
    if (lam && needsEnv(lam)) out_ << "    " << lamName(lam) << "_env* fs_env = (" << lamName(lam) << "_env*)fs_fr->fs_envp;\n    (void)fs_env;\n";
    out_ << "    faset_exc_frame* fs_entry_top = faset_exc_top;\n";
    if (hasTask) {
        out_ << "    faset_exc_frame fs_top;\n";
        out_ << "    FASET_TRY(fs_top) {\n";
    } else {
        out_ << "    {\n";
    }
    out_ << "        " << asyncDispatch(asyncTop_) << "\n";
    out_ << bodyCode;
    indent_ = 2;
    resetLoc();
    line("goto fs_done;");
    line("fs_done: ;");
    line("faset_exc_top = fs_entry_top;");
    if (hasTask) line(expr(a->setResult) + ";");
    out_ << "    }";
    if (hasTask) {
        out_ << " else {\n";
        indent_ = 2;
        if (a->exc && a->setException) {
            line(a->exc->cname + " = (" + ctype(a->exc->type) + ")fs_top.obj;");
            line(expr(a->setException) + ";");
        }
        out_ << "    }";
    }
    out_ << "\n}\n";
    for (auto& f : asyncFields_) out_ << "#undef " << f.second << "\n";
    out_ << "\n";
    indent_ = 0;
    async_ = nullptr;
}
