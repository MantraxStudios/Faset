// Faset - generación de C para lambdas, cierres y delegados.
//
// Representación
//   Un delegado es un puntero a 'faset_delegate' (objeto del recolector, o estático si no
//   captura nada):
//       struct faset_delegate { fn; env; count; list; }
//   'fn' es una función C 'R f(void* env, A1, A2...)' y 'env' su entorno. Los delegados
//   multicast (eventos, d += f) tienen count > 0 y la lista de invocación en 'list'; son
//   inmutables (combinar crea uno nuevo), como en C#.
//
// Coste
//   - Lambda sin capturas, o método estático convertido a delegado: objeto estático, ninguna
//     reserva de memoria al crearla ni al llamarla.
//   - Lambda con capturas: una reserva para el delegado y otra para su entorno al evaluar la
//     expresión lambda (no al llamarla); cada variable capturada vive en una caja (una reserva
//     al ejecutar su declaración).
//   - Llamar a un delegado: comprobación de nulo + llamada indirecta (fs_dinvN, 'static inline').
//   - obj.Metodo como delegado: una reserva (el entorno es el propio objeto).
#include "CodeGen.h"

const char* const kDelegateRuntime = R"FASET(
/* ---- delegados (Func<...>, Action<...>, lambdas y eventos) ---- */
typedef void (*faset_fnptr)(void);
typedef struct faset_delegate {
    faset_fnptr fn;                  /* R fn(void* env, A...) */
    void* env;                       /* entorno: cierre, objeto (obj.Metodo) o nulo */
    int32_t count;                   /* > 0: multicast, lista de invocación en 'list' */
    struct faset_delegate** list;
} faset_delegate;

static inline faset_delegate* faset_dlg_new(faset_fnptr fn, void* env) {
    faset_delegate* d = (faset_delegate*)faset_gc_alloc((int64_t)sizeof(faset_delegate));
    d->fn = fn;
    d->env = env;
    return d;
}
static inline void* faset_dlg_box(const void* src, int64_t size) {
    void* p = faset_gc_alloc(size);
    __builtin_memcpy(p, src, (size_t)size);  /* sin <string.h>: no choca con un 'extern strlen' del programa */
    return p;
}
static inline int32_t faset_dlg_len(faset_delegate* d) { return !d ? 0 : d->count > 0 ? d->count : 1; }
static inline faset_delegate* faset_dlg_at(faset_delegate* d, int32_t i) { return d->count > 0 ? d->list[i] : d; }
static inline _Bool faset_dlg_same(faset_delegate* a, faset_delegate* b) { return a->fn == b->fn && a->env == b->env; }
static inline faset_delegate* faset_dlg_from(faset_delegate** items, int32_t n) {
    if (n == 0) return 0;
    if (n == 1) return items[0];
    faset_delegate* d = (faset_delegate*)faset_gc_alloc((int64_t)sizeof(faset_delegate));
    d->list = (faset_delegate**)faset_gc_alloc((int64_t)sizeof(faset_delegate*) * n);
    for (int32_t i = 0; i < n; i++) d->list[i] = items[i];
    d->count = n;
    d->fn = items[n - 1]->fn;
    d->env = items[n - 1]->env;
    return d;
}
/* a + b: lista de invocación de 'a' seguida de la de 'b'. */
static inline faset_delegate* faset_dlg_combine(faset_delegate* a, faset_delegate* b) {
    if (!a) return b;
    if (!b) return a;
    int32_t na = faset_dlg_len(a), nb = faset_dlg_len(b);
    faset_delegate** items = (faset_delegate**)faset_gc_alloc((int64_t)sizeof(faset_delegate*) * (na + nb));
    for (int32_t i = 0; i < na; i++) items[i] = faset_dlg_at(a, i);
    for (int32_t i = 0; i < nb; i++) items[na + i] = faset_dlg_at(b, i);
    return faset_dlg_from(items, na + nb);
}
/* a - b: quita la última aparición de la lista de 'b' (como en C#). */
static inline faset_delegate* faset_dlg_remove(faset_delegate* a, faset_delegate* b) {
    if (!a || !b) return a;
    int32_t na = faset_dlg_len(a), nb = faset_dlg_len(b);
    for (int32_t s = na - nb; s >= 0; s--) {
        int32_t k = 0;
        while (k < nb && faset_dlg_same(faset_dlg_at(a, s + k), faset_dlg_at(b, k))) k++;
        if (k < nb) continue;
        faset_delegate** items = (faset_delegate**)faset_gc_alloc((int64_t)sizeof(faset_delegate*) * (na - nb + 1));
        int32_t n = 0;
        for (int32_t i = 0; i < na; i++)
            if (i < s || i >= s + nb) items[n++] = faset_dlg_at(a, i);
        return faset_dlg_from(items, n);
    }
    return a;
}
/* Dos delegados son iguales si tienen la misma lista de (función, entorno). */
static inline _Bool faset_dlg_eq(faset_delegate* a, faset_delegate* b) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    int32_t na = faset_dlg_len(a);
    if (na != faset_dlg_len(b)) return 0;
    for (int32_t i = 0; i < na; i++)
        if (!faset_dlg_same(faset_dlg_at(a, i), faset_dlg_at(b, i))) return 0;
    return 1;
}
)FASET";

namespace {
bool needsEnv(LambdaExpr* l) { return l->usesThis || !l->captures.empty(); }
std::string lamName(LambdaExpr* l) { return "fs_lam" + std::to_string(l->id); }
}  // namespace

// ------------------------------------------------------------------ variables capturadas

std::string CodeGen::boxRef(VarInfo* v) {
    int cur = curLambda_ ? curLambda_->depth : 0;
    if (v->fnDepth == cur) return v->cname + "_bx";
    return "fs_env->" + v->cname;  // declarada fuera de esta lambda: viene en su entorno
}

std::string CodeGen::localRef(VarInfo* v) {
    if (v->captured) return "(*" + boxRef(v) + ")";
    return v->isRef ? "(*" + v->cname + ")" : v->cname;
}

void CodeGen::declareLocalVar(VarInfo* v, const std::string& init) {
    std::string t = ctype(v->type);
    if (!v->captured) {
        emitLocalDecl(t, v->cname, init.empty() ? zeroInit(v->type) : init);
        return;
    }
    emitLocalDecl(t + "*", v->cname + "_bx", "(" + t + "*)faset_gc_alloc((int64_t)sizeof(" + t + "))");
    if (!init.empty()) line("*" + v->cname + "_bx = " + init + ";");
}

void CodeGen::boxParams(const std::vector<VarInfo*>& params) {
    for (VarInfo* v : params)
        if (v && v->captured) declareLocalVar(v, v->cname);
}

// ------------------------------------------------------------------ declaraciones

void CodeGen::emitDelegateSupport() {
    // Un invocador por tipo delegado: comprueba nulo, recorre la lista multicast y llama.
    // Con fs_file nulo (eventos), invocar un delegado nulo no hace nada.
    for (Type* d : tc_.delegates()) {
        std::string R = ctype(d->ret);
        std::string fnT = R + " (*)(void*";
        std::string decl, args;
        for (size_t i = 0; i < d->params.size(); i++) {
            fnT += ", " + ctype(d->params[i]);
            decl += ", " + ctype(d->params[i]) + " a" + std::to_string(i);
            args += ", a" + std::to_string(i);
        }
        fnT += ")";
        bool isVoid = d->ret->isVoid();
        out_ << "static inline " << R << " fs_dinv" << d->id << "(faset_delegate* d, const char* fs_file, int32_t fs_line"
             << decl << ") {\n";
        out_ << "    if (FASET_UNLIKELY(!d)) {\n";
        out_ << "        if (!fs_file) return" << (isVoid ? "" : " (" + R + "){0}") << ";\n";
        out_ << "        faset_panic_msg(\"llamada a un delegado nulo\", fs_file, fs_line);\n    }\n";
        out_ << "    if (FASET_UNLIKELY(d->count > 0)) {\n";
        out_ << "        for (int32_t i = 0; i + 1 < d->count; i++) {\n";
        out_ << "            faset_delegate* x = d->list[i];\n";
        out_ << "            ((" << fnT << ")x->fn)(x->env" << args << ");\n        }\n";
        out_ << "        d = d->list[d->count - 1];\n    }\n";
        out_ << "    " << (isVoid ? "" : "return ") << "((" << fnT << ")d->fn)(d->env" << args << ");\n}\n";
    }
    // Entornos de las lambdas con capturas: punteros a las cajas de las variables (y 'this').
    for (LambdaExpr* l : sema_.lambdas) {
        if (!needsEnv(l)) continue;
        out_ << "typedef struct " << lamName(l) << "_env {\n";
        if (l->usesThis) out_ << "    " << l->ownerClass->cname << "* self;\n";
        for (VarInfo* v : l->captures) out_ << "    " << ctype(v->type) << "* " << v->cname << ";\n";
        out_ << "} " << lamName(l) << "_env;\n";
    }
    out_ << "\n";
}

std::string CodeGen::lambdaSig(LambdaExpr* l) {
    std::string s = ctype(l->ret) + " " + lamName(l) + "(void* fs_envp";
    for (size_t i = 0; i < l->params.size(); i++) s += ", " + ctype(l->paramTypes[i]) + " " + l->params[i].var->cname;
    return s + ")";
}

void CodeGen::emitLambdaDecls() {
    // Adaptadores grupo de métodos -> delegado.
    for (size_t i = 0; i < sema_.thunks.size(); i++) {
        const Sema::Thunk& t = sema_.thunks[i];
        Type* d = t.dlg;
        MethodDecl* m = t.target;
        std::string name = "fs_thk" + std::to_string(i);
        out_ << "static " << ctype(d->ret) << " " << name << "(void* fs_envp";
        for (size_t k = 0; k < d->params.size(); k++) out_ << ", " << ctype(d->params[k]) << " a" << k;
        out_ << ") {\n";
        std::vector<std::string> parts;
        if (t.instance) parts.push_back("(" + m->owner->cname + "*)fs_envp");
        else out_ << "    (void)fs_envp;\n";
        for (size_t k = 0; k < d->params.size(); k++) parts.push_back("a" + std::to_string(k));
        if (m->trackCaller) parts.push_back(loc(m->loc));  // [TrackCaller]: la ubicación del método
        std::string call = m->cname + "(";
        for (size_t k = 0; k < parts.size(); k++) call += (k ? ", " : "") + parts[k];
        call += ")";
        if (d->ret->isVoid()) out_ << "    (void)" << call << ";\n}\n";
        else out_ << "    return " << call << ";\n}\n";
        if (!t.instance) out_ << "static faset_delegate " << name << "_d = { (faset_fnptr)" << name << ", 0, 0, 0 };\n";
    }
    // Lambdas: prototipo y delegado estático (sin capturas) o constructor del cierre.
    for (LambdaExpr* l : sema_.lambdas) {
        std::string n = lamName(l);
        out_ << "static " << lambdaSig(l) << ";\n";
        if (!needsEnv(l)) {
            out_ << "static faset_delegate " << n << "_d = { (faset_fnptr)" << n << ", 0, 0, 0 };\n";
            continue;
        }
        std::vector<std::string> ps;
        if (l->usesThis) ps.push_back(l->ownerClass->cname + "* self");
        for (VarInfo* v : l->captures) ps.push_back(ctype(v->type) + "* " + v->cname);
        out_ << "static faset_delegate* " << n << "_new(";
        for (size_t i = 0; i < ps.size(); i++) out_ << (i ? ", " : "") << ps[i];
        out_ << ") {\n";
        out_ << "    " << n << "_env* e = (" << n << "_env*)faset_gc_alloc((int64_t)sizeof(" << n << "_env));\n";
        if (l->usesThis) out_ << "    e->self = self;\n";
        for (VarInfo* v : l->captures) out_ << "    e->" << v->cname << " = " << v->cname << ";\n";
        out_ << "    return faset_dlg_new((faset_fnptr)" << n << ", e);\n}\n";
    }
    out_ << "\n";
}

void CodeGen::emitLambdaBodies() {
    for (LambdaExpr* l : sema_.lambdas) {
        curLambda_ = l;
        curMethod_ = l->fn;
        curClass_ = l->ownerClass;
        if (l->fn && l->fn->async) {  // lambda async: máquina de estados (CodeGenAsync.cpp)
            emitAsyncLambda(l);
            continue;
        }
        std::string n = lamName(l);
        out_ << "static " << lambdaSig(l) << " {\n";
        indent_ = 1;
        pushHoist();            // temporales de expresión del azúcar (switch, ?., tuplas...)
        usings_.push_back({});  // 'using var' del cuerpo
        if (needsEnv(l)) line(n + "_env* fs_env = (" + n + "_env*)fs_envp;");
        else line("(void)fs_envp;");
        if (l->usesThis) line(l->ownerClass->cname + "* self = fs_env->self;");
        std::vector<VarInfo*> params;
        for (auto& p : l->params) params.push_back(p.var);
        boxParams(params);
        if (l->exprBody) {
            if (l->ret->isVoid()) line(expr(l->exprBody) + ";");
            else line("return " + expr(l->exprBody) + ";");
        } else {
            for (Stmt* s : l->blockBody->stmts) emitStmt(s);
            if (std::string clean = usingCleanup(0); !clean.empty()) line(clean);
        }
        usings_.pop_back();
        popHoist();
        indent_ = 0;
        out_ << "}\n\n";
    }
    curLambda_ = nullptr;
    curMethod_ = nullptr;
}

// ------------------------------------------------------------------ expresiones

std::string CodeGen::lambdaExpr(LambdaExpr* l) {
    std::string n = lamName(l);
    if (!needsEnv(l)) return "(&" + n + "_d)";  // sin capturas: sin reservas de memoria
    std::string s = n + "_new(";
    bool first = true;
    if (l->usesThis) {
        s += "self";
        first = false;
    }
    for (VarInfo* v : l->captures) {
        s += (first ? "" : ", ") + boxRef(v);
        first = false;
    }
    return s + ")";
}

std::string CodeGen::delegateConv(DelegateConvExpr* dc) {
    const Sema::Thunk& t = sema_.thunks[dc->thunk];
    std::string name = "fs_thk" + std::to_string(dc->thunk);
    if (!t.instance) return "(&" + name + "_d)";
    std::string self = dc->implicitThis ? "self" : receiverPtr(dc->receiver, dc->receiverArrow);
    ClassDecl* owner = dc->target->owner;
    if (owner->kind == ClassKind::Struct)  // como en C#: el delegado guarda una copia del struct
        return "faset_dlg_new((faset_fnptr)" + name + ", faset_dlg_box(" + self + ", (int64_t)sizeof(" + owner->cname +
               ")))";
    return "faset_dlg_new((faset_fnptr)" + name + ", (void*)" + self + ")";
}

namespace {
bool isEventRef(Expr* e) {
    if (e->kind == EK::Name) {
        auto* n = static_cast<NameExpr*>(e);
        return n->field && n->field->isEvent &&
               (n->ref == NameExpr::Ref::Field || n->ref == NameExpr::Ref::StaticField);
    }
    if (e->kind == EK::Member) {
        auto* m = static_cast<MemberExpr*>(e);
        if (m->ref == MemberExpr::Ref::DelegateInvoke) return isEventRef(m->obj);
        return m->field && m->field->isEvent &&
               (m->ref == MemberExpr::Ref::Field || m->ref == MemberExpr::Ref::StaticField);
    }
    return false;
}
}  // namespace

std::string CodeGen::delegateCall(CallExpr* c) {
    Type* d = c->callee->type;
    // Un evento sin manejadores no hace nada; un delegado nulo es un 'panic'.
    std::string s = "fs_dinv" + std::to_string(d->id) + "(" + expr(c->callee) + ", " +
                    (isEventRef(c->callee) ? std::string("0, 0") : callerLoc(c->loc));
    for (Expr* a : c->args) s += ", " + expr(a);
    return s + ")";
}
