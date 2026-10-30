// Faset - generación de C para los iteradores ('yield', ver Iterators.cpp). Usa la máquina de
// estados de async/await (CodeGenAsync.cpp): el marco en el recolector, las macros #define de las
// variables, el despacho con 'goto' y la reentrada de los 'try'; cada 'yield return' es un punto de
// suspensión más.
//
// Un iterador  'IEnumerable<int> F(int n)'  se emite así:
//
//     typedef struct fs_aN_fr { int32_t fs_st, fs_cmd; <self>; <copias de los argumentos>; <campos> } fs_aN_fr;
//     Generador* F(int32_t p_n) {          // no ejecuta nada del cuerpo: crea el marco y el generador
//         fs_aN_fr* fs_fr = faset_gc_alloc(...);  fs_fr->p_n = p_n;  fs_fr->fs_o_p_n = p_n;
//         return fs_aN_start(fs_fr);
//     }
//     static Generador* fs_aN_clone(void*)   // GetEnumerator() otra vez: marco nuevo con los argumentos originales
//     #define p_n (fs_fr->p_n) ...
//     static Generador* fs_aN_start(fs_aN_fr* fs_fr) {  // <paso> = Func<int, bool>(fs_aN_step, marco), <clon>...
//         <it> = new Generador<int>(<paso>, <clon>);  return <it>;
//     }
//     static _Bool fs_aN_step(void* p, int32_t fs_cmd) {   // MoveNext (cmd 0) / Dispose (cmd 1)
//         if (fs_fr->fs_st < 0) return 0;                  // ya terminó
//         FASET_TRY(fs_top) {
//             switch (fs_fr->fs_st) { case 1: goto fs_yd1; ... }
//             ...cuerpo...
//                 <it>.__actual = valor;  fs_fr->fs_st = 1;  return 1;     // yield return
//                 fs_yd1: if (fs_fr->fs_cmd) <yield break>;                 // Dispose: termina aquí
//             ...
//             fs_done: fs_fr->fs_st = -1; return 0;
//         } else { fs_fr->fs_st = -1; faset_exc_rethrow(&fs_top); }      // la excepción sale de MoveNext
//     }
//
// Dispose() reanuda el iterador en el 'yield' donde está suspendido como si allí hubiera un 'yield
// break': los 'finally' pendientes se ejecutan (la cadena de saltos de Exceptions.cpp) y termina.
//
// Un iterador async (IAsyncEnumerable<T>) usa además la tarea, la continuación y los 'await' de la
// máquina async: fs_aN_next(marco, cmd) crea la Task<bool> de cada MoveNextAsync / DisposeAsync y
// llama a la función de paso; 'yield return' completa esa tarea con true y vuelve (sin tocar el
// marco después: la continuación de quien espera puede seguir en otro hilo); al terminar se
// completa con false y una excepción no atrapada la deja fallida.
#include "CodeGen.h"

namespace {
std::string lamName(LambdaExpr* l) { return "fs_lam" + std::to_string(l->id); }
bool needsEnv(LambdaExpr* l) { return l->usesThis || !l->captures.empty(); }
}  // namespace

void CodeGen::emitYieldBreak() {
    if (std::string clean = usingCleanup(-1); !clean.empty()) line(clean);
    // Los 'finally' que lo rodean se ejecutan antes de terminar (como un 'return').
    if (!excRegions_.empty() && excRegions_.back().method == curMethod_) emitExcJumpChain(2, (int)excRegions_.size());
    else line("goto fs_done;");
}

void CodeGen::emitYield(YieldStmt* y) {
    AsyncInfo* a = async_;
    if (!a || !a->iterKind) return;
    line("{");
    indent_++;
    if (y->isBreak) {
        emitYieldBreak();
        indent_--;
        line("}");
        return;
    }
    int k = asyncStates_.count(y) ? asyncStates_[y] : 0;
    if (y->store) line(expr(y->store) + ";");
    line("fs_fr->fs_st = " + std::to_string(k) + ";");
    line("faset_exc_top = fs_entry_top;");
    if (a->isAsyncIter()) {
        // MoveNextAsync() termina con true; desde aquí no se toca el marco.
        line(a->res->cname + " = 1;");
        line(expr(a->setResult) + ";");
        line("return;");
    } else {
        line("return 1;");
    }
    line("fs_yd" + std::to_string(k) + ": ;");
    line("fs_fr->fs_st = 0;");
    line("if (fs_fr->fs_cmd) {");  // Dispose: termina en este punto, con los 'finally' pendientes
    indent_++;
    emitYieldBreak();
    indent_--;
    line("}");
    indent_--;
    line("}");
}

void CodeGen::emitIterMachine(AsyncInfo* a, const std::string& entrySig, const std::string& selfType,
                              const std::string& selfInit, const std::vector<VarInfo*>& params, BlockStmt* body) {
    LambdaExpr* lam = a->lambda;
    bool isAsync = a->isAsyncIter();
    std::string n = "fs_a" + std::to_string(++asyncCounter_);
    std::string frT = n + "_fr";
    async_ = a;
    asyncFields_.clear();
    asyncFieldNames_.clear();
    asyncRegions_.clear();
    asyncTop_.clear();
    asyncStates_.clear();
    for (VarInfo* v : a->vars) {
        std::string ct = ctype(v->type);
        asyncField(v->isRef ? ct + "*" : ct, v->cname);
        if (v->captured) asyncField(ct + "*", v->cname + "_bx");
    }
    std::vector<std::pair<const TryStmt*, char>> chain;
    int states = 0;
    asyncAnalyze(body, chain, states);

    // 1) El cuerpo de la función de paso.
    std::ostringstream saved;
    saved.swap(out_);
    indent_ = 2;
    usings_.push_back({});
    {
        std::vector<VarInfo*> ps = params;
        boxParams(ps);  // parámetros capturados por lambdas: en el prólogo (solo la primera vez)
    }
    setLoc(body->loc);
    for (Stmt* s : body->stmts) emitStmt(s);
    if (std::string clean = usingCleanup(0); !clean.empty()) line(clean);
    usings_.pop_back();
    std::string bodyCode = out_.str();
    out_.str("");
    out_.clear();
    out_.swap(saved);

    std::string genC = ctype(a->gen);
    std::string retC = ctype(a->ret);
    std::string taskC = isAsync ? ctype(a->task->type) : "";
    resetLoc();

    // 2) El marco: estado, orden pendiente (Dispose), 'this', entorno y copia de los argumentos.
    out_ << "typedef struct " << frT << " {\n    int32_t fs_st;\n    int32_t fs_cmd;\n";
    if (!selfType.empty()) out_ << "    " << selfType << " fs_self;\n";
    if (lam) out_ << "    void* fs_envp;\n";
    for (VarInfo* v : params)
        if (v) out_ << "    " << ctype(v->type) << " fs_o_" << v->cname << ";\n";
    for (auto& [ct, name] : asyncFields_) out_ << "    " << ct << " " << name << ";\n";
    out_ << "} " << frT << ";\n";
    if (isAsync) {
        out_ << "static void " << n << "_step(void* fs_p);\n";
        out_ << "static " << taskC << " " << n << "_next(void* fs_p, int32_t fs_cmd);\n";
    } else {
        out_ << "static _Bool " << n << "_step(void* fs_p, int32_t fs_cmd);\n";
    }
    out_ << "static " << genC << " " << n << "_start(" << frT << "* fs_fr);\n";

    // 3) La función original: crea el marco con los argumentos y el generador (sin ejecutar el cuerpo).
    out_ << entrySig << " {\n";
    if (lam) out_ << "    (void)fs_envp;\n";
    out_ << "    " << frT << "* fs_fr = (" << frT << "*)faset_gc_alloc((int64_t)sizeof(" << frT << "));\n";
    if (!selfType.empty()) out_ << "    fs_fr->fs_self = " << (lam ? "((" + lamName(lam) + "_env*)fs_envp)->self" : selfInit) << ";\n";
    if (lam) out_ << "    fs_fr->fs_envp = fs_envp;\n";
    for (VarInfo* v : params)
        if (v) out_ << "    fs_fr->" << v->cname << " = fs_fr->fs_o_" << v->cname << " = " << v->cname << ";\n";
    out_ << "    return (" << retC << ")" << n << "_start(fs_fr);\n}\n";

    // 4) Otro recorrido (GetEnumerator de nuevo): marco nuevo con los argumentos originales.
    out_ << "static " << genC << " " << n << "_clone(void* fs_p) {\n";
    out_ << "    " << frT << "* fs_o = (" << frT << "*)fs_p;\n";
    out_ << "    " << frT << "* fs_fr = (" << frT << "*)faset_gc_alloc((int64_t)sizeof(" << frT << "));\n";
    if (!selfType.empty()) out_ << "    fs_fr->fs_self = fs_o->fs_self;\n";
    if (lam) out_ << "    fs_fr->fs_envp = fs_o->fs_envp;\n";
    for (VarInfo* v : params)
        if (v) out_ << "    fs_fr->" << v->cname << " = fs_fr->fs_o_" << v->cname << " = fs_o->fs_o_" << v->cname << ";\n";
    out_ << "    return " << n << "_start(fs_fr);\n}\n";

    // 5) Las variables del cuerpo se refieren a los campos del marco.
    for (auto& f : asyncFields_) out_ << "#define " << f.second << " (fs_fr->" << f.second << ")\n";

    // 6) Arranque: delegados de paso y de clonación, y el generador.
    out_ << "static " << genC << " " << n << "_start(" << frT << "* fs_fr) {\n";
    indent_ = 1;
    line(a->stepDlg->cname + " = faset_dlg_new((faset_fnptr)" + n + (isAsync ? "_next" : "_step") + ", fs_fr);");
    line(a->cloneDlg->cname + " = faset_dlg_new((faset_fnptr)" + n + "_clone, fs_fr);");
    if (isAsync) line(a->cont->cname + " = faset_dlg_new((faset_fnptr)" + n + "_step, fs_fr);");
    line(expr(a->newIter) + ";");
    line("return " + a->iterObj->cname + ";");
    out_ << "}\n";

    // 7) MoveNextAsync / DisposeAsync de un iterador async: la tarea de esta llamada y un paso.
    if (isAsync) {
        out_ << "static " << taskC << " " << n << "_next(void* fs_p, int32_t fs_cmd) {\n";
        out_ << "    " << frT << "* fs_fr = (" << frT << "*)fs_p;\n";
        indent_ = 1;
        line(expr(a->newTask) + ";");
        line(taskC + " fs_task = " + a->task->cname + ";");
        line("if (fs_fr->fs_st < 0 || (fs_cmd && fs_fr->fs_st == 0)) {");  // terminado, o Dispose antes de empezar
        line("    fs_fr->fs_st = -1;");
        line("    " + a->res->cname + " = 0;");
        line("    " + expr(a->setResult) + ";");
        line("    return fs_task;");
        line("}");
        line("fs_fr->fs_cmd = fs_cmd;");
        line(n + "_step(fs_fr);");
        line("return fs_task;");
        out_ << "}\n";
    }

    // 8) La función de paso.
    if (isAsync) out_ << "static void " << n << "_step(void* fs_p) {\n";
    else out_ << "static _Bool " << n << "_step(void* fs_p, int32_t fs_cmd) {\n";
    out_ << "    " << frT << "* fs_fr = (" << frT << "*)fs_p;\n";
    if (!selfType.empty()) out_ << "    " << selfType << " self = fs_fr->fs_self;\n    (void)self;\n";
    if (lam && needsEnv(lam)) out_ << "    " << lamName(lam) << "_env* fs_env = (" << lamName(lam) << "_env*)fs_fr->fs_envp;\n    (void)fs_env;\n";
    if (!isAsync) {
        out_ << "    if (fs_fr->fs_st < 0) return 0;\n";
        out_ << "    if (fs_cmd && fs_fr->fs_st == 0) { fs_fr->fs_st = -1; return 0; }\n";
        out_ << "    fs_fr->fs_cmd = fs_cmd;\n";
    }
    out_ << "    faset_exc_frame* fs_entry_top = faset_exc_top;\n";
    out_ << "    faset_exc_frame fs_top;\n";
    out_ << "    FASET_TRY(fs_top) {\n";
    out_ << "        " << asyncDispatch(asyncTop_) << "\n";
    out_ << bodyCode;
    indent_ = 2;
    resetLoc();
    line("goto fs_done;");
    line("fs_done: ;");
    line("faset_exc_top = fs_entry_top;");
    line("fs_fr->fs_st = -1;");
    if (isAsync) {
        line(a->res->cname + " = 0;");
        line(expr(a->setResult) + ";");
    } else {
        line("return 0;");
    }
    out_ << "    } else {\n";
    indent_ = 2;
    line("fs_fr->fs_st = -1;");
    if (isAsync) {
        if (a->exc && a->setException) {
            line(a->exc->cname + " = (" + ctype(a->exc->type) + ")fs_top.obj;");
            line(expr(a->setException) + ";");
        }
    } else {
        line("faset_exc_rethrow(&fs_top);");  // la excepción sale de MoveNext hacia quien recorre
    }
    out_ << "    }\n";
    if (!isAsync) out_ << "    return 0;\n";
    out_ << "}\n";
    for (auto& f : asyncFields_) out_ << "#undef " << f.second << "\n";
    out_ << "\n";
    indent_ = 0;
    async_ = nullptr;
}
