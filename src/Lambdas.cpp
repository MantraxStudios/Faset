// Faset - lambdas, cierres, delegados y eventos (análisis semántico).
//
// Tipos delegado
//   Func<A, B, R>, Action<A, B> y los delegados declarados (delegate int Comparador(string a,
//   string b);) son tipos *estructurales*: dos delegados con la misma firma son el mismo tipo.
//   Un valor delegado es una referencia (puede ser null) a un objeto del recolector con la función
//   y su entorno (ver CodeGenLambdas.cpp).
//
// Lambdas
//   Una lambda no tiene tipo propio: su expresión queda "pendiente" (TK::Pending) hasta que se
//   convierte a un delegado de destino (coerce). Para elegir sobrecargas e inferir argumentos de
//   tipo (lista.Select(x => x * 2) -> Select<int>) se comprueban *copias de prueba*: la lambda se
//   vuelve a analizar desde sus tokens y se comprueba con los diagnósticos silenciados; la
//   comprobación definitiva se hace sobre el nodo original al convertirlo.
//
// Cierres
//   Las variables locales y parámetros que usa una lambda declarada más adentro se marcan como
//   capturadas (VarInfo::captured). El generador las guarda en una caja del recolector creada al
//   ejecutar su declaración: el método y todas las lambdas comparten esa caja (captura por
//   referencia, como en C#), y la caja sigue viva mientras alguna lambda la alcance.
#include <algorithm>

#include "Parser.h"
#include "Sema.h"

namespace {

// Silencia los diagnósticos mientras se comprueba una copia de prueba.
struct DiagMute {
    int errors;
    bool capture;
    size_t captured;
    DiagMute() : errors(diag.errorCount), capture(diag.capture), captured(diag.captured.size()) { diag.capture = true; }
    int count() const { return diag.errorCount - errors; }
    ~DiagMute() {
        diag.errorCount = errors;
        diag.captured.erase(diag.captured.begin() + (long)captured, diag.captured.end());
        diag.capture = capture;
    }
};

std::string typesKey(const std::vector<Type*>& ts, Type* ret) {
    std::string k;
    for (Type* t : ts) k += std::to_string((uintptr_t)t) + ",";
    return k + "->" + (ret ? std::to_string((uintptr_t)ret) : "?");
}

std::vector<TypeRef*>* typeArgsOf(Expr* e) {
    if (e->kind == EK::Name) return &static_cast<NameExpr*>(e)->typeArgs;
    if (e->kind == EK::Member) return &static_cast<MemberExpr*>(e)->typeArgs;
    return nullptr;
}

// Como en C#: el cuerpo de expresión de una lambda sin valor de retorno debe ser una instrucción.
bool statementLike(Expr* e) {
    switch (e->kind) {
        case EK::Call: case EK::Assign: case EK::Postfix: case EK::New: return true;
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            return u->op == "++" || u->op == "--";
        }
        default: return false;
    }
}

bool isBuiltinDelegateRef(TypeRef* p, bool& func) {
    if (p->ptrDepth || p->isFuncPtr || p->parts.size() != 1) return false;
    func = p->parts[0] == "Func";
    if (func) return !p->typeArgs.empty();
    return p->parts[0] == "Action";
}

bool mentionsUnbound(TypeRef* tr, MethodDecl* tmpl, const std::map<std::string, Type*>& b) {
    if (tr->parts.size() == 1 && tr->typeArgs.empty() && !tr->isFuncPtr &&
        std::find(tmpl->typeParams.begin(), tmpl->typeParams.end(), tr->parts[0]) != tmpl->typeParams.end() &&
        !b.count(tr->parts[0]))
        return true;
    for (TypeRef* a : tr->typeArgs)
        if (mentionsUnbound(a, tmpl, b)) return true;
    return false;
}

std::string memberName(Expr* e) {
    if (e->kind == EK::Name) return static_cast<NameExpr*>(e)->name;
    if (e->kind == EK::Member) return static_cast<MemberExpr*>(e)->name;
    return "?";
}

}  // namespace

// ================================================================== tipos delegado

void Sema::registerDelegates() {
    for (MethodDecl* d : prog_.delegates) {
        if (d->owner->isTemplate()) {
            diag.error(d->loc, "no se puede declarar un delegado dentro de una clase genérica; declaralo en el namespace");
            continue;
        }
        NamespaceSym* ns = getNs(d->owner->ns, true);
        if (ns->types.count(d->name) || ns->delegates.count(d->name)) {
            diag.error(d->loc, "el tipo '" + d->name + "' ya está definido en '" + ns->display() + "'");
            continue;
        }
        ns->delegates[d->name] = d;
    }
}

// Firma de un delegado declarado con sus argumentos de tipo: Predicate<int> -> Func<int, bool>.
Type* Sema::delegateFromDecl(MethodDecl* d, TypeRef* tr) {
    if (tr->typeArgs.size() != d->typeParams.size()) {
        if (d->typeParams.empty()) diag.error(tr->loc, "'" + d->name + "' no es un tipo genérico");
        else
            diag.error(tr->loc, "el delegado genérico '" + d->name + "' requiere " + std::to_string(d->typeParams.size()) +
                                    " argumento(s) de tipo");
        return tc_.error();
    }
    std::vector<Type*> args;
    for (TypeRef* a : tr->typeArgs) {
        Type* t = resolveType(a);
        if (t->isError()) return t;
        args.push_back(t);
    }
    if (ideMode && !tr->parts.empty()) {
        int len = 0;
        for (size_t i = 0; i < tr->parts.size(); i++) len += (int)tr->parts[i].size() + (i ? 1 : 0);
        addRef(tr->loc, len, "delegate " + methodSignature(d), &d->loc);
    }
    static std::set<MethodDecl*> resolving;  // delegate void D(D d): recursión
    if (resolving.count(d)) {
        diag.error(d->loc, "el delegado '" + d->name + "' no puede usarse a sí mismo en su firma");
        return tc_.error();
    }
    resolving.insert(d);
    Type* result = nullptr;
    {
        CtxSave save(*this);
        auto* fake = new MethodDecl();
        fake->owner = d->owner;
        fake->file = d->file;
        fake->mods.isStatic = true;
        fake->unsafeBody = d->mods.isMemoryUnsafe || d->owner->unsafeCtx || (d->file && d->file->unsafeCtx);
        for (size_t i = 0; i < args.size(); i++) fake->typeArgMap[d->typeParams[i]] = args[i];
        enter(d->owner, fake);
        int before = diag.errorCount;
        Type* ret = resolveType(d->retRef, true);
        std::vector<Type*> ps;
        for (Param& p : d->params) ps.push_back(resolveType(p.tref));
        result = diag.errorCount == before ? tc_.delegateType(ps, ret) : tc_.error();
    }
    resolving.erase(d);
    return result;
}

// Func<A..., R> y Action<A...> (si no hay un tipo del usuario con ese nombre).
Type* Sema::builtinDelegateType(TypeRef* tr) {
    bool func = false;
    if (!isBuiltinDelegateRef(tr, func)) {
        if (tr->parts.size() == 1 && tr->parts[0] == "Func" && tr->typeArgs.empty() && !tr->isFuncPtr) {
            diag.error(tr->loc, "'Func' requiere al menos un argumento de tipo (el de retorno): Func<int>, Func<int, bool>...");
            return tc_.error();
        }
        return nullptr;
    }
    size_t np = func ? tr->typeArgs.size() - 1 : tr->typeArgs.size();
    std::vector<Type*> ps;
    for (size_t i = 0; i < np; i++) {
        Type* t = resolveType(tr->typeArgs[i]);
        if (t->isError()) return t;
        ps.push_back(t);
    }
    Type* ret = tc_.get(TK::Void);
    if (func) {
        ret = resolveType(tr->typeArgs.back(), true);
        if (ret->isError()) return ret;
        if (ret->isVoid()) {
            diag.error(tr->loc, "'Func' no puede devolver 'void'; usa 'Action<...>'");
            return tc_.error();
        }
    }
    return tc_.delegateType(ps, ret);
}

// ================================================================== eventos

void Sema::checkEventField(FieldDecl* f) {
    if (f->type && !f->type->isDelegate() && !f->type->isError())
        diag.error(f->loc, "el tipo de un evento debe ser un delegado (Action<...>, Func<...> o un delegado declarado), no '" +
                               f->type->str() + "'");
}

// Fuera de la clase que lo declara, un evento solo puede aparecer a la izquierda de += o -=.
bool Sema::eventAccessible(FieldDecl* f, Expr* e) {
    if (e == eventLhs_) return true;
    ClassDecl* owner = f->owner;
    ClassDecl* cur = ctx_.cls;
    if (cur == owner) return true;
    if (owner->templateOf && cur && cur->templateOf == owner->templateOf) return true;
    diag.error(e->loc, "el evento '" + owner->displayName + "." + f->name + "' solo se puede invocar o asignar dentro de '" +
                           owner->displayName + "'; desde fuera usa '+=' o '-='");
    return false;
}

// ================================================================== capturas

void Sema::noteLocalUse(VarInfo* v, SourceLoc loc) {
    if (v->fnDepth >= (int)lambdaStack_.size()) return;
    if (v->isRef) {
        diag.error(loc, "no se puede usar la referencia '" + v->name +
                            "' dentro de una lambda (las variables y parámetros 'ref' no se pueden capturar)");
        return;
    }
    v->captured = true;
    for (size_t k = (size_t)v->fnDepth; k < lambdaStack_.size(); k++) {
        auto& c = lambdaStack_[k]->captures;
        if (std::find(c.begin(), c.end(), v) == c.end()) c.push_back(v);
    }
}

void Sema::noteThisUse(SourceLoc loc) {
    if (lambdaStack_.empty()) return;
    if (ctx_.cls && ctx_.cls->kind == ClassKind::Struct) {
        diag.error(loc, "una lambda no puede usar 'this' (ni campos o métodos de instancia) dentro de un struct; "
                        "copia lo que necesites a una variable local");
        return;
    }
    for (LambdaExpr* l : lambdaStack_) l->usesThis = true;
}

// ================================================================== lambdas

Type* Sema::checkLambdaExpr(Expr* e) {
    if (e->kind == EK::DelegateConv) return e->type;
    auto* l = static_cast<LambdaExpr*>(e);
    if (l->bound) return l->type ? l->type : tc_.pendingLambda();
    l->paramTypes.assign(l->params.size(), nullptr);
    for (size_t i = 0; i < l->params.size(); i++) {
        if (!l->params[i].tref) continue;
        Type* t = resolveType(l->params[i].tref);
        if (t->isError()) return t;
        l->paramTypes[i] = t;
    }
    return tc_.pendingLambda();
}

// 'return' dentro del cuerpo de una lambda (no del método que la contiene).
bool Sema::lambdaReturn(ReturnStmt* rs) {
    if (lambdaStack_.empty()) return false;
    LambdaExpr* l = lambdaStack_.back();
    if (ctx_.method != l->fn) return false;
    if (l->fn && iterReturn(rs, l->fn->async)) return true;  // iterador: 'yield break' (Iterators.cpp)
    l->returns.push_back(rs);
    if (!l->ret) {  // infiriendo el tipo de retorno
        if (rs->value) checkOperand(rs->value);
        return true;
    }
    Type* lret = l->ret;
    if (l->fn && l->fn->async) {  // lambda async: devuelve el T de Task<T> (Async.cpp)
        lret = l->fn->async->result ? l->fn->async->result : tc_.error();
        if (lret->isVoid() && rs->value && rs->fromExprBody) {  // async () => expr con Task o void
            Type* t = checkOperand(rs->value);
            if (!t->isVoid() && !t->isError() && !statementLike(rs->value) && rs->value->kind != EK::Await)
                diag.error(rs->value->loc, "el cuerpo de una lambda async sin resultado debe ser una llamada, una "
                                           "asignación, 'new' o un 'await'");
            return true;
        }
    }
    if (lret->isError()) {
        if (rs->value) checkOperand(rs->value);
        return true;
    }
    if (lret->isVoid()) {
        if (rs->value) {
            checkOperand(rs->value);
            diag.error(rs->loc, "esta lambda corresponde a un delegado sin valor de retorno ('void') y no puede devolver un valor");
        }
    } else if (!rs->value) {
        diag.error(rs->loc, "la lambda debe devolver un valor de tipo '" + lret->str() + "'");
    } else {
        checkOperand(rs->value);
        int c = convCost(rs->value, lret);
        if (c > l->retCost) l->retCost = c;
        coerce(rs->value, lret);
    }
    return true;
}

// Comprueba el cuerpo con esos tipos de parámetros; 'ret' nulo = inferir el tipo de retorno.
bool Sema::bindLambda(LambdaExpr* l, const std::vector<Type*>& params, Type* ret) {
    CtxSave save(*this);
    auto* fn = new MethodDecl();
    fn->name = "<lambda>";
    fn->loc = l->loc;
    fn->owner = ctx_.cls;
    fn->file = ctx_.file;
    fn->mods.isStatic = ctx_.isStatic;
    fn->unsafeBody = unsafeCtx();
    if (ctx_.method) fn->typeArgMap = ctx_.method->typeArgMap;
    fn->ret = ret;
    fn->checked = true;
    l->fn = fn;
    l->ret = ret;
    l->retCost = 0;
    l->paramTypes = params;
    l->ownerClass = ctx_.cls;
    l->returns.clear();
    l->captures.clear();
    l->usesThis = false;
    l->depth = (int)lambdaStack_.size() + 1;
    lambdaStack_.push_back(l);
    ctx_.method = fn;
    ctx_.loopDepth = 0;
    ctx_.switchDepth = 0;
    ctx_.scopes.emplace_back();
    ctx_.async = nullptr;  // una lambda dentro de un método async tiene su propio contexto
    fn->async = nullptr;
    if (l->blockBody && iterHasYield(l->blockBody)) ctx_.async = iterBegin(fn, ret, l, l->isAsync, l->loc);  // Iterators.cpp
    else if (l->isAsync) ctx_.async = asyncBegin(fn, ret, l, l->loc);  // máquina de estados (Async.cpp)
    for (size_t i = 0; i < l->params.size(); i++) {
        auto& p = l->params[i];
        p.var = declareLocal(p.name, params[i], p.loc, "p_");
        if (ideMode) addRef(p.loc, (int)p.name.size(), "(parámetro) " + params[i]->str() + " " + p.name, &p.loc);
    }
    if (l->exprBody) {
        Type* t = checkOperand(l->exprBody);
        if (ret && ret->isVoid()) {
            if (!t->isError() && !statementLike(l->exprBody))
                diag.error(l->exprBody->loc, "el cuerpo de una lambda sin valor de retorno debe ser una llamada, una "
                                             "asignación, un incremento o 'new' (el delegado es '" +
                                                 tc_.delegateType(params, ret)->str() + "')");
        } else if (ret) {
            if (t->isVoid()) {
                diag.error(l->exprBody->loc, "la lambda debe devolver un valor de tipo '" + ret->str() + "'");
            } else {
                l->retCost = convCost(l->exprBody, ret);
                coerce(l->exprBody, ret);
            }
        }
    } else {
        lowerDefers(l->blockBody->stmts);  // Flow.cpp
        for (Stmt* s : l->blockBody->stmts) checkStmt(s);
        Type* mustReturn = ret;
        if (fn->async) {
            asyncEnd(fn->async, l->blockBody);
            mustReturn = fn->async->result;
        }
        if (mustReturn && !mustReturn->isVoid() && !mustReturn->isError() && !alwaysReturns(l->blockBody))
            diag.error(l->loc, "no todas las rutas de código de la lambda devuelven un valor");
    }
    lambdaStack_.pop_back();
    l->bound = true;
    return true;
}

// Copia de prueba de 'l' comprobada con esos tipos (y retorno conocido o inferido).
LambdaExpr* Sema::lambdaTrial(LambdaExpr* l, const std::vector<Type*>& params, Type* ret) {
    std::string key = typesKey(params, ret);
    auto it = l->trials.find(key);
    if (it != l->trials.end()) return it->second;
    LambdaExpr* c = Parser::reparseLambda(l, prog_);
    if (!c) return nullptr;
    c->trial = true;
    auto savedUnsafe = unsafeReported_;
    trialDepth_++;
    {
        DiagMute mute;
        checkLambdaExpr(c);
        bindLambda(c, params, ret);
        c->trialErrors = mute.count();
    }
    trialDepth_--;
    unsafeReported_ = savedUnsafe;
    l->trials[key] = c;
    return c;
}

// Tipo de retorno inferido de una copia comprobada sin retorno conocido (nullptr si no se puede).
Type* Sema::lambdaReturnType(LambdaExpr* t) {
    if (t->blockBody && iterHasYield(t->blockBody)) return nullptr;  // iterador: el tipo debe ser conocido
    if (t->isAsync) return asyncLambdaReturnType(t);  // Task / Task<T> (Async.cpp)
    if (t->exprBody) {
        Type* bt = t->exprBody->type;
        if (!bt || bt->isPending() || bt->is(TK::Null)) return nullptr;
        return bt;
    }
    Type* r = nullptr;
    bool anyValue = false;
    for (ReturnStmt* rs : t->returns) {
        if (!rs->value) continue;
        anyValue = true;
        Type* vt = rs->value->type;
        if (!vt || vt->isError() || vt->isPending() || vt->is(TK::Null)) continue;
        if (!r) r = vt;
        else if (r != vt) {
            if (canImplicit(nullptr, r, vt)) r = vt;  // int y double -> double
        }
    }
    if (!anyValue) return tc_.get(TK::Void);
    return r;
}

int Sema::lambdaCost(LambdaExpr* l, Type* d) {
    if (!d->isDelegate() || l->params.size() != d->params.size()) return -1;
    for (size_t i = 0; i < l->params.size(); i++)
        if (i < l->paramTypes.size() && l->paramTypes[i] && l->paramTypes[i] != d->params[i]) return -1;
    LambdaExpr* t = lambdaTrial(l, d->params, d->ret);
    if (!t || t->trialErrors) return -1;
    // Una lambda async prefiere un delegado que devuelva la tarea (Func<Task>) a uno void (Action).
    if (l->isAsync && d->ret->isVoid()) return 2 + t->retCost;
    // () => Llamada() con valor encaja con Action (se descarta) y con Func<T>: mejor Func<T> (como en C#).
    if (!l->isAsync && d->ret->isVoid() && t->exprBody && t->exprBody->type && !t->exprBody->type->isVoid() &&
        !t->exprBody->type->isError())
        return 2 + t->retCost;
    // () => { throw ...; } encaja con cualquier retorno: se prefiere el delegado sin valor (Action).
    if (!l->isAsync && !d->ret->isVoid() && t->blockBody) {
        bool value = false;
        for (ReturnStmt* rs : t->returns) value |= rs->value != nullptr;
        if (!value) return 2 + t->retCost;
    }
    return 1 + t->retCost;
}

// ================================================================== grupos de métodos

MethodDecl* Sema::groupMatch(Expr* e, Type* d, bool report) {
    std::vector<TypeRef*> none;
    std::vector<TypeRef*>* ta = typeArgsOf(e);
    std::vector<MethodDecl*> found;
    for (MethodDecl* m0 : e->group) {
        if (m0->kind != MethodKind::Normal) continue;
        MethodDecl* m = m0;
        if (m0->isTemplate()) {
            std::vector<Expr*> fake;
            for (Type* p : d->params) {
                auto* x = new NullExpr(e->loc);
                x->type = p;
                fake.push_back(x);
            }
            std::vector<Type*> args;
            if (!inferTypeArgs(m0, fake, ta ? *ta : none, args)) continue;
            m = instantiateMethod(m0, args, e->loc);
            if (!m) continue;
        } else if (ta && !ta->empty()) {
            continue;
        }
        if (m->params.size() != d->params.size() || m->variadic || m->retIsRef() || m->isExtension()) continue;
        bool ok = true;
        for (size_t i = 0; i < m->params.size() && ok; i++)
            ok = !m->params[i].isRef() && m->params[i].type == d->params[i];
        if (!ok || (!d->ret->isVoid() && m->ret != d->ret)) continue;
        if (std::find(found.begin(), found.end(), m) == found.end()) found.push_back(m);
    }
    if (found.size() == 1) return found[0];
    if (report)
        diag.error(e->loc, found.empty() ? "ninguna sobrecarga de '" + memberName(e) + "' coincide con el delegado '" +
                                               d->str() + "'"
                                         : "la conversión de '" + memberName(e) + "' al delegado '" + d->str() +
                                               "' es ambigua");
    return nullptr;
}

int Sema::groupCost(Expr* e, Type* d) {
    if (!d->isDelegate()) return -1;
    if (e->kind == EK::Member && static_cast<MemberExpr*>(e)->extension) return -1;
    return groupMatch(e, d, false) ? 1 : -1;
}

int Sema::pendingCost(Expr* e, Type* to) {
    if (e->type == tc_.pendingCase()) return unionPendingCost(e, to);  // Unions.cpp
    if (e->kind == EK::Collection) return collectionCost(static_cast<CollectionExpr*>(e), to);  // Arrays.cpp
    if (e->kind == EK::Lambda) return lambdaCost(static_cast<LambdaExpr*>(e), to);
    if (e->vk == ValKind::MethodGroup) return groupCost(e, to);
    return -1;
}

// Convierte una lambda o un grupo de métodos al delegado 'to' (comprobación definitiva).
void Sema::convertPending(Expr*& e, Type* to) {
    if (unionConvertPending(e, to)) return;  // caso de unión sin tipo: Option.None (Unions.cpp)
    if (e->kind == EK::Collection) return convertCollection(e, to);  // [1, 2, 3] (Arrays.cpp)
    if (e->kind == EK::Lambda) {
        auto* l = static_cast<LambdaExpr*>(e);
        auto ideFallback = [&]() {  // IntelliSense dentro de una lambda sin delegado válido
            if (!ideMode || l->bound) return;
            std::vector<Type*> errs(l->params.size(), tc_.error());
            for (size_t i = 0; i < l->params.size(); i++)
                if (i < l->paramTypes.size() && l->paramTypes[i]) errs[i] = l->paramTypes[i];
            bindLambda(l, errs, tc_.error());
        };
        if (!to->isDelegate()) {
            diag.error(e->loc, "no se puede convertir una expresión lambda en '" + to->str() + "' (no es un tipo delegado)");
            ideFallback();
            return;
        }
        if (l->bound) {
            if (l->type != to)
                diag.error(e->loc, "la lambda ya se convirtió en '" + (l->type ? l->type->str() : "?") + "'");
            return;
        }
        if (l->params.size() != to->params.size()) {
            diag.error(l->loc, "la lambda tiene " + std::to_string(l->params.size()) + " parámetro(s) pero el delegado '" +
                                   to->str() + "' espera " + std::to_string(to->params.size()));
            ideFallback();
            return;
        }
        for (size_t i = 0; i < l->params.size(); i++)
            if (i < l->paramTypes.size() && l->paramTypes[i] && l->paramTypes[i] != to->params[i]) {
                diag.error(l->params[i].loc, "el parámetro '" + l->params[i].name + "' de la lambda es de tipo '" +
                                                 l->paramTypes[i]->str() + "' pero el delegado '" + to->str() + "' espera '" +
                                                 to->params[i]->str() + "'");
                ideFallback();
                return;
            }
        bindLambda(l, to->params, to->ret);
        l->type = to;
        if (trialDepth_ == 0) {
            l->id = (int)lambdas.size();
            lambdas.push_back(l);
        }
        return;
    }

    // Grupo de métodos -> delegado: Func<int, int> f = Doble;  obj.Metodo
    if (!to->isDelegate()) {
        diag.error(e->loc, "un grupo de métodos no es válido en este contexto (¿faltan paréntesis de llamada?)");
        return;
    }
    if (e->kind == EK::Member && static_cast<MemberExpr*>(e)->extension) {
        diag.error(e->loc, "un método de extensión no se puede convertir en delegado; usa una lambda (x => obj.Metodo(x))");
        return;
    }
    MethodDecl* m = groupMatch(e, to, true);
    if (!m) return;
    auto* dc = new DelegateConvExpr(e->loc);
    dc->type = to;
    dc->target = m;
    if (!m->isStatic()) {
        if (e->kind == EK::Name) {
            if (ctx_.isStatic) {
                diag.error(e->loc, "se requiere una referencia de objeto para el método no estático '" +
                                       m->owner->displayName + "." + m->name + "'");
                return;
            }
            dc->implicitThis = true;
            noteThisUse(e->loc);
        } else {
            auto* me = static_cast<MemberExpr*>(e);
            if (me->obj->vk != ValKind::Value) {
                diag.error(e->loc, "se requiere una referencia de objeto para el método no estático '" +
                                       m->owner->displayName + "." + m->name + "'");
                return;
            }
            dc->receiver = me->obj;
            dc->receiverArrow = me->arrow;
        }
    } else if (e->kind == EK::Member && static_cast<MemberExpr*>(e)->obj->vk == ValKind::Value) {
        diag.error(e->loc, "el método estático '" + m->owner->displayName + "." + m->name +
                               "' no se puede usar con una referencia de instancia; califícalo con el nombre del tipo");
        return;
    }
    checkAccess(m->mods.access, m->owner, m->name, e->loc);
    requireSafeCall(m, e->loc);
    useMethod(m, &e->loc);
    if (ideMode) {
        SourceLoc at = e->kind == EK::Member ? static_cast<MemberExpr*>(e)->nameLoc : e->loc;
        addRef(at, (int)m->name.size(), methodSignature(m), &m->loc);
    }
    auto key = std::make_pair(m, to);
    auto it = thunkIndex_.find(key);
    if (it == thunkIndex_.end()) {
        it = thunkIndex_.emplace(key, (int)thunks.size()).first;
        thunks.push_back({m, to, !m->isStatic()});
    }
    dc->thunk = it->second;
    e = dc;
}

// 'var f = ...' con una lambda de parámetros tipados o un grupo con un solo método.
Type* Sema::naturalType(Expr*& e) {
    if (unionNaturalType(e)) return tc_.error();  // var x = None; (Unions.cpp)
    if (e->kind == EK::Collection) return collectionNaturalType(e);  // Arrays.cpp
    if (e->kind == EK::Lambda) {
        auto* l = static_cast<LambdaExpr*>(e);
        for (Type* t : l->paramTypes)
            if (!t) {
                diag.error(l->loc, "no se puede inferir el tipo de la lambda: indica el tipo de sus parámetros "
                                   "((int x) => ...) o declara la variable con un tipo delegado (Func<int, int> f = x => ...)");
                return tc_.error();
            }
        LambdaExpr* t = lambdaTrial(l, l->paramTypes, nullptr);
        Type* r = t && !t->trialErrors ? lambdaReturnType(t) : nullptr;
        if (!r || r->isError()) {
            if (!t || t->trialErrors) {
                bindLambda(l, l->paramTypes, nullptr);  // muestra los errores del cuerpo
            } else {
                diag.error(l->loc, "no se puede inferir el tipo de retorno de la lambda; declara la variable con un tipo "
                                   "delegado (Func<...> o Action<...>)");
            }
            return tc_.error();
        }
        Type* d = tc_.delegateType(l->paramTypes, r);
        coerce(e, d);
        return d;
    }
    std::vector<MethodDecl*> plain;
    for (MethodDecl* m : e->group)
        if (m->kind == MethodKind::Normal && !m->isTemplate()) plain.push_back(m);
    if (plain.size() == 1 && e->group.size() == 1) {
        MethodDecl* m = plain[0];
        bool ok = !m->variadic && !m->retIsRef();
        std::vector<Type*> ps;
        for (Param& p : m->params) {
            ok &= !p.isRef() && p.type && !p.type->isError();
            ps.push_back(p.type);
        }
        if (ok && m->ret) {
            Type* d = tc_.delegateType(ps, m->ret);
            coerce(e, d);
            return d;
        }
    }
    diag.error(e->loc, "no se puede inferir el tipo del grupo de métodos '" + memberName(e) +
                           "'; declara la variable con un tipo delegado (Func<...> o Action<...>)");
    return tc_.error();
}

// ================================================================== inferencia de tipos genéricos

bool Sema::unifyDelegate(TypeRef* p, Type* a, MethodDecl* tmpl, std::map<std::string, Type*>& b) {
    bool func = false;
    if (isBuiltinDelegateRef(p, func)) {
        size_t np = func ? p->typeArgs.size() - 1 : p->typeArgs.size();
        if (np != a->params.size() || (!func && !a->ret->isVoid())) return true;
        for (size_t i = 0; i < np; i++) unify(p->typeArgs[i], a->params[i], tmpl, b);
        if (func) unify(p->typeArgs.back(), a->ret, tmpl, b);
        return true;
    }
    if (p->parts.size() == 1 && p->typeArgs.empty() &&
        std::find(tmpl->typeParams.begin(), tmpl->typeParams.end(), p->parts[0]) != tmpl->typeParams.end() &&
        !b.count(p->parts[0]))
        b[p->parts[0]] = a;
    return true;
}

// Segunda fase de la inferencia: con los argumentos de tipo ya conocidos (p. ej. T del receptor),
// se comprueban las lambdas y grupos de métodos para deducir los que aparecen en el retorno.
//   lista.Select(x => x.Nombre)        -> U = string
//   lista.Aggregate(0, (acc, x) => acc + x)  -> A = int (de la semilla), luego la lambda
void Sema::inferFromLambdas(MethodDecl* tmpl, const std::vector<Expr*>& args, std::map<std::string, Type*>& b) {
    size_t n = std::min(tmpl->params.size(), args.size());
    auto resolveIn = [&](TypeRef* tr) { return resolveInTemplate(tmpl, tr, b); };
    bool progress = true;
    for (int round = 0; progress && round < 8; round++) {
        progress = false;
        for (size_t i = 0; i < n; i++) {
            Expr* a = args[i];
            if (!a->type || !a->type->isPending()) continue;
            TypeRef* p = tmpl->params[i].tref;
            bool func = false;
            if (!isBuiltinDelegateRef(p, func)) continue;
            size_t np = func ? p->typeArgs.size() - 1 : p->typeArgs.size();
            LambdaExpr* l = a->kind == EK::Lambda ? static_cast<LambdaExpr*>(a) : nullptr;
            if (l && l->params.size() != np) continue;
            if (l) {  // parámetros con tipo explícito: (int x) => ...
                for (size_t k = 0; k < np && k < l->paramTypes.size(); k++)
                    if (l->paramTypes[k]) {
                        size_t before = b.size();
                        unify(p->typeArgs[k], l->paramTypes[k], tmpl, b);
                        progress |= b.size() > before;
                    }
            }
            if (!func || !mentionsUnbound(p->typeArgs.back(), tmpl, b)) continue;
            std::vector<Type*> ps;
            bool ok = true;
            for (size_t k = 0; k < np && ok; k++) {
                if (mentionsUnbound(p->typeArgs[k], tmpl, b)) {
                    ok = false;
                    break;
                }
                Type* t = resolveIn(p->typeArgs[k]);
                if (!t) ok = false;
                else ps.push_back(t);
            }
            if (!ok) continue;
            Type* r = nullptr;
            if (l) {
                LambdaExpr* t = lambdaTrial(l, ps, nullptr);
                if (t && !t->trialErrors) r = lambdaReturnType(t);
                if (t && !t->trialErrors && !r) {  // x => Ok(x * 2): de los argumentos del caso (Unions.cpp)
                    size_t before = b.size();
                    if (t->exprBody) unionInferReturn(t->exprBody, p->typeArgs.back(), tmpl, b);
                    for (ReturnStmt* rs : t->returns)
                        if (rs->value) unionInferReturn(rs->value, p->typeArgs.back(), tmpl, b);
                    if (b.size() > before) {
                        progress = true;
                        continue;
                    }
                }
            } else if (a->vk == ValKind::MethodGroup) {
                MethodDecl* only = nullptr;
                int count = 0;
                for (MethodDecl* m : a->group) {
                    if (m->kind != MethodKind::Normal || m->isTemplate() || m->params.size() != ps.size()) continue;
                    bool same = true;
                    for (size_t k = 0; k < ps.size(); k++) same &= m->params[k].type == ps[k];
                    if (same) only = m, count++;
                }
                if (count == 1) r = only->ret;
            }
            if (!r || r->isError() || r->isPending() || r->isVoid() || r->is(TK::Null)) continue;
            size_t before = b.size();
            unify(p->typeArgs.back(), r, tmpl, b);
            progress |= b.size() > before;
        }
    }
}

// Un tipo de la firma de una plantilla con argumentos de tipo parciales (nullptr si falla).
Type* Sema::resolveInTemplate(MethodDecl* tmpl, TypeRef* tr, const std::map<std::string, Type*>& b) {
    CtxSave save(*this);
    auto* fake = new MethodDecl();
    fake->owner = tmpl->owner;
    fake->file = tmpl->file;
    fake->mods.isStatic = true;
    fake->unsafeBody = true;
    fake->typeArgMap = b;
    enter(tmpl->owner, fake);
    DiagMute mute;
    Type* t = resolveType(tr, true);
    return mute.count() ? nullptr : t;
}

// Ninguna sobrecarga aceptó los argumentos: si una lambda solo encaja (por número de parámetros)
// con un delegado posible, se comprueba de verdad para mostrar el error de su cuerpo.
void Sema::explainPendingArgs(const std::vector<MethodDecl*>& group, std::vector<Expr*>& args) {
    for (size_t i = 0; i < args.size(); i++) {
        if (args[i]->kind != EK::Lambda) continue;
        auto* l = static_cast<LambdaExpr*>(args[i]);
        if (l->bound) continue;
        std::vector<std::vector<Type*>> targets;
        std::vector<Type*> rets;
        for (MethodDecl* m : group) {
            if (m->params.size() != args.size() || m->variadic) continue;
            std::vector<Type*> ps;
            Type* ret = nullptr;
            if (!m->isTemplate()) {
                Type* p = m->params[i].type;
                if (!p || !p->isDelegate() || p->params.size() != l->params.size()) continue;
                ps = p->params;
                ret = p->ret;
            } else {
                bool func = false;
                TypeRef* pr = m->params[i].tref;
                if (!isBuiltinDelegateRef(pr, func)) continue;
                size_t np = func ? pr->typeArgs.size() - 1 : pr->typeArgs.size();
                if (np != l->params.size()) continue;
                std::map<std::string, Type*> b;
                for (size_t k = 0; k < args.size(); k++)
                    if (k != i) unify(m->params[k].tref, args[k]->type, m, b);
                bool ok = true;
                for (size_t k = 0; k < np && ok; k++) {
                    Type* t = mentionsUnbound(pr->typeArgs[k], m, b) ? nullptr : resolveInTemplate(m, pr->typeArgs[k], b);
                    if (!t) ok = false;
                    else ps.push_back(t);
                }
                if (!ok) continue;
                if (!func) ret = tc_.get(TK::Void);
                else if (!mentionsUnbound(pr->typeArgs.back(), m, b)) ret = resolveInTemplate(m, pr->typeArgs.back(), b);
            }
            bool seen = false;
            for (auto& t : targets) seen |= t == ps;
            if (!seen) {
                targets.push_back(ps);
                rets.push_back(ret);
            }
        }
        if (targets.size() != 1) continue;
        if (rets[0]) coerce(args[i], tc_.delegateType(targets[0], rets[0]));
        else bindLambda(l, targets[0], nullptr);  // retorno desconocido: al menos los errores del cuerpo
    }
}

// ================================================================== llamadas, asignaciones y miembros

Type* Sema::checkOperand(Expr* e) {
    check(e);
    if (e->vk == ValKind::MethodGroup && !e->group.empty()) {
        e->type = tc_.pendingGroup();
        return e->type;
    }
    return requireValue(e);
}

Type* Sema::checkDelegateCall(CallExpr* e) {
    Type* d = e->callee->type;
    if (e->args.size() != d->params.size()) {
        diag.error(e->loc, "el delegado '" + d->str() + "' espera " + std::to_string(d->params.size()) +
                               " argumento(s), no " + std::to_string(e->args.size()));
        return tc_.error();
    }
    for (size_t i = 0; i < e->args.size(); i++) coerce(e->args[i], d->params[i]);
    return d->ret;
}

// d += f  /  d -= f  (combinar y quitar de la lista de invocación)
bool Sema::delegateAssign(AssignExpr* e, Type* L) {
    if (e->op != "+=" && e->op != "-=") return false;
    coerce(e->rhs, L);
    return true;
}

bool Sema::hasCallableNamed(ClassDecl* c, const std::string& name) {
    for (MethodDecl* m : c->methods)
        if (m->kind == MethodKind::Normal && m->name == name) return true;
    return false;
}
