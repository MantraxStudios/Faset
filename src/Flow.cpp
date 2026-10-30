// Faset - flujo: defer / errdefer (Zig, Go) y el operador |> (F#).
//
//   defer S;   resto del bloque        ->  try { resto } finally { S }
//   errdefer S; resto del bloque       ->  bool __errdeferN = false;
//                                          try { try { resto } catch { __errdeferN = true; throw; } }
//                                          finally { if (__errdeferN) S }
//
// Así 'defer' se ejecuta al salir del bloque por cualquier camino (final normal, return, break,
// continue o una excepción), en orden inverso (LIFO: cada uno envuelve a los siguientes), y usa
// la maquinaria de 'finally' de Exceptions.cpp (también en métodos async). Los 'using var' del
// mismo bloque se liberan en el mismo orden inverso (CodeGen los intercala con los finally al
// salir con return/break/continue). 'errdefer' solo corre si se sale por una excepción o por el
// Err/None que devuelve un '?' (Unions.cpp pone la marca a true antes de su 'return').
//
//   a |> f            ->  f(a)
//   a |> F(b, c)      ->  F(a, b, c)        (el valor entra como primer argumento)
//   a |> Metodo(b)    ->  a.Metodo(b)       (si no hay una función 'Metodo' visible: métodos de
//                                            instancia y de extensión)
//   a |> x => cuerpo  ->  (x = a, cuerpo)   (lambda de expresión: sin crear un delegado)
//   a |> (expr)       ->  (expr)(a)         (paréntesis: se llama al valor, p. ej. un delegado)
#include "Sema.h"

namespace {

BlockStmt* asBlock(Stmt* s, SourceLoc loc) {
    if (s->kind == SK::Block) return static_cast<BlockStmt*>(s);
    auto* b = new BlockStmt(loc);
    b->stmts.push_back(s);
    return b;
}

NameExpr* nameRef(const std::string& n, SourceLoc loc) {
    auto* e = new NameExpr(loc);
    e->name = n;
    return e;
}

}  // namespace

void Sema::lowerDefers(std::vector<Stmt*>& stmts) {
    for (size_t i = 0; i < stmts.size(); i++) {
        if (stmts[i]->kind != SK::Defer) continue;
        auto* d = static_cast<DeferStmt*>(stmts[i]);
        SourceLoc loc = d->loc;
        auto* rest = new BlockStmt(i + 1 < stmts.size() ? stmts[i + 1]->loc : loc);
        rest->stmts.assign(stmts.begin() + (long)i + 1, stmts.end());
        BlockStmt* fin = asBlock(d->body, d->body->loc);
        stmts.resize(i);
        if (!d->onError) {
            auto* t = new TryStmt(loc);
            t->body = rest;
            t->finallyBody = fin;
            stmts.push_back(t);
            return;
        }
        std::string flag = "__errdefer" + std::to_string(++deferCounter_);
        auto* vd = new VarDeclStmt(loc);
        vd->tref = new TypeRef();
        vd->tref->loc = loc;
        vd->tref->parts = {"bool"};
        VarDeclStmt::Declarator dc;
        dc.loc = loc;
        dc.name = flag;
        auto* f = new BoolLitExpr(loc);
        dc.init = f;
        vd->decls.push_back(dc);
        auto* inner = new TryStmt(loc);
        inner->body = rest;
        TryStmt::Catch c;
        c.loc = loc;
        c.body = new BlockStmt(loc);
        auto* set = new AssignExpr(loc);
        set->op = "=";
        set->lhs = nameRef(flag, loc);
        auto* t = new BoolLitExpr(loc);
        t->value = true;
        set->rhs = t;
        auto* es = new ExprStmt(loc);
        es->expr = set;
        c.body->stmts.push_back(es);
        c.body->stmts.push_back(new ThrowStmt(loc));
        inner->catches.push_back(c);
        auto* outer = new TryStmt(loc);
        outer->body = new BlockStmt(loc);
        outer->body->stmts.push_back(inner);
        auto* run = new IfStmt(loc);
        run->cond = nameRef(flag, loc);
        run->then = fin;
        outer->finallyBody = new BlockStmt(loc);
        outer->finallyBody->stmts.push_back(run);
        stmts.push_back(vd);
        stmts.push_back(outer);
        return;
    }
}

Type* Sema::checkPipe(PipeExpr* e) {
    SourceLoc loc = e->loc;
    Expr* rhs = e->rhs;
    // ¿'nombre' es algo que se puede llamar o un valor en este ámbito? (si no: a.nombre(...))
    auto visible = [&](const std::string& n) {
        if (lookupLocal(n)) return true;
        if (ctx_.cls && !ctx_.cls->isNamespaceScope &&
            (findField(ctx_.cls, n) || findGetter(ctx_.cls, n) || !findMethods(ctx_.cls, n).empty()))
            return true;
        return lookupUnqualified(n, loc).kind != Sym::None || preludeUnion(n);
    };
    if (rhs->kind == EK::Lambda) {
        auto* l = static_cast<LambdaExpr*>(rhs);
        if (l->params.size() != 1) {
            diag.error(l->loc, "la lambda de '|>' debe tener un parámetro (recibe el valor de la izquierda)");
            return tc_.error();
        }
        Type* A = checkValue(e->lhs);
        if (A->isError()) return A;
        if (l->params[0].tref) {
            Type* pt = resolveType(l->params[0].tref);
            if (pt->isError()) return pt;
            coerce(e->lhs, pt);
            A = pt;
        }
        if (A->isVoid()) {
            diag.error(e->lhs->loc, "la parte izquierda de '|>' no produce ningún valor (es 'void')");
            return tc_.error();
        }
        if (l->exprBody && !l->isAsync) {  // a |> x => cuerpo  ->  (x = a, cuerpo)
            ctx_.scopes.emplace_back();
            VarInfo* v = patternVar(l->params[0].name, A, l->params[0].loc);
            Type* bt = checkValue(l->exprBody);
            ctx_.scopes.pop_back();
            auto* let = new LetExpr(loc);
            let->binds.push_back({v, e->lhs});
            let->seq.push_back(l->exprBody);
            let->type = bt;
            e->lowered = let;
            return bt;
        }
        // Cuerpo de bloque: delegado Func<A, R> (R se infiere del cuerpo) y se invoca.
        if (check(e->rhs)->isError()) return tc_.error();
        LambdaExpr* t = lambdaTrial(l, {A}, nullptr);
        Type* r = t && !t->trialErrors ? lambdaReturnType(t) : nullptr;
        if (!r) r = tc_.get(TK::Void);
        Type* d = tc_.delegateType({A}, r);
        coerce(e->rhs, d);
        if (e->rhs->type->isError()) return tc_.error();
        auto* c = new CallExpr(loc);
        c->callee = e->rhs;
        c->args = {e->lhs};
        c->type = r;
        e->lowered = c;
        return r;
    }
    Expr* call = nullptr;
    if (!e->rhsParen && rhs->kind == EK::Call) {
        auto* c = static_cast<CallExpr*>(rhs);
        if (c->callee->kind == EK::Name && !visible(static_cast<NameExpr*>(c->callee)->name)) {
            auto* n = static_cast<NameExpr*>(c->callee);  // a |> Where(f)  ->  a.Where(f)
            auto* m = new MemberExpr(n->loc);
            m->obj = e->lhs;
            m->name = n->name;
            m->nameLoc = n->loc;
            m->typeArgs = n->typeArgs;
            c->callee = m;
        } else {
            c->args.insert(c->args.begin(), e->lhs);  // a |> F(b)  ->  F(a, b)
        }
        call = c;
    } else if (!e->rhsParen && rhs->kind == EK::Name && !visible(static_cast<NameExpr*>(rhs)->name)) {
        auto* n = static_cast<NameExpr*>(rhs);  // a |> Trim  ->  a.Trim()
        auto* m = new MemberExpr(n->loc);
        m->obj = e->lhs;
        m->name = n->name;
        m->nameLoc = n->loc;
        m->typeArgs = n->typeArgs;
        auto* c = new CallExpr(loc);
        c->callee = m;
        call = c;
    } else {
        auto* c = new CallExpr(loc);  // a |> f  ->  f(a)
        c->callee = rhs;
        c->args = {e->lhs};
        call = c;
    }
    Type* t = check(call);
    e->lowered = call;
    return t;
}
