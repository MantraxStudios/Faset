// Faset - arreglos (T[]), arreglos multidimensionales, índices (^i), rangos (a..b), expresiones de
// colección ([1, 2, ..otra]) y patrones de lista ([1, .., var x]): análisis semántico.
//
// Representación: T[] es una instancia de la clase std.Array<T> de lib/std/arrays.fst (T[,] y
// T[,,] de Array2D<T> / Array3D<T>). Así un arreglo es un objeto del recolector como cualquier
// otro y funciona sin más con genéricos, tuplas, lambdas, async, excepciones y 'object'. El
// parser escribe T[] como el tipo std.Array<T> (TypeRef::arrayRank solo sirve para mostrarlo) y
// Sema muestra 'int[]' en vez de 'Array<int>'. Igual que en Sugar.cpp, casi todo se reescribe
// (campo 'lowered') en construcciones que el resto del compilador ya sabe comprobar y emitir:
//
//   new T[n]                    ->  new Array<T>(n)        (T* si el destino es un puntero, en memory_unsafe)
//   new T[a, b]                 ->  new Array2D<T>(a, b)
//   [e1, e2] / { e1, e2 }       ->  (<t> = new T[2], <t>[0] = e1, <t>[1] = e2, <t>)   (según el destino:
//                                    T[], List<T>, HashSet<T>, Span<T>, ReadOnlySpan<T>, Dictionary<K, V>
//                                    o cualquier clase con Add)
//   [a, ..xs, b]                ->  una List<T> (Add/AddRange) y .ToArray() si el destino es T[]
//   ^n                          ->  new Index(n, true)
//   a..b                        ->  new Range(new Index(a, false), new Index(b, false))
//   s[^1], s[1..3] (string)     ->  s.At(^1), s.Slice(1..3)          (los arreglos, List<T> y Span<T>
//                                                                     tienen operator[](Index/Range))
//   foreach (x in arreglo)      ->  for (<i> = 0; <i> < <n>; <i>++) { x = <a>[<i>]; ... }
//   x is [1, .., var y]         ->  x != null && x.Length >= 2 && x[0] == 1 && (y = x[x.Length - 1], true)
//
// Las expresiones de colección no tienen tipo propio: como las lambdas, son "pendientes"
// (tc_.pendingCollection()) hasta que la conversión al destino (convertPending) las construye;
// la resolución de sobrecargas usa collectionCost. El acceso a[i] de un T[] lo emite CodeGen
// (CodeGenArrays.cpp) como una comprobación de límites y un acceso directo.
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

Expr* mkInt(int64_t v, SourceLoc loc) {
    auto* i = new IntLitExpr(loc);
    i->value = (uint64_t)v;
    return i;
}

Expr* mkBool(bool v, SourceLoc loc) {
    auto* b = new BoolLitExpr(loc);
    b->value = v;
    return b;
}

Expr* mkIndex(Expr* obj, Expr* index, SourceLoc loc) {
    auto* ix = new IndexExpr(loc);
    ix->obj = obj;
    ix->index = index;
    return ix;
}

Expr* mkAssign(Expr* lhs, Expr* rhs, SourceLoc loc) {
    auto* a = new AssignExpr(loc);
    a->op = "=";
    a->lhs = lhs;
    a->rhs = rhs;
    return a;
}

// 'new T(args)' sobre un tipo ya resuelto (sin texto en el código).
Expr* mkNew(Type* t, std::vector<Expr*> args, SourceLoc loc) {
    auto* n = new NewExpr(loc);
    n->tref = new TypeRef();
    n->tref->loc = loc;
    n->tref->preset = t;
    n->args = std::move(args);
    return n;
}

// Literales que se pueden volver a comprobar sin efectos (no necesitan un temporal).
bool isLiteral(Expr* e) {
    if (e->lowered) return false;
    switch (e->kind) {
        case EK::IntLit: case EK::FloatLit: case EK::BoolLit: case EK::CharLit: case EK::StringLit: case EK::Null:
            return true;
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            return u->op == "-" && !u->opMethod && (u->operand->kind == EK::IntLit || u->operand->kind == EK::FloatLit);
        }
        default: return false;
    }
}

const char* const kArrayTemplates[] = {"Array", "Array2D", "Array3D"};

}  // namespace

// ================================================================== tipos

ClassDecl* Sema::stdTemplate(const char* ns, const char* name) {
    NamespaceSym* n = getNs(ns, false);
    if (!n) return nullptr;
    auto it = n->types.find(name);
    if (it == n->types.end()) return nullptr;
    ClassDecl* c = it->second;
    if (!c->isTemplate() && c->arityTwin) c = c->arityTwin;  // Array (estática) / Array<T>
    return c->isTemplate() ? c : nullptr;
}

Type* Sema::stdType(const char* name) {
    NamespaceSym* n = getNs("std", false);
    if (!n) return nullptr;
    auto it = n->types.find(name);
    if (it == n->types.end() || it->second->isTemplate()) return nullptr;
    return it->second->type;
}

ClassDecl* Sema::arrayTemplate(int rank) {
    if (!arrayTmpl_[rank - 1]) arrayTmpl_[rank - 1] = stdTemplate("std", kArrayTemplates[rank - 1]);
    return arrayTmpl_[rank - 1];
}

Type* Sema::instanceOf(const char* ns, const char* name, const std::vector<Type*>& args, SourceLoc loc) {
    for (Type* a : args)
        if (a->isError()) return a;
    ClassDecl* t = stdTemplate(ns, name);
    if (!t) {
        diag.error(loc, std::string("missing type ") + ns + "." + name + " (standard library not found)");
        return tc_.error();
    }
    ClassDecl* inst = instantiate(t, args, loc);
    return inst ? inst->type : tc_.error();
}

Type* Sema::arrayOf(Type* elem, int rank, SourceLoc loc) {
    if (elem->isVoid()) {
        diag.error(loc, "cannot have arrays of 'void'");
        return tc_.error();
    }
    return instanceOf("std", kArrayTemplates[rank - 1], {elem}, loc);
}

// Al instanciar std.Array<T>: se muestra 'T[]' en los mensajes y en el IntelliSense.
void Sema::arrayInstantiated(ClassDecl* c) {
    ClassDecl* tm = c->templateOf;
    if (!tm || tm->ns != "std" || c->typeArgs.size() != 1) return;
    for (int r = 0; r < 3; r++)
        if (tm->name == kArrayTemplates[r]) c->displayName = c->typeArgs[0]->str() + "[" + std::string(r, ',') + "]";
}

// ================================================================== conversiones

namespace {
bool rawCandidate(Expr* e) {
    return e && e->kind == EK::NewArray && static_cast<NewArrayExpr*>(e)->moreCounts.empty();
}
}  // namespace

int Sema::arrayImplicit(Expr* e, Type* from, Type* to) {
    Type* fe = vectorElemOf(from);
    if (!fe) {
        if (Type* se = stdTemplateArg(from, "Span", "std"))  // Span<T> -> ReadOnlySpan<T>
            if (stdTemplateArg(to, "ReadOnlySpan", "std") == se) return 1;
        return -1;
    }
    // new T[n] en memory_unsafe con destino T* (o void*): memoria sin procesar, como antes de T[].
    if (to->isPointer() && rawCandidate(e) && unsafeCtx() && (to->elem == fe || to->isVoidPointer())) return 1;
    // T[] -> Span<T> / ReadOnlySpan<T>
    if (stdTemplateArg(to, "Span", "std") == fe || stdTemplateArg(to, "ReadOnlySpan", "std") == fe) return 1;
    return -1;
}

bool Sema::arrayCoerce(Expr*& e, Type* to) {
    Type* from = e->type;
    Type* fe = vectorElemOf(from);
    SourceLoc loc = e->loc;
    if (fe && to->isPointer() && rawCandidate(e) && unsafeCtx() && (to->elem == fe || to->isVoidPointer())) {
        auto* na = static_cast<NewArrayExpr*>(e);
        na->lowered = nullptr;  // ya no es new Array<T>(n)
        na->rawPointer = true;
        if (!na->count->type->is(TK::ULong)) coerce(na->count, tc_.get(TK::Long));
        na->type = tc_.pointerTo(fe);
        if (na->type != to) {
            auto* c = new CastExpr(loc);
            c->operand = na;
            c->implicit = true;
            c->type = to;
            e = c;
        }
        return true;
    }
    // string[] -> object[]: la covarianza de C# no existe (no es segura: a[0] = 5 fallaría al ejecutar).
    int fr = 0, tr = 0;
    Type* fa = arrayElemOf(from, &fr);
    Type* ta = arrayElemOf(to, &tr);
    if (fa && ta && fr == tr && fa != ta && (fa->isClass() || fa->is(TK::String)) &&
        (canImplicit(nullptr, fa, ta) || (objectDecl && ta == objectDecl->type))) {
        diag.error(loc, "arrays are not covariant in Faset: '" + from->str() + "' does not convert to '" + to->str() +
                            "' (create a new array, e.g. with Array.ConvertAll or a loop)");
        e->type = tc_.error();
        return true;
    }
    bool toSpan = fe && (stdTemplateArg(to, "Span", "std") == fe || stdTemplateArg(to, "ReadOnlySpan", "std") == fe);
    Type* se = stdTemplateArg(from, "Span", "std");
    bool toRo = se && stdTemplateArg(to, "ReadOnlySpan", "std") == se;
    if (!toSpan && !toRo) return false;
    // arreglo -> new Span<T>(arreglo);  Span<T> -> s.AsReadOnly()
    VarInfo* h = hiddenLocal(from, loc, true);
    Expr* conv = toSpan ? mkNew(to, {refTo(h, loc)}, loc) : mkCall(mkMember(refTo(h, loc), "AsReadOnly", loc), {}, loc);
    checkValue(conv);
    auto* let = new LetExpr(loc);
    let->binds.push_back({h, e});
    let->seq.push_back(conv);
    let->type = to;
    e = let;
    return true;
}

// ================================================================== new T[n], ^i, a..b

Type* Sema::checkArrayExpr(Expr* e) {
    switch (e->kind) {
        case EK::Collection: return checkCollection(static_cast<CollectionExpr*>(e));
        case EK::Range: return checkRange(static_cast<RangeExpr*>(e));
        case EK::FromEnd: {
            auto* f = static_cast<FromEndExpr*>(e);
            Type* idx = stdType("Index");
            if (!idx) {
                diag.error(e->loc, "'^' needs std.Index (standard library not found)");
                return tc_.error();
            }
            Expr* n = mkNew(idx, {f->operand, mkBool(true, e->loc)}, e->loc);
            Type* t = checkValue(n);
            f->lowered = n;
            return t;
        }
        default: return tc_.error();
    }
}

Type* Sema::checkNewArray(NewArrayExpr* na) {
    Type* elem = resolveType(na->elemRef);
    std::vector<Expr*> counts = {na->count};
    counts.insert(counts.end(), na->moreCounts.begin(), na->moreCounts.end());
    bool bad = elem->isError();
    for (Expr* c : counts) {
        Type* ct = checkValue(c);
        if (ct->isError()) {
            bad = true;
        } else if (!ct->isIntegral()) {
            diag.error(c->loc, "array size must be an integer (not '" + ct->str() + "')");
            bad = true;
        }
    }
    if (bad) return tc_.error();
    Type* arr = arrayOf(elem, (int)counts.size(), na->loc);
    if (arr->isError()) return arr;
    // new Array<T>(n) con los tamaños ya comprobados (no se vuelven a comprobar).
    MethodDecl* ctor = nullptr;
    for (MethodDecl* m : arr->decl->ctors)
        if (m->params.size() == counts.size()) ctor = m;
    if (!ctor) {
        diag.error(na->loc, "std." + arr->decl->templateOf->name + " does not have the expected constructor");
        return tc_.error();
    }
    auto* ne = new NewExpr(na->loc);
    ne->type = arr;
    ne->ctor = ctor;
    for (size_t i = 0; i < counts.size(); i++) {
        Expr* x = counts[i];
        Type* want = ctor->params[i].type;
        if (x->type->is(TK::ULong) || x->type->is(TK::UInt) || x->type->is(TK::Long)) {
            if (want->is(TK::Int) || x->type->is(TK::ULong)) {  // el constructor comprueba el tamaño
                auto* c = new CastExpr(x->loc);
                c->operand = x;
                c->type = tc_.get(TK::Long);
                x = c;
            }
        }
        if (x->type == tc_.get(TK::Long) && want->is(TK::Int)) {
            diag.error(x->loc, "the size of each dimension of a multidimensional array must be 'int'");
            return tc_.error();
        }
        coerce(x, want);
        ne->args.push_back(x);
    }
    useMethod(ctor, &na->loc);
    na->lowered = ne;
    return arr;
}

// a..b: new Range(Index, Index). Los extremos int se convierten en Index; se evalúan en orden.
Type* Sema::checkRange(RangeExpr* r) {
    Type* idx = stdType("Index");
    Type* rng = stdType("Range");
    if (!idx || !rng) {
        diag.error(r->loc, "'..' needs std.Index and std.Range (standard library not found)");
        return tc_.error();
    }
    SourceLoc loc = r->loc;
    auto* let = new LetExpr(loc);
    bool bad = false;
    auto endpoint = [&](Expr* x, bool isEnd) -> Expr* {
        if (!x) return mkNew(idx, {mkInt(0, loc), mkBool(isEnd, loc)}, loc);  // a.. / ..b
        Type* t = checkValue(x);
        if (t->isError()) {
            bad = true;
            return nullptr;
        }
        if (t != idx && !(t->isIntegral() && canImplicit(x, t, tc_.get(TK::Int)))) {
            diag.error(x->loc, "the endpoints of a range must be 'int' or 'Index' (not '" + t->str() + "')");
            bad = true;
            return nullptr;
        }
        VarInfo* h = hiddenLocal(t, x->loc, true);
        let->binds.push_back({h, x});
        if (t == idx) return refTo(h, x->loc);
        return mkNew(idx, {refTo(h, x->loc), mkBool(false, x->loc)}, x->loc);
    };
    Expr* s = endpoint(r->start, false);
    Expr* e = endpoint(r->end, true);
    if (bad) return tc_.error();
    Expr* n = mkNew(rng, {s, e}, loc);
    Type* t = checkValue(n);
    if (let->binds.empty()) {
        r->lowered = n;
        return t;
    }
    let->seq.push_back(n);
    let->type = t;
    r->lowered = let;
    return t;
}

// s[^1] y s[1..3] sobre string (los arreglos, List<T> y Span<T> lo resuelven con operator[]).
Type* Sema::arrayIndexHook(IndexExpr* ix, Type* ot, Type* it) {
    if (!ot->is(TK::String)) return nullptr;
    Type* idx = stdType("Index");
    Type* rng = stdType("Range");
    if (!it || (it != idx && it != rng) || !idx) return nullptr;
    SourceLoc loc = ix->loc;
    VarInfo* hs = hiddenLocal(ot, loc, true);
    VarInfo* hi = hiddenLocal(it, loc, true);
    Expr* call = mkCall(mkMember(refTo(hs, loc), it == rng ? "Slice" : "At", loc), {refTo(hi, loc)}, loc);
    Type* t = checkValue(call);
    auto* let = new LetExpr(loc);
    let->binds.push_back({hs, ix->obj});
    let->binds.push_back({hi, ix->index});
    let->seq.push_back(call);
    let->type = t;
    ix->lowered = let;
    return t;
}

// ================================================================== expresiones de colección

Sema::CollTarget Sema::collTarget(Type* to) {
    CollTarget r;
    if (!to || !to->isAggregate()) return r;
    int rank = 1;
    if (Type* e = arrayElemOf(to, &rank)) {
        r.kind = 1;
        r.elem = e;
        r.rank = rank;
    } else if (Type* e = stdTemplateArg(to, "List", "std.collections")) {
        r.kind = 2;
        r.elem = e;
    } else if (Type* e = stdTemplateArg(to, "HashSet", "std.collections")) {
        r.kind = 3;
        r.elem = e;
    } else if (Type* e = stdTemplateArg(to, "Span", "std")) {
        r.kind = 4;
        r.elem = e;
    } else if (Type* e = stdTemplateArg(to, "ReadOnlySpan", "std")) {
        r.kind = 5;
        r.elem = e;
    } else if (Type* k = stdTemplateArg(to, "Dictionary", "std.collections")) {
        r.kind = 6;
        r.key = k;
        r.elem = stdTemplateArg(to, "Dictionary", "std.collections", 1);
    } else if (to->isClass() && !to->decl->isInterface() && !to->decl->mods.isAbstract &&
               (to->decl->ctors.empty() || paramlessCtor(to->decl))) {
        // Cualquier clase con un constructor sin parámetros y un único Add(T) (como en C#).
        MethodDecl* add = nullptr;
        int n = 0;
        for (MethodDecl* m : findMethods(to->decl, "Add"))
            if (!m->isStatic() && !m->isTemplate() && m->params.size() == 1 && m->params[0].type) {
                add = m;
                n++;
            }
        if (n == 1) {
            r.kind = 7;
            r.elem = add->params[0].type;
        }
    }
    return r;
}

// Elemento de lo que se puede expandir con '..': T[], List<T>, HashSet<T>, Span<T>, ReadOnlySpan<T>.
Type* Sema::spreadElem(Type* t) {
    if (Type* e = vectorElemOf(t)) return e;
    if (Type* e = stdTemplateArg(t, "List", "std.collections")) return e;
    if (Type* e = stdTemplateArg(t, "HashSet", "std.collections")) return e;
    if (Type* e = stdTemplateArg(t, "Span", "std")) return e;
    if (Type* e = stdTemplateArg(t, "ReadOnlySpan", "std")) return e;
    return nullptr;
}

Type* Sema::checkCollection(CollectionExpr* c) {
    for (auto& el : c->elems) {
        if (el.spread) {
            checkValue(el.value);
            continue;
        }
        if (el.key) checkValue(el.key);
        checkOperand(el.value);  // lambdas y colecciones anidadas quedan pendientes del destino
    }
    for (Expr* s : c->sizes) checkValue(s);
    if (!c->arrayRef) return tc_.pendingCollection();  // [1, 2, 3] / { 1, 2 }: tipo del destino

    // new T[] { ... } / new[] { ... } / new T[n] { ... }
    for (auto& el : c->elems)
        if (el.spread || el.key) {
            diag.error(el.loc, "an array initializer { ... } does not allow '..' or 'key: value' (use [ ... ])");
            return tc_.error();
        }
    int rank = c->arrayRef->arrayRank;
    Type* arr;
    if (c->implicitNew) {  // el mejor tipo común de los elementos
        std::vector<Expr*> leaves;
        std::function<void(CollectionExpr*, int)> walk = [&](CollectionExpr* k, int level) {
            for (auto& el : k->elems) {
                if (level + 1 < rank && el.value->kind == EK::Collection) walk(static_cast<CollectionExpr*>(el.value), level + 1);
                else leaves.push_back(el.value);
            }
        };
        walk(c, 0);
        Type* best = nullptr;
        for (Expr* cand : leaves) {
            Type* t = cand->type;
            if (!t || t->isError() || t->isPending() || t->is(TK::Null)) continue;
            bool all = true;
            for (Expr* x : leaves)
                if (!x->type || (!x->type->isError() && !canImplicit(x, x->type, t))) all = false;
            if (all) {
                best = t;
                break;
            }
        }
        if (!best) {
            for (Expr* x : leaves)
                if (x->type && x->type->isError()) return tc_.error();
            diag.error(c->loc, "cannot infer the type of the elements of 'new[]': specify the type (new int[] { ... })");
            return tc_.error();
        }
        arr = arrayOf(best, rank, c->loc);
    } else {
        arr = resolveType(c->arrayRef);
    }
    if (arr->isError()) return arr;
    if (!c->sizes.empty()) {  // new int[3] { 1, 2, 3 }: el tamaño debe coincidir
        std::vector<int> dims;
        if (rectCost(c, nullptr, rank, dims, 0) >= 0)
            for (size_t i = 0; i < c->sizes.size() && i < dims.size(); i++) {
                int64_t v;
                if (!constEval(c->sizes[i], v)) {
                    diag.error(c->sizes[i]->loc, "with an initializer, the array size must be a constant");
                    return tc_.error();
                }
                if (v != dims[i]) {
                    diag.error(c->sizes[i]->loc, "the specified size (" + std::to_string(v) + ") does not match the number of elements (" +
                                                     std::to_string(dims[i]) + ")");
                    return tc_.error();
                }
            }
    }
    Expr* low = buildCollection(c, arr);
    c->lowered = low;
    return arr;
}

// Forma de un inicializador multidimensional { {1, 2}, {3, 4} } (filas del mismo tamaño) y coste de
// convertir sus elementos a 'elem' (sin elem: solo la forma). -1 si no encaja.
int Sema::rectCost(CollectionExpr* c, Type* elem, int rank, std::vector<int>& dims, size_t level) {
    if (dims.size() == level) dims.push_back((int)c->elems.size());
    else if (dims[level] != (int)c->elems.size()) return -1;
    int sum = 0;
    for (auto& el : c->elems) {
        if (el.spread || el.key) return -1;
        if ((int)level + 1 < rank) {
            if (el.value->kind != EK::Collection || static_cast<CollectionExpr*>(el.value)->arrayRef) return -1;
            int k = rectCost(static_cast<CollectionExpr*>(el.value), elem, rank, dims, level + 1);
            if (k < 0) return -1;
            sum += k;
        } else if (elem) {
            int k = convCost(el.value, elem);
            if (k < 0) return -1;
            sum += k;
        }
    }
    // { } sin filas: las dimensiones interiores son 0
    if (c->elems.empty())
        while ((int)dims.size() < rank) dims.push_back(0);
    return sum;
}

int Sema::collectionCost(CollectionExpr* c, Type* to) {
    CollTarget tg = collTarget(to);
    if (!tg.kind || (c->braces && tg.kind != 1)) return -1;
    int sum = 0;
    if (tg.kind == 1 && tg.rank > 1) {
        std::vector<int> dims;
        sum = rectCost(c, tg.elem, tg.rank, dims, 0);
        if (sum < 0) return -1;
    } else {
        for (auto& el : c->elems) {
            if (tg.kind == 6) {  // [clave: valor]
                if (!el.key || el.spread) return -1;
                int ck = convCost(el.key, tg.key), cv = convCost(el.value, tg.elem);
                if (ck < 0 || cv < 0) return -1;
                sum += ck + cv;
                continue;
            }
            if (el.key) return -1;
            if (el.spread) {
                if (tg.kind == 7 || spreadElem(el.value->type) != tg.elem) return -1;
                continue;
            }
            int k = convCost(el.value, tg.elem);
            if (k < 0) return -1;
            sum += k;
        }
    }
    // A igualdad de elementos: ReadOnlySpan<T>, Span<T>, T[], List<T>, el resto.
    static const int base[] = {0, 3, 4, 5, 2, 1, 5, 6};
    return base[tg.kind] + 10 * sum;
}

Type* Sema::collectionNaturalType(Expr*& e) {
    diag.error(e->loc, "a collection expression has no type of its own: specify the target type "
                       "(int[] xs = [1, 2], List<int> xs = [1, 2]...)");
    return tc_.error();
}

void Sema::convertCollection(Expr*& e, Type* to) {
    auto* c = static_cast<CollectionExpr*>(e);
    if (to->isError()) {
        c->type = to;
        return;
    }
    CollTarget tg = collTarget(to);
    if (!tg.kind || (c->braces && tg.kind != 1)) {
        if (c->braces)
            diag.error(c->loc, "an initializer { ... } only works for arrays and '" + to->str() +
                                   "' is not one (use a collection expression [ ... ])");
        else
            diag.error(c->loc, "cannot convert a collection expression to '" + to->str() +
                                   "' (expected an array, List<T>, HashSet<T>, Span<T>, ReadOnlySpan<T>, "
                                   "Dictionary<K, V> or a class with an Add method)");
        c->type = tc_.error();
        return;
    }
    c->lowered = buildCollection(c, to);
    c->type = to;
}

// Construye la colección de tipo 'to' con los elementos (ya comprobados) de 'c'.
Expr* Sema::buildCollection(CollectionExpr* c, Type* to) {
    SourceLoc loc = c->loc;
    CollTarget tg = collTarget(to);
    auto* let = new LetExpr(loc);
    let->type = to;
    auto fail = [&]() -> Expr* {
        auto* d = new DefaultExpr(loc);
        d->type = to;
        return d;
    };
    // Valor de un elemento convertido a 't', para usarlo en la forma reescrita (sin comprobar):
    // un literal se vuelve a comprobar; el resto se evalúa antes, en orden, en un temporal.
    auto value = [&](Expr* v, Type* t) -> Expr* {
        if (isLiteral(v) && !v->type->isPending()) return v;
        coerce(v, t);
        VarInfo* h = hiddenLocal(t, v->loc, true);
        let->binds.push_back({h, v});
        return refTo(h, v->loc);
    };
    auto finish = [&](VarInfo* t) -> Expr* {
        Expr* r = refTo(t, loc);
        checkValue(r);
        let->seq.push_back(r);
        return let;
    };
    auto step = [&](Expr* x) {
        checkValue(x);
        let->seq.push_back(x);
    };

    if (!tg.kind) return fail();
    bool spreads = false;
    for (auto& el : c->elems) {
        if (el.key && tg.kind != 6) {
            diag.error(el.loc, "'key: value' only works for dictionaries ('" + to->str() + "' is not one)");
            return fail();
        }
        if (tg.kind == 6 && !el.key) {
            diag.error(el.loc, "dictionary elements are written 'key: value' or '[key] = value'");
            return fail();
        }
        if (el.spread) {
            spreads = true;
            Type* se = spreadElem(el.value->type);
            if (el.value->type->isError()) return fail();
            if (tg.kind == 6 || tg.kind == 7 || !se) {
                diag.error(el.loc, "'..' can only spread an array, List<T>, HashSet<T> or Span<T> (not '" +
                                       el.value->type->str() + "') into an array, List<T>, HashSet<T> or Span<T>");
                return fail();
            }
            if (se != tg.elem) {
                diag.error(el.loc, "'..' spreads elements of type '" + se->str() + "' but the collection is of '" +
                                       tg.elem->str() + "'");
                return fail();
            }
        }
    }

    // ---- T[,] / T[,,]: { {1, 2}, {3, 4} }
    if (tg.kind == 1 && tg.rank > 1) {
        std::vector<int> dims;
        if (rectCost(c, nullptr, tg.rank, dims, 0) < 0) {
            diag.error(loc, "the initializer of an array of " + std::to_string(tg.rank) +
                                " dimensions must have " + std::to_string(tg.rank) +
                                " levels of { } and all rows the same size");
            return fail();
        }
        std::vector<Expr*> sizes;
        for (int d : dims) sizes.push_back(mkInt(d, loc));
        Expr* alloc = mkNew(to, sizes, loc);
        checkValue(alloc);
        VarInfo* t = hiddenLocal(to, loc, true);
        let->binds.push_back({t, alloc});
        std::vector<int> at;
        std::function<void(CollectionExpr*)> walk = [&](CollectionExpr* k) {
            for (size_t i = 0; i < k->elems.size(); i++) {
                at.push_back((int)i);
                Expr* v = k->elems[i].value;
                if ((int)at.size() < tg.rank) {
                    walk(static_cast<CollectionExpr*>(v));
                } else {
                    auto* tup = new TupleExpr(v->loc);
                    for (int x : at) {
                        tup->elems.push_back(mkInt(x, v->loc));
                        tup->names.push_back("");
                    }
                    Expr* val = value(v, tg.elem);
                    step(mkAssign(mkIndex(refTo(t, v->loc), tup, v->loc), val, v->loc));
                }
                at.pop_back();
            }
        };
        walk(c);
        return finish(t);
    }

    // ---- T[] con '..', Span<T> y ReadOnlySpan<T>: se construye otra colección y se convierte
    if ((tg.kind == 1 && spreads) || tg.kind == 4 || tg.kind == 5) {
        // T[] con '..': una List<T> y .ToArray();  Span<T>: new Span<T>(un arreglo nuevo)
        Type* inner = tg.kind == 1 ? instanceOf("std.collections", "List", {tg.elem}, loc) : arrayOf(tg.elem, 1, loc);
        if (inner->isError()) return fail();
        Expr* built = buildCollection(c, inner);
        VarInfo* h = hiddenLocal(inner, loc, true);
        Expr* conv = tg.kind == 1 ? mkCall(mkMember(refTo(h, loc), "ToArray", loc), {}, loc) : mkNew(to, {refTo(h, loc)}, loc);
        checkValue(conv);
        auto* outer = new LetExpr(loc);
        outer->binds.push_back({h, built});
        outer->seq.push_back(conv);
        outer->type = to;
        return outer;
    }

    // ---- T[] sin '..': new T[n] y una asignación por elemento
    if (tg.kind == 1) {
        Expr* alloc = mkNew(to, {mkInt((int64_t)c->elems.size(), loc)}, loc);
        checkValue(alloc);
        VarInfo* t = hiddenLocal(to, loc, true);
        let->binds.push_back({t, alloc});
        for (size_t i = 0; i < c->elems.size(); i++) {
            Expr* v = c->elems[i].value;
            Expr* val = value(v, tg.elem);
            step(mkAssign(mkIndex(refTo(t, v->loc), mkInt((int64_t)i, v->loc), v->loc), val, v->loc));
        }
        return finish(t);
    }

    // ---- List<T>, HashSet<T>, Dictionary<K, V> y clases con Add
    int plain = 0;
    for (auto& el : c->elems) plain += el.spread ? 0 : 1;
    Expr* alloc = tg.kind == 2 ? mkNew(to, {mkInt(plain, loc)}, loc) : mkNew(to, {}, loc);
    checkValue(alloc);
    VarInfo* t = hiddenLocal(to, loc, true);
    let->binds.push_back({t, alloc});
    for (auto& el : c->elems) {
        SourceLoc l = el.loc;
        if (tg.kind == 6) {  // d.Set(clave, valor)
            Expr* k = value(el.key, tg.key);
            Expr* v = value(el.value, tg.elem);
            step(mkCall(mkMember(refTo(t, l), "Set", l), {k, v}, l));
            continue;
        }
        if (el.spread) {
            Type* st = el.value->type;
            VarInfo* h = hiddenLocal(st, l, true);
            let->binds.push_back({h, el.value});
            Expr* arg = refTo(h, l);
            bool direct = vectorElemOf(st) || stdTemplateArg(st, "List", "std.collections");
            if (!direct) arg = mkCall(mkMember(arg, "ToArray", l), {}, l);
            step(mkCall(mkMember(refTo(t, l), tg.kind == 3 ? "UnionWith" : "AddRange", l), {arg}, l));
            continue;
        }
        Expr* v = value(el.value, tg.elem);
        step(mkCall(mkMember(refTo(t, l), "Add", l), {v}, l));
    }
    return finish(t);
}

// params T[]: los argumentos sueltos se empaquetan en un arreglo nuevo.
void Sema::packParamsArray(MethodDecl* m, std::vector<Expr*>& args) {
    size_t n = m->params.size();
    Param& last = m->params.back();
    auto* c = new CollectionExpr(args.size() >= n ? args[n - 1]->loc : m->loc);
    for (size_t j = n - 1; j < args.size(); j++) {
        CollectionExpr::Elem el;
        el.loc = args[j]->loc;
        el.value = args[j];
        c->elems.push_back(el);
    }
    c->lowered = buildCollection(c, last.type);
    c->type = last.type;
    args.resize(n - 1);
    args.push_back(c);
}

// ================================================================== foreach sobre T[]

bool Sema::arrayForeach(ForeachStmt* s, Type* ct) {
    Type* el = vectorElemOf(ct);
    if (!el) return false;
    SourceLoc loc = s->loc;
    ctx_.scopes.emplace_back();
    VarInfo* av = hiddenLocal(ct, loc, false);
    VarDeclStmt* d1 = bindDecl(av, s->coll);
    Expr* zero = mkInt(0, loc);
    checkValue(zero);
    VarInfo* iv = hiddenLocal(tc_.get(TK::Int), loc, false);
    VarDeclStmt* d2 = bindDecl(iv, zero);
    Expr* len = mkMember(refTo(av, loc), "Length", loc);
    checkValue(len);
    VarInfo* nv = hiddenLocal(tc_.get(TK::Int), loc, false);
    VarDeclStmt* d3 = bindDecl(nv, len);
    auto* f = new ForStmt(loc);
    f->cond = mkBin("<", refTo(iv, loc), refTo(nv, loc), loc);
    auto* inc = new PostfixExpr(loc);
    inc->op = "++";
    inc->operand = refTo(iv, loc);
    f->iter.push_back(inc);
    auto* inner = new BlockStmt(s->body->loc);
    Expr* current = mkIndex(refTo(av, loc), refTo(iv, loc), loc);
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
    f->body = inner;
    checkStmt(f);
    ctx_.scopes.pop_back();
    auto* blk = new BlockStmt(loc);
    blk->stmts = {d1, d2, d3, f};
    s->lowered = blk;
    return true;
}

// ================================================================== patrones de lista

Expr* Sema::listPatternTest(Pattern* p, const SubjectFn& subj, Type* st) {
    SourceLoc l = p->loc;
    if (p->kind == PK::Slice) {
        diag.error(l, "'..' can only appear inside a list pattern [ ... ]");
        return mkBool(false, l);
    }
    std::string lenName;
    bool indexable = st->is(TK::String);
    if (st->is(TK::String)) {
        lenName = "Length";
    } else if (st->isAggregate()) {
        if (findGetter(st->decl, "Length")) lenName = "Length";
        else if (findGetter(st->decl, "Count")) lenName = "Count";
        indexable = !findMethods(st->decl, "operator[]", MethodKind::Operator).empty();
    }
    if (lenName.empty() || !indexable) {
        diag.error(l, "a list pattern needs an array, a list, a Span<T> or a string (the value is '" +
                          st->str() + "')");
        return mkBool(false, l);
    }
    int slices = 0;
    size_t slicePos = 0;
    for (size_t i = 0; i < p->elems.size(); i++)
        if (p->elems[i]->kind == PK::Slice) {
            slices++;
            slicePos = i;
        }
    if (slices > 1) {
        diag.error(l, "a list pattern allows only one '..'");
        return mkBool(false, l);
    }
    size_t fixed = p->elems.size() - (size_t)slices;
    Expr* test = nullptr;
    auto conj = [&](Expr* t) { test = test ? mkBin("&&", test, t, l) : t; };
    if (st->isClass()) conj(mkBin("!=", subj(), new NullExpr(l), l));
    conj(mkBin(slices ? ">=" : "==", mkMember(subj(), lenName, l), mkInt((int64_t)fixed, l), l));
    Type* et = nullptr;
    if (fixed > 0) {
        Expr* probe = mkIndex(subj(), mkInt(0, l), l);  // solo para conocer el tipo de los elementos
        et = checkValue(probe);
        if (et->isError()) return mkBool(false, l);
    }
    size_t n = p->elems.size();
    for (size_t i = 0; i < n; i++) {
        Pattern* e = p->elems[i];
        if (e->kind == PK::Slice) {
            if (!e->a) continue;
            size_t after = n - i - 1;
            SubjectFn sub = [&, i, after, l]() -> Expr* {  // x[i..^after]
                auto* r = new RangeExpr(l);
                r->start = mkInt((int64_t)i, l);
                auto* fe = new FromEndExpr(l);
                fe->operand = mkInt((int64_t)after, l);
                r->end = fe;
                return mkIndex(subj(), r, l);
            };
            Type* rt = checkValue(sub());  // tipo del tramo (T[], List<T>, Span<T>, string)
            if (rt->isError()) return mkBool(false, l);
            conj(patternTest(e->a, sub, rt));
            continue;
        }
        if (e->kind == PK::Discard) continue;
        SubjectFn sub;
        if (!slices || i < slicePos) {
            sub = [&, i, l]() -> Expr* { return mkIndex(subj(), mkInt((int64_t)i, l), l); };
        } else {
            size_t back = n - i;  // x[x.Length - back]
            sub = [&, back, l]() -> Expr* {
                return mkIndex(subj(), mkBin("-", mkMember(subj(), lenName, l), mkInt((int64_t)back, l), l), l);
            };
        }
        conj(patternTest(e, sub, et));
    }
    if (!p->name.empty()) conj(bindPatternVar(p, p->name, st, subj()));
    return test;
}
