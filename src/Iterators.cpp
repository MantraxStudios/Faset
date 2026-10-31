// Faset - iteradores (análisis semántico): 'yield return' / 'yield break', IEnumerable<T> /
// IEnumerator<T>, flujos asíncronos (IAsyncEnumerable<T>, 'await foreach'), implementaciones
// explícitas de interfaces y la conversión de string a IEnumerable<char>. La generación de C está en
// CodeGenIterators.cpp y la biblioteca en lib/std/collections/*.fst y lib/std/task/flujos.fst.
//
// Diseño (como en C#):
//
//  * Un método, propiedad, función local o lambda cuyo cuerpo contiene 'yield' es un ITERADOR. Se
//    compila con la misma máquina de estados que async/await (Async.cpp): todas sus variables viven
//    en un MARCO del recolector y cada 'yield return' es un punto de suspensión, igual que un 'await'.
//    Llamar al método no ejecuta nada del cuerpo: solo crea el marco (con una copia de los argumentos)
//    y un generador (std.collections.Generador<T>, que es a la vez IEnumerable<T> e IEnumerator<T>).
//
//  * MoveNext() llama a la función de paso, que sigue desde el último 'yield' hasta el siguiente
//    (guarda el valor en Current y devuelve true) o hasta el final (devuelve false). Es perezoso: un
//    generador infinito solo calcula lo que se pide.
//
//  * Dispose() (lo llama 'foreach' en un 'finally' al salir del bucle, también con break, return o
//    una excepción) reanuda el iterador en el 'yield' donde está suspendido como si allí hubiera un
//    'yield break': se ejecutan los bloques 'finally' pendientes del iterador y termina.
//
//  * Una excepción dentro del iterador sale de MoveNext() hacia quien recorre (y el iterador queda
//    terminado). 'return' no se admite (se termina con 'yield break') ni 'yield' dentro de 'finally'.
//
//  * GetEnumerator() de un IEnumerable<T> devuelve el propio generador la primera vez; las siguientes
//    crean otro marco con los argumentos originales (cada recorrido empieza desde el principio).
//
//  * 'async IAsyncEnumerable<T> F()' admite 'await' y 'yield return': MoveNextAsync() devuelve una
//    Task<bool> que se completa en el siguiente 'yield' (true) o al terminar (false). Se consume con
//    'await foreach (var x in F()) ...', que llama a DisposeAsync() al salir.
#include "Sema.h"

namespace {

NameExpr* refTo(VarInfo* v, SourceLoc loc) {  // sin comprobar: se resuelve por nombre
    auto* n = new NameExpr(loc);
    n->name = v->name;
    return n;
}

NameExpr* checkedRef(VarInfo* v, SourceLoc loc) {
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

BlockStmt* blockOf(std::vector<Stmt*> stmts, SourceLoc loc) {
    auto* b = new BlockStmt(loc);
    b->stmts = std::move(stmts);
    return b;
}

// Silencia los diagnósticos de una resolución de prueba (como en Lambdas.cpp).
struct Mute {
    int errors;
    bool capture;
    size_t captured;
    Mute() : errors(diag.errorCount), capture(diag.capture), captured(diag.captured.size()) { diag.capture = true; }
    ~Mute() {
        diag.errorCount = errors;
        diag.captured.erase(diag.captured.begin() + (long)captured, diag.captured.end());
        diag.capture = capture;
    }
};

ExprStmt* exprStmt(Expr* e) {
    auto* s = new ExprStmt(e->loc);
    s->expr = e;
    return s;
}

}  // namespace

// ================================================================== detección

// ¿Contiene el cuerpo algún 'yield'? (sin entrar en lambdas ni funciones locales: son expresiones)
bool Sema::iterHasYield(Stmt* s) {
    if (!s) return false;
    switch (s->kind) {
        case SK::Yield: return true;
        case SK::Block:
            for (Stmt* c : static_cast<BlockStmt*>(s)->stmts)
                if (iterHasYield(c)) return true;
            return false;
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            return iterHasYield(is->then) || iterHasYield(is->els);
        }
        case SK::While: return iterHasYield(static_cast<WhileStmt*>(s)->body);
        case SK::DoWhile: return iterHasYield(static_cast<DoWhileStmt*>(s)->body);
        case SK::For: return iterHasYield(static_cast<ForStmt*>(s)->body);
        case SK::Foreach: return iterHasYield(static_cast<ForeachStmt*>(s)->body);
        case SK::Using: return iterHasYield(static_cast<UsingStmt*>(s)->body);
        case SK::Switch:
            for (auto& sec : static_cast<SwitchStmt*>(s)->sections)
                for (Stmt* b : sec.body)
                    if (iterHasYield(b)) return true;
            return false;
        case SK::Try: {
            auto* t = static_cast<TryStmt*>(s);
            if (iterHasYield(t->body) || iterHasYield(t->finallyBody)) return true;
            for (auto& c : t->catches)
                if (iterHasYield(c.body)) return true;
            return false;
        }
        default: return ctAnyChild(s, [](Stmt* c) { return iterHasYield(c); });  // comptime if/foreach (Comptime.cpp)
    }
}

// ================================================================== tipos de la biblioteca

ClassDecl* Sema::iterLibType(const char* module, const char* name, bool generic) {
    NamespaceSym* ns = findNs({"std", module});
    if (!ns) return nullptr;
    auto it = ns->types.find(name);
    if (it == ns->types.end()) return nullptr;
    ClassDecl* c = it->second;
    if (c->isTemplate() != generic) c = c->arityTwin;
    return c;
}

// 1 IEnumerable<T>, 2 IEnumerator<T>, 3 IAsyncEnumerable<T>, 4 IAsyncEnumerator<T> (0: ninguno).
int Sema::iterKindOf(Type* t, Type** elem) {
    if (!t || !t->isClass() || !t->decl || !t->decl->templateOf || t->decl->typeArgs.size() != 1) return 0;
    static const char* const names[] = {"IEnumerable", "IEnumerator", "IAsyncEnumerable", "IAsyncEnumerator"};
    for (int k = 0; k < 4; k++) {
        ClassDecl* d = iterLibType(k < 2 ? "collections" : "task", names[k], true);
        if (d && t->decl->templateOf == d) {
            if (elem) *elem = t->decl->typeArgs[0];
            return k + 1;
        }
    }
    return 0;
}

// ================================================================== iterador: comienzo

AsyncInfo* Sema::iterBegin(MethodDecl* fn, Type* ret, LambdaExpr* lambda, bool isAsync, SourceLoc loc) {
    auto* a = new AsyncInfo();
    a->fn = fn;
    a->lambda = lambda;
    a->ret = ret;
    a->depth = (int)lambdaStack_.size();
    a->result = tc_.get(TK::Void);  // no hay 'return' con valor
    a->iterKind = -1;
    a->elem = tc_.error();
    fn->async = a;
    ctx_.async = a;
    if (trialDepth_ == 0) asyncFns.push_back(a);
    if (!lambda) {
        for (Param& p : fn->params) {
            if (p.isRef()) diag.error(p.loc, "an iterator cannot have 'ref' or 'out' parameters");
            if (p.var) a->vars.push_back(p.var);
        }
        if (fn->kind != MethodKind::Normal && fn->kind != MethodKind::Getter)
            diag.error(fn->loc, "only methods, (get) properties and local functions can use 'yield'");
        if (fn->owner && fn->owner->kind == ClassKind::Struct && !fn->isStatic())
            diag.error(fn->loc, "an instance iterator cannot be in a struct (the struct would be copied); "
                                "use a class or a static method");
        if (fn->retIsRef()) diag.error(fn->loc, "an iterator cannot return a reference");
    }
    if (!ret) {
        diag.error(loc, "a lambda with 'yield' needs a known delegate type that returns IEnumerable<T> "
                        "(declare it as a local function: IEnumerable<int> Numeros() { yield return 1; })");
        return a;
    }
    if (ret->isError()) return a;
    Type* elem = nullptr;
    int kind = iterKindOf(ret, &elem);
    if (!kind) {
        diag.error(loc, std::string("an iterator (with 'yield') must return ") +
                            (isAsync ? "IAsyncEnumerable<T> or IAsyncEnumerator<T>" : "IEnumerable<T> or IEnumerator<T>") +
                            " (not '" + ret->str() + "')");
        return a;
    }
    if (isAsync && kind <= 2) {
        diag.error(loc, "an 'async' iterator must return IAsyncEnumerable<T> or IAsyncEnumerator<T> (not '" + ret->str() + "')");
        return a;
    }
    if (!isAsync && kind >= 3) {
        diag.error(loc, "an iterator that returns '" + ret->str() + "' must be 'async' (async IAsyncEnumerable<T> F() { ... })");
        return a;
    }
    ClassDecl* gt = iterLibType(kind <= 2 ? "collections" : "task", kind <= 2 ? "Generador" : "GeneradorAsync", true);
    if (!gt || (isAsync && !taskDecl(true))) {
        diag.error(loc, kind <= 2 ? "'yield' needs the std.collections library (add 'using std.collections;')"
                                  : "async streams need the std.task library (add 'using std.task;')");
        return a;
    }
    ClassDecl* gi = instantiate(gt, {elem}, loc);
    if (!gi) return a;
    MethodDecl* ctor = nullptr;
    for (MethodDecl* k : gi->ctors)
        if (k->params.size() == 2) ctor = k;
    if (!ctor) return a;
    a->iterKind = kind;
    a->elem = elem;
    a->gen = gi->type;
    Type* boolT = tc_.get(TK::Bool);
    Type* stepRet = boolT;
    if (isAsync) {
        // Igual que un método async (asyncBegin): continuación, tarea de cada MoveNextAsync y su resultado.
        Type* taskT = taskOf(boolT, loc);
        a->cont = hiddenLocal(tc_.delegateType({}, tc_.get(TK::Void)), loc, false);
        a->task = hiddenLocal(taskT, loc, false);
        auto* nw = new NewExpr(loc);
        nw->type = taskT;
        nw->ctor = paramlessCtor(taskT->decl);
        if (nw->ctor) useMethod(nw->ctor);
        auto* as = new AssignExpr(loc);
        as->op = "=";
        as->lhs = checkedRef(a->task, loc);
        as->rhs = nw;
        as->type = taskT;
        a->newTask = as;
        a->res = hiddenLocal(boolT, loc, false);
        a->setResult = mkCall(mkMember(refTo(a->task, loc), "SetResult", loc), {refTo(a->res, loc)}, loc);
        checkValue(a->setResult);
        if (exceptionClass) {
            a->exc = hiddenLocal(exceptionClass->type, loc, false);
            a->setException = mkCall(mkMember(refTo(a->task, loc), "SetException", loc), {refTo(a->exc, loc)}, loc);
            checkValue(a->setException);
        }
        stepRet = taskT;
    }
    a->stepDlg = hiddenLocal(tc_.delegateType({tc_.get(TK::Int)}, stepRet), loc, false);
    a->cloneDlg = hiddenLocal(tc_.delegateType({}, a->gen), loc, false);
    a->iterObj = hiddenLocal(a->gen, loc, false);
    auto* nw = new NewExpr(loc);
    nw->type = a->gen;
    nw->ctor = ctor;
    nw->args = {checkedRef(a->stepDlg, loc), checkedRef(a->cloneDlg, loc)};
    useMethod(ctor);
    auto* as = new AssignExpr(loc);
    as->op = "=";
    as->lhs = checkedRef(a->iterObj, loc);
    as->rhs = nw;
    as->type = a->gen;
    a->newIter = as;
    // Los miembros del generador que usa la máquina (la interfaz los pide igualmente).
    for (MethodDecl* m : gi->methods) useMethod(m);
    return a;
}

// Método o propiedad: ¿es un iterador? (lo llama checkMethod antes de comprobar el cuerpo)
AsyncInfo* Sema::iterMethodBegin(MethodDecl* m) {
    if (!iterHasYield(m->body)) return nullptr;
    return iterBegin(m, m->ret, nullptr, m->mods.isAsync, m->loc);
}

// ================================================================== yield

void Sema::checkYield(YieldStmt* y) {
    AsyncInfo* a = ctx_.async;
    if (!a || !a->iterKind || ctx_.method != a->fn) {
        if (y->value) checkOperand(y->value);
        diag.error(y->loc, "'yield' can only be used in the body of a method, property or local function that returns "
                           "IEnumerable<T> or IEnumerator<T> (or IAsyncEnumerable<T> if async)");
        return;
    }
    for (char h : ctx_.excHandlers)
        if (h == 'F') {
            diag.error(y->loc, "'yield' cannot be used inside a 'finally' block");
            break;
        }
    if (ideMode && a->iterKind > 0)
        addRef(y->loc, 5, y->isBreak ? "yield break: ends the iterator (its 'finally' blocks run)"
                                     : "yield return: yields an element of '" + a->ret->str() +
                                           "' and suspends the iterator until the next MoveNext()", nullptr);
    if (y->isBreak) return;
    a->yields++;
    if (a->iterKind < 0) {
        checkOperand(y->value);
        return;
    }
    // <it>.__actual = valor   (convierte el valor al tipo de los elementos)
    auto* as = new AssignExpr(y->loc);
    as->op = "=";
    as->lhs = mkMember(refTo(a->iterObj, y->loc), "__actual", y->loc);
    as->rhs = y->value;
    Type* t = checkValue(as);
    if (!t->isError()) y->store = as;
}

bool Sema::iterCheckStmt(Stmt* s) {
    if (s->kind == SK::Yield) {
        checkYield(static_cast<YieldStmt*>(s));
        return true;
    }
    if (s->kind == SK::Foreach && static_cast<ForeachStmt*>(s)->isAwait) {
        checkAwaitForeach(static_cast<ForeachStmt*>(s));
        return true;
    }
    return false;
}

// 'return' dentro de un iterador (método o lambda): error.
bool Sema::iterReturn(ReturnStmt* rs, AsyncInfo* a) {
    if (!a || !a->iterKind) return false;
    if (rs->value) checkOperand(rs->value);
    diag.error(rs->loc, "'return' cannot be used in an iterator: use 'yield return value;' to produce an element "
                        "and 'yield break;' to finish");
    return true;
}

// 'await' en un iterador que no es async.
bool Sema::iterAwaitInvalid(AwaitExpr* e) {
    AsyncInfo* a = ctx_.async;
    if (!a || !a->iterKind) return false;
    if (a->cont) return false;  // iterador async: el 'await' es válido
    checkValue(e->operand);
    if (!a->isAsyncIter() && a->iterKind > 0)
        diag.error(e->loc, "'await' can only be used in an 'async' iterator (async IAsyncEnumerable<T> F() { ... })");
    return true;
}

// ================================================================== foreach

// foreach sobre un enumerador con Dispose() (IEnumerator<T>): el bucle va en un try/finally que lo
// llama al salir (también con break, return o una excepción). Los enumeradores struct de List,
// Dictionary... no tienen Dispose: su foreach sigue siendo un bucle sin reservas de memoria.
Stmt* Sema::iterForeachLoop(VarInfo* ev, Type* et, Stmt* loop, SourceLoc loc) {
    if (!et || !et->isClass() || !et->decl) return loop;
    bool has = false;
    for (MethodDecl* m : findMethods(et->decl, "Dispose"))
        if (m->params.empty() && !m->isStatic() && m->ret && m->ret->isVoid()) has = true;
    if (!has) return loop;
    auto* t = new TryStmt(loc);
    t->body = blockOf({loop}, loc);
    t->finallyBody = blockOf({exprStmt(mkCall(mkMember(refTo(ev, loc), "Dispose", loc), {}, loc))}, loc);
    return t;
}

// foreach sobre una clase que solo implementa IEnumerable<T> de forma explícita: se recorre la interfaz.
Type* Sema::iterForeachSource(Expr*& coll, Type* ct) {
    if (!ct->isClass() || !ct->decl) return ct;
    for (ClassDecl* i : ct->decl->allInterfaces)
        if (iterKindOf(i->type, nullptr) == 1) {
            coerce(coll, i->type);
            return i->type;
        }
    return ct;
}

// await foreach (var x in flujo) cuerpo  ->
//     <c> = flujo; <e> = <c>.GetAsyncEnumerator();
//     try { while (await <e>.MoveNextAsync()) { var x = <e>.Current; cuerpo } }
//     finally { await <e>.DisposeAsync(); }
void Sema::checkAwaitForeach(ForeachStmt* s) {
    SourceLoc loc = s->loc;
    AsyncInfo* a = ctx_.async;
    Type* ct = checkValue(s->coll);
    ctx_.scopes.emplace_back();
    auto fallback = [&]() {
        if (!s->name.empty()) declareLocal(s->name, tc_.error(), s->nameLoc, "l_");
        for (size_t i = 0; i < s->names.size(); i++) declareLocal(s->names[i], tc_.error(), s->nameLocs[i], "l_");
        ctx_.loopDepth++;
        checkStmt(s->body);
        ctx_.loopDepth--;
        ctx_.scopes.pop_back();
    };
    if (!a || !a->cont) {
        diag.error(loc, "'await foreach' can only be used inside an 'async' method or lambda");
        return fallback();
    }
    if (ct->isError()) return fallback();
    bool has = ct->isAggregate() && !findMethods(ct->decl, "GetAsyncEnumerator").empty();
    if (!has) {
        diag.error(s->coll->loc, "'await foreach' cannot iterate over a value of type '" + ct->str() +
                                     "': it needs a GetAsyncEnumerator() method (like IAsyncEnumerable<T>)");
        return fallback();
    }
    VarInfo* cv = hiddenLocal(ct, loc, false);
    VarDeclStmt* d1 = bindDecl(cv, s->coll);
    Expr* getEnum = mkCall(mkMember(refTo(cv, loc), "GetAsyncEnumerator", loc), {}, loc);
    Type* et = checkValue(getEnum);
    if (et->isError()) return fallback();
    VarInfo* ev = hiddenLocal(et, loc, false);
    VarDeclStmt* d2 = bindDecl(ev, getEnum);
    auto* next = new AwaitExpr(loc);
    next->operand = mkCall(mkMember(refTo(ev, loc), "MoveNextAsync", loc), {}, loc);
    auto* w = new WhileStmt(loc);
    w->cond = next;
    auto* inner = new BlockStmt(s->body->loc);
    Expr* current = mkMember(refTo(ev, loc), "Current", loc);
    if (!s->name.empty()) {
        auto* vd = new VarDeclStmt(s->nameLoc);
        vd->tref = s->tref;
        VarDeclStmt::Declarator dc;
        dc.loc = s->nameLoc;
        dc.name = s->name;
        dc.init = current;
        vd->decls.push_back(dc);
        inner->stmts.push_back(vd);
    } else {
        auto* ds = new DeconstructStmt(loc);
        ds->names = s->names;
        ds->types = s->types;
        ds->locs = s->nameLocs;
        ds->init = current;
        inner->stmts.push_back(ds);
    }
    inner->stmts.push_back(s->body);
    w->body = inner;
    auto* dispose = new AwaitExpr(loc);
    dispose->operand = mkCall(mkMember(refTo(ev, loc), "DisposeAsync", loc), {}, loc);
    auto* t = new TryStmt(loc);
    t->body = blockOf({w}, loc);
    t->finallyBody = blockOf({exprStmt(dispose)}, loc);
    checkStmt(t);
    ctx_.scopes.pop_back();
    auto* blk = new BlockStmt(loc);
    blk->stmts = {d1, d2, t};
    s->lowered = blk;
}

// ================================================================== genéricos y conversiones

// unify(IEnumerable<T>, List<int>): busca la interfaz (o la base) genérica con ese nombre entre las
// que implementa el tipo del argumento; string es IEnumerable<char>.
void Sema::iterUnify(TypeRef* p, Type* t, MethodDecl* tmpl, std::map<std::string, Type*>& b) {
    if (p->typeArgs.empty() || p->ptrDepth != 0) return;
    const std::string& want = p->parts.back();
    if (t->is(TK::String)) {
        if (want == "IEnumerable" && p->typeArgs.size() == 1) unify(p->typeArgs[0], tc_.get(TK::Char), tmpl, b);
        return;
    }
    if (!t->isClass() || !t->decl) return;
    auto match = [&](ClassDecl* d) {
        if (!d->templateOf || d->templateOf->name != want || d->typeArgs.size() != p->typeArgs.size()) return false;
        for (size_t i = 0; i < p->typeArgs.size(); i++) unify(p->typeArgs[i], d->typeArgs[i], tmpl, b);
        return true;
    };
    if (t->decl->templateOf && t->decl->templateOf->name == want) return;  // ya lo trata unify
    for (ClassDecl* k = t->decl->base; k; k = k->base)
        if (match(k)) return;
    for (ClassDecl* i : t->decl->allInterfaces)
        if (match(i)) return;
}

bool Sema::iterStringToEnumerable(Type* from, Type* to) {
    Type* elem = nullptr;
    return from && from->is(TK::String) && iterKindOf(to, &elem) == 1 && elem->is(TK::Char);
}

int Sema::iterImplicit(Expr* e, Type* from, Type* to) {
    (void)e;
    if (iterStringToEnumerable(from, to)) return 1;
    return -1;
}

// string -> IEnumerable<char>: Enumerable.Caracteres(s) (un iterador sobre los caracteres).
bool Sema::iterCoerce(Expr*& e, Type* to) {
    if (!iterStringToEnumerable(e->type, to)) return false;
    ClassDecl* en = iterLibType("collections", "Enumerable", false);
    MethodDecl* m = nullptr;
    if (en) {
        resolveClassSignatures(en);
        for (MethodDecl* k : en->methods)
            if (k->name == "Caracteres" && k->isStatic() && k->params.size() == 1 && !k->isTemplate()) m = k;
    }
    if (!m) {
        diag.error(e->loc, "converting string to IEnumerable<char> needs std.collections (add 'using std.collections;')");
        return true;
    }
    auto* callee = new NameExpr(e->loc);
    callee->name = m->name;
    callee->vk = ValKind::MethodGroup;
    callee->group = {m};
    callee->type = tc_.get(TK::Void);
    auto* c = new CallExpr(e->loc);
    c->callee = callee;
    c->args = {e};
    c->target = m;
    c->type = m->ret;
    useMethod(m, &e->loc);
    e = c;
    if (m->ret != to) coerce(e, to);
    return true;
}

// ================================================================== implementaciones explícitas

// 'IEnumerator<T> IEnumerable<T>.GetEnumerator()': la interfaz se resuelve con la firma.
void Sema::iterResolveExplicit(MethodDecl* m) {
    if (!m->explicitIface) return;
    Type* t = resolveType(m->explicitIface);
    if (t->isError()) return;
    if (!t->isClass() || !t->decl->isInterface()) {
        diag.error(m->explicitIface->loc, "'" + t->str() + "' is not an interface: only interface members can be "
                                                              "implemented explicitly");
        return;
    }
    m->explicitDecl = t->decl;
    m->mods.access = Access::Public;  // se usa a través de la interfaz
}

MethodDecl* Sema::iterExplicitImpl(ClassDecl* c, MethodDecl* im) {
    for (ClassDecl* k = c; k; k = k->base)
        for (MethodDecl* m : k->methods) {
            if (!m->explicitDecl || m->explicitDecl != im->owner || m->explicitName != im->name || m->kind != im->kind)
                continue;
            if (m->params.size() != im->params.size()) continue;
            bool same = true;
            for (size_t i = 0; i < m->params.size(); i++)
                same &= m->params[i].type == im->params[i].type && m->params[i].isRef() == im->params[i].isRef();
            if (same) return m;
        }
    return nullptr;
}

// ================================================================== métodos de extensión

// obj.Metodo(args) con métodos propios que no aceptan los argumentos pero sí un método de extensión
// (como en C#): dic.Count(kv => kv.Value > 1) usa Enumerable.Count sobre IEnumerable<KeyValuePair>
// aunque Dictionary tenga su propio Count(Func<K, V, bool>).
void Sema::iterExtensionFallback(MemberExpr* me, std::vector<Expr*>& args, SourceLoc loc,
                                 const std::vector<TypeRef*>& typeArgs) {
    if (me->extension || me->arrow || !me->obj || me->obj->vk != ValKind::Value || me->group.empty()) return;
    for (Expr* a : args)
        if (a->type && a->type->isError()) return;
    std::vector<MethodDecl*> ext = findExtensions(me->name);
    if (ext.empty()) return;
    {
        Mute mute;
        if (resolveOverload(me->group, args, loc, me->name, typeArgs, false)) return;
    }
    std::vector<Expr*> withObj = args;
    withObj.insert(withObj.begin(), me->obj);
    {
        Mute mute;
        if (!resolveOverload(ext, withObj, loc, me->name, typeArgs, false)) return;
    }
    me->group = ext;
    me->extension = true;
}
