// Faset - análisis sintáctico de los iteradores (ver Iterators.cpp):
//
//   yield return valor;   yield break;              (palabra contextual: 'yield' sigue siendo un nombre válido)
//   await foreach (var x in flujo) { ... }          (flujos asíncronos)
//   IEnumerable<int> Pares(int n) { ... }           función local (dentro de un método)
//   IEnumerator<T> IEnumerable<T>.GetEnumerator()   implementación explícita de un miembro de interfaz
#include "Parser.h"

// Sentencias propias de los iteradores; nullptr si la sentencia es de otro tipo (no consume nada).
Stmt* Parser::parseIterStmt() {
    SourceLoc loc = cur().loc;
    // yield return expr;  /  yield break;
    if (isIdentText("yield") && peekTok().kind == TokKind::Keyword && (peekTok().text == "return" || peekTok().text == "break")) {
        p_++;
        auto* y = new YieldStmt(loc);
        if (acceptK("break")) {
            y->isBreak = true;
        } else {
            p_++;  // return
            if (isP(";")) fail("'yield return' necesita un valor (para terminar el iterador usa 'yield break;')");
            y->value = parseExpr();
        }
        expectP(";");
        requestModule({"std", "collections"});
        return y;
    }
    // await foreach (...)
    if (isIdentText("await") && peekTok().kind == TokKind::Keyword && peekTok().text == "foreach") {
        p_++;
        auto* f = static_cast<ForeachStmt*>(parseForeach());
        f->isAwait = true;
        f->loc = loc;
        requestModule({"std", "task"});
        return f;
    }
    return parseLocalFunction();
}

// Función local:  [static] [async] T Nombre(parámetros) { cuerpo }   /   ... => expresión;
// Se convierte en una variable delegado (Func<...> / Action<...>) con una lambda; primero se declara
// la variable y después se asigna, así la función puede llamarse a sí misma (recursión).
Stmt* Parser::parseLocalFunction() {
    size_t save = p_;
    SourceLoc loc = cur().loc;
    bool isAsync = false;
    if (isK("static")) p_++;
    if (isIdentText("async") && (peekTok().kind == TokKind::Ident || peekTok().kind == TokKind::Keyword)) {
        p_++;
        isAsync = true;
    }
    if (!isPrimitiveKw() && cur().kind != TokKind::Ident && !isP("(")) {
        p_ = save;
        return nullptr;
    }
    TypeRef* ret = tryParseType();
    bool ok = ret && !halfGt_ && cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct &&
              (peekTok().text == "(" || peekTok().text == "<");
    if (ok) {  // los paréntesis deben ir seguidos de '{' o '=>'
        size_t i = p_ + 1;
        if ((*toks_)[i].text == "<") {
            ok = false;
        } else {
            int depth = 0;
            for (; i < toks_->size(); i++) {
                const Token& t = (*toks_)[i];
                if (t.kind == TokKind::End) break;
                if (t.kind != TokKind::Punct) continue;
                if (t.text == "(") depth++;
                else if (t.text == ")" && --depth == 0) break;
                else if (t.text == ";" || t.text == "{" || t.text == "}") break;
            }
            ok = i + 1 < toks_->size() && (*toks_)[i].text == ")" && (*toks_)[i + 1].kind == TokKind::Punct &&
                 ((*toks_)[i + 1].text == "{" || (*toks_)[i + 1].text == "=>");
        }
    }
    if (!ok) {
        halfGt_ = false;
        p_ = save;
        return nullptr;
    }
    if (ret->isRef) fail(loc, "una función local no puede devolver una referencia");
    SourceLoc nameLoc = cur().loc;
    std::string name = expectIdent();
    MethodDecl tmp;
    parseParams(&tmp);
    auto* l = new LambdaExpr(loc);
    l->file = file_;
    l->isAsync = isAsync;
    for (Param& p : tmp.params) {
        if (p.isRef() || p.isThis || p.isParams)
            fail(p.loc, "los parámetros de una función local no pueden ser 'ref', 'out', 'this' ni 'params'");
        LambdaExpr::LParam lp;
        lp.loc = p.loc;
        lp.name = p.name;
        lp.tref = p.tref;
        l->params.push_back(lp);
    }
    bool isVoid = ret->parts.size() == 1 && ret->parts[0] == "void" && ret->ptrDepth == 0 && !ret->isTuple;
    if (acceptP("=>")) {
        Expr* e = parseExpr();
        expectP(";");
        auto* b = new BlockStmt(e->loc);
        if (isVoid) {
            auto* es = new ExprStmt(e->loc);
            es->expr = e;
            b->stmts.push_back(es);
        } else {
            auto* rs = new ReturnStmt(e->loc);
            rs->value = e;
            b->stmts.push_back(rs);
        }
        b->endLoc = e->loc;
        l->blockBody = b;
    } else {
        l->blockBody = parseBlock();
    }
    // Tipo delegado: Action<P...> si devuelve void, si no Func<P..., R>.
    auto* dt = new TypeRef();
    dt->loc = loc;
    dt->parts = {isVoid ? "Action" : "Func"};
    for (Param& p : tmp.params) dt->typeArgs.push_back(p.tref);
    if (!isVoid) dt->typeArgs.push_back(ret);
    auto* decl = new VarDeclStmt(loc);
    decl->tref = dt;
    VarDeclStmt::Declarator dc;
    dc.loc = nameLoc;
    dc.name = name;
    dc.init = new NullExpr(loc);
    decl->decls.push_back(dc);
    decl->isLocalFunction = true;  // se puede llamar antes de su declaración (hoistLocalFunctions, ParserMembers.cpp)
    auto* target = new NameExpr(nameLoc);
    target->name = name;
    auto* as = new AssignExpr(loc);
    as->op = "=";
    as->lhs = target;
    as->rhs = l;
    auto* set = new ExprStmt(loc);
    set->expr = as;
    auto* blk = new BlockStmt(loc);
    blk->noScope = true;  // la variable sigue visible en el resto del bloque
    blk->stmts = {decl, set};
    if (isAsync) requestModule({"std", "task"});
    return blk;
}

// Delante del nombre de un miembro: 'IEnumerable<T>.' o 'IDisposable.' (implementación explícita).
// Devuelve la interfaz y deja el cursor en el nombre del miembro; nullptr si no hay ninguna.
TypeRef* Parser::parseExplicitIface() {
    if (cur().kind != TokKind::Ident) return nullptr;
    size_t save = p_;
    bool saveHalf = halfGt_;
    TypeRef* tr = tryParseType();
    auto restore = [&]() -> TypeRef* {
        p_ = save;
        halfGt_ = saveHalf;
        return nullptr;
    };
    if (!tr || tr->ptrDepth || tr->isRef || tr->nullable || tr->isTuple || halfGt_) return restore();
    if (!tr->typeArgs.empty()) {  // IEnumerable<T>.Miembro
        if (isP(".") && peekTok().kind == TokKind::Ident) {
            p_++;
            return tr;
        }
        return restore();
    }
    // IDisposable.Dispose: tryParseType ya consumió el nombre del miembro como parte del tipo.
    if (tr->parts.size() >= 2 && (isP("(") || isP("=>") || isP("{"))) {
        p_--;  // vuelve al nombre del miembro
        tr->parts.pop_back();
        return tr;
    }
    return restore();
}
