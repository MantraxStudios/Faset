// Faset - sintaxis de arreglos, índices, rangos, expresiones de colección y patrones de lista.
//
//   T[] / T[,] / T[][]          ->  std.Array<T> / std.Array2D<T> / std.Array<std.Array<T>>
//   new T[n], new T[a, b]       ->  NewArrayExpr
//   new T[] { 1, 2 }, new[] { 1, 2 }, int[] a = { 1, 2 }, [1, 2, ..otra]  ->  CollectionExpr
//   ^n                          ->  FromEndExpr (std.Index)
//   a..b, a.., ..b, ..          ->  RangeExpr (std.Range)
//   a[i, j]                     ->  IndexExpr con el índice (i, j) (arreglos multidimensionales)
//   [1, .., var x]              ->  patrón de lista (PK::List con PK::Slice)
// La semántica está en Arrays.cpp.
#include "Parser.h"

namespace {
const char* const kArrayNames[] = {"Array", "Array2D", "Array3D"};
}

// T[R1][R2]...: el arreglo exterior es el del primer especificador (como en C#: int[][,] es un
// arreglo de arreglos bidimensionales).
TypeRef* Parser::arrayTypeRef(TypeRef* elem, int rank) {
    auto* a = new TypeRef();
    a->loc = elem->loc;
    a->parts = {"std", kArrayNames[rank - 1]};
    a->typeArgs = {elem};
    a->arrayRank = rank;
    return a;
}

std::vector<int> Parser::parseArrayRanks() {
    std::vector<int> ranks;
    while (isP("[")) {
        size_t q = p_ + 1;
        int commas = 0;
        while ((*toks_)[q].kind == TokKind::Punct && (*toks_)[q].text == ",") {
            commas++;
            q++;
        }
        const Token& close = (*toks_)[q];
        if (close.kind != TokKind::Punct || close.text != "]") break;  // new T[n], a[i]: no es un sufijo
        if (commas > 2) fail("arrays have at most 3 dimensions");
        ranks.push_back(commas + 1);
        p_ = q + 1;
    }
    return ranks;
}

TypeRef* Parser::parseArraySuffix(TypeRef* tr) {
    std::vector<int> ranks = parseArrayRanks();
    if (ranks.empty()) return tr;
    for (size_t i = ranks.size(); i-- > 0;) tr = arrayTypeRef(tr, ranks[i]);
    if (isP("?") && nullableMarkFollows()) {  // int[]? (un arreglo ya admite null)
        tr->nullable = true;
        p_++;
    }
    if (isP("&") && !halfGt_) {  // ref int[] a  ->  int[]& a
        tr->isRef = true;
        p_++;
    }
    return tr;
}

// Después de 'new T' con '[' (o con T[] y '{').
Expr* Parser::parseNewArray(SourceLoc loc, TypeRef* tr) {
    if (tr->arrayRank) {  // new int[] { ... } / new int[,] { ... }
        if (!isP("{")) fail("expected '{' with the elements after 'new " + tr->str() + "'");
        auto* c = static_cast<CollectionExpr*>(parseBraceInit());
        c->loc = loc;
        c->arrayRef = tr;
        return c;
    }
    expectP("[");
    std::vector<Expr*> counts;
    do counts.push_back(parseExpr());
    while (acceptP(","));
    expectP("]");
    if (counts.size() > 3) fail(loc, "arrays have at most 3 dimensions");
    // new int[3][]: arreglo de 3 elementos de tipo int[]
    std::vector<int> ranks = parseArrayRanks();
    TypeRef* elem = tr;
    for (size_t i = ranks.size(); i-- > 0;) elem = arrayTypeRef(elem, ranks[i]);
    if (isP("{")) {  // new int[3] { 1, 2, 3 }
        auto* c = static_cast<CollectionExpr*>(parseBraceInit());
        c->loc = loc;
        c->arrayRef = arrayTypeRef(elem, (int)counts.size());
        c->sizes = counts;
        return c;
    }
    auto* e = new NewArrayExpr(loc);
    e->elemRef = elem;
    e->count = counts[0];
    e->moreCounts.assign(counts.begin() + 1, counts.end());
    return e;
}

// new[] { 1, 2, 3 }  /  new[,] { {1, 2}, {3, 4} }
Expr* Parser::parseImplicitNewArray(SourceLoc loc) {
    std::vector<int> ranks = parseArrayRanks();
    if (ranks.size() != 1) fail("expected 'new[] { ... }'");
    if (!isP("{")) fail("expected '{' with the elements after 'new[]'");
    auto* c = static_cast<CollectionExpr*>(parseBraceInit());
    c->loc = loc;
    c->implicitNew = true;
    auto* r = new TypeRef();  // solo lleva el rango; el elemento se infiere
    r->loc = loc;
    r->arrayRank = ranks[0];
    c->arrayRef = r;
    return c;
}

// { e1, e2, { ... } }: los elementos pueden ser a su vez llaves (arreglos multidimensionales).
Expr* Parser::parseBraceInit() {
    auto* c = new CollectionExpr(cur().loc);
    c->braces = true;
    expectP("{");
    while (!isP("}") && !atEnd()) {
        CollectionExpr::Elem el;
        el.loc = cur().loc;
        el.value = isP("{") ? parseBraceInit() : parseExpr();
        c->elems.push_back(el);
        if (!acceptP(",")) break;
    }
    expectP("}");
    return c;
}

// [1, 2, ..otra, 4]  /  []  /  [k: v] y [[k] = v] (diccionarios)
Expr* Parser::parseCollectionExpr() {
    auto* c = new CollectionExpr(cur().loc);
    expectP("[");
    while (!isP("]") && !atEnd()) {
        CollectionExpr::Elem el;
        el.loc = cur().loc;
        if (acceptP("..")) {
            el.spread = true;
            el.value = parseExpr();
        } else {
            Expr* e = parseExpr();
            if (acceptP(":")) {  // clave: valor
                el.key = e;
                el.value = parseExpr();
            } else if (e->kind == EK::Assign && static_cast<AssignExpr*>(e)->op == "=" &&
                       static_cast<AssignExpr*>(e)->lhs->kind == EK::Collection) {  // [clave] = valor
                auto* a = static_cast<AssignExpr*>(e);
                auto* k = static_cast<CollectionExpr*>(a->lhs);
                if (k->elems.size() != 1 || k->elems[0].spread || k->elems[0].key)
                    fail(e->loc, "expected '[key] = value'");
                el.key = k->elems[0].value;
                el.value = a->rhs;
            } else {
                el.value = e;
            }
        }
        c->elems.push_back(el);
        if (!acceptP(",")) break;
    }
    expectP("]");
    return c;
}

bool Parser::startsRangeEnd() const {
    const Token& t = cur();
    if (t.kind == TokKind::End) return false;
    if (t.kind == TokKind::Punct) {
        static const char* const stops[] = {"]", ")", ",", ";", "}", ":", "=>", "?", "??", "=", ".."};
        for (const char* s : stops)
            if (t.text == s) return false;
    }
    if (t.kind == TokKind::Keyword && (t.text == "is" || t.text == "as")) return false;
    return true;
}

// a..b: los extremos son expresiones binarias completas (a diferencia de C#, 1..n-1 es 1..(n-1)).
Expr* Parser::parseRangeTail(Expr* start) {
    auto* r = new RangeExpr(cur().loc);
    if (start) r->loc = start->loc;
    expectP("..");
    r->start = start;
    if (startsRangeEnd()) r->end = parseBinary(1);
    return r;
}

Expr* Parser::parseFromEnd() {
    auto* f = new FromEndExpr(cur().loc);
    expectP("^");
    f->operand = parseUnary();
    return f;
}

// a[i, j]: el índice es la tupla (i, j) (std.Array2D define operator[]((int, int))).
Expr* Parser::parseIndexList(Expr* first) {
    auto* t = new TupleExpr(first->loc);
    t->elems.push_back(first);
    t->names.push_back("");
    while (acceptP(",")) {
        t->elems.push_back(parseExpr());
        t->names.push_back("");
    }
    return t;
}

// [p1, p2, .., pN]: '..' (opcionalmente '.. patrón') captura el resto.
Pattern* Parser::parseListPattern() {
    auto* p = new Pattern(PK::List, cur().loc);
    expectP("[");
    while (!isP("]") && !atEnd()) {
        if (isP("..")) {
            auto* s = new Pattern(PK::Slice, cur().loc);
            p_++;
            if (!isP(",") && !isP("]")) s->a = parsePattern();
            p->elems.push_back(s);
        } else {
            p->elems.push_back(parsePattern());
        }
        if (!acceptP(",")) break;
    }
    expectP("]");
    // [1, 2] lista: designación opcional, como en los patrones de propiedades
    if (cur().kind == TokKind::Ident && !isIdentText("and") && !isIdentText("or") && !isIdentText("when")) {
        p->nameLoc = cur().loc;
        p->name = expectIdent();
    }
    return p;
}
