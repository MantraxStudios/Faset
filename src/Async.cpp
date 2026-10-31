// Faset - async / await (análisis semántico). La generación de C está en CodeGenAsync.cpp y la
// biblioteca (Task, Task<T>, planificadores, temporizadores, cancelación) en lib/std/task.fst.
//
// Diseño (como en C#, sin cambiar de pila):
//
//  * Un método o lambda 'async' se compila como una MÁQUINA DE ESTADOS. Sus variables locales,
//    parámetros, temporales y marcos de 'try' viven en un MARCO: un objeto del recolector que
//    sobrevive a las suspensiones. La función C original solo crea el marco, la tarea y la
//    continuación, y llama a la función de paso; la función de paso ejecuta el cuerpo desde el
//    estado guardado hasta el siguiente 'await' pendiente o hasta el final.
//
//  * 'await e' sigue el patrón de C#: a = e.GetAwaiter(); si !a.IsCompleted, se guarda el número
//    de estado, se registra la continuación con a.OnCompleted(<cont>) y la función de paso vuelve;
//    al reanudarse continúa justo después y toma a.GetResult(). Valen Task, Task<T> y cualquier
//    tipo con esos miembros. <cont> es un Action creado una vez por marco que vuelve a llamar a la
//    función de paso (los planificadores deciden en qué hilo: ver task.fst).
//
//  * Para que la suspensión solo ocurra entre sentencias, cada 'await' se saca de su expresión a
//    una sentencia propia (AwaitStmt) cuyo resultado queda en una variable oculta. Lo que se evalúa
//    antes que el 'await' (receptor, argumentos y operandos a su izquierda) se guarda antes en
//    temporales, así el orden de evaluación es el de C#:
//        F(a(), await t, b())   ->   <t1> = a();  [await t -> <r>];  F(<t1>, <r>, b());
//    &&, || y ?: con un 'await' en la parte condicional se convierten en 'if':
//        x = c && await t       ->   <b> = c; if (<b>) { [await t -> <r>]; <b> = <r>; } x = <b>;
//    'while (await ...)' pasa a 'while (true) { ...; if (!cond) break; cuerpo }'. Las posiciones que
//    no se pueden reescribir (dentro de ?., ??=, la condición de 'for'/'do-while', un filtro 'when',
//    una referencia 'ref') son un error de compilación claro: nunca se bloquea en silencio.
//
//  * try/catch/finally alrededor de un 'await': ver CodeGenAsync.cpp (los marcos de setjmp se
//    vuelven a establecer en cada reanudación).
#include "Sema.h"

namespace {

NameExpr* refTo(VarInfo* v, SourceLoc loc) {  // sin comprobar: se resuelve por nombre
    auto* n = new NameExpr(loc);
    n->name = v->name;
    return n;
}

NameExpr* checkedRef(VarInfo* v, SourceLoc loc) {  // ya comprobada
    auto* n = new NameExpr(loc);
    n->name = v->name;
    n->ref = NameExpr::Ref::Local;
    n->var = v;
    n->type = v->type;
    return n;
}

MemberExpr* mkMember(Expr* obj, const std::string& name, SourceLoc loc) {
    auto* m = new MemberExpr(loc);
    m->obj = obj;
    m->name = name;
    m->nameLoc = loc;
    return m;
}

CallExpr* mkCall(Expr* callee, std::vector<Expr*> args, SourceLoc loc) {
    auto* c = new CallExpr(loc);
    c->callee = callee;
    c->args = std::move(args);
    return c;
}

// <v> = valor; (comprobada)
Stmt* assignStmt(VarInfo* v, Expr* value, SourceLoc loc) {
    auto* a = new AssignExpr(loc);
    a->op = "=";
    a->lhs = checkedRef(v, loc);
    a->rhs = value;
    a->type = v->type;
    auto* s = new ExprStmt(loc);
    s->expr = a;
    return s;
}

Expr* notOf(Expr* e, Type* boolT) {
    auto* u = new UnaryExpr(e->loc);
    u->op = "!";
    u->operand = e;
    u->type = boolT;
    return u;
}

BlockStmt* blockOf(std::vector<Stmt*> stmts, SourceLoc loc, bool noScope) {
    auto* b = new BlockStmt(loc);
    b->stmts = std::move(stmts);
    b->noScope = noScope;
    return b;
}

// Una subexpresión: dónde está, si es un lvalue (no se puede copiar a un temporal) y si se pasa
// por referencia (tampoco).
struct Slot {
    Expr** p;
    bool lvalue;
};

// Hijos de una expresión comprobada en orden de evaluación (sin 'lowered', que se trata aparte).
std::vector<Slot> slotsOf(Expr* e) {
    std::vector<Slot> s;
    auto add = [&](Expr*& x, bool lv = false) {
        if (x) s.push_back({&x, lv});
    };
    switch (e->kind) {
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->obj && m->obj->vk == ValKind::Value) add(m->obj, m->obj->type && m->obj->type->isStruct());
            break;
        }
        case EK::Call: {
            auto* c = static_cast<CallExpr*>(e);
            if (!c->target) {  // delegado o puntero a función
                add(c->callee);
            } else if (!c->target->isStatic() && c->receiver && !c->implicitThis) {
                add(c->receiver, c->receiver->type && c->receiver->type->isStruct());
            }
            for (size_t i = 0; i < c->args.size(); i++)
                add(c->args[i], c->target && i < c->target->params.size() && c->target->params[i].isRef());
            break;
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            add(ix->obj, ix->obj && ix->obj->type && ix->obj->type->isStruct());
            add(ix->index);
            break;
        }
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            add(u->operand, u->op == "++" || u->op == "--" || u->op == "&");
            break;
        }
        case EK::Postfix: add(static_cast<PostfixExpr*>(e)->operand, true); break;
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            add(b->lhs);
            add(b->rhs);
            break;
        }
        case EK::Assign: {
            auto* a = static_cast<AssignExpr*>(e);
            add(a->lhs, true);
            add(a->rhs);
            break;
        }
        case EK::Cond: {
            auto* c = static_cast<CondExpr*>(e);
            add(c->cond);
            add(c->a);
            add(c->b);
            break;
        }
        case EK::Cast: add(static_cast<CastExpr*>(e)->operand); break;
        case EK::Is: add(static_cast<IsExpr*>(e)->operand); break;
        case EK::As: add(static_cast<AsExpr*>(e)->operand); break;
        case EK::New: {
            auto* n = static_cast<NewExpr*>(e);
            for (size_t i = 0; i < n->args.size(); i++)
                add(n->args[i], n->ctor && i < n->ctor->params.size() && n->ctor->params[i].isRef());
            break;
        }
        case EK::NewArray: add(static_cast<NewArrayExpr*>(e)->count); break;
        case EK::Interp:
            for (auto& part : static_cast<InterpExpr*>(e)->parts) add(part.expr);
            break;
        case EK::Tuple:
            for (Expr*& x : static_cast<TupleExpr*>(e)->elems) add(x);
            break;
        case EK::ParamsList:
            for (Expr*& x : static_cast<ParamsListExpr*>(e)->items) add(x);
            break;
        case EK::Let: {
            auto* l = static_cast<LetExpr*>(e);
            for (auto& b : l->binds) add(b.second);
            for (Expr*& x : l->seq) add(x);
            break;
        }
        case EK::CondAccess: {
            auto* ca = static_cast<CondAccessExpr*>(e);
            add(ca->obj);
            add(ca->access);
            break;
        }
        case EK::CoalesceAssign: {
            auto* ca = static_cast<CoalesceAssignExpr*>(e);
            add(ca->lhs, true);
            add(ca->rhs);
            break;
        }
        case EK::With: {
            auto* w = static_cast<WithExpr*>(e);
            add(w->operand);
            for (auto& in : w->inits) add(in.value);
            break;
        }
        case EK::MatchFail: add(static_cast<MatchFailExpr*>(e)->value); break;
        case EK::DelegateConv: add(static_cast<DelegateConvExpr*>(e)->receiver); break;
        case EK::Await: add(static_cast<AwaitExpr*>(e)->operand); break;
        case EK::Propagate: add(static_cast<PropagateExpr*>(e)->operand); break;  // expr? (Unions.cpp)
        default: break;
    }
    return s;
}

bool containsAwait(Expr* e) {
    if (!e) return false;
    if (e->lowered) return containsAwait(e->lowered);
    if (e->kind == EK::Await) return true;
    if (e->kind == EK::Propagate && !static_cast<PropagateExpr*>(e)->spilled) return true;  // '?' (Unions.cpp)
    for (Slot& s : slotsOf(e))
        if (containsAwait(*s.p)) return true;
    return false;
}

// ¿Hace falta guardar este operando en un temporal antes de un 'await' posterior? Las constantes,
// las variables locales, 'this' y las lambdas no cambian por esperar.
bool needsSpill(Expr* c) {
    if (!c || c->vk != ValKind::Value || !c->type) return false;
    Type* t = c->type;
    if (t->isVoid() || t->isPending() || t->isError() || t->is(TK::Null)) return false;
    switch (c->kind) {
        case EK::IntLit: case EK::FloatLit: case EK::BoolLit: case EK::CharLit: case EK::StringLit: case EK::Null:
        case EK::Default: case EK::This: case EK::SizeOf: case EK::TypeOf: case EK::NameOf: case EK::Lambda:
            return false;
        case EK::Name: {
            auto r = static_cast<NameExpr*>(c)->ref;
            return !(r == NameExpr::Ref::Local || r == NameExpr::Ref::Base);
        }
        case EK::Cast: return needsSpill(static_cast<CastExpr*>(c)->operand);
        case EK::DelegateConv: return needsSpill(static_cast<DelegateConvExpr*>(c)->receiver);
        default: return true;
    }
}

}  // namespace

// ================================================================== tipos de la biblioteca

ClassDecl* Sema::taskDecl(bool generic) {
    NamespaceSym* ns = findNs({"std", "task"});
    if (!ns) return nullptr;
    auto it = ns->types.find("Task");
    if (it == ns->types.end()) return nullptr;
    ClassDecl* c = it->second;
    if (c->isTemplate() != generic) c = c->arityTwin;
    return c;
}

Type* Sema::taskOf(Type* result, SourceLoc loc) {
    if (!result || result->isVoid()) {
        ClassDecl* c = taskDecl(false);
        return c ? c->type : nullptr;
    }
    ClassDecl* g = taskDecl(true);
    if (!g) return nullptr;
    ClassDecl* inst = instantiate(g, {result}, loc);
    return inst ? inst->type : nullptr;
}

Type* Sema::asyncResultOf(Type* ret) {
    if (!ret || !ret->isClass() || !ret->decl) return nullptr;
    ClassDecl* d = ret->decl;
    ClassDecl* plain = taskDecl(false);
    if (plain && d == plain) return tc_.get(TK::Void);
    ClassDecl* g = taskDecl(true);
    if (g && d->templateOf == g && d->typeArgs.size() == 1) return d->typeArgs[0];
    return nullptr;
}

std::string Sema::awaitHover(Type* t) {
    Type* r = asyncResultOf(t);
    if (!r) return "";
    return "  (await devuelve " + (r->isVoid() ? std::string("nada") : "'" + r->str() + "'") + ")";
}

// Main async: 'static async Task Main()' o 'static async Task<int> Main()'.
bool Sema::asyncCheckEntry(MethodDecl* m) {
    Type* r = asyncResultOf(m->ret);
    if (!r || !(r->isVoid() || r->is(TK::Int))) return false;
    ClassDecl* plain = taskDecl(false);
    for (MethodDecl* k : plain->methods)
        if (k->name == "RunMain" && k->isStatic() && k->params.size() == 1) entryWait = k;
    if (!entryWait) return false;
    useMethod(entryWait);
    if (r->is(TK::Int))
        for (ClassDecl* k = m->ret->decl; k && !entryResult; k = k->base == k ? nullptr : k->base)
            for (FieldDecl* f : k->fields)
                if (f->name == "value" && !f->isStatic()) entryResult = f;
    return true;
}

// ================================================================== método o lambda async

void Sema::asyncNoteLocal(VarInfo* v) {
    AsyncInfo* a = ctx_.async;
    if (!a || v->fnDepth != a->depth) return;
    // Todas las variables del cuerpo son campos del marco: el nombre en C debe ser único en todo
    // el método (dos bloques hermanos pueden declarar 'x' con tipos distintos).
    if (v->cname.rfind("fs_h", 0) != 0) v->cname += "_" + std::to_string(++hiddenCounter_);
    a->vars.push_back(v);
}

AsyncInfo* Sema::asyncBegin(MethodDecl* fn, Type* ret, LambdaExpr* lambda, SourceLoc loc) {
    auto* a = new AsyncInfo();
    a->fn = fn;
    a->lambda = lambda;
    a->ret = ret;
    a->depth = (int)lambdaStack_.size();
    fn->async = a;
    ctx_.async = a;
    if (trialDepth_ == 0) asyncFns.push_back(a);
    if (!lambda) {
        for (Param& p : fn->params) {
            if (p.isRef()) diag.error(p.loc, "an async method cannot have 'ref' or 'out' parameters");
            if (p.var) a->vars.push_back(p.var);
        }
        if (fn->kind != MethodKind::Normal)
            diag.error(fn->loc, "only methods (not constructors, properties, or operators) can be 'async'");
        if (fn->owner && fn->owner->kind == ClassKind::Struct && !fn->isStatic())
            diag.error(fn->loc, "an instance async method cannot be in a struct (the struct would be copied); "
                                "use a class or a static method");
        if (fn->retIsRef()) diag.error(fn->loc, "an async method cannot return a reference");
    }
    if (!taskDecl(false)) {
        diag.error(loc, "'async' needs the std.task library (add 'using std.task;')");
        a->result = tc_.error();
        return a;
    }
    if (!ret) {
        a->result = nullptr;  // lambda: se infiere de sus 'return'
    } else if (ret->isError()) {
        a->result = ret;
    } else if (ret->isVoid()) {
        a->isVoid = true;
        a->result = ret;
    } else if (Type* r = asyncResultOf(ret)) {
        a->result = r;
    } else {
        diag.error(loc, std::string(lambda ? "an async lambda" : "an async method") +
                            " must return void, Task, or Task<T> (not '" + ret->str() + "')");
        a->result = tc_.error();
    }
    // Variables ocultas del marco y las llamadas a la tarea (comprobadas aquí, una vez).
    Type* actionT = tc_.delegateType({}, tc_.get(TK::Void));
    a->cont = hiddenLocal(actionT, loc, false);
    if (!a->result || a->result->isError() || a->isVoid) return a;
    a->task = hiddenLocal(ret, loc, false);
    ClassDecl* td = ret->decl;
    auto* nw = new NewExpr(loc);
    nw->type = ret;
    nw->ctor = paramlessCtor(td);
    if (nw->ctor) useMethod(nw->ctor);
    auto* as = new AssignExpr(loc);
    as->op = "=";
    as->lhs = checkedRef(a->task, loc);
    as->rhs = nw;
    as->type = ret;
    a->newTask = as;
    std::vector<Expr*> args;
    if (!a->result->isVoid()) {
        a->res = hiddenLocal(a->result, loc, false);
        args.push_back(refTo(a->res, loc));
    }
    a->setResult = mkCall(mkMember(refTo(a->task, loc), "SetResult", loc), args, loc);
    checkValue(a->setResult);
    if (exceptionClass) {
        a->exc = hiddenLocal(exceptionClass->type, loc, false);
        a->setException = mkCall(mkMember(refTo(a->task, loc), "SetException", loc), {refTo(a->exc, loc)}, loc);
        checkValue(a->setException);
    }
    return a;
}

void Sema::asyncEnd(AsyncInfo* a, BlockStmt* body) {
    (void)a;
    asyncValidate(body);
}

// Tipo de retorno inferido de una lambda async: Task<T> si algún 'return' devuelve un T, si no Task.
Type* Sema::asyncLambdaReturnType(LambdaExpr* t) {
    Type* r = nullptr;
    bool anyValue = false;
    for (ReturnStmt* rs : t->returns) {
        if (!rs->value) continue;
        Type* vt = rs->value->type;
        if (vt && vt->isVoid()) continue;  // async () => Accion()
        anyValue = true;
        if (!vt || vt->isError() || vt->isPending() || vt->is(TK::Null)) continue;
        if (!r) r = vt;
        else if (r != vt && canImplicit(nullptr, r, vt)) r = vt;
    }
    if (!anyValue) return taskOf(nullptr, t->loc);
    if (!r) return nullptr;
    return taskOf(r, t->loc);
}

// ================================================================== await

Type* Sema::checkAwait(AwaitExpr* e) {
    awaitCount_++;
    if (iterAwaitInvalid(e)) return tc_.error();  // 'await' en un iterador que no es async (Iterators.cpp)
    AsyncInfo* a = ctx_.async;
    if (!a) {
        checkValue(e->operand);
        diag.error(e->loc, lambdaStack_.empty() || !ctx_.method || ctx_.method->name != "<lambda>"
                               ? "'await' can only be used inside an 'async' method (mark it: async Task Metodo())"
                               : "'await' can only be used inside an 'async' lambda (async () => ...)");
        return tc_.error();
    }
    if (ctx_.filterDepth > 0) {
        checkValue(e->operand);
        diag.error(e->loc, "'await' cannot be used in a 'when' filter");
        return tc_.error();
    }
    Type* t = checkValue(e->operand);
    if (t->isError()) return t;
    bool has = t->isAggregate() && !findMethods(t->decl, "GetAwaiter").empty();
    if (!has) {
        diag.error(e->operand->loc, "cannot await a value of type '" + t->str() +
                                        "': it needs a GetAwaiter() method (like Task and Task<T>)");
        return tc_.error();
    }
    SourceLoc loc = e->loc;
    a->awaits++;
    e->opVar = hiddenLocal(t, loc, false);
    Expr* ga = mkCall(mkMember(refTo(e->opVar, loc), "GetAwaiter", loc), {}, loc);
    Type* at = checkValue(ga);
    if (at->isError()) return at;
    if (at->isVoid() || !at->isAggregate()) {
        diag.error(e->operand->loc, "GetAwaiter() of '" + t->str() + "' must return an 'awaiter' object (not '" +
                                        at->str() + "')");
        return tc_.error();
    }
    e->getAwaiter = ga;
    e->awVar = hiddenLocal(at, loc, false);
    Expr* ic = mkMember(refTo(e->awVar, loc), "IsCompleted", loc);
    Type* it = checkValue(ic);
    if (it->isError()) return it;
    if (!it->is(TK::Bool)) {
        diag.error(e->loc, "IsCompleted of 'awaiter' '" + at->str() + "' must be bool");
        return tc_.error();
    }
    Expr* oc = mkCall(mkMember(refTo(e->awVar, loc), "OnCompleted", loc), {refTo(a->cont, loc)}, loc);
    if (checkValue(oc)->isError()) return tc_.error();
    Expr* gr = mkCall(mkMember(refTo(e->awVar, loc), "GetResult", loc), {}, loc);
    Type* rt = checkValue(gr);
    if (rt->isError()) return rt;
    e->isCompleted = ic;
    e->onCompleted = oc;
    e->getResult = gr;
    if (ideMode) addRef(loc, 5, "await: espera a '" + t->str() + "' y da " + (rt->isVoid() ? "nada (void)" : "'" + rt->str() + "'"), nullptr);
    return rt;
}

// ================================================================== reescritura de las expresiones

Stmt* Sema::asyncAwaitStmt(AwaitExpr* aw, bool wantResult) {
    auto* st = new AwaitStmt(aw->loc);
    st->aw = aw;
    aw->spilled = true;
    if (wantResult && aw->type && !aw->type->isVoid()) st->result = hiddenLocal(aw->type, aw->loc, false);
    return st;
}

VarInfo* Sema::asyncTemp(Expr*& e, std::vector<Stmt*>& pre) {
    VarInfo* t = hiddenLocal(e->type, e->loc, false);
    pre.push_back(bindDecl(t, e));
    e = checkedRef(t, e->loc);
    return t;
}


// Saca los 'await' de 'e' (comprobada) a sentencias en 'pre'; 'e' queda sin ningún 'await'.
void Sema::asyncSpill(Expr*& e, std::vector<Stmt*>& pre) {
    if (!containsAwait(e)) return;
    if (e->lowered) {
        asyncSpill(e->lowered, pre);
        return;
    }
    SourceLoc loc = e->loc;
    Type* boolT = tc_.get(TK::Bool);
    // Deja estable un lvalue (sus partes se evalúan ahora, en orden) sin copiarlo.
    std::function<void(Expr*)> stabilize = [&](Expr* lv) {
        if (!lv) return;
        for (Slot& s : slotsOf(lv)) {
            if (s.lvalue) {
                stabilize(*s.p);
                continue;
            }
            asyncSpill(*s.p, pre);
            if (needsSpill(*s.p)) asyncTemp(*s.p, pre);
        }
    };
    switch (e->kind) {
        case EK::Await: {
            auto* aw = static_cast<AwaitExpr*>(e);
            asyncSpill(aw->operand, pre);  // await (await x)
            auto* st = static_cast<AwaitStmt*>(asyncAwaitStmt(aw, true));
            pre.push_back(st);
            if (!st->result) {
                diag.error(loc, "this task does not return a value: 'await' cannot be used as a value here");
                return;
            }
            e = checkedRef(st->result, loc);
            return;
        }
        case EK::Propagate: {  // expr?: <t> = expr; if (<t> es Err/None) return ...; y queda <t>.valor
            auto* pe = static_cast<PropagateExpr*>(e);
            asyncSpill(pe->operand, pre);
            e = propagateSpill(pe, pre);
            return;
        }
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            if ((b->op == "&&" || b->op == "||") && !b->opMethod && containsAwait(b->rhs)) {
                VarInfo* t = hiddenLocal(boolT, loc, false);
                asyncSpill(b->lhs, pre);
                pre.push_back(bindDecl(t, b->lhs));
                std::vector<Stmt*> inner;
                asyncSpill(b->rhs, inner);
                inner.push_back(assignStmt(t, b->rhs, loc));
                auto* is = new IfStmt(loc);
                is->cond = b->op == "&&" ? (Expr*)checkedRef(t, loc) : notOf(checkedRef(t, loc), boolT);
                is->then = blockOf(inner, loc, false);
                pre.push_back(is);
                e = checkedRef(t, loc);
                return;
            }
            break;
        }
        case EK::Cond: {
            auto* c = static_cast<CondExpr*>(e);
            if (containsAwait(c->a) || containsAwait(c->b)) {
                VarInfo* t = hiddenLocal(e->type, loc, false);
                asyncSpill(c->cond, pre);
                std::vector<Stmt*> pa, pb;
                asyncSpill(c->a, pa);
                pa.push_back(assignStmt(t, c->a, loc));
                asyncSpill(c->b, pb);
                pb.push_back(assignStmt(t, c->b, loc));
                auto* is = new IfStmt(loc);
                is->cond = c->cond;
                is->then = blockOf(pa, loc, false);
                is->els = blockOf(pb, loc, false);
                pre.push_back(is);
                e = checkedRef(t, loc);
                return;
            }
            break;
        }
        case EK::Let: {  // (<h1> = a, <h2> = b, seq...): las asignaciones pasan a ser sentencias
            auto* l = static_cast<LetExpr*>(e);
            for (auto& [v, init] : l->binds) {
                asyncSpill(init, pre);
                pre.push_back(assignStmt(v, init, loc));
            }
            l->binds.clear();
            size_t k = 0;
            for (size_t i = 0; i < l->seq.size(); i++)
                if (containsAwait(l->seq[i])) k = i;
            for (size_t i = 0; i < k; i++) {
                auto* es = new ExprStmt(l->seq[i]->loc);
                es->expr = l->seq[i];
                pre.push_back(es);
            }
            l->seq.erase(l->seq.begin(), l->seq.begin() + (long)k);
            if (!l->seq.empty()) asyncSpill(l->seq[0], pre);
            if (l->seq.size() == 1) e = l->seq[0];
            return;
        }
        case EK::CondAccess:
            if (containsAwait(static_cast<CondAccessExpr*>(e)->access)) return;  // no admitido (asyncValidate)
            break;
        case EK::CoalesceAssign:
            if (containsAwait(static_cast<CoalesceAssignExpr*>(e)->rhs)) return;  // no admitido
            break;
        default: break;
    }
    // Caso general: los hijos anteriores al último que contiene un 'await' se evalúan antes.
    std::vector<Slot> slots = slotsOf(e);
    int k = -1;
    for (int i = 0; i < (int)slots.size(); i++)
        if (containsAwait(*slots[i].p)) k = i;
    if (k < 0) return;
    for (int i = 0; i < k; i++) {
        if (slots[i].lvalue) {
            stabilize(*slots[i].p);
            continue;
        }
        asyncSpill(*slots[i].p, pre);  // sus propios 'await' van antes, en orden
        if (needsSpill(*slots[i].p)) asyncTemp(*slots[i].p, pre);
    }
    if (slots[k].lvalue) {  // arr[await i] = x: el lvalue se queda, sus partes se calculan antes
        Expr* lv = *slots[k].p;
        if (lv->kind == EK::Await) return;
        std::vector<Slot> inner = slotsOf(lv);
        int kk = -1;
        for (int i = 0; i < (int)inner.size(); i++)
            if (containsAwait(*inner[i].p)) kk = i;
        for (int i = 0; i < kk; i++) {
            if (inner[i].lvalue) {
                stabilize(*inner[i].p);
                continue;
            }
            asyncSpill(*inner[i].p, pre);
            if (needsSpill(*inner[i].p)) asyncTemp(*inner[i].p, pre);
        }
        if (kk >= 0 && !inner[kk].lvalue) asyncSpill(*inner[kk].p, pre);
        return;
    }
    asyncSpill(*slots[k].p, pre);
}

// Después de comprobar una sentencia con algún 'await' en sus propias expresiones: forma reescrita
// (s->lowered) con los 'await' como sentencias AwaitStmt delante.
void Sema::asyncLowerStmt(Stmt* s) {
    if (!s) return;  // (checkStmt solo llama con 'await' en un método async o con '?' de Unions.cpp)
    if (s->lowered) {
        asyncLowerStmt(s->lowered);
        return;
    }
    SourceLoc loc = s->loc;
    auto wrap = [&](std::vector<Stmt*> pre, Stmt* last) {
        pre.push_back(last);
        s->lowered = blockOf(pre, loc, true);
    };
    switch (s->kind) {
        case SK::Block:
            for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) asyncLowerStmt(c);
            break;
        case SK::ExprStmt: {
            auto* es = static_cast<ExprStmt*>(s);
            if (!containsAwait(es->expr)) break;
            if (es->expr->kind == EK::Await && !es->expr->lowered) {  // await t;
                auto* aw = static_cast<AwaitExpr*>(es->expr);
                std::vector<Stmt*> pre;
                asyncSpill(aw->operand, pre);
                pre.push_back(asyncAwaitStmt(aw, false));
                s->lowered = blockOf(pre, loc, true);
                break;
            }
            std::vector<Stmt*> pre;
            asyncSpill(es->expr, pre);
            auto* n = new ExprStmt(*es);
            n->lowered = nullptr;
            wrap(pre, n);
            break;
        }
        case SK::VarDecl: {
            auto* d = static_cast<VarDeclStmt*>(s);
            bool any = false;
            for (auto& dc : d->decls) any |= dc.init && !(dc.var && dc.var->isRef) && containsAwait(dc.init);
            if (!any) break;
            std::vector<Stmt*> out;
            for (auto& dc : d->decls) {
                if (dc.init && !(dc.var && dc.var->isRef)) asyncSpill(dc.init, out);
                auto* one = new VarDeclStmt(*d);
                one->lowered = nullptr;
                one->decls = {dc};
                out.push_back(one);
            }
            s->lowered = blockOf(out, loc, true);
            break;
        }
        case SK::Return: {
            auto* rs = static_cast<ReturnStmt*>(s);
            if (!containsAwait(rs->value)) break;
            std::vector<Stmt*> pre;
            auto* n = new ReturnStmt(*rs);
            n->lowered = nullptr;
            if (rs->value->kind == EK::Await && rs->value->type && rs->value->type->isVoid()) {
                auto* aw = static_cast<AwaitExpr*>(rs->value);  // async () => await Tarea()
                asyncSpill(aw->operand, pre);
                pre.push_back(asyncAwaitStmt(aw, false));
                n->value = nullptr;
            } else {
                asyncSpill(n->value, pre);
            }
            wrap(pre, n);
            break;
        }
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            if (!containsAwait(is->cond)) break;
            std::vector<Stmt*> pre;
            auto* n = new IfStmt(*is);
            n->lowered = nullptr;
            asyncSpill(n->cond, pre);
            wrap(pre, n);
            break;
        }
        case SK::While: {  // while (c) b  ->  while (true) { pre; if (!c) break; b }
            auto* ws = static_cast<WhileStmt*>(s);
            if (!containsAwait(ws->cond)) break;
            std::vector<Stmt*> body;
            Expr* cond = ws->cond;
            asyncSpill(cond, body);
            auto* brk = new IfStmt(loc);
            brk->cond = notOf(cond, tc_.get(TK::Bool));
            brk->then = new BreakStmt(loc);
            body.push_back(brk);
            body.push_back(ws->body);
            auto* w = new WhileStmt(loc);
            auto* t = new BoolLitExpr(loc);
            t->value = true;
            t->type = tc_.get(TK::Bool);
            w->cond = t;
            w->body = blockOf(body, loc, false);
            s->lowered = w;
            break;
        }
        case SK::Switch: {
            auto* ss = static_cast<SwitchStmt*>(s);
            if (!containsAwait(ss->subject)) break;
            std::vector<Stmt*> pre;
            auto* n = new SwitchStmt(*ss);
            n->lowered = nullptr;
            asyncSpill(n->subject, pre);
            wrap(pre, n);
            break;
        }
        case SK::Throw: {
            auto* ts = static_cast<ThrowStmt*>(s);
            if (!containsAwait(ts->value)) break;
            std::vector<Stmt*> pre;
            auto* n = new ThrowStmt(*ts);
            n->lowered = nullptr;
            asyncSpill(n->value, pre);
            wrap(pre, n);
            break;
        }
        case SK::Delete: {
            auto* ds = static_cast<DeleteStmt*>(s);
            if (!containsAwait(ds->expr)) break;
            std::vector<Stmt*> pre;
            auto* n = new DeleteStmt(*ds);
            n->lowered = nullptr;
            asyncSpill(n->expr, pre);
            wrap(pre, n);
            break;
        }
        case SK::Using: {
            auto* u = static_cast<UsingStmt*>(s);
            if (u->decl) asyncLowerStmt(u->decl);
            break;
        }
        case SK::Yield: {  // yield return await x; (iterador async, Iterators.cpp)
            auto* ys = static_cast<YieldStmt*>(s);
            if (!containsAwait(ys->store)) break;
            std::vector<Stmt*> pre;
            auto* n = new YieldStmt(*ys);
            n->lowered = nullptr;
            asyncSpill(n->store, pre);
            wrap(pre, n);
            break;
        }
        default: break;  // do-while y for con 'await' en la condición: error en asyncValidate
    }
}

// ================================================================== comprobación final

namespace {

struct AwaitValidator {
    std::set<AwaitExpr*> reported;
    void expr(Expr* e) {
        if (!e) return;
        if (e->lowered) {
            expr(e->lowered);
            return;
        }
        if (e->kind == EK::Await) {
            auto* aw = static_cast<AwaitExpr*>(e);
            if (!aw->spilled && aw->type && !aw->type->isError() && reported.insert(aw).second)
                diag.error(e->loc, "'await' cannot be used in this position (inside '?.' or '?\?=', in the condition or "
                                   "increment of a 'for', in the condition of a 'do-while', or in a 'ref' reference); "
                                   "store the result in a variable first: var x = await ...;");
        }
        for (Slot& s : slotsOf(e)) expr(*s.p);
    }
    void stmt(Stmt* s) {
        if (!s) return;
        if (s->lowered) {
            stmt(s->lowered);
            return;
        }
        switch (s->kind) {
            case SK::Block:
                for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) stmt(c);
                break;
            case SK::VarDecl:
                for (auto& dc : static_cast<VarDeclStmt*>(s)->decls) expr(dc.init);
                break;
            case SK::ExprStmt: expr(static_cast<ExprStmt*>(s)->expr); break;
            case SK::If: {
                auto* is = static_cast<IfStmt*>(s);
                expr(is->cond);
                stmt(is->then);
                stmt(is->els);
                break;
            }
            case SK::While: {
                auto* ws = static_cast<WhileStmt*>(s);
                expr(ws->cond);
                stmt(ws->body);
                break;
            }
            case SK::DoWhile: {
                auto* ds = static_cast<DoWhileStmt*>(s);
                stmt(ds->body);
                expr(ds->cond);
                break;
            }
            case SK::For: {
                auto* fs = static_cast<ForStmt*>(s);
                stmt(fs->initDecl);
                for (Expr* x : fs->initExprs) expr(x);
                expr(fs->cond);
                for (Expr* x : fs->iter) expr(x);
                stmt(fs->body);
                break;
            }
            case SK::Return: expr(static_cast<ReturnStmt*>(s)->value); break;
            case SK::Switch: {
                auto* ss = static_cast<SwitchStmt*>(s);
                expr(ss->subject);
                for (auto& sec : ss->sections)
                    for (Stmt* b : sec.body) stmt(b);
                break;
            }
            case SK::Delete: expr(static_cast<DeleteStmt*>(s)->expr); break;
            case SK::Try: {
                auto* t = static_cast<TryStmt*>(s);
                stmt(t->body);
                for (auto& c : t->catches) {
                    expr(c.filter);
                    stmt(c.body);
                }
                stmt(t->finallyBody);
                break;
            }
            case SK::Throw: expr(static_cast<ThrowStmt*>(s)->value); break;
            case SK::Yield: expr(static_cast<YieldStmt*>(s)->store); break;
            case SK::Using: {
                auto* u = static_cast<UsingStmt*>(s);
                stmt(u->decl);
                if (!u->decl) expr(u->expr);
                stmt(u->body);
                break;
            }
            default: break;
        }
    }
};

}  // namespace

void Sema::asyncValidate(Stmt* s) {
    AwaitValidator v;
    v.stmt(s);
}
