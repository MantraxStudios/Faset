// Faset - análisis sintáctico del azúcar del lenguaje: foreach, cadenas interpoladas,
// operadores de null (?? ??= ?. ?[]), tuplas y deconstrucción, patrones (switch de expresión,
// 'case ... when', 'is'), nameof y 'using'. Lo comprueba y reescribe Sema (Sugar.cpp).
#include "Parser.h"

// ¿El '?' que sigue a un tipo lo marca como anulable (int? x, List<int?>, (int?)x)?
bool Parser::nullableMarkFollows() const {
    const Token& n = peekTok();
    if (n.kind == TokKind::Ident) {
        // 'T? x' es una declaración; 'a ? b : c' no: tras el nombre viene '=', ';', ',' o ')'.
        const Token& n2 = peekTok(2);
        if (n2.kind == TokKind::Keyword) return n2.text == "in";  // foreach (int? x in ...)
        return n2.kind == TokKind::Punct && (n2.text == "=" || n2.text == ";" || n2.text == "," || n2.text == ")" ||
                                            n2.text == "=>" || n2.text == "{" || n2.text == "(");
    }
    return n.kind == TokKind::Punct && (n.text == ")" || n.text == ">" || n.text == ">>" || n.text == "," ||
                                        n.text == "*" || n.text == "&" || n.text == "]");
}

// (int, string)  /  (int x, int y): al menos dos elementos.
TypeRef* Parser::tryParseTupleType() {
    auto* tr = new TypeRef();
    tr->loc = cur().loc;
    tr->isTuple = true;
    p_++;  // '('
    for (;;) {
        TypeRef* el = tryParseType();
        if (!el || halfGt_) return nullptr;
        tr->typeArgs.push_back(el);
        std::string name;
        if (cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct &&
            (peekTok().text == "," || peekTok().text == ")"))
            name = (*toks_)[p_++].text;
        tr->tupleNames.push_back(name);
        if (acceptP(",")) continue;
        if (!acceptP(")")) return nullptr;
        break;
    }
    if (tr->typeArgs.size() < 2) return nullptr;
    bool anyName = false;
    for (auto& n : tr->tupleNames) anyName |= !n.empty();
    if (!anyName) tr->tupleNames.clear();
    return tr;
}

// $"texto {expr,alineación:formato} texto"
Expr* Parser::parseInterpolated() {
    auto* e = new InterpExpr(cur().loc);
    p_++;
    while (!atEnd() && cur().kind != TokKind::InterpEnd) {
        if (cur().kind == TokKind::String) {
            InterpExpr::Part part;
            part.text = cur().text;
            e->parts.push_back(part);
            p_++;
            continue;
        }
        if (cur().kind != TokKind::InterpHole) fail("malformed interpolated string");
        InterpExpr::Part part;
        part.format = cur().text;
        part.hasAlign = cur().isLong;
        part.align = (int)(int64_t)cur().intVal;
        p_++;
        if (cur().kind == TokKind::InterpHoleEnd) {  // hueco vacío (ya se informó)
            p_++;
            continue;
        }
        part.expr = parseExpr();
        if (cur().kind != TokKind::InterpHoleEnd)
            fail("expected '}' in the interpolated string hole but found '" + cur().text + "'");
        p_++;
        e->parts.push_back(part);
    }
    if (cur().kind == TokKind::InterpEnd) p_++;
    // "a" + $"b": la concatenación sigue siendo un '+' normal.
    return e;
}

// '(' ya consumido: expresión entre paréntesis o tupla (1, "a") / (x: 1, y: 2).
Expr* Parser::parseParenOrTuple(SourceLoc loc) {
    auto element = [&](std::string& name) {
        if (cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct && peekTok().text == ":") {
            name = (*toks_)[p_].text;
            p_ += 2;
        }
        return parseExpr();
    };
    std::string n0;
    Expr* first = element(n0);
    if (!isP(",")) {
        expectP(")");
        if (!n0.empty()) fail(loc, "a tuple needs at least two elements");
        return first;
    }
    auto* t = new TupleExpr(loc);
    t->elems.push_back(first);
    t->names.push_back(n0);
    while (acceptP(",")) {
        std::string n;
        t->elems.push_back(element(n));
        t->names.push_back(n);
    }
    expectP(")");
    return t;
}

// obj?.a.b()  /  obj?[i]: el resto de la cadena se evalúa solo si obj no es null.
Expr* Parser::parseConditionalAccess(Expr* obj) {
    auto* ca = new CondAccessExpr(cur().loc);
    ca->obj = obj;
    auto* recv = new CondRecvExpr(cur().loc);
    recv->owner = ca;
    p_++;  // '?'
    Expr* first;
    SourceLoc loc = cur().loc;
    if (acceptP(".")) {
        auto* m = new MemberExpr(loc);
        m->obj = recv;
        m->nameLoc = cur().loc;
        m->name = expectIdent();
        tryExprTypeArgs(m->typeArgs);
        first = m;
    } else {
        p_++;  // '['
        auto* ix = new IndexExpr(loc);
        ix->obj = recv;
        ix->index = parseExpr();
        expectP("]");
        first = ix;
    }
    ca->access = parsePostfix(first);
    return ca;
}

// a ?? b ?? c (asociativo por la derecha); se representa como BinaryExpr "??".
Expr* Parser::parseCoalesce(Expr* lhs) {
    auto* b = new BinaryExpr(cur().loc);
    b->op = "??";
    p_++;
    b->lhs = lhs;
    Expr* rhs = parseBinary(1);
    b->rhs = isP("??") ? parseCoalesce(rhs) : rhs;
    return b;
}

// nameof(x), nameof(obj.Campo), nameof(Tipo.Metodo): el último nombre como cadena constante.
Expr* Parser::parseNameof(SourceLoc loc) {
    p_++;  // nameof
    expectP("(");
    Expr* e = parseExpr();
    expectP(")");
    auto* s = new StringLitExpr(loc);
    if (e->kind == EK::Name) s->value = static_cast<NameExpr*>(e)->name;
    else if (e->kind == EK::Member) s->value = static_cast<MemberExpr*>(e)->name;
    else fail(loc, "nameof requires a name (variable, type, field or method)");
    return s;
}

// ------------------------------------------------------------------ patrones

Pattern* Parser::parsePattern() {
    Pattern* a = parseAndPattern();
    while (isIdentText("or")) {
        auto* p = new Pattern(PK::Or, cur().loc);
        p_++;
        p->a = a;
        p->b = parseAndPattern();
        a = p;
    }
    return a;
}

Pattern* Parser::parseAndPattern() {
    Pattern* a = parseNotPattern();
    while (isIdentText("and")) {
        auto* p = new Pattern(PK::And, cur().loc);
        p_++;
        p->a = a;
        p->b = parseNotPattern();
        a = p;
    }
    return a;
}

Pattern* Parser::parseNotPattern() {
    if (isIdentText("not")) {
        auto* p = new Pattern(PK::Not, cur().loc);
        p_++;
        p->a = parseNotPattern();
        return p;
    }
    return parsePrimaryPattern();
}

Pattern* Parser::parsePrimaryPattern() {
    SourceLoc loc = cur().loc;
    if (isP("[")) return parseListPattern();  // [1, .., var x] (ParserArrays.cpp)
    // Relacional: > 5, <= 0, < "m"
    for (const char* op : {"<=", ">=", "<", ">"}) {
        if (isP(op)) {
            auto* p = new Pattern(PK::Relational, loc);
            p->op = op;
            p_++;
            p->value = parseBinary(8);
            return p;
        }
    }
    if (isIdentText("_")) {
        p_++;
        return new Pattern(PK::Discard, loc);
    }
    if (isIdentText("var") && peekTok().kind == TokKind::Ident) {
        p_++;
        auto* p = new Pattern(PK::Var, loc);
        p->nameLoc = cur().loc;
        p->name = expectIdent();
        return p;
    }
    auto propertyList = [&](Pattern* p) {
        expectP("{");
        while (!isP("}") && !atEnd()) {
            SourceLoc nl = cur().loc;
            std::string name = expectIdent();
            expectP(":");
            p->props.push_back({name, parsePattern()});
            p->propLocs.push_back(nl);
            if (!acceptP(",")) break;
        }
        expectP("}");
        if (cur().kind == TokKind::Ident && !isIdentText("and") && !isIdentText("or") && !isIdentText("when")) {
            p->nameLoc = cur().loc;
            p->name = expectIdent();  // { Edad: > 18 } adulto
        }
    };
    if (isP("{")) {  // { Edad: > 18, Nombre: "Ana" }
        auto* p = new Pattern(PK::Property, loc);
        propertyList(p);
        return p;
    }
    if (isP("(")) {  // posicional (0, _) o patrón entre paréntesis
        size_t save = p_;
        p_++;
        Pattern* first = parsePattern();
        if (acceptP(",")) {
            auto* p = new Pattern(PK::Positional, loc);
            p->elems.push_back(first);
            do p->elems.push_back(parsePattern());
            while (acceptP(","));
            expectP(")");
            return p;
        }
        if (acceptP(")")) return first;
        p_ = save;  // p. ej. (1 + 2) * 3: es una constante
    }
    // Patrón de tipo: 'Perro p', 'Perro { Edad: > 3 }'. Lo comprueba el gancho de Sema
    // (Sema::lowerTypePattern); los tipos sin designación se analizan como constantes.
    if (cur().kind == TokKind::Ident || isPrimitiveKw()) {
        size_t save = p_;
        TypeRef* tr = tryParseType();
        if (tr && !halfGt_ && !tr->typeArgs.empty() && tr->ptrDepth == 0 && isDot() &&
            peekTok().kind == TokKind::Ident) {  // Arbol<int>.Hoja(...): caso de una unión genérica
            p_++;
            tr->parts.push_back(expectIdent());
        }
        if (tr && !halfGt_) {
            if (isP("(") &&!tr->parts.empty() && tr->ptrDepth == 0 && !tr->nullable)
                return parseCasePattern(tr, loc);  // Forma.Circulo(var r) (ParserUnions.cpp)
            if (cur().kind == TokKind::Ident && !isIdentText("and") && !isIdentText("or") && !isIdentText("when")) {
                auto* p = new Pattern(PK::Type, loc);
                p->tref = tr;
                p->nameLoc = cur().loc;
                p->name = expectIdent();
                return p;
            }
            if (isP("{") && !tr->parts.empty()) {
                auto* p = new Pattern(PK::Property, loc);
                p->tref = tr;
                propertyList(p);
                return p;
            }
            if (tr->arrayRank) {  // x is int[] (sin designación)
                auto* p = new Pattern(PK::Type, loc);
                p->tref = tr;
                return p;
            }
        }
        p_ = save;
        halfGt_ = false;
    }
    auto* p = new Pattern(PK::Constant, loc);
    p->value = parseBinary(3);
    return p;
}

// x switch { patrón [when guarda] => valor, ... }
Expr* Parser::parseSwitchExpr(Expr* subject) {
    auto* e = new SwitchExpr(cur().loc);
    e->subject = subject;
    p_++;  // switch
    expectP("{");
    while (!isP("}") && !atEnd()) {
        SwitchExpr::Arm arm;
        arm.loc = cur().loc;
        arm.pat = parsePattern();
        if (isIdentText("when")) {
            p_++;
            arm.guard = parseConditional();  // no parseAssign: "x => ..." sería una lambda
        }
        expectP("=>");
        arm.value = parseExpr();
        e->arms.push_back(arm);
        if (!acceptP(",")) break;
    }
    expectP("}");
    if (e->arms.empty()) fail(e->loc, "a 'switch' expression needs at least one arm");
    return e;
}

// x is patrón
Expr* Parser::parseIsPattern(Expr* subject) {
    auto* e = new IsPatternExpr(cur().loc);
    p_++;  // is
    e->subject = subject;
    e->pat = parsePattern();
    return e;
}

// 'case' ya consumido: patrón [when guarda]
void Parser::parseSwitchLabel(SwitchStmt::Section& sec) {
    Pattern* p = parsePattern();
    Expr* guard = nullptr;
    if (isIdentText("when")) {
        p_++;
        guard = parseConditional();  // no parseAssign: "x => ..." sería una lambda
    }
    sec.patterns.push_back(p);
    sec.guards.push_back(guard);
    if (p->kind == PK::Constant && !guard) sec.labels.push_back(p->value);
}

// ------------------------------------------------------------------ sentencias

// foreach (var x in c) / foreach (int x in c) / foreach (var (k, v) in c) / foreach ((int k, string v) in c)
Stmt* Parser::parseForeach() {
    auto* s = new ForeachStmt(cur().loc);
    p_++;  // foreach
    expectP("(");
    auto names = [&](bool typed) {
        expectP("(");
        do {
            TypeRef* t = nullptr;
            if (typed) {
                t = parseType();
                if (t->isVar()) t = nullptr;
            }
            s->nameLocs.push_back(cur().loc);
            s->names.push_back(expectIdent());
            s->types.push_back(t);
        } while (acceptP(","));
        expectP(")");
    };
    if (isIdentText("var") && peekTok().kind == TokKind::Punct && peekTok().text == "(") {
        p_++;
        names(false);
    } else if (isP("(")) {
        names(true);
    } else {
        s->tref = parseType();
        s->nameLoc = cur().loc;
        s->name = expectIdent();
    }
    if (!acceptK("in")) fail("expected 'in' in 'foreach' but found '" + cur().text + "'");
    s->coll = parseExpr();
    expectP(")");
    s->body = parseStatement();
    return s;
}

// using var x = e;   using (var x = e) cuerpo   using (e) cuerpo
Stmt* Parser::parseUsingStmt() {
    auto* s = new UsingStmt(cur().loc);
    p_++;  // using
    if (acceptP("(")) {
        if (looksLikeDecl()) s->decl = parseVarDecl(false);
        else s->expr = parseExpr();
        expectP(")");
        s->body = parseStatement();
        return s;
    }
    if (!looksLikeDecl()) fail("expected a declaration after 'using' (using var x = ...;)");
    s->decl = parseVarDecl(true);
    return s;
}

// var (a, b) = e;   (int a, string b) = e;   (var a, var b) = e;
Stmt* Parser::tryParseDeconstruct() {
    SourceLoc loc = cur().loc;
    if (isIdentText("var") && peekTok().kind == TokKind::Punct && peekTok().text == "(") {
        auto* d = new DeconstructStmt(loc);
        p_ += 2;
        do {
            d->locs.push_back(cur().loc);
            d->names.push_back(expectIdent());
            d->types.push_back(nullptr);
        } while (acceptP(","));
        expectP(")");
        expectP("=");
        d->init = parseExpr();
        expectP(";");
        return d;
    }
    if (!isP("(")) return nullptr;
    size_t save = p_;
    TypeRef* tr = tryParseType();
    bool ok = tr && tr->isTuple && !halfGt_ && isP("=") && tr->tupleNames.size() == tr->typeArgs.size();
    for (size_t i = 0; ok && i < tr->tupleNames.size(); i++) ok = !tr->tupleNames[i].empty();
    if (!ok) {
        p_ = save;
        halfGt_ = false;
        return nullptr;
    }
    auto* d = new DeconstructStmt(loc);
    for (size_t i = 0; i < tr->typeArgs.size(); i++) {
        d->names.push_back(tr->tupleNames[i]);
        d->types.push_back(tr->typeArgs[i]->isVar() ? nullptr : tr->typeArgs[i]);
        d->locs.push_back(tr->typeArgs[i]->loc);
    }
    p_++;  // '='
    d->init = parseExpr();
    expectP(";");
    return d;
}
