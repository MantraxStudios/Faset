// Faset - generación de C para la orientación a objetos.
//
// Representación (ver también SemaClasses.cpp):
//   struct fs_std_Object { const faset_type* faset_vt; };     raíz: puntero al tipo / vtable
//   struct fs_Animal     { fs_std_Object base; ...campos };    la base incrustada al principio
//   struct fs_Perro      { fs_Animal base; ...campos };        (Perro*) es un (Animal*) válido
//
//   La descripción del tipo (faset_type: nombre, base, antecesores, interfaces, tamaño) es el
//   primer miembro de la vtable estática de cada clase:
//     struct fs_Animal__vt { fs_std_Object__vt base; void (*v_Hablar)(fs_std_Object*); };
//   Una llamada virtual pasa por un 'thunk' static inline que se reduce a
//     ((const fs_Animal__vt*)obj->faset_vt)->v_Hablar(obj)  (una carga y una llamada indirecta).
//   Las referencias a interfaz son el mismo puntero al objeto; el método se busca en la lista de
//   interfaces de la clase (faset_itab: una comparación de punteros por interfaz implementada)
//   que apunta a la tabla de métodos de esa pareja (clase, interfaz).
//   'x is T' y '(T)x' miran un único elemento del arreglo de antecesores: O(1).
#include <algorithm>
#include <functional>
#include <set>

#include "CodeGen.h"

namespace {

const char* const kTypeRuntime = R"FASET(
/* ---- tipos en tiempo de ejecución: herencia, interfaces, is / as, typeof */
typedef struct faset_type faset_type;
typedef struct faset_itab_ent { const faset_type* iface; const void* itab; } faset_itab_ent;
struct faset_type {
    faset_string name;                /* "Perro", "List<int>" */
    faset_string fullName;            /* "Zoo.Perro" */
    const faset_type* base;
    int64_t size;
    int32_t kind;                     /* 0 clase, 1 interfaz, 2 enum, 3 struct, 4 primitivo */
    int32_t depth;                    /* clases: distancia hasta object */
    const faset_type* const* anc;     /* anc[i]: antecesor de profundidad i; anc[depth] == este tipo */
    int32_t nitabs;                   /* interfaces implementadas (todas) */
    const faset_itab_ent* itabs;
    int32_t nenum;
    const faset_string* enumNames;
    const int32_t* enumValues;
    int32_t flags;                    /* 1 abstract, 2 sealed, 4 record */
};
#define FASET_TYPEOF(o) (*(const faset_type* const*)(o))
static inline _Bool faset_type_is(const faset_type* t, const faset_type* target) {
    if (t == target) return 1;
    if (target->kind == 1) {
        for (int32_t i = 0; i < t->nitabs; i++)
            if (t->itabs[i].iface == target) return 1;
        return 0;
    }
    return target->kind == 0 && t->kind == 0 && t->depth > target->depth && t->anc[target->depth] == target;
}
static inline _Bool faset_is(const void* o, const faset_type* target) { return o && faset_type_is(FASET_TYPEOF(o), target); }
static inline void* faset_as(void* o, const faset_type* target) {
    return (o && faset_type_is(FASET_TYPEOF(o), target)) ? o : (void*)0;
}
static faset_string faset_cstr_(const char* s) {
    int64_t n = 0;
    while (s[n]) n++;
    return FASET_STR(s, n);
}
static FASET_NORETURN void faset_panic_cast(const faset_type* from, const faset_type* to, const char* f, int32_t l) {
    faset_string m = faset_str_concat(faset_cstr_("conversi\303\263n no v\303\241lida de "), from->name);
    m = faset_str_concat(faset_str_concat(m, faset_cstr_(" a ")), to->name);
    faset_panic_at(m, f, l);
}
static inline void* faset_cast(void* o, const faset_type* target, const char* f, int32_t l) {
    if (o && FASET_UNLIKELY(!faset_type_is(FASET_TYPEOF(o), target))) faset_panic_cast(FASET_TYPEOF(o), target, f, l);
    return o;
}
static FASET_NORETURN void faset_panic_noiface(const faset_type* t, const faset_type* iface) {
    faset_string m = faset_str_concat(faset_cstr_("el objeto de tipo "), t->name);
    m = faset_str_concat(faset_str_concat(m, faset_cstr_(" no implementa la interfaz ")), iface->name);
    faset_panic_at(m, "?", 0);
}
static inline const void* faset_itab(const void* o, const faset_type* iface) {
    const faset_type* t = FASET_TYPEOF(o);
    const faset_itab_ent* e = t->itabs;
    for (int32_t i = 0, n = t->nitabs; i < n; i++)
        if (e[i].iface == iface) return e[i].itab;
    faset_panic_noiface(t, iface);
    return 0;
}
static inline int32_t faset_f64_hash(double d) {
    union { double d; uint64_t u; } x;
    x.d = d == 0 ? 0.0 : d;
    return (int32_t)(x.u ^ (x.u >> 32));
}
int32_t faset_str_hash(faset_string s) {
    uint32_t h = 2166136261u;
    for (int64_t i = 0; i < s.len; i++) h = (h ^ s.ptr[i]) * 16777619u;
    return (int32_t)h;
}
/* API de std.Object / std.Type (extern en core.fst) */
void* faset_obj_type(void* o) { return (void*)FASET_TYPEOF(o); }
int32_t faset_obj_hash(void* o) {
    uint64_t p = (uint64_t)(uintptr_t)o;
    p ^= p >> 33;
    p *= 0xff51afd7ed558ccdULL;
    p ^= p >> 33;
    return (int32_t)p;
}
faset_string faset_type_name(void* t) { return ((const faset_type*)t)->name; }
faset_string faset_type_fullname(void* t) { return ((const faset_type*)t)->fullName; }
void* faset_type_base(void* t) { return (void*)((const faset_type*)t)->base; }
int32_t faset_type_kind(void* t) { return ((const faset_type*)t)->kind; }
int32_t faset_type_flags(void* t) { return ((const faset_type*)t)->flags; }
_Bool faset_type_assignable(void* to, void* from) {
    const faset_type* a = (const faset_type*)to;
    const faset_type* b = (const faset_type*)from;
    if (a == b) return 1;
    if (a->kind > 1 || b->kind > 1) return 0;
    if (a->kind == 0 && a->depth == 0 && b->kind == 1) return 1; /* interfaz -> object */
    return faset_type_is(b, a);
}
int32_t faset_type_enum_count(void* t) { return ((const faset_type*)t)->nenum; }
faset_string faset_type_enum_name(void* t, int32_t i) { return ((const faset_type*)t)->enumNames[i]; }
int32_t faset_type_enum_value(void* t, int32_t i) { return ((const faset_type*)t)->enumValues[i]; }
)FASET";

bool emitted(MethodDecl* m) { return m && !m->isTemplate() && m->body && m->checked; }

// Nombre de un miembro para mostrar (sin el sufijo del campo de respaldo de las propiedades).
std::string shownName(FieldDecl* f) {
    const std::string suffix = "__valor";
    if (f->name.size() > suffix.size() && f->name.compare(f->name.size() - suffix.size(), suffix.size(), suffix) == 0)
        return f->name.substr(0, f->name.size() - suffix.size());
    return f->name;
}

}  // namespace

// ------------------------------------------------------------------ utilidades

std::string CodeGen::objC() { return sema_.objectDecl ? sema_.objectDecl->cname : std::string("void"); }

std::string CodeGen::tiOf(ClassDecl* c) { return c->cname + "__TI"; }

std::string CodeGen::tiOfType(Type* t) {
    if ((t->isClass() || t->isEnum()) && t->decl) return tiOf(t->decl);
    auto& v = sema_.typeofTypes;
    size_t i = std::find(v.begin(), v.end(), t) - v.begin();
    return "(&fs__tt" + std::to_string(i) + ")";
}

// Ruta hasta un campo desde una clase: los campos heredados están en 'base.base. ...'.
std::string CodeGen::fieldPath(ClassDecl* from, FieldDecl* f) {
    std::string path;
    for (ClassDecl* k = from; k; k = k->base) {
        if (k == f->owner) return path + f->cname;
        path += "base.";
    }
    return f->cname;
}

// Receptor convertido al tipo que espera el método (la clase que lo declara, u object).
std::string CodeGen::selfArg(MethodDecl* m, const std::string& self) {
    ClassDecl* o = m->owner;
    if (!o || (o->kind != ClassKind::Class && o->kind != ClassKind::Interface)) return self;
    return "((" + (m->objSelf ? objC() : o->cname) + "*)" + self + ")";
}

// Función a la que se llama: el método, o el thunk de despacho virtual / de interfaz.
std::string CodeGen::calleeName(MethodDecl* m, bool nonVirtual) {
    if (m->isStatic() || !m->owner) return m->cname;
    if (m->owner->isInterface()) return m->cname + "__id";
    if (m->vslot >= 0 && m->vroot && !nonVirtual && !m->mods.isSealed && !m->owner->mods.isSealed)
        return m->vroot->cname + "__vd";
    return m->cname;
}

bool CodeGen::hasDtorChain(ClassDecl* c) {
    for (ClassDecl* k = c; k; k = k->base)
        if (k->dtor && emitted(k->dtor)) return true;
    return false;
}

// Construcción por defecto de la base (constructor sin parámetros o inicialización de campos).
std::string CodeGen::baseDefaultCtor(ClassDecl* c) {
    ClassDecl* b = c->base;
    if (!b) return "";
    std::string self = "((" + b->cname + "*)self)";
    if (b->ctors.empty()) return b->cname + "__ctord(" + self + ")";
    MethodDecl* p = Sema::paramlessCtor(b);
    return p ? p->cname + "(" + self + ")" : "";
}

// Puntero a función con la firma de un método de instancia que recibe 'object'.
std::string CodeGen::fnPtrDecl(MethodDecl* m, const std::string& name) {
    std::string s = ctype(m->ret) + (m->retIsRef() ? "*" : "") + " (*" + name + ")(" + objC() + "*";
    for (Param& p : m->params) s += ", " + ctype(p.type) + (p.isRef() ? "*" : "");
    return s + ")";
}

void CodeGen::emitClassStructPrefix(ClassDecl* c) {
    if (c->base) out_ << "    " << c->base->cname << " base;\n";
    else out_ << "    const faset_type* faset_vt;\n";
}

// Prólogo de un constructor de clase: ': this(...)', o los inicializadores de campos y la base.
void CodeGen::emitCtorPrologue(MethodDecl* m) {
    ClassDecl* c = m->owner;
    if (m->ctorInit == 2 && m->ctorInitTarget) {
        line(call(m->ctorInitTarget, "self", m->ctorInitArgs, m->ctorInitLoc) + ";");
        return;
    }
    if (c->kind != ClassKind::Class) return;
    line(c->cname + "__init(self);");
    if (!c->base) return;
    if (m->ctorInitTarget) line(call(m->ctorInitTarget, "self", m->ctorInitArgs, m->ctorInitLoc) + ";");
    else if (std::string b = baseDefaultCtor(c); !b.empty()) line(b + ";");
}

// ------------------------------------------------------------------ registros

std::string CodeGen::strOf(Type* t, const std::string& v, int depth) {
    switch (t->kind) {
        case TK::String: return v;
        case TK::Bool: return "((" + v + ") ? FASET_STR(\"True\", 4) : FASET_STR(\"False\", 5))";
        case TK::Char: return "faset_char_to_str(" + v + ")";
        case TK::Float: return "faset_f32_to_str(" + v + ")";
        case TK::Double: return "faset_f64_to_str(" + v + ")";
        case TK::Enum: return t->decl->cname + "__name(" + v + ")";
        case TK::Class: return "fs__obj_str((" + objC() + "*)(" + v + "))";
        case TK::Pointer: case TK::FuncPtr: case TK::Null: return "faset_u64_to_str((uint64_t)(uintptr_t)(" + v + "))";
        case TK::Struct: {
            for (MethodDecl* m : t->decl->methods)
                if (m->name == "ToString" && m->kind == MethodKind::Normal && !m->isStatic() && m->params.empty() &&
                    m->ret->is(TK::String) && emitted(m))
                    return m->cname + "(&(" + v + "))";
            return "FASET_STR(" + cstring(t->decl->displayName) + ", " + std::to_string(t->decl->displayName.size()) + ")";
        }
        default:
            if (t->isUnsignedInt()) return "faset_u64_to_str((uint64_t)(" + v + "))";
            return "faset_i64_to_str((int64_t)(" + v + "))";
    }
}

std::string CodeGen::eqOf(Type* t, const std::string& a, const std::string& b, int depth) {
    switch (t->kind) {
        case TK::String: return "faset_str_eq(" + a + ", " + b + ")";
        case TK::Class: return "fs__obj_eq((" + objC() + "*)(" + a + "), (" + objC() + "*)(" + b + "))";
        case TK::Struct: {
            for (MethodDecl* m : t->decl->methods)
                if (m->kind == MethodKind::Operator && m->name == "operator==" && m->params.size() == 2 &&
                    m->params[0].type == t && m->params[1].type == t && !m->params[0].isRef() && emitted(m))
                    return m->cname + "(" + a + ", " + b + ")";
            if (depth > 8) return "1";
            std::string s;
            for (FieldDecl* f : t->decl->fields)
                if (!f->isStatic())
                    s += (s.empty() ? "" : " && ") + eqOf(f->type, "(" + a + ")." + f->cname, "(" + b + ")." + f->cname, depth + 1);
            return s.empty() ? "1" : "(" + s + ")";
        }
        default: return "((" + a + ") == (" + b + "))";
    }
}

std::string CodeGen::hashOf(Type* t, const std::string& v, int depth) {
    switch (t->kind) {
        case TK::String: return "faset_str_hash(" + v + ")";
        case TK::Float: case TK::Double: return "faset_f64_hash((double)(" + v + "))";
        case TK::Class: return "fs__obj_hash((" + objC() + "*)(" + v + "))";
        case TK::Pointer: case TK::FuncPtr: case TK::Null: return "faset_obj_hash((void*)(" + v + "))";
        case TK::Struct: {
            for (MethodDecl* m : t->decl->methods)
                if (m->name == "GetHashCode" && m->kind == MethodKind::Normal && !m->isStatic() && m->params.empty() &&
                    emitted(m))
                    return m->cname + "(&(" + v + "))";
            if (depth > 8) return "0";
            std::string s = "(int32_t)(17u";
            for (FieldDecl* f : t->decl->fields)
                if (!f->isStatic()) s += " * 31u + (uint32_t)" + hashOf(f->type, "(" + v + ")." + f->cname, depth + 1);
            return s + ")";
        }
        default: {
            std::string u = "((uint64_t)(int64_t)(" + v + "))";
            if (t->isUnsignedInt()) u = "((uint64_t)(" + v + "))";
            return "((int32_t)(" + u + " ^ (" + u + " >> 32)))";
        }
    }
}

// Cuerpos generados de un 'record': ToString, GetHashCode y operator==.
void CodeGen::emitRecordBody(MethodDecl* m) {
    if (m->recordGen >= 4) {  // uniones (Unions.cpp)
        emitUnionBody(m);
        return;
    }
    ClassDecl* c = m->owner;
    bool isClass = c->kind == ClassKind::Class;
    std::vector<FieldDecl*> fields;  // de la base hacia la derivada (sin object)
    for (ClassDecl* k = c; k && k != sema_.objectDecl; k = k->base) {
        std::vector<FieldDecl*> own;
        for (FieldDecl* f : k->fields)
            if (!f->isStatic()) own.push_back(f);
        fields.insert(fields.begin(), own.begin(), own.end());
    }
    if (m->recordGen == 1) {
        std::string head = c->name + " { ";
        line("faset_string s = FASET_STR(" + cstring(head) + ", " + std::to_string(head.size()) + ");");
        bool first = true;
        for (FieldDecl* f : fields) {
            bool backing = shownName(f) != f->name;
            Access a = f->mods.access;
            if (backing)  // propiedad: su acceso es el del 'get'
                for (ClassDecl* k = f->owner; k; k = nullptr)
                    for (MethodDecl* g : k->methods)
                        if (g->kind == MethodKind::Getter && g->name == shownName(f)) a = g->mods.access;
            if (a != Access::Public && a != Access::Internal) continue;
            std::string label = (first ? "" : ", ") + shownName(f) + " = ";
            first = false;
            line("s = faset_str_concat(s, FASET_STR(" + cstring(label) + ", " + std::to_string(label.size()) + "));");
            line("s = faset_str_concat(s, " + strOf(f->type, "self->" + fieldPath(c, f)) + ");");
        }
        line(std::string("s = faset_str_concat(s, FASET_STR(") + (first ? "\"}\", 1" : "\" }\", 2") + "));");
        line("return s;");
    } else if (m->recordGen == 2) {
        line("uint32_t h = 17u;");
        for (FieldDecl* f : fields) line("h = h * 31u + (uint32_t)" + hashOf(f->type, "self->" + fieldPath(c, f)) + ";");
        line("return (int32_t)h;");
    } else if (m->recordGen == 3) {
        std::string a = "p_" + m->params[0].name, b = "p_" + m->params[1].name;
        std::string acc = isClass ? "->" : ".";
        if (isClass) {
            line("if (" + a + " == " + b + ") return 1;");
            line("if (!" + a + " || !" + b + ") return 0;");
            line("if (FASET_TYPEOF(" + a + ") != FASET_TYPEOF(" + b + ")) return 0;");
        }
        std::string s;
        for (FieldDecl* f : fields)
            s += (s.empty() ? "" : " && ") + eqOf(f->type, a + acc + fieldPath(c, f), b + acc + fieldPath(c, f));
        line("return " + (s.empty() ? std::string("1") : s) + ";");
    }
}

// ------------------------------------------------------------------ descripciones de tipos y vtables

void CodeGen::emitOO(int phase) {
    std::vector<ClassDecl*> classes, ifaces, enums;
    for (ClassDecl* c : sema_.structOrder)
        if (c->kind == ClassKind::Class) classes.push_back(c);
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate() || c->isNamespaceScope) continue;
        if (c->isInterface()) ifaces.push_back(c);
        else if (c->kind == ClassKind::Enum) enums.push_back(c);
    }
    std::string obj = objC();

    if (phase == 0) {
        out_ << kTypeRuntime << "\n";
        for (ClassDecl* i : ifaces) out_ << "typedef struct " << obj << " " << i->cname << ";\n";
        return;
    }

    // ---- tipos de las vtables (la de la base incrustada al principio) y de las tablas de interfaz
    for (ClassDecl* c : classes) {
        out_ << "typedef struct " << c->cname << "__vt {\n";
        out_ << "    " << (c->base ? c->base->cname + "__vt base;" : std::string("faset_type ti;")) << "\n";
        for (MethodDecl* m : c->methods)
            if (m->vroot == m) out_ << "    " << fnPtrDecl(m, "v_" + m->cname) << ";\n";
        out_ << "} " << c->cname << "__vt;\n";
    }
    for (ClassDecl* i : ifaces) {
        out_ << "typedef struct " << i->cname << "__it {\n";
        int n = 0;
        for (MethodDecl* m : i->methods)
            if (!m->isStatic() && !m->isTemplate() && m->kind != MethodKind::Operator) {
                out_ << "    " << fnPtrDecl(m, "v_" + m->cname) << ";\n";
                n++;
            }
        if (!n) out_ << "    char faset_vacio;\n";
        out_ << "} " << i->cname << "__it;\n";
    }
    // ---- declaraciones adelantadas de las descripciones
    for (ClassDecl* c : classes) {
        out_ << "static const " << c->cname << "__vt " << c->cname << "__vtbl;\n";
        out_ << "#define " << tiOf(c) << " ((const faset_type*)&" << c->cname << "__vtbl)\n";
    }
    for (ClassDecl* c : ifaces) {
        out_ << "static const faset_type " << c->cname << "__ti;\n";
        out_ << "#define " << tiOf(c) << " (&" << c->cname << "__ti)\n";
    }
    for (ClassDecl* c : enums) {
        out_ << "static const faset_type " << c->cname << "__ti;\n";
        out_ << "#define " << tiOf(c) << " (&" << c->cname << "__ti)\n";
    }
    for (size_t i = 0; i < sema_.typeofTypes.size(); i++) out_ << "static const faset_type fs__tt" << i << ";\n";

    // ---- thunks de despacho
    auto params = [&](MethodDecl* m, std::string& decl, std::string& args) {
        decl = obj + "* self";
        args = "self";
        for (Param& p : m->params) {
            decl += ", " + ctype(p.type) + (p.isRef() ? "*" : "") + " p_" + p.name;
            args += ", p_" + p.name;
        }
    };
    auto ret = [&](MethodDecl* m) { return ctype(m->ret) + (m->retIsRef() ? "*" : ""); };
    for (ClassDecl* c : classes)
        for (MethodDecl* m : c->methods) {
            if (m->vroot != m) continue;
            std::string decl, args;
            params(m, decl, args);
            out_ << "static inline " << ret(m) << " " << m->cname << "__vd(" << decl << ") { "
                 << (m->ret->isVoid() && !m->retIsRef() ? "" : "return ") << "((const " << c->cname
                 << "__vt*)FASET_TYPEOF(self))->v_" << m->cname << "(" << args << "); }\n";
        }
    for (ClassDecl* i : ifaces)
        for (MethodDecl* m : i->methods) {
            if (m->isStatic() || m->isTemplate() || m->kind == MethodKind::Operator) continue;
            std::string decl, args;
            params(m, decl, args);
            out_ << "static inline " << ret(m) << " " << m->cname << "__id(" << decl << ") { "
                 << (m->ret->isVoid() && !m->retIsRef() ? "" : "return ") << "((const " << i->cname << "__it*)faset_itab(self, "
                 << tiOf(i) << "))->v_" << m->cname << "(" << args << "); }\n";
        }
    // ---- construcción por defecto y cadena de destructores (prototipos)
    for (ClassDecl* c : classes) {
        if (c->ctors.empty()) out_ << "static void " << c->cname << "__ctord(" << c->cname << "* self);\n";
        if (hasDtorChain(c)) out_ << "static void " << c->cname << "__dtorchain(void* p);\n";
    }
    // ---- ayudas para object: ToString / Equals / GetHashCode con null
    if (ClassDecl* o = sema_.objectDecl) {
        auto vd = [&](const char* name) -> std::string {
            for (MethodDecl* m : o->methods)
                if (m->name == name && m->vroot == m) return m->cname + "__vd";
            return "";
        };
        std::string ts = vd("ToString"), eq = vd("Equals"), hc = vd("GetHashCode");
        out_ << "static faset_string fs__obj_str(" << obj << "* o) { return o ? "
             << (ts.empty() ? "FASET_STR(\"\", 0)" : ts + "(o)") << " : FASET_STR(\"\", 0); }\n";
        out_ << "static _Bool fs__obj_eq(" << obj << "* a, " << obj << "* b) { return a == b || (a && b && "
             << (eq.empty() ? "0" : eq + "(a, b)") << "); }\n";
        out_ << "static int32_t fs__obj_hash(" << obj << "* o) { return o ? " << (hc.empty() ? "faset_obj_hash(o)" : hc + "(o)")
             << " : 0; }\n";
    }
    // ---- enums: nombre de cada valor
    for (ClassDecl* e : enums) {
        out_ << "static faset_string " << e->cname << "__name(int32_t v) {\n    switch (v) {\n";
        std::set<int64_t> seen;
        for (EnumMember& m : e->enumMembers)
            if (seen.insert(m.val).second)
                out_ << "        case " << m.val << ": return FASET_STR(" << cstring(m.name) << ", " << m.name.size() << ");\n";
        out_ << "        default: return faset_i64_to_str(v);\n    }\n}\n";
    }

    // ---- descripciones (faset_type) y vtables
    auto str = [&](const std::string& s) { return "{(const uint8_t*)" + cstring(s) + ", " + std::to_string(s.size()) + "}"; };
    // object se muestra como "object" en los mensajes del compilador, pero su tipo se llama Object.
    auto shown = [&](ClassDecl* c) { return c == sema_.objectDecl ? c->name : c->displayName; };
    auto fullName = [&](ClassDecl* c) { return c->ns.empty() ? shown(c) : c->ns + "." + shown(c); };
    auto flags = [&](ClassDecl* c) {
        return std::to_string((c->mods.isAbstract ? 1 : 0) | (c->mods.isSealed ? 2 : 0) | (c->isRecord ? 4 : 0));
    };
    for (ClassDecl* i : ifaces) {
        if (!i->allInterfaces.empty()) {
            out_ << "static const faset_itab_ent " << i->cname << "__itabs[] = {";
            for (ClassDecl* j : i->allInterfaces) out_ << " {" << tiOf(j) << ", 0},";
            out_ << " };\n";
        }
        out_ << "static const faset_type " << i->cname << "__ti = { " << str(i->displayName) << ", " << str(fullName(i))
             << ", 0, 0, 1, -1, 0, " << i->allInterfaces.size() << ", "
             << (i->allInterfaces.empty() ? "0" : i->cname + "__itabs") << ", 0, 0, 0, 0 };\n";
    }
    for (ClassDecl* e : enums) {
        size_t n = e->enumMembers.size();
        if (n) {
            out_ << "static const faset_string " << e->cname << "__names[] = {";
            for (EnumMember& m : e->enumMembers) out_ << " " << str(m.name) << ",";
            out_ << " };\nstatic const int32_t " << e->cname << "__values[] = {";
            for (EnumMember& m : e->enumMembers) out_ << " " << m.val << ",";
            out_ << " };\n";
        }
        out_ << "static const faset_type " << e->cname << "__ti = { " << str(e->displayName) << ", " << str(fullName(e))
             << ", 0, 4, 2, -1, 0, 0, 0, " << n << ", " << (n ? e->cname + "__names" : "0") << ", "
             << (n ? e->cname + "__values" : "0") << ", 0 };\n";
    }
    for (size_t i = 0; i < sema_.typeofTypes.size(); i++) {
        Type* t = sema_.typeofTypes[i];
        bool isStruct = t->isStruct();
        std::string name = isStruct ? t->decl->displayName : t->str();
        std::string full = isStruct ? fullName(t->decl) : name;
        std::string size = t->isVoid() ? "0" : "(int64_t)sizeof(" + ctype(t) + ")";
        out_ << "static const faset_type fs__tt" << i << " = { " << str(name) << ", " << str(full) << ", 0, " << size << ", "
             << (isStruct ? 3 : 4) << ", -1, 0, 0, 0, 0, 0, 0, " << (isStruct && t->decl->isRecord ? 4 : 0) << " };\n";
    }
    for (ClassDecl* c : classes) {
        // tablas de interfaz de esta clase
        for (size_t k = 0; k < c->allInterfaces.size() && k < c->itabs.size(); k++) {
            ClassDecl* i = c->allInterfaces[k];
            out_ << "static const " << i->cname << "__it " << c->cname << "__it" << k << " = {";
            size_t j = 0;
            int n = 0;
            for (MethodDecl* im : i->methods) {
                if (im->isStatic() || im->isTemplate() || im->kind == MethodKind::Operator) continue;
                MethodDecl* impl = j < c->itabs[k].size() ? c->itabs[k][j] : nullptr;
                j++;
                n++;
                out_ << " .v_" << im->cname << " = " << (emitted(impl) ? impl->cname : std::string("0")) << ",";
            }
            if (!n) out_ << " 0";
            out_ << " };\n";
        }
        if (!c->allInterfaces.empty()) {
            out_ << "static const faset_itab_ent " << c->cname << "__itabs[] = {";
            for (size_t k = 0; k < c->allInterfaces.size(); k++)
                out_ << " {" << tiOf(c->allInterfaces[k]) << ", &" << c->cname << "__it" << k << "},";
            out_ << " };\n";
        }
        std::vector<ClassDecl*> chain;
        for (ClassDecl* k = c; k; k = k->base) chain.insert(chain.begin(), k);
        out_ << "static const faset_type* const " << c->cname << "__anc[] = {";
        for (ClassDecl* k : chain) out_ << " " << tiOf(k) << ",";
        out_ << " };\n";
        std::string ti = "{ " + str(shown(c)) + ", " + str(fullName(c)) + ", " + (c->base ? tiOf(c->base) : "0") +
                         ", (int64_t)sizeof(" + c->cname + "), 0, " + std::to_string(chain.size() - 1) + ", " + c->cname +
                         "__anc, " + std::to_string(c->allInterfaces.size()) + ", " +
                         (c->allInterfaces.empty() ? "0" : c->cname + "__itabs") + ", 0, 0, 0, " + flags(c) + " }";
        // Inicializador anidado: cada nivel de la jerarquía, con la implementación final de cada entrada.
        std::function<std::string(ClassDecl*)> init = [&](ClassDecl* level) {
            std::string s = "{ " + (level->base ? ".base = " + init(level->base) : ".ti = " + ti);
            for (MethodDecl* m : level->methods) {
                if (m->vroot != m) continue;
                MethodDecl* impl = m->vslot >= 0 && m->vslot < (int)c->vtable.size() ? c->vtable[m->vslot] : nullptr;
                s += ", .v_" + m->cname + " = " + (emitted(impl) ? impl->cname : std::string("0"));
            }
            return s + " }";
        };
        out_ << "static const " << c->cname << "__vt " << c->cname << "__vtbl = " << init(c) << ";\n";
    }

    // ---- construcción por defecto y destructores en cadena (derivada y luego base)
    for (ClassDecl* c : classes) {
        if (c->ctors.empty()) {
            out_ << "static void " << c->cname << "__ctord(" << c->cname << "* self) {\n";
            out_ << "    " << c->cname << "__init(self);\n";
            if (std::string b = baseDefaultCtor(c); !b.empty()) out_ << "    " << b << ";\n";
            out_ << "}\n";
        }
        if (hasDtorChain(c)) {
            out_ << "static void " << c->cname << "__dtorchain(void* p) {\n";
            if (c->dtor && emitted(c->dtor)) out_ << "    " << c->dtor->cname << "((" << c->cname << "*)p);\n";
            if (c->base && hasDtorChain(c->base)) out_ << "    " << c->base->cname << "__dtorchain(p);\n";
            out_ << "}\n";
        }
    }

    // ---- expresiones 'with': copia del registro y asignación de las propiedades indicadas
    for (WithExpr* w : sema_.withExprs) {
        if (!w->type || !w->type->isAggregate()) continue;
        ClassDecl* c = w->type->decl;
        bool isClass = c->kind == ClassKind::Class;
        std::string T = isClass ? c->cname + "*" : c->cname;
        out_ << "static " << T << " fs__with" << w->id << "(" << T << " src";
        for (size_t i = 0; i < w->inits.size(); i++)
            if (w->inits[i].field) out_ << ", " << ctype(w->inits[i].field->type) << " a" << i;
        out_ << ") {\n";
        if (isClass) {
            out_ << "    " << T << " r = (" << T << ")faset_obj_alloc((int64_t)sizeof(" << c->cname << "), "
                 << (hasDtorChain(c) ? c->cname + "__dtorchain" : std::string("0")) << ");\n";
            out_ << "    *r = *src;\n";
        }
        for (size_t i = 0; i < w->inits.size(); i++)
            if (w->inits[i].field)
                out_ << "    " << (isClass ? "r->" : "src.") << fieldPath(c, w->inits[i].field) << " = a" << i << ";\n";
        out_ << "    return " << (isClass ? "r" : "src") << ";\n}\n";
    }
    out_ << "\n";
}

// ------------------------------------------------------------------ expresiones

std::string CodeGen::ooExpr(Expr* e) {
    switch (e->kind) {
        case EK::Is: {
            auto* is = static_cast<IsExpr*>(e);
            std::string o = expr(is->operand);
            std::string r;
            if (!is->tref && !is->preset) {  // is null / is not null
                r = "((void*)(" + o + ") == 0)";
                return is->negate ? "(!" + r + ")" : r;
            }
            if (!is->target || !is->target->isClass()) return "0";
            std::string T = ctype(is->target);
            if (is->var) {
                std::string src = is->always ? "(" + T + ")(" + o + ")" : "(" + T + ")faset_as((void*)(" + o + "), " + tiOf(is->target->decl) + ")";
                r = "((" + is->var->cname + " = " + src + ") != 0)";
            } else if (is->always) {
                r = "((void*)(" + o + ") != 0)";
            } else {
                r = "faset_is((const void*)(" + o + "), " + tiOf(is->target->decl) + ")";
            }
            return is->negate ? "(!" + r + ")" : r;
        }
        case EK::As: {
            auto* as = static_cast<AsExpr*>(e);
            std::string T = ctype(e->type);
            if (as->always || as->operand->type->is(TK::Null)) return "((" + T + ")" + expr(as->operand) + ")";
            return "((" + T + ")faset_as((void*)(" + expr(as->operand) + "), " + tiOf(e->type->decl) + "))";
        }
        case EK::TypeOf: {
            auto* t = static_cast<TypeOfExpr*>(e);
            MethodDecl* from = sema_.typeFromHandle();
            return from->cname + "((void*)" + tiOfType(t->target) + ")";
        }
        case EK::NameOf: {
            auto* n = static_cast<NameOfExpr*>(e);
            return "FASET_STR(" + cstring(n->value) + ", " + std::to_string(n->value.size()) + ")";
        }
        case EK::With: {
            auto* w = static_cast<WithExpr*>(e);
            // El registro original y después los valores nuevos, en orden (EvalOrder.cpp).
            std::vector<EvalOp> ops = {{w->operand, expr(w->operand), ctype(w->operand->type)}};
            for (auto& in : w->inits)
                if (in.field) ops.push_back({in.value, expr(in.value), ctype(in.value->type)});
            std::string pre = sequence(ops);
            std::string s = "fs__with" + std::to_string(w->id) + "(" +
                            (w->type->isClass() ? chkObj(w->operand, ops[0].code) : ops[0].code);
            for (size_t i = 1; i < ops.size(); i++) s += ", " + ops[i].code;
            return seqWrap(pre, s + ")");
        }
        default: return "0";
    }
}
