// Faset - orden de la inicialización estática y constructores estáticos.
//
// Los campos estáticos (y las constantes, que en C son variables globales) se inicializan en
// fs__static_init. Antes se hacía en el orden en que se comprobaban, así que el inicializador de
// un módulo podía ver a 0 una constante o un campo de otro módulo (p. ej. un 'static Mutex m =
// new Mutex();' que leía Posix.MutexSize antes de su inicialización). Ahora el orden es
// topológico: cada inicializador va después de los campos estáticos que lee, directa o
// indirectamente (a través de los métodos, propiedades, constructores y operadores a los que
// llama, cuyos cuerpos se recorren). Las constantes van primero. Si hay un ciclo, se respeta el
// orden original entre los campos del ciclo.
//
// static Clase() { ... } (constructor estático) se ejecuta después de los inicializadores de los
// campos estáticos de su clase y antes de cualquier inicializador que use la clase (sus campos
// estáticos, sus métodos estáticos o sus constructores), como el primer acceso de C#. Si nadie la
// usa durante la inicialización, se ejecuta al final, antes de Main.
#include <algorithm>
#include <functional>

#include "Sema.h"

namespace {

struct Uses {
    std::set<FieldDecl*> fields;   // campos estáticos leídos o escritos
    std::set<ClassDecl*> classes;  // clases "usadas" (constructor estático pendiente)
};

class UseWalker {
public:
    explicit UseWalker(std::map<MethodDecl*, Uses>& memo) : memo_(memo) {}
    Uses out;

    void method(MethodDecl* m) {
        if (!m) return;
        if (m->isStatic() || m->kind == MethodKind::Ctor) out.classes.insert(m->owner);
        const Uses& u = summary(m);
        out.fields.insert(u.fields.begin(), u.fields.end());
        out.classes.insert(u.classes.begin(), u.classes.end());
    }

    void field(FieldDecl* f) {
        if (!f || !f->isStatic()) return;
        out.fields.insert(f);
        if (f->owner) out.classes.insert(f->owner);
    }

    void expr(Expr* e) {
        if (!e) return;
        if (e->lowered) {
            expr(e->lowered);
            return;
        }
        switch (e->kind) {
            case EK::Name: {
                auto* n = static_cast<NameExpr*>(e);
                if (n->ref == NameExpr::Ref::StaticField) field(n->field);
                else if (n->ref == NameExpr::Ref::Property) method(n->getter);
                break;
            }
            case EK::Member: {
                auto* m = static_cast<MemberExpr*>(e);
                if (m->ref == MemberExpr::Ref::StaticField) field(m->field);
                else if (m->ref == MemberExpr::Ref::Property) method(m->getter);
                if (m->obj && m->obj->vk == ValKind::Value) expr(m->obj);
                break;
            }
            case EK::Call: {
                auto* c = static_cast<CallExpr*>(e);
                if (c->target) method(c->target);
                else expr(c->callee);
                if (c->receiver) expr(c->receiver);
                for (Expr* a : c->args) expr(a);
                break;
            }
            case EK::Index: {
                auto* ix = static_cast<IndexExpr*>(e);
                method(ix->opMethod);
                expr(ix->obj);
                expr(ix->index);
                for (Expr* a : ix->moreIndices) expr(a);
                break;
            }
            case EK::Unary: method(static_cast<UnaryExpr*>(e)->opMethod), expr(static_cast<UnaryExpr*>(e)->operand); break;
            case EK::Postfix: expr(static_cast<PostfixExpr*>(e)->operand); break;
            case EK::Binary: {
                auto* b = static_cast<BinaryExpr*>(e);
                method(b->opMethod);
                expr(b->lhs);
                expr(b->rhs);
                break;
            }
            case EK::Assign: {
                auto* a = static_cast<AssignExpr*>(e);
                method(a->opMethod);
                method(a->setter);
                expr(a->lhs);
                expr(a->rhs);
                break;
            }
            case EK::Cond: {
                auto* c = static_cast<CondExpr*>(e);
                expr(c->cond);
                expr(c->a);
                expr(c->b);
                break;
            }
            case EK::Cast: expr(static_cast<CastExpr*>(e)->operand); break;
            case EK::New: {
                auto* n = static_cast<NewExpr*>(e);
                if (n->type && n->type->isAggregate()) {
                    out.classes.insert(n->type->decl);
                    instanceInit(n->type->decl);
                }
                method(n->ctor);
                for (Expr* a : n->args) expr(a);
                break;
            }
            case EK::NewArray: expr(static_cast<NewArrayExpr*>(e)->count); break;
            case EK::Interp:
                for (auto& p : static_cast<InterpExpr*>(e)->parts) expr(p.expr), method(p.toString);
                break;
            case EK::Tuple:
                for (Expr* x : static_cast<TupleExpr*>(e)->elems) expr(x);
                break;
            case EK::Let: {
                auto* l = static_cast<LetExpr*>(e);
                for (auto& b : l->binds) expr(b.second);
                for (Expr* x : l->seq) expr(x);
                break;
            }
            case EK::ParamsList: {
                auto* p = static_cast<ParamsListExpr*>(e);
                method(p->ctor);
                method(p->add);
                for (Expr* x : p->items) expr(x);
                break;
            }
            case EK::CondAccess: expr(static_cast<CondAccessExpr*>(e)->obj), expr(static_cast<CondAccessExpr*>(e)->access); break;
            case EK::CoalesceAssign:
                expr(static_cast<CoalesceAssignExpr*>(e)->lhs);
                expr(static_cast<CoalesceAssignExpr*>(e)->rhs);
                break;
            case EK::MatchFail: expr(static_cast<MatchFailExpr*>(e)->value); break;
            case EK::Is: expr(static_cast<IsExpr*>(e)->operand); break;
            case EK::As: expr(static_cast<AsExpr*>(e)->operand); break;
            case EK::With: {
                auto* w = static_cast<WithExpr*>(e);
                expr(w->operand);
                for (auto& in : w->inits) expr(in.value);
                break;
            }
            case EK::DelegateConv: expr(static_cast<DelegateConvExpr*>(e)->receiver); break;
            case EK::Await: expr(static_cast<AwaitExpr*>(e)->operand); break;
            default: break;  // literales, lambdas (su cuerpo se ejecuta después), typeof...
        }
    }

    void stmt(Stmt* s) {
        if (!s) return;
        if (s->lowered) {
            stmt(s->lowered);
            return;
        }
        switch (s->kind) {
            case SK::Block:
                for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) stmt(c);
                break;
            case SK::VarDecl:
                for (auto& d : static_cast<VarDeclStmt*>(s)->decls) expr(d.init);
                break;
            case SK::ExprStmt: expr(static_cast<ExprStmt*>(s)->expr); break;
            case SK::If: {
                auto* i = static_cast<IfStmt*>(s);
                expr(i->cond);
                stmt(i->then);
                stmt(i->els);
                break;
            }
            case SK::While: expr(static_cast<WhileStmt*>(s)->cond), stmt(static_cast<WhileStmt*>(s)->body); break;
            case SK::DoWhile: expr(static_cast<DoWhileStmt*>(s)->cond), stmt(static_cast<DoWhileStmt*>(s)->body); break;
            case SK::For: {
                auto* f = static_cast<ForStmt*>(s);
                stmt(f->initDecl);
                for (Expr* x : f->initExprs) expr(x);
                expr(f->cond);
                for (Expr* x : f->iter) expr(x);
                stmt(f->body);
                break;
            }
            case SK::Return: expr(static_cast<ReturnStmt*>(s)->value); break;
            case SK::Throw: expr(static_cast<ThrowStmt*>(s)->value); break;
            case SK::Delete: expr(static_cast<DeleteStmt*>(s)->expr); break;
            case SK::Switch: {
                auto* sw = static_cast<SwitchStmt*>(s);
                expr(sw->subject);
                for (auto& sec : sw->sections) {
                    for (Expr* g : sec.guards) expr(g);
                    for (Stmt* b : sec.body) stmt(b);
                }
                break;
            }
            case SK::Try: {
                auto* t = static_cast<TryStmt*>(s);
                stmt(t->body);
                for (auto& c : t->catches) expr(c.filter), stmt(c.body);
                stmt(t->finallyBody);
                break;
            }
            case SK::Foreach: expr(static_cast<ForeachStmt*>(s)->coll), stmt(static_cast<ForeachStmt*>(s)->body); break;
            case SK::Using: {
                auto* u = static_cast<UsingStmt*>(s);
                stmt(u->decl);
                expr(u->expr);
                stmt(u->body);
                break;
            }
            case SK::Deconstruct: expr(static_cast<DeconstructStmt*>(s)->init); break;
            case SK::Await: {
                auto* a = static_cast<AwaitStmt*>(s);
                if (a->aw) expr(a->aw->operand);
                break;
            }
            default: break;
        }
    }

private:
    std::map<MethodDecl*, Uses>& memo_;
    std::set<ClassDecl*> instanceDone_;

    // Inicializadores de los campos de instancia (se ejecutan en cada 'new').
    void instanceInit(ClassDecl* c) {
        for (ClassDecl* k = c; k; k = k->base) {
            if (!instanceDone_.insert(k).second) break;
            for (FieldDecl* f : k->fields)
                if (!f->isStatic() && f->init) expr(f->init);
        }
    }

    const Uses& summary(MethodDecl* m) {
        auto it = memo_.find(m);
        if (it != memo_.end()) return it->second;
        memo_[m];  // en curso: la recursión ve un resumen vacío
        UseWalker w(memo_);
        if (m->body && m->checked) {
            if (m->kind == MethodKind::Ctor) {
                w.method(m->ctorInitTarget);
                for (Expr* a : m->ctorInitArgs) w.expr(a);
                if (m->owner) w.instanceInit(m->owner);
            }
            w.stmt(m->body);
        }
        // Métodos virtuales: también las implementaciones que los reemplazan (se desconoce cuál se llama).
        memo_[m] = w.out;
        return memo_[m];
    }
};

CallExpr* cctorCall(TypeCtx& tc, MethodDecl* m) {
    auto* callee = new NameExpr(m->loc);
    callee->name = m->name;
    callee->vk = ValKind::MethodGroup;
    callee->group = {m};
    callee->type = tc.get(TK::Void);
    auto* c = new CallExpr(m->loc);
    c->callee = callee;
    c->target = m;
    c->type = tc.get(TK::Void);
    return c;
}

}  // namespace

void Sema::orderStaticInits() {
    // Constructores estáticos: un pseudo-campo cada uno (CodeGen emite solo la llamada).
    std::map<ClassDecl*, FieldDecl*> cctor;
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate()) continue;
        for (MethodDecl* m : c->methods) {
            if (m->name != ".cctor" || !m->checked) continue;
            auto* f = new FieldDecl();
            f->loc = m->loc;
            f->owner = c;
            f->name = ".cctor";
            f->mods.isStatic = true;
            f->type = tc_.get(TK::Void);
            f->staticCtor = m;
            f->init = cctorCall(tc_, m);
            cctor[c] = f;
            staticInits.push_back(f);
        }
    }
    if (staticInits.size() < 2) return;
    std::map<FieldDecl*, size_t> index;
    for (size_t i = 0; i < staticInits.size(); i++) index[staticInits[i]] = i;
    std::map<MethodDecl*, Uses> memo;
    std::vector<std::vector<size_t>> deps(staticInits.size());
    for (size_t i = 0; i < staticInits.size(); i++) {
        FieldDecl* f = staticInits[i];
        UseWalker w(memo);
        if (f->staticCtor) {
            w.method(f->staticCtor);
            for (FieldDecl* g : f->owner->fields)  // los inicializadores de su clase van antes
                if (index.count(g)) deps[i].push_back(index[g]);
        } else {
            w.expr(f->init);
        }
        for (FieldDecl* g : w.out.fields)
            if (g != f && index.count(g)) deps[i].push_back(index[g]);
        for (ClassDecl* c : w.out.classes) {
            if (c == f->owner) continue;  // la propia clase: su constructor estático va después
            auto it = cctor.find(c);
            if (it != cctor.end() && it->second != f) deps[i].push_back(index[it->second]);
        }
        std::sort(deps[i].begin(), deps[i].end());
        deps[i].erase(std::unique(deps[i].begin(), deps[i].end()), deps[i].end());
    }
    std::vector<int> state(staticInits.size(), 0);
    std::vector<FieldDecl*> order;
    std::function<void(size_t)> visit = [&](size_t i) {
        if (state[i]) return;  // hecho, o en curso (ciclo: se deja el orden original)
        state[i] = 1;
        for (size_t d : deps[i]) visit(d);
        state[i] = 2;
        order.push_back(staticInits[i]);
    };
    for (size_t i = 0; i < staticInits.size(); i++)  // primero las constantes
        if (staticInits[i]->mods.isConst) visit(i);
    for (size_t i = 0; i < staticInits.size(); i++) visit(i);
    staticInits = order;
}
