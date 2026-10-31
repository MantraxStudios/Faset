// Faset - reflexión al ejecutar (opcional).
//
// typeof(Persona).GetFields(), GetProperties(), GetMethods(), GetValue/SetValue, Invoke y
// Activator.CreateInstance (lib/std/reflection.fst) necesitan metadatos en el ejecutable. Solo se
// generan para los tipos que los usan:
//
//   - las clases marcadas con [Reflectable] (y las que derivan de ellas);
//   - los tipos escritos directamente en typeof(X).GetFields()/GetProperties()/GetMethods()/... y en
//     Activator.CreateInstance(typeof(X)) / Activator.CreateInstance<X>() (el compilador lo detecta).
//
// Los metadatos no los escribe el compilador a mano: para cada tipo se añade un campo estático
// oculto en std.reflection.Reflection cuyo valor inicial es Registrar<X>(), una función genérica
// de la biblioteca escrita con 'comptime foreach' sobre Tipo<X>.Miembros/Metodos. Cada tipo recibe
// así funciones de acceso directas (sin búsquedas por nombre al leer un campo). Un programa que no
// usa la reflexión no contiene nada de esto.
#include "ComptimeInterp.h"

class CtReflect {
public:
    static ClassDecl* registry(Sema& S) {
        NamespaceSym* ns = S.findNs({"std", "reflection"});
        if (!ns) return nullptr;
        auto it = ns->types.find("Reflection");
        return it == ns->types.end() ? nullptr : it->second;
    }
    static bool marked(ClassDecl* c) {
        for (ClassDecl* k = c; k; k = k->base)
            for (Attribute& a : k->attrs)
                if (a.name == "Reflectable" || a.name == "ReflectableAttribute") return true;
        return false;
    }
};

void Sema::reflectWant(ClassDecl* c, SourceLoc loc) {
    CtState& st = ct();
    if (!c || c->isTemplate() || st.reflectSet.count(c)) return;
    st.reflectSet.insert(c);
    st.reflectQueue.push_back({c, loc});
}

bool Sema::reflectStep() {
    CtState& st = ct();
    for (size_t i = 0; i < prog_.types.size(); i++) {
        ClassDecl* c = prog_.types[i];
        if (c->isTemplate() || c->isNamespaceScope || (c->kind != ClassKind::Class && c->kind != ClassKind::Struct) ||
            st.reflectSet.count(c))
            continue;
        if (CtReflect::marked(c)) reflectWant(c, c->loc);
    }
    if (st.reflectDone == st.reflectQueue.size()) return false;
    ClassDecl* R = CtReflect::registry(*this);
    if (!R) {
        for (; st.reflectDone < st.reflectQueue.size(); st.reflectDone++)
            diag.error(st.reflectQueue[st.reflectDone].second,
                       "runtime reflection ([Reflectable], GetFields, Activator...) needs 'using std.reflection;'");
        return false;
    }
    resolveClassSignatures(R);
    while (st.reflectDone < st.reflectQueue.size()) {
        auto [c, loc] = st.reflectQueue[st.reflectDone++];
        if ((c->kind != ClassKind::Class && c->kind != ClassKind::Struct) || c->isInterface() || c->isStaticClass()) {
            diag.error(loc, "runtime reflection only supports classes and structs ('" + c->displayName +
                                "' is not one); for enums use compile-time reflection (Tipo<T>)");
            continue;
        }
        auto* f = new FieldDecl();
        f->loc = loc;
        f->mods.isStatic = true;
        f->mods.access = Access::Private;
        f->name = "__metadatos" + std::to_string(st.reflectDone);
        f->owner = R;
        f->type = tc_.get(TK::Bool);
        f->tref = presetRef(f->type, loc);
        f->cname = R->cname + "__s_" + f->name;
        f->unsafeCtx = true;
        auto* n = new NameExpr(loc);
        n->name = "Registrar";
        n->typeArgs = {presetRef(c->type, loc)};
        auto* call = new CallExpr(loc);
        call->callee = n;
        f->init = call;
        R->fields.push_back(f);
        fieldWork_.push_back({R, f});
    }
    return true;
}
