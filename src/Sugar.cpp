// Faset - análisis semántico del azúcar sintáctico.
//
// La mayoría de las construcciones se reescriben (campo 'lowered') en código que el resto del
// compilador ya sabe comprobar y emitir. El patrón general: las subexpresiones que ya se
// comprobaron se guardan en variables temporales ocultas (nombres "<hN>", que no se pueden
// escribir en el código) y la forma reescrita se construye SIN comprobar sobre esos nombres, para
// después comprobarla con las reglas normales (conversiones, sobrecargas, comparación de cadenas...).
//
//   foreach (T x in c) cuerpo   ->  { var <c> = c; var <e> = <c>.GetEnumerator();
//                                     while (<e>.MoveNext()) { T x = <e>.Current; cuerpo } }
//   a ?? b                      ->  (<a> = a, <a> != null ? <a> : b)
//   x switch { p => v, ... }    ->  (<s> = x, prueba(p) ? v : ... : panic)
//   switch (s) { case p when g: ... }  ->  { var <s> = s; switch (0) { default: if (...) ... } }
//   (a, b) = (b, a)             ->  (<t> = (b, a), a = <t>.Item1, b = <t>.Item2)
#include <algorithm>

#include "Arrays.h"
#include "Sema.h"

namespace {

NameExpr* refTo(VarInfo* v, SourceLoc loc) {
    auto* n = new NameExpr(loc);
    n->name = v->name;
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

Expr* mkBin(const std::string& op, Expr* l, Expr* r, SourceLoc loc) {
    auto* b = new BinaryExpr(loc);
    b->op = op;
    b->lhs = l;
    b->rhs = r;
    return b;
}

Expr* mkNot(Expr* e, SourceLoc loc) {
    auto* u = new UnaryExpr(loc);
    u->op = "!";
    u->operand = e;
    return u;
}

Expr* mkBool(bool v, SourceLoc loc) {
    auto* b = new BoolLitExpr(loc);
    b->value = v;
    return b;
}

TypeRef* mkVarRef(SourceLoc loc) {
    auto* t = new TypeRef();
    t->loc = loc;
    t->parts = {"var"};
    return t;
}

std::string itemName(size_t i) { return "Item" + std::to_string(i + 1); }

// Elemento T de una List<T> (representación de 'params').
Type* listElem(Type* t) {
    if (!t || !t->isClass() || !t->decl->templateOf || t->decl->templateOf->name != "List" ||
        t->decl->typeArgs.size() != 1)
        return nullptr;
    return t->decl->typeArgs[0];
}

bool isIrrefutable(Pattern* p) { return p->kind == PK::Discard || (p->kind == PK::Var); }

// Formatos de número: estándar (D4, X8, F2, N0, E3, P1, G) o personalizados ("0.00", "#,##0").
bool validFormat(const std::string& f, Type* t) {
    if (f.empty()) return true;
    char c = (char)toupper((unsigned char)f[0]);
    bool std = std::string("DXFNEPG").find(c) != std::string::npos;
    if (std && f.size() <= 3) {
        bool digits = true;
        for (size_t i = 1; i < f.size(); i++) digits &= isdigit((unsigned char)f[i]) != 0;
        if (digits) return t->isIntegral() || t->isEnum() || (c != 'D' && c != 'X');
    }
    bool any = false;
    for (char ch : f) {
        if (ch == '0' || ch == '#') any = true;
        else if (ch != '.' && ch != ',' && ch != '%') return false;
    }
    return any;
}

}  // namespace

bool Sema::isSugarExpr(EK k) const {
    switch (k) {
        case EK::Interp: case EK::CondAccess: case EK::CondRecv: case EK::Tuple: case EK::Let: case EK::SwitchExpr:
        case EK::IsPattern: case EK::ParamsList: case EK::MatchFail: case EK::CoalesceAssign:
        case EK::Pipe: case EK::Propagate: case EK::UnionCase:  // Flow.cpp / Unions.cpp
            return true;
        default: return false;
    }
}

Type* Sema::checkSugar(Expr* e) {
    switch (e->kind) {
        case EK::Interp: return checkInterp(static_cast<InterpExpr*>(e));
        case EK::CondAccess: return checkCondAccess(static_cast<CondAccessExpr*>(e));
        case EK::CondRecv: {
            auto* r = static_cast<CondRecvExpr*>(e);
            return r->owner && r->owner->recvType ? r->owner->recvType : tc_.error();
        }
        case EK::Tuple: return checkTuple(static_cast<TupleExpr*>(e));
        case EK::SwitchExpr: return checkSwitchExpr(static_cast<SwitchExpr*>(e));
        case EK::IsPattern: return checkIsPattern(static_cast<IsPatternExpr*>(e));
        case EK::Pipe: return checkPipe(static_cast<PipeExpr*>(e));                  // Flow.cpp
        case EK::Propagate: return checkPropagate(static_cast<PropagateExpr*>(e));   // Unions.cpp
        default: return e->type ? e->type : tc_.error();  // nodos generados: ya tienen tipo
    }
}

// ================================================================== temporales ocultos

VarInfo* Sema::hiddenLocal(Type* t, SourceLoc loc, bool hoisted) {
    int n = ++hiddenCounter_;
    auto* v = new VarInfo();
    v->name = "<h" + std::to_string(n) + ">";
    v->cname = "fs_h" + std::to_string(n);
    v->type = t;
    v->loc = loc;
    v->hoisted = hoisted;
    v->fnDepth = (int)lambdaStack_.size();  // pertenece a la lambda que se comprueba (no se captura)
    if (ctx_.scopes.empty()) ctx_.scopes.emplace_back();
    ctx_.scopes.back()[v->name] = v;
    asyncNoteLocal(v);  // Async.cpp
    return v;
}

// Variable de un patrón ('var x', 'Perro p'): visible en el ámbito actual; en C se declara al
// principio de la función porque se asigna dentro de una expresión.
VarInfo* Sema::patternVar(const std::string& name, Type* t, SourceLoc loc) {
    VarInfo* v = declareLocal(name, t, loc, "l_");
    v->cname = "fs_h" + std::to_string(++hiddenCounter_) + "_" + name;
    v->hoisted = true;
    if (ideMode) addRef(loc, (int)name.size(), "(variable local) " + t->str() + " " + name, &loc);
    return v;
}

VarDeclStmt* Sema::bindDecl(VarInfo* v, Expr* checkedInit) {
    auto* d = new VarDeclStmt(v->loc);
    VarDeclStmt::Declarator dc;
    dc.loc = v->loc;
    dc.name = v->name;
    dc.init = checkedInit;
    dc.var = v;
    d->decls.push_back(dc);
    return d;
}

void Sema::checkHiddenDecl(VarDeclStmt* d) { checkStmt(d); }

// ================================================================== tipos: T? y tuplas

ClassDecl* Sema::nullableTemplate() {
    NamespaceSym* ns = getNs("std", false);
    if (!ns) return nullptr;
    auto it = ns->types.find("Nullable");
    return it != ns->types.end() && it->second->isTemplate() ? it->second : nullptr;
}

Type* Sema::nullableOf(Type* t, SourceLoc loc) {
    if (t->isError() || t->isRefLike() || nullableElem(t)) return t;  // las clases ya admiten null
    if (t->isVoid()) {
        diag.error(loc, "'void?' is not a valid type");
        return tc_.error();
    }
    ClassDecl* tm = nullableTemplate();
    if (!tm) {
        diag.error(loc, "'T?' types need std.Nullable<T> (standard library not found)");
        return tc_.error();
    }
    ClassDecl* inst = instantiate(tm, {t}, loc);
    if (!inst) return tc_.error();
    inst->displayName = t->str() + "?";  // en mensajes y hover: int? en vez de Nullable<int>
    return inst->type;
}

ClassDecl* Sema::tupleDecl(const std::vector<Type*>& elems, SourceLoc loc) {
    std::string key, disp = "(";
    for (size_t i = 0; i < elems.size(); i++) {
        key += std::to_string((uintptr_t)elems[i]) + ",";
        disp += (i ? ", " : "") + elems[i]->str();
    }
    auto it = tupleDecls_.find(key);
    if (it != tupleDecls_.end()) return it->second;
    auto* c = new ClassDecl();
    c->kind = ClassKind::Struct;
    c->isTuple = true;
    c->name = c->displayName = disp + ")";
    c->loc.file = -1;  // sin posición en el código (no aparece en los símbolos del documento)
    c->nsSym = global_;
    c->cname = "fs_tupla" + std::to_string(tupleDecls_.size() + 1);
    c->signaturesDone = true;
    c->mods.access = Access::Public;
    for (size_t i = 0; i < elems.size(); i++) {
        auto* f = new FieldDecl();
        f->loc = c->loc;
        f->name = itemName(i);
        f->type = elems[i];
        f->owner = c;
        f->cname = "f_" + f->name;
        f->mods.access = Access::Public;
        f->tref = new TypeRef();  // solo para mostrarlo
        f->tref->parts = {elems[i]->str()};
        c->fields.push_back(f);
    }
    c->type = new Type(TK::Struct);
    c->type->decl = c;
    tupleDecls_[key] = c;
    prog_.types.push_back(c);
    (void)loc;
    return c;
}

Type* Sema::tupleType(const std::vector<Type*>& elems, const std::vector<std::string>& names, SourceLoc loc) {
    for (Type* t : elems)
        if (t->isError()) return t;
    ClassDecl* c = tupleDecl(elems, loc);
    bool any = false;
    std::set<std::string> seen;
    for (const std::string& n : names) {
        if (n.empty()) continue;
        any = true;
        if (!seen.insert(n).second) {
            diag.error(loc, "element name '" + n + "' is repeated in the tuple");
            return c->type;
        }
    }
    if (!any) return c->type;
    std::vector<std::string> key = names;
    key.resize(elems.size());
    auto it = tupleNamed_.find({c, key});
    if (it != tupleNamed_.end()) return it->second;
    auto* t = new Type(TK::Struct);
    t->decl = c;
    t->tupleNames = key;
    tupleNamed_[{c, key}] = t;
    return t;
}

Type* Sema::resolveSugarType(TypeRef* tr, bool allowVoid) {
    if (tr->isTuple) {
        std::vector<Type*> elems;
        for (TypeRef* a : tr->typeArgs) {
            Type* t = resolveType(a);
            if (t->isError()) return t;
            elems.push_back(t);
        }
        Type* base = tupleType(elems, tr->tupleNames, tr->loc);
        if (tr->nullable) base = nullableOf(base, tr->loc);
        if (tr->ptrDepth > 0 && !unsafeCtx()) unsafeError(tr->loc, "the pointer type '" + tr->str() + "'");
        for (int i = 0; i < tr->ptrDepth; i++) base = tc_.pointerTo(base);
        return base;
    }
    tr->nullable = false;
    Type* base = resolveType(tr, allowVoid);
    tr->nullable = true;
    return nullableOf(base, tr->loc);
}

int Sema::sugarImplicit(Expr* e, Type* from, Type* to) {
    if (int r = iterImplicit(e, from, to); r >= 0) return r;  // string -> IEnumerable<char> (Iterators.cpp)
    if (isDefaultLiteral(e)) return to->isVoid() ? 0 : 1;
    if (e && unionRetarget(e, to, false)) return 1;  // Option<long> x = Some(5) (Unions.cpp)
    if (Type* el = nullableElem(to)) {
        if (from->is(TK::Null)) return 1;
        if (nullableElem(from)) return 0;
        return canImplicit(e, from, el) ? 1 : 0;
    }
    if (isTupleType(to)) {
        if (isTupleType(from) && from->decl == to->decl) return 1;
        if (e && e->kind == EK::Tuple && !e->lowered && isTupleType(from)) {
            auto* t = static_cast<TupleExpr*>(e);
            if (t->elems.size() != to->decl->fields.size()) return 0;
            for (size_t i = 0; i < t->elems.size(); i++)
                if (!canImplicit(t->elems[i], t->elems[i]->type, to->decl->fields[i]->type)) return 0;
            return 1;
        }
        return 0;
    }
    return -1;
}

bool Sema::sugarCoerce(Expr*& e, Type* to) {
    Type* from = e->type;
    auto wrap = [&]() {
        auto* c = new CastExpr(e->loc);
        c->operand = e;
        c->implicit = true;
        c->type = to;
        e = c;
    };
    if (iterCoerce(e, to)) return true;  // string -> IEnumerable<char> (Iterators.cpp)
    if (isDefaultLiteral(e)) {
        if (to->isVoid()) return false;
        e->type = to;
        return true;
    }
    if (unionRetarget(e, to, true)) return true;  // Unions.cpp
    if (Type* el = nullableElem(to)) {
        if (from->is(TK::Null)) {
            wrap();
            return true;
        }
        if (nullableElem(from) || !canImplicit(e, from, el)) return false;  // error normal
        coerce(e, el);
        wrap();
        return true;
    }
    if (isTupleType(to) && isTupleType(from)) {
        if (e->kind == EK::Tuple && !e->lowered) {  // literal: cada elemento al tipo de destino
            auto* t = static_cast<TupleExpr*>(e);
            if (t->elems.size() != to->decl->fields.size()) return false;
            for (size_t i = 0; i < t->elems.size(); i++)
                if (!canImplicit(t->elems[i], t->elems[i]->type, to->decl->fields[i]->type)) return false;
            for (size_t i = 0; i < t->elems.size(); i++) coerce(t->elems[i], to->decl->fields[i]->type);
            e->type = to;
            return true;
        }
        if (from->decl == to->decl) {  // misma forma, otros nombres: mismo struct en C
            wrap();
            return true;
        }
    }
    return false;
}

bool Sema::sugarUnify(TypeRef* p, Type* a, MethodDecl* tmpl, std::map<std::string, Type*>& b) {
    if (p->isTuple) {
        if (isTupleType(a) && a->decl->fields.size() == p->typeArgs.size())
            for (size_t i = 0; i < p->typeArgs.size(); i++) unify(p->typeArgs[i], a->decl->fields[i]->type, tmpl, b);
        return true;
    }
    Type* inner = nullableElem(a) ? nullableElem(a) : a;  // F<T>(T? x) con int? o con int
    TypeRef copy = *p;
    copy.nullable = false;
    return unify(&copy, inner, tmpl, b);
}

Type* Sema::sugarMember(MemberExpr* e, Type* base) {
    if (!isTupleType(base) || base->tupleNames.empty()) return nullptr;
    for (size_t i = 0; i < base->tupleNames.size() && i < base->decl->fields.size(); i++) {
        if (base->tupleNames[i] != e->name) continue;
        e->ref = MemberExpr::Ref::Field;
        e->field = base->decl->fields[i];
        return e->field->type;
    }
    return nullptr;
}

// ================================================================== conversión a texto

bool Sema::toStringable(Type* t, int depth) {
    if (depth > 8) return false;
    if (t->is(TK::String) || t->isNumeric() || t->is(TK::Bool) || t->isEnum()) return true;
    if (Type* el = nullableElem(t)) return toStringable(el, depth + 1);
    if (isTupleType(t)) {
        for (FieldDecl* f : t->decl->fields)
            if (!toStringable(f->type, depth + 1)) return false;
        return true;
    }
    if (MethodDecl* m = findToString(t)) {
        useMethod(m);
        return true;
    }
    return false;
}

bool Sema::sugarConcatable(Type* t) {
    if (!t || t->isError()) return false;
    if (!isTupleType(t) && !nullableElem(t) && !findToString(t)) return false;
    return toStringable(t);
}

Type* Sema::checkInterp(InterpExpr* e) {
    for (auto& part : e->parts) {
        if (!part.expr) continue;
        Type* t = checkValue(part.expr);
        if (t->isError()) continue;
        if (t->isVoid()) {
            diag.error(part.expr->loc, "an interpolated string hole cannot be 'void'");
            continue;
        }
        if (!toStringable(t)) {
            diag.error(part.expr->loc, "cannot convert '" + t->str() + "' to string in an interpolated string" +
                                           (t->isAggregate() ? " (define 'public string ToString()' on the type)" : ""));
            continue;
        }
        part.toString = findToString(t);
        if (!part.format.empty()) {
            Type* nt = nullableElem(t) ? nullableElem(t) : t;
            if (!nt->isNumeric() && !nt->isEnum())
                diag.error(part.expr->loc, "format ':" + part.format + "' only applies to numbers (the value is '" +
                                               t->str() + "')");
            else if (!validFormat(part.format, nt))
                diag.error(part.expr->loc, "invalid numeric format ':" + part.format + "' for '" + nt->str() +
                                               "' (use D, X, F, N, E, P, G with optional digits, or '0.00', '#,##0')");
        }
    }
    return tc_.get(TK::String);
}

// ================================================================== operadores de null

Type* Sema::checkCoalesce(BinaryExpr* e, Type* L) {
    if (L->isError()) {
        checkValue(e->rhs);
        return L;
    }
    SourceLoc loc = e->loc;
    Expr* cond;
    Expr* val;
    VarInfo* a = hiddenLocal(L, loc, true);
    if (nullableElem(L)) {
        cond = mkMember(refTo(a, loc), "HasValue", loc);
        val = mkCall(mkMember(refTo(a, loc), "GetValueOrDefault", loc), {}, loc);
    } else if (L->isRefLike() && !L->is(TK::Null)) {
        cond = mkBin("!=", refTo(a, loc), new NullExpr(loc), loc);
        val = refTo(a, loc);
    } else {
        diag.error(e->lhs->loc, "the '?\?' operator needs a nullable value on the left (a class or a "
                                "T? type); '" + L->str() + "' is never null");
        checkValue(e->rhs);
        return tc_.error();
    }
    auto* c = new CondExpr(loc);
    c->cond = cond;
    c->a = val;
    c->b = e->rhs;
    Type* t = checkValue(c);
    auto* let = new LetExpr(loc);
    let->binds.push_back({a, e->lhs});
    let->seq.push_back(c);
    let->type = t;
    e->lowered = let;
    return t;
}

Type* Sema::checkCoalesceAssign(AssignExpr* e) {
    Type* L = checkValue(e->lhs);
    Type* R = checkValue(e->rhs);
    if (L->isError() || R->isError()) return tc_.error();
    if (!isLValue(e->lhs) || isConstTarget(e->lhs)) {
        diag.error(e->lhs->loc, "the left-hand side of '?\?=' must be a variable, a field or an element");
        return tc_.error();
    }
    Type* el = nullableElem(L);
    if (!el && !(L->isRefLike() && !L->is(TK::Null))) {
        diag.error(e->lhs->loc, "the '?\?=' operator needs a nullable value on the left (a class or a "
                                "T? type); '" + L->str() + "' is never null");
        return tc_.error();
    }
    coerce(e->rhs, L);
    auto* ca = new CoalesceAssignExpr(e->loc);
    ca->lhs = e->lhs;
    ca->rhs = e->rhs;
    ca->nullableLhs = el != nullptr;
    ca->type = el ? el : L;
    e->lowered = ca;
    return ca->type;
}

Type* Sema::checkCondAccess(CondAccessExpr* e) {
    Type* O = checkValue(e->obj);
    if (O->isError()) return O;
    if (Type* r = propagateCondAccess(e, O)) return r;  // r?.Campo con un Result/Option: r? (Unions.cpp)
    if (Type* el = nullableElem(O)) {
        e->objNullable = true;
        e->recvType = el;
    } else if (O->isClass() || O->isDelegate()) {  // obj?.Campo, accion?.Invoke(x)
        e->recvType = O;
    } else {
        diag.error(e->loc, "the '?.' operator needs a nullable value (a class, a delegate or a T? type); '" + O->str() +
                               "' is never null (use '.')");
        return tc_.error();
    }
    e->tmp = hiddenLocal(O, e->loc, true);
    Type* A = checkValue(e->access);
    if (A->isError() || A->isVoid()) return A;
    if (A->isRefLike() || nullableElem(A)) return A;
    return nullableOf(A, e->loc);  // obj?.Edad es int?: null si obj es null
}

// ================================================================== tuplas

Type* Sema::checkTuple(TupleExpr* e) {
    std::vector<Type*> elems;
    std::vector<std::string> names = e->names;
    std::vector<bool> inferred(e->elems.size(), false);
    bool bad = false;
    for (size_t i = 0; i < e->elems.size(); i++) {
        Type* t = checkValue(e->elems[i]);
        if (t->isError()) {
            bad = true;
        } else if (t->is(TK::Null)) {
            diag.error(e->elems[i]->loc, "cannot infer the type of 'null' in a tuple (use a cast)");
            bad = true;
        } else if (t->isVoid()) {
            diag.error(e->elems[i]->loc, "a tuple element cannot be 'void'");
            bad = true;
        }
        elems.push_back(t);
        if (names[i].empty()) {  // (nombre, edad): los nombres se toman de las variables
            Expr* x = e->elems[i];
            if (x->kind == EK::Name) names[i] = static_cast<NameExpr*>(x)->name;
            else if (x->kind == EK::Member) names[i] = static_cast<MemberExpr*>(x)->name;
            inferred[i] = !names[i].empty();
        }
    }
    if (bad) return tc_.error();
    // Los nombres deducidos que se repiten (o chocan con ItemN) se descartan.
    for (size_t i = 0; i < names.size(); i++) {
        if (!inferred[i]) continue;
        bool dup = names[i].rfind("Item", 0) == 0 || names[i] == "_";
        for (size_t j = 0; j < names.size(); j++)
            if (j != i && names[j] == names[i]) dup = true;
        if (dup) names[i].clear();
    }
    return tupleType(elems, names, e->loc);
}

Type* Sema::checkDeconstructAssign(AssignExpr* e) {
    auto* lhs = static_cast<TupleExpr*>(e->lhs);
    if (e->op != "=") {
        diag.error(e->loc, "only '=' can be used to deconstruct a tuple");
        return tc_.error();
    }
    Type* R = checkValue(e->rhs);
    if (R->isError()) return R;
    if (!isTupleType(R) || R->decl->fields.size() != lhs->elems.size()) {
        diag.error(e->loc, "cannot deconstruct a value of type '" + R->str() + "' into " +
                               std::to_string(lhs->elems.size()) + " variables");
        return tc_.error();
    }
    SourceLoc loc = e->loc;
    VarInfo* t = hiddenLocal(R, loc, true);
    auto* let = new LetExpr(loc);
    let->binds.push_back({t, e->rhs});
    for (size_t i = 0; i < lhs->elems.size(); i++) {
        Expr* target = lhs->elems[i];
        if (target->kind == EK::Name && static_cast<NameExpr*>(target)->name == "_" && !lookupLocal("_")) continue;
        auto* as = new AssignExpr(target->loc);
        as->op = "=";
        as->lhs = target;
        as->rhs = mkMember(refTo(t, loc), itemName(i), loc);
        checkValue(as);
        let->seq.push_back(as);
    }
    Expr* result = refTo(t, loc);
    checkValue(result);
    let->seq.push_back(result);
    let->type = R;
    e->lowered = let;
    return R;
}

// ================================================================== operadores binarios

Type* Sema::sugarBinary(BinaryExpr* e, Type*& L, Type*& R) {
    unionBinary(e, L, R);  // x == None: el caso sin tipo toma el del otro operando (Unions.cpp)
    const std::string& op = e->op;
    // 'default' sin tipo junto a otro operando: toma su tipo (x == default).
    if (isDefaultLiteral(e->rhs) && !L->is(TK::Null)) e->rhs->type = R = L;
    if (isDefaultLiteral(e->lhs) && !R->is(TK::Null)) e->lhs->type = L = R;

    auto basic = [](Type* t) { return t->is(TK::String) || t->isNumeric() || t->is(TK::Bool) || t->isEnum(); };
    if (op == "+" && (L->is(TK::String) || R->is(TK::String)) && (sugarConcatable(L) || sugarConcatable(R)) &&
        (basic(L) || sugarConcatable(L)) && (basic(R) || sugarConcatable(R)))
        return tc_.get(TK::String);

    bool eq = op == "==" || op == "!=";
    bool rel = op == "<" || op == ">" || op == "<=" || op == ">=";
    Type* nl = nullableElem(L);
    Type* nr = nullableElem(R);
    SourceLoc loc = e->loc;
    if (nl || nr) {
        if (!eq && !rel) {
            diag.error(e->loc, "the '" + op + "' operator is not defined for '" + (nl ? L : R)->str() +
                                   "'; get the value first with '?\?' or '.Value'");
            return tc_.error();
        }
        auto* let = new LetExpr(loc);
        auto finish = [&](Expr* t) {
            checkValue(t);
            let->seq.push_back(t);
            let->type = tc_.get(TK::Bool);
            e->lowered = let;
            return let->type;
        };
        if (L->is(TK::Null) || R->is(TK::Null)) {  // x == null
            if (!eq) {
                diag.error(e->loc, "cannot compare with null using '" + op + "'");
                return tc_.error();
            }
            VarInfo* a = hiddenLocal(nl ? L : R, loc, true);
            let->binds.push_back({a, nl ? e->lhs : e->rhs});
            Expr* t = mkMember(refTo(a, loc), "HasValue", loc);
            return finish(op == "==" ? mkNot(t, loc) : t);
        }
        VarInfo* a = hiddenLocal(L, loc, true);
        VarInfo* b = hiddenLocal(R, loc, true);
        let->binds.push_back({a, e->lhs});
        let->binds.push_back({b, e->rhs});
        auto value = [&](VarInfo* v, bool n) -> Expr* {
            if (n) return mkCall(mkMember(refTo(v, loc), "GetValueOrDefault", loc), {}, loc);
            return refTo(v, loc);
        };
        auto has = [&](VarInfo* v) -> Expr* { return mkMember(refTo(v, loc), "HasValue", loc); };
        Expr* cmp = mkBin(eq ? "==" : op, value(a, nl), value(b, nr), loc);
        Expr* t;
        if (eq) {
            if (nl && nr) t = mkBin("&&", mkBin("==", has(a), has(b), loc), mkBin("||", mkNot(has(a), loc), cmp, loc), loc);
            else t = mkBin("&&", has(nl ? a : b), cmp, loc);
            if (op == "!=") t = mkNot(t, loc);
        } else {
            t = cmp;
            if (nr) t = mkBin("&&", has(b), t, loc);
            if (nl) t = mkBin("&&", has(a), t, loc);
        }
        return finish(t);
    }
    if (eq && isTupleType(L) && isTupleType(R)) {
        if (L->decl->fields.size() != R->decl->fields.size()) {
            diag.error(e->loc, "cannot compare tuples of different sizes ('" + L->str() + "' and '" + R->str() + "')");
            return tc_.error();
        }
        auto* let = new LetExpr(loc);
        VarInfo* a = hiddenLocal(L, loc, true);
        VarInfo* b = hiddenLocal(R, loc, true);
        let->binds.push_back({a, e->lhs});
        let->binds.push_back({b, e->rhs});
        Expr* t = nullptr;
        for (size_t i = 0; i < L->decl->fields.size(); i++) {
            Expr* c = mkBin("==", mkMember(refTo(a, loc), itemName(i), loc), mkMember(refTo(b, loc), itemName(i), loc), loc);
            t = t ? mkBin("&&", t, c, loc) : c;
        }
        if (op == "!=") t = mkNot(t, loc);
        checkValue(t);
        let->seq.push_back(t);
        let->type = tc_.get(TK::Bool);
        e->lowered = let;
        return let->type;
    }
    return nullptr;
}

// ================================================================== patrones

Expr* Sema::bindPatternVar(Pattern* p, const std::string& name, Type* t, Expr* value) {
    if (name.empty() || name == "_") return mkBool(true, p->loc);
    VarInfo* v = patternVar(name, t, p->nameLoc);
    checkValue(value);
    coerce(value, t);
    auto* let = new LetExpr(p->loc);  // (x = valor, true): se asigna justo al comprobar el patrón
    let->binds.push_back({v, value});
    Expr* yes = mkBool(true, p->loc);
    checkValue(yes);
    let->seq.push_back(yes);
    let->type = tc_.get(TK::Bool);
    return let;
}

Expr* Sema::propertyTests(Pattern* p, const SubjectFn& subj, Type* st) {
    Expr* all = nullptr;
    for (size_t i = 0; i < p->props.size(); i++) {
        const std::string& name = p->props[i].first;
        SourceLoc nl = i < p->propLocs.size() ? p->propLocs[i] : p->loc;
        Expr* probe = mkMember(subj(), name, nl);  // solo para conocer el tipo (y el hover)
        Type* pt = checkValue(probe);
        if (pt->isError()) {
            all = mkBool(false, p->loc);
            continue;
        }
        SubjectFn sub = [&, name, nl]() -> Expr* { return mkMember(subj(), name, nl); };
        Expr* t = patternTest(p->props[i].second, sub, pt);
        all = all ? mkBin("&&", all, t, p->loc) : t;
    }
    (void)st;
    return all ? all : mkBool(true, p->loc);
}

Expr* Sema::patternTest(Pattern* p, const SubjectFn& subj, Type* st) {
    SourceLoc l = p->loc;
    if (Expr* u = unionPatternTest(p, subj, st)) return u;  // casos de una unión (Unions.cpp)
    switch (p->kind) {
        case PK::Discard: return mkBool(true, l);
        case PK::Constant: {
            Expr* v = p->value;
            if (v->kind == EK::Name || v->kind == EK::Member) {  // ¿'case Perro:'? (un tipo)
                check(v);
                if (v->vk == ValKind::TypeName && v->typeValue) return lowerTypePattern(p, v->typeValue, subj, st);
            }
            return mkBin("==", subj(), v, l);
        }
        case PK::Relational: return mkBin(p->op, subj(), p->value, l);
        case PK::And: return mkBin("&&", patternTest(p->a, subj, st), patternTest(p->b, subj, st), l);
        case PK::Or: return mkBin("||", patternTest(p->a, subj, st), patternTest(p->b, subj, st), l);
        case PK::Not: return mkNot(patternTest(p->a, subj, st), l);
        case PK::Var: return bindPatternVar(p, p->name, st, subj());
        case PK::Type: {
            Type* target = resolveType(p->tref);
            if (target->isError()) return mkBool(false, l);
            return lowerTypePattern(p, target, subj, st);
        }
        case PK::Property: {
            if (p->tref) {
                Type* target = resolveType(p->tref);
                if (target->isError()) return mkBool(false, l);
                return lowerTypePattern(p, target, subj, st);
            }
            Expr* guardNull = nullptr;
            SubjectFn inner = subj;
            Type* it = st;
            if (Type* el = nullableElem(st)) {  // int? { ... }: tiene valor y se mira el valor
                guardNull = mkMember(subj(), "HasValue", l);
                inner = [&, l]() -> Expr* { return mkCall(mkMember(subj(), "GetValueOrDefault", l), {}, l); };
                it = el;
            } else if (st->isClass()) {
                guardNull = mkBin("!=", subj(), new NullExpr(l), l);
            }
            Expr* t = propertyTests(p, inner, it);
            if (guardNull) t = mkBin("&&", guardNull, t, l);
            if (!p->name.empty()) t = mkBin("&&", t, bindPatternVar(p, p->name, it, inner()), l);
            return t;
        }
        case PK::List: case PK::Slice: return listPatternTest(p, subj, st);  // [1, .., x] (Arrays.cpp)
        case PK::Positional: {
            if (!isTupleType(st) || st->decl->fields.size() != p->elems.size()) {
                diag.error(l, "the positional pattern of " + std::to_string(p->elems.size()) +
                                  " elements needs a tuple of the same size (the value is '" + st->str() + "')");
                return mkBool(false, l);
            }
            Expr* all = nullptr;
            for (size_t i = 0; i < p->elems.size(); i++) {
                SubjectFn sub = [&, i, l]() -> Expr* { return mkMember(subj(), itemName(i), l); };
                Expr* t = patternTest(p->elems[i], sub, st->decl->fields[i]->type);
                all = all ? mkBin("&&", all, t, l) : t;
            }
            return all;
        }
        case PK::Case: break;  // lo trata unionPatternTest al principio (Unions.cpp)
    }
    return mkBool(false, l);
}

// ================================================================== GANCHO: patrones de tipo
//
// Para la implementación de herencia/interfaces. Recibe el patrón ('Perro p', 'Perro { ... }' o
// la constante 'Perro' de 'case Perro:'), el tipo de destino ya resuelto y el sujeto (subj() crea
// una expresión nueva, sin comprobar, de tipo 'st'). Debe devolver una condición SIN comprobar que
// sea true cuando el valor es de tipo 'target'; además:
//   - si p->name no está vacío, declarar y asignar la variable con
//       bindPatternVar(p, p->name, target, <sujeto convertido a target>)
//     (es una expresión (x = valor, true) que se combina con '&&');
//   - si p->kind == PK::Property, añadir '&& propertyTests(p, <sujeto convertido>, target)'.
// Mientras no haya herencia, solo se admite el mismo tipo estático del sujeto (o T para un T?).
Expr* Sema::lowerTypePattern(Pattern* p, Type* target, const SubjectFn& subj, Type* st) {
    SourceLoc l = p->loc;
    SubjectFn value = subj;
    Expr* test = nullptr;
    if (target == st) {
        if (st->isClass()) test = mkBin("!=", subj(), new NullExpr(l), l);
    } else if (nullableElem(st) == target) {
        test = mkMember(subj(), "HasValue", l);
        value = [&, l]() -> Expr* { return mkCall(mkMember(subj(), "GetValueOrDefault", l), {}, l); };
    } else if (st->isClass() && target->isClass()) {
        // Herencia e interfaces (SemaClasses.cpp): 'x is T' comprueba el tipo en ejecución y el
        // valor convertido es 'x as T' (no es null cuando la prueba es cierta).
        auto* is = new IsExpr(l);
        is->operand = subj();
        is->preset = target;
        test = is;
        value = [&, l, target]() -> Expr* {
            auto* as = new AsExpr(l);
            as->operand = subj();
            as->preset = target;
            return as;
        };
    } else if (target->isClass() && !st->isRefLike()) {
        diag.error(l, "the 'is' operator requires a class or interface reference (the type is '" + st->str() + "')");
        return mkBool(false, l);
    } else {
        diag.error(l, "the type pattern '" + target->str() + "' cannot match a value of type '" + st->str() + "'");
        return mkBool(false, l);
    }
    auto conj = [&](Expr* t) { test = test ? mkBin("&&", test, t, l) : t; };
    if (p->kind == PK::Property) conj(propertyTests(p, value, target));
    if (!p->name.empty()) conj(bindPatternVar(p, p->name, target, value()));
    return test ? test : mkBool(true, l);
}

Type* Sema::checkIsPattern(IsPatternExpr* e) {
    Type* st = checkValue(e->subject);
    if (st->isError()) return tc_.get(TK::Bool);
    SourceLoc loc = e->loc;
    VarInfo* sv = hiddenLocal(st, loc, true);
    SubjectFn subj = [&]() -> Expr* { return refTo(sv, loc); };
    Expr* test = patternTest(e->pat, subj, st);  // las variables del patrón quedan en el ámbito actual
    checkCondition(test);
    auto* let = new LetExpr(loc);
    let->binds.push_back({sv, e->subject});
    let->seq.push_back(test);
    let->type = tc_.get(TK::Bool);
    e->lowered = let;
    return let->type;
}

Type* Sema::checkSwitchExpr(SwitchExpr* e) {
    Type* st = checkValue(e->subject);
    SourceLoc loc = e->loc;
    if (st->isError()) return st;
    VarInfo* sv = hiddenLocal(st, loc, true);
    SubjectFn subj = [&]() -> Expr* { return refTo(sv, loc); };
    std::vector<Expr*> conds;
    bool covered = false;
    for (auto& arm : e->arms) {
        if (covered) diag.error(arm.loc, "this 'switch' arm is never reached: an earlier one already covers all values");
        ctx_.scopes.emplace_back();
        Expr* cond = patternTest(arm.pat, subj, st);
        if (arm.guard) cond = mkBin("&&", cond, arm.guard, arm.loc);
        checkCondition(cond);
        checkValue(arm.value);
        ctx_.scopes.pop_back();
        conds.push_back(cond);
        if (!arm.guard && isIrrefutable(arm.pat)) covered = true;
    }
    {  // exhaustividad en tiempo de compilación sobre una unión (Unions.cpp)
        std::vector<std::pair<Pattern*, Expr*>> pats;
        for (auto& arm : e->arms) pats.push_back({arm.pat, arm.guard});
        unionExhaustive(st, pats, loc, true);
    }
    // Tipo del resultado: el común a todos los brazos (como en '?:'); 'null' lo hace T?.
    Type* T = nullptr;
    Expr* src = nullptr;
    bool sawNull = false, bad = false;
    for (auto& arm : e->arms) {
        Type* vt = arm.value->type;
        if (vt->isError()) {
            bad = true;
            continue;
        }
        if (vt->is(TK::Null)) {
            sawNull = true;
            continue;
        }
        if (!T) {
            T = vt, src = arm.value;
            continue;
        }
        if (T == vt || canImplicit(arm.value, vt, T)) continue;
        if (canImplicit(src, T, vt)) {
            T = vt, src = arm.value;
            continue;
        }
        diag.error(arm.value->loc, "the 'switch' arms do not have a common type ('" + T->str() + "' and '" + vt->str() + "')");
        bad = true;
    }
    if (bad) return tc_.error();
    if (!T) {
        diag.error(loc, "cannot infer the type of the 'switch' (all arms are null)");
        return tc_.error();
    }
    if (T->isVoid()) {
        diag.error(loc, "the arms of a 'switch' expression must produce a value");
        return tc_.error();
    }
    if (sawNull) T = nullableOf(T, loc);
    for (auto& arm : e->arms) coerce(arm.value, T);
    Expr* chain;
    size_t n = e->arms.size();
    if (covered && !e->arms.back().guard && isIrrefutable(e->arms.back().pat)) {
        chain = e->arms.back().value;
        n--;
    } else {
        auto* f = new MatchFailExpr(loc);  // ningún brazo coincide: panic con el valor si se puede mostrar
        f->type = T;
        if (toStringable(st)) {
            f->value = refTo(sv, loc);
            checkValue(f->value);
        }
        chain = f;
    }
    for (size_t i = n; i-- > 0;) {
        auto* c = new CondExpr(e->arms[i].loc);
        c->cond = conds[i];
        c->a = e->arms[i].value;
        c->b = chain;
        c->type = T;
        chain = c;
    }
    auto* let = new LetExpr(loc);
    let->binds.push_back({sv, e->subject});
    let->seq.push_back(chain);
    let->type = T;
    e->lowered = let;
    return T;
}

// switch (s) { case p when g: ... } con cadenas, patrones o guardas: cadena de 'if' dentro de un
// 'switch (0) { default: }' de C (así 'break' sigue saliendo del switch).
bool Sema::lowerSwitchStmt(SwitchStmt* s) {
    Type* st = checkValue(s->subject);
    bool needs = !(st->isIntegral() || st->isEnum() || st->isError());
    for (auto& sec : s->sections)
        for (size_t i = 0; i < sec.patterns.size(); i++)
            if (sec.patterns[i]->kind != PK::Constant || sec.guards[i]) needs = true;
    if (!needs) return false;
    SourceLoc loc = s->loc;
    ctx_.scopes.emplace_back();
    VarInfo* sv = hiddenLocal(st, loc, false);
    VarDeclStmt* pre = bindDecl(sv, s->subject);
    SubjectFn subj = [&]() -> Expr* { return refTo(sv, loc); };
    ctx_.switchDepth++;
    std::vector<SwitchStmt::Section*> order;
    SwitchStmt::Section* def = nullptr;
    for (auto& sec : s->sections) {
        if (!sec.hasDefault) {
            order.push_back(&sec);
        } else if (def) {
            diag.error(s->loc, "the 'switch' already has a 'default' label");
        } else {
            def = &sec;
        }
    }
    if (def) order.push_back(def);  // 'default' se prueba al final, esté donde esté
    if (!def) {  // exhaustividad sobre una unión (Unions.cpp)
        std::vector<std::pair<Pattern*, Expr*>> pats;
        for (auto& sec : s->sections)
            for (size_t i = 0; i < sec.patterns.size(); i++) pats.push_back({sec.patterns[i], sec.guards[i]});
        unionExhaustive(st, pats, loc, false);
    }
    std::vector<IfStmt*> ifs;
    for (SwitchStmt::Section* sec : order) {
        ctx_.scopes.emplace_back();
        Expr* cond = nullptr;
        for (size_t i = 0; i < sec->patterns.size(); i++) {
            Expr* t = patternTest(sec->patterns[i], subj, st);
            if (sec->guards[i]) t = mkBin("&&", t, sec->guards[i], sec->guards[i]->loc);
            cond = cond ? mkBin("||", cond, t, loc) : t;
        }
        if (!cond || sec == def) {
            if (cond && !st->isError()) checkCondition(cond);  // se comprueba aunque 'default' lo cubra
            cond = mkBool(true, loc);
        }
        if (!st->isError()) checkCondition(cond);
        auto* body = new BlockStmt(sec->body.empty() ? loc : sec->body.front()->loc);
        body->stmts = sec->body;
        checkStmt(body);
        if (!sectionEnds(sec->body))
            diag.error(s->loc, "control cannot fall through from one 'case' label to another (missing 'break')");
        ctx_.scopes.pop_back();
        auto* is = new IfStmt(loc);
        is->cond = cond;
        is->then = body;
        ifs.push_back(is);
    }
    ctx_.switchDepth--;
    ctx_.scopes.pop_back();
    for (size_t i = ifs.size(); i-- > 1;) ifs[i - 1]->els = ifs[i];
    auto* zero = new IntLitExpr(loc);
    zero->type = tc_.get(TK::Int);
    auto* sw = new SwitchStmt(loc);
    sw->subject = zero;
    SwitchStmt::Section only;
    only.hasDefault = true;
    if (!ifs.empty()) only.body.push_back(ifs.front());
    sw->sections.push_back(only);
    auto* blk = new BlockStmt(loc);
    blk->stmts = {pre, sw};
    s->lowered = blk;
    return true;
}

// ================================================================== sentencias

bool Sema::checkSugarStmt(Stmt* s) {
    switch (s->kind) {
        case SK::Foreach: checkForeach(static_cast<ForeachStmt*>(s)); return true;
        case SK::Deconstruct: checkDeconstruct(static_cast<DeconstructStmt*>(s)); return true;
        case SK::Using: checkUsing(static_cast<UsingStmt*>(s)); return true;
        case SK::Switch: return lowerSwitchStmt(static_cast<SwitchStmt*>(s));
        case SK::Defer:  // las demás se convierten en try/finally al comprobar su bloque (Flow.cpp)
            diag.error(s->loc, "'defer' must appear directly inside a { ... } block");
            return true;
        default: return false;
    }
}

void Sema::checkForeach(ForeachStmt* s) {
    Type* ct = checkValue(s->coll);
    if (arrayForeach(s, ct)) return;  // T[]: bucle de índices (Arrays.cpp)
    SourceLoc loc = s->loc;
    ctx_.scopes.emplace_back();
    auto fallback = [&]() {  // sigue comprobando el cuerpo para informar de más errores
        if (!s->name.empty()) declareLocal(s->name, tc_.error(), s->nameLoc, "l_");
        for (size_t i = 0; i < s->names.size(); i++) declareLocal(s->names[i], tc_.error(), s->nameLocs[i], "l_");
        ctx_.loopDepth++;
        checkStmt(s->body);
        ctx_.loopDepth--;
        ctx_.scopes.pop_back();
    };
    if (ct->isError()) return fallback();
    if (ct->isClass() && findMethods(ct->decl, "GetEnumerator").empty()) ct = iterForeachSource(s->coll, ct);  // Iterators.cpp
    bool has = ct->is(TK::String) && !findExtensions("GetEnumerator").empty();
    if (ct->isAggregate())
        for (MethodDecl* m : ct->decl->methods) has |= m->name == "GetEnumerator";
    if (!has && !ct->is(TK::String)) {
        for (MethodDecl* m : findExtensions("GetEnumerator"))
            if (m->params[0].type && (m->params[0].type == ct || m->isTemplate())) has = true;
    }
    if (!has) {
        diag.error(s->coll->loc, "'foreach' cannot iterate over a value of type '" + ct->str() +
                                     "': it needs a GetEnumerator() method (like List<T>, Dictionary<K, V>, "
                                     "HashSet<T>, Span<T> or string)");
        return fallback();
    }
    VarInfo* cv = hiddenLocal(ct, loc, false);
    VarDeclStmt* d1 = bindDecl(cv, s->coll);
    Expr* getEnum = mkCall(mkMember(refTo(cv, loc), "GetEnumerator", loc), {}, loc);
    Type* et = checkValue(getEnum);
    if (et->isError()) return fallback();
    VarInfo* ev = hiddenLocal(et, loc, false);
    VarDeclStmt* d2 = bindDecl(ev, getEnum);
    auto* w = new WhileStmt(loc);
    w->cond = mkCall(mkMember(refTo(ev, loc), "MoveNext", loc), {}, loc);
    auto* inner = new BlockStmt(s->body->loc);
    Expr* current = mkMember(refTo(ev, loc), "Current", loc);
    if (!s->name.empty()) {  // variable nueva en cada vuelta (las capturas ven su propio valor)
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
    Stmt* loop = iterForeachLoop(ev, et, w, loc);  // Dispose() al salir (IEnumerator<T>, Iterators.cpp)
    checkStmt(loop);
    ctx_.scopes.pop_back();
    auto* blk = new BlockStmt(loc);
    blk->stmts = {d1, d2, loop};
    s->lowered = blk;
}

void Sema::checkDeconstruct(DeconstructStmt* s) {
    Type* t = checkValue(s->init);
    SourceLoc loc = s->loc;
    auto fallback = [&]() {
        for (size_t i = 0; i < s->names.size(); i++)
            if (s->names[i] != "_") declareLocal(s->names[i], tc_.error(), s->locs[i], "l_");
    };
    if (t->isError()) return fallback();
    VarInfo* dv = hiddenLocal(t, loc, false);
    auto* blk = new BlockStmt(loc);
    blk->noScope = true;  // las variables siguen visibles después
    blk->stmts.push_back(bindDecl(dv, s->init));
    size_t n = s->names.size();
    if (isTupleType(t)) {
        if (t->decl->fields.size() != n) {
            diag.error(loc, "cannot deconstruct a tuple of " + std::to_string(t->decl->fields.size()) +
                                " elements into " + std::to_string(n) + " variables");
            return fallback();
        }
        for (size_t i = 0; i < n; i++) {
            if (s->names[i] == "_") continue;
            auto* vd = new VarDeclStmt(s->locs[i]);
            vd->tref = s->types[i] ? s->types[i] : mkVarRef(s->locs[i]);
            VarDeclStmt::Declarator dc;
            dc.loc = s->locs[i];
            dc.name = s->names[i];
            dc.init = mkMember(refTo(dv, loc), itemName(i), loc);
            vd->decls.push_back(dc);
            checkStmt(vd);
            blk->stmts.push_back(vd);
        }
        s->lowered = blk;
        return;
    }
    // Deconstruct(out A a, out B b) del tipo (p. ej. KeyValuePair<K, V>).
    MethodDecl* dm = nullptr;
    if (t->isAggregate())
        for (MethodDecl* m : t->decl->methods) {
            if (m->kind != MethodKind::Normal || m->name != "Deconstruct" || m->isStatic() || m->params.size() != n) continue;
            bool allRef = true;
            for (Param& p : m->params) allRef &= p.isRef();
            if (allRef) dm = m;
        }
    if (!dm) {
        diag.error(loc, "cannot deconstruct a value of type '" + t->str() + "' into " + std::to_string(n) +
                            " variables (expected a tuple or a Deconstruct(out ...) method)");
        return fallback();
    }
    std::vector<Expr*> args;
    for (size_t i = 0; i < n; i++) {
        Type* pt = dm->params[i].type;
        VarInfo* v;
        if (s->names[i] == "_") {
            v = hiddenLocal(pt, s->locs[i], false);
        } else {
            if (s->types[i]) {
                Type* want = resolveType(s->types[i]);
                if (!want->isError() && want != pt)
                    diag.error(s->locs[i], "'" + s->names[i] + "' must be of type '" + pt->str() + "' (what Deconstruct returns)");
            }
            v = declareLocal(s->names[i], pt, s->locs[i], "l_");
            if (ideMode) addRef(s->locs[i], (int)s->names[i].size(), "(variable local) " + pt->str() + " " + s->names[i], &s->locs[i]);
        }
        blk->stmts.push_back(bindDecl(v, nullptr));
        args.push_back(refTo(v, s->locs[i]));
    }
    auto* call = new ExprStmt(loc);
    call->expr = mkCall(mkMember(refTo(dv, loc), "Deconstruct", loc), args, loc);
    checkStmt(call);
    blk->stmts.push_back(call);
    s->lowered = blk;
}

// using var x = e;  /  using (var x = e) { }: se llama al destructor (delete) al salir del ámbito.
void Sema::checkUsing(UsingStmt* s) {
    if (s->body) ctx_.scopes.emplace_back();
    auto require = [&](VarInfo* v, SourceLoc l) {
        Type* t = v->type;
        if (t->isError()) return;
        if (!t->isClass()) {
            diag.error(l, "'using' needs a class object (released by its destructor on exit); '" + t->str() +
                              "' is not one");
            return;
        }
        useMethod(t->decl->dtor);
        s->vars.push_back(v);
    };
    if (s->decl) {
        checkStmt(s->decl);
        for (auto& dc : s->decl->decls)
            if (dc.var) require(dc.var, dc.loc);
    } else if (s->expr) {
        Type* t = checkValue(s->expr);
        VarInfo* v = hiddenLocal(t, s->loc, false);
        s->decl = bindDecl(v, s->expr);
        require(v, s->expr->loc);
    }
    if (s->body) {
        checkStmt(s->body);
        ctx_.scopes.pop_back();
    }
}

// ================================================================== params

void Sema::checkParamsSignature(MethodDecl* m) {
    for (size_t i = 0; i < m->params.size(); i++) {
        Param& p = m->params[i];
        if (!p.isParams) continue;
        if (i + 1 != m->params.size()) diag.error(p.loc, "'params' can only be used on the last parameter");
        if (p.isRef()) diag.error(p.loc, "a 'params' parameter cannot be ref or out");
        if (p.type && !p.type->isError() && !listElem(p.type) && !vectorElemOf(p.type))
            diag.error(p.loc, "a 'params' parameter must be a T[] array or List<T>");
    }
}

void Sema::inferParamsTypeArgs(MethodDecl* tmpl, const std::vector<Expr*>& args, std::map<std::string, Type*>& b) {
    if (!paramsMethod(tmpl)) return;
    size_t n = tmpl->params.size();
    TypeRef* tr = tmpl->params.back().tref;
    if (tr->typeArgs.size() != 1 || args.size() + 1 < n) return;
    if (args.size() == n && (listElem(args[n - 1]->type) || vectorElemOf(args[n - 1]->type))) return;  // forma normal
    for (size_t j = n - 1; j < args.size(); j++) unify(tr->typeArgs[0], args[j]->type, tmpl, b);
}

int Sema::paramsCost(MethodDecl* m, std::vector<Expr*>& args) {
    size_t n = m->params.size();
    if (args.size() + 1 < n) return -1;
    int cost = 0;
    for (size_t i = 0; i + 1 < n; i++) {
        Param& p = m->params[i];
        if (!p.type || p.type->isError()) return -1;
        if (p.isRef()) {
            if (!(args[i]->type == p.type && isLValue(args[i]) && !isConstTarget(args[i]))) return -1;
            continue;
        }
        int c = convCost(args[i], p.type);
        if (c < 0) return -1;
        cost += c;
    }
    Param& last = m->params.back();
    if (!last.type || last.type->isError()) return -1;
    if (args.size() == n) {  // forma normal: se pasa la lista directamente
        int c = convCost(args[n - 1], last.type);
        if (c >= 0) return cost + c;
    }
    Type* el = listElem(last.type);
    if (!el) el = vectorElemOf(last.type);  // params T[] (Arrays.cpp)
    if (!el) return -1;
    for (size_t j = n - 1; j < args.size(); j++) {
        int c = convCost(args[j], el);
        if (c < 0) return -1;
        cost += c;
    }
    return cost + 1;
}

void Sema::packParams(MethodDecl* m, std::vector<Expr*>& args) {
    size_t n = m->params.size();
    Param& last = m->params.back();
    if (args.size() + 1 < n || !last.type || last.type->isError()) return;
    if (args.size() == n && args[n - 1]->type && canImplicit(args[n - 1], args[n - 1]->type, last.type)) return;
    if (vectorElemOf(last.type)) return packParamsArray(m, args);  // params T[] (Arrays.cpp)
    Type* el = listElem(last.type);
    if (!el) return;
    auto* pl = new ParamsListExpr(args.size() >= n ? args[n - 1]->loc : m->loc);
    for (size_t j = n - 1; j < args.size(); j++) {
        coerce(args[j], el);
        pl->items.push_back(args[j]);
    }
    pl->type = last.type;
    ClassDecl* c = last.type->decl;
    for (size_t k = 0; k < c->ctors.size(); k++)
        if (c->ctors[k]->params.size() == 1 && c->ctors[k]->params[0].type && c->ctors[k]->params[0].type->is(TK::Int)) {
            pl->ctor = c->ctors[k];
            pl->ctorIndex = k;
        }
    for (MethodDecl* mm : c->methods)
        if (mm->kind == MethodKind::Normal && mm->name == "Add" && mm->params.size() == 1) pl->add = mm;
    if (!pl->ctor || !pl->add) {
        diag.error(pl->loc, "List<T> does not have the List(int) constructor or the Add method needed for 'params'");
        return;
    }
    useMethod(pl->ctor);
    useMethod(pl->add);
    args.resize(n - 1);
    args.push_back(pl);
}
