// Faset - análisis semántico de la orientación a objetos:
//   herencia simple de clases (con std.Object como base universal), interfaces múltiples,
//   métodos y propiedades virtual / override / abstract / sealed, tablas virtuales,
//   'protected', conversiones comprobadas (is / as / (T)x), typeof / nameof,
//   restricciones genéricas (where) y registros (record, with).
//
// Modelo en C (ver CodeGenClasses.cpp):
//   - cada objeto de clase empieza por un puntero a la descripción de su tipo, que es a la vez
//     su tabla virtual; la clase derivada incrusta a la base como primer miembro, así que un
//     'Perro*' es un 'Animal*' válido en C;
//   - una llamada virtual es una carga de la tabla y una llamada indirecta;
//   - una referencia a interfaz es el mismo puntero al objeto: el método se busca en la lista
//     (corta) de interfaces de la clase, cuyo elemento apunta a la tabla (clase, interfaz).
#include <algorithm>

#include "Sema.h"

namespace {

bool sameParams(MethodDecl* a, MethodDecl* b) {
    if (a->params.size() != b->params.size()) return false;
    for (size_t i = 0; i < a->params.size(); i++)
        if (a->params[i].type != b->params[i].type || a->params[i].isRef() != b->params[i].isRef()) return false;
    return true;
}

bool sameSig(MethodDecl* a, MethodDecl* b) { return a->name == b->name && a->kind == b->kind && sameParams(a, b); }

std::string memberName(MethodDecl* m) {
    std::string s = (m->owner ? m->owner->displayName + "." : std::string()) + m->name;
    if (m->kind == MethodKind::Getter || m->kind == MethodKind::Setter) return s;
    s += "(";
    for (size_t i = 0; i < m->params.size(); i++)
        s += (i ? ", " : "") + (m->params[i].type ? m->params[i].type->str() : m->params[i].tref->str());
    return s + ")";
}

// 'Clase.Metodo(int)', o 'Clase.Propiedad' (get) / (set) para los descriptores de propiedades.
std::string described(MethodDecl* m) {
    return "'" + memberName(m) + "'" +
           (m->kind == MethodKind::Getter ? " (get)" : m->kind == MethodKind::Setter ? " (set)" : "");
}

}  // namespace

// ================================================================== modelo de objetos

void Sema::initObjectModel() {
    NamespaceSym* stdNs = getNs("std", false);
    if (!stdNs) return;
    auto find = [&](const char* name) -> ClassDecl* {
        auto it = stdNs->types.find(name);
        return it == stdNs->types.end() || it->second->isTemplate() ? nullptr : it->second;
    };
    objectDecl = find("Object");
    typeDecl = find("Type");
    if (objectDecl && objectDecl->kind != ClassKind::Class) objectDecl = nullptr;
    if (objectDecl) objectDecl->displayName = "object";  // en los mensajes, como la palabra clave
    // 'where X : ...' debe nombrar un parámetro de tipo del propio tipo o método genérico.
    auto checkWhere = [&](const std::vector<TypeConstraint>& cons, const std::vector<std::string>& params,
                          const std::string& owner) {
        for (const TypeConstraint& tc : cons)
            if (std::find(params.begin(), params.end(), tc.param) == params.end())
                diag.error(tc.loc, "'" + tc.param + "' no es un parámetro de tipo de '" + owner + "' (cláusula 'where')");
    };
    for (ClassDecl* c : prog_.types) {
        if (c->templateOf) continue;
        checkWhere(c->constraints, c->typeParams, c->name);
        for (MethodDecl* m : c->methods) checkWhere(m->constraints, m->typeParams, m->name);
    }
    enumToString = new MethodDecl();
    enumToString->name = "ToString";
    enumToString->mods.access = Access::Public;
    enumToString->ret = tc_.get(TK::String);
    enumToString->signatureDone = true;
    enumToString->cname = "faset_enum_tostring";
}

MethodDecl* Sema::typeFromHandle() const {
    if (!typeDecl) return nullptr;
    for (MethodDecl* m : typeDecl->methods)
        if (m->name == "FromHandle" && m->isStatic()) return m;
    return nullptr;
}

bool Sema::derivesFrom(ClassDecl* c, ClassDecl* target) {
    if (!c || !target) return false;
    for (ClassDecl* k = c; k; k = k->base)
        if (k == target) return true;
    for (ClassDecl* i : c->allInterfaces)
        if (i == target) return true;
    // Las interfaces se convierten implícitamente a 'object'.
    if (c->isInterface() && !target->base && target->kind == ClassKind::Class && !target->isInterface() &&
        target->name == "Object" && target->ns == "std")
        return true;
    return false;
}

MethodDecl* Sema::paramlessCtor(ClassDecl* c) {
    for (MethodDecl* m : c->ctors)
        if (m->params.empty()) return m;
    return nullptr;
}

// Coste de una conversión implícita entre clases para la resolución de sobrecargas:
// cuanto más cercana la base, mejor; las interfaces y 'object' van al final.
int Sema::inheritCost(ClassDecl* from, ClassDecl* to) {
    int n = 0;
    for (ClassDecl* k = from; k; k = k->base, n++)
        if (k == to) return to == objectDecl ? 100 : n;
    return to == objectDecl ? 100 : 50;
}

bool Sema::isBaseExpr(Expr* e) const {
    return e && e->kind == EK::Name && static_cast<NameExpr*>(e)->ref == NameExpr::Ref::Base;
}

// Conversión explícita entre referencias que se comprueba al ejecutar (sin memory_unsafe):
// de una base a una derivada, y desde o hacia una interfaz.
bool Sema::checkedCastOk(Type* from, Type* to) {
    if (!from->isClass() || !to->isClass()) return false;
    ClassDecl* f = from->decl;
    ClassDecl* t = to->decl;
    if (derivesFrom(t, f)) return true;  // bajada: Animal -> Perro
    if (t->isInterface()) return !(f->mods.isSealed && !derivesFrom(f, t));
    if (f->isInterface()) return !(t->mods.isSealed && !derivesFrom(t, f));
    return false;
}

// La clase y sus bases (o la interfaz, las que extiende y 'object'), en orden de búsqueda.
std::vector<ClassDecl*> Sema::lookupChain(ClassDecl* c) {
    std::vector<ClassDecl*> out;
    if (!c) return out;
    if (c->isInterface()) {
        out.push_back(c);
        for (ClassDecl* i : c->allInterfaces) out.push_back(i);
        if (objectDecl) out.push_back(objectDecl);
        return out;
    }
    for (ClassDecl* k = c; k; k = k->base) out.push_back(k);
    return out;
}

FieldDecl* Sema::findField(ClassDecl* c, const std::string& name) {
    for (ClassDecl* k : lookupChain(c))
        for (FieldDecl* f : k->fields)
            if (f->name == name) return f;
    return nullptr;
}

MethodDecl* Sema::findGetter(ClassDecl* c, const std::string& name) {
    for (ClassDecl* k : lookupChain(c))
        for (MethodDecl* m : k->methods)
            if (m->kind == MethodKind::Getter && m->name == name) return m;
    return nullptr;
}

// Métodos con ese nombre en la clase y sus bases; un método de una base que tiene la misma
// firma que otro más derivado (lo reemplaza o lo oculta) no se incluye.
std::vector<MethodDecl*> Sema::findMethods(ClassDecl* c, const std::string& name, MethodKind kind) {
    std::vector<MethodDecl*> out;
    for (ClassDecl* k : lookupChain(c)) {
        size_t before = out.size();
        for (MethodDecl* m : k->methods) {
            if (m->kind != kind || m->name != name) continue;
            bool hidden = false;
            if (!m->isTemplate() && m->signatureDone)
                for (size_t i = 0; i < before && !hidden; i++)
                    hidden = !out[i]->isTemplate() && out[i]->signatureDone && sameParams(out[i], m);
            if (!hidden) out.push_back(m);
        }
    }
    return out;
}

// ¿Es accesible un miembro con ese nivel de acceso desde el contexto actual? (sin informar)
bool Sema::accessible(Access a, ClassDecl* owner) {
    if (a == Access::Public || a == Access::Internal || !owner || owner->isNamespaceScope || owner == ctx_.cls) return true;
    if (owner->templateOf && ctx_.cls && ctx_.cls->templateOf == owner->templateOf) return true;
    if (a == Access::Protected && ctx_.cls) {
        for (ClassDecl* k = ctx_.cls; k; k = k->base)
            if (k == owner || (owner->templateOf && k->templateOf == owner->templateOf)) return true;
    }
    return false;
}

// ================================================================== jerarquía

// Resuelve ': Base, I1, I2' (lo llama resolveClassSignatures, ya dentro del contexto de la clase).
void Sema::resolveHierarchy(ClassDecl* c) {
    if (c->hierarchyState == 2 || c->isNamespaceScope || c->kind == ClassKind::Enum) return;
    c->hierarchyState = 1;
    for (size_t i = 0; i < c->baseRefs.size(); i++) {
        TypeRef* r = c->baseRefs[i];
        Type* t = resolveType(r);
        if (t->isError()) continue;
        if (!t->isClass()) {
            diag.error(r->loc, "no se puede heredar de '" + t->str() + "': solo de una clase o de interfaces");
            continue;
        }
        ClassDecl* b = t->decl;
        resolveClassSignatures(b);
        if (b == c || derivesFrom(b, c) || b->hierarchyState == 1) {
            diag.error(r->loc, "herencia circular: '" + b->displayName + "' depende de '" + c->displayName + "'");
            continue;
        }
        if (b->isInterface()) {
            if (std::find(c->interfaces.begin(), c->interfaces.end(), b) != c->interfaces.end())
                diag.error(r->loc, "la interfaz '" + b->displayName + "' ya está en la lista de bases");
            else
                c->interfaces.push_back(b);
            continue;
        }
        if (c->kind != ClassKind::Class) {
            diag.error(r->loc, std::string(c->isInterface() ? "una interfaz" : "un struct") +
                                   " solo puede heredar de interfaces ('" + b->displayName + "' es una clase)");
        } else if (c->isStaticClass()) {
            diag.error(r->loc, "una clase estática no puede tener clase base");
        } else if (c->base) {
            diag.error(r->loc, "'" + c->displayName + "' ya hereda de '" + c->base->displayName +
                                   "': Faset solo admite herencia simple de clases (usa interfaces)");
        } else if (i != 0) {
            diag.error(r->loc, "la clase base '" + b->displayName + "' debe ir antes que las interfaces");
        } else if (b->mods.isSealed) {
            diag.error(r->loc, "'" + c->displayName + "' no puede derivar de la clase sellada (sealed) '" + b->displayName + "'");
        } else if (b->isStaticClass()) {
            diag.error(r->loc, "no se puede derivar de la clase estática '" + b->displayName + "'");
        } else {
            c->base = b;
        }
    }
    if (c->kind == ClassKind::Class && !c->isStaticClass() && !c->base && objectDecl && c != objectDecl) {
        resolveClassSignatures(objectDecl);
        c->base = objectDecl;
    }
    auto add = [&](ClassDecl* i) {
        if (std::find(c->allInterfaces.begin(), c->allInterfaces.end(), i) == c->allInterfaces.end())
            c->allInterfaces.push_back(i);
    };
    if (c->base)
        for (ClassDecl* i : c->base->allInterfaces) add(i);
    for (ClassDecl* i : c->interfaces) {
        add(i);
        for (ClassDecl* j : i->allInterfaces) add(j);
    }
    c->hierarchyState = 2;
}

// Implementación de un método de interfaz en la clase (o en sus bases).
MethodDecl* Sema::findInterfaceImpl(ClassDecl* c, MethodDecl* im) {
    for (ClassDecl* k = c; k; k = k->base)
        for (MethodDecl* m : k->methods)
            if (!m->isStatic() && !m->isTemplate() && sameSig(m, im)) return m;
    return nullptr;
}

// Tabla virtual, interfaces y comprobaciones de los modificadores de herencia.
void Sema::finishClassLayout(ClassDecl* c) {
    if (c->isNamespaceScope || c->kind == ClassKind::Enum) return;
    if (c->mods.isAbstract && c->kind != ClassKind::Class) diag.error(c->loc, "solo las clases pueden ser 'abstract'");
    if (c->mods.isSealed && c->kind != ClassKind::Class) diag.error(c->loc, "solo las clases pueden ser 'sealed'");
    if (c->mods.isAbstract && c->mods.isSealed)
        diag.error(c->loc, "una clase no puede ser 'abstract' y 'sealed' a la vez");
    if (c->mods.isStatic && (c->mods.isAbstract || c->mods.isSealed))
        diag.error(c->loc, "una clase estática no puede ser 'abstract' ni 'sealed'");

    if (c->isInterface()) {
        for (FieldDecl* f : c->fields)
            if (!f->isStatic()) diag.error(f->loc, "las interfaces no pueden tener campos");
        if (!c->ctors.empty()) diag.error(c->ctors[0]->loc, "las interfaces no pueden tener constructores");
        if (c->dtor) diag.error(c->dtor->loc, "las interfaces no pueden tener destructor");
        for (MethodDecl* m : c->methods) {
            if (m->isStatic()) {
                diag.error(m->loc, "las interfaces no admiten miembros estáticos");
                continue;
            }
            if (m->kind == MethodKind::Operator) diag.error(m->loc, "las interfaces no pueden declarar operadores");
            if (m->mods.access != Access::Public) diag.error(m->loc, "los miembros de una interfaz son siempre públicos");
            if (m->mods.isVirtual || m->mods.isOverride || m->mods.isSealed || m->mods.isAbstract)
                diag.error(m->loc, "los miembros de una interfaz no admiten virtual/override/abstract/sealed");
            if (m->isTemplate()) diag.error(m->loc, "los métodos de una interfaz no pueden ser genéricos");
            m->objSelf = true;
            useMethod(m);  // método por defecto (con cuerpo)
        }
        return;
    }

    if (c->kind == ClassKind::Struct) {
        for (MethodDecl* m : c->methods) {
            if (m->mods.isVirtual || m->mods.isAbstract || m->mods.isSealed)
                diag.error(m->loc, "los miembros de un struct no pueden ser virtual, abstract ni sealed");
            // 'override' de ToString/GetHashCode/Equals se acepta por costumbre (no hay herencia).
            if (m->mods.isOverride && m->name != "ToString" && m->name != "GetHashCode" && m->name != "Equals")
                diag.error(m->loc, "'" + memberName(m) + "': un struct no tiene clase base que reemplazar");
        }
    } else {
        // ---- tabla virtual
        c->vtable = c->base ? c->base->vtable : std::vector<MethodDecl*>();
        for (MethodDecl* m : c->methods) {
            bool vmods = m->isVirtualish() || m->mods.isSealed;
            if (m->isStatic()) {
                if (vmods) diag.error(m->loc, "un miembro estático no puede ser virtual, abstract, override ni sealed");
                continue;
            }
            if (m->kind != MethodKind::Normal && m->kind != MethodKind::Getter && m->kind != MethodKind::Setter) {
                if (vmods) diag.error(m->loc, "solo los métodos y las propiedades pueden ser virtuales");
                continue;
            }
            if (m->isTemplate()) {
                if (vmods) diag.error(m->loc, "un método genérico no puede ser virtual, abstract ni override");
                continue;
            }
            const std::string what = described(m);
            if (m->mods.isAbstract && m->body) diag.error(m->loc, "el miembro abstracto " + what + " no puede tener cuerpo");
            if (m->mods.isAbstract && !c->mods.isAbstract)
                diag.error(m->loc, what + " es abstracto pero la clase '" + c->displayName + "' no es 'abstract'");
            if (m->isVirtualish() && m->mods.access == Access::Private)
                diag.error(m->loc, "un miembro virtual, abstract u override no puede ser privado (" + what + ")");
            if (m->mods.isVirtual && (m->mods.isOverride || m->mods.isAbstract))
                diag.error(m->loc, what + ": 'virtual' no se combina con 'override' ni con 'abstract'");
            if (m->mods.isSealed && !m->mods.isOverride) diag.error(m->loc, "'sealed' solo se puede aplicar a un 'override' (" + what + ")");
            if (m->trackCaller && m->isVirtualish()) diag.error(m->loc, "[TrackCaller] no se puede aplicar a miembros virtuales");
            int slot = -1;
            for (size_t s = 0; s < c->vtable.size() && slot < 0; s++)
                if (sameSig(c->vtable[s], m)) slot = (int)s;
            MethodDecl* hiddenBase = nullptr;  // miembro no virtual de la base con la misma firma
            if (slot < 0 && c->base)
                for (ClassDecl* k = c->base; k && !hiddenBase; k = k->base)
                    for (MethodDecl* b : k->methods)
                        if (!b->isStatic() && !b->isTemplate() && sameSig(b, m)) hiddenBase = b;
            // ToString / Equals / GetHashCode de object con la misma firma y sin 'override' (código
            // anterior a la herencia): se reemplazan igualmente.
            if (!m->isVirtualish() && !m->mods.isNew && slot >= 0 && objectDecl && c->vtable[slot]->vroot &&
                c->vtable[slot]->vroot->owner == objectDecl && m->mods.access == Access::Public)
                m->mods.isOverride = true;
            if (m->mods.isOverride) {
                if (slot < 0) {
                    std::string msg = what + " está marcado como 'override' pero no hay ningún miembro virtual, abstract u "
                                             "override adecuado que reemplazar en la clase base";
                    if (hiddenBase) msg += " ('" + memberName(hiddenBase) + "' no es virtual)";
                    else {
                        MethodDecl* similar = nullptr;
                        for (ClassDecl* k = c->base; k && !similar; k = k->base)
                            for (MethodDecl* b : k->methods)
                                if (!similar && b->name == m->name && b->kind == m->kind && b->isVirtualish()) similar = b;
                        if (similar) msg += " (la firma no coincide con '" + memberName(similar) + "')";
                    }
                    diag.error(m->loc, msg);
                    continue;
                }
                MethodDecl* b = c->vtable[slot];
                if (b->ret != m->ret && !b->ret->isError() && !m->ret->isError())
                    diag.error(m->loc, "el tipo de retorno de " + what + " debe ser '" + b->ret->str() +
                                           "' para coincidir con el miembro reemplazado '" + memberName(b) + "'");
                if (b->mods.isSealed)
                    diag.error(m->loc, what + ": no se puede reemplazar '" + memberName(b) + "' porque es 'sealed'");
                if (b->mods.access != m->mods.access && !(b->owner && b->owner == objectDecl && m->mods.access == Access::Public))
                    diag.error(m->loc, what + ": no se puede cambiar el nivel de acceso al reemplazar '" + memberName(b) + "'");
                m->vslot = slot;
                m->vroot = b->vroot ? b->vroot : b;
                m->overridden = b;
                m->objSelf = true;
                c->vtable[slot] = m;
            } else if (m->mods.isVirtual || m->mods.isAbstract) {
                if (slot >= 0 && !m->mods.isNew)
                    diag.error(m->loc, what + " oculta el miembro heredado '" + memberName(c->vtable[slot]) +
                                           "'; usa 'override' para reemplazarlo o 'new' para ocultarlo");
                m->vslot = (int)c->vtable.size();
                m->vroot = m;
                m->objSelf = true;
                c->vtable.push_back(m);
            } else if (slot >= 0 && !m->mods.isNew) {
                diag.error(m->loc, what + " oculta el miembro virtual heredado '" + memberName(c->vtable[slot]) +
                                       "'; usa 'override' para reemplazarlo o 'new' para ocultarlo");
            }
        }
        if (!c->mods.isAbstract)
            for (MethodDecl* m : c->vtable)
                if (m->mods.isAbstract)
                    diag.error(c->loc, "'" + c->displayName + "' no implementa el miembro abstracto heredado " + described(m));
        for (MethodDecl* m : c->vtable) useMethod(m);

        // ---- construcción por defecto: la base necesita un constructor sin parámetros
        if (c->ctors.empty() && c->base && !c->base->ctors.empty()) {
            if (MethodDecl* p = paramlessCtor(c->base)) useMethod(p);
            else
                diag.error(c->loc, "'" + c->displayName + "' debe declarar un constructor que llame a ': base(...)': '" +
                                       c->base->displayName + "' no tiene un constructor sin parámetros");
        }
    }

    // ---- interfaces: implementación de cada miembro
    c->itabs.clear();
    for (ClassDecl* i : c->allInterfaces) {
        std::vector<MethodDecl*> impl;
        for (MethodDecl* im : i->methods) {
            if (im->isStatic() || im->isTemplate() || im->kind == MethodKind::Operator) continue;
            MethodDecl* m = findInterfaceImpl(c, im);
            if (m && m->mods.access != Access::Public) {
                diag.error(m->loc, "'" + memberName(m) + "' implementa '" + memberName(im) + "' y debe ser 'public'");
            } else if (m && m->ret != im->ret && !m->ret->isError() && !im->ret->isError()) {
                diag.error(m->loc, "'" + memberName(m) + "' no puede implementar '" + memberName(im) +
                                       "': el tipo de retorno debe ser '" + im->ret->str() + "'");
            } else if (m) {
                if (m->vslot >= 0 && c->kind == ClassKind::Class) m = c->vtable[m->vslot];
                m->objSelf = c->kind == ClassKind::Class || m->objSelf;
                useMethod(m);
            } else if (im->body) {
                m = im;  // método por defecto de la interfaz
            } else if (!c->mods.isAbstract) {
                diag.error(c->loc, "'" + c->displayName + "' no implementa el miembro de interfaz " + described(im));
            }
            impl.push_back(m);
        }
        c->itabs.push_back(impl);
    }
}

// ================================================================== constructores

// ': base(...)' / ': this(...)' (o la llamada implícita al constructor sin parámetros de la base).
void Sema::checkCtorInit(MethodDecl* m) {
    ClassDecl* c = m->owner;
    SourceLoc at = m->ctorInit ? m->ctorInitLoc : m->loc;
    for (Expr* a : m->ctorInitArgs) checkValue(a);
    MethodDecl* target = nullptr;
    if (m->ctorInit == 2) {
        target = resolveOverload(c->ctors, m->ctorInitArgs, at, c->displayName);
        if (!target) return;
        if (target == m) {
            diag.error(at, "el constructor no puede llamarse a sí mismo con ': this(...)'");
            return;
        }
    } else if (c->kind != ClassKind::Class || !c->base) {
        if (m->ctorInit == 1) diag.error(at, "'" + c->displayName + "' no tiene clase base: ': base(...)' no es válido");
        return;
    } else {
        ClassDecl* b = c->base;
        if (m->ctorInit == 1) {
            if (b->ctors.empty()) {
                if (!m->ctorInitArgs.empty())
                    diag.error(at, "'" + b->displayName + "' no contiene un constructor que acepte " +
                                       std::to_string(m->ctorInitArgs.size()) + " argumento(s)");
                return;
            }
            target = resolveOverload(b->ctors, m->ctorInitArgs, at, b->displayName);
            if (!target) return;
        } else {
            if (b->ctors.empty()) return;
            target = paramlessCtor(b);
            if (!target) {
                diag.error(at, "'" + b->displayName + "' no contiene un constructor sin parámetros; llama a uno con ': base(...)'");
                return;
            }
        }
    }
    checkAccess(target->mods.access, target->owner, target->owner->name, at);
    requireSafeCall(target, at);
    useMethod(target, &at);
    coerceArgs(target, m->ctorInitArgs);
    m->ctorInitTarget = target;
    if (ideMode && m->ctorInit) addRef(at, 4, methodSignature(target), &target->loc);  // 'base' / 'this'
}

// ================================================================== restricciones genéricas

bool Sema::satisfies(Type* arg, const TypeConstraint& tc, std::string& what) {
    auto primitive = [](Type* t) { return t->isNumeric() || t->is(TK::Bool) || t->is(TK::String) || t->isEnum(); };
    if (tc.isClass && !(arg->isClass() || arg->is(TK::String))) {
        what = "class";
        return false;
    }
    if (tc.isStruct && !(arg->isStruct() || arg->isNumeric() || arg->is(TK::Bool) || arg->isEnum())) {
        what = "struct";
        return false;
    }
    if (tc.isNew) {
        bool ok = !arg->isClass() || (!arg->decl->isInterface() && !arg->decl->mods.isAbstract &&
                                      (arg->decl->ctors.empty() ||
                                       (paramlessCtor(arg->decl) && paramlessCtor(arg->decl)->mods.access == Access::Public)));
        if (!ok) {
            what = "new()";
            return false;
        }
    }
    for (TypeRef* r : tc.types) {
        Type* t = resolveType(r);
        if (t->isError()) continue;
        what = t->str();
        if (!t->isClass()) {
            diag.error(r->loc, "'" + t->str() + "' no es válido como restricción: usa una clase o una interfaz");
            continue;
        }
        if (arg->isClass() && derivesFrom(arg->decl, t->decl)) continue;
        if (arg->isStruct() && derivesFrom(arg->decl, t->decl)) continue;
        // Los tipos primitivos cumplen IComparable<T> e IEquatable<T> (tienen CompareTo / ==).
        ClassDecl* d = t->decl;
        if (primitive(arg) && d->templateOf && d->ns == "std" &&
            (d->templateOf->name == "IComparable" || d->templateOf->name == "IEquatable") && d->typeArgs.size() == 1 &&
            d->typeArgs[0] == arg)
            continue;
        return false;
    }
    return true;
}

bool Sema::checkConstraints(const std::vector<std::string>& params, const std::vector<TypeConstraint>& cons,
                            const std::map<std::string, Type*>& args, const std::string& owner, std::string& err) {
    for (const TypeConstraint& tc : cons) {
        if (std::find(params.begin(), params.end(), tc.param) == params.end()) continue;  // ya informado
        auto it = args.find(tc.param);
        if (it == args.end() || it->second->isError()) continue;
        std::string what;
        if (!satisfies(it->second, tc, what)) {
            err = "el tipo '" + it->second->str() + "' no cumple la restricción '" + what + "' del parámetro de tipo '" +
                  tc.param + "' de '" + owner + "'";
            return false;
        }
    }
    return true;
}

// Restricciones de las instancias de clases genéricas: se comprueban cuando ya está resuelta toda
// la jerarquía (así funciona 'class Nodo : Base<Nodo>' con 'where T : Base<T>').
bool Sema::checkPendingConstraints() {
    if (pendingConstraints_.empty()) return false;
    std::vector<PendingConstraint> list;
    list.swap(pendingConstraints_);
    for (PendingConstraint& p : list) {
        ClassDecl* c = p.inst;
        CtxSave save(*this);
        enter(c, nullptr);
        std::string err;
        if (!checkConstraints(c->templateOf->typeParams, c->templateOf->constraints, c->typeArgMap, c->templateOf->name, err))
            diag.error(p.loc, err);
    }
    return true;
}

// ================================================================== expresiones

Type* Sema::checkIs(IsExpr* e) {
    Type* boolT = tc_.get(TK::Bool);
    Type* ot = checkValue(e->operand);
    if (ot->isError()) return boolT;
    if (!e->tref) {  // is null / is not null
        if (!ot->isRefLike()) diag.error(e->loc, "'is null' requiere una referencia (el tipo es '" + ot->str() + "')");
        return boolT;
    }
    Type* T = resolveType(e->tref);
    if (T->isError()) return boolT;
    e->target = T;
    if (!ot->isClass()) {
        diag.error(e->loc, "el operador 'is' requiere una referencia a clase o interfaz (el tipo es '" + ot->str() + "')");
        return boolT;
    }
    if (!T->isClass()) {
        diag.error(e->tref->loc, "'is' solo admite clases e interfaces como tipo (no '" + T->str() + "')");
        return boolT;
    }
    if (derivesFrom(ot->decl, T->decl)) e->always = true;
    else if (!checkedCastOk(ot, T))
        diag.error(e->loc, "una expresión de tipo '" + ot->str() + "' nunca puede ser de tipo '" + T->str() + "'");
    if (!e->varName.empty()) {
        if (!ctx_.method) {
            diag.error(e->varLoc, "los patrones con variable ('is T nombre') solo se pueden usar dentro de métodos");
            return boolT;
        }
        e->var = declareLocal(e->varName, T, e->varLoc, "l_");
        e->var->cname += "__p" + std::to_string(++patternCounter_);
        ctx_.method->patternVars.push_back(e->var);
        if (ideMode) addRef(e->varLoc, (int)e->varName.size(), "(variable local) " + T->str() + " " + e->varName, &e->varLoc);
    }
    return boolT;
}

Type* Sema::checkAs(AsExpr* e) {
    Type* ot = checkValue(e->operand);
    Type* T = resolveType(e->tref);
    if (ot->isError() || T->isError()) return tc_.error();
    if (!T->isClass()) {
        diag.error(e->tref->loc, "'as' solo admite clases e interfaces como tipo (no '" + T->str() + "')");
        return tc_.error();
    }
    if (ot->is(TK::Null)) return T;
    if (!ot->isClass()) {
        diag.error(e->loc, "el operador 'as' requiere una referencia a clase o interfaz (el tipo es '" + ot->str() + "')");
        return tc_.error();
    }
    if (derivesFrom(ot->decl, T->decl)) e->always = true;
    else if (!checkedCastOk(ot, T)) {
        diag.error(e->loc, "no se puede convertir '" + ot->str() + "' en '" + T->str() + "' con 'as': los tipos no están relacionados");
        return tc_.error();
    }
    return T;
}

Type* Sema::checkWith(WithExpr* e) {
    Type* t = checkValue(e->operand);
    for (auto& in : e->inits)
        if (in.value) checkValue(in.value);
    if (t->isError()) return t;
    if (!t->isAggregate() || !t->decl->isRecord) {
        diag.error(e->loc, "'with' solo se puede usar con registros (record), no con '" + t->str() + "'");
        return tc_.error();
    }
    ClassDecl* c = t->decl;
    std::set<std::string> seen;
    for (auto& in : e->inits) {
        if (!seen.insert(in.name).second) diag.error(in.loc, "la propiedad '" + in.name + "' ya se asignó en este 'with'");
        MethodDecl* g = findGetter(c, in.name);
        FieldDecl* f = findField(c, in.name + "__valor");
        if (!g) {
            if (FieldDecl* plain = findField(c, in.name); plain && !plain->isStatic()) f = plain;
            else {
                diag.error(in.loc, "'" + c->displayName + "' no contiene una propiedad '" + in.name + "'");
                continue;
            }
        } else if (!f) {
            diag.error(in.loc, "la propiedad '" + in.name + "' no es automática ({ get; }): no se puede usar en 'with'");
            continue;
        }
        if (!accessible(g ? g->mods.access : f->mods.access, c)) {
            diag.error(in.loc, "'" + c->displayName + "." + in.name + "' no es accesible debido a su nivel de protección");
            continue;
        }
        in.field = f;
        coerce(in.value, f->type);
        if (ideMode && g) addRef(in.loc, (int)in.name.size(), "(propiedad) " + methodSignature(g), &g->loc);
    }
    e->id = (int)withExprs.size();
    withExprs.push_back(e);
    return t;
}

Type* Sema::checkOO(Expr* e) {
    switch (e->kind) {
        case EK::Is: return checkIs(static_cast<IsExpr*>(e));
        case EK::As: return checkAs(static_cast<AsExpr*>(e));
        case EK::With: return checkWith(static_cast<WithExpr*>(e));
        case EK::TypeOf: {
            auto* t = static_cast<TypeOfExpr*>(e);
            t->target = resolveType(t->tref, true);
            if (t->target->isError()) return t->target;
            MethodDecl* from = typeFromHandle();
            if (!typeDecl || !from) {
                diag.error(e->loc, "'typeof' requiere std.Type");
                return tc_.error();
            }
            useMethod(from, &e->loc);
            if (!t->target->isClass() && !t->target->isEnum() &&
                std::find(typeofTypes.begin(), typeofTypes.end(), t->target) == typeofTypes.end())
                typeofTypes.push_back(t->target);
            return typeDecl->type;
        }
        case EK::NameOf: {
            auto* n = static_cast<NameOfExpr*>(e);
            Expr* o = n->operand;
            if (o->kind == EK::Name) n->value = static_cast<NameExpr*>(o)->name;
            else if (o->kind == EK::Member) n->value = static_cast<MemberExpr*>(o)->name;
            else if (o->kind == EK::This) n->value = "this";
            else {
                diag.error(o->loc, "'nameof' requiere un nombre (variable, tipo, miembro o método)");
                return tc_.get(TK::String);
            }
            if (o->kind == EK::Member) {  // nameof(Tipo.Miembro): también miembros de instancia
                auto* m = static_cast<MemberExpr*>(o);
                Type* ot = check(m->obj);
                if (m->obj->vk == ValKind::TypeName && ot->isAggregate()) {
                    ClassDecl* c = ot->decl;
                    if (!findField(c, m->name) && !findGetter(c, m->name) && findMethods(c, m->name).empty())
                        diag.error(m->nameLoc, "'" + c->displayName + "' no contiene una definición para '" + m->name + "'");
                    return tc_.get(TK::String);
                }
            }
            check(o);  // el nombre debe existir (también tipos y grupos de métodos)
            return tc_.get(TK::String);
        }
        default: return tc_.error();
    }
}
