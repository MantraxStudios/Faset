// Faset - análisis sintáctico de lambdas y declaraciones de delegados.
//
//   x => x * 2          (a, b) => a + b          (int x, int y) => x * y
//   () => { ...; return v; }
//   delegate int Comparador(string a, string b);
//   delegate bool Predicate<T>(T valor);
#include "Parser.h"

// ¿Empieza aquí una lambda? 'nombre =>' o '( ... ) =>' (paréntesis equilibrados).
// Si es así la analiza; si no, no consume nada y devuelve nullptr.
Expr* Parser::tryParseLambda() {
    // async x => ...  /  async (a, b) => { ... }  (ver Async.cpp)
    if (cur().kind == TokKind::Ident && cur().text == "async" &&
        (peekTok().kind == TokKind::Ident || (peekTok().kind == TokKind::Punct && peekTok().text == "("))) {
        size_t save = p_;
        p_++;
        Expr* e = tryParseLambda();
        if (!e) {
            p_ = save;
            return nullptr;
        }
        auto* l = static_cast<LambdaExpr*>(e);
        l->isAsync = true;
        l->tokBegin = save;
        l->loc = (*toks_)[save].loc;
        requestModule({"std", "task"});
        if (l->exprBody) {  // el cuerpo de expresión pasa a ser { return expr; } (la máquina de estados trabaja con sentencias)
            auto* rs = new ReturnStmt(l->exprBody->loc);
            rs->value = l->exprBody;
            rs->fromExprBody = true;
            auto* b = new BlockStmt(l->exprBody->loc);
            b->stmts.push_back(rs);
            b->endLoc = l->exprBody->loc;
            l->blockBody = b;
            l->exprBody = nullptr;
        }
        return l;
    }
    bool single = cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct && peekTok().text == "=>";
    bool paren = false;
    if (!single && isP("(")) {
        int depth = 0;
        size_t i = p_;
        for (; i < toks_->size(); i++) {
            const Token& t = (*toks_)[i];
            if (t.kind == TokKind::End) break;
            if (t.kind != TokKind::Punct) continue;
            if (t.text == "(") depth++;
            else if (t.text == ")" && --depth == 0) break;
            else if (t.text == ";" || t.text == "{" || t.text == "}") break;  // no es una lista de parámetros
        }
        paren = i + 1 < toks_->size() && (*toks_)[i].kind == TokKind::Punct && (*toks_)[i].text == ")" &&
                (*toks_)[i + 1].kind == TokKind::Punct && (*toks_)[i + 1].text == "=>";
    }
    if (!single && !paren) return nullptr;

    auto* l = new LambdaExpr(cur().loc);
    l->tokens = toks_;
    l->tokBegin = p_;
    l->file = file_;
    if (single) {
        LambdaExpr::LParam prm;
        prm.loc = cur().loc;
        prm.name = expectIdent();
        l->params.push_back(prm);
        expectP("=>");
    } else {
        expectP("(");
        int typed = 0;
        if (!isP(")")) {
            do {
                LambdaExpr::LParam prm;
                prm.loc = cur().loc;
                if (isK("ref") || isK("out")) fail("the parameters of a lambda cannot be 'ref' or 'out'");
                bool bare = cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct &&
                            (peekTok().text == "," || peekTok().text == ")");
                if (!bare) {
                    prm.tref = parseType();
                    prm.loc = cur().loc;
                    typed++;
                }
                prm.name = expectIdent();
                l->params.push_back(prm);
            } while (acceptP(","));
        }
        expectP(")");
        if (typed != 0 && typed != (int)l->params.size())
            fail(l->loc, "in a lambda, either all parameters specify their type or none do");
        expectP("=>");
    }
    if (isP("{")) l->blockBody = parseBlock();
    else l->exprBody = parseAssign();
    return l;
}

LambdaExpr* Parser::reparseLambda(LambdaExpr* l, Program& prog) {
    Parser p(l->tokens, prog, l->file, "");
    p.reparse_ = true;
    p.p_ = l->tokBegin;
    try {
        Expr* e = p.tryParseLambda();
        return e ? static_cast<LambdaExpr*>(e) : nullptr;
    } catch (ParseError&) {
        return nullptr;
    }
}

// delegate R Nombre<T...>(parámetros);   (en un namespace o dentro de una clase)
void Parser::parseDelegateDecl(ClassDecl* owner, std::vector<Attribute> attrs, Modifiers mods) {
    SourceLoc loc = cur().loc;
    p_++;  // 'delegate'
    auto* m = new MethodDecl();
    m->mods = mods;
    if (!mods.hasAccess) m->mods.access = Access::Public;
    m->attrs = std::move(attrs);
    m->retRef = parseType();
    m->loc = cur().loc;
    m->name = expectIdent();
    if (isP("<")) m->typeParams = parseTypeParams();
    parseParams(m);
    for (Param& p : m->params)
        if (p.isRef() || p.isThis) fail(p.loc, "the parameters of a delegate cannot be 'ref', 'out' or 'this'");
    if (m->variadic) fail(loc, "a delegate cannot be variadic");
    expectP(";");
    m->owner = owner;
    m->file = file_;
    m->mods.isStatic = true;
    if (!reparse_) prog_.delegates.push_back(m);
}
