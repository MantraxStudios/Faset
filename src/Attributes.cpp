// Faset - atributos.
//
// Un atributo de usuario es una clase que deriva de std.Attribute (lib/std/attributes.fst):
//
//   [AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
//   class Rango : Attribute
//   {
//       public int Min, Max;
//       public string Mensaje = "";
//       public Rango(int min, int max) { Min = min; Max = max; }
//   }
//
//   class Persona { [Rango(0, 150, Mensaje = "edad no válida")] public int Edad; }
//
// '[Rango(...)]' busca la clase 'Rango' o 'RangoAttribute'. Los argumentos del constructor y las
// propiedades con nombre se evalúan al compilar (con el intérprete de Comptime.cpp): el atributo es
// un objeto de tiempo de compilación que la reflexión lee sin coste (f.Atributo<Rango>().Min) y que
// a.Crear() construye al ejecutar. [AttributeUsage] limita dónde se puede poner y si se repite.
//
// Los atributos integrados que entiende el compilador sin clase son [TrackCaller], [Export],
// [ExceptionBase], los de faset test ([Test], [TestCase]...), [CallerMemberName]/[CallerLineNumber]/
// [CallerFilePath] y [SetsRequiredMembers]; [Obsolete], [Conditional], [Reflectable] y [CallerArgumentExpression]
// son clases de std (también se pueden consultar por reflexión).
#include <algorithm>

#include "ComptimeInterp.h"

namespace {

struct Builtin {
    const char* name;
    int targets;
};
const Builtin kBuiltins[] = {
    {"TrackCaller", kTgMethod | kTgProperty}, {"Export", kTgMethod}, {"ExceptionBase", kTgClass},
    // faset test (TestRunner.cpp)
    {"Test", kTgMethod}, {"TestCase", kTgMethod}, {"Ignore", kTgMethod}, {"Setup", kTgMethod}, {"Teardown", kTgMethod},
    // parámetros opcionales e inicializadores (Members.cpp)
    {"CallerMemberName", kTgParameter}, {"CallerLineNumber", kTgParameter}, {"CallerFilePath", kTgParameter},
    {"SetsRequiredMembers", kTgConstructor},
};
// Los integrados que se pueden repetir.
bool builtinMultiple(const std::string& n) { return n == "TestCase"; }

std::string targetName(int t) {
    switch (t) {
        case kTgClass: return "classes";
        case kTgStruct: return "structs";
        case kTgEnum: return "enums";
        case kTgInterface: return "interfaces";
        case kTgField: return "fields";
        case kTgProperty: return "properties";
        case kTgMethod: return "methods";
        case kTgConstructor: return "constructors";
        case kTgParameter: return "parameters";
        default: return "?";
    }
}

std::string targetList(int mask) {
    std::string s;
    for (int b = 1; b <= kTgParameter; b <<= 1)
        if (mask & b) s += (s.empty() ? "" : ", ") + targetName(b);
    return s;
}

}  // namespace

class CtAttr {
public:
    static ClassDecl* attributeBase(Sema& S) {
        NamespaceSym* ns = S.findNs({"std"});
        if (!ns) return nullptr;
        auto it = ns->types.find("Attribute");
        return it == ns->types.end() ? nullptr : it->second;
    }

    static ClassDecl* findClass(Sema& S, const std::string& name) {
        for (const std::string& n : {name, name + "Attribute"}) {
            Sym s = S.lookupUnqualified(n, SourceLoc());
            if (s.kind == Sym::TypeK && s.decl && !s.decl->isTemplate()) return s.decl;
        }
        return nullptr;
    }

    // [AttributeUsage(destinos, AllowMultiple = ...)] de la clase del atributo (o de sus bases).
    static void usage(Sema& S, ClassDecl* ac, int& targets, bool& multiple) {
        targets = kTgAll;
        multiple = false;
        for (ClassDecl* k = ac; k; k = k->base) {
            for (Attribute& u : k->attrs) {
                if (u.name != "AttributeUsage" && u.name != "AttributeUsageAttribute") continue;
                Sema::CtxSave save(S);
                S.enter(k, nullptr);
                CtInterp I(S);
                CtValue v;
                if (!u.argExprs.empty() && I.run(u.argExprs[0], v, "[AttributeUsage]") && v.k == CtValue::Int) targets = (int)v.i;
                for (size_t i = 0; i < u.namedArgs.size(); i++)
                    if (u.namedArgs[i] == "AllowMultiple" && I.run(u.namedExprs[i], v, "[AttributeUsage]") && v.k == CtValue::Bool)
                        multiple = v.i != 0;
                return;
            }
        }
    }
};

void Sema::attrResolveList(std::vector<Attribute>& attrs, int target, ClassDecl* cls, FileScope* file) {
    CtState& st = ct();
    bool any = false;
    for (Attribute& a : attrs) any |= a.state == 0;
    if (!any) return;
    CtxSave save(*this);
    if (cls) enter(cls, nullptr);
    if (file) ctx_.file = file;
    for (Attribute& a : attrs) {
        if (a.state != 0) continue;
        a.state = 1;
        if (a.name == kCompletionMarker) {  // IntelliSense: [Ra|]
            completionRequested = true;
            ClassDecl* base = CtAttr::attributeBase(*this);
            for (ClassDecl* c : prog_.types) {
                if (c->isTemplate() || c->templateOf || !base || c == base || !derivesFrom(c, base)) continue;
                std::string label = c->name;
                if (label.size() > 9 && label.compare(label.size() - 9, 9, "Attribute") == 0) label.resize(label.size() - 9);
                addCompletion(label, 7, "(atributo) " + typeDescription(c));
            }
            for (const Builtin& b : kBuiltins) addCompletion(b.name, 7, "(builtin attribute)");
            a.state = 2;
            continue;
        }
        ClassDecl* ac = CtAttr::findClass(*this, a.name);
        if (!ac) {
            const Builtin* bi = nullptr;
            for (const Builtin& b : kBuiltins)
                if (a.name == b.name) bi = &b;
            if (bi) {
                if (!(bi->targets & target))
                    diag.error(a.loc, "attribute [" + a.name + "] cannot be applied to " + targetName(target) + " (only to " +
                                          targetList(bi->targets) + ")");
                if (!builtinMultiple(a.name))
                    for (Attribute& o : attrs)
                        if (&o != &a && o.state == 2 && !o.cls && o.name == a.name) {
                            diag.error(a.loc, "attribute [" + a.name + "] is duplicated");
                            break;
                        }
                if (ideMode) addRef(a.loc, (int)a.name.size(), "(builtin attribute) " + a.name, nullptr);
            } else {
                diag.error(a.loc, "unknown attribute '" + a.name + "' (there is no class '" + a.name + "' or '" + a.name +
                                      "Attribute' deriving from Attribute)");
            }
            a.state = 2;
            continue;
        }
        resolveClassSignatures(ac);
        ClassDecl* base = CtAttr::attributeBase(*this);
        if (!base || !derivesFrom(ac, base)) {
            diag.error(a.loc, "'" + ac->displayName + "' is not an attribute: an attribute class must derive from Attribute");
            a.state = 2;
            continue;
        }
        a.cls = ac;
        if (ideMode) addRef(a.loc, (int)a.name.size(), "(atributo) " + typeDescription(ac), &ac->loc);
        int targets;
        bool multiple;
        CtAttr::usage(*this, ac, targets, multiple);
        if (!(targets & target))
            diag.error(a.loc, "attribute [" + a.name + "] cannot be applied to " + targetName(target) + "; per its [AttributeUsage] it is only valid for " +
                                  targetList(targets));
        if (!multiple) {
            int n = 0;
            for (Attribute& o : attrs)
                if (&o != &a && o.state == 2 && o.cls == ac) n++;
            if (n) diag.error(a.loc, "attribute [" + a.name + "] is duplicated (use [AttributeUsage(..., AllowMultiple = true)] to allow it)");
        }
        // Evaluación al compilar: argumentos del constructor y propiedades con nombre.
        CtInterp I(*this);
        std::vector<CtValue> args;
        bool ok = true;
        for (Expr* x : a.argExprs) {
            CtValue v;
            if (!I.run(x, v, "argument of attribute [" + a.name + "]")) {
                ok = false;
                break;
            }
            args.push_back(v);
        }
        if (ok) {
            try {
                std::vector<CtValue> ctorArgs = args;
                CtValue obj = I.construct(ac, ctorArgs, a.loc);
                if (!ac->ctors.empty()) {
                    std::vector<CtValue> again = args;
                    a.ctor = I.pick(ac->ctors, again, a.loc, "the constructor of '" + ac->displayName + "'");
                }
                std::vector<std::pair<std::string, CtValue>> named;
                for (size_t i = 0; i < a.namedArgs.size(); i++) {
                    const std::string& n = a.namedArgs[i];
                    CtValue v = I.eval(a.namedExprs[i]);
                    FieldDecl* f = findField(ac, n);
                    MethodDecl* g = f ? nullptr : findGetter(ac, n);
                    MethodDecl* set = g ? FindSetter(g) : nullptr;
                    if (f && !f->isStatic() && f->mods.access == Access::Public && !f->mods.isReadonly && !f->mods.isConst) {
                        obj.obj->fields[n] = I.convert(v, f->type, a.namedLocs[i]);
                    } else if (set && set->mods.access == Access::Public) {
                        I.callMethod(set, {v}, obj.obj, a.namedLocs[i]);
                    } else {
                        diag.error(a.namedLocs[i], "'" + ac->displayName + "' has no writable public field or property '" + n + "'");
                        continue;
                    }
                    if (ideMode) addRef(a.namedLocs[i], (int)n.size(), "(attribute property) " + ac->displayName + "." + n,
                                        f ? &f->loc : &g->loc);
                    named.push_back({n, v});
                }
                obj.obj->attr = &a;
                st.attrObjs[&a] = obj.obj;
                st.attrArgs[&a] = args;
                st.attrNamed[&a] = named;
            } catch (CtError& err) {
                I.report(err, a.loc, "attribute [" + a.name + "]");
            }
        }
        a.state = 2;
    }
}

void Sema::attrCheckAll() {
    CtState& st = ct();
    if (st.attrsChecked) return;
    st.attrsChecked = true;
    size_t n = prog_.types.size();
    for (size_t i = 0; i < n; i++) {
        ClassDecl* c = prog_.types[i];
        if (c->templateOf || c->isTemplate() || c->isTuple) continue;
        if (!c->isNamespaceScope) {
            int t = c->kind == ClassKind::Struct ? kTgStruct : c->kind == ClassKind::Enum ? kTgEnum
                    : c->kind == ClassKind::Interface ? kTgInterface : kTgClass;
            attrResolveList(c->attrs, t, c, c->file);
        }
        for (FieldDecl* f : c->fields) attrResolveList(f->attrs, kTgField, c, f->file ? f->file : c->file);
        for (MethodDecl* m : c->methods) {
            if (m->kind == MethodKind::Setter) continue;  // comparte los atributos de su propiedad
            FileScope* file = m->file ? m->file : c->file;
            attrResolveList(m->attrs, m->kind == MethodKind::Getter ? kTgProperty : kTgMethod, c, file);
            for (Attribute& a : m->attrs)  // [Conditional] quita las llamadas: no puede haber un valor que usar
                if (a.cls && a.cls->name == "Conditional" && a.cls->ns == "std" && m->ret && !m->ret->isVoid())
                    diag.error(a.loc, "[Conditional] can only be applied to 'void' methods");
            for (Param& p : m->params) attrResolveList(p.attrs, kTgParameter, c, file);
        }
        for (MethodDecl* m : c->ctors) {
            FileScope* file = m->file ? m->file : c->file;
            attrResolveList(m->attrs, kTgConstructor, c, file);
            for (Param& p : m->params) attrResolveList(p.attrs, kTgParameter, c, file);
        }
        if (c->dtor) attrResolveList(c->dtor->attrs, kTgMethod, c, c->dtor->file ? c->dtor->file : c->file);
    }
}

// a.Crear(): new Atributo(args) { Propiedad = valor, ... } con los valores evaluados al compilar.
Expr* Sema::attrCreateExpr(Attribute* a, SourceLoc loc) {
    CtState& st = ct();
    if (!a->cls) return nullptr;
    auto mkRef = [&](Type* t) {
        auto* tr = new TypeRef();
        tr->loc = loc;
        tr->parts = {t->str()};
        tr->preset = t;
        return tr;
    };
    auto* n = new NewExpr(loc);
    n->tref = mkRef(a->cls->type);
    std::string err;
    for (const CtValue& v : st.attrArgs[a]) {
        Expr* x = CtHooks::toExpr(*this, v, loc, err);
        if (!x) {
            diag.error(loc, "cannot create [" + a->name + "] at run time: " + err);
            return nullptr;
        }
        n->args.push_back(x);
    }
    auto& named = st.attrNamed[a];
    if (named.empty()) return n;
    Type* t = checkValue(n);
    VarInfo* tmp = hiddenLocal(t, loc, true);
    auto* let = new LetExpr(loc);
    let->binds.push_back({tmp, n});
    for (auto& [name, v] : named) {
        Expr* x = CtHooks::toExpr(*this, v, loc, err);
        if (!x) {
            diag.error(loc, "cannot create [" + a->name + "] at run time: " + err);
            return nullptr;
        }
        auto* ref = new NameExpr(loc);
        ref->name = tmp->name;
        auto* m = new MemberExpr(loc);
        m->obj = ref;
        m->name = name;
        m->nameLoc = loc;
        auto* as = new AssignExpr(loc);
        as->op = "=";
        as->lhs = m;
        as->rhs = x;
        checkValue(as);
        let->seq.push_back(as);
    }
    auto* ref = new NameExpr(loc);
    ref->name = tmp->name;
    checkValue(ref);
    let->seq.push_back(ref);
    let->type = t;
    return let;
}
