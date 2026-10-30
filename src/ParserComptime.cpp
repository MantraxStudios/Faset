// Faset - análisis sintáctico de la programación en tiempo de compilación y de los atributos.
//
//   [Rango(0, 100, Mensaje = "fuera de rango")]   argumentos de atributo (expresiones constantes)
//   comptime if (Tipo<T>.EsLista) { ... } else { ... }
//   comptime foreach (var f in Tipo<T>.Miembros) { ... f.Nombre ... f.Get(obj) ... }
//   comptime var E = Tipo<T>.Elemento;
//   const int N = comptime Fibonacci(20);
//   static_assert(sizeof(Punto) == 8, "Punto debe ocupar 8 bytes");
//
// La semántica está en Comptime.cpp (intérprete y desenrollado) y Attributes.cpp.
#include "Parser.h"

// ( arg, arg, Nombre = valor, ... ). Cada argumento posicional se guarda también como texto en
// 'args' (el valor de los literales de cadena) para los atributos integrados ([Export("simbolo")],
// [ExceptionBase("Base")], [TestCase(1, 2)]...).
void Parser::parseAttributeArgs(Attribute& a) {
    expectP("(");
    if (!isP(")")) {
        do {
            if (cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct && peekTok().text == "=") {
                a.namedLocs.push_back(cur().loc);
                a.namedArgs.push_back(cur().text);
                p_ += 2;
                a.namedExprs.push_back(parseConditional());
                continue;
            }
            if (!a.namedArgs.empty()) fail("los argumentos posicionales de un atributo van antes de los nombrados");
            size_t begin = p_;
            Expr* e = parseConditional();
            if (e->kind == EK::StringLit) {
                a.args.push_back(static_cast<StringLitExpr*>(e)->value);
            } else {  // texto de los tokens ([TestCase(1, -2.5)]: lo usa faset test, TestRunner.cpp)
                std::string text;
                for (size_t k = begin; k < p_; k++) text += (*toks_)[k].text.empty() ? "?" : (*toks_)[k].text;
                a.args.push_back(text);
            }
            a.argExprs.push_back(e);
        } while (acceptP(","));
    }
    expectP(")");
}

Stmt* Parser::tryParseComptimeStmt() {
    if (!isComptimeKw()) return nullptr;
    const Token& n = peekTok();
    SourceLoc loc = cur().loc;
    if (n.kind == TokKind::Keyword && n.text == "if") {
        p_ += 2;
        auto* s = new ComptimeIfStmt(loc);
        expectP("(");
        s->cond = parseExpr();
        expectP(")");
        s->then = parseStatement();
        if (acceptK("else")) s->els = parseStatement();
        return s;
    }
    if (n.kind == TokKind::Keyword && n.text == "foreach") {
        p_ += 2;
        auto* s = new ComptimeForeachStmt(loc);
        expectP("(");
        parseType();  // 'var' o el tipo (se ignora: el elemento es un valor de tiempo de compilación)
        s->nameLoc = cur().loc;
        s->name = expectIdent();
        if (!acceptK("in")) fail("se esperaba 'in' en 'comptime foreach' pero se encontró '" + cur().text + "'");
        s->coll = parseExpr();
        expectP(")");
        s->tokens = toks_;
        s->bodyBegin = p_;
        s->file = file_;
        s->body = parseStatement();  // solo para validar la sintaxis: cada vuelta se analiza de nuevo
        return s;
    }
    // comptime var x = expr;  /  comptime int x = expr;
    size_t save = p_;
    p_++;
    if (looksLikeDecl() && !isK("const")) {
        auto* s = new ComptimeVarStmt(loc);
        s->tref = parseType();
        s->nameLoc = cur().loc;
        s->name = expectIdent();
        expectP("=");
        s->init = parseExpr();
        expectP(";");
        return s;
    }
    p_ = save;
    return nullptr;
}

Expr* Parser::tryParseComptimeExpr() {
    if (!isComptimeKw()) return nullptr;
    const Token& n = peekTok();
    bool operand = n.kind == TokKind::Ident || n.kind == TokKind::Int || n.kind == TokKind::Float ||
                   n.kind == TokKind::Char || n.kind == TokKind::String || n.kind == TokKind::InterpBegin ||
                   (n.kind == TokKind::Punct && (n.text == "(" || n.text == "-" || n.text == "!" || n.text == "[")) ||
                   (n.kind == TokKind::Keyword && (n.text == "new" || n.text == "typeof" || n.text == "sizeof" ||
                                                   n.text == "true" || n.text == "false" || n.text == "default" ||
                                                   n.text == "int" || n.text == "long" || n.text == "string" ||
                                                   n.text == "double"));
    if (!operand) return nullptr;
    auto* e = new ComptimeExpr(cur().loc);
    p_++;
    e->operand = parseUnary();
    return e;
}

// static_assert(cond, "mensaje"); como miembro de una clase o de un namespace.
bool Parser::tryParseStaticAssertMember(ClassDecl* c) {
    if (!(cur().kind == TokKind::Ident && cur().text == "static_assert" && peekTok().kind == TokKind::Punct &&
          peekTok().text == "("))
        return false;
    Expr* e = parsePostfix(parsePrimary());
    expectP(";");
    c->staticAsserts.push_back(e);
    return true;
}

Stmt* Parser::reparseStmt(const TokenList& toks, size_t begin, FileScope* file, Program& prog) {
    Parser p(toks, prog, file, "");
    p.reparse_ = true;
    p.p_ = begin;
    try {
        return p.parseStatement();
    } catch (ParseError&) {
        return nullptr;
    }
}
