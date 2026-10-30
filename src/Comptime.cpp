// Faset - programación en tiempo de compilación (al estilo de 'comptime' de Zig).
//
// Un intérprete pequeño ejecuta, mientras compila, un subconjunto puro del lenguaje: aritmética,
// cadenas, List<T>, StringBuilder, bucles, condicionales, objetos de clases del usuario y llamadas
// a otras funciones. Lo usan:
//
//   comptime expr                 el resultado se escribe en el programa como constante
//   comptime int F(...) { }       cada llamada se evalúa al compilar (los argumentos deben ser
//                                 constantes)
//   comptime if (cond) { } else   solo se comprueba y se genera la rama elegida
//   comptime foreach (var f in Tipo<T>.Miembros) { }
//                                 el cuerpo se repite una vez por elemento (desenrollado), con 'f'
//                                 como valor de tiempo de compilación: f.Nombre, f.Tipo, f.Get(obj)
//   comptime var E = T.Elemento;  valor o tipo con nombre, con el ámbito de una variable local
//   static_assert(cond, "msg");   error de compilación si la condición es falsa
//
// La reflexión de tiempo de compilación (Tipo<T>.Campos, .Propiedades, .Metodos, .Atributos,
// .EsLista, .Elemento...) se resuelve aquí: el código que la usa queda convertido en accesos
// directos a campos, sin metadatos ni coste al ejecutar. Como los genéricos se instancian por
// tipo (igual que las plantillas de C++), una función genérica con 'comptime foreach' genera un
// código distinto y directo para cada T: así funciona la serialización JSON automática.
//
// Límites: kCtMaxSteps pasos y kCtMaxDepth llamadas anidadas por evaluación; un error muestra la
// pila de llamadas de tiempo de compilación.
#include "ComptimeInterp.h"

#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>

#include "Parser.h"


// ==================================================================== Sema: ganchos

CtState& Sema::ct() {
    if (!ct_) ct_ = new CtState();
    return *ct_;
}

// ¿Empieza 'e' en un valor de tiempo de compilación (variable comptime o Tipo<T>)?
static bool ctRooted(Sema& S, Expr* e, bool (*isBound)(Sema&, const std::string&), bool (*userTipo)(Sema&)) {
    // f.Get(obj).Count: lo que sigue a una operación que genera código al ejecutar ya no es comptime.
    for (Expr* x = e; x->kind == EK::Member || x->kind == EK::Call || x->kind == EK::Index;) {
        if (x->kind == EK::Call && x != e) {
            Expr* c = static_cast<CallExpr*>(x)->callee;
            if (c->kind == EK::Member) {
                const std::string& n = static_cast<MemberExpr*>(c)->name;
                if (n == "Get" || n == "Set" || n == "Invocar" || n == "InvocarLista" || n == "Crear") return false;
            }
        }
        x = x->kind == EK::Member ? static_cast<MemberExpr*>(x)->obj
            : x->kind == EK::Call ? static_cast<CallExpr*>(x)->callee
                                  : static_cast<IndexExpr*>(x)->obj;
    }
    Expr* r = rootOf(e);
    if (r->kind != EK::Name) return false;
    auto* n = static_cast<NameExpr*>(r);
    if (n->name == "Tipo" && n->typeArgs.size() == 1) return !userTipo(S);
    return isBound(S, n->name);
}

// IntelliSense: hover de una variable de tiempo de compilación (f en f.Nombre) con su valor.
void CtHooks::hoverRoot(Sema& S, Expr* e) {
    if (!S.ideMode) return;
    Expr* r = rootOf(e);
    if (r->kind != EK::Name) return;
    auto* n = static_cast<NameExpr*>(r);
    VarInfo* v = S.lookupLocal(n->name);
    if (!v || !S.ct().binds.count(v)) return;
    const CtValue& val = S.ct().binds[v];
    std::string shown = CtInterp(S).toStr(val);
    S.addRef(n->loc, (int)n->name.size(), "(comptime) " + kindName(val) + " " + n->name + (shown.empty() ? "" : " = " + shown), &v->loc);
}

Type* Sema::ctName(NameExpr* e) {
    bool tipo = e->name == "Tipo" && e->typeArgs.size() == 1 && !CtHooks::userTipo(*this);
    if (!tipo && !CtHooks::bound(*this, e->name)) return nullptr;
    CtHooks::hoverRoot(*this, e);
    CtInterp I(*this);
    CtValue v;
    if (!I.run(e, v)) return tc_.error();
    return CtHooks::lowerTo(*this, e, v);
}

Type* Sema::ctMember(MemberExpr* e) {
    if (!ctRooted(*this, e, CtHooks::bound, CtHooks::userTipo)) return nullptr;
    if (e == calleeExpr_) return nullptr;  // f.Metodo(...): lo trata ctCall
    CtHooks::hoverRoot(*this, e);
    CtInterp I(*this);
    CtValue v;
    if (!I.run(e, v)) return tc_.error();
    return CtHooks::lowerTo(*this, e, v);
}

namespace {

// Texto de una expresión (para [CallerArgumentExpression]).
std::string exprText(Expr* e) {
    switch (e->kind) {
        case EK::IntLit: return std::to_string(static_cast<IntLitExpr*>(e)->value);
        case EK::FloatLit: {
            char b[64];
            std::snprintf(b, sizeof b, "%g", static_cast<FloatLitExpr*>(e)->value);
            return b;
        }
        case EK::BoolLit: return static_cast<BoolLitExpr*>(e)->value ? "true" : "false";
        case EK::StringLit: return "\"" + static_cast<StringLitExpr*>(e)->value + "\"";
        case EK::CharLit: return "'" + utf8(static_cast<CharLitExpr*>(e)->value) + "'";
        case EK::Null: return "null";
        case EK::This: return "this";
        case EK::Name: return static_cast<NameExpr*>(e)->name;
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            return exprText(m->obj) + (m->arrow ? "->" : ".") + m->name;
        }
        case EK::Call: {
            auto* c = static_cast<CallExpr*>(e);
            std::string s = exprText(c->callee) + "(";
            for (size_t i = 0; i < c->args.size(); i++) s += (i ? ", " : "") + exprText(c->args[i]);
            return s + ")";
        }
        case EK::Index: {
            auto* i = static_cast<IndexExpr*>(e);
            return exprText(i->obj) + "[" + exprText(i->index) + "]";
        }
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            return u->op + exprText(u->operand);
        }
        case EK::Postfix: {
            auto* p = static_cast<PostfixExpr*>(e);
            return exprText(p->operand) + p->op;
        }
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            return exprText(b->lhs) + " " + b->op + " " + exprText(b->rhs);
        }
        case EK::Assign: {
            auto* a = static_cast<AssignExpr*>(e);
            return exprText(a->lhs) + " " + a->op + " " + exprText(a->rhs);
        }
        case EK::Cond: {
            auto* c = static_cast<CondExpr*>(e);
            return exprText(c->cond) + " ? " + exprText(c->a) + " : " + exprText(c->b);
        }
        case EK::Cast: {
            auto* c = static_cast<CastExpr*>(e);
            return c->tref ? "(" + c->tref->str() + ")" + exprText(c->operand) : exprText(c->operand);
        }
        case EK::New: {
            auto* n = static_cast<NewExpr*>(e);
            std::string s = "new " + n->tref->str() + "(";
            for (size_t i = 0; i < n->args.size(); i++) s += (i ? ", " : "") + exprText(n->args[i]);
            return s + ")";
        }
        case EK::TypeOf: return "typeof(" + static_cast<TypeOfExpr*>(e)->tref->str() + ")";
        case EK::Is: {
            auto* i = static_cast<IsExpr*>(e);
            return exprText(i->operand) + (i->negate ? " is not " : " is ") + (i->tref ? i->tref->str() : "null");
        }
        default: return "...";
    }
}

}  // namespace

Type* Sema::ctCall(CallExpr* e) {
    CtState& st = ct();
    // [CallerArgumentExpression("x")]: si falta el último argumento, es el texto del argumento 'x'.
    if (!st.callerScanned) {
        st.callerScanned = true;
        for (ClassDecl* c : prog_.types)
            for (MethodDecl* m : c->methods)
                for (Param& p : m->params)
                    for (Attribute& a : p.attrs)
                        if (a.name == "CallerArgumentExpression" || a.name == "CallerArgumentExpressionAttribute")
                            st.callerArgMethods.insert(m->name);
    }
    std::string calleeName = e->callee->kind == EK::Name     ? static_cast<NameExpr*>(e->callee)->name
                             : e->callee->kind == EK::Member ? static_cast<MemberExpr*>(e->callee)->name
                                                             : "";
    if (!calleeName.empty() && st.callerArgMethods.count(calleeName) && !e->args.empty()) {
        std::vector<MethodDecl*> cands;
        for (ClassDecl* c : prog_.types)
            for (MethodDecl* m : c->methods)
                if (m->name == calleeName && m->params.size() == e->args.size() + 1 + (m->isExtension() ? 1 : 0) &&
                    !m->params.back().attrs.empty())
                    cands.push_back(m);
        for (MethodDecl* m : cands) {
            for (Attribute& a : m->params.back().attrs) {
                if ((a.name != "CallerArgumentExpression" && a.name != "CallerArgumentExpressionAttribute") || a.args.size() != 1) continue;
                size_t off = m->isExtension() ? 1 : 0;
                for (size_t i = off; i + 1 < m->params.size(); i++)
                    if (m->params[i].name == a.args[0] && i - off < e->args.size()) {
                        auto* s = new StringLitExpr(e->loc);
                        s->value = exprText(e->args[i - off]);
                        e->args.push_back(s);
                        goto added;
                    }
            }
        }
    added:;
    }

    if (e->callee->kind == EK::Name) {
        auto* n = static_cast<NameExpr*>(e->callee);
        if (n->name == "static_assert" && !lookupLocal("static_assert")) {
            Sym s = lookupUnqualified("static_assert", e->loc);
            if (s.kind == Sym::None) {
                diag.error(e->loc, "'static_assert' es una sentencia: static_assert(condición, \"mensaje\");");
                return tc_.error();
            }
        }
        return nullptr;
    }
    if (e->callee->kind != EK::Member) return nullptr;
    auto* me = static_cast<MemberExpr*>(e->callee);
    if (!ctRooted(*this, me, CtHooks::bound, CtHooks::userTipo)) return nullptr;
    CtHooks::hoverRoot(*this, me);
    CtInterp I(*this);
    // Operaciones que generan código al ejecutar: f.Get(obj), f.Set(obj, v), m.Invocar(obj, ...), a.Crear().
    if (me->name == "Get" || me->name == "Set" || me->name == "Invocar" || me->name == "InvocarLista" || me->name == "Crear") {
        CtValue h;
        if (!I.run(me->obj, h)) return tc_.error();
        Expr* low = nullptr;
        if (h.k == CtValue::Member && (me->name == "Get" || me->name == "Set")) {
            size_t want = me->name == "Get" ? 1 : 2;
            if (e->args.size() != want) {
                diag.error(e->loc, "'" + me->name + "' espera " + std::to_string(want) + " argumento(s): " +
                                       (want == 1 ? "f.Get(obj)" : "f.Set(obj, valor)"));
                return tc_.error();
            }
            auto* acc = new MemberExpr(e->loc);
            acc->obj = e->args[0];
            acc->name = h.s;
            acc->nameLoc = me->nameLoc;
            if (want == 1) {
                low = acc;
            } else {
                auto* as = new AssignExpr(e->loc);
                as->op = "=";
                as->lhs = acc;
                as->rhs = e->args[1];
                low = as;
            }
        } else if (h.k == CtValue::Method && (me->name == "Invocar" || me->name == "InvocarLista")) {
            // m.Invocar(obj, a, b)  ->  obj.M(a, b);   m.InvocarLista(obj, lista)  ->
            // obj.M(Reflection.Unbox<P0>(lista[0]), ...)  (para la reflexión al ejecutar).
            MethodDecl* m = h.method;
            size_t first = m->isStatic() ? 0 : 1;
            if (e->args.size() < first) {
                diag.error(e->loc, "'" + me->name + "' de un método de instancia necesita el objeto: m." + me->name + "(obj, ...)");
                return tc_.error();
            }
            std::vector<Expr*> args(e->args.begin() + first, e->args.end());
            if (me->name == "InvocarLista") {
                if (args.size() != 1) {
                    diag.error(e->loc, "uso: m.InvocarLista(obj, lista) con una List<object> de argumentos");
                    return tc_.error();
                }
                Expr* list = args[0];
                args.clear();
                for (size_t i = 0; i < m->params.size(); i++) {
                    Expr* q = nullptr;
                    for (const char* part : {"std", "reflection", "Reflection", "Unbox"}) {
                        if (!q) {
                            auto* n0 = new NameExpr(e->loc);
                            n0->name = part;
                            q = n0;
                        } else {
                            auto* mm = new MemberExpr(e->loc);
                            mm->obj = q;
                            mm->name = part;
                            mm->nameLoc = e->loc;
                            q = mm;
                        }
                    }
                    static_cast<MemberExpr*>(q)->typeArgs = {presetRef(m->params[i].type, e->loc)};
                    auto* ix = new IndexExpr(e->loc);
                    ix->obj = list;
                    auto* lit = new IntLitExpr(e->loc);
                    lit->value = i;
                    ix->index = lit;
                    auto* un = new CallExpr(e->loc);
                    un->callee = q;
                    un->args = {ix};
                    args.push_back(un);
                }
            }
            Expr* target = nullptr;
            if (m->isStatic()) {  // por su nombre completo: ns.Clase.Metodo o ns.funcion
                std::vector<std::string> path;
                std::string ns = m->owner->ns;
                for (size_t p = 0; !ns.empty();) {
                    size_t dot = ns.find('.', p);
                    path.push_back(ns.substr(p, dot == std::string::npos ? std::string::npos : dot - p));
                    if (dot == std::string::npos) break;
                    p = dot + 1;
                }
                if (!m->owner->isNamespaceScope) path.push_back(m->owner->name);
                if (m->owner->templateOf) {
                    diag.error(e->loc, "'" + me->name + "' no admite métodos estáticos de tipos genéricos");
                    return tc_.error();
                }
                for (const std::string& part : path) {
                    if (!target) {
                        auto* n0 = new NameExpr(e->loc);
                        n0->name = part;
                        target = n0;
                    } else {
                        auto* mm = new MemberExpr(e->loc);
                        mm->obj = target;
                        mm->name = part;
                        mm->nameLoc = e->loc;
                        target = mm;
                    }
                }
            } else {
                target = e->args[0];
            }
            Expr* callee;
            if (target) {
                auto* acc = new MemberExpr(e->loc);
                acc->obj = target;
                acc->name = m->name;
                acc->nameLoc = me->nameLoc;
                callee = acc;
            } else {
                auto* n0 = new NameExpr(e->loc);
                n0->name = m->name;
                callee = n0;
            }
            auto* call = new CallExpr(e->loc);
            call->callee = callee;
            call->args = args;
            low = call;
        } else if (h.k == CtValue::Obj && h.obj && h.obj->attr && me->name == "Crear") {
            low = attrCreateExpr(h.obj->attr, e->loc);
            if (!low) return tc_.error();
        }
        if (low) {
            e->lowered = low;
            return check(low);
        }
    }
    CtValue v;
    if (!I.run(e, v)) return tc_.error();
    if (v.k == CtValue::Void) {
        e->lowered = new NullExpr(e->loc);  // llamada sin valor (p. ej. lista.Add(x) sobre una lista comptime)
        diag.error(e->loc, "esta llamada solo tiene efecto en tiempo de compilación; úsala dentro de 'comptime'");
        return tc_.error();
    }
    return CtHooks::lowerTo(*this, e, v);
}

Type* Sema::ctAfterCall(CallExpr* e, MethodDecl* m) {
    Type* ret = m->ret;
    CtState& st = ct();
    // [Obsolete("mensaje")] y [Obsolete("mensaje", true)] (error).
    for (Attribute& a : m->attrs) {
        if (a.name == "Obsolete" || a.name == "ObsoleteAttribute") {
            bool inObsolete = false;  // dentro de otro miembro obsoleto no se avisa (como en C#)
            if (ctx_.method)
                for (Attribute& o : ctx_.method->attrs) inObsolete |= o.name == "Obsolete" || o.name == "ObsoleteAttribute";
            if (inObsolete) break;
            bool isError = false;
            if (a.argExprs.size() >= 2 && a.argExprs[1]->kind == EK::BoolLit) isError = static_cast<BoolLitExpr*>(a.argExprs[1])->value;
            std::string what = (m->owner && !m->owner->isNamespaceScope ? m->owner->displayName + "." : "") + m->name;
            std::string msg = "'" + what + "' está obsoleto" + (a.args.empty() ? "" : ": " + a.args[0]);
            std::string key = std::to_string(e->loc.file) + ":" + std::to_string(e->loc.line) + ":" + std::to_string(e->loc.col);
            if (isError) diag.error(e->loc, msg);
            else if (st.obsoleteSeen.insert(key).second) diag.warning(e->loc, msg);
        }
    }
    // [Conditional("DEBUG")]: sin ese símbolo la llamada desaparece (y no se evalúan sus argumentos).
    for (Attribute& a : m->attrs) {
        if ((a.name == "Conditional" || a.name == "ConditionalAttribute") && a.args.size() == 1 && !isDefinedSymbol(a.args[0])) {
            if (!m->ret->isVoid()) break;  // error en la declaración (Attributes.cpp)
            auto* z = new IntLitExpr(e->loc);
            auto* c = new CastExpr(e->loc);
            c->tref = presetRef(tc_.get(TK::Void), e->loc);
            c->operand = z;
            c->type = tc_.get(TK::Void);
            c->implicit = true;
            z->type = tc_.get(TK::Int);
            e->lowered = c;
            return ret;
        }
    }
    // Reflexión al ejecutar: typeof(X).GetFields()... y Activator.CreateInstance pide metadatos de X.
    if (m->owner && m->owner->ns == "std.reflection" && !(ctx_.cls && ctx_.cls->ns == "std.reflection")) {
        for (Expr* a : e->args) {
            Expr* x = a;
            while (x->kind == EK::Cast && static_cast<CastExpr*>(x)->implicit) x = static_cast<CastExpr*>(x)->operand;
            if (x->kind == EK::TypeOf) {
                Type* t = static_cast<TypeOfExpr*>(x)->target;
                if (t && t->isClass() && t->decl) reflectWant(t->decl, x->loc);
            }
        }
        if (m->templateOf && m->name == "CreateInstance")
            for (auto& [n, t] : m->typeArgMap)
                if (t && t->isClass() && t->decl) reflectWant(t->decl, e->loc);
    }
    // Funciones 'comptime': cada llamada se evalúa al compilar (salvo dentro de otra función comptime,
    // que se comprueba como código normal).
    if (m->mods.isComptime && !(ctx_.method && ctx_.method->mods.isComptime) && trialDepth_ == 0) {
        CtInterp I(*this);
        CtValue v;
        if (!I.run(e, v, "al evaluar '" + m->name + "' en tiempo de compilación")) return tc_.error();
        if (m->ret->isVoid()) {
            diag.error(e->loc, "una función 'comptime' debe devolver un valor");
            return tc_.error();
        }
        CtValue cv = I.convert(v, m->ret, e->loc);
        std::string err;
        Expr* x = CtHooks::toExpr(*this, cv, e->loc, err);
        if (!x) {
            diag.error(e->loc, err);
            return tc_.error();
        }
        e->lowered = x;
        if (x->kind != EK::ParamsList) {
            checkValue(x);
            coerce(e->lowered, m->ret);
        }
        return ret;
    }
    return ret;
}

Type* Sema::checkComptimeExpr(ComptimeExpr* e) {
    CtInterp I(*this);
    CtValue v;
    if (!I.run(e->operand, v)) return tc_.error();
    if (v.k == CtValue::Void) {
        diag.error(e->loc, "la expresión 'comptime' no produce ningún valor");
        return tc_.error();
    }
    return CtHooks::lowerTo(*this, e, v);
}

// Tipos de tiempo de compilación en posición de tipo: TypeRef ya resuelto (preset), una variable
// comptime con un tipo (E), una cadena de consultas sobre ella (f.Tipo, f.Tipo.Elemento) o sobre un
// parámetro de tipo (T.Elemento, T.Clave, T.Valor).
Type* Sema::ctResolveType(TypeRef* tr) {
    if (tr->preset) return tr->preset;
    if (!ct_ || tr->parts.empty() || !tr->typeArgs.empty() || tr->isFuncPtr || tr->isTuple) return nullptr;
    const std::string& head = tr->parts[0];
    bool isBound = CtHooks::bound(*this, head);
    bool typeParam = tr->parts.size() > 1 && ((ctx_.method && ctx_.method->typeArgMap.count(head)) ||
                                              (ctx_.cls && ctx_.cls->typeArgMap.count(head)));
    if (!isBound && !typeParam) return nullptr;
    if (typeParam) {
        static const std::set<std::string> queries = {"Elemento", "Clave", "Valor", "Base", "Subyacente"};
        if (!queries.count(tr->parts[1])) return nullptr;
    }
    CtInterp I(*this);
    CtValue v;
    Expr* e = nullptr;
    auto* n = new NameExpr(tr->loc);
    n->name = head;
    e = n;
    for (size_t i = 1; i < tr->parts.size(); i++) {
        auto* m = new MemberExpr(tr->loc);
        m->obj = e;
        m->name = tr->parts[i];
        m->nameLoc = tr->loc;
        e = m;
    }
    if (!I.run(e, v)) return tc_.error();
    if (v.k != CtValue::TypeV) {
        if (v.k == CtValue::Null) diag.error(tr->loc, "'" + tr->str() + "' no es un tipo para este argumento (vale null)");
        else diag.error(tr->loc, "'" + tr->str() + "' no es un tipo (es " + kindName(v) + ")");
        return tc_.error();
    }
    Type* t = v.t;
    if (tr->nullable) t = nullableOf(t, tr->loc);
    for (int i = 0; i < tr->ptrDepth; i++) t = tc_.pointerTo(t);
    return t;
}

bool Sema::ctStmt(Stmt* s) {
    switch (s->kind) {
        case SK::ComptimeIf: {
            auto* is = static_cast<ComptimeIfStmt*>(s);
            CtInterp I(*this);
            CtValue v;
            Stmt* chosen = nullptr;
            if (I.run(is->cond, v)) {
                if (v.k != CtValue::Bool) diag.error(is->cond->loc, "la condición de 'comptime if' debe ser 'bool' (es " + kindName(v) + ")");
                else chosen = v.i ? is->then : is->els;
            }
            if (!chosen) {
                s->lowered = new EmptyStmt(s->loc);
                return true;
            }
            checkStmt(chosen);
            s->lowered = chosen;
            return true;
        }
        case SK::ComptimeVar: {
            auto* d = static_cast<ComptimeVarStmt*>(s);
            CtInterp I(*this);
            CtValue v;
            if (I.run(d->init, v) && !d->tref->isVar()) {
                try {
                    v = I.convert(v, I.resolve(d->tref), d->loc);
                } catch (CtError& err) {
                    I.report(err, d->loc, "");
                }
            }
            if (lookupLocal(d->name)) diag.error(d->nameLoc, "ya existe una variable local o parámetro llamado '" + d->name + "' en este ámbito");
            auto* var = new VarInfo();
            var->name = d->name;
            var->cname = "ct_" + d->name;
            var->type = tc_.error();
            var->loc = d->nameLoc;
            var->isConst = true;
            ctx_.scopes.back()[d->name] = var;
            ct().binds[var] = v;
            d->var = var;
            if (ideMode) addRef(d->nameLoc, (int)d->name.size(), "(comptime) " + kindName(v) + " " + d->name + " = " + CtInterp(*this).toStr(v), &d->nameLoc);
            s->lowered = new EmptyStmt(s->loc);
            return true;
        }
        case SK::ComptimeForeach: {
            auto* fe = static_cast<ComptimeForeachStmt*>(s);
            CtInterp I(*this);
            CtValue coll;
            auto* block = new BlockStmt(s->loc);
            block->noScope = true;
            s->lowered = block;
            if (!I.run(fe->coll, coll)) return true;
            std::vector<CtValue> items;
            if (coll.k == CtValue::List) items = *coll.list;
            else if (coll.k == CtValue::Str)
                for (uint32_t cp : codepoints(coll.s)) items.push_back(I.mkChar(cp));
            else {
                diag.error(fe->coll->loc, "'comptime foreach' recorre una lista de tiempo de compilación (p. ej. Tipo<T>.Miembros), no " + kindName(coll));
                return true;
            }
            if ((int)items.size() > kCtMaxUnroll) {
                diag.error(fe->coll->loc, "'comptime foreach' desenrollaría " + std::to_string(items.size()) + " vueltas (límite: " +
                                              std::to_string(kCtMaxUnroll) + ")");
                return true;
            }
            if ((ct().unrolled += (long long)items.size()) > kCtMaxUnrollTotal) {
                diag.error(fe->coll->loc, "se superó el límite de " + std::to_string(kCtMaxUnrollTotal) +
                                              " vueltas de 'comptime foreach' en el programa (¿bucles anidados demasiado grandes?)");
                return true;
            }
            for (CtValue& it : items) {
                Stmt* body = Parser::reparseStmt(fe->tokens, fe->bodyBegin, fe->file, prog_);
                if (!body) break;
                ctx_.scopes.emplace_back();
                auto* var = new VarInfo();
                var->name = fe->name;
                var->cname = "ct_" + fe->name;
                var->type = tc_.error();
                var->loc = fe->nameLoc;
                var->isConst = true;
                ctx_.scopes.back()[fe->name] = var;
                ct().binds[var] = it;
                if (ideMode) addRef(fe->nameLoc, (int)fe->name.size(), "(comptime) " + kindName(it) + " " + fe->name, &fe->nameLoc);
                int before = diag.errorCount;
                checkStmt(body);
                ctx_.scopes.pop_back();
                block->stmts.push_back(body);
                if (diag.errorCount > before && it.k != CtValue::Void) {
                    std::string shown = I.toStr(it);
                    diag.note(fe->loc, "en la vuelta de 'comptime foreach' con " + fe->name + " = " + (shown.empty() ? kindName(it) : shown));
                }
            }
            return true;
        }
        case SK::ExprStmt: {
            auto* es = static_cast<ExprStmt*>(s);
            if (es->expr->kind != EK::Call) return false;
            auto* c = static_cast<CallExpr*>(es->expr);
            if (c->callee->kind != EK::Name || static_cast<NameExpr*>(c->callee)->name != "static_assert") return false;
            if (lookupLocal("static_assert") || lookupUnqualified("static_assert", c->loc).kind != Sym::None) return false;
            s->lowered = new EmptyStmt(s->loc);
            if (c->args.empty() || c->args.size() > 2) {
                diag.error(c->loc, "uso: static_assert(condición, \"mensaje\");");
                return true;
            }
            CtInterp I(*this);
            CtValue cond, msg;
            if (!I.run(c->args[0], cond, "static_assert")) return true;
            if (cond.k != CtValue::Bool) {
                diag.error(c->args[0]->loc, "la condición de static_assert debe ser 'bool' (es " + kindName(cond) + ")");
                return true;
            }
            if (!cond.i) {
                std::string text = "static_assert falló";
                if (c->args.size() == 2 && I.run(c->args[1], msg, "static_assert")) text += ": " + I.toStr(msg);
                else text += ": " + exprText(c->args[0]);
                diag.error(c->loc, text);
            }
            return true;
        }
        default: return false;
    }
}

bool Sema::ctAlwaysReturns(Stmt* s) {
    if (s->kind == SK::ComptimeIf || s->kind == SK::ComptimeForeach) return s->lowered && alwaysReturns(s->lowered);
    if (s->kind == SK::Block && s->lowered) return alwaysReturns(s->lowered);
    return false;
}

bool Sema::ctAnyChild(Stmt* s, const std::function<bool(Stmt*)>& f) {
    if (s->kind == SK::ComptimeIf) {
        auto* is = static_cast<ComptimeIfStmt*>(s);
        return (is->then && f(is->then)) || (is->els && f(is->els));
    }
    if (s->kind == SK::ComptimeForeach) return static_cast<ComptimeForeachStmt*>(s)->body && f(static_cast<ComptimeForeachStmt*>(s)->body);
    return false;
}

bool Sema::ctContainsBreak(Stmt* s) {
    if (s->kind == SK::ComptimeIf || s->kind == SK::ComptimeForeach) return s->lowered && containsBreak(s->lowered);
    return false;
}

void Sema::ctAfterWork() {
    // static_assert de clases y namespaces (también de cada instancia de una plantilla).
    for (size_t round = 0; round < 50; round++) {
        bool more = false;
        for (size_t i = 0; i < prog_.types.size(); i++) {
            ClassDecl* c = prog_.types[i];
            if (c->isTemplate() || c->staticAsserts.empty()) continue;
            std::vector<Expr*> asserts;
            asserts.swap(c->staticAsserts);
            for (Expr* e : asserts) {
                CtxSave save(*this);
                enter(c, nullptr);
                auto* es = new ExprStmt(e->loc);
                es->expr = e;
                if (!ctStmt(es)) diag.error(e->loc, "uso: static_assert(condición, \"mensaje\");");
            }
            more = true;
        }
        attrCheckAll();          // Attributes.cpp
        more |= reflectStep();   // Reflection.cpp: puede instanciar más plantillas
        processWork();
        while (checkPendingConstraints()) processWork();
        if (!more) break;
    }
}
