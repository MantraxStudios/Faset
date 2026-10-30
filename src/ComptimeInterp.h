// Faset - intérprete de tiempo de compilación (lo comparten Comptime.cpp, Attributes.cpp y
// Reflection.cpp). Ver el comentario de Comptime.cpp.
#pragma once
#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Comptime.h"


inline int64_t ctTrunc(int64_t v, const Type* t) {
    if (!t) return v;
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

inline int ctRank(const Type* t) {
    if (!t) return 4;
    switch (t->kind) {
        case TK::SByte: case TK::Byte: return 1;
        case TK::Short: case TK::UShort: return 2;
        case TK::Char: return 3;
        case TK::Int: case TK::UInt: case TK::Enum: return 4;
        case TK::Long: case TK::ULong: return 5;
        default: return 4;
    }
}

// Mismo formato que faset_f64_to_str del runtime (el más corto que vuelve al mismo valor).
inline std::string fmtDouble(double v, bool f32) {
    char buf[64];
    int maxPrec = f32 ? 9 : 17;
    if (v != v) return "NaN";
    if (v > 1.7976931348623157e308) return "\xE2\x88\x9E";
    if (v < -1.7976931348623157e308) return "-\xE2\x88\x9E";
    if (v == 0) return (1.0 / v) < 0 ? "-0" : "0";
    char tmp[64];
    int prec = 1;
    for (; prec <= maxPrec; prec++) {
        std::snprintf(tmp, sizeof tmp, "%.*e", prec - 1, v);
        double back = std::strtod(tmp, nullptr);
        if (f32 ? (float)back == (float)v : back == v) break;
    }
    if (prec > maxPrec) prec = maxPrec;
    const char* e = std::strchr(tmp, 'e');
    int exp = e ? std::atoi(e + 1) : 0;
    if (exp > -5 && exp < 15) {
        int dec = prec - 1 - exp;
        std::snprintf(buf, sizeof buf, "%.*f", dec < 0 ? 0 : dec, v);
    } else {
        std::snprintf(buf, sizeof buf, "%.*E", prec - 1, v);
    }
    return buf;
}

inline std::string utf8(uint32_t c) {
    std::string b;
    if (c < 0x80) b += (char)c;
    else if (c < 0x800) b += (char)(0xC0 | (c >> 6)), b += (char)(0x80 | (c & 0x3F));
    else if (c < 0x10000)
        b += (char)(0xE0 | (c >> 12)), b += (char)(0x80 | ((c >> 6) & 0x3F)), b += (char)(0x80 | (c & 0x3F));
    else
        b += (char)(0xF0 | (c >> 18)), b += (char)(0x80 | ((c >> 12) & 0x3F)), b += (char)(0x80 | ((c >> 6) & 0x3F)),
            b += (char)(0x80 | (c & 0x3F));
    return b;
}

inline std::vector<uint32_t> codepoints(const std::string& s) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < s.size();) {
        unsigned char b = s[i];
        int extra = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : b >= 0xC0 ? 1 : 0;
        uint32_t cp = extra == 3 ? b & 7 : extra == 2 ? b & 15 : extra == 1 ? b & 31 : b;
        i++;
        for (int k = 0; k < extra && i < s.size(); k++, i++) cp = (cp << 6) | (s[i] & 0x3F);
        out.push_back(cp);
    }
    return out;
}

inline bool isStd(ClassDecl* c, const char* ns, const char* name) {
    ClassDecl* t = c && c->templateOf ? c->templateOf : c;
    return t && t->name == name && t->ns == ns;
}

inline std::string kindName(const CtValue& v) {
    switch (v.k) {
        case CtValue::Void: return "void";
        case CtValue::Null: return "null";
        case CtValue::Bool: return "bool";
        case CtValue::Int: return v.t ? v.t->str() : "int";
        case CtValue::Float: return v.t ? v.t->str() : "double";
        case CtValue::Char: return "char";
        case CtValue::Str: return "string";
        case CtValue::List: return "List<" + (v.t ? v.t->str() : std::string("?")) + ">";
        case CtValue::TypeV: return "tipo";
        case CtValue::Member: return "miembro (campo o propiedad)";
        case CtValue::Method: return "método";
        case CtValue::Param: return "parámetro";
        case CtValue::EnumItem: return "valor de enum";
        case CtValue::Obj: return v.obj && v.obj->cls ? v.obj->cls->displayName : "objeto";
        case CtValue::Group: return "grupo de métodos";
    }
    return "?";
}

inline bool endsWith(const std::string& s, const std::string& suf) {
    return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
}

inline std::string methodLabel(MethodDecl* m) {
    std::string s = m->owner && !m->owner->isNamespaceScope ? m->owner->displayName + "." : "";
    s += m->name + "(";
    for (size_t i = 0; i < m->params.size(); i++)
        s += (i ? ", " : "") + (m->params[i].type ? m->params[i].type->str() : m->params[i].tref->str()) + " " +
             m->params[i].name;
    return s + ")";
}

inline bool locLess(SourceLoc a, SourceLoc b) {
    if (a.file != b.file) return a.file < b.file;
    if (a.line != b.line) return a.line < b.line;
    return a.col < b.col;
}



inline Expr* rootOf(Expr* e) {
    for (;;) {
        if (e->kind == EK::Member) e = static_cast<MemberExpr*>(e)->obj;
        else if (e->kind == EK::Call) e = static_cast<CallExpr*>(e)->callee;
        else if (e->kind == EK::Index) e = static_cast<IndexExpr*>(e)->obj;
        else return e;
    }
}

inline TypeRef* presetRef(Type* t, SourceLoc loc) {
    auto* tr = new TypeRef();
    tr->loc = loc;
    tr->parts = {t->str()};
    tr->preset = t;
    return tr;
}


// ==================================================================== intérprete

class CtInterp {
public:
    enum Flow { FNormal, FBreak, FContinue, FReturn };
    struct Env {
        std::vector<std::map<std::string, CtValue>> scopes;
        std::shared_ptr<CtObj> self;
        CtValue ret;
        MethodDecl* fn = nullptr;
    };

    Sema& S;
    CtState& st;
    Env top;
    Env* env = &top;

    explicit CtInterp(Sema& s) : S(s), st(s.ct()) { top.scopes.emplace_back(); }

    // ---------------------------------------------------------------- utilidades

    [[noreturn]] void fail(SourceLoc loc, const std::string& msg) { throw CtError{loc, msg, st.stack}; }
    void step(SourceLoc loc) {
        if (++st.steps > kCtMaxSteps)
            fail(loc, "se superó el límite de " + std::to_string(kCtMaxSteps) +
                          " pasos de evaluación en tiempo de compilación (¿bucle infinito?)");
    }
    // Límite de memoria: el compilador no debe agotar la RAM con un bucle que crece sin fin.
    void grow(SourceLoc loc, long long n = 1) {
        if ((st.cells += n) > kCtMaxCells)
            fail(loc, "se superó el límite de " + std::to_string(kCtMaxCells) +
                          " elementos creados en una evaluación de tiempo de compilación (¿una lista que crece sin fin?)");
    }
    const std::string& checkLen(const std::string& s, SourceLoc loc) {
        if (s.size() > kCtMaxString)
            fail(loc, "una cadena de tiempo de compilación superó el límite de " + std::to_string(kCtMaxString >> 20) + " MB");
        return s;
    }
    Type* T(TK k) { return S.tc_.get(k); }

    CtValue mkInt(int64_t v, Type* t) {
        CtValue r;
        r.k = CtValue::Int;
        r.t = t ? t : T(TK::Int);
        r.i = ctTrunc(v, r.t);
        return r;
    }
    CtValue mkFloat(double v, Type* t) {
        CtValue r;
        r.k = CtValue::Float;
        r.t = t ? t : T(TK::Double);
        r.f = r.t->is(TK::Float) ? (double)(float)v : v;
        return r;
    }
    CtValue mkChar(uint32_t c) {
        CtValue r;
        r.k = CtValue::Char;
        r.t = T(TK::Char);
        r.i = c;
        return r;
    }
    CtValue mkList(Type* elem) {
        CtValue r;
        r.k = CtValue::List;
        r.t = elem;
        r.list = std::make_shared<std::vector<CtValue>>();
        return r;
    }

    // Tipo en el contexto actual (con caché: en una plantilla cada instancia tiene sus propios TypeRef).
    Type* resolve(TypeRef* tr) {
        auto it = st.typeCache.find(tr);
        if (it != st.typeCache.end()) return it->second;
        Type* t = S.resolveType(tr, true);
        if (t->isError()) fail(tr->loc, "no se encontró el tipo '" + tr->str() + "'");
        st.typeCache[tr] = t;
        return t;
    }

    std::string toStr(const CtValue& v) {
        switch (v.k) {
            case CtValue::Null: return "";
            case CtValue::Bool: return v.i ? "True" : "False";
            case CtValue::Int:
                if (v.t && v.t->isEnum()) {
                    for (EnumMember& m : v.t->decl->enumMembers)
                        if (m.val == v.i) return m.name;
                }
                if (v.t && (v.t->is(TK::ULong) || v.t->is(TK::UInt))) return std::to_string((uint64_t)v.i);
                return std::to_string(v.i);
            case CtValue::Float: return fmtDouble(v.f, v.t && v.t->is(TK::Float));
            case CtValue::Char: return utf8((uint32_t)v.i);
            case CtValue::Str: return v.s;
            case CtValue::TypeV: return v.t->str();
            case CtValue::Member: case CtValue::Method: case CtValue::Param: case CtValue::EnumItem: return v.s;
            case CtValue::Obj:
                if (v.obj && v.obj->fields.count("__sb")) return v.obj->fields["__sb"].s;
                return v.obj && v.obj->cls ? v.obj->cls->ns + (v.obj->cls->ns.empty() ? "" : ".") + v.obj->cls->displayName : "";
            case CtValue::List: return "List<" + (v.t ? v.t->str() : std::string("?")) + ">";
            default: return "";
        }
    }

    bool truthy(const CtValue& v, SourceLoc loc) {
        if (v.k != CtValue::Bool) fail(loc, "se esperaba un valor 'bool' y se obtuvo " + kindName(v));
        return v.i != 0;
    }
    int64_t asInt(const CtValue& v, SourceLoc loc) {
        if (v.k == CtValue::Int || v.k == CtValue::Char) return v.i;
        if (v.k == CtValue::Float) return (int64_t)v.f;
        fail(loc, "se esperaba un número entero y se obtuvo " + kindName(v));
    }
    double asNum(const CtValue& v, SourceLoc loc) {
        if (v.k == CtValue::Float) return v.f;
        if (v.k == CtValue::Int || v.k == CtValue::Char) {
            if (v.t && (v.t->is(TK::ULong))) return (double)(uint64_t)v.i;
            return (double)v.i;
        }
        fail(loc, "se esperaba un número y se obtuvo " + kindName(v));
    }
    const std::string& asStr(const CtValue& v, SourceLoc loc) {
        if (v.k != CtValue::Str) fail(loc, "se esperaba un 'string' y se obtuvo " + kindName(v));
        return v.s;
    }

    CtValue copyStruct(const CtValue& v) {
        if (v.k != CtValue::Obj || !v.obj || !v.obj->cls || v.obj->cls->kind != ClassKind::Struct) return v;
        CtValue r = v;
        r.obj = std::make_shared<CtObj>(*v.obj);
        for (auto& [n, f] : r.obj->fields) f = copyStruct(f);
        return r;
    }

    CtValue defaultOf(Type* t, SourceLoc loc) {
        if (!t) return CtValue::null();
        if (t->isIntegral() || t->isEnum()) return t->is(TK::Char) ? mkChar(0) : mkInt(0, t);
        if (t->isFloating()) return mkFloat(0, t);
        if (t->is(TK::Bool)) return CtValue::boolean(false);
        if (t->is(TK::String)) return CtValue::str("");
        if (t->isStruct() && t->decl) {
            if (isStd(t->decl, "std", "Nullable")) return CtValue::null();
            CtValue r;
            r.k = CtValue::Obj;
            r.obj = std::make_shared<CtObj>();
            r.obj->cls = t->decl;
            initFields(r.obj, loc);
            return r;
        }
        return CtValue::null();
    }

    // Conversión al tipo 't' (implícita o con (T)x).
    CtValue convert(const CtValue& v, Type* t, SourceLoc loc) {
        if (!t || t->isError() || t->isVoid()) return v;
        if (t->isStruct() && t->decl && isStd(t->decl, "std", "Nullable")) {
            if (v.k == CtValue::Null) return v;
            return convert(v, t->decl->typeArgs.empty() ? nullptr : t->decl->typeArgs[0], loc);
        }
        if (t->is(TK::Char)) {
            if (v.k == CtValue::Int || v.k == CtValue::Char) return mkChar((uint32_t)v.i);
            if (v.k == CtValue::Float) return mkChar((uint32_t)(int64_t)v.f);
        } else if (t->isIntegral() || t->isEnum()) {
            if (v.k == CtValue::Int || v.k == CtValue::Char) return mkInt(v.i, t);
            if (v.k == CtValue::Float) {
                if (v.f != v.f) return mkInt(0, t);
                return mkInt(t->is(TK::ULong) ? (int64_t)(uint64_t)v.f : (int64_t)v.f, t);
            }
        } else if (t->isFloating()) {
            if (v.k == CtValue::Int || v.k == CtValue::Char || v.k == CtValue::Float) return mkFloat(asNum(v, loc), t);
        } else if (t->is(TK::Bool)) {
            if (v.k == CtValue::Bool) return v;
        } else if (t->is(TK::String)) {
            if (v.k == CtValue::Str) return v;
            if (v.k == CtValue::Null) return CtValue::str("");
        } else {
            CtValue r = copyStruct(v);
            if (r.k == CtValue::List && t->isClass() && t->decl && isStd(t->decl, "std.collections", "List") &&
                !t->decl->typeArgs.empty())
                r.t = r.t ? r.t : t->decl->typeArgs[0];
            return r;
        }
        fail(loc, "no se puede convertir " + kindName(v) + " en '" + t->str() + "' en tiempo de compilación");
    }

    // ---------------------------------------------------------------- nombres y tipos

    CtValue* findLocal(const std::string& name) {
        for (auto it = env->scopes.rbegin(); it != env->scopes.rend(); ++it) {
            auto f = it->find(name);
            if (f != it->end()) return &f->second;
        }
        return nullptr;
    }

    bool isUserTipo(const std::string& name) {
        Sym s = S.lookupUnqualified(name, SourceLoc());
        return s.kind == Sym::TypeK;
    }

    // ¿Nombra 'e' un tipo (para acceder a sus miembros estáticos)? Los parámetros de tipo, Tipo<T> y
    // las variables de tiempo de compilación son valores de tipo (reflexión), no nombres de tipo.
    bool typeNameOf(Expr* e, Type*& t, ClassDecl*& c, NamespaceSym** nsOut = nullptr) {
        t = nullptr;
        c = nullptr;
        if (e->kind == EK::Name) {
            auto* n = static_cast<NameExpr*>(e);
            if (findLocal(n->name) || S.lookupLocal(n->name)) return false;
            if (n->name == "Tipo" && n->typeArgs.size() == 1 && !isUserTipo("Tipo")) return false;
            if (S.ctx_.method && S.ctx_.method->typeArgMap.count(n->name)) return false;
            if (S.ctx_.cls && S.ctx_.cls->typeArgMap.count(n->name)) return false;
            if (S.ctx_.cls && !S.ctx_.cls->isNamespaceScope &&
                (S.findField(S.ctx_.cls, n->name) || S.findGetter(S.ctx_.cls, n->name)))
                return false;
            if (Type* k = S.tc_.fromKeyword(n->name)) {
                t = k;
                return true;
            }
            Sym s = S.lookupUnqualified(n->name, n->loc);
            if (s.kind == Sym::Ns && nsOut) {
                *nsOut = s.ns;
                return false;
            }
            if (s.kind != Sym::TypeK) return false;
            return symType(s, n->typeArgs, n->loc, t, c);
        }
        if (e->kind == EK::Member) {
            auto* m = static_cast<MemberExpr*>(e);
            NamespaceSym* ns = nullptr;
            Type* ot;
            ClassDecl* oc;
            if (typeNameOf(m->obj, ot, oc, &ns) || !ns) return false;
            Sym s = S.lookupIn(ns, m->name);
            if (s.kind == Sym::Ns && nsOut) {
                *nsOut = s.ns;
                return false;
            }
            if (s.kind != Sym::TypeK) return false;
            return symType(s, m->typeArgs, m->loc, t, c);
        }
        return false;
    }

    bool symType(const Sym& s, const std::vector<TypeRef*>& typeArgs, SourceLoc loc, Type*& t, ClassDecl*& c) {
        if (s.type) {
            t = s.type;
            c = t->decl;
            return true;
        }
        c = s.decl;
        if (!c) return false;
        if (c->arityTwin && c->isTemplate() == typeArgs.empty()) c = c->arityTwin;
        if (c->isTemplate()) {
            if (typeArgs.empty()) fail(loc, "el tipo genérico '" + c->name + "' requiere argumentos de tipo");
            std::vector<Type*> args;
            for (TypeRef* a : typeArgs) args.push_back(resolve(a));
            c = S.instantiate(c, args, loc);
            if (!c) fail(loc, "no se pudo instanciar '" + s.decl->name + "'");
        }
        S.resolveClassSignatures(c);
        t = c->isStaticClass() ? nullptr : c->type;
        return true;
    }

    CtValue evalName(NameExpr* n) {
        const std::string& name = n->name;
        if (CtValue* v = findLocal(name)) return *v;
        if (VarInfo* v = S.lookupLocal(name)) {
            auto b = st.binds.find(v);
            if (b != st.binds.end()) return b->second;
            if (v->isConst && v->constInit) return eval(v->constInit);
            fail(n->loc, "el valor de la variable '" + name + "' no se conoce en tiempo de compilación");
        }
        if (name == "Tipo" && n->typeArgs.size() == 1 && !isUserTipo("Tipo")) return CtValue::type(resolve(n->typeArgs[0]));
        ClassDecl* cls = S.ctx_.cls;
        if (env->self) {
            auto f = env->self->fields.find(name);
            if (f != env->self->fields.end()) return f->second;
            if (MethodDecl* g = S.findGetter(env->self->cls, name)) return callMethod(g, {}, env->self, n->loc);
        }
        if (cls && !cls->isNamespaceScope) {
            if (FieldDecl* f = S.findField(cls, name)) return staticField(f, n->loc);
            if (MethodDecl* g = S.findGetter(cls, name)) {
                if (!g->isStatic()) fail(n->loc, "la propiedad de instancia '" + name + "' no tiene objeto en tiempo de compilación");
                return callMethod(g, {}, nullptr, n->loc);
            }
            std::vector<MethodDecl*> grp = S.findMethods(cls, name);
            if (!grp.empty()) {
                CtValue r;
                r.k = CtValue::Group;
                r.group = grp;
                r.s = name;
                return r;
            }
        }
        if (n->typeArgs.empty()) {
            if (S.ctx_.method && S.ctx_.method->typeArgMap.count(name)) return CtValue::type(S.ctx_.method->typeArgMap[name]);
            if (cls && cls->typeArgMap.count(name)) return CtValue::type(cls->typeArgMap[name]);
            if (Type* k = S.tc_.fromKeyword(name)) return CtValue::type(k);
        }
        Sym s = S.lookupUnqualified(name, n->loc);
        if (s.kind == Sym::Global) return staticField(s.global, n->loc);
        if (s.kind == Sym::Funcs) {
            CtValue r;
            r.k = CtValue::Group;
            r.group = s.funcs;
            r.s = name;
            return r;
        }
        if (s.kind == Sym::TypeK) {
            Type* t;
            ClassDecl* c;
            if (symType(s, n->typeArgs, n->loc, t, c) && t) return CtValue::type(t);
        }
        fail(n->loc, "el nombre '" + name + "' no existe o no se puede usar en tiempo de compilación");
    }

    // Campo estático: 'const' o 'static readonly' con inicializador (su valor no cambia).
    CtValue staticField(FieldDecl* f, SourceLoc loc) {
        if (!f->isStatic()) {
            if (env->self) {
                auto it = env->self->fields.find(f->name);
                if (it != env->self->fields.end()) return it->second;
            }
            fail(loc, "el campo de instancia '" + f->name + "' no tiene objeto en tiempo de compilación");
        }
        if (!(f->mods.isConst || f->mods.isReadonly) || !f->init)
            fail(loc, "el campo estático '" + f->name + "' puede cambiar al ejecutar: solo se pueden leer 'const' y "
                      "'static readonly' con valor inicial en tiempo de compilación");
        Sema::CtxSave save(S);
        S.enter(f->owner, nullptr);
        if (f->file) S.ctx_.file = f->file;
        S.ctx_.field = f;
        Env e2;
        e2.scopes.emplace_back();
        Env* saved = env;
        env = &e2;
        CtValue v;
        try {
            v = eval(f->init);
        } catch (...) {
            env = saved;
            throw;
        }
        env = saved;
        return f->type ? convert(v, f->type, loc) : v;
    }

    // ---------------------------------------------------------------- expresiones

    CtValue eval(Expr* e) {
        switch (e->kind) {
            case EK::IntLit: {
                auto* l = static_cast<IntLitExpr*>(e);
                uint64_t v = l->value;
                Type* t = T(TK::Int);
                if (l->suffixU && l->suffixL) t = T(TK::ULong);
                else if (l->suffixU) t = T(v <= UINT32_MAX ? TK::UInt : TK::ULong);
                else if (l->suffixL) t = T(v <= (uint64_t)INT64_MAX ? TK::Long : TK::ULong);
                else if (v > (uint64_t)INT32_MAX) t = T(v <= UINT32_MAX ? TK::UInt : v <= (uint64_t)INT64_MAX ? TK::Long : TK::ULong);
                return mkInt((int64_t)v, t);
            }
            case EK::FloatLit: {
                auto* l = static_cast<FloatLitExpr*>(e);
                return mkFloat(l->value, T(l->isFloat32 ? TK::Float : TK::Double));
            }
            case EK::BoolLit: return CtValue::boolean(static_cast<BoolLitExpr*>(e)->value);
            case EK::CharLit: return mkChar(static_cast<CharLitExpr*>(e)->value);
            case EK::StringLit: return CtValue::str(static_cast<StringLitExpr*>(e)->value);
            case EK::Null: return CtValue::null();
            case EK::Default: {
                auto* d = static_cast<DefaultExpr*>(e);
                if (!d->tref) return e->type && !e->type->is(TK::Null) ? defaultOf(e->type, e->loc) : CtValue::null();
                return defaultOf(resolve(d->tref), e->loc);
            }
            case EK::This:
                if (!env->self) fail(e->loc, "'this' no existe aquí en tiempo de compilación");
                {
                    CtValue r;
                    r.k = CtValue::Obj;
                    r.obj = env->self;
                    return r;
                }
            case EK::Interp: return evalInterp(static_cast<InterpExpr*>(e));
            case EK::Name: return evalName(static_cast<NameExpr*>(e));
            case EK::Member: return evalMember(static_cast<MemberExpr*>(e));
            case EK::Call: return evalCall(static_cast<CallExpr*>(e));
            case EK::Index: {
                auto* ix = static_cast<IndexExpr*>(e);
                CtValue o = eval(ix->obj);
                CtValue i = eval(ix->index);
                CtValue r;
                if (indexByRange(o, i, ix->loc, r)) return r;
                return *indexRef(o, i, ix->loc, false);
            }
            case EK::Unary: return evalUnary(static_cast<UnaryExpr*>(e));
            case EK::Postfix: {
                auto* p = static_cast<PostfixExpr*>(e);
                CtValue old = eval(p->operand);
                CtValue nv = arith(old, mkInt(1, T(TK::Int)), p->op == "++" ? "+" : "-", p->loc);
                store(p->operand, convert(nv, typeOfValue(old), p->loc));
                return old;
            }
            case EK::Binary: return evalBinary(static_cast<BinaryExpr*>(e));
            case EK::Assign: return evalAssign(static_cast<AssignExpr*>(e));
            case EK::Cond: {
                auto* c = static_cast<CondExpr*>(e);
                return truthy(eval(c->cond), c->cond->loc) ? eval(c->a) : eval(c->b);
            }
            case EK::Cast: {
                auto* c = static_cast<CastExpr*>(e);
                Type* to = c->tref ? resolve(c->tref) : c->type;
                return convert(eval(c->operand), to, c->loc);
            }
            case EK::New: return evalNew(static_cast<NewExpr*>(e));
            case EK::TypeOf: return CtValue::type(resolve(static_cast<TypeOfExpr*>(e)->tref));
            case EK::NameOf: {
                auto* n = static_cast<NameOfExpr*>(e);
                if (!n->value.empty()) return CtValue::str(n->value);
                Expr* o = n->operand;
                if (o->kind == EK::Name) return CtValue::str(static_cast<NameExpr*>(o)->name);
                if (o->kind == EK::Member) return CtValue::str(static_cast<MemberExpr*>(o)->name);
                fail(e->loc, "'nameof' requiere un nombre");
            }
            case EK::Comptime: return eval(static_cast<ComptimeExpr*>(e)->operand);
            case EK::ParamsList: {
                auto* pl = static_cast<ParamsListExpr*>(e);
                CtValue l = mkList(pl->type && pl->type->decl && !pl->type->decl->typeArgs.empty() ? pl->type->decl->typeArgs[0] : nullptr);
                grow(e->loc, (long long)pl->items.size());
                for (Expr* it : pl->items) l.list->push_back(copyStruct(eval(it)));
                return l;
            }
            case EK::SwitchExpr: return evalSwitchExpr(static_cast<SwitchExpr*>(e));
            case EK::Is: return evalIs(static_cast<IsExpr*>(e));
            case EK::SizeOf: {
                int64_t size, align, size4, align4;
                Type* st = resolve(static_cast<SizeOfExpr*>(e)->tref);
                layoutOf(st, e->loc, size, align);
                layoutOf(st, e->loc, size4, align4, 4);
                if (size != size4)
                    fail(e->loc, "sizeof(" + st->str() + ") depende de la plataforma de destino (x86 de 32 bits alinea long y double a 4 bytes)");
                return mkInt(size, T(TK::Int));
            }
            case EK::As: {
                auto* a = static_cast<AsExpr*>(e);
                CtValue v = eval(a->operand);
                return instanceOf(v, a->preset ? a->preset : resolve(a->tref)) ? v : CtValue::null();
            }
            case EK::IsPattern: {
                auto* ip = static_cast<IsPatternExpr*>(e);
                return CtValue::boolean(matches(ip->pat, eval(ip->subject)));
            }
            case EK::Lambda: case EK::DelegateConv:
                fail(e->loc, "las lambdas y los delegados no se pueden usar en tiempo de compilación");
            case EK::Await: fail(e->loc, "'await' no se puede usar en tiempo de compilación");
            case EK::Let: {  // (temporales; a; b; resultado): la forma reescrita de [..], a..b, s[^1]...
                auto* l = static_cast<LetExpr*>(e);
                env->scopes.emplace_back();
                for (auto& b : l->binds) env->scopes.back()[b.first->name] = copyStruct(eval(b.second));
                CtValue r;
                for (Expr* x : l->seq) r = eval(x);
                env->scopes.pop_back();
                return r;
            }
            case EK::Collection: case EK::Range: case EK::FromEnd:  // [1, 2, ..xs], a..b, ^n (Arrays.cpp)
                if (e->lowered) return eval(e->lowered);
                return evalUnlowered(e);  // en 'comptime expr' llegan sin la forma reescrita
            case EK::NewArray: arrayUnsupported(e->loc);
            default: break;
        }
        fail(e->loc, "esta expresión no se puede evaluar en tiempo de compilación");
    }

    Type* typeOfValue(const CtValue& v) {
        switch (v.k) {
            case CtValue::Int: case CtValue::Float: return v.t;
            case CtValue::Char: return T(TK::Char);
            case CtValue::Bool: return T(TK::Bool);
            case CtValue::Str: return T(TK::String);
            default: return nullptr;
        }
    }

    CtValue evalInterp(InterpExpr* e) {
        std::string out;
        for (auto& p : e->parts) {
            if (!p.expr) {
                out += p.text;
                continue;
            }
            CtValue v = eval(p.expr);
            std::string s = formatValue(v, p.format, p.expr->loc);
            if (p.hasAlign) {
                size_t w = (size_t)std::abs(p.align);
                size_t len = codepoints(s).size();
                if (len < w) s = p.align < 0 ? s + std::string(w - len, ' ') : std::string(w - len, ' ') + s;
            }
            out += s;
        }
        return CtValue::str(out);
    }

    std::string formatValue(const CtValue& v, const std::string& fmt, SourceLoc loc) {
        if (fmt.empty()) return toStr(v);
        char spec = fmt[0];
        int prec = fmt.size() > 1 ? std::atoi(fmt.c_str() + 1) : -1;
        char buf[128];
        if ((spec == 'F' || spec == 'f' || spec == 'N' || spec == 'n') && (v.k == CtValue::Float || v.k == CtValue::Int)) {
            std::snprintf(buf, sizeof buf, "%.*f", prec < 0 ? 2 : prec, asNum(v, loc));
            return buf;
        }
        if ((spec == 'D' || spec == 'd') && v.k == CtValue::Int) {
            std::snprintf(buf, sizeof buf, "%0*lld", prec < 0 ? 1 : prec, (long long)v.i);
            return buf;
        }
        if ((spec == 'X' || spec == 'x') && (v.k == CtValue::Int || v.k == CtValue::Char)) {
            std::snprintf(buf, sizeof buf, spec == 'X' ? "%0*llX" : "%0*llx", prec < 0 ? 1 : prec,
                          (unsigned long long)ctTrunc(v.i, v.t ? v.t : T(TK::Long)) & (v.t && ctRank(v.t) < 5 ? 0xFFFFFFFFull : ~0ull));
            return buf;
        }
        if ((spec == 'E' || spec == 'e') && (v.k == CtValue::Float || v.k == CtValue::Int)) {
            std::snprintf(buf, sizeof buf, spec == 'E' ? "%.*E" : "%.*e", prec < 0 ? 6 : prec, asNum(v, loc));
            return buf;
        }
        return toStr(v);
    }

    CtValue evalUnary(UnaryExpr* u) {
        if (u->op == "++" || u->op == "--") {
            CtValue old = eval(u->operand);
            CtValue nv = convert(arith(old, mkInt(1, T(TK::Int)), u->op == "++" ? "+" : "-", u->loc), typeOfValue(old), u->loc);
            store(u->operand, nv);
            return nv;
        }
        if (u->op == "*" || u->op == "&") fail(u->loc, "los punteros no existen en tiempo de compilación");
        CtValue v = eval(u->operand);
        if (u->op == "!") return CtValue::boolean(!truthy(v, u->loc));
        if (u->op == "-") {
            if (v.k == CtValue::Float) return mkFloat(-v.f, v.t);
            int64_t x = asInt(v, u->loc);
            Type* t = ctRank(v.t) < 4 || v.k == CtValue::Char ? T(TK::Int) : v.t;
            if (t->is(TK::UInt)) t = T(TK::Long);
            return mkInt((int64_t)(0ull - (uint64_t)x), t);
        }
        if (u->op == "+") return v;
        if (u->op == "~") {
            Type* t = ctRank(v.t) < 4 || v.k == CtValue::Char ? T(TK::Int) : v.t;
            return mkInt(~asInt(v, u->loc), t);
        }
        fail(u->loc, "operador '" + u->op + "' no admitido en tiempo de compilación");
    }

    bool equal(const CtValue& a, const CtValue& b) {
        if (a.k == CtValue::Null || b.k == CtValue::Null) return a.k == b.k;
        if ((a.k == CtValue::Int || a.k == CtValue::Char || a.k == CtValue::Float) &&
            (b.k == CtValue::Int || b.k == CtValue::Char || b.k == CtValue::Float)) {
            if (a.k == CtValue::Float || b.k == CtValue::Float) return asNum(a, {}) == asNum(b, {});
            return a.i == b.i;
        }
        if (a.k != b.k) return false;
        switch (a.k) {
            case CtValue::Bool: return a.i == b.i;
            case CtValue::Str: return a.s == b.s;
            case CtValue::TypeV: return a.t == b.t;
            case CtValue::Member: return a.field == b.field && a.getter == b.getter;
            case CtValue::Method: case CtValue::Param: return a.method == b.method && a.index == b.index;
            case CtValue::EnumItem: return a.owner == b.owner && a.index == b.index;
            case CtValue::Obj: return a.obj == b.obj;
            case CtValue::List: return a.list == b.list;
            default: return false;
        }
    }

    // Operación aritmética, de bits o de comparación (con las promociones numéricas de C#).
    CtValue arith(const CtValue& L, const CtValue& R, const std::string& op, SourceLoc loc) {
        if (op == "+" && (L.k == CtValue::Str || R.k == CtValue::Str)) return CtValue::str(checkLen(toStr(L) + toStr(R), loc));
        if (op == "==") return CtValue::boolean(equal(L, R));
        if (op == "!=") return CtValue::boolean(!equal(L, R));
        if (L.k == CtValue::Bool && R.k == CtValue::Bool && (op == "&" || op == "|" || op == "^")) {
            bool x = L.i, y = R.i;
            return CtValue::boolean(op == "&" ? (x && y) : op == "|" ? (x || y) : (x != y));
        }
        if (L.k == CtValue::Str && R.k == CtValue::Str && (op == "<" || op == ">" || op == "<=" || op == ">=")) {
            int c = L.s.compare(R.s);
            return CtValue::boolean(op == "<" ? c < 0 : op == ">" ? c > 0 : op == "<=" ? c <= 0 : c >= 0);
        }
        bool numL = L.k == CtValue::Int || L.k == CtValue::Char || L.k == CtValue::Float;
        bool numR = R.k == CtValue::Int || R.k == CtValue::Char || R.k == CtValue::Float;
        if (!numL || !numR)
            fail(loc, "el operador '" + op + "' no se puede aplicar a " + kindName(L) + " y " + kindName(R) +
                          " en tiempo de compilación");
        bool cmp = op == "<" || op == ">" || op == "<=" || op == ">=";
        if (L.k == CtValue::Float || R.k == CtValue::Float) {
            double x = asNum(L, loc), y = asNum(R, loc);
            Type* t = (L.k != CtValue::Float || L.t->is(TK::Float)) && (R.k != CtValue::Float || R.t->is(TK::Float)) ? T(TK::Float) : T(TK::Double);
            if (cmp) return CtValue::boolean(op == "<" ? x < y : op == ">" ? x > y : op == "<=" ? x <= y : x >= y);
            if (op == "+") return mkFloat(x + y, t);
            if (op == "-") return mkFloat(x - y, t);
            if (op == "*") return mkFloat(x * y, t);
            if (op == "/") return mkFloat(x / y, t);
            if (op == "%") return mkFloat(std::fmod(x, y), t);
            fail(loc, "el operador '" + op + "' no se puede aplicar a números con decimales");
        }
        Type* lt = L.k == CtValue::Char ? T(TK::Char) : L.t;
        Type* rt = R.k == CtValue::Char ? T(TK::Char) : R.t;
        bool shift = op == "<<" || op == ">>";
        Type* t;
        if (lt->isEnum() && rt->isEnum() && lt == rt && (op == "&" || op == "|" || op == "^")) t = lt;
        else if (shift) t = ctRank(lt) < 4 ? T(TK::Int) : lt->isEnum() ? T(TK::Int) : lt;
        else {
            bool uL = lt->isUnsignedInt() && !lt->is(TK::Char), uR = rt->isUnsignedInt() && !rt->is(TK::Char);
            int rank = std::max(ctRank(lt), ctRank(rt));
            if (rank < 4) rank = 4;
            if (rank == 5) t = (lt->is(TK::ULong) || rt->is(TK::ULong)) ? T(TK::ULong) : T(TK::Long);
            else if ((lt->is(TK::UInt) && rt->is(TK::UInt)) || (lt->is(TK::UInt) && uR) || (rt->is(TK::UInt) && uL)) t = T(TK::UInt);
            else if (lt->is(TK::UInt) || rt->is(TK::UInt)) t = T(TK::Long);
            else t = T(TK::Int);
        }
        bool uns = t->is(TK::UInt) || t->is(TK::ULong);
        int64_t x = L.i, y = R.i;
        uint64_t ux = (uint64_t)x, uy = (uint64_t)y;
        if (cmp) {
            bool r = uns ? (op == "<" ? ux < uy : op == ">" ? ux > uy : op == "<=" ? ux <= uy : ux >= uy)
                         : (op == "<" ? x < y : op == ">" ? x > y : op == "<=" ? x <= y : x >= y);
            return CtValue::boolean(r);
        }
        int64_t r;
        if (op == "+") r = (int64_t)(ux + uy);
        else if (op == "-") r = (int64_t)(ux - uy);
        else if (op == "*") r = (int64_t)(ux * uy);
        else if (op == "/" || op == "%") {
            if (y == 0) fail(loc, "división por cero en tiempo de compilación");
            if (uns) r = (int64_t)(op == "/" ? ux / uy : ux % uy);
            else if (x == INT64_MIN && y == -1) r = op == "/" ? x : 0;
            else r = op == "/" ? x / y : x % y;
        } else if (op == "<<") r = (int64_t)(ux << (y & (ctRank(t) == 5 ? 63 : 31)));
        else if (op == ">>") r = uns ? (int64_t)(ux >> (y & (ctRank(t) == 5 ? 63 : 31))) : x >> (y & (ctRank(t) == 5 ? 63 : 31));
        else if (op == "&") r = x & y;
        else if (op == "|") r = x | y;
        else if (op == "^") r = x ^ y;
        else fail(loc, "operador '" + op + "' no admitido en tiempo de compilación");
        return mkInt(r, t);
    }

    CtValue evalBinary(BinaryExpr* b) {
        if (b->op == "&&") return CtValue::boolean(truthy(eval(b->lhs), b->lhs->loc) && truthy(eval(b->rhs), b->rhs->loc));
        if (b->op == "||") return CtValue::boolean(truthy(eval(b->lhs), b->lhs->loc) || truthy(eval(b->rhs), b->rhs->loc));
        if (b->op == "??") {
            CtValue l = eval(b->lhs);
            return l.k == CtValue::Null ? eval(b->rhs) : l;
        }
        CtValue L = eval(b->lhs);
        CtValue R = eval(b->rhs);
        return arith(L, R, b->op, b->loc);
    }

    CtValue evalAssign(AssignExpr* a) {
        CtValue r = eval(a->rhs);
        if (a->op == "?\?=") {
            CtValue cur = eval(a->lhs);
            if (cur.k != CtValue::Null) return cur;
        } else if (a->op != "=") {
            CtValue cur = eval(a->lhs);
            std::string op = a->op.substr(0, a->op.size() - 1);
            r = arith(cur, r, op, a->loc);
            if (Type* t = typeOfValue(cur)) r = convert(r, t, a->loc);
        }
        store(a->lhs, r);
        return r;
    }

    // Guarda 'v' en el destino 'lhs' (variable, campo de un objeto, elemento de una lista).
    void store(Expr* lhs, const CtValue& val) {
        CtValue v = copyStruct(val);
        if (lhs->kind == EK::Name) {
            auto* n = static_cast<NameExpr*>(lhs);
            if (CtValue* slot = findLocal(n->name)) {
                if (Type* t = typeOfValue(*slot)) v = convert(v, t, lhs->loc);
                *slot = v;
                return;
            }
            if (env->self) {
                auto f = env->self->fields.find(n->name);
                if (f != env->self->fields.end()) {
                    FieldDecl* fd = S.findField(env->self->cls, n->name);
                    f->second = fd && fd->type ? convert(v, fd->type, lhs->loc) : v;
                    return;
                }
                if (MethodDecl* g = S.findGetter(env->self->cls, n->name)) {
                    if (MethodDecl* set = S.FindSetter(g)) {
                        callMethod(set, {v}, env->self, lhs->loc);
                        return;
                    }
                }
            }
            if (S.lookupLocal(n->name)) fail(lhs->loc, "no se puede modificar '" + n->name + "' en tiempo de compilación");
            fail(lhs->loc, "solo se pueden modificar variables locales, campos de objetos y elementos de listas en tiempo de compilación");
        }
        if (lhs->kind == EK::Member) {
            auto* m = static_cast<MemberExpr*>(lhs);
            CtValue o = eval(m->obj);
            if (o.k == CtValue::Obj && o.obj) {
                auto f = o.obj->fields.find(m->name);
                if (f != o.obj->fields.end()) {
                    FieldDecl* fd = S.findField(o.obj->cls, m->name);
                    f->second = fd && fd->type ? convert(v, fd->type, lhs->loc) : v;
                    return;
                }
                if (MethodDecl* g = S.findGetter(o.obj->cls, m->name)) {
                    if (MethodDecl* set = S.FindSetter(g)) {
                        callMethod(set, {v}, o.obj, lhs->loc);
                        return;
                    }
                }
            }
            fail(lhs->loc, "no se puede asignar '" + m->name + "' en tiempo de compilación");
        }
        if (lhs->kind == EK::Index) {
            auto* ix = static_cast<IndexExpr*>(lhs);
            CtValue o = eval(ix->obj);
            CtValue i = eval(ix->index);
            CtValue* slot = indexRef(o, i, ix->loc, true);
            *slot = o.t ? convert(v, o.t, lhs->loc) : v;
            return;
        }
        fail(lhs->loc, "no se puede asignar a esta expresión en tiempo de compilación");
    }

    CtValue scratch_;
    // ^n, a..b y [a, ..xs] tal como los escribió el parser (sin el tipo de destino ya resuelto).
    CtValue mkStdIndex(int64_t n, bool fromEnd, SourceLoc loc) {
        Type* it = S.stdType("Index");
        if (!it || !it->decl) fail(loc, "'^' necesita std.Index");
        if (n < 0) fail(loc, "Index: el valor no puede ser negativo (" + std::to_string(n) + ")");
        CtValue r;
        r.k = CtValue::Obj;
        r.obj = std::make_shared<CtObj>();
        r.obj->cls = it->decl;
        r.obj->fields["value"] = mkInt(n, T(TK::Int));
        r.obj->fields["fromEnd"] = CtValue::boolean(fromEnd);
        return r;
    }
    CtValue evalUnlowered(Expr* e) {
        if (e->kind == EK::FromEnd) return mkStdIndex(asInt(eval(static_cast<FromEndExpr*>(e)->operand), e->loc), true, e->loc);
        if (e->kind == EK::Range) {
            auto* r = static_cast<RangeExpr*>(e);
            Type* rt = S.stdType("Range");
            if (!rt || !rt->decl) fail(e->loc, "'..' necesita std.Range");
            auto end = [&](Expr* x, bool isEnd) {
                if (!x) return mkStdIndex(0, isEnd, e->loc);  // ..b es 0..b; a.. es a..^0
                CtValue v = eval(x);
                if (v.k == CtValue::Obj) return v;  // ya es un Index
                return mkStdIndex(asInt(v, x->loc), false, x->loc);
            };
            CtValue v;
            v.k = CtValue::Obj;
            v.obj = std::make_shared<CtObj>();
            v.obj->cls = rt->decl;
            v.obj->fields["start"] = end(r->start, false);
            v.obj->fields["end"] = end(r->end, true);
            return v;
        }
        auto* c = static_cast<CollectionExpr*>(e);
        CtValue l = mkList(nullptr);
        for (auto& el : c->elems) {
            if (el.key) fail(el.loc, "los diccionarios no se pueden crear en tiempo de compilación");
            CtValue v = eval(el.value);
            if (el.spread) {
                if (v.k != CtValue::List) fail(el.loc, "'..' en tiempo de compilación solo puede expandir una lista");
                grow(el.loc, (long long)v.list->size());
                for (const CtValue& x : *v.list) l.list->push_back(copyStruct(x));
            } else {
                grow(el.loc);
                l.list->push_back(copyStruct(v));
            }
        }
        // Sin destino, el tipo de los elementos sale de ellos si todos son del mismo ([1, 2] es List<int>).
        for (size_t k = 0; k < l.list->size(); k++) {
            Type* t = typeOfValue((*l.list)[k]);
            if (k == 0) l.t = t;
            else if (t != l.t) l.t = nullptr;
            if (!l.t) break;
        }
        return l;
    }

    [[noreturn]] void arrayUnsupported(SourceLoc loc) {
        fail(loc, "los arreglos T[] no se pueden usar en tiempo de compilación; usa List<T> (también con [1, 2, ..otra])");
    }

    // Un std.Index (^n o n) dentro de una secuencia de 'len' elementos.
    bool stdIndex(const CtValue& v, int64_t len, int64_t& out, SourceLoc loc) {
        if (v.k != CtValue::Obj || !v.obj || !isStd(v.obj->cls, "std", "Index")) return false;
        int64_t n = asInt(v.obj->fields["value"], loc);
        out = truthy(v.obj->fields["fromEnd"], loc) ? len - n : n;
        return true;
    }

    // a[^n] y a[x..y] sobre listas y cadenas (las cadenas, por bytes como al ejecutar).
    bool indexByRange(CtValue& o, const CtValue& idx, SourceLoc loc, CtValue& out) {
        if (o.k != CtValue::List && o.k != CtValue::Str) return false;
        int64_t len = o.k == CtValue::List ? (int64_t)o.list->size() : (int64_t)o.s.size();
        int64_t i;
        if (stdIndex(idx, len, i, loc)) {
            out = *indexRef(o, mkInt(i, T(TK::Int)), loc, false);
            return true;
        }
        if (idx.k != CtValue::Obj || !idx.obj || !isStd(idx.obj->cls, "std", "Range")) return false;
        int64_t a, b;
        if (!stdIndex(idx.obj->fields["start"], len, a, loc) || !stdIndex(idx.obj->fields["end"], len, b, loc)) return false;
        if (a < 0 || b > len || a > b)
            fail(loc, "el rango " + std::to_string(a) + ".." + std::to_string(b) + " se sale de los límites (longitud " +
                          std::to_string(len) + ")");
        if (o.k == CtValue::Str) {
            out = CtValue::str(o.s.substr((size_t)a, (size_t)(b - a)));
        } else {
            out = mkList(o.t);
            grow(loc, (long long)(b - a));
            for (int64_t k = a; k < b; k++) out.list->push_back(copyStruct((*o.list)[(size_t)k]));
        }
        return true;
    }

    CtValue* indexRef(CtValue& o, const CtValue& idx, SourceLoc loc, bool write) {
        if (o.k == CtValue::List && write && idx.k == CtValue::Obj) {  // l[^1] = x
            int64_t i;
            if (stdIndex(idx, (int64_t)o.list->size(), i, loc)) return indexRef(o, mkInt(i, T(TK::Int)), loc, true);
        }
        if (o.k == CtValue::List) {
            int64_t i = asInt(idx, loc);
            if (i < 0 || i >= (int64_t)o.list->size())
                fail(loc, "índice fuera de rango: " + std::to_string(i) + " (la lista tiene " + std::to_string(o.list->size()) + " elementos)");
            return &(*o.list)[(size_t)i];
        }
        if (o.k == CtValue::Str && !write) {
            int64_t i = asInt(idx, loc);
            if (i < 0 || i >= (int64_t)o.s.size())
                fail(loc, "índice fuera de rango: " + std::to_string(i) + " (la cadena tiene " + std::to_string(o.s.size()) + " bytes)");
            scratch_ = mkInt((unsigned char)o.s[(size_t)i], T(TK::Byte));
            return &scratch_;
        }
        fail(loc, "no se puede indexar " + kindName(o) + " en tiempo de compilación");
    }

    CtValue evalSwitchExpr(SwitchExpr* s) {
        CtValue v = eval(s->subject);
        for (auto& arm : s->arms) {
            env->scopes.emplace_back();
            bool ok = matches(arm.pat, v);
            if (ok && arm.guard) ok = truthy(eval(arm.guard), arm.guard->loc);
            if (ok) {
                CtValue r = eval(arm.value);
                env->scopes.pop_back();
                return r;
            }
            env->scopes.pop_back();
        }
        fail(s->loc, "ningún brazo del 'switch' coincide con " + toStr(v));
    }

    bool matches(Pattern* p, const CtValue& v) {
        switch (p->kind) {
            case PK::Discard: return true;
            case PK::Var:
                env->scopes.back()[p->name] = v;
                return true;
            case PK::Constant: {
                Type* tt;
                ClassDecl* tc;
                if (typeNameOf(p->value, tt, tc) && tt) return instanceOf(v, tt);  // 'a is Rango': un tipo
                return equal(v, eval(p->value));
            }
            case PK::Relational: {
                CtValue r = arith(v, eval(p->value), p->op, p->loc);
                return r.i != 0;
            }
            case PK::And: return matches(p->a, v) && matches(p->b, v);
            case PK::Or: return matches(p->a, v) || matches(p->b, v);
            case PK::Not: return !matches(p->a, v);
            case PK::Type: {  // Rango r  /  string s
                if (!instanceOf(v, resolve(p->tref))) return false;
                if (!p->name.empty() && p->name != "_") env->scopes.back()[p->name] = v;
                return true;
            }
            case PK::Property: {  // { Min: 0 } o Rango { Min: > 0 }
                if (v.k == CtValue::Null || (p->tref && !instanceOf(v, resolve(p->tref)))) return false;
                for (auto& [n, sub] : p->props)
                    if (!matches(sub, memberOf(v, n, sub->loc))) return false;
                if (!p->name.empty() && p->name != "_") env->scopes.back()[p->name] = v;
                return true;
            }
            default: fail(p->loc, "este patrón no se puede evaluar en tiempo de compilación");
        }
    }

    // ¿Es 'v' un valor del tipo 't'? (is / as / patrones de tipo)
    bool instanceOf(const CtValue& v, Type* t) {
        if (!t) return false;
        switch (v.k) {
            case CtValue::Null: case CtValue::Void: return false;
            case CtValue::Obj: return v.obj && v.obj->cls && t->decl && S.derivesFrom(v.obj->cls, t->decl);
            case CtValue::Str: return t->is(TK::String) || t->decl == S.objectDecl;
            case CtValue::Bool: return t->is(TK::Bool) || t->decl == S.objectDecl;
            case CtValue::Char: return t->is(TK::Char) || t->decl == S.objectDecl;
            case CtValue::Int: case CtValue::Float: return t == v.t || t->decl == S.objectDecl;
            case CtValue::List: return t->decl && isStd(t->decl, "std.collections", "List");
            default: return false;
        }
    }

    // sizeof al compilar: tipos primitivos, enums y structs formados por ellos (alineación natural de C).
    // 'align8': alineación de long y double dentro de un struct (8 en casi todas las plataformas, 4
    // en x86 de 32 bits); si el tamaño depende de ella, sizeof no se puede evaluar al compilar.
    void layoutOf(Type* t, SourceLoc loc, int64_t& size, int64_t& align, int align8 = 8, int depth = 0) {
        if (depth > 32) fail(loc, "sizeof: tipo anidado demasiado profundo");
        switch (t->kind) {
            case TK::Bool: case TK::SByte: case TK::Byte: size = align = 1; return;
            case TK::Short: case TK::UShort: size = align = 2; return;
            case TK::Char: case TK::Int: case TK::UInt: case TK::Float: case TK::Enum: size = align = 4; return;
            case TK::Long: case TK::ULong: case TK::Double:
                size = 8;
                align = align8;
                return;
            case TK::Struct: {
                if (!t->decl) break;
                S.resolveClassSignatures(t->decl);
                size = 0;
                align = 1;
                for (FieldDecl* f : t->decl->fields) {
                    if (f->isStatic() || f->mods.isConst) continue;
                    int64_t fs, fa;
                    layoutOf(f->type, loc, fs, fa, align8, depth + 1);
                    size = (size + fa - 1) / fa * fa + fs;
                    align = std::max(align, fa);
                }
                size = size == 0 ? 1 : (size + align - 1) / align * align;
                return;
            }
            default: break;
        }
        fail(loc, "sizeof(" + t->str() + ") depende de la plataforma de destino: no se puede evaluar en tiempo de compilación");
    }

    CtValue evalIs(IsExpr* e) {
        CtValue v = eval(e->operand);
        bool r;
        if (!e->tref && !e->preset) r = v.k == CtValue::Null;
        else {
            r = instanceOf(v, e->preset ? e->preset : resolve(e->tref));
            if (r && !e->varName.empty()) env->scopes.back()[e->varName] = v;
        }
        return CtValue::boolean(e->negate ? !r : r);
    }

    // ---------------------------------------------------------------- objetos

    void initFields(const std::shared_ptr<CtObj>& o, SourceLoc loc) {
        std::vector<ClassDecl*> chain = S.lookupChain(o->cls);
        std::reverse(chain.begin(), chain.end());
        for (ClassDecl* k : chain) {
            for (FieldDecl* f : k->fields) {
                if (f->isStatic()) continue;
                CtValue v;
                if (f->init) {
                    Sema::CtxSave save(S);
                    S.enter(k, nullptr);
                    if (f->file) S.ctx_.file = f->file;
                    Env e2;
                    e2.scopes.emplace_back();
                    e2.self = o;
                    Env* saved = env;
                    env = &e2;
                    try {
                        v = convert(eval(f->init), f->type, f->loc);
                    } catch (...) {
                        env = saved;
                        throw;
                    }
                    env = saved;
                } else {
                    v = defaultOf(f->type, loc);
                }
                o->fields[f->name] = v;
            }
        }
    }

    CtValue construct(ClassDecl* c, std::vector<CtValue> args, SourceLoc loc) {
        S.resolveClassSignatures(c);
        if (c->kind == ClassKind::Interface || c->mods.isAbstract)
            fail(loc, "no se puede crear una instancia de '" + c->displayName + "'");
        CtValue r;
        r.k = CtValue::Obj;
        grow(loc);
        r.obj = std::make_shared<CtObj>();
        r.obj->cls = c;
        initFields(r.obj, loc);
        if (c->ctors.empty()) {
            if (!args.empty()) fail(loc, "'" + c->displayName + "' no tiene un constructor con " + std::to_string(args.size()) + " argumento(s)");
            return r;
        }
        MethodDecl* ctor = pick(c->ctors, args, loc, "el constructor de '" + c->displayName + "'");
        runCtor(ctor, args, r.obj, loc);
        return r;
    }

    void runCtor(MethodDecl* ctor, std::vector<CtValue> args, const std::shared_ptr<CtObj>& self, SourceLoc loc) {
        if (ctor->ctorInit) {  // : base(...) / : this(...)
            Sema::CtxSave save(S);
            S.enter(ctor->owner, ctor);
            Env e2;
            e2.scopes.emplace_back();
            e2.self = self;
            for (size_t i = 0; i < ctor->params.size() && i < args.size(); i++)
                e2.scopes.back()[ctor->params[i].name] = convert(args[i], ctor->params[i].type, loc);
            Env* saved = env;
            env = &e2;
            std::vector<CtValue> ia;
            try {
                for (Expr* a : ctor->ctorInitArgs) ia.push_back(eval(a));
            } catch (...) {
                env = saved;
                throw;
            }
            env = saved;
            ClassDecl* target = ctor->ctorInit == 1 ? ctor->owner->base : ctor->owner;
            if (target && !target->ctors.empty()) runCtor(pick(target->ctors, ia, ctor->ctorInitLoc, "el constructor"), ia, self, ctor->ctorInitLoc);
        }
        callMethod(ctor, std::move(args), self, loc);
    }

    CtValue evalNew(NewExpr* n) {
        Type* t = resolve(n->tref);
        std::vector<CtValue> args;
        for (Expr* a : n->args) args.push_back(eval(a));
        if (t->isAggregate() && t->decl) {
            ClassDecl* c = t->decl;
            if (isStd(c, "std", "Array") || isStd(c, "std", "Array2D") || isStd(c, "std", "Array3D")) arrayUnsupported(n->loc);
            if (isStd(c, "std.collections", "List")) {
                CtValue l = mkList(c->typeArgs.empty() ? nullptr : c->typeArgs[0]);
                if (args.size() == 1 && args[0].k == CtValue::List) *l.list = *args[0].list;
                return l;
            }
            if (isStd(c, "std.text", "StringBuilder")) {
                CtValue r;
                r.k = CtValue::Obj;
                r.obj = std::make_shared<CtObj>();
                r.obj->cls = c;
                r.obj->fields["__sb"] = CtValue::str("");
                return r;
            }
            if (c->ns.rfind("std", 0) == 0 && c->ns != "std" && !S.derivesFrom(c, attributeBase()))
                fail(n->loc, "'" + c->displayName + "' de la biblioteca estándar no se puede usar en tiempo de compilación");
            return construct(c, std::move(args), n->loc);
        }
        if (args.empty()) return defaultOf(t, n->loc);
        fail(n->loc, "no se puede crear '" + t->str() + "' en tiempo de compilación");
    }

    ClassDecl* attributeBase() {
        NamespaceSym* ns = S.findNs({"std"});
        if (!ns) return nullptr;
        auto it = ns->types.find("Attribute");
        return it == ns->types.end() ? nullptr : it->second;
    }

    // ---------------------------------------------------------------- llamadas

    // Elige la sobrecarga según los valores de los argumentos.
    MethodDecl* pick(const std::vector<MethodDecl*>& cands, std::vector<CtValue>& args, SourceLoc loc, const std::string& what) {
        MethodDecl* best = nullptr;
        int bestCost = INT_MAX;
        for (MethodDecl* m : cands) {
            if (m->isTemplate()) continue;
            S.resolveMethodSignature(m);
            size_t n = m->params.size();
            bool pack = n > 0 && m->params.back().isParams && !(args.size() == n && args.back().k == CtValue::List);
            if (pack ? args.size() + 1 < n : args.size() != n) continue;
            int cost = 0;
            for (size_t i = 0; i < args.size() && cost < 1000; i++) {
                Type* p = i < n ? m->params[i].type : nullptr;
                if (pack && i + 1 >= n) p = m->params.back().type && m->params.back().type->decl && !m->params.back().type->decl->typeArgs.empty()
                                                 ? m->params.back().type->decl->typeArgs[0] : nullptr;
                cost += argCost(args[i], p);
            }
            if (pack) cost += 5;
            if (cost < bestCost) best = m, bestCost = cost;
        }
        if (!best || bestCost >= 1000) {
            std::string a;
            for (size_t i = 0; i < args.size(); i++) a += (i ? ", " : "") + kindName(args[i]);
            fail(loc, (what.rfind("el ", 0) == 0 ? "ninguna sobrecarga d" + what : "ninguna sobrecarga de " + what) + " acepta (" + a + ") en tiempo de compilación");
        }
        if (best->params.size() && best->params.back().isParams && !(args.size() == best->params.size() && args.back().k == CtValue::List)) {
            size_t n = best->params.size();
            Type* lt = best->params.back().type;
            CtValue l = mkList(lt && lt->decl && !lt->decl->typeArgs.empty() ? lt->decl->typeArgs[0] : nullptr);
            for (size_t i = n - 1; i < args.size(); i++) l.list->push_back(args[i]);
            args.resize(n - 1);
            args.push_back(l);
        }
        return best;
    }

    int argCost(const CtValue& v, Type* p) {
        if (!p) return 1;
        switch (v.k) {
            case CtValue::Int:
                if (p == v.t) return 0;
                if (p->isEnum() || v.t->isEnum()) return 1000;
                if (p->isIntegral()) return ctRank(p) >= ctRank(v.t) ? 1 + ctRank(p) - ctRank(v.t) : 500;
                if (p->isFloating()) return 10;
                return 1000;
            case CtValue::Float: return p->isFloating() ? (p == v.t ? 0 : 1) : 1000;
            case CtValue::Char: return p->is(TK::Char) ? 0 : p->isIntegral() ? 3 : p->isFloating() ? 10 : 1000;
            case CtValue::Bool: return p->is(TK::Bool) ? 0 : 1000;
            case CtValue::Str: return p->is(TK::String) ? 0 : 1000;
            case CtValue::Null: return p->isRefLike() || p->is(TK::String) || (p->decl && isStd(p->decl, "std", "Nullable")) ? 1 : 1000;
            case CtValue::List: return p->decl && isStd(p->decl, "std.collections", "List") ? 0 : 1000;
            case CtValue::Obj:
                if (!p->decl || !v.obj) return 1000;
                if (p->decl == v.obj->cls) return 0;
                return S.derivesFrom(v.obj->cls, p->decl) ? 2 : 1000;
            case CtValue::TypeV: return p->decl && p->decl == S.typeDecl ? 0 : 1000;
            default: return 1000;
        }
    }

    CtValue callMethod(MethodDecl* m, std::vector<CtValue> args, std::shared_ptr<CtObj> self, SourceLoc loc) {
        if (m->isTemplate()) fail(loc, "las funciones genéricas no se pueden llamar en tiempo de compilación ('" + m->name + "')");
        if (!m->body)
            fail(loc, "'" + methodLabel(m) + "' no tiene cuerpo (es nativa, abstracta o externa): no se puede ejecutar en tiempo de compilación");
        if (m->mods.isAsync) fail(loc, "los métodos 'async' no se pueden ejecutar en tiempo de compilación");
        if ((int)st.stack.size() >= kCtMaxDepth)
            fail(loc, "recursión demasiado profunda en tiempo de compilación (límite: " + std::to_string(kCtMaxDepth) + " llamadas anidadas)");
        S.resolveMethodSignature(m);
        if (!self && !m->isStatic() && m->kind != MethodKind::Ctor) {
            if (env->self && S.derivesFrom(env->self->cls, m->owner)) self = env->self;
            else fail(loc, "el método de instancia '" + m->name + "' necesita un objeto en tiempo de compilación");
        }
        if (self && m->isVirtualish() && self->cls != m->owner) {  // despacho virtual
            for (ClassDecl* k : S.lookupChain(self->cls)) {
                bool found = false;
                for (MethodDecl* o : k->methods)
                    if (o->name == m->name && o->kind == m->kind && o->params.size() == m->params.size() && o->body &&
                        (o->mods.isOverride || o == m)) {
                        m = o;
                        found = true;
                        break;
                    }
                if (found) break;
            }
        }
        st.stack.push_back({methodLabel(m), loc});
        Sema::CtxSave save(S);
        S.enter(m->owner, m);
        Env e2;
        e2.fn = m;
        e2.self = self;
        e2.scopes.emplace_back();
        for (size_t i = 0; i < m->params.size(); i++) {
            if (m->params[i].isRef()) fail(loc, "los parámetros 'ref'/'out' no se admiten en tiempo de compilación");
            e2.scopes.back()[m->params[i].name] = i < args.size() ? convert(args[i], m->params[i].type, loc) : CtValue();
        }
        Env* saved = env;
        env = &e2;
        try {
            exec(m->body);
        } catch (...) {
            env = saved;
            throw;
        }
        env = saved;
        st.stack.pop_back();
        if (m->kind == MethodKind::Ctor || !m->ret || m->ret->isVoid()) return CtValue();
        return convert(e2.ret, m->ret, loc);
    }

    std::vector<CtValue> evalArgs(CallExpr* c, size_t skip) {
        std::vector<CtValue> out;
        for (size_t i = skip; i < c->args.size(); i++) {
            Expr* a = c->args[i];
            if (a->kind == EK::ParamsList && i + 1 == c->args.size()) {  // params ya empaquetados por Sema
                for (Expr* it : static_cast<ParamsListExpr*>(a)->items) out.push_back(eval(it));
                continue;
            }
            out.push_back(eval(a));
        }
        return out;
    }

    CtValue evalCall(CallExpr* c) {
        step(c->loc);
        Expr* callee = c->callee;
        if (callee->kind == EK::Name) {
            auto* n = static_cast<NameExpr*>(callee);
            if (CtValue* v = findLocal(n->name)) fail(c->loc, "'" + n->name + "' no se puede invocar (" + kindName(*v) + ")");
            std::vector<CtValue> args = evalArgs(c, 0);
            if (env->self) {
                std::vector<MethodDecl*> grp = S.findMethods(env->self->cls, n->name);
                if (!grp.empty()) {
                    MethodDecl* m = pick(grp, args, c->loc, "'" + n->name + "'");
                    return callMethod(m, args, m->isStatic() ? nullptr : env->self, c->loc);
                }
            }
            CtValue g = evalName(n);
            if (g.k != CtValue::Group) fail(c->loc, "'" + n->name + "' no es una función");
            MethodDecl* m = pick(g.group, args, c->loc, "'" + n->name + "'");
            if (CtValue r; builtinStatic(m->owner, n->name, args, c->loc, r)) return r;
            return callMethod(m, args, nullptr, c->loc);
        }
        if (callee->kind != EK::Member) fail(c->loc, "esta llamada no se puede evaluar en tiempo de compilación");
        auto* me = static_cast<MemberExpr*>(callee);
        // Llamada estática: Tipo.Metodo(...)
        Type* tt;
        ClassDecl* tc;
        if (typeNameOf(me->obj, tt, tc)) {
            std::vector<CtValue> args = evalArgs(c, me->extension ? 1 : 0);
            ClassDecl* cls = tc ? tc : (tt && tt->decl ? tt->decl : nullptr);
            CtValue r;
            if (builtinStatic(cls, me->name, args, c->loc, r, tt)) return r;
            if (!cls) fail(c->loc, "'" + (tt ? tt->str() : std::string("?")) + "." + me->name + "' no se puede evaluar en tiempo de compilación");
            std::vector<MethodDecl*> grp = S.findMethods(cls, me->name);
            if (grp.empty()) fail(c->loc, "'" + cls->displayName + "' no tiene un método '" + me->name + "'");
            MethodDecl* m = pick(grp, args, c->loc, "'" + cls->displayName + "." + me->name + "'");
            return callMethod(m, args, nullptr, c->loc);
        }
        CtValue recv = eval(me->obj);
        std::vector<CtValue> args = evalArgs(c, me->extension ? 1 : 0);
        return callOn(recv, me, args, c);
    }

    // ---------------------------------------------------------------- reflexión

    std::vector<CtValue> dataMembers(Type* t, bool fields, bool props) {
        std::vector<CtValue> out;
        if (!t || !t->isAggregate() || !t->decl) return out;
        ClassDecl* c = t->decl;
        S.resolveClassSignatures(c);
        std::vector<ClassDecl*> chain = S.lookupChain(c);
        std::reverse(chain.begin(), chain.end());
        for (ClassDecl* k : chain) {
            if (k == S.objectDecl) continue;
            std::vector<CtValue> mine;
            if (fields)
                for (FieldDecl* f : k->fields) {
                    if (f->isStatic() || f->mods.access != Access::Public || f->isEvent || endsWith(f->name, "__valor")) continue;
                    CtValue v;
                    v.k = CtValue::Member;
                    v.s = f->name;
                    v.t = f->type;
                    v.field = f;
                    v.owner = k;
                    mine.push_back(v);
                }
            if (props)
                for (MethodDecl* m : k->methods) {
                    if (m->kind != MethodKind::Getter || m->isStatic() || m->mods.access != Access::Public || !m->params.empty())
                        continue;
                    if (m->name.find('.') != std::string::npos) continue;  // implementación explícita de interfaz
                    S.resolveMethodSignature(m);
                    CtValue v;
                    v.k = CtValue::Member;
                    v.s = m->name;
                    v.t = m->ret;
                    v.getter = m;
                    v.setter = S.FindSetter(m);
                    if (v.setter && v.setter->mods.access != Access::Public) v.setter = nullptr;
                    v.owner = k;
                    mine.push_back(v);
                }
            std::stable_sort(mine.begin(), mine.end(), [](const CtValue& a, const CtValue& b) {
                SourceLoc la = a.field ? a.field->loc : a.getter->loc, lb = b.field ? b.field->loc : b.getter->loc;
                return locLess(la, lb);
            });
            for (CtValue& v : mine) out.push_back(v);
        }
        for (size_t i = 0; i < out.size(); i++) out[i].index = (int)i;
        return out;
    }

    CtValue listOf(std::vector<CtValue> items) {
        CtValue l = mkList(nullptr);
        *l.list = std::move(items);
        return l;
    }

    std::vector<Attribute>* attrsOf(const CtValue& v, ClassDecl*& ctxCls, FileScope*& file, int& target) {
        ctxCls = v.owner;
        file = nullptr;
        switch (v.k) {
            case CtValue::TypeV:
                if (!v.t || !v.t->decl) return nullptr;
                ctxCls = v.t->decl;
                file = v.t->decl->file;
                target = v.t->decl->kind == ClassKind::Struct ? kTgStruct : v.t->decl->kind == ClassKind::Enum ? kTgEnum
                         : v.t->decl->kind == ClassKind::Interface ? kTgInterface : kTgClass;
                return &v.t->decl->attrs;
            case CtValue::Member:
                if (v.field) {
                    file = v.field->file;
                    target = kTgField;
                    return &v.field->attrs;
                }
                file = v.getter->file;
                target = kTgProperty;
                return &v.getter->attrs;
            case CtValue::Method:
                file = v.method->file;
                target = v.method->kind == MethodKind::Ctor ? kTgConstructor : kTgMethod;
                ctxCls = v.method->owner;
                return &v.method->attrs;
            case CtValue::Param:
                file = v.method->file;
                target = kTgParameter;
                ctxCls = v.method->owner;
                return &v.method->params[(size_t)v.index].attrs;
            default: return nullptr;
        }
    }

    std::vector<CtValue> attributeValues(const CtValue& v, ClassDecl* filter) {
        std::vector<CtValue> out;
        ClassDecl* ctxCls;
        FileScope* file;
        int target = 0;
        std::vector<Attribute>* attrs = attrsOf(v, ctxCls, file, target);
        if (!attrs) return out;
        S.attrResolveList(*attrs, target, ctxCls, file);
        for (Attribute& a : *attrs) {
            auto it = st.attrObjs.find(&a);
            if (!a.cls || it == st.attrObjs.end()) continue;
            if (filter && !S.derivesFrom(a.cls, filter)) continue;
            CtValue r;
            r.k = CtValue::Obj;
            r.obj = it->second;
            out.push_back(r);
        }
        return out;
    }

    ClassDecl* attrFilter(MemberExpr* me, SourceLoc loc) {
        if (me->typeArgs.size() != 1) fail(loc, "'" + me->name + "' necesita el tipo del atributo: " + me->name + "<MiAtributo>()");
        Type* t = resolve(me->typeArgs[0]);
        if (!t->decl) fail(loc, "'" + t->str() + "' no es una clase de atributo");
        return t->decl;
    }

    bool isReflectHandle(const CtValue& v) {
        return v.k == CtValue::TypeV || v.k == CtValue::Member || v.k == CtValue::Method || v.k == CtValue::Param;
    }

    Type* typeArg(Type* t, size_t i) {
        if (!t || !t->decl || t->decl->typeArgs.size() <= i) return nullptr;
        return t->decl->typeArgs[i];
    }

    // Consultas sobre un tipo: Tipo<T>.Nombre, .Campos, .EsLista, .Elemento...
    bool typeQuery(Type* t, const std::string& name, SourceLoc loc, CtValue& r) {
        ClassDecl* d = t->isAggregate() || t->isEnum() ? t->decl : nullptr;
        if (d) S.resolveClassSignatures(d);
        ClassDecl* td = d && d->templateOf ? d->templateOf : d;
        auto B = [&](bool b) {
            r = CtValue::boolean(b);
            return true;
        };
        auto Ty = [&](Type* x) {
            r = x ? CtValue::type(x) : CtValue::null();
            return true;
        };
        if (name == "Nombre") {
            r = CtValue::str(d ? d->displayName : t->str());
            return true;
        }
        if (name == "NombreCompleto") {
            r = CtValue::str(d && !d->ns.empty() ? d->ns + "." + d->displayName : (d ? d->displayName : t->str()));
            return true;
        }
        if (name == "Namespace") {
            r = CtValue::str(d ? d->ns : "");
            return true;
        }
        if (name == "EsClase") return B(t->isClass() && d && d->kind == ClassKind::Class);
        if (name == "EsStruct") return B(t->isStruct() && !(d && isStd(d, "std", "Nullable")) && !(d && d->isTuple));
        if (name == "EsEnum") return B(t->isEnum());
        if (name == "TieneToString") return B(S.toStringable(t));  // $"{x}" y "a" + x funcionan con ese tipo
        if (name == "EsInterfaz") return B(d && d->isInterface());
        if (name == "EsRegistro") return B(d && d->isRecord);
        if (name == "EsAbstracta") return B(d && (d->mods.isAbstract || d->isInterface()));
        if (name == "EsSellada") return B(d && d->mods.isSealed);
        if (name == "EsTupla") return B(d && d->isTuple);
        if (name == "EsGenerico") return B(d && d->templateOf);
        if (name == "EsPrimitivo") return B(t->isNumeric() || t->is(TK::Bool));
        if (name == "EsNumerico") return B(t->isNumeric() && !t->is(TK::Char));
        if (name == "EsEntero") return B(t->isIntegral() && !t->is(TK::Char));
        if (name == "EsDecimal") return B(t->isFloating());
        if (name == "EsTexto") return B(t->is(TK::String));
        if (name == "EsBool") return B(t->is(TK::Bool));
        if (name == "EsChar") return B(t->is(TK::Char));
        if (name == "EsPuntero") return B(t->isPointer());
        if (name == "EsVoid") return B(t->isVoid());
        if (name == "EsDelegado") return B(t->isDelegate());
        if (name == "EsReferencia") return B(t->isRefLike());
        if (name == "EsValor") return B(!t->isRefLike() && !t->isVoid());
        if (name == "EsLista") return B(td && isStd(td, "std.collections", "List"));
        if (name == "EsDiccionario") return B(td && isStd(td, "std.collections", "Dictionary"));
        if (name == "EsConjunto") return B(td && isStd(td, "std.collections", "HashSet"));
        if (name == "EsArreglo") return B(td && isStd(td, "std", "Array"));  // T[] (std.Array<T>)
        if (name == "EsNullable") return B(td && isStd(td, "std", "Nullable"));
        if (name == "TieneConstructorVacio") return B(d && (d->ctors.empty() || Sema::paramlessCtor(d)) && !d->isInterface() && !d->mods.isAbstract);
        if (name == "Elemento") {
            if (t->isPointer()) return Ty(t->elem);
            if (td && (isStd(td, "std.collections", "Dictionary"))) return Ty(nullptr);
            return Ty(typeArg(t, 0));
        }
        if (name == "Clave") return Ty(td && isStd(td, "std.collections", "Dictionary") ? typeArg(t, 0) : nullptr);
        if (name == "Valor") return Ty(td && isStd(td, "std.collections", "Dictionary") ? typeArg(t, 1) : nullptr);
        if (name == "Subyacente") return Ty(t->isEnum() ? T(TK::Int) : (td && isStd(td, "std", "Nullable")) ? typeArg(t, 0) : nullptr);
        if (name == "Base") return Ty(d && d->base && d->base != S.objectDecl ? d->base->type : nullptr);
        if (name == "ArgumentosGenericos") {
            std::vector<CtValue> l;
            if (d)
                for (Type* a : d->typeArgs) l.push_back(CtValue::type(a));
            r = listOf(l);
            return true;
        }
        if (name == "Interfaces") {
            std::vector<CtValue> l;
            if (d)
                for (ClassDecl* i : d->allInterfaces) l.push_back(CtValue::type(i->type));
            r = listOf(l);
            return true;
        }
        if (name == "Campos" || name == "Propiedades" || name == "Miembros") {
            r = listOf(dataMembers(t, name != "Propiedades", name != "Campos"));
            return true;
        }
        if (name == "Metodos" || name == "Constructores") {
            std::vector<CtValue> l;
            if (d) {
                std::vector<ClassDecl*> chain = S.lookupChain(d);
                std::reverse(chain.begin(), chain.end());
                for (ClassDecl* k : chain) {
                    if (k == S.objectDecl) continue;
                    const std::vector<MethodDecl*>& src = name == "Metodos" ? k->methods : k->ctors;
                    for (MethodDecl* m : src) {
                        if (name == "Metodos" && (m->kind != MethodKind::Normal || m->isTemplate() || m->ctTemplate() || m->recordGen)) continue;
                        if (m->mods.access != Access::Public || (name == "Constructores" && k != d)) continue;
                        S.resolveMethodSignature(m);
                        CtValue v;
                        v.k = CtValue::Method;
                        v.s = m->name;
                        v.t = m->ret;
                        v.method = m;
                        v.owner = k;
                        v.index = (int)l.size();
                        l.push_back(v);
                    }
                }
            }
            r = listOf(l);
            return true;
        }
        if (name == "Valores") {
            std::vector<CtValue> l;
            if (t->isEnum())
                for (size_t i = 0; i < d->enumMembers.size(); i++) {
                    CtValue v;
                    v.k = CtValue::EnumItem;
                    v.s = d->enumMembers[i].name;
                    v.i = d->enumMembers[i].val;
                    v.owner = d;
                    v.t = t;
                    v.index = (int)i;
                    l.push_back(v);
                }
            r = listOf(l);
            return true;
        }
        if (name == "Atributos") {
            r = listOf(attributeValues(CtValue::type(t), nullptr));
            return true;
        }
        return false;
    }

    CtValue memberOf(const CtValue& v, const std::string& name, SourceLoc loc) {
        CtValue r;
        switch (v.k) {
            case CtValue::Str:
                if (name == "Length") return mkInt((int64_t)v.s.size(), T(TK::Int));
                break;
            case CtValue::List:
                if (name == "Count") return mkInt((int64_t)v.list->size(), T(TK::Int));
                break;
            case CtValue::TypeV:
                if (typeQuery(v.t, name, loc, r)) return r;
                fail(loc, "los tipos no tienen '" + name + "' en tiempo de compilación (consultas: Nombre, Campos, "
                          "Propiedades, Miembros, Metodos, Atributos, EsClase, EsStruct, EsEnum, EsLista, EsDiccionario, "
                          "EsNullable, Elemento, Clave, Valor, Base...)");
            case CtValue::Member:
                if (name == "Nombre") return CtValue::str(v.s);
                if (name == "Tipo") return CtValue::type(v.t);
                if (name == "EsCampo") return CtValue::boolean(v.field != nullptr);
                if (name == "EsPropiedad") return CtValue::boolean(v.getter != nullptr);
                if (name == "PuedeLeer") return CtValue::boolean(true);
                if (name == "PuedeEscribir")
                    return CtValue::boolean(v.field ? !(v.field->mods.isReadonly || v.field->mods.isConst) : v.setter != nullptr);
                if (name == "SoloLectura")
                    return CtValue::boolean(v.field ? (v.field->mods.isReadonly || v.field->mods.isConst) : v.setter == nullptr);
                if (name == "Indice") return mkInt(v.index, T(TK::Int));
                if (name == "DeclaradoEn") return CtValue::type(v.owner->type);
                if (name == "Atributos") return listOf(attributeValues(v, nullptr));
                break;
            case CtValue::Method:
                if (name == "Nombre") return CtValue::str(v.s);
                if (name == "Retorno") return CtValue::type(v.method->ret);
                if (name == "EsEstatico") return CtValue::boolean(v.method->isStatic());
                if (name == "EsVirtual") return CtValue::boolean(v.method->isVirtualish());
                if (name == "EsInvocable") {  // se puede llamar con InvocarLista (sin ref/out ni punteros)
                    bool ok = !v.method->isTemplate() && !v.method->variadic && !v.method->mods.isExtern &&
                              !v.method->unsafeApi && !(v.method->ret && v.method->ret->isPointer());
                    for (Param& p : v.method->params) ok &= !p.isRef() && p.type && !p.type->isPointer() && !p.isParams;
                    if (v.method->isStatic() && v.method->owner->templateOf) ok = false;
                    return CtValue::boolean(ok);
                }
                if (name == "Indice") return mkInt(v.index, T(TK::Int));
                if (name == "DeclaradoEn") return CtValue::type(v.owner->type);
                if (name == "Atributos") return listOf(attributeValues(v, nullptr));
                if (name == "Parametros") {
                    std::vector<CtValue> l;
                    for (size_t i = 0; i < v.method->params.size(); i++) {
                        CtValue p;
                        p.k = CtValue::Param;
                        p.s = v.method->params[i].name;
                        p.t = v.method->params[i].type;
                        p.method = v.method;
                        p.owner = v.owner;
                        p.index = (int)i;
                        l.push_back(p);
                    }
                    return listOf(l);
                }
                break;
            case CtValue::Param:
                if (name == "Nombre") return CtValue::str(v.s);
                if (name == "Tipo") return CtValue::type(v.t);
                if (name == "Indice") return mkInt(v.index, T(TK::Int));
                if (name == "Atributos") return listOf(attributeValues(v, nullptr));
                break;
            case CtValue::EnumItem:
                if (name == "Nombre") return CtValue::str(v.s);
                if (name == "Valor") return mkInt(v.i, v.t);
                if (name == "Entero") return mkInt(v.i, T(TK::Int));
                if (name == "Indice") return mkInt(v.index, T(TK::Int));
                break;
            case CtValue::Obj:
                if (v.obj) {
                    if (v.obj->fields.count("__sb") && name == "Length") return mkInt((int64_t)v.obj->fields["__sb"].s.size(), T(TK::Int));
                    auto f = v.obj->fields.find(name);
                    if (f != v.obj->fields.end()) return f->second;
                    if (MethodDecl* g = S.findGetter(v.obj->cls, name)) return callMethod(g, {}, v.obj, loc);
                }
                break;
            case CtValue::Int:
                if (v.t && v.t->isEnum()) break;
                break;
            default: break;
        }
        fail(loc, kindName(v) + " no tiene un miembro '" + name + "' en tiempo de compilación");
    }

    CtValue evalMember(MemberExpr* m) {
        Type* tt;
        ClassDecl* tc;
        if (typeNameOf(m->obj, tt, tc)) return staticMember(tt, tc, m->name, m->loc);
        // "Color Color" (como en C#): una propiedad o campo con el nombre de su propio tipo; Color.Verde
        // es el tipo si 'Verde' es un valor del enum o un miembro estático.
        if (m->obj->kind == EK::Name && S.ctx_.cls && !S.ctx_.cls->isNamespaceScope) {
            auto* n = static_cast<NameExpr*>(m->obj);
            FieldDecl* f = findLocal(n->name) ? nullptr : S.findField(S.ctx_.cls, n->name);
            MethodDecl* g = f || findLocal(n->name) ? nullptr : S.findGetter(S.ctx_.cls, n->name);
            Type* mt = f ? f->type : g ? g->ret : nullptr;
            if (mt && mt->decl && mt->decl->name == n->name) {
                ClassDecl* d = mt->decl;
                bool isStatic = false;
                for (EnumMember& em : d->enumMembers) isStatic |= em.name == m->name;
                if (FieldDecl* sf = S.findField(d, m->name)) isStatic |= sf->isStatic() || sf->mods.isConst;
                if (MethodDecl* sg = S.findGetter(d, m->name)) isStatic |= sg->isStatic();
                if (isStatic) return staticMember(mt, d, m->name, m->loc);
            }
        }
        CtValue o = eval(m->obj);
        if (o.k == CtValue::Null) fail(m->loc, "acceso a '" + m->name + "' sobre null en tiempo de compilación");
        if (m->name == "Value" && o.k != CtValue::Obj) return o;   // Nullable<T>.Value
        if (m->name == "HasValue") return CtValue::boolean(o.k != CtValue::Null);
        return memberOf(o, m->name, m->loc);
    }

    CtValue staticMember(Type* t, ClassDecl* c, const std::string& name, SourceLoc loc) {
        if (t && t->isIntegral() && (name == "MaxValue" || name == "MinValue")) {
            bool mx = name == "MaxValue";
            switch (t->kind) {
                case TK::SByte: return mkInt(mx ? INT8_MAX : INT8_MIN, t);
                case TK::Byte: return mkInt(mx ? UINT8_MAX : 0, t);
                case TK::Short: return mkInt(mx ? INT16_MAX : INT16_MIN, t);
                case TK::UShort: return mkInt(mx ? UINT16_MAX : 0, t);
                case TK::Int: return mkInt(mx ? INT32_MAX : INT32_MIN, t);
                case TK::UInt: return mkInt(mx ? UINT32_MAX : 0, t);
                case TK::Long: return mkInt(mx ? INT64_MAX : INT64_MIN, t);
                case TK::ULong: return mkInt(mx ? -1 : 0, t);
                case TK::Char: return mkChar(mx ? 0x10FFFF : 0);
                default: break;
            }
        }
        if (t && t->isFloating() && (name == "MaxValue" || name == "MinValue" || name == "Epsilon" || name == "NaN" ||
                                     name == "PositiveInfinity" || name == "NegativeInfinity")) {
            bool f = t->is(TK::Float);
            double v = name == "MaxValue" ? (f ? 3.40282347e38 : 1.7976931348623157e308)
                       : name == "MinValue" ? (f ? -3.40282347e38 : -1.7976931348623157e308)
                       : name == "Epsilon" ? (f ? 1.401298e-45 : 4.9406564584124654e-324)
                       : name == "NaN" ? NAN : name == "PositiveInfinity" ? INFINITY : -INFINITY;
            return mkFloat(v, t);
        }
        if (t && t->is(TK::String) && name == "Empty") return CtValue::str("");
        if (c) {
            S.resolveClassSignatures(c);
            if (c->kind == ClassKind::Enum) {
                for (EnumMember& m : c->enumMembers)
                    if (m.name == name) return mkInt(m.val, c->type);
                fail(loc, "el enum '" + c->displayName + "' no tiene el valor '" + name + "'");
            }
            if (FieldDecl* f = S.findField(c, name)) return staticField(f, loc);
            if (MethodDecl* g = S.findGetter(c, name)) {
                if (!g->isStatic()) fail(loc, "la propiedad '" + name + "' no es estática");
                return callMethod(g, {}, nullptr, loc);
            }
        }
        if (t && !c) {
            CtValue r;
            if (typeQuery(t, name, loc, r)) return r;
        }
        fail(loc, "'" + (c ? c->displayName : t ? t->str() : std::string("?")) + "." + name + "' no se puede evaluar en tiempo de compilación");
    }

    // ---------------------------------------------------------------- funciones integradas

    // Funciones de la biblioteca estándar que se ejecutan con código nativo (Math, cadenas...).
    bool builtinStatic(ClassDecl* c, const std::string& name, std::vector<CtValue>& a, SourceLoc loc, CtValue& r, Type* prim = nullptr) {
        std::string cls = c ? c->name : prim ? prim->str() : "";
        bool stdCls = c && (c->ns == "std" || c->ns.rfind("std.", 0) == 0);
        if (prim && !c) {
            if ((name == "Parse") && a.size() == 1 && a[0].k == CtValue::Str) {
                std::string s = a[0].s;
                if (prim->isIntegral()) {
                    char* end = nullptr;
                    long long v = std::strtoll(s.c_str(), &end, 10);
                    if (s.empty() || *end) fail(loc, prim->str() + ".Parse: '" + s + "' no es un número entero");
                    r = mkInt(v, prim);
                    return true;
                }
                if (prim->isFloating()) {
                    char* end = nullptr;
                    double v = std::strtod(s.c_str(), &end);
                    if (s.empty() || *end) fail(loc, prim->str() + ".Parse: '" + s + "' no es un número");
                    r = mkFloat(v, prim);
                    return true;
                }
            }
            if (prim->is(TK::Char)) cls = "Char";
            else if (prim->is(TK::String)) cls = "String";
            else return false;
            stdCls = true;
        }
        if (!stdCls) return false;
        auto num = [&](size_t i) { return asNum(a.at(i), loc); };
        auto isInt = [&](size_t i) { return a.at(i).k == CtValue::Int || a.at(i).k == CtValue::Char; };
        if (cls == "Math") {
            static const std::map<std::string, double (*)(double)> f1 = {
                {"Sqrt", std::sqrt}, {"Cbrt", std::cbrt}, {"Sin", std::sin}, {"Cos", std::cos}, {"Tan", std::tan},
                {"Asin", std::asin}, {"Acos", std::acos}, {"Atan", std::atan}, {"Sinh", std::sinh}, {"Cosh", std::cosh},
                {"Tanh", std::tanh}, {"Exp", std::exp}, {"Log", std::log}, {"Log2", std::log2}, {"Log10", std::log10},
                {"Floor", std::floor}, {"Ceiling", std::ceil}, {"Truncate", std::trunc}, {"Round", std::rint}};
            auto it = f1.find(name);
            if (it != f1.end() && a.size() == 1) {
                r = mkFloat(it->second(num(0)), T(TK::Double));
                return true;
            }
            if (name == "Pow" && a.size() == 2) return r = mkFloat(std::pow(num(0), num(1)), T(TK::Double)), true;
            if (name == "Atan2" && a.size() == 2) return r = mkFloat(std::atan2(num(0), num(1)), T(TK::Double)), true;
            if (name == "Hypot" && a.size() == 2) return r = mkFloat(std::hypot(num(0), num(1)), T(TK::Double)), true;
            if (name == "Mod" && a.size() == 2) return r = mkFloat(std::fmod(num(0), num(1)), T(TK::Double)), true;
            if (name == "Abs" && a.size() == 1) {
                if (isInt(0)) r = mkInt(a[0].i < 0 ? -a[0].i : a[0].i, a[0].k == CtValue::Char ? T(TK::Int) : a[0].t);
                else r = mkFloat(std::fabs(num(0)), T(TK::Double));
                return true;
            }
            if ((name == "Min" || name == "Max") && a.size() == 2) {
                bool mn = name == "Min";
                if (isInt(0) && isInt(1)) {
                    Type* t = ctRank(a[0].t) >= ctRank(a[1].t) ? a[0].t : a[1].t;
                    r = mkInt(mn ? std::min(a[0].i, a[1].i) : std::max(a[0].i, a[1].i), t);
                } else {
                    r = mkFloat(mn ? std::min(num(0), num(1)) : std::max(num(0), num(1)), T(TK::Double));
                }
                return true;
            }
            return false;  // el resto (Clamp, Gcd, IPow...) está escrito en Faset: se interpreta
        }
        if (cls == "Char") {
            if (a.size() != 1) return false;
            uint32_t ch = (uint32_t)asInt(a[0], loc);
            if (name == "IsDigit") return r = CtValue::boolean(ch >= '0' && ch <= '9'), true;
            if (name == "IsLetter") return r = CtValue::boolean((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch >= 0xC0), true;
            if (name == "IsUpper") return r = CtValue::boolean(ch >= 'A' && ch <= 'Z'), true;
            if (name == "IsLower") return r = CtValue::boolean(ch >= 'a' && ch <= 'z'), true;
            if (name == "IsWhiteSpace") return r = CtValue::boolean(ch == ' ' || (ch >= 9 && ch <= 13)), true;
            if (name == "ToUpper") return r = mkChar(ch >= 'a' && ch <= 'z' ? ch - 32 : ch), true;
            if (name == "ToLower") return r = mkChar(ch >= 'A' && ch <= 'Z' ? ch + 32 : ch), true;
            return false;
        }
        if (cls == "String") {
            if (name == "Concat") {
                std::string s;
                for (CtValue& v : a) s += toStr(v);
                return r = CtValue::str(s), true;
            }
            if ((name == "Copy") && a.size() == 1) return r = CtValue::str(toStr(a[0])), true;
            if (name == "FromInt" && a.size() == 1) return r = CtValue::str(toStr(a[0])), true;
            if (name == "FromDouble" && a.size() == 1) return r = CtValue::str(fmtDouble(num(0), false)), true;
            if (name == "Join" && a.size() == 2 && a[1].k == CtValue::List) return r = joinList(*a[1].list, toStr(a[0])), true;
            if (name == "IsNullOrEmpty" && a.size() == 1) return r = CtValue::boolean(a[0].k == CtValue::Null || toStr(a[0]).empty()), true;
            return false;
        }
        if (cls == "Text") {
            if (name == "Repeat" && a.size() == 2) {
                std::string s;
                for (int64_t i = 0; i < asInt(a[1], loc); i++) checkLen(s += asStr(a[0], loc), loc);
                return r = CtValue::str(s), true;
            }
            if (name == "Join" && a.size() == 2 && a[0].k == CtValue::List) return r = joinList(*a[0].list, asStr(a[1], loc)), true;
            if (name == "Replace" && a.size() == 3) return r = CtValue::str(checkLen(replaceAll(asStr(a[0], loc), asStr(a[1], loc), asStr(a[2], loc)), loc)), true;
            if (name == "Split" && a.size() == 2) return r = split(asStr(a[0], loc), asStr(a[1], loc)), true;
            if ((name == "PadLeft" || name == "PadRight") && a.size() == 3) {
                std::string s = asStr(a[0], loc);
                size_t w = (size_t)asInt(a[1], loc), len = codepoints(s).size();
                std::string pad;
                if (w > kCtMaxString) fail(loc, name + ": ancho demasiado grande en tiempo de compilación");
                for (size_t i = len; i < w; i++) pad += utf8((uint32_t)a[2].i);
                return r = CtValue::str(name == "PadLeft" ? pad + s : s + pad), true;
            }
            if (name == "Reverse" && a.size() == 1) {
                std::vector<uint32_t> cps = codepoints(asStr(a[0], loc));
                std::string s;
                for (size_t i = cps.size(); i-- > 0;) s += utf8(cps[i]);
                return r = CtValue::str(s), true;
            }
            if (name == "IsNullOrWhiteSpace" && a.size() == 1) {
                std::string s = toStr(a[0]);
                return r = CtValue::boolean(s.find_first_not_of(" \t\r\n\v\f") == std::string::npos), true;
            }
            return false;
        }
        if (cls == "Convert") {
            if (name == "ToString" && a.size() == 1) return r = CtValue::str(toStr(a[0])), true;
            if ((name == "ToInt32" || name == "ToInt64" || name == "ToDouble") && a.size() == 1 && a[0].k == CtValue::Str) {
                std::vector<CtValue> one = a;
                return builtinStatic(nullptr, "Parse", one, loc, r, T(name == "ToInt32" ? TK::Int : name == "ToInt64" ? TK::Long : TK::Double));
            }
            return false;
        }
        if (cls == "Int32" || cls == "Int64" || cls == "Double") {
            if (name == "Parse" && a.size() == 1)
                return builtinStatic(nullptr, "Parse", a, loc, r, T(cls == "Int32" ? TK::Int : cls == "Int64" ? TK::Long : TK::Double));
            return false;
        }
        return false;
    }

    CtValue joinList(const std::vector<CtValue>& l, const std::string& sep) {
        std::string s;
        for (size_t i = 0; i < l.size(); i++) s += (i ? sep : "") + toStr(l[i]);
        return CtValue::str(s);
    }
    static std::string replaceAll(std::string s, const std::string& from, const std::string& to) {
        if (from.empty()) return s;
        size_t p = 0;
        while ((p = s.find(from, p)) != std::string::npos) {
            s.replace(p, from.size(), to);
            p += to.size();
        }
        return s;
    }
    CtValue split(const std::string& s, const std::string& sep) {
        CtValue l = mkList(T(TK::String));
        if (sep.empty()) {
            l.list->push_back(CtValue::str(s));
            return l;
        }
        size_t start = 0, p;
        while ((p = s.find(sep, start)) != std::string::npos) {
            l.list->push_back(CtValue::str(s.substr(start, p - start)));
            start = p + sep.size();
        }
        l.list->push_back(CtValue::str(s.substr(start)));
        return l;
    }

    // Método sobre un valor: cadenas, listas, StringBuilder, reflexión y objetos del usuario.
    CtValue callOn(CtValue& recv, MemberExpr* me, std::vector<CtValue>& a, CallExpr* c) {
        const std::string& name = me->name;
        SourceLoc loc = c->loc;
        auto argc = [&](size_t n) {
            if (a.size() != n) fail(loc, "'" + name + "' espera " + std::to_string(n) + " argumento(s)");
        };
        if (name == "ToString" && a.empty() && recv.k != CtValue::Obj) return CtValue::str(toStr(recv));
        if (name == "Equals" && a.size() == 1 && recv.k != CtValue::Obj) return CtValue::boolean(equal(recv, a[0]));
        if (name == "GetHashCode" && recv.k != CtValue::Obj) fail(loc, "GetHashCode no está disponible en tiempo de compilación");
        if (recv.k == CtValue::Null) fail(loc, "llamada a '" + name + "' sobre null en tiempo de compilación");
        if (recv.k == CtValue::Str) {
            const std::string& s = recv.s;
            if (name == "Substring") {
                int64_t st0 = asInt(a.at(0), loc);
                int64_t n = a.size() > 1 ? asInt(a[1], loc) : (int64_t)s.size() - st0;
                if (st0 < 0 || n < 0 || st0 + n > (int64_t)s.size()) fail(loc, "Substring fuera de rango");
                return CtValue::str(s.substr((size_t)st0, (size_t)n));
            }
            if (name == "ToUpper" || name == "ToLower") {
                std::string o = s;
                for (char& ch : o) ch = name == "ToUpper" ? (char)std::toupper((unsigned char)ch) : (char)std::tolower((unsigned char)ch);
                return CtValue::str(o);
            }
            if (name == "Trim" || name == "TrimStart" || name == "TrimEnd") {
                const char* ws = " \t\r\n\v\f";
                size_t b = name == "TrimEnd" ? 0 : s.find_first_not_of(ws);
                if (b == std::string::npos) return CtValue::str("");
                size_t e = name == "TrimStart" ? s.size() : s.find_last_not_of(ws) + 1;
                return CtValue::str(s.substr(b, e - b));
            }
            if (name == "Contains") return argc(1), CtValue::boolean(s.find(asStr(a[0], loc)) != std::string::npos);
            if (name == "StartsWith") return argc(1), CtValue::boolean(s.rfind(asStr(a[0], loc), 0) == 0);
            if (name == "EndsWith") return argc(1), CtValue::boolean(endsWith(s, asStr(a[0], loc)));
            if (name == "IndexOf") {
                size_t from = a.size() > 1 ? (size_t)asInt(a[1], loc) : 0;
                size_t p = a.at(0).k == CtValue::Char ? s.find(utf8((uint32_t)a[0].i), from) : s.find(asStr(a[0], loc), from);
                return mkInt(p == std::string::npos ? -1 : (int64_t)p, T(TK::Int));
            }
            if (name == "LastIndexOf") {
                argc(1);
                size_t p = s.rfind(asStr(a[0], loc));
                return mkInt(p == std::string::npos ? -1 : (int64_t)p, T(TK::Int));
            }
            if (name == "Replace") return argc(2), CtValue::str(checkLen(replaceAll(s, asStr(a[0], loc), asStr(a[1], loc)), loc));
            if (name == "Split") return argc(1), split(s, a[0].k == CtValue::Char ? utf8((uint32_t)a[0].i) : asStr(a[0], loc));
            if (name == "IsEmpty") return CtValue::boolean(s.empty());
            if (name == "Equals") return argc(1), CtValue::boolean(s == asStr(a[0], loc));
            if (name == "CompareTo") {
                int cmp = s.compare(asStr(a.at(0), loc));
                return mkInt(cmp < 0 ? -1 : cmp > 0 ? 1 : 0, T(TK::Int));
            }
            if (name == "Count") {
                argc(1);
                const std::string& sub = asStr(a[0], loc);
                int64_t n = 0;
                for (size_t p = 0; !sub.empty() && (p = s.find(sub, p)) != std::string::npos; p += sub.size()) n++;
                return mkInt(n, T(TK::Int));
            }
            if (name == "ToInt" || name == "ToLong" || name == "ToDouble") {
                std::vector<CtValue> one = {recv};
                CtValue r;
                builtinStatic(nullptr, "Parse", one, loc, r, T(name == "ToInt" ? TK::Int : name == "ToLong" ? TK::Long : TK::Double));
                return r;
            }
            if (name == "PadLeft" || name == "PadRight") {
                std::vector<CtValue> three = {recv, a.at(0), a.size() > 1 ? a[1] : mkChar(' ')};
                CtValue r;
                ClassDecl fake;
                fake.name = "Text";
                fake.ns = "std.text";
                builtinStatic(&fake, name, three, loc, r);
                return r;
            }
        }
        if (recv.k == CtValue::List) {
            auto& l = *recv.list;
            if (name == "Add") return argc(1), grow(loc), l.push_back(recv.t ? convert(a[0], recv.t, loc) : copyStruct(a[0])), CtValue();
            if (name == "AddRange") {
                argc(1);
                if (a[0].k != CtValue::List) fail(loc, "AddRange espera una lista");
                std::vector<CtValue> items = *a[0].list;
                grow(loc, (long long)items.size());
                for (CtValue& v : items) l.push_back(v);
                return CtValue();
            }
            if (name == "Clear") return l.clear(), CtValue();
            if (name == "Insert") {
                argc(2);
                int64_t i = asInt(a[0], loc);
                if (i < 0 || i > (int64_t)l.size()) fail(loc, "Insert fuera de rango");
                grow(loc);
                l.insert(l.begin() + i, a[1]);
                return CtValue();
            }
            if (name == "RemoveAt") {
                argc(1);
                int64_t i = asInt(a[0], loc);
                if (i < 0 || i >= (int64_t)l.size()) fail(loc, "RemoveAt fuera de rango");
                l.erase(l.begin() + i);
                return CtValue();
            }
            if (name == "IndexOf" || name == "Contains" || name == "Remove") {
                argc(1);
                int64_t idx = -1;
                for (size_t i = 0; i < l.size(); i++)
                    if (equal(l[i], a[0])) {
                        idx = (int64_t)i;
                        break;
                    }
                if (name == "IndexOf") return mkInt(idx, T(TK::Int));
                if (name == "Contains") return CtValue::boolean(idx >= 0);
                if (idx >= 0) l.erase(l.begin() + idx);
                return CtValue::boolean(idx >= 0);
            }
            if (name == "Reverse") return std::reverse(l.begin(), l.end()), CtValue();
            if (name == "Sort" && a.empty()) {
                std::stable_sort(l.begin(), l.end(), [&](const CtValue& x, const CtValue& y) {
                    if (x.k == CtValue::Str && y.k == CtValue::Str) return x.s < y.s;
                    return asNum(x, loc) < asNum(y, loc);
                });
                return CtValue();
            }
            if (name == "Clone" || name == "ToList") {
                CtValue c2 = mkList(recv.t);
                grow(loc, (long long)l.size());
                *c2.list = l;
                return c2;
            }
            if (name == "Sum" || name == "Min" || name == "Max") {
                if (l.empty()) {
                    if (name == "Sum") return recv.t ? defaultOf(recv.t, loc) : mkInt(0, T(TK::Int));
                    fail(loc, name + " sobre una lista vacía");
                }
                CtValue acc = l[0];
                for (size_t i = 1; i < l.size(); i++) {
                    if (name == "Sum") acc = convert(arith(acc, l[i], "+", loc), recv.t ? recv.t : typeOfValue(acc), loc);
                    else if (truthy(arith(l[i], acc, name == "Min" ? "<" : ">", loc), loc)) acc = l[i];
                }
                return acc;
            }
        }
        if (recv.k == CtValue::Obj && recv.obj && recv.obj->fields.count("__sb")) {  // StringBuilder
            CtValue& sb = recv.obj->fields["__sb"];
            if (name == "Append") {
                for (CtValue& v : a) sb.s += toStr(v);
                checkLen(sb.s, loc);
                return recv;
            }
            if (name == "AppendLine") {
                for (CtValue& v : a) sb.s += toStr(v);
                sb.s += "\n";
                checkLen(sb.s, loc);
                return recv;
            }
            if (name == "AppendRepeat") {
                for (int64_t i = 0; i < asInt(a.at(1), loc); i++) checkLen(sb.s += asStr(a[0], loc), loc);
                return recv;
            }
            if (name == "Clear") return sb.s.clear(), CtValue();
            if (name == "ToString" || name == "View") return CtValue::str(sb.s);
        }
        if (isReflectHandle(recv)) {
            if (name == "TieneAtributo") return CtValue::boolean(!attributeValues(recv, attrFilter(me, loc)).empty());
            if (name == "Atributo") {
                std::vector<CtValue> l = attributeValues(recv, attrFilter(me, loc));
                return l.empty() ? CtValue::null() : l[0];
            }
            if (name == "AtributosDe") return listOf(attributeValues(recv, attrFilter(me, loc)));
            if (recv.k == CtValue::TypeV && recv.t && (name == "Implementa" || name == "DerivaDe")) {
                ClassDecl* f = attrFilter(me, loc);
                return CtValue::boolean(recv.t->decl && S.derivesFrom(recv.t->decl, f));
            }
            if (recv.k == CtValue::Member && name == "Get") {
                argc(1);
                return memberOf(a[0], recv.s, loc);
            }
            // c.Parametro("nombre"): el parámetro de ese nombre (sin distinguir mayúsculas, como System.Text.Json
            // al casar los parámetros de un constructor con las propiedades) o null.
            if (recv.k == CtValue::Method && name == "Parametro") {
                argc(1);
                if (a[0].k != CtValue::Str) fail(loc, "Parametro espera el nombre del parámetro (string)");
                auto lower = [](std::string x) {
                    for (char& ch : x) ch = (char)std::tolower((unsigned char)ch);
                    return x;
                };
                for (size_t i = 0; i < recv.method->params.size(); i++)
                    if (lower(recv.method->params[i].name) == lower(a[0].s)) {
                        CtValue p;
                        p.k = CtValue::Param;
                        p.s = recv.method->params[i].name;
                        p.t = recv.method->params[i].type;
                        p.method = recv.method;
                        p.owner = recv.owner;
                        p.index = (int)i;
                        return p;
                    }
                return CtValue::null();
            }
        }
        if (recv.k == CtValue::Int && recv.t && recv.t->isEnum() && name == "HasFlag")
            return argc(1), CtValue::boolean((recv.i & a[0].i) == a[0].i);
        if (recv.k == CtValue::Int || recv.k == CtValue::Float || recv.k == CtValue::Char) {
            if (name == "CompareTo") {
                argc(1);
                double x = asNum(recv, loc), y = asNum(a[0], loc);
                return mkInt(x < y ? -1 : x > y ? 1 : 0, T(TK::Int));
            }
        }
        if (recv.k == CtValue::Obj && recv.obj && recv.obj->cls) {
            std::vector<MethodDecl*> grp = S.findMethods(recv.obj->cls, name);
            if (!grp.empty()) {
                MethodDecl* m = pick(grp, a, loc, "'" + recv.obj->cls->displayName + "." + name + "'");
                return callMethod(m, a, m->isStatic() ? nullptr : recv.obj, loc);
            }
            if (name == "ToString") return CtValue::str(toStr(recv));
        }
        // Métodos de extensión del usuario (los de std sobre cadenas ya están arriba).
        if (c->target && c->target->isExtension() && c->target->owner &&
            !(c->target->owner->ns == "std" || c->target->owner->ns.rfind("std.", 0) == 0)) {
            std::vector<CtValue> all = a;
            all.insert(all.begin(), recv);
            return callMethod(c->target, all, nullptr, loc);
        }
        if (!c->target) {
            std::vector<MethodDecl*> ext = S.findExtensions(name);
            std::vector<MethodDecl*> user;
            for (MethodDecl* m : ext)
                if (!(m->owner->ns == "std" || m->owner->ns.rfind("std.", 0) == 0)) user.push_back(m);
            if (!user.empty()) {
                std::vector<CtValue> all = a;
                all.insert(all.begin(), recv);
                MethodDecl* m = pick(user, all, loc, "'" + name + "'");
                return callMethod(m, all, nullptr, loc);
            }
        }
        fail(loc, kindName(recv) + " no tiene un método '" + name + "' utilizable en tiempo de compilación");
    }

    // ---------------------------------------------------------------- sentencias

    Flow exec(Stmt* s) {
        step(s->loc);
        switch (s->kind) {
            case SK::Empty: return FNormal;
            case SK::Block: {
                env->scopes.emplace_back();
                for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) {
                    Flow f = exec(c);
                    if (f != FNormal) {
                        env->scopes.pop_back();
                        return f;
                    }
                }
                env->scopes.pop_back();
                return FNormal;
            }
            case SK::VarDecl: {
                auto* d = static_cast<VarDeclStmt*>(s);
                Type* t = d->tref->isVar() ? nullptr : resolve(d->tref);
                if (d->tref->isRef) fail(s->loc, "las referencias (T&) no se admiten en tiempo de compilación");
                for (auto& dc : d->decls) {
                    CtValue v = dc.init ? eval(dc.init) : defaultOf(t, dc.loc);
                    env->scopes.back()[dc.name] = t ? convert(v, t, dc.loc) : copyStruct(v);
                }
                return FNormal;
            }
            case SK::ComptimeVar: {
                auto* d = static_cast<ComptimeVarStmt*>(s);
                CtValue v = eval(d->init);
                env->scopes.back()[d->name] = d->tref->isVar() ? v : convert(v, resolve(d->tref), d->loc);
                return FNormal;
            }
            case SK::ExprStmt: {
                Expr* x = static_cast<ExprStmt*>(s)->expr;
                if (x->kind == EK::Call && static_cast<CallExpr*>(x)->callee->kind == EK::Name &&
                    static_cast<NameExpr*>(static_cast<CallExpr*>(x)->callee)->name == "static_assert") {
                    auto* c = static_cast<CallExpr*>(x);  // en una función que se está evaluando al compilar
                    if (c->args.empty() || c->args.size() > 2) fail(c->loc, "uso: static_assert(condición, \"mensaje\");");
                    if (!truthy(eval(c->args[0]), c->args[0]->loc))
                        fail(c->loc, "static_assert falló" + (c->args.size() == 2 ? ": " + toStr(eval(c->args[1])) : std::string()));
                    return FNormal;
                }
                eval(x);
                return FNormal;
            }
            case SK::If: {
                auto* is = static_cast<IfStmt*>(s);
                if (truthy(eval(is->cond), is->cond->loc)) return exec(is->then);
                return is->els ? exec(is->els) : FNormal;
            }
            case SK::ComptimeIf: {
                auto* is = static_cast<ComptimeIfStmt*>(s);
                if (truthy(eval(is->cond), is->cond->loc)) return exec(is->then);
                return is->els ? exec(is->els) : FNormal;
            }
            case SK::While: {
                auto* w = static_cast<WhileStmt*>(s);
                while (truthy(eval(w->cond), w->cond->loc)) {
                    step(w->loc);
                    Flow f = exec(w->body);
                    if (f == FBreak) break;
                    if (f == FReturn) return f;
                }
                return FNormal;
            }
            case SK::DoWhile: {
                auto* w = static_cast<DoWhileStmt*>(s);
                do {
                    step(w->loc);
                    Flow f = exec(w->body);
                    if (f == FBreak) break;
                    if (f == FReturn) return f;
                } while (truthy(eval(w->cond), w->cond->loc));
                return FNormal;
            }
            case SK::For: {
                auto* fs = static_cast<ForStmt*>(s);
                env->scopes.emplace_back();
                Flow out = FNormal;
                if (fs->initDecl) exec(fs->initDecl);
                for (Expr* e : fs->initExprs) eval(e);
                while (!fs->cond || truthy(eval(fs->cond), fs->cond->loc)) {
                    step(fs->loc);
                    Flow f = exec(fs->body);
                    if (f == FBreak) break;
                    if (f == FReturn) {
                        out = f;
                        break;
                    }
                    for (Expr* e : fs->iter) eval(e);
                }
                env->scopes.pop_back();
                return out;
            }
            case SK::Foreach: {
                auto* fe = static_cast<ForeachStmt*>(s);
                if (fe->name.empty()) fail(s->loc, "'foreach' con deconstrucción no se admite en tiempo de compilación");
                CtValue coll = eval(fe->coll);
                std::vector<CtValue> items;
                if (coll.k == CtValue::List) items = *coll.list;
                else if (coll.k == CtValue::Str)
                    for (uint32_t cp : codepoints(coll.s)) items.push_back(mkChar(cp));
                else fail(fe->coll->loc, "'foreach' en tiempo de compilación solo recorre listas y cadenas (no " + kindName(coll) + ")");
                Type* t = fe->tref && !fe->tref->isVar() ? resolve(fe->tref) : nullptr;
                for (CtValue& it : items) {
                    step(fe->loc);
                    env->scopes.emplace_back();
                    env->scopes.back()[fe->name] = t ? convert(it, t, fe->loc) : it;
                    Flow f = exec(fe->body);
                    env->scopes.pop_back();
                    if (f == FBreak) break;
                    if (f == FReturn) return f;
                }
                return FNormal;
            }
            case SK::ComptimeForeach: {
                auto* fe = static_cast<ComptimeForeachStmt*>(s);
                CtValue coll = eval(fe->coll);
                if (coll.k != CtValue::List) fail(fe->coll->loc, "'comptime foreach' recorre listas de tiempo de compilación");
                std::vector<CtValue> items = *coll.list;
                for (CtValue& it : items) {
                    env->scopes.emplace_back();
                    env->scopes.back()[fe->name] = it;
                    Flow f = exec(fe->body);
                    env->scopes.pop_back();
                    if (f == FBreak) break;
                    if (f == FReturn) return f;
                }
                return FNormal;
            }
            case SK::Break: return FBreak;
            case SK::Continue: return FContinue;
            case SK::Return: {
                auto* r = static_cast<ReturnStmt*>(s);
                env->ret = r->value ? eval(r->value) : CtValue();
                return FReturn;
            }
            case SK::Switch: {
                auto* sw = static_cast<SwitchStmt*>(s);
                CtValue v = eval(sw->subject);
                int chosen = -1;
                for (size_t i = 0; i < sw->sections.size() && chosen < 0; i++) {
                    auto& sec = sw->sections[i];
                    if (sec.labels.empty() && !sec.patterns.empty()) {
                        env->scopes.emplace_back();
                        for (size_t k = 0; k < sec.patterns.size() && chosen < 0; k++) {
                            if (!sec.patterns[k]) continue;
                            bool ok = matches(sec.patterns[k], v);
                            if (ok && k < sec.guards.size() && sec.guards[k]) ok = truthy(eval(sec.guards[k]), sec.guards[k]->loc);
                            if (ok) chosen = (int)i;
                        }
                        env->scopes.pop_back();
                    }
                    for (Expr* l : sec.labels)
                        if (equal(v, eval(l))) chosen = (int)i;
                }
                if (chosen < 0)
                    for (size_t i = 0; i < sw->sections.size(); i++)
                        if (sw->sections[i].hasDefault) chosen = (int)i;
                if (chosen < 0) return FNormal;
                env->scopes.emplace_back();
                for (Stmt* b : sw->sections[(size_t)chosen].body) {
                    Flow f = exec(b);
                    if (f == FBreak) break;
                    if (f != FNormal) {
                        env->scopes.pop_back();
                        return f;
                    }
                }
                env->scopes.pop_back();
                return FNormal;
            }
            case SK::Throw: {
                auto* t = static_cast<ThrowStmt*>(s);
                std::string msg = "se lanzó una excepción";
                if (t->value) {
                    CtValue v = eval(t->value);
                    if (v.k == CtValue::Obj && v.obj) {
                        auto it = v.obj->fields.find("Message");
                        if (it == v.obj->fields.end()) it = v.obj->fields.find("Message__valor");
                        msg = v.obj->cls->displayName + (it != v.obj->fields.end() ? ": " + toStr(it->second) : "");
                    }
                }
                fail(s->loc, msg);
            }
            case SK::Try: {
                auto* t = static_cast<TryStmt*>(s);
                Flow f = exec(t->body);
                if (t->finallyBody) exec(t->finallyBody);
                return f;
            }
            case SK::Delete: return FNormal;
            default: break;
        }
        if (s->kind == SK::ExprStmt) return FNormal;
        fail(s->loc, "esta sentencia no se puede ejecutar en tiempo de compilación");
    }

    // ---------------------------------------------------------------- entrada

    // Evalúa 'e' en el contexto actual de Sema. Informa del error (con la pila) y devuelve false.
    bool run(Expr* e, CtValue& out, const std::string& what = "") {
        long long savedSteps = st.steps, savedCells = st.cells;
        std::vector<CtFrame> savedStack = st.stack;
        st.steps = 0;
        st.cells = 0;
        st.stack.clear();
        bool ok = true;
        try {
            out = eval(e);
        } catch (CtError& err) {
            report(err, e->loc, what);
            ok = false;
        }
        st.steps = savedSteps;
        st.cells = savedCells;
        st.stack = savedStack;
        return ok;
    }

    // Como run, sin informar del error (¿se conoce el valor al compilar?).
    bool tryRun(Expr* e, CtValue& out) {
        long long savedSteps = st.steps, savedCells = st.cells;
        std::vector<CtFrame> savedStack = st.stack;
        st.steps = 0;
        st.cells = 0;
        st.stack.clear();
        bool ok = true;
        try {
            out = eval(e);
        } catch (CtError&) {
            ok = false;
        }
        st.steps = savedSteps;
        st.cells = savedCells;
        st.stack = savedStack;
        return ok;
    }

    void report(const CtError& err, SourceLoc site, const std::string& what) {
        diag.error(err.loc, (what.empty() ? "en tiempo de compilación: " : what + ": ") + err.msg);
        // Pila de llamadas, de la más interna a la más externa (en una recursión larga, solo los extremos).
        size_t n = err.stack.size();
        for (size_t i = n; i-- > 0;) {
            if (n > 12 && i + 6 < n && i >= 4) {
                if (i + 7 == n) diag.note(err.stack[i].callLoc, "... " + std::to_string(n - 10) + " llamadas más ...");
                continue;
            }
            diag.note(err.stack[i].callLoc, "en la llamada a '" + err.stack[i].what + "' (tiempo de compilación)");
        }
        if (!err.stack.empty() || err.loc.line != site.line || err.loc.file != site.file)
            diag.note(site, "evaluado en tiempo de compilación aquí");
    }
};

class CtHooks {
public:
    static bool bound(Sema& S, const std::string& name) {
        if (!S.ct_) return false;
        VarInfo* v = S.lookupLocal(name);
        return v && S.ct_->binds.count(v);
    }
    static void hoverRoot(Sema& S, Expr* e);  // IntelliSense (Comptime.cpp)
    static bool userTipo(Sema& S) {
        Sym s = S.lookupUnqualified("Tipo", SourceLoc());
        return s.kind == Sym::TypeK;
    }

    // Convierte un valor de tiempo de compilación en una expresión (sin comprobar) del programa.
    static Expr* toExpr(Sema& S, const CtValue& v, SourceLoc loc, std::string& err) {
        switch (v.k) {
            case CtValue::Bool: {
                auto* b = new BoolLitExpr(loc);
                b->value = v.i != 0;
                return b;
            }
            case CtValue::Str: {
                auto* s = new StringLitExpr(loc);
                s->value = v.s;
                return s;
            }
            case CtValue::Char: {
                auto* c = new CharLitExpr(loc);
                c->value = (uint32_t)v.i;
                return c;
            }
            case CtValue::Null: return new NullExpr(loc);
            case CtValue::Int: {
                Type* t = v.t ? v.t : S.tc_.get(TK::Int);
                bool uns = t->is(TK::ULong) || t->is(TK::UInt);
                bool neg = !uns && v.i < 0;
                auto* l = new IntLitExpr(loc);
                l->value = neg ? 0ull - (uint64_t)v.i : (uint64_t)v.i;
                if (t->is(TK::Long) || t->is(TK::ULong)) l->suffixL = true;
                if (uns) l->suffixU = true;
                Expr* e = l;
                if (neg) {
                    auto* u = new UnaryExpr(loc);
                    u->op = "-";
                    u->operand = l;
                    e = u;
                }
                bool plainInt = t->is(TK::Int) && v.i > INT32_MIN;
                bool plain = plainInt || t->is(TK::Long) || t->is(TK::ULong) || t->is(TK::UInt);
                if (t->is(TK::Long) && v.i == INT64_MIN) plain = false;
                if (!plain) {
                    auto* c = new CastExpr(loc);
                    c->tref = presetRef(t, loc);
                    c->operand = e;
                    e = c;
                }
                return e;
            }
            case CtValue::Float: {
                Type* t = v.t ? v.t : S.tc_.get(TK::Double);
                if (v.f != v.f || std::isinf(v.f)) {  // NaN e infinitos: 0.0/0.0, 1.0/0.0
                    auto* a = new FloatLitExpr(loc);
                    a->value = v.f != v.f ? 0.0 : (v.f > 0 ? 1.0 : -1.0);
                    auto* b = new FloatLitExpr(loc);
                    b->value = 0.0;
                    auto* d = new BinaryExpr(loc);
                    d->op = "/";
                    d->lhs = a;
                    d->rhs = b;
                    auto* c = new CastExpr(loc);
                    c->tref = presetRef(t, loc);
                    c->operand = d;
                    return c;
                }
                auto* l = new FloatLitExpr(loc);
                l->value = std::fabs(v.f);
                l->isFloat32 = t->is(TK::Float);
                if (std::signbit(v.f)) {
                    auto* u = new UnaryExpr(loc);
                    u->op = "-";
                    u->operand = l;
                    return u;
                }
                return l;
            }
            case CtValue::TypeV: {
                auto* t = new TypeOfExpr(loc);
                t->tref = presetRef(v.t, loc);
                return t;
            }
            case CtValue::List: {
                if (!v.t) {
                    err = "una lista de " + (v.list->empty() ? std::string("elementos de tipo desconocido") : kindName((*v.list)[0])) +
                          " solo existe en tiempo de compilación";
                    return nullptr;
                }
                auto* tr = new TypeRef();
                tr->loc = loc;
                tr->parts = {"std", "collections", "List"};
                tr->typeArgs = {presetRef(v.t, loc)};
                Type* lt = S.resolveType(tr);
                if (lt->isError() || !lt->decl) {
                    err = "no se pudo crear la lista (¿falta 'using std.collections;'?)";
                    return nullptr;
                }
                auto* pl = new ParamsListExpr(loc);
                for (const CtValue& it : *v.list) {
                    Expr* x = toExpr(S, it, loc, err);
                    if (!x) return nullptr;
                    S.checkValue(x);
                    S.coerce(x, v.t);
                    pl->items.push_back(x);
                }
                pl->type = lt;
                ClassDecl* c = lt->decl;
                for (size_t k = 0; k < c->ctors.size(); k++)
                    if (c->ctors[k]->params.size() == 1 && c->ctors[k]->params[0].type && c->ctors[k]->params[0].type->is(TK::Int)) {
                        pl->ctor = c->ctors[k];
                        pl->ctorIndex = k;
                    }
                for (MethodDecl* mm : c->methods)
                    if (mm->kind == MethodKind::Normal && mm->name == "Add" && mm->params.size() == 1) pl->add = mm;
                if (!pl->ctor || !pl->add) {
                    err = "List<T> no tiene List(int) y Add";
                    return nullptr;
                }
                S.useMethod(pl->ctor);
                S.useMethod(pl->add);
                return pl;
            }
            case CtValue::Member:
                err = "'" + v.s + "' es un miembro de tiempo de compilación: usa " + "f.Nombre, f.Tipo, f.Get(obj) o f.Set(obj, valor)";
                return nullptr;
            case CtValue::Obj: {
                // Un objeto de una clase o struct propio: se crea sin constructor con los valores de
                // todos sus campos (el constructor ya se ejecutó al compilar).
                ClassDecl* c = v.obj ? v.obj->cls : nullptr;
                if (!c || v.obj->attr || v.obj->fields.count("__sb") || S.isExceptionClass(c) ||
                    (c->kind != ClassKind::Class && c->kind != ClassKind::Struct) || isStd(c, "std.collections", "List")) {
                    err = "un objeto de '" + kindName(v) + "' solo existe en tiempo de compilación (usa sus campos, o a.Crear() en un atributo)";
                    return nullptr;
                }
                static thread_local std::vector<CtObj*> building;  // ciclos: a.Otro = b; b.Otro = a
                for (CtObj* o : building)
                    if (o == v.obj.get()) {
                        err = "el objeto de '" + c->displayName + "' calculado con comptime se refiere a sí mismo (un ciclo): no se puede escribir como constante";
                        return nullptr;
                    }
                building.push_back(v.obj.get());
                auto* w = new WithExpr(loc);
                w->blank = true;
                auto* d = new DefaultExpr(loc);
                d->tref = presetRef(c->type, loc);
                w->operand = d;
                bool ok = true;
                for (ClassDecl* k : S.lookupChain(c)) {
                    if (k == S.objectDecl) continue;
                    for (FieldDecl* f : k->fields) {
                        if (f->isStatic() || f->mods.isConst || f->staticCtor) continue;
                        auto it = v.obj->fields.find(f->name);
                        if (it == v.obj->fields.end()) continue;  // no se tocó: queda a cero (default)
                        Expr* x = toExpr(S, it->second, loc, err);
                        if (!x) {
                            ok = false;
                            break;
                        }
                        WithExpr::Init in;
                        in.loc = loc;
                        in.name = f->name;
                        in.value = x;
                        in.field = f;
                        w->inits.push_back(in);
                    }
                    if (!ok) break;
                }
                building.pop_back();
                return ok ? w : nullptr;
            }
            default:
                err = kindName(v) + " solo existe en tiempo de compilación";
                return nullptr;
        }
    }

    // e->lowered = constante con el valor; devuelve su tipo.
    static Type* lowerTo(Sema& S, Expr* e, const CtValue& v) {
        std::string err;
        Expr* x = toExpr(S, v, e->loc, err);
        if (!x) {
            diag.error(e->loc, err);
            return S.tc_.error();
        }
        e->lowered = x;
        if (x->kind == EK::ParamsList) return x->type;
        return S.checkValue(x);
    }
};
