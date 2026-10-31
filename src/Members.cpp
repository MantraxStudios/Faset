// Faset - métodos y construcción (análisis semántico).
//
// Parámetros opcionales y argumentos con nombre
//   void F(int x = 0, string s = "a", Color c = Color.Rojo);   F(s: "b");   F(1, c: Color.Azul);
//   El valor por defecto se comprueba una vez, en el contexto del método, y debe ser una constante
//   (literal, const, miembro de enum, null o default). En cada llamada, resolveOverload asocia los
//   argumentos con los parámetros (bindArgs): los posicionales por orden, los que tienen nombre por
//   nombre, y los que faltan toman su valor por defecto (el mismo nodo comprobado). Los argumentos
//   quedan en el orden de los parámetros; 'argPos' guarda su posición en el código para que
//   CodeGen los evalúe en ese orden (sequenceArgs). Reglas de C#: un argumento con nombre fuera de
//   su posición no puede ir seguido de argumentos sin nombre, y entre dos candidatos igual de
//   buenos gana el que no necesita valores por defecto.
//   [CallerMemberName], [CallerLineNumber] y [CallerFilePath] reciben el miembro, la línea y el
//   archivo de la llamada. Los valores por defecto no forman parte de los tipos delegado.
//
// Inicializadores de objeto y de colección
//   new T(args) { A = 1, B = { C = 2 }, [k] = v, 1, { "b", 2 } }  se reescribe como
//   (<t> = new T(args), <t>.A = 1, <t>.B.C = 2, <t>[k] = v, <t>.Add(1), <t>.Add("b", 2), <t>)
//   Cualquier tipo con un método Add admite inicializadores de colección.
//
// 'init' y 'required'
//   Una propiedad { get; init; } solo se asigna en un inicializador de objeto, en 'with' o en un
//   constructor (sobre 'this'). Los miembros 'required' deben asignarse en el inicializador de cada
//   'new' (salvo que el constructor tenga [SetsRequiredMembers]).
//
// Indizadores
//   T this[int i] { get; set; } son un 'get' y un 'set' llamados "this[]". a[i] se reescribe como
//   la llamada al 'get'; a[i] = v como la llamada al 'set'; a[i] op= v como
//   (<o> = a, <i> = i, <o>[<i>] = <o>[<i>] op v).
//
// out var
//   F(out var x) / F(out int x): declara la variable en el ámbito de la llamada (declareOutVars).
//
// Conversiones del usuario
//   public static implicit operator Celsius(double d) / explicit operator: se usan en asignaciones,
//   argumentos, retornos, conversiones explícitas y resolución de sobrecargas (cuestan más que
//   cualquier conversión estándar). Como en C#, la conversión puede ir precedida y seguida de una
//   conversión estándar implícita (int -> double -> Celsius).
#include <algorithm>
#include <cstdio>

#include "CodeGen.h"

namespace {

NameExpr* refTo(VarInfo* v, SourceLoc loc) {
    auto* n = new NameExpr(loc);
    n->name = v->name;
    return n;
}

MemberExpr* mkMember(Expr* obj, const std::string& name, SourceLoc loc) {
    auto* m = new MemberExpr(loc);
    m->obj = obj;
    m->name = name;
    m->nameLoc = loc;
    return m;
}

bool hasAttr(const std::vector<Attribute>& attrs, const char* name) {
    for (const Attribute& a : attrs)
        if (a.name == name) return true;
    return false;
}

// [int, string]: tipos de los índices de un indizador.
std::string indexTypes(const std::vector<Expr*>& args) {
    std::string s = "[";
    for (size_t i = 0; i < args.size(); i++) s += (i ? ", " : "") + (args[i]->type ? args[i]->type->str() : std::string("?"));
    return s + "]";
}

std::string methodName(MethodDecl* m) {
    if (m->kind == MethodKind::Ctor) return m->owner ? m->owner->displayName : m->name;
    if (m->name == "this[]") return (m->owner ? m->owner->displayName : std::string("")) + "[]";
    if (m->owner && !m->owner->isNamespaceScope) return m->owner->displayName + "." + m->name;
    return m->name;
}

// Texto de un valor por defecto para las firmas (IntelliSense): 0, "a", Color.Rojo, null...
std::string exprText(Expr* e) {
    if (!e) return "";
    switch (e->kind) {
        case EK::Cast: {
            auto* c = static_cast<CastExpr*>(e);
            if (c->implicit || !c->tref) return exprText(c->operand);
            return "(" + c->tref->str() + ")" + exprText(c->operand);
        }
        case EK::IntLit: return std::to_string(static_cast<IntLitExpr*>(e)->value);
        case EK::FloatLit: {
            char buf[64];
            std::snprintf(buf, sizeof buf, "%g", static_cast<FloatLitExpr*>(e)->value);
            std::string s = buf;
            if (s.find_first_of(".en") == std::string::npos) s += ".0";
            return s;
        }
        case EK::BoolLit: return static_cast<BoolLitExpr*>(e)->value ? "true" : "false";
        case EK::CharLit: {
            uint32_t c = static_cast<CharLitExpr*>(e)->value;
            if (c >= 32 && c < 127) return std::string("'") + (char)c + "'";
            return "'\\u" + std::to_string(c) + "'";
        }
        case EK::StringLit: return "\"" + static_cast<StringLitExpr*>(e)->value + "\"";
        case EK::Null: return "null";
        case EK::Default: {
            auto* d = static_cast<DefaultExpr*>(e);
            return d->tref ? "default(" + d->tref->str() + ")" : "default";
        }
        case EK::Name: return static_cast<NameExpr*>(e)->name;
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            return exprText(m->obj) + "." + m->name;
        }
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            return u->op + exprText(u->operand);
        }
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            return exprText(b->lhs) + " " + b->op + " " + exprText(b->rhs);
        }
        case EK::New: {
            auto* n = static_cast<NewExpr*>(e);
            return "new " + (n->tref ? n->tref->str() : std::string("")) + "()";
        }
        default: return e->lowered ? exprText(e->lowered) : "...";
    }
}

}  // namespace

// Llamada ya comprobada a un método (indizadores y conversiones).
static CallExpr* checkedCall(TypeCtx& tc, MethodDecl* m, Expr* recv, std::vector<Expr*> args, SourceLoc loc) {
    auto* callee = new NameExpr(loc);
    callee->name = m->name;
    callee->vk = ValKind::MethodGroup;
    callee->group = {m};
    callee->type = tc.get(TK::Void);
    auto* c = new CallExpr(loc);
    c->callee = callee;
    c->target = m;
    c->args = std::move(args);
    c->type = m->ret;
    if (!m->isStatic()) {
        c->receiver = recv;
        c->nonVirtual = recv && recv->kind == EK::Name && static_cast<NameExpr*>(recv)->ref == NameExpr::Ref::Base;
    }
    return c;
}

static Expr* implicitCast(Expr* e, Type* t) {
    auto* c = new CastExpr(e->loc);
    c->operand = e;
    c->implicit = true;
    c->type = t;
    return c;
}

bool Sema::isConversionOp(const MethodDecl* m) {
    return m->kind == MethodKind::Operator && (m->name == "operator implicit" || m->name == "operator explicit");
}

// ================================================================== parámetros opcionales

std::string Sema::paramDefaultText(const Param& p) {
    if (!p.defaultValue) return "";
    return " = " + exprText(p.defaultValue);
}

void Sema::flushParamDefaults() {
    defaultsReady_ = true;
    std::vector<MethodDecl*> pend;
    pend.swap(pendingDefaults_);
    for (MethodDecl* m : pend) resolveParamDefaults(m);
    for (MethodDecl* d : prog_.delegates)
        for (Param& p : d->params)
            if (p.defaultValue)
                diag.error(p.defaultValue->loc, "default values are not part of a delegate type: remove '= " +
                                                    exprText(p.defaultValue) + "' from '" + p.name + "'");
}

// ¿Es una constante en tiempo de compilación? (como en C#: literales, const, enums, null, default)
bool Sema::isConstantDefault(Expr* e) {
    if (!e) return false;
    switch (e->kind) {
        case EK::IntLit: case EK::FloatLit: case EK::BoolLit: case EK::CharLit: case EK::StringLit: case EK::Null:
        case EK::Default:
            return true;
        case EK::Name: {
            auto* n = static_cast<NameExpr*>(e);
            return n->ref == NameExpr::Ref::StaticField && n->field && n->field->mods.isConst;
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref == MemberExpr::Ref::EnumConst || m->ref == MemberExpr::Ref::ConstInt) return true;
            return m->ref == MemberExpr::Ref::StaticField && m->field && m->field->mods.isConst;
        }
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            return !u->opMethod && (u->op == "-" || u->op == "+" || u->op == "~" || u->op == "!") &&
                   isConstantDefault(u->operand);
        }
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            return !b->opMethod && !b->lowered && isConstantDefault(b->lhs) && isConstantDefault(b->rhs);
        }
        case EK::Cast: {
            auto* c = static_cast<CastExpr*>(e);
            if (c->lowered) return isConstantDefault(c->lowered);
            return isConstantDefault(c->operand);
        }
        case EK::New: {  // new S() de un struct sin constructor, o T? con un valor constante
            auto* n = static_cast<NewExpr*>(e);
            if (n->init || !n->type || !n->type->isStruct()) return false;
            if (!n->ctor) return n->args.empty();
            ClassDecl* t = nullableTemplate();
            if (!t || n->type->decl->templateOf != t) return false;
            for (Expr* a : n->args)
                if (!isConstantDefault(a)) return false;
            return true;
        }
        default: return e->lowered && isConstantDefault(e->lowered);
    }
}

void Sema::resolveParamDefaults(MethodDecl* m) {
    bool optional = false, orderReported = false;
    for (size_t i = 0; i < m->params.size(); i++) {
        Param& p = m->params[i];
        for (Attribute& a : p.attrs) {
            if (a.name == "CallerMemberName") p.callerInfo = 1;
            else if (a.name == "CallerLineNumber") p.callerInfo = 2;
            else if (a.name == "CallerFilePath") p.callerInfo = 3;
            // los demás ([CallerArgumentExpression], atributos de usuario) los valida Attributes.cpp
        }
        if (!p.defaultValue) {
            if (p.callerInfo) diag.error(p.loc, "[Caller...] can only be applied to an optional parameter (with a default value)");
            if (optional && !p.isParams && !orderReported) {
                diag.error(p.loc, "optional parameters must come after all required ones ('" + p.name +
                                      "' has no default value)");
                orderReported = true;
            }
            continue;
        }
        optional = true;
        if (p.defaultChecked) continue;
        p.defaultChecked = true;
        if (p.isRef()) {
            diag.error(p.loc, "a 'ref' or 'out' parameter cannot have a default value");
            continue;
        }
        if (p.isThis) {
            diag.error(p.loc, "the 'this' parameter of an extension method cannot have a default value");
            continue;
        }
        if (p.isParams) {
            diag.error(p.loc, "a 'params' parameter cannot have a default value");
            continue;
        }
        if (!p.type || p.type->isError()) continue;
        if (p.callerInfo) {
            bool str = p.callerInfo != 2;
            if (str ? !p.type->is(TK::String) : !(p.type->isIntegral() && p.type->bits() >= 32))
                diag.error(p.loc, std::string(p.callerInfo == 1 ? "[CallerMemberName]" : p.callerInfo == 2 ? "[CallerLineNumber]"
                                                                                                         : "[CallerFilePath]") +
                                      " requires a parameter of type " + (str ? "'string'" : "'int' or 'long'"));
        }
        CtxSave save(*this);
        enter(m->owner, m);
        if (m->file) ctx_.file = m->file;
        Type* t = checkValue(p.defaultValue);
        if (t->isError()) continue;
        coerce(p.defaultValue, p.type);
        if (!isConstantDefault(p.defaultValue))
            diag.error(p.defaultValue->loc, "the default value of '" + p.name +
                                                "' must be a constant (a literal, a constant, an enum member, "
                                                "null or default)");
    }
}

// Valor de [CallerMemberName] / [CallerLineNumber] / [CallerFilePath] en el sitio de la llamada.
Expr* Sema::callerInfoArg(const Param& p, SourceLoc loc) {
    Expr* lit;
    if (p.callerInfo == 2) {
        auto* i = new IntLitExpr(loc);
        i->value = (uint64_t)loc.line;
        lit = i;
    } else {
        auto* s = new StringLitExpr(loc);
        if (p.callerInfo == 3) {
            if (loc.file >= 0 && loc.file < (int)diag.paths.size())
                s->value = !diag.paths[loc.file].empty() ? diag.paths[loc.file] : diag.files[loc.file];
        } else {
            MethodDecl* m = ctx_.method;
            while (m && m->name == "<lambda>" && m->usedBy) m = m->usedBy;  // la lambda: su método
            if (m && m->name != "<lambda>") s->value = m->kind == MethodKind::Ctor ? ".ctor" : m->name;
            else if (ctx_.field) s->value = ctx_.field->name;
        }
        lit = s;
    }
    checkValue(lit);
    coerce(lit, p.type);
    return lit;
}

bool Sema::needsArgBinding(MethodDecl* m, const std::vector<Expr*>& args) {
    for (Expr* a : args)
        if (!a->argName.empty()) return true;
    if (args.size() >= m->params.size()) return false;
    for (const Param& p : m->params)
        if (p.defaultValue) return true;
    return false;
}

// Asocia los argumentos con los parámetros de 'm' (ver el comentario del principio). 'out' recibe
// los argumentos en el orden de los parámetros; 'filled', cuántos toman su valor por defecto.
bool Sema::bindArgs(MethodDecl* m, const std::vector<Expr*>& args, std::vector<Expr*>& out, int& filled,
                    std::string* err, SourceLoc loc) {
    size_t n = m->params.size();
    bool params = paramsMethod(m);
    std::vector<Expr*> slots(n, nullptr), extra;
    size_t pos = 0;
    bool outOfPlace = false;
    filled = 0;
    auto fail = [&](const std::string& msg) {
        if (err) *err = msg;
        return false;
    };
    for (Expr* a : args) {
        if (a->argName.empty()) {
            if (outOfPlace)
                return fail("a named argument out of position cannot be followed by positional arguments");
            if (pos < n) slots[pos] = a;
            else if (params || m->variadic) extra.push_back(a);
            else return fail("'" + methodName(m) + "' does not accept " + std::to_string(args.size()) + " argument(s)");
            pos++;
            continue;
        }
        size_t k = 0;
        while (k < n && m->params[k].name != a->argName) k++;
        if (k == n) return fail("'" + methodName(m) + "' has no parameter named '" + a->argName + "'");
        if (slots[k]) return fail("parameter '" + a->argName + "' of '" + methodName(m) + "' already received an argument");
        if (m->params[k].isThis) return fail("the 'this' parameter of an extension method cannot be passed by name");
        slots[k] = a;
        if (k != pos) outOfPlace = true;
        pos++;
    }
    for (size_t k = 0; k < n; k++) {
        if (slots[k]) continue;
        Param& p = m->params[k];
        if (p.isParams && k + 1 == n) continue;  // 'params' sin elementos: lista vacía
        if (!p.defaultValue)
            return fail("missing an argument for required parameter '" + p.name + "' of '" + methodName(m) + "'");
        if (p.callerInfo && p.type && !p.type->isError()) slots[k] = callerInfoArg(p, loc);
        else slots[k] = p.defaultValue;  // en una plantilla: sin comprobar (solo para inferir)
        filled++;
    }
    out.clear();
    for (size_t k = 0; k < n; k++)
        if (slots[k]) out.push_back(slots[k]);
    for (Expr* a : extra) out.push_back(a);
    return true;
}

bool Sema::rejectNamedArgs(const std::vector<Expr*>& args, const std::string& what) {
    for (Expr* a : args)
        if (!a->argName.empty()) {
            diag.error(a->argNameLoc, "named arguments cannot be used " + what);
            return true;
        }
    return false;
}

// IntelliSense: dentro de los paréntesis de una llamada se sugieren los nombres de los parámetros.
void Sema::completeArgNames(Expr* callee, const std::vector<Expr*>& args) {
    if (!ideMode) return;
    bool marker = false;
    for (Expr* a : args)
        if (a->kind == EK::Name && static_cast<NameExpr*>(a)->name == kCompletionMarker && a->argName.empty()) marker = true;
    if (!marker) return;
    std::vector<MethodDecl*> group;
    if (callee && callee->vk == ValKind::MethodGroup) group = callee->group;
    else if (callee && callee->kind == EK::New && callee->type && callee->type->isAggregate()) group = callee->type->decl->ctors;
    for (MethodDecl* m : group)
        for (Param& p : m->params) {
            if (p.isThis) continue;
            addCompletion(p.name + ":", 6, "(parameter) " + (p.type ? p.type->str() : p.tref->str()) + " " + p.name +
                                               paramDefaultText(p) + "  — " + methodSignature(m));
        }
}

// Constructor de la base que se puede llamar sin argumentos (todos sus parámetros son opcionales).
MethodDecl* Sema::defaultedCtor(ClassDecl* c, std::vector<Expr*>& args, SourceLoc at) {
    std::vector<Expr*> none;
    MethodDecl* m = resolveOverload(c->ctors, none, at, c->displayName, {}, false);
    if (m) args = none;
    return m;
}

// ================================================================== out var

// F(out var x) / F(out int x): se declara la variable en el ámbito actual (como las variables de
// los patrones) y el argumento pasa a ser una referencia a ella. Con 'var', el tipo es el del
// parámetro 'out' en esa posición, que debe ser el mismo en todas las sobrecargas posibles.
void Sema::declareOutVars(const std::vector<MethodDecl*>& group, std::vector<Expr*>& args) {
    for (size_t i = 0; i < args.size(); i++) {
        // Una lambda se comprueba otra vez con cada tipo de delegado: la variable se vuelve a declarar.
        auto again = outVarOrigin_.find(args[i]);
        if (again != outVarOrigin_.end()) args[i] = again->second;
        if (args[i]->kind != EK::OutVar) continue;
        auto* o = static_cast<OutVarExpr*>(args[i]);
        Type* t = nullptr;
        if (o->tref->isVar()) {
            bool ambiguous = false;
            for (MethodDecl* m : group) {
                if (m->isTemplate()) continue;
                if (!m->signatureDone) resolveMethodSignature(m);
                size_t k = i;
                if (!o->argName.empty()) {  // out var con nombre: F(resultado: out var r)
                    for (k = 0; k < m->params.size() && m->params[k].name != o->argName; k++) {}
                }
                if (k >= m->params.size() || !m->params[k].isRef() || !m->params[k].type) continue;
                if (args.size() > m->params.size() && !m->variadic && !paramsMethod(m)) continue;
                if (t && t != m->params[k].type) ambiguous = true;
                t = m->params[k].type;
            }
            if (!t || ambiguous) {
                diag.error(o->loc, "cannot infer the type of 'out var " + o->name + "'" +
                                       (ambiguous ? " (the overloads do not match); write the type: out T " + o->name
                                                  : ": there is no 'out' parameter in that position"));
                t = tc_.error();
            }
        } else {
            t = resolveType(o->tref);
        }
        if (!ctx_.method) {
            diag.error(o->loc, "'out " + o->name + "': 'out' variables can only be declared inside methods");
            args[i] = new NullExpr(o->loc);
            continue;
        }
        VarInfo* v = declareLocal(o->name, t, o->loc, "l_");  // como 'is T x' (SemaClasses.cpp)
        v->cname += "__o" + std::to_string(++patternCounter_);
        ctx_.method->patternVars.push_back(v);
        if (ideMode) addRef(o->loc, (int)o->name.size(), "(local variable) " + t->str() + " " + o->name, &o->loc);
        auto* n = new NameExpr(o->loc);
        n->name = v->name;
        n->argName = o->argName;
        n->argNameLoc = o->argNameLoc;
        outVarOrigin_[n] = o;
        args[i] = n;
    }
}

// ================================================================== new: inicializadores y 'required'

Type* Sema::checkNewMembers(NewExpr* e) {
    e->initState = 1;
    if (ideMode && e->args.size()) {  // nombres de los parámetros del constructor
        bool marker = false;
        for (Expr* a : e->args)
            if (a->kind == EK::Name && static_cast<NameExpr*>(a)->name == kCompletionMarker) marker = true;
        if (marker) {
            CtxSave save(*this);
            Type* t = resolveType(e->tref);
            if (t->isAggregate())
                for (MethodDecl* m : t->decl->ctors)
                    for (Param& p : m->params) addCompletion(p.name + ":", 6, "(parameter) " + p.type->str() + " " + p.name);
        }
    }
    Type* T = checkNew(e);
    ObjInit* oi = e->init;
    if (T->isError() || !T->isAggregate()) {
        if (oi && !T->isError())
            diag.error(oi->loc, "'" + T->str() + "' does not allow object initializers");
        return T;
    }
    ClassDecl* c = T->decl;
    std::set<std::string> assigned;
    if (oi) {
        VarInfo* tmp = hiddenLocal(T, e->loc, true);
        auto* inner = new NewExpr(*e);
        inner->init = nullptr;
        inner->lowered = nullptr;
        inner->type = T;  // 'check' aún no lo ha guardado en 'e'
        inner->argName.clear();
        inner->argPos = -1;
        auto* let = new LetExpr(e->loc);
        let->binds.push_back({tmp, inner});
        SourceLoc loc = e->loc;
        applyObjInit(oi, T, [tmp, loc]() -> Expr* { return refTo(tmp, loc); }, let->seq, &assigned);
        Expr* result = refTo(tmp, loc);
        checkValue(result);
        let->seq.push_back(result);
        let->type = T;
        e->lowered = let;
    }
    checkRequiredMembers(c, e->ctor, assigned, e->loc);
    return T;
}

void Sema::applyObjInit(ObjInit* oi, Type* t, const std::function<Expr*()>& target, std::vector<Expr*>& seq,
                        std::set<std::string>* assigned) {
    bool members = false, adds = false, noAdd = false;
    for (ObjInit::Entry& en : oi->entries) {
        if (en.kind == ObjInit::Entry::Member) {
            members = true;
            if (en.name == kCompletionMarker) {
                completionRequested = true;
                completeInitMembers(t);
                continue;
            }
            if (assigned && !assigned->insert(en.name).second)
                diag.error(en.loc, "member '" + en.name + "' was already initialized in this initializer");
            MemberExpr* mem = mkMember(target(), en.name, en.loc);
            if (en.nested) {  // Miembro = { ... }: se inicializa el objeto que ya tiene el miembro
                Type* mt = checkValue(mem);
                if (mt->isError()) continue;
                if (!mt->isAggregate()) {
                    diag.error(en.loc, "member '" + en.name + "' is of type '" + mt->str() +
                                           "' and does not allow a nested initializer");
                    continue;
                }
                if (mt->isStruct() && mem->ref == MemberExpr::Ref::Property) {
                    diag.error(en.loc, "cannot use a nested initializer with property '" + en.name +
                                           "' of struct type (it would modify a copy); assign it a new value");
                    continue;
                }
                std::string name = en.name;
                SourceLoc l = en.loc;
                applyObjInit(en.nested, mt, [target, name, l]() -> Expr* { return mkMember(target(), name, l); }, seq, nullptr);
                continue;
            }
            auto* as = new AssignExpr(en.loc);
            as->op = "=";
            as->lhs = mem;
            as->rhs = en.value;
            AssignExpr* saved = initAssign_;
            initAssign_ = as;
            checkValue(as);
            initAssign_ = saved;
            seq.push_back(as);
            continue;
        }
        if (en.kind == ObjInit::Entry::Index) {  // [k] = v (se admite junto a elementos: { ["a"] = 1, { "b", 2 } })
            if (en.nested) {
                diag.error(en.loc, "an index initializer needs a value ('[k] = value'), not a nested initializer");
                continue;
            }
            auto* ix = new IndexExpr(en.loc);
            ix->obj = target();
            ix->index = en.args[0];
            ix->moreIndices.assign(en.args.begin() + 1, en.args.end());
            auto* as = new AssignExpr(en.loc);
            as->op = "=";
            as->lhs = ix;
            as->rhs = en.value;
            AssignExpr* saved = initAssign_;
            initAssign_ = as;
            checkValue(as);
            initAssign_ = saved;
            seq.push_back(as);
            continue;
        }
        // Elemento de colección: Add(...)
        adds = true;
        if (en.args.size() == 1 && en.args[0]->kind == EK::Name &&
            static_cast<NameExpr*>(en.args[0])->name == kCompletionMarker) {
            completionRequested = true;
            completeInitMembers(t);
            continue;
        }
        if (t->isAggregate() && findMethods(t->decl, "Add").empty() && findExtensions("Add").empty()) {
            if (!noAdd)  // un solo error por inicializador
                diag.error(en.loc, "'" + t->str() + "' has no 'Add' method: it does not allow collection initializers");
            noAdd = true;
            for (Expr* a : en.args) checkOperand(a);
            continue;
        }
        auto* call = new CallExpr(en.loc);
        call->callee = mkMember(target(), "Add", en.loc);
        call->args = en.args;
        check(call);
        seq.push_back(call);
    }
    if (members && adds)
        diag.error(oi->loc, "an initializer cannot mix member assignments ('X = ...') and collection elements");
}

void Sema::checkRequiredMembers(ClassDecl* c, MethodDecl* ctor, const std::set<std::string>& assigned, SourceLoc loc) {
    if (ctor && hasAttr(ctor->attrs, "SetsRequiredMembers")) return;
    std::set<std::string> seen;
    std::vector<std::string> missing;
    for (ClassDecl* k : lookupChain(c)) {
        for (FieldDecl* f : k->fields) {
            if (!f->mods.isRequired || f->isStatic() || (f->name.size() > 7 && f->name.rfind("__valor") == f->name.size() - 7))
                continue;
            if (seen.insert(f->name).second && !assigned.count(f->name)) missing.push_back(k->displayName + "." + f->name);
        }
        for (MethodDecl* m : k->methods) {
            if (m->kind != MethodKind::Getter || !m->mods.isRequired || m->isStatic()) continue;
            if (seen.insert(m->name).second && !assigned.count(m->name)) missing.push_back(k->displayName + "." + m->name);
        }
    }
    for (const std::string& m : missing)
        diag.error(loc, "required member '" + m + "' ('required') must be assigned: initialize it in the object "
                        "initializer (new " + c->displayName + " { " + m.substr(m.rfind('.') + 1) + " = ... })");
}

// IntelliSense dentro de 'new T { | }': miembros que se pueden asignar.
void Sema::completeInitMembers(Type* t) {
    if (!t || !t->isAggregate()) return;
    for (ClassDecl* k : lookupChain(t->decl)) {
        for (FieldDecl* f : k->fields)
            if (!f->isStatic() && !f->mods.isReadonly && accessible(f->mods.access, k))
                addCompletion(f->name, 5, (f->mods.isRequired ? "(required) " : "") + f->type->str() + " " + f->name);
        for (MethodDecl* m : k->methods)
            if (m->kind == MethodKind::Getter && !m->isStatic() && m->name != "this[]" && accessible(m->mods.access, k) &&
                (FindSetter(m) || (m->ret && m->ret->isClass())))
                addCompletion(m->name, 10, (m->mods.isRequired ? "(required) " : "") + methodSignature(m));
    }
}

// Accesor 'init': solo en un inicializador de objeto, en 'with' o en un constructor sobre 'this'.
bool Sema::initSetterAllowed(AssignExpr* e, MethodDecl* setter) {
    if (e == initAssign_) return true;
    MethodDecl* m = ctx_.method;
    bool onThis = e->lhs->kind == EK::Name ||
                  (e->lhs->kind == EK::Member && (static_cast<MemberExpr*>(e->lhs)->obj->kind == EK::This ||
                                                  isBaseExpr(static_cast<MemberExpr*>(e->lhs)->obj)));
    if (m && onThis && ctx_.cls && derivesFrom(ctx_.cls, setter->owner) &&
        (m->kind == MethodKind::Ctor || (m->kind == MethodKind::Setter && m->isInit)))
        return true;
    diag.error(e->loc, "property '" + setter->name + "' is init-only ('init'): it can only be assigned in "
                       "an object initializer, in 'with' or in a constructor");
    return false;
}

// Comprobaciones de los modificadores nuevos (en resolveClassSignatures).
void Sema::checkMemberModifiers(ClassDecl* c) {
    for (FieldDecl* f : c->fields) {
        if (!f->mods.isRequired || (f->name.size() > 7 && f->name.rfind("__valor") == f->name.size() - 7)) continue;
        if (f->isStatic() || f->mods.isReadonly)
            diag.error(f->loc, "a 'required' member cannot be static, const or readonly");
        else if (f->mods.access == Access::Private || f->mods.access == Access::Protected)
            diag.error(f->loc, "a 'required' member must be as accessible as its type (public or internal)");
    }
    for (MethodDecl* m : c->methods) {
        if (m->mods.isRequired && m->kind != MethodKind::Getter && m->kind != MethodKind::Setter)
            diag.error(m->loc, "'required' can only be applied to fields and properties");
        if (m->kind == MethodKind::Getter && m->mods.isRequired) {
            if (m->isStatic()) diag.error(m->loc, "a 'required' member cannot be static");
            else if (m->name == "this[]") diag.error(m->loc, "an indexer cannot be 'required'");
            else if (!FindSetter(m)) diag.error(m->loc, "required property '" + m->name + "' needs 'set' or 'init'");
            else if (m->mods.access == Access::Private || m->mods.access == Access::Protected)
                diag.error(m->loc, "a 'required' member must be as accessible as its type (public or internal)");
        }
        if (m->kind == MethodKind::Setter && m->isInit && m->isStatic())
            diag.error(m->loc, "'init' cannot be used on static properties; use 'set'");
        if (m->name == "this[]" && m->isStatic()) diag.error(m->loc, "an indexer cannot be 'static'");
        if (m->name == ".cctor") {
            if (c->isInterface()) diag.error(m->loc, "interfaces cannot have static constructors");
            useMethod(m);
        }
    }
    checkConversionOps(c);
}

// ================================================================== indizadores

void Sema::noteIndexTarget(AssignExpr* e) {
    indexTarget_ = e->lhs->kind == EK::Index && e->op == "=" ? e->lhs : nullptr;
}

Type* Sema::checkIndexer(IndexExpr* ix, Type* ot) {
    bool target = indexTarget_ == ix;
    if (target) indexTarget_ = nullptr;
    for (Expr*& x : ix->moreIndices) checkValue(x);
    if (ot->isError() || !ot->isAggregate()) {
        if (!ix->moreIndices.empty() && !ot->isError()) {
            diag.error(ix->loc, "'" + ot->str() + "' does not allow multiple indices");
            return tc_.error();
        }
        return nullptr;
    }
    std::vector<MethodDecl*> gets = findMethods(ot->decl, "this[]", MethodKind::Getter);
    std::vector<MethodDecl*> sets = findMethods(ot->decl, "this[]", MethodKind::Setter);
    if (gets.empty() && sets.empty()) {
        if (!ix->moreIndices.empty()) {
            diag.error(ix->loc, "'" + ot->str() + "' has no indexer with multiple indices (this[...])");
            return tc_.error();
        }
        return nullptr;  // operator[] (Sema.cpp)
    }
    if (ix->indexList && ix->index->kind == EK::Tuple) {  // a[i, j]: los índices por separado
        auto* tup = static_cast<TupleExpr*>(ix->index);
        ix->index = tup->elems[0];
        ix->moreIndices.assign(tup->elems.begin() + 1, tup->elems.end());
        ix->indexList = false;
    }
    std::vector<Expr*> args = {ix->index};
    args.insert(args.end(), ix->moreIndices.begin(), ix->moreIndices.end());
    for (Expr* a : args)
        if (!a->type || a->type->isError()) return tc_.error();
    std::string what = ot->decl->displayName + "[]";
    if (target) {  // a[i] = v: el 'set' se elige con el valor (checkIndexerAssign)
        if (sets.empty()) {
            diag.error(ix->loc, "the indexer of '" + ot->decl->displayName + "' is read-only (has no 'set')");
            return tc_.error();
        }
        ix->idxArgs = args;
        indexerTargets_.insert(ix);
        return sets[0]->params.back().type ? sets[0]->params.back().type : tc_.error();
    }
    if (gets.empty()) {
        diag.error(ix->loc, "the indexer of '" + ot->decl->displayName + "' is write-only (has no 'get')");
        return tc_.error();
    }
    MethodDecl* g = resolveOverload(gets, args, ix->loc, what);
    if (!g) return tc_.error();
    checkAccess(g->mods.access, g->owner, "this[]", ix->loc);
    requireSafeCall(g, ix->loc);
    useMethod(g, &ix->loc);
    coerceArgs(g, args);
    ix->idxGetter = g;
    ix->idxArgs = args;
    ix->lowered = checkedCall(tc_, g, ix->obj, args, ix->loc);
    if (ideMode) addRef(ix->loc, 1, methodSignature(g), &g->loc);
    return g->ret;
}

Type* Sema::checkIndexerAssign(AssignExpr* e) {
    if (e->lhs->kind != EK::Index) return nullptr;
    auto* ix = static_cast<IndexExpr*>(e->lhs);
    if (indexerTargets_.count(ix)) {  // a[i] = v  ->  set(a, i, v)
        indexerTargets_.erase(ix);
        Type* R = checkOperand(e->rhs);
        if (R->isError()) return tc_.error();
        Type* ot = ix->obj->type;
        std::vector<MethodDecl*> sets = findMethods(ot->decl, "this[]", MethodKind::Setter);
        std::vector<Expr*> args = ix->idxArgs;
        args.push_back(e->rhs);
        MethodDecl* s = resolveOverload(sets, args, e->loc, ot->decl->displayName + "[]", {}, false);
        if (!s) {
            // ¿Hay un 'get' para esos índices? Entonces el indizador es de solo lectura.
            std::vector<Expr*> idx = ix->idxArgs;
            std::vector<MethodDecl*> gets = findMethods(ot->decl, "this[]", MethodKind::Getter);
            if (!gets.empty() && resolveOverload(gets, idx, e->loc, "", {}, false))
                diag.error(ix->loc, "the indexer of '" + ot->decl->displayName + "' for " + indexTypes(ix->idxArgs) +
                                        " is read-only (has no 'set')");
            else
                resolveOverload(sets, args, e->loc, ot->decl->displayName + "[]");  // informa del error
            return tc_.error();
        }
        if (s->isInit && !initSetterAllowed(e, s)) return tc_.error();
        checkAccess(s->mods.access, s->owner, "this[]", e->loc);
        requireSafeCall(s, e->loc);
        useMethod(s, &e->loc);
        coerceArgs(s, args);
        e->lowered = checkedCall(tc_, s, ix->obj, args, e->loc);
        return tc_.get(TK::Void);
    }
    if (!ix->idxGetter || e->op == "=") return nullptr;
    // a[i] op= v  ->  (<o> = a, <i> = i, <o>[<i>] = <o>[<i>] op v)
    SourceLoc loc = e->loc;
    Expr* obj = ix->obj;
    auto* let = new LetExpr(loc);
    std::function<Expr*()> objRef;
    bool stableName = obj->kind == EK::Name && static_cast<NameExpr*>(obj)->ref == NameExpr::Ref::Local;
    if (obj->kind == EK::This) {
        objRef = [loc]() -> Expr* { return new ThisExpr(loc); };
    } else if (stableName) {
        std::string nm = static_cast<NameExpr*>(obj)->name;
        objRef = [nm, loc]() -> Expr* {
            auto* n = new NameExpr(loc);
            n->name = nm;
            return n;
        };
    } else if (obj->type && obj->type->isClass()) {
        VarInfo* t = hiddenLocal(obj->type, loc, true);
        let->binds.push_back({t, obj});
        objRef = [t, loc]() -> Expr* { return refTo(t, loc); };
    } else {
        diag.error(loc, "'" + e->op + "' on the indexer of a temporary value is not supported; use a variable");
        checkValue(e->rhs);
        return tc_.error();
    }
    std::vector<VarInfo*> idx;
    for (Expr* a : ix->idxArgs) {
        VarInfo* t = hiddenLocal(a->type, loc, true);
        let->binds.push_back({t, a});
        idx.push_back(t);
    }
    auto access = [&]() {
        auto* n = new IndexExpr(ix->loc);
        n->obj = objRef();
        n->index = refTo(idx[0], loc);
        for (size_t i = 1; i < idx.size(); i++) n->moreIndices.push_back(refTo(idx[i], loc));
        return n;
    };
    auto* bin = new BinaryExpr(loc);
    bin->op = e->op.substr(0, e->op.size() - 1);
    bin->lhs = access();
    bin->rhs = e->rhs;
    auto* as = new AssignExpr(loc);
    as->op = "=";
    as->lhs = access();
    as->rhs = bin;
    Type* t = checkValue(as);
    if (t->isError()) return t;
    let->seq.push_back(as);
    let->type = t;
    e->lowered = let;
    return t;
}

// ================================================================== conversiones del usuario

bool Sema::userImplicit(Expr* e, Type* from, Type* to) {
    return findUserConversion(e, from, to, false, nullptr, false) != nullptr;
}

std::vector<MethodDecl*> Sema::conversionOps(Type* from, Type* to, bool allowExplicit) {
    std::vector<MethodDecl*> out;
    for (Type* t : {from, to}) {
        if (!t || !t->isAggregate()) continue;
        for (ClassDecl* k : lookupChain(t->decl))
            for (MethodDecl* m : k->methods)
                if (isConversionOp(m) && (allowExplicit || m->name == "operator implicit") && m->signatureDone &&
                    m->params.size() == 1 && std::find(out.begin(), out.end(), m) == out.end())
                    out.push_back(m);
    }
    return out;
}

// La conversión del usuario de 'from' a 'to' con menor coste (o nullptr). Antes y después de la
// conversión se admite una conversión estándar implícita (o, en una conversión explícita, numérica).
MethodDecl* Sema::findUserConversion(Expr* e, Type* from, Type* to, bool allowExplicit, int* cost, bool report) {
    if (noUserConv_ || !from || !to || from == to || from->isError() || to->isError() || from->isPending()) return nullptr;
    if (!from->isAggregate() && !to->isAggregate()) return nullptr;
    std::vector<MethodDecl*> ops = conversionOps(from, to, allowExplicit);
    if (ops.empty()) return nullptr;
    noUserConv_++;
    auto numLike = [](Type* t) { return t->isNumeric() || t->isEnum(); };
    auto step = [&](Expr* x, Type* a, Type* b) -> int {
        if (a == b) return 0;
        if (canImplicit(x, a, b)) return x ? std::max(convCost(x, b), 1) : 1;
        if (allowExplicit && numLike(a) && numLike(b)) return 20;
        return -1;
    };
    MethodDecl* best = nullptr;
    int bestCost = 0;
    bool ambiguous = false;
    for (MethodDecl* op : ops) {
        Type* P = op->params[0].type;
        Type* R = op->ret;
        if (!P || !R || P->isError() || R->isError()) continue;
        int c1 = step(e, from, P);
        if (c1 < 0) continue;
        int c2 = step(nullptr, R, to);
        if (c2 < 0) continue;
        int c = c1 + c2 + (op->name == "operator explicit" ? 1 : 0);
        if (!best || c < bestCost) {
            best = op;
            bestCost = c;
            ambiguous = false;
        } else if (c == bestCost && op != best) {
            ambiguous = true;
        }
    }
    noUserConv_--;
    if (best && ambiguous) {
        if (report) diag.error(e ? e->loc : SourceLoc(), "the conversion from '" + from->str() + "' to '" + to->str() + "' is ambiguous");
        return nullptr;
    }
    if (best && cost) *cost = bestCost;
    return best;
}

int Sema::userConvCost(Expr* e, Type* from, Type* to) {
    if (noUserConv_ || !from || !to || (!from->isAggregate() && !to->isAggregate())) return -1;
    noUserConv_++;
    bool standard = canImplicit(e, from, to);
    noUserConv_--;
    if (standard) return -1;
    int c = 0;
    if (!findUserConversion(e, from, to, false, &c, false)) return -1;
    return 60 + c;  // peor que cualquier conversión estándar
}

Expr* Sema::applyUserConversion(Expr* e, MethodDecl* op, Type* to, bool explicitCast) {
    (void)explicitCast;
    Type* P = op->params[0].type;
    SourceLoc loc = e->loc;
    noUserConv_++;
    Expr* arg = e;
    if (arg->type != P) {
        if (canImplicit(arg, arg->type, P)) coerce(arg, P);
        else arg = implicitCast(arg, P);  // conversión numérica explícita previa
    }
    Expr* r = checkedCall(tc_, op, nullptr, {arg}, loc);
    if (op->ret != to) {
        if (canImplicit(nullptr, op->ret, to)) coerce(r, to);
        else r = implicitCast(r, to);
    }
    noUserConv_--;
    checkAccess(op->mods.access, op->owner, op->name, loc);
    requireSafeCall(op, loc);
    useMethod(op, &loc);
    return r;
}

bool Sema::userCoerce(Expr*& e, Type* to) {
    Type* from = e->type;
    if (noUserConv_ || !from || from->isPending() || from->isError() || (!from->isAggregate() && !to->isAggregate()))
        return false;
    noUserConv_++;
    bool standard = canImplicit(e, from, to);
    noUserConv_--;
    if (standard) return false;
    MethodDecl* op = findUserConversion(e, from, to, false, nullptr, true);
    if (!op) return false;
    e = applyUserConversion(e, op, to, false);
    return true;
}

Type* Sema::userCast(CastExpr* c, Type* from, Type* to) {
    if (!from->isAggregate() && !to->isAggregate()) return nullptr;
    noUserConv_++;
    bool standard = canImplicit(c->operand, from, to) || checkedCastOk(from, to);
    noUserConv_--;
    if (standard) return nullptr;
    MethodDecl* op = findUserConversion(c->operand, from, to, true, nullptr, true);
    if (!op) return nullptr;
    c->lowered = applyUserConversion(c->operand, op, to, true);
    return to;
}

void Sema::checkConversionOps(ClassDecl* c) {
    std::vector<MethodDecl*> convs;
    for (MethodDecl* m : c->methods)
        if (isConversionOp(m)) convs.push_back(m);
    for (MethodDecl* m : convs) {
        std::string what = m->name == "operator implicit" ? "implicit operator" : "explicit operator";
        if (!m->isStatic() || m->mods.access != Access::Public) {
            diag.error(m->loc, "the '" + what + "' conversion must be 'public static'");
            continue;
        }
        if (m->params.size() != 1) {
            diag.error(m->loc, "a user-defined conversion must have exactly one parameter");
            continue;
        }
        Type* S = m->params[0].type;
        Type* T = m->ret;
        if (!S || !T || S->isError() || T->isError()) continue;
        if (S != c->type && T != c->type) {
            diag.error(m->loc, "a user-defined conversion must convert from or to '" + c->displayName + "'");
            continue;
        }
        if (S == T) {
            diag.error(m->loc, "a user-defined conversion cannot convert a type to itself");
            continue;
        }
        auto bad = [&](Type* t) {
            return t->isVoid() || (t->isClass() && (t->decl->isInterface() || t->decl == objectDecl));
        };
        bool related = S->isClass() && T->isClass() && (derivesFrom(S->decl, T->decl) || derivesFrom(T->decl, S->decl));
        if (bad(S) || bad(T) || related) {
            diag.error(m->loc, "user-defined conversions to or from an interface, 'object' or a base or derived class are not allowed");
            continue;
        }
        for (MethodDecl* o : convs) {
            if (o == m) break;
            if (o->name != m->name && o->params.size() == 1 && o->params[0].type == S && o->ret == T)
                diag.error(m->loc, "a conversion from '" + S->str() + "' to '" + T->str() + "' already exists (both implicit and explicit)");
        }
    }
}

// ================================================================== orden de evaluación (CodeGen)

// Los argumentos con nombre quedan en el orden de los parámetros, pero se evalúan en el orden del
// código (C#): 'sequence' decide los temporales con los operandos ordenados por 'argPos' (los
// valores por defecto, constantes, al final) y después se devuelven a su sitio.
std::string CodeGen::sequenceArgs(std::vector<EvalOp>& ops, size_t first) {
    bool reorder = false;
    int last = -1;
    for (size_t i = first; i < ops.size(); i++) {
        int p = ops[i].e ? ops[i].e->argPos : -1;
        if (p < 0) continue;
        if (p < last) reorder = true;
        last = p;
    }
    if (!reorder) return sequence(ops);
    std::vector<size_t> idx;
    for (size_t i = first; i < ops.size(); i++) idx.push_back(i);
    auto key = [&](size_t i) { return ops[i].e && ops[i].e->argPos >= 0 ? ops[i].e->argPos : 1 << 30; };
    std::stable_sort(idx.begin(), idx.end(), [&](size_t a, size_t b) { return key(a) < key(b); });
    std::vector<EvalOp> sorted(ops.begin(), ops.begin() + (long)first);
    for (size_t i : idx) sorted.push_back(ops[i]);
    std::string pre = sequence(sorted);
    for (size_t k = 0; k < first; k++) ops[k] = sorted[k];
    for (size_t k = 0; k < idx.size(); k++) ops[idx[k]] = sorted[first + k];
    return pre;
}
