#include "Sema.h"

#include <algorithm>
#include <climits>
#include <functional>

#include "Parser.h"

namespace {

int64_t truncTo(int64_t v, const Type* t) {
    switch (t->kind) {
        case TK::SByte: return (int8_t)v;
        case TK::Byte: return (uint8_t)v;
        case TK::Short: return (int16_t)v;
        case TK::UShort: return (uint16_t)v;
        case TK::Int: case TK::Enum: return (int32_t)v;
        case TK::UInt: case TK::Char: return (uint32_t)v;
        default: return v;
    }
}

bool fits(int64_t v, const Type* t) {
    switch (t->kind) {
        case TK::SByte: return v >= INT8_MIN && v <= INT8_MAX;
        case TK::Byte: return v >= 0 && v <= UINT8_MAX;
        case TK::Short: return v >= INT16_MIN && v <= INT16_MAX;
        case TK::UShort: return v >= 0 && v <= UINT16_MAX;
        case TK::Int: return v >= INT32_MIN && v <= INT32_MAX;
        case TK::UInt: return v >= 0 && v <= (int64_t)UINT32_MAX;
        case TK::Char: return v >= 0 && v <= 0x10FFFF;
        case TK::Long: return true;
        case TK::ULong: return v >= 0;
        default: return false;
    }
}

int numRank(TK k) {
    switch (k) {
        case TK::SByte: case TK::Byte: return 1;
        case TK::Short: case TK::UShort: return 2;
        case TK::Char: return 3;
        case TK::Int: case TK::UInt: return 4;
        case TK::Long: case TK::ULong: return 5;
        case TK::Float: return 6;
        case TK::Double: return 7;
        default: return 0;
    }
}

bool isAssignOrCallLike(Expr* e) {
    switch (e->kind) {
        case EK::Call: case EK::Assign: case EK::Postfix: case EK::New: return true;
        case EK::CondAccess: case EK::CoalesceAssign: return true;  // obj?.Metodo();  a ??= b;
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            return u->op == "++" || u->op == "--";
        }
        default: return false;
    }
}

bool isConstTrue(Expr* e) { return e && e->kind == EK::BoolLit && static_cast<BoolLitExpr*>(e)->value; }

std::string typeList(const std::vector<Expr*>& args) {
    std::string s = "(";
    for (size_t i = 0; i < args.size(); i++) s += (i ? ", " : "") + (args[i]->type ? args[i]->type->str() : "?");
    return s + ")";
}

std::string join(const std::vector<std::string>& v, const char* sep) {
    std::string s;
    for (size_t i = 0; i < v.size(); i++) s += (i ? sep : "") + v[i];
    return s;
}

std::string mangleNs(const std::string& ns) {
    std::string s = "fs_";
    for (char c : ns) s += c == '.' ? '_' : c;
    if (!ns.empty()) s += "_";
    return s;
}

std::string mangleName(const std::string& name) {
    static const std::map<std::string, std::string> ops = {
        {"operator+", "op_add"}, {"operator-", "op_sub"}, {"operator*", "op_mul"}, {"operator/", "op_div"},
        {"operator%", "op_mod"}, {"operator==", "op_eq"}, {"operator!=", "op_ne"}, {"operator<", "op_lt"},
        {"operator>", "op_gt"}, {"operator<=", "op_le"}, {"operator>=", "op_ge"}, {"operator&", "op_and"},
        {"operator|", "op_or"}, {"operator^", "op_xor"}, {"operator<<", "op_shl"}, {"operator>>", "op_shr"},
        {"operator!", "op_not"}, {"operator~", "op_inv"}, {"operator[]", "op_index"},
    };
    auto it = ops.find(name);
    return it == ops.end() ? name : it->second;
}

std::string typeKey(const std::vector<Type*>& args) {
    std::string k;
    for (Type* t : args) k += std::to_string((uintptr_t)t) + ",";
    return k;
}

std::vector<TypeRef*>* exprTypeArgs(Expr* e) {
    if (e->kind == EK::Name) return &static_cast<NameExpr*>(e)->typeArgs;
    if (e->kind == EK::Member) return &static_cast<MemberExpr*>(e)->typeArgs;
    return nullptr;
}

std::string describeVar(VarInfo* v) {
    std::string kind = v->cname.rfind("p_", 0) == 0 ? "(parámetro) " : v->isConst ? "(constante local) " : "(variable local) ";
    return kind + v->type->str() + (v->isRef ? "& " : " ") + v->name;
}
std::string describeField(FieldDecl* f) {
    std::string kind = f->owner->isNamespaceScope ? "(variable global) "
                       : f->mods.isConst          ? "(constante) "
                       : f->isStatic()            ? "(campo estático) "
                                                  : "(campo) ";
    std::string owner = f->owner->isNamespaceScope ? (f->owner->ns.empty() ? "" : f->owner->ns + ".")
                                                   : f->owner->displayName + ".";
    return kind + (f->type ? f->type->str() : f->tref->str()) + " " + owner + f->name;
}
}  // namespace

// ================================================================== fases

bool Sema::run() {
    buildNamespaces();
    // En el IDE se sigue analizando aunque haya errores (de sintaxis o de nombres duplicados)
    // para ofrecer información de símbolos y autocompletado mientras se escribe.
    if (diag.errorCount && !ideMode) return false;
    for (FileScope* f : prog_.files) resolveUsings(f);
    excSetupHierarchy();  // [ExceptionBase]: campos heredados de la excepción base (Exceptions.cpp)
    size_t initial = prog_.types.size();
    for (size_t i = 0; i < initial; i++)
        if (!prog_.types[i]->isTemplate()) resolveClassSignatures(prog_.types[i]);
    assignFunctionNames();

    for (size_t i = 0; i < initial; i++) {
        ClassDecl* c = prog_.types[i];
        if (c->isTemplate() || c->kind == ClassKind::Enum) continue;
        for (FieldDecl* f : c->fields)
            if (f->init) fieldWork_.push_back({c, f});
        for (MethodDecl* m : c->methods) useMethod(m);
        for (MethodDecl* m : c->ctors) useMethod(m);
        useMethod(c->dtor);
    }
    processWork();
    orderStructs();
    findEntry();
    return diag.errorCount == 0;
}

NamespaceSym* Sema::getNs(const std::string& name, bool create) {
    NamespaceSym* ns = global_;
    if (name.empty()) return ns;
    size_t start = 0;
    for (;;) {
        size_t dot = name.find('.', start);
        std::string part = name.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        auto it = ns->children.find(part);
        if (it == ns->children.end()) {
            if (!create) return nullptr;
            auto* child = new NamespaceSym();
            child->name = ns->name.empty() ? part : ns->name + "." + part;
            child->parent = ns;
            ns->children[part] = child;
            ns = child;
        } else {
            ns = it->second;
        }
        if (dot == std::string::npos) break;
        start = dot + 1;
    }
    return ns;
}

NamespaceSym* Sema::findNs(const std::vector<std::string>& path) { return getNs(join(path, "."), false); }

// Une las partes de las clases 'partial' (mismo namespace y nombre) en la primera.
void Sema::mergePartials() {
    std::map<std::string, ClassDecl*> first;
    std::vector<ClassDecl*> kept;
    for (ClassDecl* c : prog_.types) {
        if (!c->mods.isPartial || c->isNamespaceScope) {
            kept.push_back(c);
            continue;
        }
        std::string key = c->ns + "." + c->name + (c->isTemplate() ? "<>" : "");
        auto it = first.find(key);
        if (it == first.end()) {
            first[key] = c;
            kept.push_back(c);
            continue;
        }
        ClassDecl* d = it->second;
        if (d->kind != c->kind || c->isTemplate()) {
            diag.error(c->loc, "las partes de '" + c->name + "' deben ser del mismo tipo (class/struct) y no genéricas");
            continue;
        }
        if (c->mods.isStatic) d->mods.isStatic = true;
        if (c->mods.hasAccess && !d->mods.hasAccess) d->mods.access = c->mods.access, d->mods.hasAccess = true;
        for (FieldDecl* f : c->fields) {
            if (!f->file) f->file = c->file;
            d->fields.push_back(f);
        }
        for (MethodDecl* m : c->methods) {
            if (!m->file) m->file = c->file;
            d->methods.push_back(m);
        }
        for (MethodDecl* m : c->ctors) {
            if (!m->file) m->file = c->file;
            d->ctors.push_back(m);
        }
        if (c->dtor) {
            if (d->dtor) diag.error(c->dtor->loc, "'" + c->name + "' ya tiene un destructor en otra parte");
            else {
                if (!c->dtor->file) c->dtor->file = c->file;
                d->dtor = c->dtor;
            }
        }
        for (Attribute& a : c->attrs) d->attrs.push_back(a);
    }
    prog_.types = kept;
}

void Sema::buildNamespaces() {
    mergePartials();
    global_ = new NamespaceSym();
    for (size_t i = 0; i < prog_.types.size(); i++) {
        ClassDecl* c = prog_.types[i];
        NamespaceSym* ns = getNs(c->ns, true);
        c->nsSym = ns;
        std::string prefix = mangleNs(c->ns);
        if (c->isNamespaceScope) {
            c->cname = prefix + "global";
            for (MethodDecl* m : c->methods) {
                m->owner = c;
                if (m->kind != MethodKind::Normal) {
                    diag.error(m->loc, "los operadores y propiedades deben declararse dentro de un tipo");
                    continue;
                }
                ns->funcs[m->name].push_back(m);
            }
            for (FieldDecl* f : c->fields) {
                f->owner = c;
                f->mods.isStatic = true;
                if (ns->globals.count(f->name))
                    diag.error(f->loc, "la variable global '" + f->name + "' ya está definida en '" + ns->display() + "'");
                ns->globals[f->name] = f;
                f->cname = prefix + "g_" + f->name;
            }
            continue;
        }
        if (ns->types.count(c->name)) {
            diag.error(c->loc, "el tipo '" + c->name + "' ya está definido en '" + ns->display() + "'");
            continue;
        }
        if (c->mods.isStatic && c->kind != ClassKind::Class) diag.error(c->loc, "solo las clases pueden ser 'static'");
        ns->types[c->name] = c;
        c->cname = prefix + c->name;
        if (!c->isTemplate()) {
            c->type = new Type(c->kind == ClassKind::Class ? TK::Class : c->kind == ClassKind::Struct ? TK::Struct : TK::Enum);
            c->type->decl = c;
        }
    }
    registerDelegates();
    // Conflictos entre funciones/variables globales y tipos del mismo namespace.
    std::function<void(NamespaceSym*)> checkNs = [&](NamespaceSym* ns) {
        for (auto& [name, fs] : ns->funcs) {
            if (ns->types.count(name)) diag.error(fs[0]->loc, "'" + name + "' ya está definido como tipo en este namespace");
            if (ns->globals.count(name)) diag.error(fs[0]->loc, "'" + name + "' ya está definido como variable global");
        }
        for (auto& [name, f] : ns->globals)
            if (ns->types.count(name)) diag.error(f->loc, "'" + name + "' ya está definido como tipo en este namespace");
        for (auto& [n, child] : ns->children) checkNs(child);
    };
    checkNs(global_);
}

void Sema::resolveUsings(FileScope* f) {
    if (f->resolved) return;
    f->resolved = true;
    auto add = [&](NamespaceSym* ns) {
        if (std::find(f->nsUsings.begin(), f->nsUsings.end(), ns) == f->nsUsings.end()) f->nsUsings.push_back(ns);
    };
    if (NamespaceSym* stdNs = findNs({"std"})) add(stdNs);  // 'using std;' implícito
    for (UsingDirective& u : f->usings) {
        if (!u.alias.empty()) continue;
        NamespaceSym* ns = findNs(u.path);
        if (!ns) diag.error(u.loc, "el namespace '" + join(u.path, ".") + "' no existe (¿falta un módulo o un archivo?)");
        else add(ns);
    }
}

Sym Sema::lookupIn(NamespaceSym* ns, const std::string& name, bool includeChildren) {
    Sym s;
    auto t = ns->types.find(name);
    if (t != ns->types.end()) {
        s.kind = Sym::TypeK;
        s.decl = t->second;
        return s;
    }
    auto dg = ns->delegates.find(name);
    if (dg != ns->delegates.end()) {
        s.kind = Sym::TypeK;
        s.dlg = dg->second;
        return s;
    }
    auto f = ns->funcs.find(name);
    if (f != ns->funcs.end()) {
        s.kind = Sym::Funcs;
        s.funcs = f->second;
        return s;
    }
    auto g = ns->globals.find(name);
    if (g != ns->globals.end()) {
        s.kind = Sym::Global;
        s.global = g->second;
        return s;
    }
    if (includeChildren) {
        auto c = ns->children.find(name);
        if (c != ns->children.end()) {
            s.kind = Sym::Ns;
            s.ns = c->second;
        }
    }
    return s;
}

Sym Sema::lookupUnqualified(const std::string& name, SourceLoc loc) {
    for (NamespaceSym* ns = ctx_.ns; ns; ns = ns->parent) {
        Sym s = lookupIn(ns, name);
        if (s.kind != Sym::None) return s;
    }
    Sym res;
    FileScope* f = ctx_.file;
    if (!f) return res;
    for (UsingDirective& u : f->usings) {
        if (u.alias != name) continue;
        if (u.aliasType->typeArgs.empty() && u.aliasType->ptrDepth == 0 && !u.aliasType->isFuncPtr) {
            if (NamespaceSym* ns = findNs(u.path)) {
                res.kind = Sym::Ns;
                res.ns = ns;
                return res;
            }
            // Alias a un tipo por su ruta completa (también clases estáticas).
            Sym t = lookupIn(global_, u.path[0]);
            for (size_t i = 1; i < u.path.size() && t.kind == Sym::Ns; i++) t = lookupIn(t.ns, u.path[i]);
            if (t.kind == Sym::TypeK && t.decl && !t.decl->isTemplate()) return t;
        }
        res.kind = Sym::TypeK;
        res.type = resolveType(u.aliasType);
        return res;
    }
    for (NamespaceSym* ns : f->nsUsings) {
        Sym s = lookupIn(ns, name, false);
        if (s.kind == Sym::None) continue;
        if (res.kind == Sym::None) {
            res = s;
        } else if (res.kind == Sym::Funcs && s.kind == Sym::Funcs) {
            res.funcs.insert(res.funcs.end(), s.funcs.begin(), s.funcs.end());
        } else {
            diag.error(loc, "'" + name + "' es ambiguo: existe en varios namespaces importados con 'using'");
            return res;
        }
    }
    return res;
}

std::vector<MethodDecl*> Sema::findExtensions(const std::string& name) {
    std::vector<NamespaceSym*> nss;
    for (NamespaceSym* ns = ctx_.ns; ns; ns = ns->parent) nss.push_back(ns);
    if (ctx_.file)
        for (NamespaceSym* ns : ctx_.file->nsUsings)
            if (std::find(nss.begin(), nss.end(), ns) == nss.end()) nss.push_back(ns);
    std::vector<MethodDecl*> out;
    for (NamespaceSym* ns : nss) {
        for (auto& [n, c] : ns->types) {
            if (!c->isStaticClass() || c->isTemplate()) continue;
            for (MethodDecl* m : c->methods)
                if (m->name == name && m->isExtension()) out.push_back(m);
        }
        auto f = ns->funcs.find(name);
        if (f != ns->funcs.end())
            for (MethodDecl* m : f->second)
                if (m->isExtension()) out.push_back(m);
    }
    return out;
}

void Sema::enter(ClassDecl* c, MethodDecl* m) {
    ctx_ = Ctx();
    ctx_.file = m && m->file ? m->file : c->file;
    ctx_.ns = c->nsSym;
    ctx_.cls = c;
    ctx_.method = m;
    ctx_.isStatic = m ? m->isStatic() : true;
    ctx_.scopes.assign(1, {});
}

// ================================================================== tipos y firmas

Type* Sema::typeFromSym(const Sym& s, TypeRef* tr) {
    if (s.dlg) return delegateFromDecl(s.dlg, tr);
    if (s.type) {
        if (!tr->typeArgs.empty()) diag.error(tr->loc, "un alias de tipo no admite argumentos genéricos");
        return s.type;
    }
    ClassDecl* c = s.decl;
    if (c->isTemplate()) {
        if (tr->typeArgs.empty()) {
            diag.error(tr->loc, "el tipo genérico '" + c->name + "' requiere " + std::to_string(c->typeParams.size()) +
                                    " argumento(s) de tipo");
            return tc_.error();
        }
        std::vector<Type*> args;
        for (TypeRef* a : tr->typeArgs) {
            Type* t = resolveType(a);
            if (t->isError()) return t;
            args.push_back(t);
        }
        ClassDecl* inst = instantiate(c, args, tr->loc);
        return inst ? inst->type : tc_.error();
    }
    if (!tr->typeArgs.empty()) {
        diag.error(tr->loc, "'" + c->name + "' no es un tipo genérico");
        return tc_.error();
    }
    return c->type;
}

Type* Sema::resolveType(TypeRef* tr, bool allowVoid) {
    if (tr->isTuple || tr->nullable) return resolveSugarType(tr, allowVoid);  // (int, string), T? (Sugar.cpp)
    Type* base = nullptr;
    if (tr->isFuncPtr) {
        std::vector<Type*> params;
        for (size_t i = 0; i + 1 < tr->typeArgs.size(); i++) params.push_back(resolveType(tr->typeArgs[i]));
        Type* ret = resolveType(tr->typeArgs.back(), true);
        for (Type* p : params)
            if (p->isError()) return p;
        if (ret->isError()) return ret;
        base = tc_.funcPtr(params, ret);
    } else if (tr->parts.size() == 1 && tr->typeArgs.empty()) {
        base = tc_.fromKeyword(tr->parts[0]);
        if (!base && ctx_.method) {
            auto it = ctx_.method->typeArgMap.find(tr->parts[0]);
            if (it != ctx_.method->typeArgMap.end()) base = it->second;
        }
        if (!base && ctx_.cls) {
            auto it = ctx_.cls->typeArgMap.find(tr->parts[0]);
            if (it != ctx_.cls->typeArgMap.end()) base = it->second;
        }
    }
    if (!base && std::find(tr->parts.begin(), tr->parts.end(), std::string(kCompletionMarker)) != tr->parts.end()) {
        completionRequested = true;
        std::vector<std::string> prefix(tr->parts.begin(), std::find(tr->parts.begin(), tr->parts.end(),
                                                                       std::string(kCompletionMarker)));
        completeTypes(prefix);
        return tc_.error();
    }
    if (!base) {
        if (tr->isVar()) {
            diag.error(tr->loc, "'" + tr->parts[0] + "' solo puede usarse en variables locales con inicializador");
            return tc_.error();
        }
        Sym s = lookupUnqualified(tr->parts[0], tr->loc);
        for (size_t i = 1; i < tr->parts.size() && s.kind == Sym::Ns; i++) s = lookupIn(s.ns, tr->parts[i]);
        if (s.kind != Sym::TypeK) {
            if (Type* d = builtinDelegateType(tr)) {  // Func<...> / Action<...>
                if (d->isError()) return d;
                for (int i = 0; i < tr->ptrDepth; i++) d = tc_.pointerTo(d);
                if (tr->ptrDepth > 0 && !unsafeCtx()) unsafeError(tr->loc, "el tipo puntero '" + tr->str() + "'");
                return d;
            }
            diag.error(tr->loc, "no se encontró el tipo '" + tr->str() + "'");
            return tc_.error();
        }
        if (s.decl && s.decl->isStaticClass()) {
            diag.error(tr->loc, "no se puede usar la clase estática '" + s.decl->name + "' como tipo");
            return tc_.error();
        }
        base = typeFromSym(s, tr);
        if (base->isError()) return base;
        if (ideMode && s.decl) {
            int len = 0;
            for (size_t i = 0; i < tr->parts.size(); i++) len += (int)tr->parts[i].size() + (i ? 1 : 0);
            addRef(tr->loc, len, typeDescription(s.decl), &s.decl->loc);
        }
    }
    if (base->isVoid() && tr->ptrDepth == 0 && !allowVoid) {
        diag.error(tr->loc, "'void' solo es válido como tipo de retorno o como puntero (void*)");
        return tc_.error();
    }
    if (tr->ptrDepth > 0 && !unsafeCtx())
        unsafeError(tr->loc, "el tipo puntero '" + tr->str() + "'");
    for (int i = 0; i < tr->ptrDepth; i++) base = tc_.pointerTo(base);
    return base;
}

void Sema::resolveMethodSignature(MethodDecl* m) {
    if (m->signatureDone) return;
    m->signatureDone = true;
    if (m->kind == MethodKind::Ctor || m->kind == MethodKind::Dtor) m->ret = tc_.get(TK::Void);
    else m->ret = resolveType(m->retRef, true);
    if (m->retIsRef() && m->ret->isVoid()) diag.error(m->loc, "no se puede devolver 'void&'");
    std::set<std::string> names;
    for (Param& p : m->params) {
        p.type = resolveType(p.tref);
        if (!names.insert(p.name).second) diag.error(p.loc, "el parámetro '" + p.name + "' está duplicado");
    }
    if (m->variadic && !m->mods.isExtern) diag.error(m->loc, "solo los métodos 'extern' pueden ser variádicos (...)");
    checkParamsSignature(m);  // 'params' (Sugar.cpp)
}

void Sema::resolveClassSignatures(ClassDecl* c) {
    if (c->signaturesDone || c->isTemplate()) return;
    c->signaturesDone = true;
    CtxSave save(*this);
    enter(c, nullptr);

    if (c->kind == ClassKind::Enum) {
        int64_t next = 0;
        std::set<std::string> seen;
        for (EnumMember& m : c->enumMembers) {
            if (!seen.insert(m.name).second) diag.error(m.loc, "el enum '" + c->name + "' ya contiene '" + m.name + "'");
            if (m.value) {
                int64_t v;
                if (!constEval(m.value, v)) {
                    diag.error(m.value->loc, "el valor de un miembro de enum debe ser una constante entera");
                    v = next;
                } else if (!fits(v, tc_.get(TK::Int))) {
                    diag.error(m.value->loc, "el valor del miembro de enum no cabe en 'int'");
                }
                m.val = v;
            } else {
                m.val = next;
            }
            next = m.val + 1;
        }
        return;
    }

    std::set<std::string> fieldNames;
    for (FieldDecl* f : c->fields) {
        f->owner = c;
        ctx_.file = f->file ? f->file : c->file;
        ctx_.field = f;
        f->type = resolveType(f->tref);
        ctx_.field = nullptr;
        ctx_.file = c->file;
        if (ideMode && !c->templateOf && f->type) addRef(f->loc, (int)f->name.size(), describeField(f), &f->loc);
        if (f->tref->isRef) diag.error(f->loc, "los campos no pueden ser referencias (T&); usa un puntero");
        if (f->isEvent) checkEventField(f);
        if (!fieldNames.insert(f->name).second)
            diag.error(f->loc, "'" + c->displayName + "' ya contiene una definición para '" + f->name + "'");
        if (f->mods.isConst && !f->init) diag.error(f->loc, "un campo 'const' requiere un valor");
        if (f->mods.isExtern) diag.error(f->loc, "los campos no pueden ser 'extern'");
        if (c->isNamespaceScope) continue;
        if (c->isStaticClass() && !f->isStatic())
            diag.error(f->loc, "las clases estáticas solo pueden tener miembros estáticos");
        f->cname = f->isStatic() ? c->cname + "__s_" + f->name : "f_" + f->name;
    }

    std::map<std::string, std::vector<MethodDecl*>> byName;
    for (MethodDecl* m : c->methods) {
        m->owner = c;
        if (!m->isTemplate()) {
            ctx_.method = m;
            ctx_.file = m->file ? m->file : c->file;
            resolveMethodSignature(m);
            ctx_.file = c->file;
            ctx_.method = nullptr;
        }
        if (fieldNames.count(m->name)) diag.error(m->loc, "'" + c->displayName + "' ya contiene un campo '" + m->name + "'");
        byName[m->name].push_back(m);
        if (m->mods.isExtern) {
            if (!m->isStatic()) diag.error(m->loc, "los métodos 'extern' deben ser 'static'");
            if (m->body) diag.error(m->loc, "un método 'extern' no puede tener cuerpo");
            if (m->isTemplate()) diag.error(m->loc, "un método 'extern' no puede ser genérico");
        } else if (!m->body) {
            diag.error(m->loc, "el método '" + m->name + "' debe tener cuerpo (o ser 'extern')");
        }
        if (!c->isNamespaceScope && c->isStaticClass() && !m->isStatic())
            diag.error(m->loc, "las clases estáticas solo pueden tener miembros estáticos");
        if (m->isExtension() && !m->isStatic()) diag.error(m->loc, "los métodos de extensión deben ser 'static'");
        if (m->kind == MethodKind::Getter && !m->params.empty())
            diag.error(m->loc, "una propiedad no puede tener parámetros");
        if (m->kind == MethodKind::Operator) {
            bool index = m->name == "operator[]";
            if (index) {
                if (m->isStatic() || m->params.size() != 1)
                    diag.error(m->loc, "'operator[]' debe ser un método de instancia con un parámetro");
            } else {
                bool unaryOk = m->name == "operator-" || m->name == "operator+" || m->name == "operator!" ||
                               m->name == "operator~";
                bool binaryOk = m->name != "operator!" && m->name != "operator~";
                size_t n = m->params.size();
                if (!m->isStatic() || !((n == 1 && unaryOk) || (n == 2 && binaryOk)))
                    diag.error(m->loc, "'" + m->name + "' debe ser 'static' y tener " +
                                           (unaryOk && !binaryOk ? "1 parámetro" : unaryOk ? "1 o 2 parámetros" : "2 parámetros"));
            }
        }
    }
    if (!c->isNamespaceScope) {
        for (auto& [name, group] : byName) {
            for (size_t i = 0; i < group.size(); i++) {
                MethodDecl* m = group[i];
                if (m->mods.isExtern) m->cname = m->name;
                else m->cname = c->cname + "__m_" + mangleName(name) + (group.size() > 1 ? "_" + std::to_string(i) : "");
                for (Attribute& a : m->attrs) {
                    if (a.name != "Export") continue;
                    if (a.args.size() != 1) diag.error(a.loc, "[Export] requiere un nombre: [Export(\"simbolo\")]");
                    else m->cname = a.args[0];
                    if (!m->isStatic()) diag.error(a.loc, "[Export] solo se puede aplicar a métodos 'static'");
                }
                if (m->isTemplate()) continue;
                for (size_t j = 0; j < i; j++) {
                    MethodDecl* o = group[j];
                    if (o->isTemplate() || o->params.size() != m->params.size()) continue;
                    bool same = true;
                    for (size_t k = 0; k < m->params.size(); k++) same &= o->params[k].type == m->params[k].type;
                    if (same) diag.error(m->loc, "ya existe un método '" + name + "' con los mismos tipos de parámetros");
                }
            }
        }
    }
    for (MethodDecl* m : c->methods)
        for (Attribute& a : m->attrs)
            if (a.name != "Export" && a.name != "TrackCaller") diag.error(a.loc, "atributo desconocido '" + a.name + "'");

    for (size_t i = 0; i < c->ctors.size(); i++) {
        MethodDecl* m = c->ctors[i];
        m->owner = c;
        ctx_.method = m;
        if (m->file) ctx_.file = m->file;
        resolveMethodSignature(m);
        ctx_.file = c->file;
        ctx_.method = nullptr;
        m->cname = c->cname + "__ctor" + std::to_string(i);
        if (m->trackCaller) diag.error(m->loc, "[TrackCaller] no se puede aplicar a constructores");
        if (c->isStaticClass() || m->isStatic())
            diag.error(m->loc, "los constructores estáticos y de clases estáticas no están soportados");
    }
    if (c->dtor) {
        c->dtor->owner = c;
        resolveMethodSignature(c->dtor);
        c->dtor->cname = c->cname + "__dtor";
        if (c->isStaticClass()) diag.error(c->dtor->loc, "una clase estática no puede tener destructor");
    }
}

// Nombres en C de las funciones globales (agrupadas por namespace, entre todos los archivos).
void Sema::assignFunctionNames() {
    std::function<void(NamespaceSym*)> visit = [&](NamespaceSym* ns) {
        for (auto& [name, group] : ns->funcs) {
            for (size_t i = 0; i < group.size(); i++) {
                MethodDecl* m = group[i];
                if (m->mods.isExtern) m->cname = m->name;
                else m->cname = mangleNs(ns->name) + "f_" + name + (group.size() > 1 ? "_" + std::to_string(i) : "");
                for (Attribute& a : m->attrs)
                    if (a.name == "Export" && a.args.size() == 1) m->cname = a.args[0];
                if (m->isTemplate()) continue;
                for (size_t j = 0; j < i; j++) {
                    MethodDecl* o = group[j];
                    if (o->isTemplate() || o->params.size() != m->params.size()) continue;
                    bool same = true;
                    for (size_t k = 0; k < m->params.size(); k++) same &= o->params[k].type == m->params[k].type;
                    if (same && !(m->mods.isExtern && o->mods.isExtern))
                        diag.error(m->loc, "ya existe una función '" + name + "' con los mismos tipos de parámetros");
                }
            }
        }
        for (auto& [n, child] : ns->children) visit(child);
    };
    visit(global_);
}

ClassDecl* Sema::instantiate(ClassDecl* tmpl, const std::vector<Type*>& args, SourceLoc loc) {
    if (args.size() != tmpl->typeParams.size()) {
        diag.error(loc, "'" + tmpl->name + "' requiere " + std::to_string(tmpl->typeParams.size()) +
                            " argumento(s) de tipo, no " + std::to_string(args.size()));
        return nullptr;
    }
    std::string key = typeKey(args);
    auto it = tmpl->instances.find(key);
    if (it != tmpl->instances.end()) return it->second;
    if (instDepth_ > 40) {
        diag.error(loc, "instanciación de plantillas demasiado profunda (¿recursión infinita en '" + tmpl->name + "'?)");
        return nullptr;
    }
    ClassDecl* c = Parser::reparseType(tmpl, prog_);
    if (!c) return nullptr;
    c->templateOf = tmpl;
    c->typeArgs = args;
    std::string disp = tmpl->name + "<";
    for (size_t i = 0; i < args.size(); i++) {
        c->typeArgMap[tmpl->typeParams[i]] = args[i];
        disp += (i ? ", " : "") + args[i]->str();
    }
    c->displayName = disp + ">";
    c->file = tmpl->file;
    c->ns = tmpl->ns;
    c->nsSym = tmpl->nsSym;
    if (tmpl->unsafeCtx && !c->unsafeCtx) {  // 'memory_unsafe namespace' alrededor de la plantilla
        c->unsafeCtx = true;
        for (FieldDecl* f : c->fields) f->unsafeCtx = true;
        for (MethodDecl* m : c->methods) m->unsafeBody = true;
        for (MethodDecl* m : c->ctors) m->unsafeBody = true;
        if (c->dtor) c->dtor->unsafeBody = true;
    }
    c->cname = tmpl->cname + "_" + std::to_string(++instCounter_);
    c->type = new Type(c->kind == ClassKind::Class ? TK::Class : TK::Struct);
    c->type->decl = c;
    tmpl->instances[key] = c;
    prog_.types.push_back(c);

    instDepth_++;
    resolveClassSignatures(c);
    instDepth_--;
    // Igual que en C++: los métodos se comprueban solo cuando se usan.
    for (FieldDecl* f : c->fields)
        if (f->init) fieldWork_.push_back({c, f});
    useMethod(c->dtor);
    return c;
}

MethodDecl* Sema::instantiateMethod(MethodDecl* tmpl, const std::vector<Type*>& args, SourceLoc loc) {
    (void)loc;
    if (args.size() != tmpl->typeParams.size()) return nullptr;
    std::string key = typeKey(args);
    auto it = tmpl->instances.find(key);
    if (it != tmpl->instances.end()) return it->second;
    MethodDecl* m = Parser::reparseMethod(tmpl, prog_);
    if (!m) return nullptr;
    m->templateOf = tmpl;
    m->owner = tmpl->owner;
    m->unsafeBody = m->unsafeBody || tmpl->unsafeBody;
    m->unsafeApi = tmpl->unsafeApi;
    for (size_t i = 0; i < args.size(); i++) m->typeArgMap[tmpl->typeParams[i]] = args[i];
    m->cname = tmpl->cname + "_g" + std::to_string(++instCounter_);
    tmpl->instances[key] = m;
    {
        CtxSave save(*this);
        enter(m->owner, m);
        resolveMethodSignature(m);
    }
    genericMethods.push_back(m);
    return m;
}

bool Sema::unify(TypeRef* p, Type* a, MethodDecl* tmpl, std::map<std::string, Type*>& b) {
    if (!a || a->isError() || a->is(TK::Null) || a->isPending()) return true;
    if (a->isDelegate() && p->ptrDepth == 0 && !p->isFuncPtr) return unifyDelegate(p, a, tmpl, b);
    if (p->isTuple || p->nullable) return sugarUnify(p, a, tmpl, b);  // (T, U), T? (Sugar.cpp)
    Type* t = a;
    for (int i = 0; i < p->ptrDepth; i++) {
        if (!t->isPointer()) return true;
        t = t->elem;
    }
    if (p->isFuncPtr) {
        if (!t->isFuncPtr() || t->params.size() + 1 != p->typeArgs.size()) return true;
        for (size_t i = 0; i < p->typeArgs.size(); i++)
            unify(p->typeArgs[i], i < t->params.size() ? t->params[i] : t->ret, tmpl, b);
        return true;
    }
    if (p->parts.size() == 1 && p->typeArgs.empty() &&
        std::find(tmpl->typeParams.begin(), tmpl->typeParams.end(), p->parts[0]) != tmpl->typeParams.end()) {
        if (!b.count(p->parts[0])) b[p->parts[0]] = t;
        return true;
    }
    if (!p->typeArgs.empty() && t->isAggregate() && t->decl->templateOf &&
        t->decl->templateOf->name == p->parts.back() && t->decl->typeArgs.size() == p->typeArgs.size()) {
        for (size_t i = 0; i < p->typeArgs.size(); i++) unify(p->typeArgs[i], t->decl->typeArgs[i], tmpl, b);
    }
    return true;
}

bool Sema::inferTypeArgs(MethodDecl* tmpl, const std::vector<Expr*>& args, const std::vector<TypeRef*>& explicitArgs,
                         std::vector<Type*>& out) {
    out.clear();
    if (!explicitArgs.empty()) {
        if (explicitArgs.size() != tmpl->typeParams.size()) return false;
        for (TypeRef* r : explicitArgs) {
            Type* t = resolveType(r);
            if (t->isError()) return false;
            out.push_back(t);
        }
        return true;
    }
    std::map<std::string, Type*> b;
    size_t n = std::min(tmpl->params.size(), args.size());
    for (size_t i = 0; i < n; i++)
        if (!unify(tmpl->params[i].tref, args[i]->type, tmpl, b)) return false;
    inferFromLambdas(tmpl, args, b);  // tipos de retorno de lambdas y grupos de métodos
    inferParamsTypeArgs(tmpl, args, b);  // params List<T> con argumentos sueltos (Sugar.cpp)
    for (const std::string& name : tmpl->typeParams) {
        auto it = b.find(name);
        if (it == b.end()) return false;
        out.push_back(it->second);
    }
    return true;
}

void Sema::useMethod(MethodDecl* m, const SourceLoc* at) {
    if (m && at && !m->hasUsedAt) {
        m->hasUsedAt = true;
        m->usedAt = *at;
        m->usedBy = ctx_.method;
    }
    if (!m || m->queued || m->isTemplate() || !m->body) return;
    m->queued = true;
    work_.push_back(m);
}

void Sema::processWork() {
    size_t fi = 0, wi = 0;
    while (fi < fieldWork_.size() || wi < work_.size()) {
        while (fi < fieldWork_.size()) {
            auto [c, f] = fieldWork_[fi++];
            CtxSave save(*this);
            enter(c, nullptr);
            if (f->file) ctx_.file = f->file;
            ctx_.field = f;
            checkOperand(f->init);
            coerce(f->init, f->type);
            if (f->isStatic()) staticInits.push_back(f);
        }
        while (wi < work_.size()) {
            MethodDecl* m = work_[wi++];
            CtxSave save(*this);
            int before = diag.errorCount;
            checkMethod(m);
            // Como en C++: cadena de "requerido desde aquí" hasta el código del usuario.
            int depth = 0;
            for (MethodDecl* cur = diag.errorCount > before ? m : nullptr;
                 cur && cur->hasUsedAt && (cur->templateOf || cur->owner->templateOf) && depth < 10;
                 cur = cur->usedBy, depth++) {
                std::string name = cur->owner->isNamespaceScope ? cur->name : cur->owner->displayName + "." + cur->name;
                if (cur->templateOf) {
                    name += "<";
                    for (size_t i = 0; i < cur->templateOf->typeParams.size(); i++)
                        name += (i ? ", " : "") + cur->typeArgMap[cur->templateOf->typeParams[i]]->str();
                    name += ">";
                }
                diag.note(cur->usedAt, "requerido por '" + name + "', usado aquí");
            }
            if (fi < fieldWork_.size()) break;
        }
    }
}

void Sema::orderStructs() {
    std::map<ClassDecl*, int> state;
    std::function<void(ClassDecl*)> visit = [&](ClassDecl* c) {
        if (state[c] == 2) return;
        if (state[c] == 1) {
            diag.error(c->loc, "el struct '" + c->displayName + "' se contiene a sí mismo por valor (usa un puntero)");
            return;
        }
        state[c] = 1;
        for (FieldDecl* f : c->fields)
            if (!f->isStatic() && f->type && f->type->isStruct()) visit(f->type->decl);
        state[c] = 2;
        structOrder.push_back(c);
    };
    for (ClassDecl* c : prog_.types)
        if (c->hasLayout()) visit(c);
}

void Sema::findEntry() {
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate() || c->templateOf) continue;
        for (MethodDecl* m : c->methods) {
            bool named = m->name == "Main" || (c->isNamespaceScope && m->name == "main");
            if (!named || !m->isStatic() || m->mods.isExtern || m->kind != MethodKind::Normal || m->isTemplate())
                continue;
            bool retOk = m->ret->isVoid() || m->ret->is(TK::Int);
            bool paramsOk = m->params.empty() ||
                            (m->params.size() == 2 && m->params[0].type->is(TK::Int) &&
                             m->params[1].type == tc_.pointerTo(tc_.pointerTo(tc_.get(TK::Byte))));
            if (!retOk || !paramsOk) {
                diag.error(m->loc, "el punto de entrada debe ser 'void|int " + m->name + "()' o 'void|int " + m->name +
                                       "(int argc, byte** argv)'");
                continue;
            }
            if (entry) {
                diag.error(m->loc, "hay más de un punto de entrada ('" + entry->name + "' ya está definido)");
                continue;
            }
            entry = m;
        }
    }
}

// ================================================================== métodos y ámbitos

VarInfo* Sema::lookupLocal(const std::string& name) {
    for (auto it = ctx_.scopes.rbegin(); it != ctx_.scopes.rend(); ++it) {
        auto f = it->find(name);
        if (f != it->end()) return f->second;
    }
    return nullptr;
}

VarInfo* Sema::declareLocal(const std::string& name, Type* t, SourceLoc loc, const std::string& prefix) {
    if (lookupLocal(name))
        diag.error(loc, "ya existe una variable local o parámetro llamado '" + name + "' en este ámbito");
    auto* v = new VarInfo();
    v->name = name;
    v->cname = prefix + name;
    v->type = t;
    v->loc = loc;
    v->fnDepth = (int)lambdaStack_.size();
    v->excDepth = ctx_.excTryDepth;
    ctx_.scopes.back()[name] = v;
    return v;
}

void Sema::checkMethod(MethodDecl* m) {
    enter(m->owner, m);
    for (Param& p : m->params) {
        p.var = declareLocal(p.name, p.type, p.loc, "p_");
        p.var->isRef = p.isRef();
    }
    if (ideMode && m->kind == MethodKind::Normal) addRef(m->loc, (int)m->name.size(), methodSignature(m), &m->loc);
    m->checked = true;
    if (!m->body) return;
    for (Stmt* s : m->body->stmts) checkStmt(s);
    if ((m->kind == MethodKind::Normal || m->kind == MethodKind::Getter || m->kind == MethodKind::Operator) &&
        !m->ret->isVoid() && !m->ret->isError() && !alwaysReturns(m->body))
        diag.error(m->loc, "no todas las rutas de código devuelven un valor en '" + m->name + "'");
}

// ================================================================== sentencias

void Sema::checkCondition(Expr*& e) {
    checkValue(e);
    coerce(e, tc_.get(TK::Bool));
}

void Sema::checkStmt(Stmt* s) {
    if (checkSugarStmt(s)) return;  // foreach, deconstrucción, using, switch con patrones (Sugar.cpp)
    switch (s->kind) {
        case SK::Empty: break;
        case SK::Block: {
            auto* b = static_cast<BlockStmt*>(s);
            ctx_.scopes.emplace_back();
            if (b->memoryUnsafe) ctx_.unsafeDepth++;
            for (Stmt* c : b->stmts) checkStmt(c);
            if (b->memoryUnsafe) ctx_.unsafeDepth--;
            ctx_.scopes.pop_back();
            break;
        }
        case SK::VarDecl: {
            auto* d = static_cast<VarDeclStmt*>(s);
            bool isVar = d->tref->isVar();
            bool isRef = d->tref->isRef;
            Type* declared = isVar ? nullptr : resolveType(d->tref);
            if (isVar && d->decls.size() > 1) diag.error(d->loc, "'var'/'auto' no admite múltiples declaradores");
            for (auto& dc : d->decls) {
                Type* t = declared;
                if (dc.init) {
                    Type* it = checkOperand(dc.init);
                    if (isVar && it->isPending()) it = naturalType(dc.init);  // var f = (int x) => x * 2;
                    if (isVar) {
                        if (it->is(TK::Null)) diag.error(dc.loc, std::string("no se puede inferir el tipo de ") + (isDefaultLiteral(dc.init) ? "'default'" : "'null'"));
                        else if (it->isVoid()) diag.error(dc.loc, "no se puede asignar 'void' a una variable");
                        t = it->is(TK::Null) || it->isVoid() ? tc_.error() : it;
                    } else if (isRef) {
                        if (it != t && !it->isError() && !t->isError())
                            diag.error(dc.loc, "una referencia '" + t->str() + "&' debe enlazarse a un valor del mismo tipo");
                    } else {
                        coerce(dc.init, t);
                    }
                    if (isRef && !isLValue(dc.init))
                        diag.error(dc.loc, "una referencia debe enlazarse a una variable, campo o elemento");
                } else if (isVar || isRef) {
                    diag.error(dc.loc, isRef ? "una referencia debe inicializarse" : "una variable 'var' debe inicializarse");
                    if (!t) t = tc_.error();
                }
                if (d->isConst && !dc.init) diag.error(dc.loc, "una constante local requiere un valor");
                dc.var = declareLocal(dc.name, t, dc.loc, "l_");
                dc.var->isRef = isRef;
                if (d->isConst) dc.var->isConst = true;
                if (ideMode && t) addRef(dc.loc, (int)dc.name.size(), describeVar(dc.var), &dc.loc);
                if (d->isConst) {
                    dc.var->isConst = true;
                    dc.var->constInit = dc.init;
                }
            }
            break;
        }
        case SK::ExprStmt: {
            auto* es = static_cast<ExprStmt*>(s);
            check(es->expr);
            if (es->expr->vk != ValKind::Value) checkValue(es->expr);
            else if (!isAssignOrCallLike(es->expr))
                diag.error(es->loc,
                           "solo las asignaciones, llamadas, incrementos, decrementos y 'new' pueden usarse como instrucción");
            break;
        }
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            checkCondition(is->cond);
            checkStmt(is->then);
            if (is->els) checkStmt(is->els);
            break;
        }
        case SK::While: {
            auto* ws = static_cast<WhileStmt*>(s);
            checkCondition(ws->cond);
            ctx_.loopDepth++;
            checkStmt(ws->body);
            ctx_.loopDepth--;
            break;
        }
        case SK::DoWhile: {
            auto* ds = static_cast<DoWhileStmt*>(s);
            ctx_.loopDepth++;
            checkStmt(ds->body);
            ctx_.loopDepth--;
            checkCondition(ds->cond);
            break;
        }
        case SK::For: {
            auto* fs = static_cast<ForStmt*>(s);
            ctx_.scopes.emplace_back();
            if (fs->initDecl) checkStmt(fs->initDecl);
            for (Expr* e : fs->initExprs) {
                checkValue(e);
                if (!isAssignOrCallLike(e)) diag.error(e->loc, "expresión no válida en la inicialización de 'for'");
            }
            if (fs->cond) checkCondition(fs->cond);
            for (Expr* e : fs->iter) {
                checkValue(e);
                if (!isAssignOrCallLike(e)) diag.error(e->loc, "expresión no válida en la iteración de 'for'");
            }
            ctx_.loopDepth++;
            checkStmt(fs->body);
            ctx_.loopDepth--;
            ctx_.scopes.pop_back();
            break;
        }
        case SK::Break:
            if (ctx_.loopDepth == 0 && ctx_.switchDepth == 0) diag.error(s->loc, "'break' fuera de un bucle o 'switch'");
            else excCheckJump(s);
            break;
        case SK::Continue:
            if (ctx_.loopDepth == 0) diag.error(s->loc, "'continue' fuera de un bucle");
            else excCheckJump(s);
            break;
        case SK::Return: {
            auto* rs = static_cast<ReturnStmt*>(s);
            excCheckJump(s);
            if (lambdaReturn(rs)) break;  // 'return' dentro del cuerpo de una lambda
            MethodDecl* m = ctx_.method;
            Type* ret = m ? m->ret : tc_.get(TK::Void);
            if (ret->isVoid()) {
                if (rs->value) {
                    checkValue(rs->value);
                    diag.error(rs->loc, "un método 'void' no puede devolver un valor");
                }
            } else if (!rs->value) {
                diag.error(rs->loc, "se requiere un valor de retorno de tipo '" + ret->str() + "'");
            } else if (m->retIsRef()) {
                Type* t = checkValue(rs->value);
                if (t != ret && !t->isError()) {
                    diag.error(rs->loc, "se debe devolver una referencia a '" + ret->str() + "'");
                } else if (!isLValue(rs->value)) {
                    diag.error(rs->loc, "solo se puede devolver por referencia una variable, campo o elemento");
                } else if (std::string local = localRefRoot(rs->value); !local.empty()) {
                    diag.error(rs->loc, "no se puede devolver una referencia a la variable local '" + local +
                                            "' (dejaría de existir al salir del método)");
                }
            } else {
                checkOperand(rs->value);
                coerce(rs->value, ret);
            }
            break;
        }
        case SK::Switch: {
            auto* ss = static_cast<SwitchStmt*>(s);
            Type* st = ss->subject->type ? ss->subject->type : checkValue(ss->subject);  // ya comprobado en Sugar.cpp
            if (!st->isError() && !st->isIntegral() && !st->isEnum())
                diag.error(ss->subject->loc, "'switch' solo admite tipos enteros, 'char' y enums (no '" + st->str() + "')");
            std::set<int64_t> seen;
            bool hasDefault = false;
            ctx_.switchDepth++;
            ctx_.scopes.emplace_back();
            for (auto& sec : ss->sections) {
                if (sec.hasDefault) {
                    if (hasDefault) diag.error(ss->loc, "el 'switch' ya tiene una etiqueta 'default'");
                    hasDefault = true;
                }
                for (Expr*& lbl : sec.labels) {
                    checkValue(lbl);
                    coerce(lbl, st);
                    int64_t v = 0;
                    if (!constEval(lbl, v)) diag.error(lbl->loc, "se esperaba un valor constante en 'case'");
                    else if (!seen.insert(v).second) diag.error(lbl->loc, "etiqueta 'case' duplicada");
                    sec.values.push_back(v);
                }
                for (Stmt* b : sec.body) checkStmt(b);
                if (!sectionEnds(sec.body))
                    diag.error(ss->loc, "el control no puede pasar de una etiqueta 'case' a otra (falta 'break')");
            }
            ctx_.scopes.pop_back();
            ctx_.switchDepth--;
            break;
        }
        case SK::Delete: {
            auto* ds = static_cast<DeleteStmt*>(s);
            Type* t = checkValue(ds->expr);
            if (!t->isError() && !t->isPointer() && !t->isClass())
                diag.error(ds->loc, "'delete' requiere un puntero o una referencia a clase (no '" + t->str() + "')");
            ClassDecl* target = t->isClass() ? t->decl : (t->isPointer() && t->elem->isStruct()) ? t->elem->decl : nullptr;
            if (target && !ds->isArray) useMethod(target->dtor);
            break;
        }
        case SK::Try: checkTry(static_cast<TryStmt*>(s)); break;
        case SK::Throw: checkThrow(static_cast<ThrowStmt*>(s)); break;
        default: break;  // SK del azúcar: Sugar.cpp
    }
}

bool Sema::containsBreak(Stmt* s) {
    if (!s) return false;
    switch (s->kind) {
        case SK::Break: return true;
        case SK::Block:
            for (Stmt* c : static_cast<BlockStmt*>(s)->stmts)
                if (containsBreak(c)) return true;
            return false;
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            return containsBreak(is->then) || containsBreak(is->els);
        }
        case SK::Try: return excContainsBreak(static_cast<TryStmt*>(s));
        default: return false;
    }
}

bool Sema::alwaysReturns(Stmt* s) {
    if (!s) return false;
    switch (s->kind) {
        case SK::Return: return true;
        case SK::Throw: return true;
        case SK::Try: return excAlwaysReturns(static_cast<TryStmt*>(s));
        case SK::Block:
            for (Stmt* c : static_cast<BlockStmt*>(s)->stmts)
                if (alwaysReturns(c)) return true;
            return false;
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            return is->els && alwaysReturns(is->then) && alwaysReturns(is->els);
        }
        case SK::While: {
            auto* ws = static_cast<WhileStmt*>(s);
            return isConstTrue(ws->cond) && !containsBreak(ws->body);
        }
        case SK::For: {
            auto* fs = static_cast<ForStmt*>(s);
            return (!fs->cond || isConstTrue(fs->cond)) && !containsBreak(fs->body);
        }
        case SK::DoWhile: {
            auto* ds = static_cast<DoWhileStmt*>(s);
            return alwaysReturns(ds->body) || (isConstTrue(ds->cond) && !containsBreak(ds->body));
        }
        case SK::Switch: {
            auto* ss = static_cast<SwitchStmt*>(s);
            bool hasDefault = false;
            for (auto& sec : ss->sections) {
                hasDefault |= sec.hasDefault;
                bool ret = false;
                for (Stmt* b : sec.body) {
                    if (containsBreak(b)) break;
                    if (alwaysReturns(b)) {
                        ret = true;
                        break;
                    }
                }
                if (!ret) return false;
            }
            return hasDefault;
        }
        default: return false;
    }
}

bool Sema::sectionEnds(const std::vector<Stmt*>& body) {
    if (body.empty()) return false;
    Stmt* last = body.back();
    switch (last->kind) {
        case SK::Break: case SK::Continue: case SK::Return: case SK::Throw: return true;
        case SK::Block: return sectionEnds(static_cast<BlockStmt*>(last)->stmts) || alwaysReturns(last);
        default: return alwaysReturns(last);
    }
}

// ================================================================== conversiones

bool Sema::implicitNumeric(Type* from, Type* to) {
    TK f = from->kind, t = to->kind;
    switch (f) {
        case TK::SByte: return t == TK::Short || t == TK::Int || t == TK::Long || t == TK::Float || t == TK::Double;
        case TK::Byte:
            return t == TK::Short || t == TK::UShort || t == TK::Int || t == TK::UInt || t == TK::Long ||
                   t == TK::ULong || t == TK::Float || t == TK::Double;
        case TK::Short: return t == TK::Int || t == TK::Long || t == TK::Float || t == TK::Double;
        case TK::UShort:
            return t == TK::Int || t == TK::UInt || t == TK::Long || t == TK::ULong || t == TK::Float || t == TK::Double;
        case TK::Int: return t == TK::Long || t == TK::Float || t == TK::Double;
        case TK::UInt: return t == TK::Long || t == TK::ULong || t == TK::Float || t == TK::Double;
        case TK::Long: case TK::ULong: return t == TK::Float || t == TK::Double;
        case TK::Char:
            return t == TK::Int || t == TK::UInt || t == TK::Long || t == TK::ULong || t == TK::Float || t == TK::Double;
        case TK::Float: return t == TK::Double;
        default: return false;
    }
}

bool Sema::canImplicit(Expr* e, Type* from, Type* to) {
    if (from == to || from->isError() || to->isError()) return true;
    if (from->isPending()) return e && pendingCost(e, to) >= 0;
    if (int r = sugarImplicit(e, from, to); r >= 0) return r == 1;  // T?, tuplas, 'default' (Sugar.cpp)
    if (from->is(TK::Null)) return to->isPointer() || to->isClass() || to->isFuncPtr() || to->isDelegate();
    if (to->isVoidPointer() && from->isPointer()) return true;
    if (from->isNumeric() && to->isNumeric() && implicitNumeric(from, to)) return true;
    if (from->isClass() && to->isClass() && excIsSubclass(from->decl, to->decl)) return true;  // excepción -> su base
    int64_t v;
    if (e && from->is(TK::Int) && to->isIntegral() && !to->is(TK::Char) && constEval(e, v) && fits(v, to)) return true;
    if (e && to->isEnum() && e->kind == EK::IntLit && static_cast<IntLitExpr*>(e)->value == 0) return true;
    return false;
}

bool Sema::canExplicit(Type* from, Type* to) {
    if (canImplicit(nullptr, from, to)) return true;
    bool fNum = from->isNumeric() || from->isEnum(), tNum = to->isNumeric() || to->isEnum();
    if (fNum && tNum) return true;
    auto ptrLike = [](Type* t) { return t->isPointer() || t->isClass() || t->isFuncPtr(); };
    if (ptrLike(from) && ptrLike(to)) return true;  // reinterpretación, como reinterpret_cast
    if (from->isPointer() && to->isIntegral()) return true;
    if (from->isIntegral() && to->isPointer()) return true;
    return false;
}

int Sema::convCost(Expr* e, Type* to) {
    Type* from = e->type;
    if (from == to) return 0;
    if (from->isPending()) return pendingCost(e, to);
    if (!canImplicit(e, from, to)) return -1;
    if (from->isNumeric() && to->isNumeric()) {
        // Una constante que se estrecha (p. ej. 42 -> byte) es peor que cualquier ensanchamiento.
        if (!implicitNumeric(from, to)) return 30 + numRank(from->kind) - numRank(to->kind);
        int c = 2 * (numRank(to->kind) - numRank(from->kind)) + (to->isUnsignedInt() ? 1 : 0) + 1;
        return std::max(c, 1);
    }
    return 1;
}

void Sema::coerce(Expr*& e, Type* to) {
    Type* from = e->type;
    if (!from || from == to || from->isError() || to->isError()) return;
    if (from->isPending()) {  // lambda o grupo de métodos -> delegado
        convertPending(e, to);
        return;
    }
    if (sugarCoerce(e, to)) return;  // T?, tuplas, 'default' (Sugar.cpp)
    if (!canImplicit(e, from, to)) {
        std::string msg = "no se puede convertir implícitamente el tipo '" + from->str() + "' en '" + to->str() + "'";
        if (canExplicit(from, to)) msg += " (existe una conversión explícita; ¿falta un cast?)";
        diag.error(e->loc, msg);
        return;
    }
    auto* c = new CastExpr(e->loc);
    c->operand = e;
    c->implicit = true;
    c->type = to;
    e = c;
}

Type* Sema::unaryPromote(Type* t) {
    switch (t->kind) {
        case TK::SByte: case TK::Byte: case TK::Short: case TK::UShort: case TK::Char: return tc_.get(TK::Int);
        default: return t;
    }
}

Type* Sema::numericPromote(Expr* a, Expr* b) {
    TK A = a->type->kind, B = b->type->kind;
    if (A == TK::Double || B == TK::Double) return tc_.get(TK::Double);
    if (A == TK::Float || B == TK::Float) return tc_.get(TK::Float);
    auto nonNegConst = [&](Expr* e) {
        int64_t v;
        return e->type->is(TK::Int) && constEval(e, v) && v >= 0;
    };
    if (A == TK::ULong || B == TK::ULong) {
        Expr* other = A == TK::ULong ? b : a;
        if (other->type->isSignedInt() && !nonNegConst(other)) return nullptr;
        return tc_.get(TK::ULong);
    }
    if (A == TK::Long || B == TK::Long) return tc_.get(TK::Long);
    if (A == TK::UInt || B == TK::UInt) {
        Expr* other = A == TK::UInt ? b : a;
        if (other->type->isSignedInt() && !nonNegConst(other)) return tc_.get(TK::Long);
        return tc_.get(TK::UInt);
    }
    return tc_.get(TK::Int);
}

bool Sema::isConstTarget(Expr* e) {
    if (e->kind == EK::Name) {
        auto* n = static_cast<NameExpr*>(e);
        return (n->var && n->var->isConst) || (n->field && n->field->mods.isConst);
    }
    if (e->kind == EK::Member) {
        auto* m = static_cast<MemberExpr*>(e);
        return m->field && m->field->mods.isConst;
    }
    return false;
}

bool Sema::isLValue(Expr* e) {
    excNoteWrite(e);  // se va a modificar (o a enlazar por referencia): ¿debe ser 'volatile'?
    switch (e->kind) {
        case EK::Name: {
            auto r = static_cast<NameExpr*>(e)->ref;
            return r == NameExpr::Ref::Local || r == NameExpr::Ref::Field || r == NameExpr::Ref::StaticField;
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref == MemberExpr::Ref::StaticField) return true;
            if (m->ref != MemberExpr::Ref::Field) return false;
            if (m->arrow || m->obj->type->isClass()) return true;
            return isLValue(m->obj);
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            if (ix->opMethod) return ix->opMethod->retIsRef();
            return ix->obj->type && ix->obj->type->isPointer();
        }
        case EK::Call: {
            auto* c = static_cast<CallExpr*>(e);
            return c->target && c->target->retIsRef();
        }
        case EK::Unary: return static_cast<UnaryExpr*>(e)->op == "*";
        case EK::This: return ctx_.cls && ctx_.cls->kind == ClassKind::Struct;
        default: return false;
    }
}

bool Sema::constEval(Expr* e, int64_t& out, int depth) {
    if (!e || depth > 32) return false;
    switch (e->kind) {
        case EK::IntLit: {
            auto* l = static_cast<IntLitExpr*>(e);
            if (l->value > (uint64_t)INT64_MAX) return false;
            out = (int64_t)l->value;
            return true;
        }
        case EK::CharLit: out = static_cast<CharLitExpr*>(e)->value; return true;
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            int64_t v;
            if (u->opMethod) return false;
            if (u->op == "-" && u->operand->kind == EK::IntLit &&
                static_cast<IntLitExpr*>(u->operand)->value == (uint64_t)INT64_MAX + 1) {
                out = INT64_MIN;
                return true;
            }
            if (!constEval(u->operand, v, depth + 1)) return false;
            if (u->op == "-") out = (int64_t)(0ull - (uint64_t)v);
            else if (u->op == "+") out = v;
            else if (u->op == "~") out = ~v;
            else return false;
            if (e->type && e->type->isIntegral()) out = truncTo(out, e->type);
            return true;
        }
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            int64_t x, y;
            if (b->opMethod) return false;
            if (!constEval(b->lhs, x, depth + 1) || !constEval(b->rhs, y, depth + 1)) return false;
            uint64_t ux = (uint64_t)x, uy = (uint64_t)y;
            const std::string& op = b->op;
            if (op == "+") out = (int64_t)(ux + uy);
            else if (op == "-") out = (int64_t)(ux - uy);
            else if (op == "*") out = (int64_t)(ux * uy);
            else if (op == "/" || op == "%") {
                if (y == 0 || (x == INT64_MIN && y == -1)) return false;
                out = op == "/" ? x / y : x % y;
            } else if (op == "<<") out = (int64_t)(ux << (y & 63));
            else if (op == ">>") out = x >> (y & 63);
            else if (op == "&") out = x & y;
            else if (op == "|") out = x | y;
            else if (op == "^") out = x ^ y;
            else return false;
            if (e->type && e->type->isIntegral()) out = truncTo(out, e->type);
            return true;
        }
        case EK::Cast: {
            auto* c = static_cast<CastExpr*>(e);
            int64_t v;
            if (!c->type || !(c->type->isIntegral() || c->type->isEnum())) return false;
            if (!constEval(c->operand, v, depth + 1)) return false;
            out = truncTo(v, c->type);
            return true;
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref == MemberExpr::Ref::EnumConst || m->ref == MemberExpr::Ref::ConstInt) {
                out = (int64_t)m->constBits;
                return true;
            }
            if (m->field && m->field->mods.isConst) return constEval(m->field->init, out, depth + 1);
            return false;
        }
        case EK::Name: {
            auto* n = static_cast<NameExpr*>(e);
            if (n->var && n->var->isConst) return constEval(n->var->constInit, out, depth + 1);
            if (n->field && n->field->mods.isConst) return constEval(n->field->init, out, depth + 1);
            return false;
        }
        default: return false;
    }
}

// ================================================================== expresiones

Type* Sema::check(Expr* e) {
    Type* t = checkInner(e);
    e->type = t ? t : tc_.error();
    if (e->type->isPointer() && e->vk == ValKind::Value && !unsafeCtx()) pointerExprError(e);
    return e->type;
}

// ================================================================== seguridad de memoria
//
// Fuera de un contexto memory_unsafe no puede aparecer ningún puntero: ni en tipos
// (variables, campos, parámetros, conversiones, argumentos genéricos) ni como valor de una
// expresión. Así, las API que reciben o devuelven punteros solo se pueden usar desde código
// memory_unsafe, sin necesidad de marcarlas una a una. Además, llamar a funciones 'extern' y a
// métodos marcados 'memory_unsafe' también exige un contexto memory_unsafe.

bool Sema::unsafeCtx() const {
    if (ctx_.unsafeDepth > 0) return true;
    if (ctx_.method && ctx_.method->unsafeBody) return true;
    // La firma de una función 'extern' puede usar punteros: llamarla ya exige memory_unsafe.
    if (ctx_.method && ctx_.method->mods.isExtern) return true;
    if (ctx_.field && ctx_.field->unsafeCtx) return true;
    if (!ctx_.method && !ctx_.field && ctx_.cls && ctx_.cls->unsafeCtx) return true;
    if (ctx_.file && ctx_.file->unsafeCtx) return true;
    // Una instancia genérica con argumentos puntero solo puede pedirla código memory_unsafe
    // (escribir 'List<int*>' ya lo exige): hereda ese contexto.
    if (ctx_.method && ctx_.method->templateOf)
        for (auto& kv : ctx_.method->typeArgMap)
            if (kv.second && kv.second->isPointer()) return true;
    if (ctx_.cls && ctx_.cls->templateOf)
        for (Type* t : ctx_.cls->typeArgs)
            if (t && t->isPointer()) return true;
    return false;
}

void Sema::unsafeError(SourceLoc loc, const std::string& what) {
    if (!unsafeReported_.insert({loc.file, loc.line}).second) return;  // uno por línea
    diag.error(loc, what + " requiere un contexto memory_unsafe (usa 'memory_unsafe { ... }' o marca "
                           "el método o la clase con 'memory_unsafe')");
}

// Llamadas a funciones nativas (extern) o a métodos marcados 'memory_unsafe'.
void Sema::requireSafeCall(MethodDecl* m, SourceLoc loc) {
    if (!m || unsafeCtx()) return;
    std::string name = m->owner && !m->owner->isNamespaceScope ? m->owner->displayName + "." + m->name : m->name;
    if (m->kind == MethodKind::Ctor) name = "el constructor de '" + m->owner->displayName + "'";
    else name = "'" + name + "'";
    if (m->mods.isExtern) unsafeError(loc, "llamar a la función nativa " + name + " (extern)");
    else if (m->unsafeApi) unsafeError(loc, "usar " + name + ", marcado como 'memory_unsafe',");
}

void Sema::pointerExprError(Expr* e) {
    switch (e->kind) {
        case EK::Name:
            // Las variables locales y parámetros puntero ya dieron error en su declaración.
            if (static_cast<NameExpr*>(e)->ref == NameExpr::Ref::Local) return;
            break;
        case EK::Cast:
            if (static_cast<CastExpr*>(e)->implicit) return;
            unsafeError(e->loc, "convertir a un tipo puntero ('" + e->type->str() + "')");
            return;
        case EK::Unary:
            if (static_cast<UnaryExpr*>(e)->op == "&") {
                unsafeError(e->loc, "tomar la dirección de una variable ('&')");
                return;
            }
            break;
        case EK::NewArray: unsafeError(e->loc, "reservar memoria sin procesar con 'new T[n]' (usa List<T>)"); return;
        case EK::Member:
            if (static_cast<MemberExpr*>(e)->ref == MemberExpr::Ref::StrPtr) {
                unsafeError(e->loc, "obtener el puntero de una cadena ('.Ptr')");
                return;
            }
            break;
        default: break;
    }
    unsafeError(e->loc, "usar un valor de tipo puntero ('" + e->type->str() + "')");
}

Type* Sema::checkValue(Expr* e) {
    check(e);
    return requireValue(e);
}

Type* Sema::requireValue(Expr* e) {
    if (e->vk != ValKind::Value) {
        std::string what = e->vk == ValKind::TypeName    ? "'" + e->typeValue->str() + "' es un tipo"
                           : e->vk == ValKind::Namespace ? "'" + e->nsValue->display() + "' es un namespace"
                                                         : "un grupo de métodos";
        diag.error(e->loc, what + " y no es válido en este contexto" +
                               (e->vk == ValKind::MethodGroup ? " (¿faltan paréntesis de llamada?)" : ""));
        e->vk = ValKind::Value;
        e->type = tc_.error();
    }
    return e->type;
}

void Sema::checkAccess(Access a, ClassDecl* owner, const std::string& what, SourceLoc loc) {
    if (a != Access::Private || owner->isNamespaceScope || owner == ctx_.cls) return;
    if (owner->templateOf && ctx_.cls && ctx_.cls->templateOf == owner->templateOf) return;
    diag.error(loc, "'" + owner->displayName + "." + what + "' no es accesible debido a su nivel de protección");
}

Type* Sema::checkInner(Expr* e) {
    if (isSugarExpr(e->kind)) return checkSugar(e);  // Sugar.cpp
    switch (e->kind) {
        case EK::IntLit: {
            auto* l = static_cast<IntLitExpr*>(e);
            uint64_t v = l->value;
            if (l->suffixU && l->suffixL) return tc_.get(TK::ULong);
            if (l->suffixU) return tc_.get(v <= UINT32_MAX ? TK::UInt : TK::ULong);
            if (l->suffixL) return tc_.get(v <= (uint64_t)INT64_MAX ? TK::Long : TK::ULong);
            if (v <= (uint64_t)INT32_MAX) return tc_.get(TK::Int);
            if (v <= UINT32_MAX) return tc_.get(TK::UInt);
            if (v <= (uint64_t)INT64_MAX) return tc_.get(TK::Long);
            return tc_.get(TK::ULong);
        }
        case EK::FloatLit: return tc_.get(static_cast<FloatLitExpr*>(e)->isFloat32 ? TK::Float : TK::Double);
        case EK::BoolLit: return tc_.get(TK::Bool);
        case EK::CharLit: return tc_.get(TK::Char);
        case EK::StringLit: return tc_.get(TK::String);
        case EK::Null: return tc_.get(TK::Null);
        case EK::This:
            if (!ctx_.cls || ctx_.cls->isNamespaceScope || ctx_.isStatic) {
                diag.error(e->loc, "'this' no es válido en un contexto estático");
                return tc_.error();
            }
            noteThisUse(e->loc);
            return ctx_.cls->type;
        case EK::Name: return checkName(static_cast<NameExpr*>(e));
        case EK::Member: return checkMember(static_cast<MemberExpr*>(e));
        case EK::Call: return checkCall(static_cast<CallExpr*>(e));
        case EK::Index: return checkIndex(static_cast<IndexExpr*>(e));
        case EK::Unary: return checkUnary(static_cast<UnaryExpr*>(e));
        case EK::Postfix: {
            auto* pe = static_cast<PostfixExpr*>(e);
            Type* t = checkValue(pe->operand);
            if (t->isError()) return t;
            if (!isLValue(pe->operand) || isConstTarget(pe->operand)) {
                diag.error(pe->loc, "el operando de '" + pe->op + "' debe ser una variable, campo o elemento");
                return tc_.error();
            }
            if (!(t->isNumeric() || (t->isPointer() && !t->isVoidPointer()))) {
                diag.error(pe->loc, "el operador '" + pe->op + "' no se puede aplicar a '" + t->str() + "'");
                return tc_.error();
            }
            if (t->isPointer() && !unsafeCtx()) unsafeError(pe->loc, "la aritmética de punteros ('" + pe->op + "')");
            return t;
        }
        case EK::Binary: return checkBinary(static_cast<BinaryExpr*>(e));
        case EK::Assign: return checkAssign(static_cast<AssignExpr*>(e));
        case EK::Cond: return checkCond(static_cast<CondExpr*>(e));
        case EK::Cast: {
            auto* c = static_cast<CastExpr*>(e);
            if (c->implicit) return c->type;
            Type* to = resolveType(c->tref);
            Type* from = checkOperand(c->operand);
            if (to->isError() || from->isError()) return tc_.error();
            if (from->isPending()) {  // (Func<int, int>)(x => x + 1)
                coerce(c->operand, to);
                return to;
            }
            if (!canExplicit(from, to)) {
                diag.error(c->loc, "no se puede convertir el tipo '" + from->str() + "' en '" + to->str() + "'");
                return tc_.error();
            }
            auto refLike = [](Type* t) { return t->isPointer() || t->isClass() || t->isFuncPtr(); };
            if (from != to && (refLike(from) || refLike(to)) && !canImplicit(c->operand, from, to) && !unsafeCtx())
                unsafeError(c->loc, "reinterpretar '" + from->str() + "' como '" + to->str() + "'");
            return to;
        }
        case EK::New: return checkNew(static_cast<NewExpr*>(e));
        case EK::NewArray: {
            auto* na = static_cast<NewArrayExpr*>(e);
            Type* elem = resolveType(na->elemRef);
            Type* ct = checkValue(na->count);
            if (elem->isError() || ct->isError()) return tc_.error();
            if (!ct->isIntegral()) {
                diag.error(na->count->loc, "el tamaño del arreglo debe ser un entero");
                return tc_.error();
            }
            if (!ct->is(TK::ULong)) coerce(na->count, tc_.get(TK::Long));
            return tc_.pointerTo(elem);
        }
        case EK::SizeOf: {
            auto* so = static_cast<SizeOfExpr*>(e);
            so->target = resolveType(so->tref);
            return tc_.get(TK::Int);
        }
        case EK::Default:  // sin tipo: literal 'default', toma el tipo del destino (sugarCoerce)
            if (!static_cast<DefaultExpr*>(e)->tref) return tc_.get(TK::Null);
            return resolveType(static_cast<DefaultExpr*>(e)->tref);
        case EK::Lambda: case EK::DelegateConv: return checkLambdaExpr(e);
        default: break;  // EK del azúcar: Sugar.cpp
    }
    return tc_.error();
}

// Convierte un símbolo encontrado por nombre en el significado de la expresión.
Type* Sema::fromSym(Expr* e, const Sym& s, const std::vector<TypeRef*>& typeArgs) {
    switch (s.kind) {
        case Sym::Ns:
            e->vk = ValKind::Namespace;
            e->nsValue = s.ns;
            return tc_.get(TK::Void);
        case Sym::TypeK: {
            TypeRef tr;
            tr.loc = e->loc;
            tr.typeArgs = typeArgs;
            if (s.decl) tr.parts = {s.decl->name};
            Type* t = typeFromSym(s, &tr);
            if (t->isError()) return t;
            e->vk = ValKind::TypeName;
            e->typeValue = t;
            return t;
        }
        case Sym::Funcs:
            e->vk = ValKind::MethodGroup;
            e->group = s.funcs;
            return tc_.get(TK::Void);
        default: return tc_.error();
    }
}


// 'set' de la misma propiedad (mismo nombre y mismo carácter estático) o nullptr.
MethodDecl* Sema::FindSetter(MethodDecl* getter) {
    for (MethodDecl* m : getter->owner->methods)
        if (m->kind == MethodKind::Setter && m->name == getter->name && m->isStatic() == getter->isStatic()) return m;
    return nullptr;
}

// Registra el significado de un nombre ya resuelto (hover / ir a la definición).
static void describeExpr(Expr* e, Type* t, std::string& hover, SourceLoc& def, bool& hasDef) {
    hasDef = false;
    if (e->vk == ValKind::Namespace) {
        hover = "namespace " + e->nsValue->name;
        return;
    }
    if (e->vk == ValKind::TypeName) {
        Type* tv = e->typeValue;
        if (tv->decl) {
            hover = Sema::typeDescription(tv->decl);
            def = tv->decl->loc;
            hasDef = true;
        } else {
            hover = tv->str();
        }
        return;
    }
    if (e->vk == ValKind::MethodGroup) {
        MethodDecl* m = e->group.front();
        hover = Sema::methodSignature(m);
        if (e->group.size() > 1) hover += "  (+" + std::to_string(e->group.size() - 1) + " sobrecarga(s))";
        def = m->loc;
        hasDef = true;
        return;
    }
    if (e->kind == EK::Name) {
        auto* n = static_cast<NameExpr*>(e);
        if (n->var) {
            hover = describeVar(n->var);
            def = n->var->loc;
            hasDef = true;
        } else if (n->getter) {
            hover = "(propiedad) " + Sema::methodSignature(n->getter);
            def = n->getter->loc;
            hasDef = true;
        } else if (n->field) {
            hover = describeField(n->field);
            def = n->field->loc;
            hasDef = true;
        }
        return;
    }
    if (e->kind == EK::Member) {
        auto* m = static_cast<MemberExpr*>(e);
        switch (m->ref) {
            case MemberExpr::Ref::Field:
            case MemberExpr::Ref::StaticField:
                hover = describeField(m->field);
                def = m->field->loc;
                hasDef = true;
                break;
            case MemberExpr::Ref::Property:
                hover = "(propiedad) " + Sema::methodSignature(m->getter);
                def = m->getter->loc;
                hasDef = true;
                break;
            case MemberExpr::Ref::EnumConst:
                hover = t->str() + "." + m->name + " = " + std::to_string((int64_t)m->constBits);
                if (t->decl) {
                    for (EnumMember& em : t->decl->enumMembers)
                        if (em.name == m->name) {
                            def = em.loc;
                            hasDef = true;
                        }
                }
                break;
            case MemberExpr::Ref::ConstInt: hover = "const " + t->str() + " " + t->str() + "." + m->name; break;
            case MemberExpr::Ref::StrLength: hover = "(propiedad) int string.Length"; break;
            case MemberExpr::Ref::StrPtr: hover = "(propiedad) byte* string.Ptr"; break;
            default: break;
        }
    }
}

Type* Sema::checkName(NameExpr* e) {
    if (e->name == kCompletionMarker) {
        completionRequested = true;
        completeScope();
        return tc_.error();
    }
    Type* t = checkNameImpl(e);
    if (ideMode && !t->isError()) {
        std::string hover;
        SourceLoc def;
        bool hasDef;
        describeExpr(e, t, hover, def, hasDef);
        if (!hover.empty()) addRef(e->loc, (int)e->name.size(), hover, hasDef ? &def : nullptr);
    }
    return t;
}

Type* Sema::checkMember(MemberExpr* e) {
    if (e->name == kCompletionMarker) {
        completionRequested = true;
        Type* ot = check(e->obj);
        completeMembers(e->obj, e->arrow, ot);
        return tc_.error();
    }
    Type* t = checkMemberImpl(e);
    if (ideMode && !t->isError()) {
        std::string hover;
        SourceLoc def;
        bool hasDef;
        describeExpr(e, t, hover, def, hasDef);
        if (!hover.empty()) addRef(e->nameLoc, (int)e->name.size(), hover, hasDef ? &def : nullptr);
    }
    return t;
}

Type* Sema::checkNameImpl(NameExpr* e) {
    if (VarInfo* v = lookupLocal(e->name)) {
        e->ref = NameExpr::Ref::Local;
        e->var = v;
        noteLocalUse(v, e->loc);  // ¿variable capturada por una lambda?
        return v->type;
    }
    ClassDecl* cls = ctx_.cls;
    if (cls && !cls->isNamespaceScope) {
        for (FieldDecl* f : cls->fields) {
            if (f->name != e->name) continue;
            e->field = f;
            if (f->isStatic()) {
                e->ref = NameExpr::Ref::StaticField;
            } else {
                if (ctx_.isStatic) {
                    diag.error(e->loc, "se requiere una referencia de objeto para el campo no estático '" +
                                           cls->displayName + "." + f->name + "'");
                    return tc_.error();
                }
                e->ref = NameExpr::Ref::Field;
                noteThisUse(e->loc);
            }
            return f->type;
        }
        for (MethodDecl* m : cls->methods) {
            if (m->kind != MethodKind::Getter || m->name != e->name) continue;
            if (!m->isStatic() && ctx_.isStatic) {
                diag.error(e->loc, "se requiere una referencia de objeto para la propiedad '" + m->name + "'");
                return tc_.error();
            }
            e->ref = NameExpr::Ref::Property;
            e->getter = m;
            e->setter = FindSetter(m);
            if (!m->isStatic()) noteThisUse(e->loc);
            requireSafeCall(m, e->loc);
            useMethod(m, &e->loc);
            return m->ret;
        }
        for (MethodDecl* m : cls->methods)
            if (m->kind == MethodKind::Normal && m->name == e->name) e->group.push_back(m);
        if (!e->group.empty()) {
            e->vk = ValKind::MethodGroup;
            return tc_.get(TK::Void);
        }
    }
    if (e->typeArgs.empty()) {
        Type* gen = nullptr;
        if (ctx_.method && ctx_.method->typeArgMap.count(e->name)) gen = ctx_.method->typeArgMap[e->name];
        else if (cls && cls->typeArgMap.count(e->name)) gen = cls->typeArgMap[e->name];
        else gen = tc_.fromKeyword(e->name);
        if (gen) {
            e->vk = ValKind::TypeName;
            e->typeValue = gen;
            return gen;
        }
    }
    Sym s = lookupUnqualified(e->name, e->loc);
    if (s.kind == Sym::Global) {
        e->ref = NameExpr::Ref::StaticField;
        e->field = s.global;
        return s.global->type;
    }
    if (s.kind != Sym::None) return fromSym(e, s, e->typeArgs);
    diag.error(e->loc, "el nombre '" + e->name + "' no existe en el contexto actual");
    return tc_.error();
}

Type* Sema::checkMemberImpl(MemberExpr* e) {
    bool isCallee = e == calleeExpr_;
    // Regla "Color Color" de C#: en 'Anchor.Left', si 'Anchor' es a la vez un campo de la clase y
    // el nombre de su tipo enum, se trata como el tipo.
    if (e->obj->kind == EK::Name && ctx_.cls) {
        auto* n = static_cast<NameExpr*>(e->obj);
        Type* same = nullptr;
        if (n->typeArgs.empty() && !lookupLocal(n->name)) {
            for (FieldDecl* f : ctx_.cls->fields)
                if (f->name == n->name && f->type && f->type->is(TK::Enum) && f->type->decl->name == n->name) same = f->type;
            for (MethodDecl* m : ctx_.cls->methods)
                if (m->kind == MethodKind::Getter && m->name == n->name && m->ret && m->ret->is(TK::Enum) && m->ret->decl->name == n->name)
                    same = m->ret;
        }
        if (same) {
            n->vk = ValKind::TypeName;
            n->typeValue = same;
            n->type = same;
        }
    }
    Type* ot = e->obj->vk == ValKind::TypeName && e->obj->typeValue ? e->obj->typeValue : check(e->obj);
    if (ot->isError()) return ot;
    Expr* obj = e->obj;

    if (obj->vk == ValKind::Namespace) {
        Sym s = lookupIn(obj->nsValue, e->name);
        if (s.kind == Sym::Global) {
            e->ref = MemberExpr::Ref::StaticField;
            e->field = s.global;
            return s.global->type;
        }
        if (s.kind != Sym::None) return fromSym(e, s, e->typeArgs);
        diag.error(e->loc, "'" + e->name + "' no existe en el namespace '" + obj->nsValue->display() + "'");
        return tc_.error();
    }

    if (obj->vk == ValKind::MethodGroup) {
        diag.error(e->loc, "no se puede acceder a un miembro de un grupo de métodos");
        return tc_.error();
    }

    if (obj->vk == ValKind::TypeName) {
        Type* T = obj->typeValue;
        if (T->isIntegral() && (e->name == "MaxValue" || e->name == "MinValue")) {
            bool mx = e->name == "MaxValue";
            uint64_t bits = 0;
            switch (T->kind) {
                case TK::SByte: bits = mx ? INT8_MAX : (uint64_t)(int64_t)INT8_MIN; break;
                case TK::Byte: bits = mx ? UINT8_MAX : 0; break;
                case TK::Short: bits = mx ? INT16_MAX : (uint64_t)(int64_t)INT16_MIN; break;
                case TK::UShort: bits = mx ? UINT16_MAX : 0; break;
                case TK::Char: bits = mx ? 0x10FFFF : 0; break;
                case TK::Int: bits = mx ? INT32_MAX : (uint64_t)(int64_t)INT32_MIN; break;
                case TK::UInt: bits = mx ? UINT32_MAX : 0; break;
                case TK::Long: bits = mx ? INT64_MAX : (uint64_t)INT64_MIN; break;
                case TK::ULong: bits = mx ? UINT64_MAX : 0; break;
                default: break;
            }
            e->ref = MemberExpr::Ref::ConstInt;
            e->constBits = bits;
            return T;
        }
        if (T->isEnum()) {
            for (EnumMember& m : T->decl->enumMembers) {
                if (m.name == e->name) {
                    e->ref = MemberExpr::Ref::EnumConst;
                    e->constBits = (uint64_t)m.val;
                    return T;
                }
            }
        }
        if (T->isAggregate()) {
            ClassDecl* c = T->decl;
            for (FieldDecl* f : c->fields) {
                if (f->name != e->name) continue;
                if (!f->isStatic()) {
                    diag.error(e->loc, "se requiere una referencia de objeto para el campo no estático '" + c->displayName +
                                           "." + f->name + "'");
                    return tc_.error();
                }
                checkAccess(f->mods.access, c, f->name, e->loc);
                if (f->isEvent && !eventAccessible(f, e)) return tc_.error();
                e->ref = MemberExpr::Ref::StaticField;
                e->field = f;
                return f->type;
            }
            for (MethodDecl* m : c->methods) {
                if (m->kind != MethodKind::Getter || m->name != e->name) continue;
                if (!m->isStatic()) {
                    diag.error(e->loc, "se requiere una referencia de objeto para la propiedad '" + m->name + "'");
                    return tc_.error();
                }
                checkAccess(m->mods.access, c, m->name, e->loc);
                e->ref = MemberExpr::Ref::Property;
                e->getter = m;
                e->setter = FindSetter(m);
                requireSafeCall(m, e->loc);
                useMethod(m, &e->loc);
                return m->ret;
            }
            for (MethodDecl* m : c->methods)
                if (m->kind == MethodKind::Normal && m->name == e->name) e->group.push_back(m);
            if (!e->group.empty()) {
                e->vk = ValKind::MethodGroup;
                return tc_.get(TK::Void);
            }
        }
        if (Type* r = primitiveStaticMember(e, T)) return r;  // int.Parse, char.IsDigit... (Exceptions.cpp)
        diag.error(e->loc, "'" + T->str() + "' no contiene una definición para '" + e->name + "'");
        return tc_.error();
    }

    // Acceso sobre un valor.
    Type* base = ot;
    if (e->arrow) {
        if (!ot->isPointer()) {
            diag.error(e->loc, "el operador '->' requiere un puntero (el tipo es '" + ot->str() + "'); usa '.'");
            return tc_.error();
        }
        if (!unsafeCtx()) unsafeError(e->loc, "acceder a un miembro a través de un puntero ('->')");
        base = ot->elem;
    } else if (ot->isPointer()) {
        diag.error(e->loc, "usa '->' para acceder a miembros a través de un puntero ('" + ot->str() + "')");
        return tc_.error();
    }
    if (base->isDelegate() && e->name == "Invoke") {  // f.Invoke(x) equivale a f(x)
        e->ref = MemberExpr::Ref::DelegateInvoke;
        return base;
    }
    if (base->is(TK::String)) {
        if (e->name == "Length") {
            e->ref = MemberExpr::Ref::StrLength;
            return tc_.get(TK::Int);
        }
        if (e->name == "Ptr") {
            e->ref = MemberExpr::Ref::StrPtr;
            return tc_.pointerTo(tc_.get(TK::Byte));
        }
    }
    if (Type* t = sugarMember(e, base)) return t;  // t.nombre en tuplas con nombre (Sugar.cpp)
    if (base->isAggregate()) {
        ClassDecl* c = base->decl;
        for (FieldDecl* f : c->fields) {
            if (f->name != e->name) continue;
            if (f->isStatic()) {
                diag.error(e->loc, "el miembro estático '" + c->displayName + "." + f->name +
                                       "' no se puede usar con una referencia de instancia; califícalo con el nombre del tipo");
                return tc_.error();
            }
            checkAccess(f->mods.access, c, f->name, e->loc);
            if (f->isEvent && !eventAccessible(f, e)) return tc_.error();
            e->ref = MemberExpr::Ref::Field;
            e->field = f;
            return f->type;
        }
        for (MethodDecl* m : c->methods) {
            if (m->kind != MethodKind::Getter || m->name != e->name) continue;
            if (isCallee && hasCallableNamed(c, e->name)) continue;  // l.Count(x => ...) frente a l.Count
            if (m->isStatic()) {
                diag.error(e->loc, "la propiedad estática '" + m->name + "' debe usarse con el nombre del tipo");
                return tc_.error();
            }
            checkAccess(m->mods.access, c, m->name, e->loc);
            e->ref = MemberExpr::Ref::Property;
            e->getter = m;
            e->setter = FindSetter(m);
            requireSafeCall(m, e->loc);
            useMethod(m, &e->loc);
            return m->ret;
        }
        for (MethodDecl* m : c->methods)
            if (m->kind == MethodKind::Normal && m->name == e->name) e->group.push_back(m);
        if (!e->group.empty()) {
            e->vk = ValKind::MethodGroup;
            return tc_.get(TK::Void);
        }
    }
    if (!e->arrow) {
        std::vector<MethodDecl*> ext = findExtensions(e->name);
        if (!ext.empty()) {
            e->vk = ValKind::MethodGroup;
            e->group = ext;
            e->extension = true;
            return tc_.get(TK::Void);
        }
    }
    diag.error(e->loc, "'" + base->str() + "' no contiene una definición para '" + e->name + "'");
    return tc_.error();
}

MethodDecl* Sema::resolveOverload(const std::vector<MethodDecl*>& cands, std::vector<Expr*>& args, SourceLoc loc,
                                  const std::string& what, const std::vector<TypeRef*>& typeArgs, bool report) {
    for (Expr* a : args)
        if (a->type->isError()) return nullptr;
    struct Cand {
        MethodDecl* m;
        int cost;
        bool generic;
    };
    std::vector<Cand> viable;
    for (MethodDecl* m0 : cands) {
        MethodDecl* m = m0;
        bool generic = false;
        if (m0->isTemplate()) {
            std::vector<Type*> ta;
            if (!inferTypeArgs(m0, args, typeArgs, ta)) continue;
            m = instantiateMethod(m0, ta, loc);
            if (!m) continue;
            generic = true;
        } else if (!typeArgs.empty()) {
            continue;
        }
        if (paramsMethod(m)) {  // forma normal o expandida de 'params' (Sugar.cpp)
            int c = paramsCost(m, args);
            if (c >= 0) viable.push_back({m, c, generic});
            continue;
        }
        size_t n = m->params.size();
        if (args.size() < n || (args.size() > n && !m->variadic)) continue;
        int cost = 0;
        bool ok = true;
        for (size_t i = 0; i < n && ok; i++) {
            Param& p = m->params[i];
            if (!p.type || p.type->isError()) {
                ok = false;
            } else if (p.isRef()) {
                ok = args[i]->type == p.type && isLValue(args[i]) && !isConstTarget(args[i]);
            } else {
                int c = convCost(args[i], p.type);
                if (c < 0) ok = false;
                else cost += c;
            }
        }
        if (ok) viable.push_back({m, cost, generic});
    }
    if (viable.empty()) {
        if (report) diag.error(loc, "ninguna sobrecarga de '" + what + "' acepta los argumentos " + typeList(args));
        return nullptr;
    }
    std::stable_sort(viable.begin(), viable.end(), [](const Cand& a, const Cand& b) {
        return a.cost != b.cost ? a.cost < b.cost : (!a.generic && b.generic);
    });
    if (viable.size() > 1 && viable[0].cost == viable[1].cost && viable[0].generic == viable[1].generic &&
        viable[0].m != viable[1].m) {
        if (report) diag.error(loc, "la llamada a '" + what + "' es ambigua para los argumentos " + typeList(args));
        return nullptr;
    }
    return viable[0].m;
}

void Sema::coerceArgs(MethodDecl* m, std::vector<Expr*>& args) {
    if (paramsMethod(m)) packParams(m, args);  // argumentos de 'params' -> List<T> (Sugar.cpp)
    for (size_t i = 0; i < args.size(); i++) {
        if (i < m->params.size()) {
            if (!m->params[i].isRef()) coerce(args[i], m->params[i].type);
            continue;
        }
        Type* t = args[i]->type;
        if (t->is(TK::Float)) coerce(args[i], tc_.get(TK::Double));
        else if (t->isIntegral() && t->bits() < 32) coerce(args[i], tc_.get(TK::Int));
        else if (t->is(TK::String))
            diag.error(args[i]->loc, "no se puede pasar 'string' a un parámetro variádico; usa 's.Ptr'");
        else if (t->isStruct())
            diag.error(args[i]->loc, "no se puede pasar un struct a un parámetro variádico");
    }
}

std::vector<MethodDecl*> Sema::operatorsFor(Type* a, Type* b, const std::string& name) {
    std::vector<MethodDecl*> out;
    for (Type* t : {a, b}) {
        if (!t || !t->isAggregate()) continue;
        for (MethodDecl* m : t->decl->methods)
            if (m->kind == MethodKind::Operator && m->name == name && std::find(out.begin(), out.end(), m) == out.end())
                out.push_back(m);
    }
    return out;
}

Type* Sema::checkCall(CallExpr* e) {
    calleeExpr_ = e->callee;
    check(e->callee);
    calleeExpr_ = nullptr;
    for (Expr* a : e->args) checkOperand(a);
    Expr* callee = e->callee;
    if (callee->type->isError()) return tc_.error();
    if (callee->vk == ValKind::Value && callee->type->isDelegate()) return checkDelegateCall(e);

    if (callee->vk == ValKind::Value && callee->type->isFuncPtr()) {
        Type* ft = callee->type;
        if (e->args.size() != ft->params.size()) {
            diag.error(e->loc, "el puntero a función espera " + std::to_string(ft->params.size()) + " argumento(s)");
            return tc_.error();
        }
        for (size_t i = 0; i < e->args.size(); i++) coerce(e->args[i], ft->params[i]);
        return ft->ret;
    }
    if (callee->vk != ValKind::MethodGroup) {
        if (callee->vk == ValKind::TypeName)
            diag.error(e->loc, "'" + callee->typeValue->str() + "' es un tipo; para crear una instancia usa 'new'");
        else
            diag.error(e->loc, "la expresión no se puede invocar");
        return tc_.error();
    }
    std::vector<TypeRef*> noArgs;
    std::vector<TypeRef*>* typeArgs = exprTypeArgs(callee);
    bool ext = callee->kind == EK::Member && static_cast<MemberExpr*>(callee)->extension;
    if (ext) e->args.insert(e->args.begin(), static_cast<MemberExpr*>(callee)->obj);

    std::string name = callee->group.front()->name;
    MethodDecl* m = resolveOverload(callee->group, e->args, e->loc, name, typeArgs ? *typeArgs : noArgs);
    if (!m) {
        explainPendingArgs(callee->group, e->args);  // errores dentro de las lambdas pasadas como argumento
        return tc_.error();
    }
    e->target = m;
    checkAccess(m->mods.access, m->owner, m->name, e->loc);
    requireSafeCall(m, e->loc);
    if (ideMode) {
        SourceLoc at = callee->kind == EK::Member ? static_cast<MemberExpr*>(callee)->nameLoc : callee->loc;
        addRef(at, (int)m->name.size(), methodSignature(m), &m->loc);
    }

    if (!ext) {
        if (callee->kind == EK::Name) {
            if (!m->isStatic()) {
                if (ctx_.isStatic) {
                    diag.error(e->loc, "se requiere una referencia de objeto para el método no estático '" +
                                           m->owner->displayName + "." + m->name + "'");
                    return tc_.error();
                }
                e->implicitThis = true;
                noteThisUse(e->loc);
            }
        } else {
            auto* me = static_cast<MemberExpr*>(callee);
            if (me->obj->vk != ValKind::Value) {
                if (!m->isStatic()) {
                    diag.error(e->loc, "se requiere una referencia de objeto para el método no estático '" +
                                           m->owner->displayName + "." + m->name + "'");
                    return tc_.error();
                }
            } else {
                if (m->isStatic()) {
                    diag.error(e->loc, "el método estático '" + m->owner->displayName + "." + m->name +
                                           "' no se puede llamar con una referencia de instancia; califícalo con el nombre del tipo");
                    return tc_.error();
                }
                e->receiver = me->obj;
                e->receiverArrow = me->arrow;
            }
        }
    }
    useMethod(m, &e->loc);
    coerceArgs(m, e->args);
    return m->ret;
}

Type* Sema::checkIndex(IndexExpr* ix) {
    Type* ot = checkValue(ix->obj);
    Type* it = checkValue(ix->index);
    if (ot->isError() || it->isError()) return tc_.error();
    if (ot->isAggregate()) {
        std::vector<MethodDecl*> cands;
        for (MethodDecl* m : ot->decl->methods)
            if (m->kind == MethodKind::Operator && m->name == "operator[]") cands.push_back(m);
        if (cands.empty()) {
            diag.error(ix->loc, "'" + ot->str() + "' no define 'operator[]'");
            return tc_.error();
        }
        std::vector<Expr*> args = {ix->index};
        MethodDecl* m = resolveOverload(cands, args, ix->loc, "operator[]");
        if (!m) return tc_.error();
        checkAccess(m->mods.access, m->owner, m->name, ix->loc);
        requireSafeCall(m, ix->loc);
        ix->opMethod = m;
        useMethod(m, &ix->loc);
        coerceArgs(m, args);
        ix->index = args[0];
        return m->ret;
    }
    if (!it->isIntegral()) {
        diag.error(ix->index->loc, "el índice debe ser un entero (no '" + it->str() + "')");
        return tc_.error();
    }
    if (!it->is(TK::ULong)) coerce(ix->index, tc_.get(TK::Long));
    if (ot->isPointer() && !ot->isVoidPointer()) {
        if (!unsafeCtx()) unsafeError(ix->loc, "indexar un puntero ('p[i]', sin comprobación de límites)");
        return ot->elem;
    }
    if (ot->is(TK::String)) return tc_.get(TK::Byte);
    diag.error(ix->loc, "no se puede aplicar indexación a una expresión de tipo '" + ot->str() + "'");
    return tc_.error();
}

Type* Sema::checkUnary(UnaryExpr* e) {
    const std::string& op = e->op;
    Type* t;
    if (op == "&") {
        check(e->operand);
        if (e->operand->vk == ValKind::MethodGroup) {
            std::vector<TypeRef*>* ta = exprTypeArgs(e->operand);
            std::vector<MethodDecl*> viable;
            for (MethodDecl* m : e->operand->group) {
                MethodDecl* c = m;
                if (m->isTemplate()) {
                    std::vector<Type*> args;
                    std::vector<Expr*> none;
                    if (!ta || ta->empty() || !inferTypeArgs(m, none, *ta, args)) continue;
                    c = instantiateMethod(m, args, e->loc);
                    if (!c) continue;
                } else if (ta && !ta->empty()) {
                    continue;
                }
                bool refParam = false;
                for (Param& p : c->params) refParam |= p.isRef();
                if (c->isStatic() && !c->variadic && !c->retIsRef() && !refParam && !c->trackCaller) viable.push_back(c);
            }
            if (viable.size() != 1) {
                diag.error(e->loc, viable.empty()
                                       ? "solo se puede tomar la dirección de métodos estáticos sin parámetros por "
                                         "referencia (ni [TrackCaller])"
                                       : "la dirección del método es ambigua (está sobrecargado)");
                return tc_.error();
            }
            MethodDecl* m = viable[0];
            e->funcRef = m;
            requireSafeCall(m, e->loc);
            useMethod(m);
            std::vector<Type*> params;
            for (Param& p : m->params) params.push_back(p.type);
            return tc_.funcPtr(params, m->ret);
        }
        t = checkValue(e->operand);
    } else {
        t = checkValue(e->operand);
    }
    if (t->isError()) return t;
    auto bad = [&]() {
        diag.error(e->loc, "el operador '" + op + "' no se puede aplicar a un operando de tipo '" + t->str() + "'");
        return tc_.error();
    };
    if (t->isAggregate() && (op == "-" || op == "+" || op == "!" || op == "~")) {
        std::vector<MethodDecl*> cands;
        for (MethodDecl* m : operatorsFor(t, nullptr, "operator" + op))
            if (m->params.size() == 1) cands.push_back(m);
        if (cands.empty()) return bad();
        std::vector<Expr*> args = {e->operand};
        MethodDecl* m = resolveOverload(cands, args, e->loc, "operator" + op);
        if (!m) return tc_.error();
        requireSafeCall(m, e->loc);
        e->opMethod = m;
        useMethod(m);
        coerceArgs(m, args);
        e->operand = args[0];
        return m->ret;
    }
    if (op == "-" || op == "+") {
        if (op == "-" && e->operand->kind == EK::IntLit) {
            auto* l = static_cast<IntLitExpr*>(e->operand);
            if (!l->suffixU && !l->suffixL && l->value == 2147483648ull) return tc_.get(TK::Int);
            if (!l->suffixU && l->value == 9223372036854775808ull) return tc_.get(TK::Long);
        }
        if (!t->isNumeric()) return bad();
        Type* p = unaryPromote(t);
        if (op == "-" && t->is(TK::UInt)) p = tc_.get(TK::Long);
        if (op == "-" && t->is(TK::ULong)) return bad();
        coerce(e->operand, p);
        return p;
    }
    if (op == "!") {
        if (!t->is(TK::Bool)) return bad();
        return t;
    }
    if (op == "~") {
        if (t->isEnum()) return t;
        if (!t->isIntegral()) return bad();
        Type* p = unaryPromote(t);
        coerce(e->operand, p);
        return p;
    }
    if (op == "++" || op == "--") {
        if (!isLValue(e->operand) || isConstTarget(e->operand)) {
            diag.error(e->loc, "el operando de '" + op + "' debe ser una variable, campo o elemento");
            return tc_.error();
        }
        if (!(t->isNumeric() || (t->isPointer() && !t->isVoidPointer()))) return bad();
        if (t->isPointer() && !unsafeCtx()) unsafeError(e->loc, "la aritmética de punteros ('" + op + "')");
        return t;
    }
    if (op == "*") {
        if (!t->isPointer()) {
            diag.error(e->loc, "solo se pueden desreferenciar punteros (el tipo es '" + t->str() + "')");
            return tc_.error();
        }
        if (t->isVoidPointer()) {
            diag.error(e->loc, "no se puede desreferenciar 'void*'; conviértelo primero a un puntero tipado");
            return tc_.error();
        }
        if (!unsafeCtx()) unsafeError(e->loc, "desreferenciar un puntero ('*')");
        return t->elem;
    }
    if (op == "&") {
        if (!isLValue(e->operand) || isConstTarget(e->operand)) {
            diag.error(e->loc, "solo se puede tomar la dirección de una variable, campo o elemento");
            return tc_.error();
        }
        return tc_.pointerTo(t);
    }
    return bad();
}

// Si una referencia apunta a (una parte de) una variable local o un parámetro por valor,
// devuelve su nombre: esa memoria desaparece al salir del método.
std::string Sema::localRefRoot(Expr* e) {
    switch (e->kind) {
        case EK::Name: {
            auto* n = static_cast<NameExpr*>(e);
            return n->ref == NameExpr::Ref::Local && !n->var->isRef ? n->name : "";
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref != MemberExpr::Ref::Field || m->arrow || !m->obj->type->isStruct()) return "";
            return localRefRoot(m->obj);  // campo de un struct: vive donde vive el struct
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            if (ix->opMethod && ix->obj->type->isStruct()) return localRefRoot(ix->obj);
            return "";
        }
        case EK::Call: {
            // f(ref local) que devuelve T&: puede devolver la misma referencia.
            auto* c = static_cast<CallExpr*>(e);
            if (!c->target || !c->target->retIsRef()) return "";
            if (!c->target->isStatic() && !c->implicitThis && c->receiver && c->receiver->type->isStruct() && !c->receiverArrow) {
                std::string r = localRefRoot(c->receiver);
                if (!r.empty()) return r;
            }
            for (size_t i = 0; i < c->args.size() && i < c->target->params.size(); i++)
                if (c->target->params[i].isRef()) {
                    std::string r = localRefRoot(c->args[i]);
                    if (!r.empty()) return r;
                }
            return "";
        }
        default: return "";
    }
}

Type* Sema::checkBinary(BinaryExpr* e) {
    const std::string& op = e->op;
    Type* boolT = tc_.get(TK::Bool);
    if (op == "&&" || op == "||") {
        checkCondition(e->lhs);
        checkCondition(e->rhs);
        return boolT;
    }
    if (op == "??") return checkCoalesce(e, checkValue(e->lhs));  // a ?? b (Sugar.cpp)
    Type* L = checkValue(e->lhs);
    Type* R = checkValue(e->rhs);
    if (L->isError() || R->isError()) return tc_.error();
    if (Type* t = sugarBinary(e, L, R)) return t;  // T?, tuplas (Sugar.cpp)
    bool eq = op == "==" || op == "!=";
    bool cmp = eq || op == "<" || op == ">" || op == "<=" || op == ">=";
    bool bitwise = op == "&" || op == "|" || op == "^";
    auto bad = [&]() {
        diag.error(e->loc, "el operador '" + op + "' no se puede aplicar a operandos de tipo '" + L->str() + "' y '" +
                               R->str() + "'");
        return tc_.error();
    };

    // Operadores sobrecargados.
    if (L->isAggregate() || R->isAggregate()) {
        std::vector<MethodDecl*> cands;
        for (MethodDecl* m : operatorsFor(L, R, "operator" + op))
            if (m->params.size() == 2) cands.push_back(m);
        bool negate = false;
        if (cands.empty() && op == "!=") {
            for (MethodDecl* m : operatorsFor(L, R, "operator=="))
                if (m->params.size() == 2) cands.push_back(m);
            negate = true;
        }
        if (!cands.empty()) {
            std::vector<Expr*> args = {e->lhs, e->rhs};
            MethodDecl* m = resolveOverload(cands, args, e->loc, "operator" + op);
            if (!m) return tc_.error();
            if (negate && !m->ret->is(TK::Bool)) return bad();
            requireSafeCall(m, e->loc);
            e->opMethod = m;
            e->negate = negate;
            useMethod(m, &e->loc);
            coerceArgs(m, args);
            e->lhs = args[0];
            e->rhs = args[1];
            return negate ? boolT : m->ret;
        }
        if (L->isStruct() || R->isStruct()) {
            diag.error(e->loc, "el operador '" + op + "' no está definido para '" + (L->isStruct() ? L : R)->str() +
                                   "' (declara 'public static ... operator" + op + "(...)')");
            return tc_.error();
        }
    }

    // Concatenación como en C#: "x = " + 5. La memoria la recupera el recolector.
    auto concatable = [this](Type* t) {
        return t->is(TK::String) || t->isNumeric() || t->is(TK::Bool) || t->isEnum() || sugarConcatable(t);
    };
    if (op == "+" && (L->is(TK::String) || R->is(TK::String)) && concatable(L) && concatable(R))
        return tc_.get(TK::String);
    if (L->is(TK::String) && R->is(TK::String)) {
        if (cmp) return boolT;  // == y != comparan contenido; < > <= >= orden lexicográfico
        bad();
        return tc_.error();
    }

    if (L->isRefLike() || R->isRefLike()) {
        if ((op == "+" || op == "-") && (L->isPointer() || R->isPointer()) && !unsafeCtx())
            unsafeError(e->loc, "la aritmética de punteros ('" + op + "')");
        if ((op == "+" || op == "-") && L->isPointer() && R->isIntegral()) {
            if (L->isVoidPointer()) return bad();
            if (!R->is(TK::ULong)) coerce(e->rhs, tc_.get(TK::Long));
            return L;
        }
        if (op == "+" && L->isIntegral() && R->isPointer()) {
            if (R->isVoidPointer()) return bad();
            if (!L->is(TK::ULong)) coerce(e->lhs, tc_.get(TK::Long));
            return R;
        }
        if (op == "-" && L->isPointer() && R->isPointer()) {
            if (L != R || L->isVoidPointer()) return bad();
            return tc_.get(TK::Long);
        }
        if (cmp) {
            if (!eq && (!L->isPointer() || !R->isPointer())) return bad();
            if (L == R) return boolT;
            if (canImplicit(e->rhs, R, L)) coerce(e->rhs, L);
            else if (canImplicit(e->lhs, L, R)) coerce(e->lhs, R);
            else return bad();
            return boolT;
        }
        return bad();
    }

    if (L->is(TK::Bool) && R->is(TK::Bool)) {
        if (eq || bitwise) return boolT;
        return bad();
    }

    if (L->isEnum() || R->isEnum()) {
        if (L != R) return bad();
        if (cmp) return boolT;
        if (bitwise) return L;
        return bad();
    }

    if (L->isNumeric() && R->isNumeric()) {
        if (op == "<<" || op == ">>") {
            if (!L->isIntegral() || !R->isIntegral()) return bad();
            Type* p = unaryPromote(L);
            coerce(e->lhs, p);
            if (!canImplicit(e->rhs, R, tc_.get(TK::Int))) return bad();
            coerce(e->rhs, tc_.get(TK::Int));
            return p;
        }
        Type* p = numericPromote(e->lhs, e->rhs);
        if (!p) {
            diag.error(e->loc, "el operador '" + op + "' es ambiguo entre '" + L->str() + "' y '" + R->str() +
                                   "' (mezcla de 'ulong' con entero con signo)");
            return tc_.error();
        }
        if (bitwise && p->isFloating()) return bad();
        coerce(e->lhs, p);
        coerce(e->rhs, p);
        return cmp ? boolT : p;
    }
    return bad();
}

Type* Sema::checkAssign(AssignExpr* e) {
    eventLhs_ = e->op == "+=" || e->op == "-=" ? e->lhs : nullptr;  // evento += manejador
    if (e->op == "?\?=") return checkCoalesceAssign(e);                      // Sugar.cpp
    if (e->lhs->kind == EK::Tuple) return checkDeconstructAssign(e);         // (a, b) = (b, a)
    Type* L = checkValue(e->lhs);
    eventLhs_ = nullptr;
    Type* R = checkOperand(e->rhs);
    if (L->isError() || R->isError()) return tc_.error();
    if (isConstTarget(e->lhs)) {
        diag.error(e->lhs->loc, "no se puede asignar a una constante");
        return tc_.error();
    }
    MethodDecl* getter = e->lhs->kind == EK::Name ? static_cast<NameExpr*>(e->lhs)->getter
                       : e->lhs->kind == EK::Member ? static_cast<MemberExpr*>(e->lhs)->getter : nullptr;
    if (getter) {
        MethodDecl* setter = e->lhs->kind == EK::Name ? static_cast<NameExpr*>(e->lhs)->setter : static_cast<MemberExpr*>(e->lhs)->setter;
        if (!setter) {
            diag.error(e->lhs->loc, "la propiedad '" + getter->name + "' es de solo lectura (no tiene 'set')");
            return tc_.error();
        }
        if (e->op != "=") {
            diag.error(e->loc, "'" + e->op + "' no se puede usar con propiedades; escribe 'p = p " + e->op.substr(0, e->op.size() - 1) + " valor'");
            return tc_.error();
        }
        checkAccess(setter->mods.access, setter->owner, setter->name, e->loc);
        requireSafeCall(setter, e->loc);
        coerce(e->rhs, L);
        e->setter = setter;
        useMethod(setter, &e->loc);
        return tc_.get(TK::Void);
    }
    if (!isLValue(e->lhs)) {
        diag.error(e->lhs->loc, "el lado izquierdo de una asignación debe ser una variable, campo o elemento indexado");
        return tc_.error();
    }
    if (e->op == "=") {
        coerce(e->rhs, L);
        return L;
    }
    if (L->isDelegate() && delegateAssign(e, L)) return L;  // d += f; d -= f (multicast)
    std::string op = e->op.substr(0, e->op.size() - 1);
    auto bad = [&]() {
        diag.error(e->loc, "el operador '" + e->op + "' no se puede aplicar a operandos de tipo '" + L->str() + "' y '" +
                               R->str() + "'");
        return tc_.error();
    };
    if (op == "+" && L->is(TK::String) &&
        (R->is(TK::String) || R->isNumeric() || R->is(TK::Bool) || R->isEnum() || sugarConcatable(R)))
        return L;  // s += x
    if (L->isAggregate()) {
        std::vector<MethodDecl*> cands;
        for (MethodDecl* m : operatorsFor(L, R, "operator" + op))
            if (m->params.size() == 2) cands.push_back(m);
        if (cands.empty()) return bad();
        std::vector<Expr*> args = {e->lhs, e->rhs};
        MethodDecl* m = resolveOverload(cands, args, e->loc, "operator" + op);
        if (!m) return tc_.error();
        if (m->ret != L) return bad();
        requireSafeCall(m, e->loc);
        e->opMethod = m;
        useMethod(m);
        coerceArgs(m, args);
        e->rhs = args[1];
        return L;
    }
    if (L->isPointer() && (op == "+" || op == "-") && R->isIntegral()) {
        if (L->isVoidPointer()) return bad();
        if (!unsafeCtx()) unsafeError(e->loc, "la aritmética de punteros ('" + e->op + "')");
        if (!R->is(TK::ULong)) coerce(e->rhs, tc_.get(TK::Long));
        return L;
    }
    if (L->is(TK::Bool) && R->is(TK::Bool) && (op == "&" || op == "|" || op == "^")) return L;
    if (L->isEnum() && L == R && (op == "&" || op == "|" || op == "^")) return L;
    if (L->isNumeric() && R->isNumeric()) {
        if (op == "<<" || op == ">>") {
            if (!L->isIntegral() || !R->isIntegral()) return bad();
            coerce(e->rhs, tc_.get(TK::Int));
            return L;
        }
        if ((op == "&" || op == "|" || op == "^") && (L->isFloating() || R->isFloating())) return bad();
        if (!canImplicit(e->rhs, R, L)) return bad();
        return L;
    }
    return bad();
}

Type* Sema::checkCond(CondExpr* e) {
    checkCondition(e->cond);
    Type* A = checkOperand(e->a);
    Type* B = checkOperand(e->b);
    if (A->isError() || B->isError()) return tc_.error();
    if (A == B) return A;
    if (A->isNumeric() && B->isNumeric()) {
        Type* p = numericPromote(e->a, e->b);
        if (p) {
            coerce(e->a, p);
            coerce(e->b, p);
            return p;
        }
    }
    if (canImplicit(e->a, A, B)) {
        coerce(e->a, B);
        return B;
    }
    if (canImplicit(e->b, B, A)) {
        coerce(e->b, A);
        return A;
    }
    diag.error(e->loc, "no hay conversión implícita entre '" + A->str() + "' y '" + B->str() + "' en el operador '?:'");
    return tc_.error();
}

Type* Sema::checkNew(NewExpr* e) {
    Type* T = resolveType(e->tref);
    for (Expr* a : e->args) checkOperand(a);
    if (T->isError()) return T;
    if (!T->isAggregate()) {
        diag.error(e->loc, "'new T(...)' solo es válido para clases y structs; para memoria de '" + T->str() +
                               "' usa 'new " + T->str() + "[n]'");
        return tc_.error();
    }
    ClassDecl* c = T->decl;
    if (c->ctors.empty()) {
        if (!e->args.empty()) {
            diag.error(e->loc, "'" + c->displayName + "' no contiene un constructor que acepte " +
                                   std::to_string(e->args.size()) + " argumento(s)");
            return tc_.error();
        }
        return T;
    }
    if (e->args.empty() && T->isStruct()) {
        bool hasParamless = false;
        for (MethodDecl* m : c->ctors) hasParamless |= m->params.empty();
        if (!hasParamless) return T;
    }
    MethodDecl* m = resolveOverload(c->ctors, e->args, e->loc, c->displayName);
    if (!m) return tc_.error();
    checkAccess(m->mods.access, c, c->name, e->loc);
    requireSafeCall(m, e->loc);
    e->ctor = m;
    useMethod(m, &e->loc);
    coerceArgs(m, e->args);
    return T;
}

// ================================================================== IntelliSense

namespace {
// CompletionItemKind de LSP
enum { kMethod = 2, kFunction = 3, kField = 5, kVariable = 6, kClass = 7, kModule = 9, kProperty = 10,
       kKeyword = 14, kEnum = 13, kConstant = 21, kEnumMember = 20, kStruct = 22, kTypeParam = 25 };

int kindOf(ClassDecl* c) { return c->kind == ClassKind::Struct ? kStruct : c->kind == ClassKind::Enum ? kEnum : kClass; }
}  // namespace

std::string Sema::typeDescription(ClassDecl* c) {
    std::string s = c->isStaticClass() ? "static class " : c->kind == ClassKind::Struct ? "struct "
                    : c->kind == ClassKind::Enum ? "enum " : "class ";
    if (!c->ns.empty()) s += c->ns + ".";
    s += c->displayName;
    if (c->isTemplate()) {
        s += "<";
        for (size_t i = 0; i < c->typeParams.size(); i++) s += (i ? ", " : "") + c->typeParams[i];
        s += ">";
    }
    return s;
}

std::string Sema::methodSignature(MethodDecl* m) {
    std::string s;
    if (m->unsafeApi) s += "memory_unsafe ";
    if (m->mods.isStatic && m->owner && !m->owner->isNamespaceScope) s += "static ";
    if (m->kind == MethodKind::Ctor) {
        s += "new " + (m->owner ? m->owner->displayName : m->name);
    } else {
        std::string ret = m->ret ? m->ret->str() : (m->retRef ? m->retRef->str() : "void");
        if (m->retIsRef() && m->ret) ret += "&";
        s += ret + " ";
        if (m->owner && !m->owner->isNamespaceScope) s += m->owner->displayName + ".";
        else if (m->owner && !m->owner->ns.empty()) s += m->owner->ns + ".";
        s += m->name;
        if (m->isTemplate()) {
            s += "<";
            for (size_t i = 0; i < m->typeParams.size(); i++) s += (i ? ", " : "") + m->typeParams[i];
            s += ">";
        }
    }
    if (m->kind == MethodKind::Getter) return s;
    s += "(";
    for (size_t i = 0; i < m->params.size(); i++) {
        const Param& p = m->params[i];
        if (i) s += ", ";
        if (p.isThis) s += "this ";
        s += p.type ? p.type->str() + (p.isRef() ? "&" : "") : p.tref->str();
        s += " " + p.name;
    }
    if (m->variadic) s += m->params.empty() ? "..." : ", ...";
    return s + ")";
}

void Sema::addRef(SourceLoc loc, int length, const std::string& hover, const SourceLoc* def) {
    if (trialDepth_ > 0) return;  // copias de prueba de lambdas: solo cuenta la comprobación final
    if (!ideMode || length <= 0) return;
    SymbolRef r;
    r.loc = loc;
    r.length = length;
    r.hover = hover;
    r.hasDef = def != nullptr;
    if (def) r.def = *def;
    refs.push_back(r);
}

void Sema::addCompletion(const std::string& label, int kind, const std::string& detail) {
    if (label.empty() || label == kCompletionMarker || label[0] == '<') return;
    if (!completionSeen_.insert(label + "#" + std::to_string(kind)).second) return;
    completions.push_back({label, kind, detail});
}

void Sema::completeNamespaceMembers(NamespaceSym* ns, bool children) {
    for (auto& [name, c] : ns->types) addCompletion(name, kindOf(c), typeDescription(c));
    for (auto& [name, fs] : ns->funcs) {
        if (fs.empty() || fs[0]->mods.isExtern) continue;  // las funciones 'extern' internas no se sugieren
        addCompletion(name, kFunction, methodSignature(fs[0]) + (fs.size() > 1 ? "  (+" + std::to_string(fs.size() - 1) + ")" : ""));
    }
    for (auto& [name, f] : ns->globals) addCompletion(name, kVariable, describeField(f));
    if (children)
        for (auto& [name, child] : ns->children) addCompletion(name, kModule, "namespace " + child->name);
}

void Sema::completeTypes(const std::vector<std::string>& prefix) {
    if (prefix.empty()) {
        static const char* const prims[] = {"bool", "char", "sbyte", "byte", "short", "ushort", "int", "uint",
                                             "long", "ulong", "float", "double", "string", "void", "var", "auto"};
        for (const char* p : prims) addCompletion(p, kKeyword, "");
        completeScope();
        return;
    }
    Sym s = lookupUnqualified(prefix[0], SourceLoc());
    for (size_t i = 1; i < prefix.size() && s.kind == Sym::Ns; i++) s = lookupIn(s.ns, prefix[i]);
    if (s.kind == Sym::Ns) completeNamespaceMembers(s.ns, true);
}

void Sema::completeScope() {
    for (auto& scope : ctx_.scopes)
        for (auto& [name, v] : scope) addCompletion(name, kVariable, describeVar(v));
    ClassDecl* cls = ctx_.cls;
    if (cls && !cls->isNamespaceScope) {
        for (FieldDecl* f : cls->fields) addCompletion(f->name, kField, describeField(f));
        for (MethodDecl* m : cls->methods) {
            if (m->kind == MethodKind::Getter) addCompletion(m->name, kProperty, methodSignature(m));
            else if (m->kind == MethodKind::Normal) addCompletion(m->name, kMethod, methodSignature(m));
        }
        for (auto& [name, t] : cls->typeArgMap) addCompletion(name, kTypeParam, t->str());
    }
    if (ctx_.method)
        for (auto& [name, t] : ctx_.method->typeArgMap) addCompletion(name, kTypeParam, t->str());
    for (NamespaceSym* ns = ctx_.ns; ns; ns = ns->parent) completeNamespaceMembers(ns, true);
    if (ctx_.file) {
        for (NamespaceSym* ns : ctx_.file->nsUsings) completeNamespaceMembers(ns, false);
        for (UsingDirective& u : ctx_.file->usings)
            if (!u.alias.empty()) addCompletion(u.alias, kClass, "alias de " + u.aliasType->str());
    }
    static const char* const keywords[] = {
        "if", "else", "while", "do", "for", "break", "continue", "return", "switch", "case", "default",
        "new", "delete", "sizeof", "this", "null", "nullptr", "true", "false", "var", "auto", "const",
        "class", "struct", "enum", "namespace", "using", "import", "public", "private", "static", "extern",
        "operator", "delegate", "ref", "out", "memory_unsafe", "int", "long", "double", "float", "bool", "char", "byte", "string", "void"};
    for (const char* k : keywords) addCompletion(k, kKeyword, "");
}

void Sema::completeMembers(Expr* obj, bool arrow, Type* ot) {
    if (obj->vk == ValKind::Namespace) {
        completeNamespaceMembers(obj->nsValue, true);
        return;
    }
    if (ot->isError() || obj->vk == ValKind::MethodGroup) return;
    auto visible = [&](Access a, ClassDecl* owner) {
        return a != Access::Private || owner == ctx_.cls ||
               (owner->templateOf && ctx_.cls && ctx_.cls->templateOf == owner->templateOf);
    };
    if (obj->vk == ValKind::TypeName) {
        Type* T = obj->typeValue;
        if (T->isIntegral()) {
            addCompletion("MaxValue", kConstant, "const " + T->str() + " MaxValue");
            addCompletion("MinValue", kConstant, "const " + T->str() + " MinValue");
        }
        if (T->isEnum())
            for (EnumMember& m : T->decl->enumMembers)
                addCompletion(m.name, kEnumMember, T->str() + "." + m.name + " = " + std::to_string(m.val));
        if (T->isAggregate()) {
            ClassDecl* c = T->decl;
            for (FieldDecl* f : c->fields)
                if (f->isStatic() && visible(f->mods.access, c)) addCompletion(f->name, kField, describeField(f));
            for (MethodDecl* m : c->methods) {
                if (!m->isStatic() || !visible(m->mods.access, c) || m->mods.isExtern) continue;
                if (m->kind == MethodKind::Getter) addCompletion(m->name, kProperty, methodSignature(m));
                else if (m->kind == MethodKind::Normal) addCompletion(m->name, kMethod, methodSignature(m));
            }
        }
        return;
    }
    Type* base = ot;
    if (arrow) {
        if (!ot->isPointer()) return;
        base = ot->elem;
    } else if (ot->isPointer()) {
        return;
    }
    if (base->is(TK::String)) {
        addCompletion("Length", kProperty, "(propiedad) int string.Length");
        addCompletion("Ptr", kProperty, "(propiedad) byte* string.Ptr");
    }
    for (size_t i = 0; isTupleType(base) && i < base->tupleNames.size(); i++)  // (int x, int y): x, y
        if (!base->tupleNames[i].empty()) addCompletion(base->tupleNames[i], kField, base->decl->fields[i]->type->str() + " " + base->tupleNames[i]);
    if (base->isAggregate()) {
        ClassDecl* c = base->decl;
        for (FieldDecl* f : c->fields)
            if (!f->isStatic() && visible(f->mods.access, c)) addCompletion(f->name, kField, describeField(f));
        for (MethodDecl* m : c->methods) {
            if (m->isStatic() || !visible(m->mods.access, c)) continue;
            if (m->kind == MethodKind::Getter) addCompletion(m->name, kProperty, methodSignature(m));
            else if (m->kind == MethodKind::Normal) addCompletion(m->name, kMethod, methodSignature(m));
        }
    }
    if (arrow) return;
    // Métodos de extensión aplicables al tipo.
    std::vector<NamespaceSym*> nss;
    for (NamespaceSym* ns = ctx_.ns; ns; ns = ns->parent) nss.push_back(ns);
    if (ctx_.file)
        for (NamespaceSym* ns : ctx_.file->nsUsings)
            if (std::find(nss.begin(), nss.end(), ns) == nss.end()) nss.push_back(ns);
    auto applies = [&](MethodDecl* m) {
        const Param& p = m->params[0];
        if (m->isTemplate()) {
            TypeRef* tr = p.tref;
            if (tr->parts.size() == 1 && tr->typeArgs.empty() &&
                std::find(m->typeParams.begin(), m->typeParams.end(), tr->parts[0]) != m->typeParams.end())
                return true;
            return base->isAggregate() && base->decl->templateOf && base->decl->templateOf->name == tr->parts.back();
        }
        return p.type && (p.type == base || canImplicit(nullptr, base, p.type));
    };
    for (NamespaceSym* ns : nss) {
        for (auto& [n, c] : ns->types) {
            if (!c->isStaticClass() || c->isTemplate()) continue;
            for (MethodDecl* m : c->methods)
                if (m->isExtension() && applies(m)) addCompletion(m->name, kMethod, "(extensión) " + methodSignature(m));
        }
        for (auto& [n, fs] : ns->funcs)
            for (MethodDecl* m : fs)
                if (m->isExtension() && applies(m)) addCompletion(m->name, kMethod, "(extensión) " + methodSignature(m));
    }
}
