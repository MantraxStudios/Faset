// Faset - organización de tipos (análisis semántico).
//
// Tipos anidados
//   class Externa { public class Interna { } enum Modo { A, B } delegate int Op(int x); }
//   Un tipo anidado no es miembro del namespace: se busca por su nombre simple dentro de la clase
//   que lo contiene (y de sus bases y de las clases que la contienen a ella) y desde fuera como
//   Externa.Interna (también en 'new', tipos de variables, 'using X = Externa.Interna;' y
//   Externa.Modo.A). Por defecto es privado, como en C#: solo se ve dentro de la clase. Desde un
//   tipo anidado se usan por su nombre los miembros estáticos (también privados) de las clases que
//   lo contienen. En una clase genérica (class Caja<T> { class Nodo { T valor; } }) cada instancia
//   tiene sus propios tipos anidados, que ven los argumentos de tipo de la clase exterior.
//   Los delegados declarados dentro de una clase se nombran igual: Clase.Delegado.
//
// using static
//   using static std.Math;  ->  Sqrt(2), PI, Max(a, b): miembros estáticos (campos, propiedades,
//   métodos y miembros de enums) de un tipo sin calificarlos. Se consultan después de los nombres
//   del ámbito y de los namespaces importados.
#include <algorithm>

#include "Sema.h"

namespace {

// ¿Hay algún tipo anidado o delegado dentro de una clase? (evita búsquedas inútiles en cada nombre)
bool gAnyNested = false;

int completionKindOf(ClassDecl* c) {
    return c->kind == ClassKind::Struct ? 22 : c->kind == ClassKind::Enum ? 13 : c->kind == ClassKind::Interface ? 8 : 7;
}

Type* newTypeFor(ClassDecl* c) {
    auto* t = new Type(c->kind == ClassKind::Class || c->kind == ClassKind::Interface ? TK::Class
                       : c->kind == ClassKind::Struct                                ? TK::Struct
                                                                                     : TK::Enum);
    t->decl = c;
    return t;
}

}  // namespace

// Tipo anidado de un tipo no genérico (buildNamespaces): nombre en C y tipo.
void Sema::registerNested(ClassDecl* c) {
    gAnyNested = true;
    ClassDecl* o = c->outer;
    c->displayName = (c->templateOf ? c->displayName : o->displayName + "." + c->name);
    c->cname = o->cname + "_" + c->name + (c->isTemplate() ? "_G" : "");
    if (c->mods.isStatic && c->kind != ClassKind::Class) diag.error(c->loc, "solo las clases pueden ser 'static'");
    if (o->unsafeCtx && !c->unsafeCtx) c->unsafeCtx = true;
    for (ClassDecl* n : o->nested) {
        if (n == c) break;
        if (n->name == c->name && n->isTemplate() == c->isTemplate()) {
            diag.error(c->loc, "'" + o->displayName + "' ya contiene un tipo llamado '" + c->name + "'");
            break;
        }
    }
    if (c->name == o->name) diag.error(c->loc, "un tipo anidado no puede llamarse como la clase que lo contiene");
    if (!c->isTemplate()) c->type = newTypeFor(c);
}

// Instancia de una plantilla: 'inst' es nuevo (Parser::reparseType). Si la plantilla es un tipo
// anidado, la instancia también; y los tipos anidados de la instancia son tipos nuevos.
void Sema::instantiateNested(ClassDecl* inst, ClassDecl* tmpl) {
    if (tmpl->outer) {
        gAnyNested = true;
        inst->outer = tmpl->outer;
        inst->displayName = tmpl->outer->displayName + "." + inst->displayName;
        for (auto& [k, v] : tmpl->outer->typeArgMap) inst->typeArgMap.emplace(k, v);
    }
    if (inst->nested.empty()) return;
    gAnyNested = true;
    std::vector<ClassDecl*> added;
    std::function<void(ClassDecl*)> reg = [&](ClassDecl* o) {
        for (ClassDecl* n : o->nested) {
            n->outer = o;
            n->file = o->file;
            n->ns = o->ns;
            n->nsSym = o->nsSym;
            n->displayName = o->displayName + "." + n->name;
            n->cname = o->cname + "_" + n->name + (n->isTemplate() ? "_G" : "");
            for (auto& [k, v] : o->typeArgMap) n->typeArgMap.emplace(k, v);
            if (o->unsafeCtx) {
                n->unsafeCtx = true;
                for (FieldDecl* f : n->fields) f->unsafeCtx = true;
                for (MethodDecl* m : n->methods) m->unsafeBody = true;
                for (MethodDecl* m : n->ctors) m->unsafeBody = true;
            }
            if (!n->isTemplate()) {
                n->type = newTypeFor(n);
                added.push_back(n);
            }
            prog_.types.push_back(n);
            reg(n);
        }
    };
    reg(inst);
    for (ClassDecl* n : added) {
        resolveClassSignatures(n);
        if (n->kind == ClassKind::Enum) continue;
        for (FieldDecl* f : n->fields)
            if (f->init) fieldWork_.push_back({n, f});
        useMethod(n->dtor);
    }
}

// ¿Se puede nombrar el tipo anidado 'n' desde el contexto actual?
bool Sema::nestedVisible(ClassDecl* n) {
    if (!n->outer) return true;
    return accessible(n->mods.access, n->outer);
}

// Tipo anidado o delegado 'name' declarado en 'scope' o en sus bases (y, con 'outers', en las
// clases que contienen a 'scope').
Sym Sema::nestedLookup(ClassDecl* scope, const std::string& name, bool outers) {
    Sym r;
    if (!gAnyNested || !scope || scope->isNamespaceScope) return r;
    for (ClassDecl* s = scope; s; s = outers ? s->outer : nullptr) {
        for (ClassDecl* k : lookupChain(s)) {
            ClassDecl* found = nullptr;
            for (ClassDecl* n : k->nested)
                if (n->name == name && (!found || (found->isTemplate() && !n->isTemplate()))) found = n;
            if (found) {
                if (found->isTemplate())  // Task y Task<T>: el gemelo con la otra aridad
                    for (ClassDecl* n : k->nested)
                        if (n != found && n->name == name) found->arityTwin = n, n->arityTwin = found;
                if (k != s && !nestedVisible(found)) continue;  // privado de una base
                r.kind = Sym::TypeK;
                r.decl = found;
                return r;
            }
            for (MethodDecl* d : prog_.delegates)
                if (d->name == name && (d->owner == k || (k->templateOf && d->owner == k->templateOf))) {
                    r.kind = Sym::TypeK;
                    r.dlg = d;
                    return r;
                }
        }
        if (!outers) break;
    }
    return r;
}

// Externa.Interna en un nombre de tipo (resolveType).
Sym Sema::nestedMember(const Sym& s, const std::string& name, SourceLoc loc) {
    Sym none;
    ClassDecl* d = s.decl;
    if (!d) return none;
    if (d->isTemplate()) {
        // Dentro de Caja<T>, 'Caja.Nodo' es el Nodo de la instancia actual.
        for (ClassDecl* k = ctx_.cls; k; k = k->outer)
            if (k->templateOf == d) {
                d = k;
                break;
            }
        if (d->isTemplate()) {
            diag.error(loc, "los tipos anidados de la clase genérica '" + d->name + "' solo se pueden nombrar dentro de ella");
            return none;
        }
    }
    Sym r = nestedLookup(d, name, false);
    if (r.kind == Sym::None) return none;
    if (r.decl && !nestedVisible(r.decl))  // se informa y se sigue con el tipo (un solo error)
        diag.error(loc, "'" + d->displayName + "." + name + "' no es accesible debido a su nivel de protección");
    if (ideMode && r.decl) addRef(loc, 0, typeDescription(r.decl), &r.decl->loc);
    return r;
}

// Externa.Interna / Externa.Modo / Clase.Delegado en una expresión (checkMemberImpl).
Type* Sema::nestedTypeMember(MemberExpr* e, Type* T) {
    if (!T->isAggregate()) return nullptr;
    Sym r = nestedLookup(T->decl, e->name, false);
    if (r.kind == Sym::None) return nullptr;
    if (r.decl && !nestedVisible(r.decl)) {
        diag.error(e->loc, "'" + T->decl->displayName + "." + e->name + "' no es accesible debido a su nivel de protección");
        return tc_.error();
    }
    return fromSym(e, r, e->typeArgs);
}

// Desde un tipo anidado: miembros estáticos de las clases que lo contienen, por su nombre.
Type* Sema::outerMemberName(NameExpr* e) {
    ClassDecl* cls = ctx_.cls;
    if (!cls || !cls->outer) return nullptr;
    for (ClassDecl* o = cls->outer; o; o = o->outer) {
        auto instanceError = [&]() {
            diag.error(e->loc, "no se puede usar el miembro de instancia '" + o->displayName + "." + e->name +
                                   "' desde el tipo anidado '" + cls->displayName + "'; usa un objeto de '" + o->displayName + "'");
            return tc_.error();
        };
        if (FieldDecl* f = findField(o, e->name)) {
            if (!f->isStatic()) return instanceError();
            checkAccess(f->mods.access, f->owner, f->name, e->loc);
            e->ref = NameExpr::Ref::StaticField;
            e->field = f;
            return f->type;
        }
        if (MethodDecl* g = findGetter(o, e->name)) {
            if (!g->isStatic()) return instanceError();
            checkAccess(g->mods.access, g->owner, g->name, e->loc);
            e->ref = NameExpr::Ref::Property;
            e->getter = g;
            e->setter = FindSetter(g);
            requireSafeCall(g, e->loc);
            useMethod(g, &e->loc);
            return g->ret;
        }
        std::vector<MethodDecl*> all = findMethods(o, e->name), statics;
        for (MethodDecl* m : all)
            if (m->isStatic()) statics.push_back(m);
        if (!statics.empty()) {
            e->vk = ValKind::MethodGroup;
            e->group = statics;
            return tc_.get(TK::Void);
        }
        if (!all.empty()) return instanceError();
    }
    return nullptr;
}

// ================================================================== using static

void Sema::resolveStaticImports(FileScope* f) {
    if (f->staticResolved) return;
    f->staticResolved = true;
    for (UsingDirective& u : f->usings) {
        if (!u.isStatic) continue;
        Sym s = lookupIn(global_, u.path[0]);
        for (size_t i = 1; i < u.path.size() && (s.kind == Sym::Ns || s.kind == Sym::TypeK); i++)
            s = s.kind == Sym::Ns ? lookupIn(s.ns, u.path[i]) : nestedMember(s, u.path[i], u.loc);
        std::string name;
        for (size_t i = 0; i < u.path.size(); i++) name += (i ? "." : "") + u.path[i];
        if (s.kind != Sym::TypeK || !s.decl) {
            diag.error(u.loc, "'using static' necesita un tipo: '" + name + "' no es una clase, struct ni enum");
            continue;
        }
        if (s.decl->isTemplate()) {
            diag.error(u.loc, "'using static' no admite tipos genéricos ('" + name + "')");
            continue;
        }
        f->staticImports.push_back(s.decl);
    }
}

Type* Sema::usingStaticName(NameExpr* e) {
    FileScope* f = ctx_.file;
    if (!f) return nullptr;
    resolveStaticImports(f);
    if (f->staticImports.empty()) return nullptr;
    // Métodos: se juntan las sobrecargas de todos los tipos importados.
    std::vector<MethodDecl*> group;
    for (ClassDecl* c : f->staticImports) {
        if (c->kind == ClassKind::Enum) continue;
        for (MethodDecl* m : findMethods(c, e->name))
            if (m->isStatic() && !m->isExtension() && accessible(m->mods.access, m->owner)) group.push_back(m);
    }
    if (!group.empty()) {
        e->vk = ValKind::MethodGroup;
        e->group = group;
        return tc_.get(TK::Void);
    }
    for (ClassDecl* c : f->staticImports) {
        if (c->kind == ClassKind::Enum) {
            for (EnumMember& m : c->enumMembers)
                if (m.name == e->name) {
                    auto* tn = new NameExpr(e->loc);
                    tn->name = c->name;
                    tn->vk = ValKind::TypeName;
                    tn->typeValue = c->type;
                    tn->type = c->type;
                    auto* me = new MemberExpr(e->loc);
                    me->obj = tn;
                    me->name = e->name;
                    me->nameLoc = e->loc;
                    Type* t = check(me);
                    e->lowered = me;
                    return t;
                }
            continue;
        }
        if (FieldDecl* fd = findField(c, e->name)) {
            if (!fd->isStatic()) continue;
            checkAccess(fd->mods.access, fd->owner, fd->name, e->loc);
            e->ref = NameExpr::Ref::StaticField;
            e->field = fd;
            if (ideMode) addRef(e->loc, (int)e->name.size(), "(campo estático) " + fd->type->str() + " " + c->displayName + "." + fd->name, &fd->loc);
            return fd->type;
        }
        if (MethodDecl* g = findGetter(c, e->name)) {
            if (!g->isStatic()) continue;
            checkAccess(g->mods.access, g->owner, g->name, e->loc);
            e->ref = NameExpr::Ref::Property;
            e->getter = g;
            e->setter = FindSetter(g);
            requireSafeCall(g, e->loc);
            useMethod(g, &e->loc);
            return g->ret;
        }
    }
    return nullptr;
}

// ================================================================== IntelliSense

void Sema::completeNested(ClassDecl* c, bool outers) {
    if (!gAnyNested || !c) return;
    for (ClassDecl* s = c; s; s = outers ? s->outer : nullptr) {
        for (ClassDecl* k : lookupChain(s)) {
            for (ClassDecl* n : k->nested)
                if (k == s || nestedVisible(n))
                    if (outers || nestedVisible(n)) addCompletion(n->name, completionKindOf(n), typeDescription(n));
            for (MethodDecl* d : prog_.delegates)
                if (d->owner == k || (k->templateOf && d->owner == k->templateOf))
                    addCompletion(d->name, 7, "delegate " + methodSignature(d));
        }
        if (!outers) break;
    }
}
