// Faset - análisis sintáctico de la orientación a objetos: restricciones genéricas (where),
// registros (record), 'is' / 'as' y expresiones 'with'.
#include "Parser.h"

// 'record' es una palabra clave contextual: record Punto(...), record class X, record struct Y.
bool Parser::isRecordStart() const {
    if (cur().kind != TokKind::Ident || cur().text != "record") return false;
    const Token& n = peekTok();
    return n.kind == TokKind::Ident || (n.kind == TokKind::Keyword && (n.text == "class" || n.text == "struct"));
}

// where T : class, struct, new(), Base, IComparable<T>   (puede haber varias cláusulas)
void Parser::parseWhereClauses(std::vector<TypeConstraint>& out) {
    while (cur().kind == TokKind::Ident && cur().text == "where") {
        p_++;
        TypeConstraint tc;
        tc.loc = cur().loc;
        tc.param = expectIdent();
        expectP(":");
        do {
            if (acceptK("class")) {
                tc.isClass = true;
            } else if (acceptK("struct")) {
                tc.isStruct = true;
            } else if (isK("new")) {
                p_++;
                expectP("(");
                expectP(")");
                tc.isNew = true;
            } else {
                tc.types.push_back(parseType());
            }
        } while (acceptP(","));
        out.push_back(tc);
    }
}

// Miembros generados de un 'record': propiedades y constructor posicionales, igualdad por valor
// (==, !=, Equals), GetHashCode y ToString ("Punto { X = 1, Y = 2 }"). Se generan como código
// Faset y se analizan con la ubicación del registro; los cuerpos de ToString, GetHashCode y
// operator== los escribe CodeGen (recordGen) porque dependen de los tipos de los campos.
void Parser::synthesizeRecord(ClassDecl* c, const std::vector<Param>& params, bool positional) {
    bool isStruct = c->kind == ClassKind::Struct;
    std::string self = c->name;
    if (!c->typeParams.empty()) {
        self += "<";
        for (size_t i = 0; i < c->typeParams.size(); i++) self += (i ? ", " : "") + c->typeParams[i];
        self += ">";
    }
    auto has = [&](const std::string& name, size_t nparams) {
        for (MethodDecl* m : c->methods)
            if (m->name == name && m->params.size() == nparams && m->kind == MethodKind::Normal) return true;
        return false;
    };
    std::vector<std::pair<std::string, int>> members;
    if (positional) {
        std::string ctorParams, ctorBody;
        for (size_t i = 0; i < params.size(); i++) {
            const Param& p = params[i];
            if (p.tref->isRef) {
                diag.error(p.loc, "los parámetros de un 'record' no pueden ser referencias");
                continue;
            }
            members.push_back({"public " + p.tref->str() + " " + p.name + " { get; }", 0});
            ctorParams += (i ? ", " : "") + p.tref->str() + " " + p.name;
            ctorBody += "this." + p.name + "__valor = " + p.name + "; ";
        }
        members.push_back({"public " + c->name + "(" + ctorParams + ") { " + ctorBody + "}", 0});
    }
    if (!has("ToString", 0))
        members.push_back({std::string("public ") + (isStruct ? "" : "override ") + "string ToString() { return \"\"; }", 1});
    if (!has("GetHashCode", 0))
        members.push_back({std::string("public ") + (isStruct ? "" : "override ") + "int GetHashCode() { return 0; }", 2});
    members.push_back({"public static bool operator==(" + self + " a, " + self + " b) { return false; }", 3});
    members.push_back({"public static bool operator!=(" + self + " a, " + self + " b) { return !(a == b); }", 0});
    if (!isStruct && !has("Equals", 1))
        members.push_back({"public override bool Equals(object o) { return o is " + self + " r && this == r; }", 0});
    members.push_back({"public bool Equals(" + self + " o) { return this == o; }", 0});

    for (auto& [text, gen] : members) {
        auto toks = std::make_shared<std::vector<Token>>(tokenize(text, file_->fileId));
        for (Token& t : *toks) t.loc = c->loc;
        Parser sub(toks, prog_, file_, fileDir_);
        sub.reparse_ = true;
        sub.nsUnsafe_ = nsUnsafe_;
        size_t before = c->methods.size();
        try {
            std::vector<Attribute> attrs = sub.parseAttributes();
            Modifiers mods = sub.parseModifiers();
            sub.parseMember(c, attrs, mods, 0);
        } catch (ParseError&) {
        }
        if (gen && c->methods.size() > before) c->methods.back()->recordGen = gen;
    }
}

// x is T, x is T nombre, x is null, x is not null, x is not T;   x as T
Expr* Parser::parseIsAs(Expr* lhs) {
    SourceLoc loc = cur().loc;
    if (acceptK("as")) {
        auto* e = new AsExpr(loc);
        e->operand = lhs;
        e->tref = parseType();
        return e;
    }
    p_++;  // 'is'
    auto* e = new IsExpr(loc);
    e->operand = lhs;
    if (cur().kind == TokKind::Ident && cur().text == "not") {
        p_++;
        e->negate = true;
    }
    if (acceptK("null") || acceptK("nullptr")) return e;
    e->tref = parseType();
    if (cur().kind == TokKind::Ident && !e->negate) {
        e->varLoc = cur().loc;
        e->varName = expectIdent();
    }
    return e;
}

// registro with { X = 1, Y = 2 }
Expr* Parser::parseWith(Expr* operand) {
    auto* e = new WithExpr(cur().loc);
    e->operand = operand;
    p_++;  // 'with'
    expectP("{");
    while (!isP("}") && !atEnd()) {
        WithExpr::Init in;
        in.loc = cur().loc;
        in.name = expectIdent();
        expectP("=");
        in.value = parseExpr();
        e->inits.push_back(in);
        if (!acceptP(",")) break;
    }
    expectP("}");
    return e;
}
