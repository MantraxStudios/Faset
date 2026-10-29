// Faset - excepciones: try / catch / when / finally / throw.
//
// Todo lo relativo a las excepciones vive aquí (análisis sintáctico, semántico y generación de C);
// el runtime está en RuntimeExc.cpp. Resumen del diseño:
//
//  * Modelo: setjmp/longjmp con una pila de marcos por hilo (faset_exc_top, thread-local). Cada
//    'try' declara su marco (faset_exc_frame) en la pila de C, lo enlaza y llama a setjmp; 'throw'
//    desapila el marco más cercano, guarda en él la excepción y hace longjmp. Como los marcos están
//    en la pila, el recolector (que recorre las pilas de forma conservadora) ve la excepción en
//    vuelo sin raíces extra. Una función sin 'try' no paga nada.
//
//  * 'finally' se emite como un marco propio que atrapa todo: al terminar el cuerpo (normalmente,
//    por una excepción o por un salto) corre el bloque y luego relanza o continúa el salto
//    pendiente. break/continue/return que salen de un 'try' se reescriben: desapilan los marcos que
//    atraviesan y, si hay un 'finally' por medio, saltan a él con 'goto' (fs_whyN dice qué hacer
//    después). try/catch/finally = try/finally { try/catch }.
//
//  * Las variables locales declaradas fuera de un 'try' y modificadas dentro se declaran
//    'volatile' en C (tras un longjmp, una variable no volatile modificada tiene valor indefinido).
//    Sema las marca en isLValue (todas las escrituras pasan por ahí): ver excNoteWrite.
//
//  * Jerarquía (provisional, hasta que exista la herencia): std.Exception es la raíz. Una clase es
//    una excepción si lleva [ExceptionBase("Base")]: hereda los campos de la base (que se copian al
//    principio, así su layout en C empieza igual que el de la base y un puntero a ella es también
//    un puntero válido a la base) y se convierte implícitamente en la base. Cada objeto guarda su
//    descriptor de tipo (campo oculto __excType, lo rellena el constructor) y 'catch (T e)' compara
//    con faset_exc_is, que recorre la cadena de bases del tipo dinámico. Los métodos de la base no
//    se heredan (cada clase de std declara su ToString). Cuando llegue la herencia,
//    exceptionBase() pasará a devolver la clase base declarada (class MiError : Exception) y
//    faset_exc_is podrá sustituirse por la comprobación de 'is'.
#include <functional>

#include "CodeGen.h"
#include "Parser.h"
#include "Sema.h"

// ================================================================== análisis sintáctico

Stmt* Parser::parseTry() {
    auto* t = new TryStmt(cur().loc);
    p_++;  // try
    if (!isP("{")) fail("se esperaba '{' después de 'try'");
    t->body = parseBlock();
    while (isK("catch")) {
        TryStmt::Catch c;
        c.loc = cur().loc;
        p_++;
        if (acceptP("(")) {
            c.tref = parseType();
            if (cur().kind == TokKind::Ident) {
                c.nameLoc = cur().loc;
                c.name = expectIdent();
            }
            expectP(")");
        }
        if (cur().kind == TokKind::Ident && cur().text == "when") {  // 'when' es una palabra contextual
            p_++;
            expectP("(");
            c.filter = parseExpr();
            expectP(")");
        }
        if (!isP("{")) fail("se esperaba '{' en la cláusula 'catch'");
        c.body = parseBlock();
        t->catches.push_back(c);
    }
    if (acceptK("finally")) {
        if (!isP("{")) fail("se esperaba '{' después de 'finally'");
        t->finallyBody = parseBlock();
    }
    if (t->catches.empty() && !t->finallyBody) fail(t->loc, "'try' necesita al menos una cláusula 'catch' o 'finally'");
    return t;
}

Stmt* Parser::parseThrow() {
    auto* t = new ThrowStmt(cur().loc);
    p_++;  // throw
    if (!isP(";")) t->value = parseExpr();
    expectP(";");
    return t;
}

// ================================================================== jerarquía de excepciones

namespace {

const Attribute* findAttr(const std::vector<Attribute>& attrs, const char* name) {
    for (const Attribute& a : attrs)
        if (a.name == name) return &a;
    return nullptr;
}

// Campos de std.Exception que usan el runtime y el generador de C (en este orden, al principio).
const char* const kExcFields[] = {"__excType", "TypeName", "Message", "InnerException", "StackTrace"};

FieldDecl* fieldNamed(ClassDecl* c, const std::string& name) {
    for (FieldDecl* f : c->fields)
        if (!f->isStatic() && f->name == name) return f;
    return nullptr;
}

std::string excWhere(MethodDecl* m) {
    if (!m || m->trackCaller) return "";  // [TrackCaller]: la ubicación ya es la de quien llama
    if (!m->owner || m->owner->isNamespaceScope) return m->name;
    std::string n = m->kind == MethodKind::Ctor ? m->owner->displayName : m->name;
    return m->owner->displayName + "." + n;
}

}  // namespace

ClassDecl* Sema::exceptionBase(ClassDecl* c) const {
    // Gancho para la herencia: hoy la base sale de [ExceptionBase("...")] (ver excPrepare).
    auto it = excBase_.find(c);
    return it == excBase_.end() ? nullptr : it->second;
}

// Herencia real (SemaClasses.cpp): al resolver la base de una clase, 'class MiError : Exception' pasa a
// ser una excepción si su base lo es. Sus campos ya vienen de la base (struct incrustado).
void Sema::excAdoptInherited(ClassDecl* c) {
    if (!exceptionClass || excClasses_.count(c) || !c->base || c->base == c) return;
    if (!excClasses_.count(c->base)) return;
    excBase_[c] = c->base;
    excClasses_.insert(c);
    exceptionTypes.push_back(c);
}

bool Sema::isExceptionClass(ClassDecl* c) const { return c && excClasses_.count(c) != 0; }

bool Sema::excIsSubclass(ClassDecl* derived, ClassDecl* base) const {
    if (!isExceptionClass(derived) || !isExceptionClass(base)) return false;
    for (ClassDecl* c = derived; c; c = exceptionBase(c))
        if (c == base) return true;
    return false;
}

void Sema::excSetupHierarchy() {
    NamespaceSym* stdNs = findNs({"std"});
    if (stdNs) {
        auto it = stdNs->types.find("Exception");
        if (it != stdNs->types.end() && it->second->kind == ClassKind::Class && !it->second->isTemplate())
            exceptionClass = it->second;
    }
    if (exceptionClass) {
        for (size_t i = 0; i < sizeof kExcFields / sizeof *kExcFields; i++) {
            FieldDecl* f = i < exceptionClass->fields.size() ? exceptionClass->fields[i] : nullptr;
            if (!f || f->name != kExcFields[i]) {
                diag.error(exceptionClass->loc, std::string("std.Exception debe empezar por el campo '") + kExcFields[i] + "'");
                exceptionClass = nullptr;
                break;
            }
        }
    }
    if (exceptionClass) {
        excClasses_.insert(exceptionClass);
        exceptionTypes.push_back(exceptionClass);
    }
    std::set<ClassDecl*> busy;
    for (size_t i = 0; i < prog_.types.size(); i++)
        if (findAttr(prog_.types[i]->attrs, "ExceptionBase")) excPrepare(prog_.types[i], busy);
}

// [ExceptionBase("Base")]: resuelve la base, copia sus campos al principio y registra la clase.
bool Sema::excPrepare(ClassDecl* c, std::set<ClassDecl*>& busy) {
    if (excClasses_.count(c)) return true;
    const Attribute* a = findAttr(c->attrs, "ExceptionBase");
    if (!a || !exceptionClass) {
        if (a) diag.error(a->loc, "no se encontró la clase std.Exception");
        return false;
    }
    if (busy.count(c)) {
        diag.error(a->loc, "la jerarquía de excepciones de '" + c->displayName + "' es circular");
        return false;
    }
    if (a->args.size() != 1) {
        diag.error(a->loc, "[ExceptionBase] requiere el nombre de la clase base: [ExceptionBase(\"Exception\")]");
        return false;
    }
    if (c->kind != ClassKind::Class || c->isTemplate() || c->isStaticClass()) {
        diag.error(a->loc, "[ExceptionBase] solo se puede aplicar a clases no estáticas ni genéricas");
        return false;
    }
    busy.insert(c);
    ClassDecl* base = nullptr;
    {
        CtxSave save(*this);
        enter(c, nullptr);
        std::vector<std::string> parts;
        std::string name = a->args[0];
        for (size_t start = 0;;) {
            size_t dot = name.find('.', start);
            parts.push_back(name.substr(start, dot == std::string::npos ? std::string::npos : dot - start));
            if (dot == std::string::npos) break;
            start = dot + 1;
        }
        Sym s = lookupUnqualified(parts[0], a->loc);
        for (size_t i = 1; i < parts.size() && s.kind == Sym::Ns; i++) s = lookupIn(s.ns, parts[i]);
        if (s.kind == Sym::TypeK && s.decl) base = s.decl;
    }
    bool ok = base && (base == exceptionClass || excPrepare(base, busy));
    busy.erase(c);
    if (!ok) {
        diag.error(a->loc, base ? "'" + base->displayName + "' no es una clase de excepción"
                                : "no se encontró la clase base '" + a->args[0] + "'");
        return false;
    }
    // Los campos de la base van primero: el layout en C empieza igual que el de la base.
    std::vector<FieldDecl*> inherited;
    for (FieldDecl* bf : base->fields) {
        if (bf->isStatic()) continue;
        auto* f = new FieldDecl(*bf);
        f->file = bf->file ? bf->file : base->file;  // su tipo se resuelve donde se declaró
        f->init = nullptr;                           // los inicializadores no se copian
        f->owner = nullptr;
        f->type = nullptr;
        f->cname.clear();
        inherited.push_back(f);
    }
    c->fields.insert(c->fields.begin(), inherited.begin(), inherited.end());
    excBase_[c] = base;
    excClasses_.insert(c);
    exceptionTypes.push_back(c);
    return true;
}

// ================================================================== análisis semántico

void Sema::excNoteWrite(Expr* e) {
    if (ctx_.excTryDepth == 0) return;
    // Raíz del lvalue: s.a.b o s[i] (indexador de un struct) modifican la variable 's'.
    for (;;) {
        if (e->kind == EK::Member) {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref == MemberExpr::Ref::Field && !m->arrow && m->obj->type && m->obj->type->isStruct()) {
                e = m->obj;
                continue;
            }
        } else if (e->kind == EK::Index) {
            auto* ix = static_cast<IndexExpr*>(e);
            if (ix->opMethod && ix->obj->type && ix->obj->type->isStruct()) {
                e = ix->obj;
                continue;
            }
        }
        break;
    }
    if (e->kind != EK::Name) return;
    auto* n = static_cast<NameExpr*>(e);
    if (n->ref == NameExpr::Ref::Local && n->var && !n->var->isRef && n->var->excDepth < ctx_.excTryDepth)
        n->var->isVolatile = true;
}

void Sema::excCheckJump(Stmt* s) {
    auto& regions = ctx_.excRegions;
    if (s->kind == SK::Return) {
        for (auto& r : regions)
            if (r.finallyBody) {
                diag.error(s->loc, "no se puede salir de un bloque 'finally' con 'return'");
                return;
            }
        return;
    }
    bool isBreak = s->kind == SK::Break;
    int depth = isBreak ? ctx_.loopDepth + ctx_.switchDepth : ctx_.loopDepth;
    int cross = 0;
    for (auto it = regions.rbegin(); it != regions.rend(); ++it) {
        if ((isBreak ? it->breaks : it->loops) != depth) break;  // el bucle destino está dentro
        if (it->finallyBody) {
            diag.error(s->loc, std::string("no se puede salir de un bloque 'finally' con '") +
                                   (isBreak ? "break" : "continue") + "'");
            return;
        }
        cross++;
    }
    if (cross) excJumpCross[s] = cross;
}

void Sema::checkTry(TryStmt* t) {
    if (!exceptionClass) {
        diag.error(t->loc, "no se encontró la clase std.Exception (biblioteca estándar incompleta)");
        return;
    }
    if (ctx_.method) excMethods.insert(ctx_.method);
    auto region = [&](bool finallyBody) {
        ctx_.excRegions.push_back({finallyBody, ctx_.loopDepth, ctx_.loopDepth + ctx_.switchDepth});
    };
    ctx_.excTryDepth++;
    bool fin = t->finallyBody != nullptr, cat = !t->catches.empty();
    if (fin) region(false);
    if (cat) region(false);
    checkStmt(t->body);
    if (cat) ctx_.excRegions.pop_back();

    bool catchAll = false;  // una cláusula anterior ya atrapa cualquier excepción
    std::vector<ClassDecl*> previous;
    for (auto& c : t->catches) {
        ctx_.scopes.emplace_back();
        c.type = c.tref ? resolveType(c.tref) : exceptionClass->type;
        bool valid = !c.type->isError();
        if (valid && !(c.type->isClass() && isExceptionClass(c.type->decl))) {
            diag.error(c.tref->loc, "'" + c.type->str() + "' no es una clase de excepción (usa Exception o una clase con " +
                                        "[ExceptionBase(\"Exception\")])");
            valid = false;
        }
        if (valid) {
            if (catchAll) {
                diag.error(c.loc, "esta cláusula 'catch' nunca se ejecuta: una anterior ya atrapa todas las excepciones");
            } else {
                for (ClassDecl* p : previous)
                    if (excIsSubclass(c.type->decl, p)) {
                        diag.error(c.loc, "esta cláusula 'catch' nunca se ejecuta: una anterior ya atrapa '" +
                                              p->displayName + "'");
                        break;
                    }
            }
            if (!c.filter) {
                if (c.type->decl == exceptionClass) catchAll = true;
                previous.push_back(c.type->decl);
            }
        }
        if (!valid) c.type = tc_.error();
        if (!c.name.empty()) {
            c.var = declareLocal(c.name, c.type, c.nameLoc, "l_");
            if (ideMode && valid)
                addRef(c.nameLoc, (int)c.name.size(), "(variable local) " + c.type->str() + " " + c.name, &c.nameLoc);
        }
        if (c.filter) checkCondition(c.filter);
        ctx_.excHandlers.push_back('C');
        checkStmt(c.body);
        ctx_.excHandlers.pop_back();
        ctx_.scopes.pop_back();
    }
    if (fin) ctx_.excRegions.pop_back();
    if (fin) {
        region(true);
        ctx_.excHandlers.push_back('F');
        checkStmt(t->finallyBody);
        ctx_.excHandlers.pop_back();
        ctx_.excRegions.pop_back();
    }
    ctx_.excTryDepth--;
}

void Sema::checkThrow(ThrowStmt* t) {
    if (!t->value) {
        if (ctx_.excHandlers.empty() || ctx_.excHandlers.back() != 'C')
            diag.error(t->loc, ctx_.excHandlers.empty() ? "'throw;' solo se puede usar dentro de una cláusula 'catch'"
                                                         : "'throw;' no se puede usar dentro de un bloque 'finally'");
        return;
    }
    if (ctx_.method) excMethods.insert(ctx_.method);
    Type* ty = checkValue(t->value);
    if (ty->isError()) return;
    if (!exceptionClass) {
        diag.error(t->loc, "no se encontró la clase std.Exception (biblioteca estándar incompleta)");
        return;
    }
    if (!(ty->isClass() && isExceptionClass(ty->decl)))
        diag.error(t->value->loc, "solo se pueden lanzar excepciones: '" + ty->str() +
                                      "' no es una clase de excepción (usa Exception o una clase con " +
                                      "[ExceptionBase(\"Exception\")])");
}

bool Sema::excAlwaysReturns(TryStmt* t) {
    if (t->finallyBody && alwaysReturns(t->finallyBody)) return true;
    if (!alwaysReturns(t->body)) return false;
    for (auto& c : t->catches)
        if (!alwaysReturns(c.body)) return false;
    return true;
}

bool Sema::excContainsBreak(TryStmt* t) {
    if (containsBreak(t->body) || (t->finallyBody && containsBreak(t->finallyBody))) return true;
    for (auto& c : t->catches)
        if (containsBreak(c.body)) return true;
    return false;
}

// Miembros estáticos de los tipos primitivos: int.Parse(s) es Int32.Parse(s), char.IsDigit(c) es
// Char.IsDigit(c)... (las clases estáticas con el nombre de .NET están en std).
Type* Sema::primitiveStaticMember(MemberExpr* e, Type* t) {
    const char* name = nullptr;
    switch (t->kind) {
        case TK::Int: name = "Int32"; break;
        case TK::Long: name = "Int64"; break;
        case TK::UInt: name = "UInt32"; break;
        case TK::ULong: name = "UInt64"; break;
        case TK::Double: name = "Double"; break;
        case TK::Float: name = "Single"; break;
        case TK::Bool: name = "Boolean"; break;
        case TK::Char: name = "Char"; break;
        case TK::String: name = "String"; break;
        default: return nullptr;
    }
    NamespaceSym* stdNs = findNs({"std"});
    if (!stdNs) return nullptr;
    auto it = stdNs->types.find(name);
    if (it == stdNs->types.end() || !it->second->isStaticClass()) return nullptr;
    ClassDecl* c = it->second;
    for (FieldDecl* f : c->fields)
        if (f->name == e->name && f->isStatic()) {
            checkAccess(f->mods.access, c, f->name, e->loc);
            e->ref = MemberExpr::Ref::StaticField;
            e->field = f;
            return f->type;
        }
    for (MethodDecl* m : c->methods)
        if (m->kind == MethodKind::Normal && m->name == e->name && m->mods.access == Access::Public) e->group.push_back(m);
    if (e->group.empty()) return nullptr;
    e->vk = ValKind::MethodGroup;
    return tc_.get(TK::Void);
}

// ================================================================== generación de C

void CodeGen::emitExcDecls() {
    if (!sema_.exceptionClass) return;
    // Descriptores de tipo: nombre y base (las bases van primero en exceptionTypes).
    for (ClassDecl* c : sema_.exceptionTypes) {
        ClassDecl* b = sema_.exceptionBase(c);
        out_ << "static const faset_exc_type fs__exct_" << c->cname << " = { " << cstring(c->displayName) << ", "
             << (b ? "&fs__exct_" + b->cname : std::string("0")) << " };\n";
    }
    out_ << "\n";
}

void CodeGen::emitExcInit(ClassDecl* c) {
    if (!sema_.isExceptionClass(c)) return;
    // Con herencia real los campos pueden estar en una clase base (struct incrustado).
    auto inherited = [&](const char* n) -> FieldDecl* {
        for (ClassDecl* k = c; k; k = k->base == k ? nullptr : k->base)
            if (FieldDecl* f = fieldNamed(k, n)) return f;
        return nullptr;
    };
    FieldDecl* type = inherited("__excType");
    FieldDecl* name = inherited("TypeName");
    if (type) line("self->" + fieldPath(c, type) + " = (uint64_t)(uintptr_t)&fs__exct_" + c->cname + ";");
    if (name)
        line("self->" + fieldPath(c, name) + " = FASET_STR(" + cstring(c->displayName) + ", " +
             std::to_string(c->displayName.size()) + ");");
}

void CodeGen::emitExcHelpers() {
    ClassDecl* root = sema_.exceptionClass;
    if (!root) return;
    // Errores del runtime (nulos, índices, divisiones) convertidos en excepciones de std.
    out_ << "static void* fs__exc_make(int32_t kind, faset_string msg) {\n";
    out_ << "    switch (kind) {\n";
    const std::pair<int, const char*> kinds[] = {
        {1, "NullReferenceException"}, {2, "IndexOutOfRangeException"}, {3, "DivideByZeroException"},
        {4, "OverflowException"},
    };
    for (auto& [kind, cls] : kinds) {
        ClassDecl* c = nullptr;
        for (ClassDecl* t : sema_.exceptionTypes)
            if (t->name == cls && t->ns == "std") c = t;
        if (!c) continue;
        for (size_t i = 0; i < c->ctors.size(); i++) {
            MethodDecl* m = c->ctors[i];
            if (m->params.size() == 1 && m->params[0].type && m->params[0].type->is(TK::String) && m->body && m->checked) {
                out_ << "        case " << kind << ": return (void*)" << c->cname << "__new" << i << "(msg);\n";
                break;
            }
        }
    }
    out_ << "        default: return 0;\n    }\n}\n\n";
    auto off = [&](const char* f) { return "(int64_t)offsetof(" + root->cname + ", " + fieldNamed(root, f)->cname + ")"; };
    out_ << "static void fs__exc_setup(void) {\n";
    out_ << "    faset_exc_setup(&fs__exct_" << root->cname << ", " << off("__excType") << ", " << off("Message") << ", "
         << off("InnerException") << ", " << off("StackTrace") << ", fs__exc_make);\n";
    out_ << "}\n\n";
}

void CodeGen::emitThrow(ThrowStmt* t) {
    std::string where = excWhere(curMethod_);
    std::string w = where.empty() ? "0" : cstring(where);
    if (!t->value) {
        line("faset_exc_rethrow_at(&" + excCatchFrames_.back() + ", " + callerLoc(t->loc) + ", " + w + ");");
        return;
    }
    // 'throw new X(...)' nunca es nulo; cualquier otra expresión se comprueba (throw null -> NullReferenceException).
    std::string v = t->value->kind == EK::New ? expr(t->value) : chkObj(t->value, expr(t->value));
    line("faset_exc_throw((void*)" + v + ", " + callerLoc(t->loc) + ", " + w + ");");
}

// Salto (kind: 2 return, 3 break, 4 continue; 1 es una excepción pendiente) que atraviesa las 'cross' zonas protegidas más
// internas: desapila sus marcos y, si alguna es un finally, salta a él; si no, hace el salto.
void CodeGen::emitExcJumpChain(int kind, int cross) {
    int n = (int)excRegions_.size();
    int target = -1;
    for (int i = n - 1; i >= n - cross; i--)
        if (excRegions_[i].finally) {
            target = i;
            break;
        }
    if (cross > 0) line("faset_exc_top = " + excRegions_[target >= 0 ? target : n - cross].frame + ".prev;");
    if (target >= 0) {
        ExcRegion& r = excRegions_[target];
        int remain = cross - (n - target);
        if (kind == 2) r.ret = true;
        if (kind == 3) r.breakRemain = remain;
        if (kind == 4) r.contRemain = remain;
        line("fs_why" + std::to_string(r.id) + " = " + std::to_string(kind) + "; goto fs_fin" + std::to_string(r.id) + ";");
        return;
    }
    if (kind == 3) line("break;");
    else if (kind == 4) line("continue;");
    else line(excRetVar_.empty() ? "return;" : "return " + excRetVar_ + ";");
}

bool CodeGen::emitExcJump(Stmt* s) {
    // Solo las zonas abiertas por este mismo método (p. ej. no las del método que contiene una lambda).
    if (excRegions_.empty() || excRegions_.back().method != curMethod_) return false;
    int kind = 0, cross = 0;
    if (s->kind == SK::Return) {
        kind = 2;
        cross = (int)excRegions_.size();
    } else {
        kind = s->kind == SK::Break ? 3 : 4;
        auto it = sema_.excJumpCross.find(s);
        if (it == sema_.excJumpCross.end()) return false;
        cross = it->second;
    }
    line("{");
    indent_++;
    if (kind == 2) {
        auto* rs = static_cast<ReturnStmt*>(s);
        // El valor se calcula dentro del 'try' (una excepción al calcularlo la atrapa este 'try').
        if (rs->value)
            line(excRetVar_ + " = " + (curMethod_ && curMethod_->retIsRef() ? "&" : "") + expr(rs->value) + ";");
    }
    emitExcJumpChain(kind, cross);
    indent_--;
    line("}");
    return true;
}

void CodeGen::emitTry(TryStmt* t) {
    bool outermost = excRegions_.empty();
    std::string savedRet = excRetVar_;
    line("{");
    indent_++;
    if (outermost) {
        excRetVar_.clear();
        if (curMethod_ && !curMethod_->ret->isVoid()) {
            excRetVar_ = "fs_ret" + std::to_string(tmp_++);
            line(ctype(curMethod_->ret) + (curMethod_->retIsRef() ? "*" : "") + " volatile " + excRetVar_ + ";");
        }
    }
    if (!t->finallyBody) {
        emitTryCatch(t);
    } else {
        int id = tmp_++;
        std::string f = "fs_f" + std::to_string(id), why = "fs_why" + std::to_string(id);
        line("faset_exc_frame " + f + ";");
        line("int32_t volatile " + why + " = 0;");
        line("FASET_TRY(" + f + ") {");
        indent_++;
        ExcRegion reg;
        reg.finally = true;
        reg.frame = f;
        reg.id = id;
        reg.method = curMethod_;
        excRegions_.push_back(reg);
        if (t->catches.empty()) emitStmt(t->body);
        else emitTryCatch(t);
        line("faset_exc_top = " + f + ".prev;");
        reg = excRegions_.back();
        excRegions_.pop_back();
        indent_--;
        line("} else " + why + " = 1;");
        line("fs_fin" + std::to_string(id) + ": ;");
        emitStmt(t->finallyBody);
        line("if (" + why + " == 1) faset_exc_rethrow(&" + f + ");");
        // Saltos pendientes: continúan desde aquí (pueden atravesar más zonas hacia fuera).
        auto pending = [&](int kind, int cross) {
            line("if (" + why + " == " + std::to_string(kind) + ") {");
            indent_++;
            emitExcJumpChain(kind, cross);
            indent_--;
            line("}");
        };
        if (reg.ret) pending(2, (int)excRegions_.size());
        if (reg.breakRemain >= 0) pending(3, reg.breakRemain);
        if (reg.contRemain >= 0) pending(4, reg.contRemain);
    }
    if (outermost) excRetVar_ = savedRet;
    indent_--;
    line("}");
}

void CodeGen::emitTryCatch(TryStmt* t) {
    int id = tmp_++;
    std::string f = "fs_c" + std::to_string(id), done = "fs_cdone" + std::to_string(id);
    line("faset_exc_frame " + f + ";");
    line("FASET_TRY(" + f + ") {");
    indent_++;
    ExcRegion reg;
    reg.frame = f;
    reg.id = id;
    reg.method = curMethod_;
    excRegions_.push_back(reg);
    emitStmt(t->body);
    excRegions_.pop_back();
    line("faset_exc_top = " + f + ".prev;");
    indent_--;
    line("} else {");
    indent_++;
    // Aquí el marco ya está desapilado: las cláusulas corren fuera de su zona protegida.
    excCatchFrames_.push_back(f);
    for (auto& c : t->catches) {
        ClassDecl* cls = c.type && c.type->isClass() ? c.type->decl : nullptr;
        bool all = !cls || cls == sema_.exceptionClass;
        line(all ? "{" : "if (faset_exc_is(" + f + ".type, &fs__exct_" + cls->cname + ")) {");
        indent_++;
        if (c.var) {
            std::string ct = ctype(c.type);
            line(ct + (c.var->isVolatile ? " volatile " : " ") + c.var->cname + " = (" + ct + ")" + f + ".obj;");
        }
        if (c.filter) {
            line("if (" + expr(c.filter) + ") {");
            indent_++;
        }
        emitStmt(c.body);
        line("goto " + done + ";");
        if (c.filter) {
            indent_--;
            line("}");
        }
        indent_--;
        line("}");
    }
    excCatchFrames_.pop_back();
    line("faset_exc_rethrow(&" + f + ");");
    indent_--;
    line("}");
    line(done + ": ;");
}
