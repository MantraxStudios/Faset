// Faset - tipos algebraicos (union): construcción con inferencia del tipo, patrones de caso,
// exhaustividad en tiempo de compilación, el operador '?' de propagación de Result/Option y los
// cuerpos generados (ToString, ==, GetHashCode). La sintaxis está en ParserUnions.cpp.
//
//   union Forma { Circulo(double Radio), Rect(double Ancho, double Alto), Punto; ... }
//
//   * Construcción: Forma.Circulo(2), Forma.Punto. En una unión genérica el tipo se infiere de
//     los argumentos (Option.Some(5) es Option<int>) o del destino (Option<int> x = Option.None;
//     return Result.Err("x");), como una lambda: la expresión queda "pendiente" (TK::Pending, id 2)
//     hasta que se convierte. Some/None/Ok/Err sin calificar son los casos de std.Option y
//     std.Result (como el preludio de Rust) cuando el nombre no existe en el ámbito.
//   * Patrones: Forma.Circulo(var r), Circulo(> 1), Rect { Ancho: > 10 }, Forma.Punto, Rect r.
//     El caso se prueba con la etiqueta (__caso) y los campos son '__Caso_Campo'.
//   * Exhaustividad: un 'switch' (de expresión o de sentencia) sobre una unión debe cubrir todos
//     los casos; si falta alguno es un error de compilación que los enumera ('_' cubre el resto).
//   * expr? (Result<T, E> u Option<T>): <t> = expr; si es Err/None el método devuelve ese error
//     (convertido con una conversión implícita o con 'static F From(E)') y si no, vale <t>.Value.
//     Como 'await', se saca de la expresión a sentencias propias (Async.cpp: asyncSpill), así
//     funciona en métodos normales, async y lambdas de bloque, respetando el orden de evaluación.
#include "CodeGen.h"
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

Expr* mkBool(bool v, SourceLoc loc) {
    auto* b = new BoolLitExpr(loc);
    b->value = v;
    return b;
}

Expr* mkInt(int v, SourceLoc loc) {
    auto* i = new IntLitExpr(loc);
    i->value = (uint64_t)v;
    return i;
}

// Nombre de un tipo ya resuelto (sin buscarlo por nombre): T.Miembro sobre el tipo 't'.
NameExpr* typeNameExpr(Type* t, SourceLoc loc) {
    auto* n = new NameExpr(loc);
    n->name = t->decl ? t->decl->name : t->str();
    n->vk = ValKind::TypeName;
    n->typeValue = t;
    n->type = t;
    return n;
}

// Nombre del tipo de la unión sin argumentos (Option para Option<int>).
std::string baseName(ClassDecl* c) { return c->templateOf ? c->templateOf->name : c->name; }

std::string caseShape(const UnionCaseInfo& uc, bool withTypes) {
    std::string s = uc.name;
    if (uc.unit()) return s;
    s += "(";
    for (size_t i = 0; i < uc.fields.size(); i++)
        s += (i ? ", " : "") + (withTypes ? uc.fields[i].tref->str() + " " + uc.fields[i].name : std::string("_"));
    return s + ")";
}

// Ruta escrita en un patrón: Forma.Circulo -> {"Forma", "Circulo"}; nulo si no es un nombre.
bool exprPath(Expr* e, std::vector<std::string>& out) {
    if (e->kind == EK::Name) {
        out.insert(out.begin(), static_cast<NameExpr*>(e)->name);
        return true;
    }
    if (e->kind == EK::Member) {
        auto* m = static_cast<MemberExpr*>(e);
        if (m->arrow) return false;
        out.insert(out.begin(), m->name);
        return exprPath(m->obj, out);
    }
    return false;
}

// Ranura del receptor 'CondRecv' de una cadena obj?.a.b(...) (para reemplazarlo).
Expr** findRecv(Expr** slot) {
    Expr* x = *slot;
    if (!x) return nullptr;
    switch (x->kind) {
        case EK::CondRecv: return slot;
        case EK::Member: return findRecv(&static_cast<MemberExpr*>(x)->obj);
        case EK::Call: return findRecv(&static_cast<CallExpr*>(x)->callee);
        case EK::Index: return findRecv(&static_cast<IndexExpr*>(x)->obj);
        default: return nullptr;
    }
}

}  // namespace

bool Sema::unionStd(Type* t, const char* name) {
    if (!t || !t->isAggregate() || !t->decl || !t->decl->unionInfo || !t->decl->templateOf) return false;
    ClassDecl* tm = t->decl->templateOf;
    return tm->name == name && tm->ns == "std";
}

std::string Sema::unionDescription(ClassDecl* c) {
    std::string s = std::string("union ") + (c->unionInfo->isRef ? "class " : "");
    if (!c->ns.empty()) s += c->ns + ".";
    s += c->displayName;
    if (c->isTemplate()) {
        s += "<";
        for (size_t i = 0; i < c->typeParams.size(); i++) s += (i ? ", " : "") + c->typeParams[i];
        s += ">";
    }
    s += " { ";
    for (size_t i = 0; i < c->unionInfo->cases.size(); i++) s += (i ? ", " : "") + caseShape(c->unionInfo->cases[i], true);
    return s + " }";
}

// ================================================================== construcción

// std.Option (Some, None) o std.Result (Ok, Err): los casos que se pueden escribir sin calificar.
ClassDecl* Sema::preludeUnion(const std::string& name) {
    const char* tn = name == "Some" || name == "None" ? "Option" : name == "Ok" || name == "Err" ? "Result" : nullptr;
    if (!tn) return nullptr;
    NamespaceSym* ns = getNs("std", false);
    if (!ns) return nullptr;
    auto it = ns->types.find(tn);
    if (it == ns->types.end()) return nullptr;
    ClassDecl* c = it->second;
    if (!c->isTemplate() && c->arityTwin) c = c->arityTwin;
    return c->isTemplate() && c->unionInfo ? c : nullptr;
}

// 'obj' nombra una unión genérica sin argumentos de tipo (Option, o Result si existe también la
// clase estática Result): la plantilla, o nulo.
ClassDecl* Sema::unionTemplateOf(Expr* obj) {
    if (!obj || obj->kind != EK::Name || obj->vk == ValKind::TypeName) return nullptr;
    auto* n = static_cast<NameExpr*>(obj);
    if (!n->typeArgs.empty() || n->name == kCompletionMarker || lookupLocal(n->name)) return nullptr;
    ClassDecl* cls = ctx_.cls;
    if (cls && !cls->isNamespaceScope && (findField(cls, n->name) || findGetter(cls, n->name))) return nullptr;
    if (ctx_.method && ctx_.method->typeArgMap.count(n->name)) return nullptr;
    if (cls && cls->typeArgMap.count(n->name)) return nullptr;
    Sym s = lookupUnqualified(n->name, n->loc);
    if (s.kind != Sym::TypeK || !s.decl) return nullptr;
    ClassDecl* d = s.decl;
    if (!d->isTemplate() && d->arityTwin) d = d->arityTwin;
    return d->isTemplate() && d->unionInfo ? d : nullptr;
}

Type* Sema::unionCaseRef(Expr* e, ClassDecl* tmpl, const std::string& cas) {
    auto* u = new UnionCaseExpr(e->loc);
    u->tmpl = tmpl;
    u->name = cas;
    e->lowered = u;
    if (ideMode) {
        int k = tmpl->unionInfo->find(cas);
        SourceLoc at = e->kind == EK::Member ? static_cast<MemberExpr*>(e)->nameLoc : e->loc;
        addRef(at, (int)cas.size(), "(case of " + baseName(tmpl) + ") " + caseShape(tmpl->unionInfo->cases[k], true),
               &tmpl->unionInfo->cases[k].loc);
    }
    return tc_.pendingCase();
}

Type* Sema::unionMemberHook(MemberExpr* e) {
    if (e->arrow) return nullptr;
    ClassDecl* t = unionTemplateOf(e->obj);
    if (!t) return nullptr;
    if (e->name == kCompletionMarker) {  // Option.| : los casos
        for (const UnionCaseInfo& uc : t->unionInfo->cases) addCompletion(uc.name, 20, baseName(t) + "." + caseShape(uc, true));
        return nullptr;
    }
    if (t->unionInfo->find(e->name) < 0) return nullptr;  // Result.Try(...): la clase estática gemela
    return unionCaseRef(e, t, e->name);
}

Type* Sema::unionNameHook(NameExpr* e) {
    if (!e->typeArgs.empty()) return nullptr;
    ClassDecl* t = preludeUnion(e->name);
    if (!t || t->unionInfo->find(e->name) < 0) return nullptr;
    return unionCaseRef(e, t, e->name);
}

// Llamada a un caso: Option.Some(5), Ok(x). El tipo se infiere de los argumentos si se puede
// (si no, queda pendiente hasta conocer el destino); con un destino de la misma unión se vuelve a
// construir para él (Option<long> x = Some(5)).
Type* Sema::unionCallHook(CallExpr* e) {
    Expr* callee = e->callee;
    if (!callee->lowered || callee->lowered->kind != EK::UnionCase) return nullptr;
    auto* u = static_cast<UnionCaseExpr*>(callee->lowered);
    ClassDecl* tm = u->tmpl;
    const UnionCaseInfo& uc = tm->unionInfo->cases[tm->unionInfo->find(u->name)];
    if (uc.unit()) {
        diag.error(e->loc, "case '" + u->name + "' has no fields: write it without parentheses (" + baseName(tm) + "." +
                               u->name + ")");
        return tc_.error();
    }
    if (e->args.size() != uc.fields.size()) {
        diag.error(e->loc, "case '" + caseShape(uc, true) + "' expects " + std::to_string(uc.fields.size()) +
                               " argument(s), not " + std::to_string(e->args.size()));
        return tc_.error();
    }
    for (Expr* a : e->args)
        if (a->type->isError()) return tc_.error();
    u->args = e->args;
    u->hasCall = true;
    u->loc = e->loc;
    MethodDecl fake;
    fake.typeParams = tm->typeParams;
    std::map<std::string, Type*> b;
    for (size_t i = 0; i < uc.fields.size(); i++) unify(uc.fields[i].tref, e->args[i]->type, &fake, b);
    std::vector<Type*> targs;
    for (const std::string& p : tm->typeParams)
        if (b.count(p)) targs.push_back(b[p]);
    if (targs.size() == tm->typeParams.size()) {
        ClassDecl* inst = instantiate(tm, targs, e->loc);
        if (!inst) return tc_.error();
        Expr* built = unionBuild(inst, u, e->loc);
        if (!built) return tc_.error();
        e->lowered = built;
        unionInferred_[e] = u;  // inferido de los argumentos: se puede reconstruir para otro destino
        return built->type;
    }
    e->lowered = u;
    return tc_.pendingCase();
}

// Construcción comprobada del caso 'u' en la instancia 'inst' (los argumentos ya comprobados).
Expr* Sema::unionBuild(ClassDecl* inst, UnionCaseExpr* u, SourceLoc loc) {
    UnionInfo* ui = inst->unionInfo;
    int k = ui ? ui->find(u->name) : -1;
    if (k < 0) {
        diag.error(loc, "'" + inst->displayName + "' does not have case '" + u->name + "'");
        return nullptr;
    }
    const UnionCaseInfo& uc = ui->cases[k];
    if (uc.unit()) {
        MethodDecl* g = findGetter(inst, u->name);
        if (!g) return nullptr;
        resolveMethodSignature(g);
        useMethod(g, &loc);
        auto* c = new CallExpr(loc);
        c->callee = typeNameExpr(inst->type, loc);
        c->target = g;
        c->type = g->ret;
        return c;
    }
    if (!u->hasCall) {
        diag.error(loc, "case '" + caseShape(uc, true) + "' needs its fields: " + baseName(inst) + "." + uc.name + "(...)");
        return nullptr;
    }
    MethodDecl* m = nullptr;
    for (MethodDecl* x : findMethods(inst, u->name))
        if (x->isStatic() && x->params.size() == uc.fields.size()) m = x;
    if (!m) return nullptr;
    resolveMethodSignature(m);
    std::vector<Expr*> args = u->args;
    for (size_t i = 0; i < args.size(); i++) {
        Type* pt = m->params[i].type;
        if (!canImplicit(args[i], args[i]->type, pt)) {
            diag.error(args[i]->loc, "field '" + uc.fields[i].name + "' of " + inst->displayName + "." + uc.name +
                                         " is of type '" + pt->str() + "'; cannot convert '" + args[i]->type->str() + "'");
            return nullptr;
        }
        coerce(args[i], pt);
    }
    useMethod(m, &loc);
    auto* c = new CallExpr(loc);
    auto* callee = mkMember(typeNameExpr(inst->type, loc), u->name, loc);
    callee->vk = ValKind::MethodGroup;
    callee->type = tc_.get(TK::Void);
    c->callee = callee;
    c->args = args;
    c->target = m;
    c->type = m->ret;
    return c;
}

namespace {

// ¿Se puede construir el caso 'u' en 'to' (otra instancia de la misma unión)?
bool caseFits(Sema& s, UnionCaseExpr* u, Type* to, const std::function<bool(Expr*, Type*)>& conv) {
    if (!to->isAggregate() || !to->decl || to->decl->templateOf != u->tmpl) return false;
    ClassDecl* inst = to->decl;
    int k = inst->unionInfo ? inst->unionInfo->find(u->name) : -1;
    if (k < 0) return false;
    const UnionCaseInfo& uc = inst->unionInfo->cases[k];
    if (uc.unit()) return !u->hasCall;
    if (!u->hasCall || u->args.size() != uc.fields.size()) return false;
    for (size_t i = 0; i < u->args.size(); i++) {
        std::string n = unionFieldName(uc.name, uc.fields[i].name);
        FieldDecl* f = nullptr;
        for (FieldDecl* x : inst->fields)
            if (x->name == n) f = x;
        if (!f || !f->type || !conv(u->args[i], f->type)) return false;
    }
    (void)s;
    return true;
}

}  // namespace

bool Sema::unionRetarget(Expr*& e, Type* to, bool apply) {
    Type* from = e->type;
    if (!from || from == to || from->isError() || from->isPending()) return false;
    // Interoperabilidad con T?:  T? -> Option<T> (null es None),  T -> Option<T> (Some),
    // Option<T> -> T? (None es null; solo con T por valor: un T de clase ya admite null).
    auto wrapCall = [&](Expr* recv, const std::string& name, std::vector<Expr*> args) {
        auto* hold = new LetExpr(e->loc);  // el valor ya está comprobado: no se vuelve a comprobar
        hold->seq.push_back(e);
        hold->type = from;
        Expr* c = recv ? (Expr*)mkCall(mkMember(hold, name, e->loc), {}, e->loc)
                       : (Expr*)mkCall(mkMember(typeNameExpr(to, e->loc), name, e->loc), {hold}, e->loc);
        (void)args;
        checkValue(c);
        e = c;
    };
    if (unionStd(to, "Option") && to->decl->typeArgs.size() == 1) {
        Type* T = to->decl->typeArgs[0];
        Type* NT = T->isRefLike() || nullableElem(T) || T->isVoid() ? T : nullableOf(T, e->loc);
        if (from == NT || from == T || (from->is(TK::Null) && T->isRefLike())) {
            if (apply) wrapCall(nullptr, from == NT || from->is(TK::Null) ? "FromNullable" : "Some", {});
            return true;
        }
    }
    if (Type* el = nullableElem(to)) {
        if (unionStd(from, "Option") && from->decl->typeArgs.size() == 1 && from->decl->typeArgs[0] == el) {
            if (apply) wrapCall(e, "ToNullable", {});
            return true;
        }
    }
    auto it = unionInferred_.find(e);
    if (it == unionInferred_.end() || e->type == to) return false;
    UnionCaseExpr* u = it->second;
    if (!caseFits(*this, u, to, [&](Expr* a, Type* t) { return canImplicit(a, a->type, t); })) return false;
    if (!apply) return true;
    Expr* built = unionBuild(to->decl, u, e->loc);
    if (!built) return false;
    e = built;
    return true;
}

// c ? Ok(1) : Err("x"): los dos brazos quedan pendientes y la expresión toma el tipo del destino.
static bool pendingCond(Expr* e) { return e->kind == EK::Cond && !e->lowered; }

int Sema::unionPendingCost(Expr* e, Type* to) {
    if (pendingCond(e)) {
        auto* c = static_cast<CondExpr*>(e);
        return unionPendingCost(c->a, to) >= 0 && unionPendingCost(c->b, to) >= 0 ? 1 : -1;
    }
    auto* u = static_cast<UnionCaseExpr*>(e->lowered);
    return caseFits(*this, u, to, [&](Expr* a, Type* t) { return canImplicit(a, a->type, t); }) ? 1 : -1;
}

bool Sema::unionConvertPending(Expr*& e, Type* to) {
    if (e->type == tc_.pendingCase() && pendingCond(e)) {
        auto* c = static_cast<CondExpr*>(e);
        unionConvertPending(c->a, to);
        unionConvertPending(c->b, to);
        e->type = c->a->type->isError() || c->b->type->isError() ? tc_.error() : to;
        return true;
    }
    if (!e->lowered || e->lowered->kind != EK::UnionCase) return false;
    auto* u = static_cast<UnionCaseExpr*>(e->lowered);
    if (!to->isAggregate() || !to->decl || to->decl->templateOf != u->tmpl) {
        diag.error(e->loc, "cannot convert case '" + u->name + "' of '" + baseName(u->tmpl) + "' to '" + to->str() +
                               "'");
        e->type = tc_.error();
        return true;
    }
    Expr* built = unionBuild(to->decl, u, e->loc);
    if (!built) {
        e->type = tc_.error();
        return true;
    }
    e = built;
    return true;
}

// Brazo de 'c ? a : b': un caso sin tipo (Ok(1), None) se deja pendiente; lo demás, como un operando.
Type* Sema::unionCondOperand(Expr* e) {
    check(e);
    if (e->type == tc_.pendingCase()) return e->type;
    if (e->vk == ValKind::MethodGroup && !e->group.empty()) return e->type = tc_.pendingGroup();
    return requireValue(e);
}

// Inferencia de un método genérico desde el retorno de una lambda que construye un caso sin tipo:
// AndThen<U>(Func<T, Result<U, E>>) con x => x > 3 ? Ok(x) : Err("e") da U = int (de 'Ok(T Value)').
bool Sema::unionInferReturn(Expr* e, TypeRef* ret, MethodDecl* tmpl, std::map<std::string, Type*>& b) {
    if (!e || e->type != tc_.pendingCase()) return false;
    if (pendingCond(e)) {
        auto* c = static_cast<CondExpr*>(e);
        bool x = unionInferReturn(c->a, ret, tmpl, b);
        bool y = unionInferReturn(c->b, ret, tmpl, b);
        return x || y;
    }
    if (!e->lowered || e->lowered->kind != EK::UnionCase) return false;
    auto* u = static_cast<UnionCaseExpr*>(e->lowered);
    ClassDecl* tm = u->tmpl;
    if (!ret || ret->parts.empty() || ret->parts.back() != baseName(tm) || ret->typeArgs.size() != tm->typeParams.size())
        return false;
    int k = tm->unionInfo->find(u->name);
    if (k < 0) return false;
    const UnionCaseInfo& uc = tm->unionInfo->cases[k];
    size_t before = b.size();
    for (size_t i = 0; i < uc.fields.size() && i < u->args.size(); i++) {
        TypeRef* ft = uc.fields[i].tref;
        Type* at = u->args[i]->type;
        if (!ft || ft->parts.size() != 1 || !ft->typeArgs.empty() || ft->ptrDepth || !at || at->isPending() || at->isError() ||
            at->is(TK::Null))
            continue;
        for (size_t j = 0; j < tm->typeParams.size(); j++)
            if (tm->typeParams[j] == ft->parts[0]) unify(ret->typeArgs[j], at, tmpl, b);
    }
    return b.size() > before;
}

// var x = None;  (sin destino): el tipo inferido de los argumentos, si lo hay.
bool Sema::unionNaturalType(Expr* e) {
    if (e->type == tc_.pendingCase() && pendingCond(e)) return unionNaturalType(static_cast<CondExpr*>(e)->a);
    if (!e->lowered || e->lowered->kind != EK::UnionCase) return false;
    auto* u = static_cast<UnionCaseExpr*>(e->lowered);
    diag.error(e->loc, "cannot infer the type of '" + u->name + "': specify the target type (" + baseName(u->tmpl) +
                           "<...> x = " + u->name + (u->hasCall ? "(...)" : "") + ";) or write " + baseName(u->tmpl) +
                           "<...>." + u->name);
    return true;
}

// x == None, Some(3) != x: el caso pendiente toma el tipo del otro operando.
void Sema::unionBinary(BinaryExpr* e, Type*& L, Type*& R) {
    if (e->op != "==" && e->op != "!=") return;
    auto pending = [](Expr* x) { return x->type && x->type->isPending() && x->lowered && x->lowered->kind == EK::UnionCase; };
    if (pending(e->rhs) && L->isAggregate() && L->decl && L->decl->unionInfo) {
        coerce(e->rhs, L);
        R = e->rhs->type;
    } else if (pending(e->lhs) && R->isAggregate() && R->decl && R->decl->unionInfo) {
        coerce(e->lhs, R);
        L = e->lhs->type;
    }
}

// ================================================================== patrones

Expr* Sema::unionPatternTest(Pattern* p, const SubjectFn& subj, Type* st) {
    std::vector<std::string> path;
    switch (p->kind) {
        case PK::Case: path = p->tref->parts; break;
        case PK::Type: case PK::Property:
            if (!p->tref) return nullptr;
            path = p->tref->parts;
            break;
        case PK::Constant:
            if (!exprPath(p->value, path)) return nullptr;
            break;
        default: return nullptr;
    }
    SourceLoc l = p->loc;
    UnionInfo* ui = st && st->isAggregate() && st->decl ? st->decl->unionInfo : nullptr;
    if (!ui) {
        if (p->kind != PK::Case) return nullptr;
        if (!st->isError())
            diag.error(l, "the pattern '" + p->tref->str() + "(...)' is for a union case, but the value is of type '" +
                              st->str() + "'");
        return mkBool(false, l);
    }
    ClassDecl* c = st->decl;
    const std::string& last = path.back();
    if (last == kCompletionMarker) {  // case |  /  Forma.|  : los casos de la unión
        for (const UnionCaseInfo& uc : ui->cases) addCompletion(uc.name, 20, baseName(c) + "." + caseShape(uc, true));
        return mkBool(false, l);
    }
    int k = ui->find(last);
    bool prefixOk = path.size() < 2 || path[path.size() - 2] == baseName(c);
    if (k < 0 || !prefixOk) {
        if (p->kind != PK::Case) return nullptr;
        std::string list;
        for (const UnionCaseInfo& uc : ui->cases) list += (list.empty() ? "" : ", ") + uc.name;
        diag.error(l, "'" + c->displayName + "' does not have case '" + p->tref->str() + "' (its cases: " + list + ")");
        return mkBool(false, l);
    }
    const UnionCaseInfo& uc = ui->cases[k];
    if (ideMode) {
        std::string shown;
        for (const std::string& s : path) shown += (shown.empty() ? "" : ".") + s;
        addRef(l, (int)shown.size(), "(case of " + baseName(c) + ") " + caseShape(uc, true), &uc.loc);
    }
    SourceLoc hid = l;  // miembros internos: sin hover ni 'ir a la definición'
    hid.file = -1;
    Expr* test = mkBin("==", mkMember(subj(), "__caso", hid), mkInt(k, l), l);
    if (ui->isRef) test = mkBin("&&", mkBin("!=", subj(), new NullExpr(l), l), test, l);
    auto field = [&](const std::string& name) -> FieldDecl* { return findField(c, unionFieldName(uc.name, name)); };
    auto conj = [&](Expr* t) { test = mkBin("&&", test, t, l); };
    if (p->kind == PK::Case) {
        if (p->elems.size() != uc.fields.size()) {
            diag.error(l, "case '" + caseShape(uc, true) + "' has " + std::to_string(uc.fields.size()) +
                              " field(s), but the pattern has " + std::to_string(p->elems.size()));
            return mkBool(false, l);
        }
        for (size_t i = 0; i < p->elems.size(); i++) {
            FieldDecl* f = field(uc.fields[i].name);
            if (!f || !f->type) return mkBool(false, l);
            std::string fname = f->name;
            SubjectFn sub = [&, fname, hid]() -> Expr* { return mkMember(subj(), fname, hid); };
            conj(patternTest(p->elems[i], sub, f->type));
        }
    } else if (p->kind == PK::Property) {
        for (size_t i = 0; i < p->props.size(); i++) {
            const std::string& name = p->props[i].first;
            SourceLoc nl = i < p->propLocs.size() ? p->propLocs[i] : l;
            FieldDecl* f = field(name);
            if (!f || !f->type) {
                std::string list;
                for (const Param& fp : uc.fields) list += (list.empty() ? "" : ", ") + fp.name;
                diag.error(nl, "case '" + uc.name + "' does not have field '" + name + "'" +
                                   (list.empty() ? " (it has no fields)" : " (its fields: " + list + ")"));
                return mkBool(false, l);
            }
            if (ideMode) addRef(nl, (int)name.size(), "(field of " + uc.name + ") " + f->type->str() + " " + name, &uc.loc);
            std::string fname = f->name;
            SubjectFn sub = [&, fname, hid]() -> Expr* { return mkMember(subj(), fname, hid); };
            conj(patternTest(p->props[i].second, sub, f->type));
        }
    }
    if (!p->name.empty()) conj(bindPatternVar(p, p->name, st, subj()));
    return test;
}

namespace {

// ¿Cubre el patrón todos los valores de 't'? Marca en 'cov' los casos de la unión que cubre por completo.
bool covers(Pattern* p, Type* t, std::vector<bool>& cov) {
    UnionInfo* ui = t && t->isAggregate() && t->decl ? t->decl->unionInfo : nullptr;
    auto caseOf = [&](const std::vector<std::string>& path) -> int {
        if (!ui || path.empty()) return -1;
        int k = ui->find(path.back());
        if (k < 0) return -1;
        if (path.size() >= 2 && path[path.size() - 2] != baseName(t->decl)) return -1;
        return k;
    };
    auto fieldType = [&](int k, size_t i) -> Type* {
        const UnionCaseInfo& uc = ui->cases[k];
        std::string n = unionFieldName(uc.name, uc.fields[i].name);
        for (FieldDecl* f : t->decl->fields)
            if (f->name == n) return f->type;
        return nullptr;
    };
    switch (p->kind) {
        case PK::Discard: case PK::Var: return true;
        case PK::Or: {
            std::vector<bool> a(cov.size()), b(cov.size());
            bool all = covers(p->a, t, a) | covers(p->b, t, b);
            for (size_t i = 0; i < cov.size(); i++) cov[i] = cov[i] || a[i] || b[i];
            return all;
        }
        case PK::And: {
            std::vector<bool> a(cov.size()), b(cov.size());
            bool aa = covers(p->a, t, a), bb = covers(p->b, t, b);
            for (size_t i = 0; i < cov.size(); i++) cov[i] = cov[i] || (aa ? b[i] : bb ? a[i] : a[i] && b[i]);
            return aa && bb;
        }
        case PK::Constant: {
            std::vector<std::string> path;
            if (!exprPath(p->value, path)) return false;
            int k = caseOf(path);
            if (k >= 0) cov[k] = true;
            return false;
        }
        case PK::Type: case PK::Property: case PK::Case: {
            if (!p->tref) return p->kind == PK::Property && p->props.empty() && !(t && t->isRefLike());
            int k = caseOf(p->tref->parts);
            if (k < 0) {  // el propio tipo de la unión: 'Forma f'
                return p->kind == PK::Type && t && t->decl && ui && p->tref->parts.back() == baseName(t->decl) &&
                       !ui->isRef;
            }
            bool full = true;
            if (p->kind == PK::Case) {
                if (p->elems.size() != ui->cases[k].fields.size()) return false;
                for (size_t i = 0; i < p->elems.size(); i++) {
                    Type* ft = fieldType(k, i);
                    std::vector<bool> sub(ft && ft->isAggregate() && ft->decl && ft->decl->unionInfo
                                              ? ft->decl->unionInfo->cases.size() : 0);
                    if (!covers(p->elems[i], ft, sub)) {
                        bool allSub = !sub.empty();
                        for (bool x : sub) allSub = allSub && x;
                        if (!allSub) full = false;
                    }
                }
            } else if (p->kind == PK::Property) {
                for (auto& pr : p->props) {
                    std::vector<bool> sub;
                    if (!covers(pr.second, nullptr, sub)) full = false;
                }
            }
            if (full) cov[k] = true;
            return false;
        }
        default: return false;
    }
}


// ---- exhaustividad con patrones anidados (matriz de patrones, como en Rust / ML)
// Cada fila es un brazo sin guarda; cada columna, un valor (de tipo 'types[i]') que se compara.
// Si no es exhaustiva, 'witness' recibe un valor de ejemplo por columna que ningún brazo cubre.
using Row = std::vector<Pattern*>;

bool irrefutable(Pattern* p, Type* t) {
    if (!p) return true;
    switch (p->kind) {
        case PK::Discard: case PK::Var: return true;
        case PK::Property: return !p->tref && p->props.empty() && !(t && t->isRefLike());
        case PK::Type: {
            UnionInfo* ui = t && t->isAggregate() && t->decl ? t->decl->unionInfo : nullptr;
            return ui && !ui->isRef && p->tref && p->tref->parts.back() == baseName(t->decl);
        }
        case PK::Or: return irrefutable(p->a, t) || irrefutable(p->b, t);
        case PK::And: return irrefutable(p->a, t) && irrefutable(p->b, t);
        default: return false;
    }
}

// Expande los 'or' de la primera columna (una fila por alternativa) y simplifica los 'and'.
void expandFirst(const Row& r, Type* t, std::vector<Row>& out) {
    Pattern* p = r[0];
    if (p && p->kind == PK::Or) {
        Row a = r, b = r;
        a[0] = p->a;
        b[0] = p->b;
        expandFirst(a, t, out);
        expandFirst(b, t, out);
        return;
    }
    if (p && p->kind == PK::And) {
        Row x = r;
        if (irrefutable(p->a, t)) x[0] = p->b;
        else if (irrefutable(p->b, t)) x[0] = p->a;
        else return;  // conservador: no se sabe qué cubre
        expandFirst(x, t, out);
        return;
    }
    out.push_back(r);
}

bool exhaustiveRows(const std::vector<Row>& rowsIn, const std::vector<Type*>& types, std::vector<std::string>& witness,
                    int depth, std::vector<std::string>* allMissing = nullptr) {
    if (types.empty()) return !rowsIn.empty();
    if (depth > 32) return true;  // anidamiento absurdo: no se sigue comprobando
    Type* t = types[0];
    std::vector<Row> rows;
    for (const Row& r : rowsIn) expandFirst(r, t, rows);
    std::vector<Type*> restTypes(types.begin() + 1, types.end());
    UnionInfo* ui = t && t->isAggregate() && t->decl ? t->decl->unionInfo : nullptr;
    bool anyCase = false;  // si ningún brazo distingue casos, la columna no aporta nada (y en una unión
    for (const Row& r : rows) // recursiva no se baja por sus campos sin fin)
        if (!irrefutable(r[0], t)) anyCase = true;
    if (!ui || !anyCase) {  // otro tipo: solo cuentan los patrones que lo cubren todo
        std::vector<Row> rest;
        for (const Row& r : rows)
            if (irrefutable(r[0], t)) rest.emplace_back(r.begin() + 1, r.end());
        std::vector<std::string> w;
        if (exhaustiveRows(rest, restTypes, w, depth + 1)) return true;
        witness = {"_"};
        witness.insert(witness.end(), w.begin(), w.end());
        return false;
    }
    auto caseOf = [&](const std::vector<std::string>& path) -> int {
        if (path.empty()) return -1;
        int k = ui->find(path.back());
        if (k < 0) return -1;
        if (path.size() >= 2 && path[path.size() - 2] != baseName(t->decl)) return -1;
        return k;
    };
    auto fieldType = [&](int k, size_t i) -> Type* {
        const UnionCaseInfo& uc = ui->cases[k];
        std::string n = unionFieldName(uc.name, uc.fields[i].name);
        for (FieldDecl* f : t->decl->fields)
            if (f->name == n) return f->type;
        return nullptr;
    };
    for (size_t k = 0; k < ui->cases.size(); k++) {
        const UnionCaseInfo& uc = ui->cases[k];
        size_t nf = uc.fields.size();
        std::vector<Row> spec;
        for (const Row& r : rows) {
            Pattern* p = r[0];
            Row sub(nf, nullptr);  // nulo = '_'
            bool keep = false;
            if (irrefutable(p, t)) keep = true;
            else if (p->kind == PK::Constant) {
                std::vector<std::string> path;
                keep = exprPath(p->value, path) && caseOf(path) == (int)k;
            } else if ((p->kind == PK::Type || p->kind == PK::Property || p->kind == PK::Case) && p->tref &&
                       caseOf(p->tref->parts) == (int)k) {
                keep = true;
                if (p->kind == PK::Case) {
                    if (p->elems.size() != nf) keep = false;
                    else for (size_t i = 0; i < nf; i++) sub[i] = p->elems[i];
                } else if (p->kind == PK::Property) {
                    for (auto& pr : p->props) {
                        size_t i = 0;
                        while (i < nf && uc.fields[i].name != pr.first) i++;
                        if (i == nf) { keep = false; break; }
                        sub[i] = pr.second;
                    }
                }
            }
            if (!keep) continue;
            for (Pattern*& q : sub)
                if (!q) q = new Pattern(PK::Discard, p->loc);
            sub.insert(sub.end(), r.begin() + 1, r.end());
            spec.push_back(sub);
        }
        std::vector<Type*> st;
        for (size_t i = 0; i < nf; i++) st.push_back(fieldType((int)k, i));
        st.insert(st.end(), restTypes.begin(), restTypes.end());
        std::vector<std::string> w;
        if (exhaustiveRows(spec, st, w, depth + 1)) continue;
        std::string c = uc.name;
        if (nf) {
            c += "(";
            for (size_t i = 0; i < nf; i++) c += (i ? ", " : "") + (i < w.size() ? w[i] : std::string("_"));
            c += ")";
        }
        if (allMissing) {  // nivel superior: se enumeran todos los casos que faltan
            allMissing->push_back(c);
            continue;
        }
        witness = {c};
        witness.insert(witness.end(), w.begin() + (long)std::min(nf, w.size()), w.end());
        return false;
    }
    return !allMissing || allMissing->empty();
}

}  // namespace

void Sema::unionExhaustive(Type* st, const std::vector<std::pair<Pattern*, Expr*>>& arms, SourceLoc loc, bool isExpr) {
    if (!st || !st->isAggregate() || !st->decl || !st->decl->unionInfo) return;
    UnionInfo* ui = st->decl->unionInfo;
    std::vector<bool> cov(ui->cases.size());
    bool all = false;
    for (auto& [pat, guard] : arms) {
        std::vector<bool> c(cov.size());
        bool a = covers(pat, st, c);
        if (guard) continue;  // con 'when' no cubre nada seguro
        bool any = a, news = a;
        for (size_t i = 0; i < c.size(); i++) {
            any = any || c[i];
            if (c[i] && !cov[i]) news = true;
        }
        if (any && !news && !all && !a) {
            bool prevAll = true;
            for (bool x : cov) prevAll = prevAll && x;
            diag.error(pat->loc, prevAll ? "this 'switch' arm is never reached: the earlier ones already cover all cases"
                                         : "this pattern never matches: the earlier ones already cover its cases");
        }
        if (a) all = true;
        for (size_t i = 0; i < c.size(); i++) cov[i] = cov[i] || c[i] || a;
    }
    if (all) return;
    // Matriz de patrones anidados (Some(Some(var x)) y Some(None) cubren juntos Some(_)).
    std::vector<Row> rows;
    for (auto& [pat, guard] : arms)
        if (!guard) rows.push_back({pat});
    std::vector<std::string> w, list;
    if (exhaustiveRows(rows, {st}, w, 0, &list)) return;
    std::string missing;
    int n = 0;
    for (auto& m : list) {
        missing += (missing.empty() ? "" : ", ") + m;
        n++;
    }
    diag.error(loc, "the 'switch' over '" + st->str() + "' is not exhaustive: " + (n == 1 ? "missing case " : "missing cases ") +
                        missing + (isExpr ? " (add their arms or '_ => ...')" : " (add their 'case' or 'default:')"));
}

// ================================================================== operador '?'

Type* Sema::checkPropagate(PropagateExpr* e) {
    if (e->done) return e->type ? e->type : tc_.error();
    e->done = true;
    SourceLoc loc = e->loc;
    Type* ot = checkValue(e->operand);
    if (ot->isError()) return ot;
    bool isOpt = unionStd(ot, "Option"), isRes = unionStd(ot, "Result");
    if (!isOpt && !isRes) {
        diag.error(loc, "the '?' operator needs a Result<T, E> or an Option<T> (the value is of type '" + ot->str() + "')");
        return tc_.error();
    }
    // Tipo que devuelve la función actual (T de Task<T> en un método o lambda async).
    Type* R = nullptr;
    LambdaExpr* lam = lambdaStack_.empty() ? nullptr : lambdaStack_.back();
    if (lam && lam->exprBody) {
        diag.error(loc, "the '?' operator cannot be used in an expression lambda: use a block body "
                        "(x => { return F(x)?; })");
        return tc_.error();
    }
    if (ctx_.async) R = ctx_.async->result;
    else if (lam) R = lam->ret;
    else if (ctx_.method) R = ctx_.method->ret;
    if (!R) {
        diag.error(loc, "the '?' operator needs to know the type the lambda returns (declare it with a delegate type: "
                        "Func<string, Result<int, string>> f = ...)");
        return tc_.error();
    }
    if (R->isError()) return R;
    const char* want = isOpt ? "Option" : "Result";
    if (!unionStd(R, want)) {
        diag.error(loc, std::string("the '?' operator over a ") + want + " can only be used in a method that returns " +
                            (isOpt ? "Option<T>" : "Result<T, E>") + " (this one returns '" + R->str() + "')" +
                            (isOpt && unionStd(R, "Result") ? "; convert the Option with .OkOr(error)?"
                             : !isOpt && unionStd(R, "Option") ? "; convert the Result with .ToOption()?" : ""));
        return tc_.error();
    }
    UnionInfo* ui = ot->decl->unionInfo;
    int kVal = ui->find(isOpt ? "Some" : "Ok"), kErr = ui->find(isOpt ? "None" : "Err");
    if (kVal < 0 || kErr < 0 || ui->cases[kVal].fields.size() != 1) return tc_.error();
    e->tmp = hiddenLocal(ot, loc, false);
    SourceLoc hid = loc;  // miembros internos: sin hover
    hid.file = -1;
    e->value = mkMember(refTo(e->tmp, loc), unionFieldName(ui->cases[kVal].name, ui->cases[kVal].fields[0].name), hid);
    Type* vt = checkValue(e->value);
    e->test = mkBin("==", mkMember(refTo(e->tmp, loc), "__caso", hid), mkInt(kErr, loc), loc);
    checkCondition(e->test);
    // Valor de retorno (sin comprobar: lo comprueba el 'return' con las reglas normales).
    Expr* ret = nullptr;
    if (isOpt) {
        ret = mkMember(typeNameExpr(R, loc), "None", loc);
    } else {
        const UnionCaseInfo& ec = ui->cases[kErr];
        if (ec.fields.size() != 1) return tc_.error();
        std::string errField = unionFieldName(ec.name, ec.fields[0].name);
        Type* E = ot->decl->typeArgs.size() == 2 ? ot->decl->typeArgs[1] : nullptr;
        Type* F = R->decl->typeArgs.size() == 2 ? R->decl->typeArgs[1] : nullptr;
        if (!E || !F) return tc_.error();
        Expr* err = mkMember(refTo(e->tmp, loc), errField, hid);
        if (E != F && !canImplicit(nullptr, E, F)) {
            // Convención 'From': static F From(E e) en el tipo de error de destino.
            MethodDecl* from = nullptr;
            if (F->isAggregate())
                for (MethodDecl* m : findMethods(F->decl, "From")) {
                    if (!m->isStatic() || m->params.size() != 1) continue;
                    resolveMethodSignature(m);
                    if (m->params[0].type && canImplicit(nullptr, E, m->params[0].type) && m->ret == F) from = m;
                }
            if (!from) {
                bool own = F->isAggregate() && F->decl && F->decl->loc.file >= 0 && !F->decl->templateOf;
                diag.error(loc, "the '?' operator cannot convert the error '" + E->str() + "' to '" + F->str() +
                                    "' (the method returns '" + R->str() + "'): " +
                                    (own ? "add 'public static " + F->str() + " From(" + E->str() + " e)' to " + F->str() + " or " : "") +
                                    "convert it first with .MapErr(...)");
                return tc_.error();
            }
            err = mkCall(mkMember(typeNameExpr(F, loc), "From", loc), {err}, loc);
        }
        ret = mkCall(mkMember(typeNameExpr(R, loc), "Err", loc), {err}, loc);
    }
    auto* early = new BlockStmt(loc);
    // errdefer: las marcas de las zonas 'errdefer' abiertas de esta función (Flow.cpp)
    for (auto& scope : ctx_.scopes)
        for (auto& [name, v] : scope)
            if (name.rfind("__errdefer", 0) == 0 && v->fnDepth == (int)lambdaStack_.size()) {
                auto* a = new AssignExpr(loc);
                a->op = "=";
                a->lhs = refTo(v, loc);
                a->rhs = mkBool(true, loc);
                auto* es = new ExprStmt(loc);
                es->expr = a;
                early->stmts.push_back(es);
            }
    auto* rs = new ReturnStmt(loc);
    rs->value = ret;
    early->stmts.push_back(rs);
    checkStmt(early);
    e->early = early;
    propagateCount_++;
    if (trialDepth_ == 0) propagates_.push_back(e);
    if (ideMode)
        addRef(loc, 1, std::string("? : if it is ") + (isOpt ? "None" : "Err") + ", returns " + (isOpt ? "None" : "the error") +
                           " from here; otherwise gives '" + vt->str() + "'", nullptr);
    return vt;
}

// r?.Campo con un Result/Option: (r?).Campo (como en Rust).
Type* Sema::propagateCondAccess(CondAccessExpr* e, Type* O) {
    if (!unionStd(O, "Option") && !unionStd(O, "Result")) return nullptr;
    Expr** slot = findRecv(&e->access);
    if (!slot) return nullptr;
    auto* p = new PropagateExpr(e->loc);
    p->operand = e->obj;
    // El operando ya está comprobado: se evita volver a comprobarlo.
    auto* hold = new LetExpr(e->obj->loc);
    hold->seq.push_back(e->obj);
    hold->type = O;
    p->operand = hold;
    p->type = checkPropagate(p);
    *slot = p;
    Type* A = checkValue(e->access);
    e->lowered = e->access;
    return A;
}

// Saca 'e?' de su expresión: <t> = operando; if (<t> es Err/None) { return ...; }  y queda <t>.Value.
Expr* Sema::propagateSpill(PropagateExpr* e, std::vector<Stmt*>& pre) {
    pre.push_back(bindDecl(e->tmp, e->operand));
    auto* is = new IfStmt(e->loc);
    is->cond = e->test;
    is->then = e->early;
    pre.push_back(is);
    e->spilled = true;
    return e->value;
}

void Sema::propagateValidate() {
    for (PropagateExpr* e : propagates_)
        if (!e->spilled && e->value && e->type && !e->type->isError())
            diag.error(e->loc, "'?' cannot be used in this position (inside '?.' or '?\?=', in the condition or "
                               "increment of a 'for', in the condition of a 'do-while', or in a field initializer); "
                               "store the result in a variable first: var x = expr?;");
    propagates_.clear();
}

// ================================================================== CodeGen: ToString, GetHashCode y ==

void CodeGen::emitUnionBody(MethodDecl* m) {
    ClassDecl* c = m->owner;
    UnionInfo* ui = c->unionInfo;
    bool isClass = c->kind == ClassKind::Class;
    auto field = [&](const UnionCaseInfo& uc, const Param& p) -> FieldDecl* {
        std::string n = unionFieldName(uc.name, p.name);
        for (FieldDecl* f : c->fields)
            if (f->name == n) return f;
        return nullptr;
    };
    FieldDecl* tag = nullptr;
    for (FieldDecl* f : c->fields)
        if (f->name == "__caso") tag = f;
    if (!tag) return;
    std::string acc = "self->";
    if (m->recordGen == 4) {  // ToString: Circulo(2.5), Rect(3, 4), Punto
        line("faset_string s;");
        line("switch (" + acc + fieldPath(c, tag) + ") {");
        for (size_t k = 0; k < ui->cases.size(); k++) {
            const UnionCaseInfo& uc = ui->cases[k];
            std::string head = uc.name + (uc.unit() ? "" : "(");
            line("case " + std::to_string(k) + ":");
            indent_++;
            line("s = FASET_STR(" + cstring(head) + ", " + std::to_string(head.size()) + ");");
            for (size_t i = 0; i < uc.fields.size(); i++) {
                FieldDecl* f = field(uc, uc.fields[i]);
                if (!f) continue;
                if (i) line("s = faset_str_concat(s, FASET_STR(\", \", 2));");
                line("s = faset_str_concat(s, " + strOf(f->type, acc + fieldPath(c, f)) + ");");
            }
            if (!uc.unit()) line("s = faset_str_concat(s, FASET_STR(\")\", 1));");
            line("return s;");
            indent_--;
        }
        line("default: return FASET_STR(\"\", 0);");
        line("}");
    } else if (m->recordGen == 5) {  // GetHashCode: el caso y sus campos
        line("uint32_t h = 17u + (uint32_t)" + acc + fieldPath(c, tag) + " * 2654435761u;");
        line("switch (" + acc + fieldPath(c, tag) + ") {");
        for (size_t k = 0; k < ui->cases.size(); k++) {
            const UnionCaseInfo& uc = ui->cases[k];
            if (uc.unit()) continue;
            line("case " + std::to_string(k) + ":");
            indent_++;
            for (const Param& p : uc.fields)
                if (FieldDecl* f = field(uc, p)) line("h = h * 31u + (uint32_t)" + hashOf(f->type, acc + fieldPath(c, f)) + ";");
            line("break;");
            indent_--;
        }
        line("default: break;");
        line("}");
        line("return (int32_t)h;");
    } else if (m->recordGen == 6) {  // ==: mismo caso y mismos campos
        std::string a = "p_" + m->params[0].name, b = "p_" + m->params[1].name;
        std::string dot = isClass ? "->" : ".";
        if (isClass) {
            line("if (" + a + " == " + b + ") return 1;");
            line("if (!" + a + " || !" + b + ") return 0;");
        }
        line("if (" + a + dot + fieldPath(c, tag) + " != " + b + dot + fieldPath(c, tag) + ") return 0;");
        line("switch (" + a + dot + fieldPath(c, tag) + ") {");
        for (size_t k = 0; k < ui->cases.size(); k++) {
            const UnionCaseInfo& uc = ui->cases[k];
            if (uc.unit()) continue;
            std::string s;
            for (const Param& p : uc.fields)
                if (FieldDecl* f = field(uc, p))
                    s += (s.empty() ? "" : " && ") + eqOf(f->type, a + dot + fieldPath(c, f), b + dot + fieldPath(c, f));
            line("case " + std::to_string(k) + ": return " + (s.empty() ? std::string("1") : s) + ";");
        }
        line("default: return 1;");
        line("}");
    }
}
