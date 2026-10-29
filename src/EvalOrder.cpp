// Faset - orden de evaluación de C#: los operandos y los argumentos se evalúan de izquierda a
// derecha, el receptor antes que los argumentos y, en una asignación, las subexpresiones del
// lado izquierdo antes que el lado derecho.
//
// C no garantiza nada de eso: el orden de los argumentos no está especificado, los operandos de
// un operador binario no están secuenciados y 'a[i++] = i' es comportamiento indefinido. Por eso:
//
//   1. Análisis (effects): qué lee y qué escribe cada expresión. Las variables locales que no
//      captura ninguna lambda y cuya dirección no se toma son "simples" (solo las cambia una
//      asignación que se ve en la propia expresión); el resto es "memoria". Las llamadas leen y
//      escriben memoria salvo que el método sea puro (se analiza su cuerpo; Math.* es puro).
//   2. Reescritura (sequence): si un operando anterior entra en conflicto con uno posterior
//      (uno escribe lo que el otro lee o escribe), el anterior se guarda antes en un temporal
//      con el operador coma de C, que es un punto de secuencia: (t1 = A, F(t1, B)).
//
// El código normal (operandos sin conflictos) sale exactamente igual que antes. Los temporales
// son los de SugarGen.cpp (newTemp): se declaran al principio de la función en C.
#include <algorithm>
#include <functional>

#include "CodeGen.h"

// ------------------------------------------------------------------ efectos

const char kEvalElems[] = "elementos";

namespace {

void addKey(std::vector<const void*>& ks, const void* k) {
    if (std::find(ks.begin(), ks.end(), k) == ks.end()) ks.push_back(k);
}

bool intersects(const std::vector<const void*>& a, const std::vector<const void*>& b) {
    for (const void* k : a)
        if (std::find(b.begin(), b.end(), k) != b.end()) return true;
    return false;
}

// Variable local que solo puede cambiar una asignación visible en la expresión.
bool plainLocal(VarInfo* v) { return v && !v->captured && !v->isRef && !v->addrTaken; }

// Clave de una variable local: ella misma, o los elementos si se accede por dirección.
const void* localKey(VarInfo* v) { return v->isRef || v->addrTaken ? (const void*)kEvalElems : (const void*)v; }

// Funciones de C de std.Math (sqrt, sin...) y los métodos de Math que las envuelven: puras.
bool isMathClass(ClassDecl* c) { return c && c->name == "Math" && c->ns == "std"; }

// Funciones del runtime que no escriben nada visible: 1 = puras (reservan memoria nueva),
// 2 = solo leen memoria. El resto de funciones 'extern' pueden tener efectos (E/S, relojes...).
int runtimeExternEffect(const std::string& name) {
    static const char* const pure[] = {"faset_alloc", "faset_alloc_zeroed", "faset_alloc_atomic", "faset_i64_to_str",
                                       "faset_u64_to_str", "faset_f64_to_str"};
    static const char* const reads[] = {"faset_obj_type", "faset_type_assignable", "faset_type_base", "faset_type_flags",
                                        "faset_type_fullname", "faset_type_kind", "faset_type_name",
                                        "faset_type_enum_count", "faset_type_enum_name", "faset_type_enum_value",
                                        "faset_obj_hash", "faset_mem_compare", "faset_str_concat", "faset_str_copy",
                                        "faset_str_from_cstr", "faset_str_make"};
    for (const char* n : pure)
        if (name == n) return 1;
    for (const char* n : reads)
        if (name == n) return 2;
    return 3;
}

}  // namespace

void EvalEffects::merge(const EvalEffects& o) {
    readsMem |= o.readsMem;
    writesMem |= o.writesMem;
    readsAny |= o.readsAny;
    writesAny |= o.writesAny;
    for (const void* k : o.reads) addKey(reads, k);
    for (const void* k : o.writes) addKey(writes, k);
}

void EvalEffects::read(const void* key, bool mem) {
    addKey(reads, key);
    readsMem |= mem;
}

void EvalEffects::write(const void* key, bool mem) {
    addKey(writes, key);
    writesMem |= mem;
}

void EvalEffects::call(int level) {
    if (level >= 2) readsMem = readsAny = true;
    if (level >= 3) writesMem = writesAny = true;
}

bool EvalEffects::conflictsWith(const EvalEffects& later) const {
    if (later.writesAny && (readsMem || writesMem)) return true;
    if (writesAny && (later.readsMem || later.writesMem)) return true;
    if ((readsAny && later.writesMem) || (later.readsAny && writesMem)) return true;
    return intersects(later.writes, reads) || intersects(later.writes, writes) || intersects(writes, later.reads);
}

// Escribir en un lvalue: la variable, el campo o los elementos que cambian.
EvalEffects CodeGen::storeEffects(Expr* e) {
    EvalEffects r;
    while (e->lowered) e = e->lowered;
    switch (e->kind) {
        case EK::Name: {
            auto* n = static_cast<NameExpr*>(e);
            if (n->ref == NameExpr::Ref::Local) r.write(localKey(n->var), !plainLocal(n->var));
            else if (n->field) r.write(n->field, true);
            else r.call(3);
            return r;
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref == MemberExpr::Ref::StaticField) r.write(m->field, true);
            else if (m->ref != MemberExpr::Ref::Field) r.call(3);
            else if (m->arrow) r.write(kEvalElems, true);
            else if (m->obj->type->isClass() || m->obj->kind == EK::This) r.write(m->field, true);
            else return storeEffects(m->obj);  // campo de un struct: cambia el struct
            return r;
        }
        default:  // a[i], *p, referencias que devuelve una llamada
            r.write(kEvalElems, true);
            return r;
    }
}

// Dirección de un lvalue (sin leer su valor): x -> nada; a[i] -> a, i; p.Campo (clase) -> p.
EvalEffects CodeGen::locEffects(Expr* e) {
    if (e->lowered) return locEffects(e->lowered);
    switch (e->kind) {
        case EK::Name: case EK::This: return {};
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref == MemberExpr::Ref::StaticField) return {};
            if (m->ref != MemberExpr::Ref::Field) return effects(e);
            if (m->arrow || m->obj->type->isClass()) return effects(m->obj);
            return locEffects(m->obj);  // campo de un struct: donde esté el struct
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            if (ix->opMethod) return effects(e);  // operator[] que devuelve T&
            EvalEffects r = effects(ix->obj);
            r.merge(effects(ix->index));
            return r;
        }
        case EK::Unary:
            if (static_cast<UnaryExpr*>(e)->op == "*") return effects(static_cast<UnaryExpr*>(e)->operand);
            return effects(e);
        default: return effects(e);  // llamada que devuelve T&, temporales...
    }
}

// Convertir a texto con '+': ToString() del usuario (virtual en las clases) puede tener efectos.
EvalEffects CodeGen::convEffects(Expr* e) {
    EvalEffects r;
    Type* t = e->type;
    if (t && !t->is(TK::String) && (t->isClass() || isTupleType(t) || findToString(t))) r.call(3);
    return r;
}

EvalEffects CodeGen::callEffects(MethodDecl* m, Expr* recv, bool arrow, bool nonVirtual, const std::vector<Expr*>& args) {
    EvalEffects r;
    int me = methodEffect(m, nonVirtual);
    if (recv) {
        r.merge(effects(recv));
        // Receptor struct por dirección: el método puede modificarlo.
        if (me == 3 && !arrow && recv->type->isStruct()) r.merge(storeEffects(recv));
    }
    for (size_t i = 0; i < args.size(); i++) {
        r.merge(effects(args[i]));
        if (m && i < m->params.size() && m->params[i].isRef()) r.merge(storeEffects(args[i]));
    }
    r.call(me);
    return r;
}

EvalEffects CodeGen::effects(Expr* e) {
    if (!e) return {};
    if (effState_ == 0) computeMethodEffects();
    if (effState_ == 1) return effectsImpl(e);  // tabla de métodos provisional: sin caché
    auto it = effCache_.find(e);
    if (it != effCache_.end()) return it->second;
    EvalEffects r = effectsImpl(e);
    effCache_[e] = r;
    return r;
}

EvalEffects CodeGen::effectsImpl(Expr* e) {
    EvalEffects r;
    auto add = [&](Expr* x) {
        if (x) r.merge(effects(x));
    };
    if (e->lowered) return effects(e->lowered);
    switch (e->kind) {
        case EK::IntLit: case EK::FloatLit: case EK::BoolLit: case EK::CharLit: case EK::StringLit: case EK::Null:
        case EK::Default: case EK::SizeOf: case EK::TypeOf: case EK::NameOf: case EK::Lambda: case EK::CondRecv:
            break;
        case EK::This:
            if (e->type && e->type->isStruct()) r.call(2);  // (*self): todos los campos
            break;
        case EK::Name: {
            auto* n = static_cast<NameExpr*>(e);
            switch (n->ref) {
                case NameExpr::Ref::Local: r.read(localKey(n->var), !plainLocal(n->var)); break;
                case NameExpr::Ref::Field: case NameExpr::Ref::StaticField: r.read(n->field, true); break;
                case NameExpr::Ref::Property: r = callEffects(n->getter, nullptr, false, false, {}); break;
                case NameExpr::Ref::Base: break;
                default: r.call(3); break;
            }
            break;
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            switch (m->ref) {
                case MemberExpr::Ref::Field:
                    if (m->arrow) {
                        add(m->obj);
                        r.read(kEvalElems, true);
                    } else if (m->obj->type->isClass()) {
                        add(m->obj);
                        r.read(m->field, true);
                    } else if (m->obj->kind == EK::This) {
                        r.read(m->field, true);  // this.Campo en un struct
                    } else {
                        add(m->obj);  // campo de un struct: se lee el struct
                    }
                    break;
                case MemberExpr::Ref::StaticField: r.read(m->field, true); break;
                case MemberExpr::Ref::EnumConst: case MemberExpr::Ref::ConstInt: break;
                case MemberExpr::Ref::StrLength: case MemberExpr::Ref::StrPtr:
                    add(m->obj);
                    if (m->arrow) r.read(kEvalElems, true);
                    break;
                case MemberExpr::Ref::Property:
                    r = callEffects(m->getter, m->getter && m->getter->isStatic() ? nullptr : m->obj, m->arrow,
                                    m->nonVirtual, {});
                    break;
                case MemberExpr::Ref::DelegateInvoke: add(m->obj); break;
                default: r.call(3); break;
            }
            break;
        }
        case EK::Call: {
            auto* c = static_cast<CallExpr*>(e);
            if (!c->target) {  // delegado o puntero a función
                add(c->callee);
                for (Expr* a : c->args) add(a);
                r.call(3);
            } else if (c->intrinsic == 1) {
                add(c->receiver);
            } else {
                Expr* recv = !c->target->isStatic() && !c->implicitThis ? c->receiver : nullptr;
                r = callEffects(c->target, recv, c->receiverArrow, c->nonVirtual, c->args);
            }
            break;
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            if (ix->opMethod) {
                r = callEffects(ix->opMethod, ix->obj, false, false, {ix->index});
            } else {
                add(ix->obj);
                add(ix->index);
                if (!ix->obj->type->is(TK::String)) r.read(kEvalElems, true);
            }
            break;
        }
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            if (u->funcRef) break;
            if (u->opMethod) {
                r = callEffects(u->opMethod, nullptr, false, false, {u->operand});
            } else if (u->op == "++" || u->op == "--") {
                add(u->operand);
                r.merge(storeEffects(u->operand));
            } else if (u->op == "&") {
                r = locEffects(u->operand);
            } else {
                add(u->operand);
                if (u->op == "*") r.read(kEvalElems, true);
            }
            break;
        }
        case EK::Postfix: {
            auto* p = static_cast<PostfixExpr*>(e);
            add(p->operand);
            r.merge(storeEffects(p->operand));
            break;
        }
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            if (b->opMethod) {
                r = callEffects(b->opMethod, nullptr, false, false, {b->lhs, b->rhs});
                break;
            }
            add(b->lhs);
            add(b->rhs);
            if (b->op == "+" && e->type->is(TK::String)) {
                r.merge(convEffects(b->lhs));
                r.merge(convEffects(b->rhs));
            }
            break;
        }
        case EK::Assign: {
            auto* a = static_cast<AssignExpr*>(e);
            if (a->setter) {
                Expr* recv = nullptr;
                if (!a->setter->isStatic() && a->lhs->kind == EK::Member) recv = static_cast<MemberExpr*>(a->lhs)->obj;
                r = callEffects(a->setter, recv, false, false, {a->rhs});
                break;
            }
            r = locEffects(a->lhs);
            if (a->op != "=") r.merge(effects(a->lhs));  // lee el valor anterior
            add(a->rhs);
            r.merge(storeEffects(a->lhs));
            if (a->opMethod) r.call(methodEffect(a->opMethod, false));
            if (a->op == "+=" && a->lhs->type->is(TK::String)) r.merge(convEffects(a->rhs));
            if ((a->op == "+=" || a->op == "-=") && a->lhs->type->isDelegate()) r.call(2);
            break;
        }
        case EK::Cond: {
            auto* c = static_cast<CondExpr*>(e);
            add(c->cond);
            add(c->a);
            add(c->b);
            break;
        }
        case EK::Cast: add(static_cast<CastExpr*>(e)->operand); break;
        case EK::New: {
            auto* n = static_cast<NewExpr*>(e);
            for (Expr* a : n->args) add(a);
            if (n->ctor)
                for (size_t i = 0; i < n->args.size() && i < n->ctor->params.size(); i++)
                    if (n->ctor->params[i].isRef()) r.merge(storeEffects(n->args[i]));
            // Un struct con constructor puro no tiene efectos; una clase puede ejecutar los
            // constructores de la base (y su tipo dinámico es observable).
            ClassDecl* c = n->type->decl;
            r.call(c->kind == ClassKind::Struct && ctorPure(c, n->ctor) ? 2 : 3);
            break;
        }
        case EK::NewArray: add(static_cast<NewArrayExpr*>(e)->count); break;
        case EK::DelegateConv: add(static_cast<DelegateConvExpr*>(e)->receiver); break;
        case EK::Is: {
            auto* is = static_cast<IsExpr*>(e);
            add(is->operand);
            if (is->var) r.write(localKey(is->var), !plainLocal(is->var));
            break;
        }
        case EK::As: add(static_cast<AsExpr*>(e)->operand); break;
        case EK::With: {
            auto* w = static_cast<WithExpr*>(e);
            add(w->operand);
            for (auto& in : w->inits) add(in.value);
            r.call(2);  // copia todos los campos del registro
            break;
        }
        case EK::Interp: {
            for (auto& part : static_cast<InterpExpr*>(e)->parts) {
                if (!part.expr) continue;
                add(part.expr);
                r.merge(convEffects(part.expr));
            }
            break;
        }
        case EK::CondAccess: {
            auto* ca = static_cast<CondAccessExpr*>(e);
            add(ca->obj);
            add(ca->access);
            break;
        }
        case EK::Tuple:
            for (Expr* x : static_cast<TupleExpr*>(e)->elems) add(x);
            break;
        case EK::Let: {
            auto* l = static_cast<LetExpr*>(e);
            for (auto& [v, init] : l->binds) {
                add(init);
                r.write(localKey(v), !plainLocal(v));
            }
            for (Expr* x : l->seq) add(x);
            break;
        }
        case EK::CoalesceAssign: {
            auto* ca = static_cast<CoalesceAssignExpr*>(e);
            r = locEffects(ca->lhs);
            add(ca->lhs);
            add(ca->rhs);
            r.merge(storeEffects(ca->lhs));
            break;
        }
        case EK::ParamsList:
            for (Expr* x : static_cast<ParamsListExpr*>(e)->items) add(x);
            r.call(3);
            break;
        default:
            // MatchFail (panic) y cualquier nodo que este análisis no conozca (p. ej. 'await'):
            // se trata como una llamada que lee y escribe memoria.
            r.call(3);
            break;
    }
    return r;
}

// ------------------------------------------------------------------ métodos puros

// Tabla de efectos de todos los métodos: 1 = puro, 2 = solo lee memoria, 3 = puede escribirla
// (o hacer E/S, lanzar excepciones...). Es un punto fijo: se empieza suponiendo que todos son
// puros y se sube hasta que nada cambia (así la recursión, como en Fib, no lo estropea).
void CodeGen::computeMethodEffects() {
    effState_ = 1;
    std::vector<MethodDecl*> all;
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate() || c->kind == ClassKind::Enum) continue;
        for (MethodDecl* m : c->methods) all.push_back(m);
        for (MethodDecl* m : c->ctors) all.push_back(m);
    }
    all.insert(all.end(), sema_.genericMethods.begin(), sema_.genericMethods.end());
    std::vector<MethodDecl*> work;
    for (MethodDecl* m : all) {
        if (!m || !m->body || !m->checked || m->isTemplate() || m->mods.isExtern) continue;
        if (methodEff_.emplace(m, 1).second) work.push_back(m);
    }
    for (bool changed = true; changed;) {
        changed = false;
        for (MethodDecl* m : work) {
            int r = bodyEffect(m);
            if (r > methodEff_[m]) {
                methodEff_[m] = r;
                changed = true;
            }
        }
    }
    effState_ = 2;
}

int CodeGen::bodyEffect(MethodDecl* m) {
    bool ctor = m->kind == MethodKind::Ctor;
    if (ctor && m->ctorInit) return 3;  // : base(...) / : this(...)
    int r = 1;
    for (Stmt* s : m->body->stmts) r = std::max(r, stmtEffect(s, ctor ? m : nullptr));
    return r;
}

int CodeGen::methodEffect(MethodDecl* m, bool nonVirtual) {
    if (!m) return 3;
    // Despacho virtual o de interfaz: no se sabe qué método se ejecutará.
    if (!m->isStatic() && m->owner &&
        (m->owner->isInterface() ||
         (m->vslot >= 0 && m->vroot && !nonVirtual && !m->mods.isSealed && !m->owner->mods.isSealed)))
        return 3;
    if (m->mods.isExtern) return isMathClass(m->owner) ? 1 : runtimeExternEffect(m->cname);
    if (m->kind == MethodKind::Ctor) return 3;  // los constructores se analizan en ctorPure
    auto it = methodEff_.find(m);
    return it != methodEff_.end() ? it->second : 3;
}

// Efecto de una sentencia de un cuerpo (ver computeMethodEffects). Las variables locales del
// propio método no cuentan; en un constructor ('ctor'), tampoco los campos del objeto nuevo.
int CodeGen::stmtEffect(Stmt* s, MethodDecl* ctor) {
    if (!s) return 1;
    if (s->lowered) return stmtEffect(s->lowered, ctor);
    auto level = [](const EvalEffects& v) { return v.writesMem ? 3 : v.readsMem ? 2 : 1; };
    auto ex = [&](Expr* e) {
        if (!e) return 1;
        if (ctor && e->kind == EK::Assign && !e->lowered) {  // this.Campo = valor
            auto* a = static_cast<AssignExpr*>(e);
            Expr* l = a->lhs;
            bool own = a->op == "=" && !a->setter &&
                       ((l->kind == EK::Name && static_cast<NameExpr*>(l)->ref == NameExpr::Ref::Field) ||
                        (l->kind == EK::Member && static_cast<MemberExpr*>(l)->ref == MemberExpr::Ref::Field &&
                         static_cast<MemberExpr*>(l)->obj->kind == EK::This));
            if (own) return level(effects(a->rhs));
        }
        return level(effects(e));
    };
    int r = 1;
    switch (s->kind) {
        case SK::Empty: case SK::Break: case SK::Continue: break;
        case SK::Block:
            for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) r = std::max(r, stmtEffect(c, ctor));
            break;
        case SK::VarDecl:
            for (auto& dc : static_cast<VarDeclStmt*>(s)->decls) r = std::max(r, ex(dc.init));
            break;
        case SK::ExprStmt: r = ex(static_cast<ExprStmt*>(s)->expr); break;
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            r = std::max({ex(is->cond), stmtEffect(is->then, ctor), stmtEffect(is->els, ctor)});
            break;
        }
        case SK::While: {
            auto* ws = static_cast<WhileStmt*>(s);
            r = std::max(ex(ws->cond), stmtEffect(ws->body, ctor));
            break;
        }
        case SK::DoWhile: {
            auto* ds = static_cast<DoWhileStmt*>(s);
            r = std::max(ex(ds->cond), stmtEffect(ds->body, ctor));
            break;
        }
        case SK::For: {
            auto* fs = static_cast<ForStmt*>(s);
            r = std::max({stmtEffect(fs->initDecl, ctor), ex(fs->cond), stmtEffect(fs->body, ctor)});
            for (Expr* x : fs->initExprs) r = std::max(r, ex(x));
            for (Expr* x : fs->iter) r = std::max(r, ex(x));
            break;
        }
        case SK::Return: r = ex(static_cast<ReturnStmt*>(s)->value); break;
        case SK::Switch: {  // con patrones viene reescrito (lowered); aquí solo hay constantes
            auto* ss = static_cast<SwitchStmt*>(s);
            r = ex(ss->subject);
            for (auto& sec : ss->sections) {
                for (Expr* g : sec.guards) r = std::max(r, ex(g));
                for (Stmt* b : sec.body) r = std::max(r, stmtEffect(b, ctor));
            }
            break;
        }
        default: r = 3; break;  // try, throw, delete, using...: se supone que tiene efectos
    }
    return r;
}

// ¿Construir este struct no escribe nada visible? (inicializadores de campos y constructor)
bool CodeGen::ctorPure(ClassDecl* c, MethodDecl* ctor) {
    for (FieldDecl* f : c->fields)
        if (!f->isStatic() && f->init && effects(f->init).writesMem) return false;
    if (!ctor) return true;
    auto it = methodEff_.find(ctor);
    return it != methodEff_.end() && it->second < 3;
}

// ------------------------------------------------------------------ reescritura

std::string CodeGen::seqWrap(const std::string& pre, const std::string& code) {
    return pre.empty() ? code : "(" + pre + code + ")";
}

// Igual, pero el resultado sigue siendo un lvalue (el operador coma de C da un rvalue).
std::string CodeGen::seqWrapLv(const std::string& pre, const std::string& code) {
    return pre.empty() ? code : "(*(" + pre + "&" + code + "))";
}

// Decide qué operandos se evalúan antes en temporales: el operando i, si entra en conflicto
// con alguno posterior. Los que no se mueven no entran en conflicto con nada de lo que queda
// detrás, así que da igual que C los evalúe en cualquier orden.
std::string CodeGen::sequence(std::vector<EvalOp>& ops) {
    if (ops.size() < 2) return "";
    std::vector<EvalEffects> eff;
    bool anyWrites = false;
    for (EvalOp& op : ops) {
        EvalEffects x = op.e ? (op.addr ? locEffects(op.e) : effects(op.e)) : EvalEffects();
        if (op.e && op.conv) x.merge(convEffects(op.e));
        anyWrites |= x.hasWrites();
        eff.push_back(std::move(x));
    }
    if (!anyWrites) return "";  // el caso normal: nada que ordenar
    std::string pre;
    for (size_t i = 0; i + 1 < ops.size(); i++) {
        bool need = false;
        for (size_t j = i + 1; j < ops.size() && !need; j++) need = eff[i].conflictsWith(eff[j]);
        if (!need) continue;
        EvalOp& op = ops[i];
        op.hoisted = true;
        if (op.addr) {
            op.tmp = newTemp("void*");
            pre += op.tmp + " = (void*)&" + op.code + ", ";
            op.code = "(*(" + op.ct + "*)" + op.tmp + ")";
        } else {
            op.tmp = newTemp(op.ct);
            pre += op.tmp + " = " + op.code + ", ";
            op.code = op.tmp;
        }
    }
    return pre;
}

// Receptor de una llamada de instancia (se evalúa antes que los argumentos).
CodeGen::EvalOp CodeGen::recvOp(Expr* recv, bool arrow) {
    EvalOp op;
    op.e = recv;
    op.code = expr(recv);
    op.ct = ctype(recv->type);
    // Un struct que es un lvalue se pasa por dirección: el método ve (y modifica) la variable.
    op.addr = !arrow && !recv->type->isClass() && cgIsLValue(recv);
    return op;
}

// El 'self' de la llamada a partir del receptor (ver receiverPtr).
std::string CodeGen::recvCode(const EvalOp& op, Expr* recv, bool arrow) {
    const std::string& r = op.code;
    Type* t = recv->type;
    if (arrow) return t->elem->isClass() ? "(*" + r + ")" : r;
    if (t->isClass()) return chkObj(recv, r);
    if (op.hoisted) return op.addr ? "((" + op.ct + "*)" + op.tmp + ")" : "(&" + op.tmp + ")";
    if (op.addr) return "(&" + r + ")";
    return "((" + t->decl->cname + "[]){" + r + "})";  // receptor temporal: literal compuesto
}

// ------------------------------------------------------------------ asignaciones

// a = b, a op= b. C#: primero la dirección de 'a' (a[i], obj.Campo), después (si es compuesta)
// su valor, después 'b' y por último la escritura. Se mueve a temporales solo lo necesario:
//   lista[i++] = i   ->  (fs_t1 = (void*)&lista[i++], (*(int32_t*)fs_t1) = i)
//   campo += Leer()  ->  (fs_t2 = self->campo, self->campo = fs_t2 + Leer())
std::string CodeGen::assignExpr(AssignExpr* a) {
    if (a->setter) {
        if (!a->setter->isStatic() && a->lhs->kind == EK::Member) {
            auto* m = static_cast<MemberExpr*>(a->lhs);
            return call(a->setter, "", {a->rhs}, a->loc, m->nonVirtual, m->obj, m->arrow);
        }
        return call(a->setter, a->setter->isStatic() ? "" : "self", {a->rhs}, a->loc);
    }
    Expr* L = a->lhs;
    Type* lt = L->type;
    const std::string& op = a->op;
    bool compound = op != "=";
    bool dlg = (op == "+=" || op == "-=") && lt->isDelegate();
    bool str = op == "+=" && lt->is(TK::String);
    bool shl = op == "<<=" && lt->isIntegral();
    bool shr = op == ">>=" && lt->isIntegral();
    bool dup = a->opMethod || dlg || str || shl;  // formas de C que repiten el lado izquierdo

    std::string lcode = expr(L);
    std::string rcode = str ? toStr(a->rhs) : expr(a->rhs);

    EvalEffects locE = locEffects(L);
    EvalEffects rE = effects(a->rhs);
    if (str) rE.merge(convEffects(a->rhs));
    std::string pre;
    if (rE.hasWrites() || locE.hasWrites()) {
        EvalEffects tgt = storeEffects(L);
        EvalEffects valE;  // leer el valor anterior (sin calcular la dirección)
        for (const void* k : tgt.writes) valE.read(k, tgt.writesMem);
        valE.readsAny = tgt.writesAny;
        // 'x = x++': el lado derecho escribe directamente lo mismo que la asignación (dentro de
        // una llamada no importa: la llamada termina antes de la escritura).
        bool hoistR = intersects(tgt.writes, rE.writes);
        bool hoistVal = compound && (valE.conflictsWith(rE) || hoistR);
        bool hoistLoc = locE.conflictsWith(rE) || (dup && locE.hasWrites()) || ((hoistVal || hoistR) && locE.any());
        if (hoistLoc) {
            std::string tp = newTemp("void*");
            pre += tp + " = (void*)&" + lcode + ", ";
            lcode = "(*(" + ctype(lt) + "*)" + tp + ")";
        }
        std::string vcode = lcode;
        if (hoistVal) {
            vcode = newTemp(ctype(lt));
            pre += vcode + " = " + lcode + ", ";
        }
        if (hoistR) {
            std::string tr = newTemp(str ? "faset_string" : ctype(a->rhs->type));
            pre += tr + " = " + rcode + ", ";
            rcode = tr;
        }
        if (hoistVal && !dup) {  // a op= b  ->  a = valor op b
            std::string bop = op.substr(0, op.size() - 1);
            std::string r = rcode;
            if (shr) r = "(" + r + ") & " + std::string(lt->is(TK::Long) || lt->is(TK::ULong) ? "63" : "31");
            if ((op == "/=" || op == "%=") && lt->isIntegral()) {
                int64_t k = 0;
                if (!(sema_.constEval(a->rhs, k) && k != 0))
                    r = std::string(lt->is(TK::ULong) ? "faset_divisor_u64(" : "faset_divisor_i64(") + r + ", " +
                        callerLoc(a->loc) + ")";
            }
            return seqWrap(pre, "(" + lcode + " = " + vcode + " " + bop + " (" + r + "))");
        }
        // Formas que repiten el lado izquierdo: la lectura usa el valor guardado si lo hay.
        if (a->opMethod)
            return seqWrap(pre, "(" + lcode + " = " + callCode(a->opMethod, "", {vcode, rcode}, a->loc, false) + ")");
        if (dlg)
            return seqWrap(pre, "(" + lcode + " = " + (op == "+=" ? "faset_dlg_combine(" : "faset_dlg_remove(") + vcode +
                                    ", " + rcode + "))");
        if (str) return seqWrap(pre, "(" + lcode + " = faset_str_concat(" + vcode + ", " + rcode + "))");
        if (shl) {
            bool wide = lt->is(TK::Long) || lt->is(TK::ULong);
            std::string ut = wide ? "uint64_t" : "uint32_t";
            return seqWrap(pre, "(" + lcode + " = (" + ctype(lt) + ")((" + ut + ")(" + vcode + ") << ((" + rcode + ") & " +
                                    (wide ? "63" : "31") + ")))");
        }
    }
    // Sin conflictos (o ya resueltos con temporales): la forma directa.
    if (a->opMethod) return seqWrap(pre, "(" + lcode + " = " + callCode(a->opMethod, "", {lcode, rcode}, a->loc, false) + ")");
    if (dlg)
        return seqWrap(pre, "(" + lcode + " = " + (op == "+=" ? "faset_dlg_combine(" : "faset_dlg_remove(") + lcode + ", " +
                                rcode + "))");
    if (str) return seqWrap(pre, "(" + lcode + " = faset_str_concat(" + lcode + ", " + rcode + "))");
    if (shl || shr) {
        bool wide = lt->is(TK::Long) || lt->is(TK::ULong);
        std::string mask = wide ? "63" : "31";
        if (shr) return seqWrap(pre, "(" + lcode + " >>= ((" + rcode + ") & " + mask + "))");
        std::string ut = wide ? "uint64_t" : "uint32_t";
        return seqWrap(pre, "(" + lcode + " = (" + ctype(lt) + ")((" + ut + ")(" + lcode + ") << ((" + rcode + ") & " +
                                mask + ")))");
    }
    if ((op == "/=" || op == "%=") && lt->isIntegral()) {
        int64_t k = 0;
        if (!(sema_.constEval(a->rhs, k) && k != 0)) {
            bool u64 = lt->is(TK::ULong);
            return seqWrap(pre, "(" + lcode + " " + op + " " + (u64 ? "faset_divisor_u64(" : "faset_divisor_i64(") + rcode +
                                    ", " + callerLoc(a->loc) + "))");
        }
    }
    return seqWrap(pre, "(" + lcode + " " + op + " " + rcode + ")");
}

// ------------------------------------------------------------------ Sema: análisis previo

void Sema::markAddressTaken(Expr* e) {
    while (e) {
        if (e->kind == EK::Name) {
            auto* n = static_cast<NameExpr*>(e);
            if (n->ref == NameExpr::Ref::Local && n->var) n->var->addrTaken = true;
            return;
        }
        if (e->kind == EK::Member) {  // campo de un struct: es parte de la variable
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref != MemberExpr::Ref::Field || m->arrow || !m->obj->type || !m->obj->type->isStruct()) return;
            e = m->obj;
            continue;
        }
        if (e->kind == EK::Index) {  // operator[] de un struct (Span<T>...): recibe su dirección
            auto* ix = static_cast<IndexExpr*>(e);
            if (!ix->opMethod || !ix->obj->type || !ix->obj->type->isStruct()) return;
            e = ix->obj;
            continue;
        }
        return;
    }
}

namespace {

// Copia sin comprobar de un receptor que se puede volver a evaluar sin efectos (x, this, base).
Expr* cloneStable(Expr* e) {
    if (e->kind == EK::This) return new ThisExpr(e->loc);
    if (e->kind == EK::Name) {
        auto* n = static_cast<NameExpr*>(e);
        auto* c = new NameExpr(n->loc);
        c->name = n->name;
        c->typeArgs = n->typeArgs;
        return c;
    }
    return nullptr;
}

}  // namespace

// obj.P op= v  ->  (<o> = obj, <o>.P = <o>.P op v): 'obj' se evalúa una vez, después se llama a
// 'get', se evalúa 'v' y por último 'set' (como en C#). P op= v (this o estática) -> P = P op v.
Type* Sema::checkPropertyCompound(AssignExpr* e) {
    SourceLoc loc = e->loc;
    auto* mem = e->lhs->kind == EK::Member ? static_cast<MemberExpr*>(e->lhs) : nullptr;
    MethodDecl* getter = mem ? mem->getter : static_cast<NameExpr*>(e->lhs)->getter;
    MethodDecl* setter = mem ? mem->setter : static_cast<NameExpr*>(e->lhs)->setter;
    if (!setter) {
        diag.error(e->lhs->loc, "la propiedad '" + getter->name + "' es de solo lectura (no tiene 'set')");
        checkValue(e->rhs);
        return tc_.error();
    }
    LetExpr* let = nullptr;
    std::function<Expr*()> target;
    if (!mem) {
        target = [&]() { return cloneStable(e->lhs); };
    } else {
        Expr* obj = mem->obj;
        bool structVar = obj->kind == EK::Name && obj->type && obj->type->isStruct() &&
                         static_cast<NameExpr*>(obj)->ref != NameExpr::Ref::Property;
        Expr* stable = getter->isStatic() || obj->kind == EK::This || structVar ? cloneStable(obj) : nullptr;
        VarInfo* tmp = nullptr;
        if (!stable) {
            if (getter->isStatic() || !obj->type || !obj->type->isClass() || mem->arrow) {
                diag.error(e->loc, "'" + e->op + "' sobre la propiedad de un valor temporal no está soportado; usa "
                                   "una variable: 'var x = ...; x." + mem->name + " " + e->op + " valor'");
                checkValue(e->rhs);
                return tc_.error();
            }
            tmp = hiddenLocal(obj->type, loc, true);
            let = new LetExpr(loc);
            let->binds.push_back({tmp, obj});
        }
        target = [&, tmp]() {
            Expr* o;
            if (tmp) {
                auto* n = new NameExpr(loc);
                n->name = tmp->name;
                o = n;
            } else {
                o = cloneStable(obj);
            }
            auto* m = new MemberExpr(mem->loc);
            m->obj = o;
            m->name = mem->name;
            m->nameLoc = mem->nameLoc;
            m->arrow = mem->arrow;
            return m;
        };
    }
    auto* bin = new BinaryExpr(loc);
    bin->op = e->op.substr(0, e->op.size() - 1);
    bin->lhs = target();
    bin->rhs = e->rhs;
    auto* as = new AssignExpr(loc);
    as->op = "=";
    as->lhs = target();
    as->rhs = bin;
    Type* t = checkValue(as);
    if (t->isError()) return t;
    if (let) {
        let->seq.push_back(as);
        let->type = t;
        e->lowered = let;
    } else {
        e->lowered = as;
    }
    return t;
}
