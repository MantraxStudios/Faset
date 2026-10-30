#include "CodeGen.h"

#include <cstdio>

#include "Frontend.h"  // nativeToUtf8
#include "Runtime.h"

namespace {

bool hasExportAttr(MethodDecl* m) {
    for (Attribute& a : m->attrs)
        if (a.name == "Export") return true;
    return false;
}

bool isLValue(Expr* e) { return cgIsLValue(e); }

}  // namespace

// Versión local de "es un lvalue" para decidir si podemos tomar '&' del receptor.
bool cgIsLValue(Expr* e) {
    switch (e->kind) {
        case EK::Name: {
            auto r = static_cast<NameExpr*>(e)->ref;
            return r == NameExpr::Ref::Local || r == NameExpr::Ref::Field || r == NameExpr::Ref::StaticField;
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            if (m->ref == MemberExpr::Ref::StaticField) return true;
            if (m->ref != MemberExpr::Ref::Field) return false;
            return m->arrow || m->obj->type->isClass() || isLValue(m->obj);
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            return ix->opMethod ? ix->opMethod->retIsRef() : ix->obj->type->isPointer();
        }
        case EK::Call: {
            auto* c = static_cast<CallExpr*>(e);
            return c->target && c->target->retIsRef();
        }
        case EK::Unary: return static_cast<UnaryExpr*>(e)->op == "*";
        case EK::This: return true;
        default: return false;
    }
}

namespace {

// ¿El tipo no contiene punteros, referencias ni cadenas? (su memoria no hace falta recorrerla)
bool pointerFree(Type* t, int depth = 0) {
    if (t->isNumeric() || t->isEnum() || t->is(TK::Bool)) return true;
    if (!t->isStruct() || depth > 16) return false;
    for (FieldDecl* f : t->decl->fields)
        if (!f->isStatic() && !pointerFree(f->type, depth + 1)) return false;
    return true;
}

// ¿Se debe emitir este método? (las plantillas no; las instancias solo si se usaron)
bool shouldEmit(MethodDecl* m) { return m && !m->isTemplate() && m->body && m->checked; }

}  // namespace

// ------------------------------------------------------------------ utilidades

std::string CodeGen::ctype(Type* t) {
    switch (t->kind) {
        case TK::Void: return "void";
        case TK::Bool: return "_Bool";
        case TK::Char: return "uint32_t";
        case TK::SByte: return "int8_t";
        case TK::Byte: return "uint8_t";
        case TK::Short: return "int16_t";
        case TK::UShort: return "uint16_t";
        case TK::Int: return "int32_t";
        case TK::UInt: return "uint32_t";
        case TK::Long: return "int64_t";
        case TK::ULong: return "uint64_t";
        case TK::Float: return "float";
        case TK::Double: return "double";
        case TK::String: return "faset_string";
        case TK::Null: return "void*";
        case TK::Pointer: return ctype(t->elem) + "*";
        case TK::Class: return t->decl->cname + "*";
        case TK::Struct: return t->decl->cname;
        case TK::Enum: return "int32_t";
        case TK::FuncPtr: return "faset_fn" + std::to_string(t->id);
        case TK::Delegate: return "faset_delegate*";
        case TK::Pending: return "void*";
        case TK::Error: return "int";
    }
    return "int";
}

std::string CodeGen::zeroInit(Type* t) { return (t->isStruct() || t->is(TK::String)) ? "{0}" : "0"; }

std::string CodeGen::cstring(const std::string& s) {
    std::string r = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') {
            r += '\\';
            r += (char)c;
        } else if (c >= 0x20 && c < 0x7F && c != '?') {
            r += (char)c;
        } else {
            char buf[8];
            std::snprintf(buf, sizeof buf, "\\%03o", c);
            r += buf;
        }
    }
    return r + "\"";
}

std::string CodeGen::signature(MethodDecl* m) {
    std::string ret = ctype(m->ret) + (m->retIsRef() ? "*" : "");
    std::string s = (hasExportAttr(m) ? "FASET_EXPORT " : "") + ret + " " + m->cname + "(";
    std::vector<std::string> ps;
    if (!m->isStatic()) ps.push_back(m->objSelf ? objC() + "* faset_self" : m->owner->cname + "* self");
    for (Param& p : m->params)
        ps.push_back(ctype(p.type) + (p.isRef() ? "*" : "") + (p.var && p.var->isVolatile ? " volatile" : "") + " p_" + p.name);
    // [TrackCaller]: parámetros ocultos con la ubicación de la llamada.
    if (m->trackCaller) {
        ps.push_back("const char* fs_file");
        ps.push_back("int32_t fs_line");
    }
    if (m->variadic) ps.push_back("...");
    if (ps.empty()) ps.push_back("void");
    for (size_t i = 0; i < ps.size(); i++) s += (i ? ", " : "") + ps[i];
    return s + ")";
}

std::string CodeGen::ctorParams(MethodDecl* ctor, bool withTypes) {
    std::string s;
    if (ctor) {
        for (size_t i = 0; i < ctor->params.size(); i++) {
            Param& p = ctor->params[i];
            s += (i ? ", " : "") +
                 (withTypes ? ctype(p.type) + (p.isRef() ? "*" : "") + " " : std::string()) + "p_" + p.name;
        }
    }
    if (s.empty() && withTypes) s = "void";
    return s;
}

void CodeGen::line(const std::string& s) {
    if (lineDirectives && curLoc_.file >= 0) lineDirective(curLoc_);  // depuración: línea de Faset
    out_ << std::string(indent_ * 4, ' ') << s << "\n";
}

// Una ubicación oculta (file < 0: código generado, sin posición en el editor) no tiene archivo.
std::string CodeGen::loc(SourceLoc l) {
    if (l.file < 0) return "\"?\", " + std::to_string(l.line);
    return "fs__f" + std::to_string(l.file) + ", " + std::to_string(l.line);
}

// Dentro de un método [TrackCaller] se reenvía la ubicación que recibió (como en Rust).
std::string CodeGen::callerLoc(SourceLoc l) {
    if (curMethod_ && curMethod_->trackCaller) return "fs_file, fs_line";
    return loc(l);
}

// Comprueba que una referencia a clase no es nula (y, con checks, que no se usó tras 'delete').
std::string CodeGen::chkObj(Expr* obj, const std::string& code) {
    if (obj->kind == EK::This) return code;
    return "((" + ctype(obj->type) + ")faset_chk_obj((void*)" + code + ", " + callerLoc(obj->loc) + "))";
}

// ------------------------------------------------------------------ programa

std::string CodeGen::generate(bool shared) {
    out_ << "/* Generado por fasetc. No editar a mano. */\n";
    if (checks) out_ << "#ifndef FASET_CHECKS\n#define FASET_CHECKS 1\n#endif\n";
    if (lineDirectives) out_ << "#define FASET_DEBUG_INFO 1\n";
    out_ << kRuntimeHeader << kRuntimeExcHeader << kRuntimeSugarHeader << "\n";
    out_ << kDelegateRuntime << "\n";
    // Nombres de archivo para los mensajes de 'panic' (Faset panic: ... at archivo.fst:línea), en
    // UTF-8 como el resto de la salida del programa (en Windows diag.files está en la página ANSI).
    for (size_t i = 0; i < diag.files.size(); i++)
        out_ << "static const char fs__f" << i << "[] = " << cstring(nativeToUtf8(diag.files[i])) << ";\n";
    out_ << "\n";

    for (ClassDecl* c : sema_.structOrder) out_ << "typedef struct " << c->cname << " " << c->cname << ";\n";
    emitOO(0);  // descripciones de tipos (runtime) y tipos de las interfaces
    out_ << "\n";
    emitDebugEnums();
    // Punteros a función (después de las declaraciones de structs).
    for (Type* f : tc_.funcPtrs()) {
        out_ << "typedef " << ctype(f->ret) << " (*" << ctype(f) << ")(";
        if (f->params.empty()) out_ << "void";
        for (size_t i = 0; i < f->params.size(); i++) out_ << (i ? ", " : "") << ctype(f->params[i]);
        out_ << ");\n";
    }
    out_ << "\n";
    for (ClassDecl* c : sema_.structOrder) {
        out_ << "struct " << c->cname << " {\n";
        int n = 0;
        if (c->kind == ClassKind::Class) {  // la base incrustada (o el puntero al tipo, en object)
            emitClassStructPrefix(c);
            n++;
        }
        for (FieldDecl* f : c->fields) {
            if (f->isStatic()) continue;
            out_ << "    " << localType(f->type) << " " << f->cname << ";\n";
            n++;
        }
        if (n == 0) out_ << "    char faset_vacio;\n";
        out_ << "};\n\n";
    }
    emitDelegateSupport();
    emitExcDecls();  // descriptores de las clases de excepción (Exceptions.cpp)

    std::vector<MethodDecl*> allMethods;
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate() || c->kind == ClassKind::Enum) continue;
        for (MethodDecl* m : c->methods) allMethods.push_back(m);
        for (MethodDecl* m : c->ctors) allMethods.push_back(m);
        if (c->dtor) allMethods.push_back(c->dtor);
    }
    allMethods.insert(allMethods.end(), sema_.genericMethods.begin(), sema_.genericMethods.end());

    // Prototipos.
    std::set<std::string> externs;
    for (MethodDecl* m : allMethods) {
        if (m->mods.isExtern && m->signatureDone) {
            if (externs.insert(m->cname).second) out_ << signature(m) << ";\n";
        } else if (shouldEmit(m)) {
            out_ << signature(m) << ";\n";
        }
    }
    for (ClassDecl* c : prog_.types) {
        if (!c->hasLayout()) continue;
        out_ << "static void " << c->cname << "__init(" << c->cname << "* self);\n";
        bool isClass = c->kind == ClassKind::Class;
        std::string ret = isClass ? c->cname + "*" : c->cname;
        const char* kind = isClass ? "__new" : "__make";
        if (c->ctors.empty() || !isClass) out_ << ret << " " << c->cname << kind << "d(void);\n";
        for (size_t i = 0; i < c->ctors.size(); i++)
            if (shouldEmit(c->ctors[i]))
                out_ << ret << " " << c->cname << kind << i << "(" << ctorParams(c->ctors[i], true) << ");\n";
    }
    out_ << "static void fs__static_init(void);\n\n";
    emitLambdaDecls();
    emitOO(1);  // vtables, thunks de despacho, descripciones de tipos

    // Campos estáticos y variables globales.
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate()) continue;
        for (FieldDecl* f : c->fields)
            if (f->isStatic()) out_ << ctype(f->type) << " " << f->cname << " = " << zeroInit(f->type) << ";\n";
    }
    out_ << "\n";

    // Cuerpos (las funciones auxiliares del azúcar, helpers_, se insertan antes de ellos).
    std::string head = out_.str();
    out_.str("");
    out_.clear();
    resetLoc();
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate() || c->kind == ClassKind::Enum) continue;
        if (c->hasLayout()) {
            curClass_ = c;
            emitConstructionHelpers(c);
        }
    }
    for (MethodDecl* m : allMethods)
        if (shouldEmit(m)) {
            curClass_ = m->owner;
            emitMethod(m);
        }
    emitLambdaBodies();

    emitExcHelpers();

    // Inicialización estática, en orden.
    resetLoc();
    out_ << "static void fs__static_init(void) {\n";
    indent_ = 1;
    if (sema_.exceptionClass) line("fs__exc_setup();");
    pushHoist();
    for (FieldDecl* f : sema_.staticInits) {
        curClass_ = f->owner;
        if (f->staticCtor) line(expr(f->init) + ";");  // static Clase() (StaticInit.cpp)
        else line(f->cname + " = " + expr(f->init) + ";");
    }
    popHoist();
    indent_ = 0;
    out_ << "}\n\n";

    if (shared) {
        out_ << "#if defined(__GNUC__) || defined(__clang__)\n__attribute__((constructor))\n#endif\n";
        out_ << "static void fs__lib_init(void) {\n    faset_rt_init(0, 0);\n    fs__static_init();\n}\n";
    } else if (MethodDecl* m = sema_.entry) {
        out_ << "int main(int argc, char** argv) {\n";
        out_ << "    faset_rt_init(argc, argv);\n";
        out_ << "    fs__static_init();\n";
        std::string call = m->cname + (m->params.empty() ? "()" : "(argc, (uint8_t**)argv)");
        if (MethodDecl* w = sema_.entryWait) {  // Main async: espera la tarea y relanza su excepción
            out_ << "    void* fs_main_task = (void*)" << call << ";\n";
            out_ << "    " << w->cname << "((" << ctype(w->params[0].type) << ")fs_main_task);\n";
            if (FieldDecl* f = sema_.entryResult) {
                out_ << "    int32_t r = ((" << m->ret->decl->cname << "*)fs_main_task)->" << fieldPath(m->ret->decl, f) << ";\n";
                out_ << "    faset_rt_exit();\n    return (int)r;\n";
            } else {
                out_ << "    faset_rt_exit();\n    return 0;\n";
            }
        } else if (m->ret->isVoid()) {
            out_ << "    " << call << ";\n";
            out_ << "    faset_rt_exit();\n    return 0;\n";
        } else {
            out_ << "    int32_t r = " << call << ";\n";
            out_ << "    faset_rt_exit();\n    return (int)r;\n";
        }
        out_ << "}\n";
    }
    return finishLineDirectives(head + helpers_ + out_.str());
}

void CodeGen::emitConstructionHelpers(ClassDecl* c) {
    out_ << "static void " << c->cname << "__init(" << c->cname << "* self) {\n";
    indent_ = 1;
    pushHoist();
    line("(void)self;");
    emitExcInit(c);  // excepciones: tipo dinámico y nombre del tipo
    for (FieldDecl* f : c->fields)
        if (!f->isStatic() && f->init) line("self->" + f->cname + " = " + expr(f->init) + ";");
    popHoist();
    indent_ = 0;
    out_ << "}\n\n";

    bool isClass = c->kind == ClassKind::Class;
    auto emitOne = [&](MethodDecl* ctor, const std::string& name) {
        std::string params = ctorParams(ctor, true);
        std::string args = ctorParams(ctor, false);
        if (isClass) {
            out_ << c->cname << "* " << name << "(" << params << ") {\n";
            // El destructor (en cadena: derivada y luego base) queda en la cabecera: lo ejecutan
            // 'delete' o el recolector. El primer campo apunta a la descripción del tipo (vtable).
            std::string dtor = hasDtorChain(c) ? c->cname + "__dtorchain" : "0";
            out_ << "    " << c->cname << "* self = (" << c->cname << "*)faset_obj_alloc((int64_t)sizeof(" << c->cname
                 << "), " << dtor << ");\n";
            out_ << "    *(const faset_type**)self = " << tiOf(c) << ";\n";
            if (ctor) out_ << "    " << ctor->cname << "(self" << (args.empty() ? "" : ", " + args) << ");\n";
            else out_ << "    " << c->cname << "__ctord(self);\n";
            // Excepciones: el constructor de la base pone su propio tipo; el dinámico es el de 'new'.
            indent_ = 1;
            emitExcInit(c);
            indent_ = 0;
            out_ << "    return self;\n}\n\n";
        } else {
            out_ << c->cname << " " << name << "(" << params << ") {\n";
            out_ << "    " << c->cname << " v = {0};\n";
            out_ << "    " << c->cname << "__init(&v);\n";
            if (ctor) out_ << "    " << ctor->cname << "(&v" << (args.empty() ? "" : ", " + args) << ");\n";
            out_ << "    return v;\n}\n\n";
        }
    };
    const char* kind = isClass ? "__new" : "__make";
    if (c->ctors.empty() || !isClass) emitOne(nullptr, c->cname + kind + "d");
    for (size_t i = 0; i < c->ctors.size(); i++)
        if (shouldEmit(c->ctors[i])) emitOne(c->ctors[i], c->cname + kind + std::to_string(i));
}

void CodeGen::emitMethod(MethodDecl* m) {
    if (m->async) {  // máquina de estados (CodeGenAsync.cpp)
        emitAsyncMethod(m);
        return;
    }
    curMethod_ = m;
    setLoc(m->loc);
    lineDirective(m->loc);
    out_ << signature(m) << " {\n";
    indent_ = 1;
    pushHoist();          // temporales de expresión (SugarGen.cpp)
    usings_.push_back({});  // objetos de 'using var' del cuerpo
    if (m->objSelf) line(m->owner->cname + "* self = (" + m->owner->cname + "*)faset_self;");
    if (!m->isStatic()) line("(void)self;");
    for (VarInfo* v : m->patternVars) line(ctype(v->type) + " " + v->cname + " = " + zeroInit(v->type) + ";");  // 'is T x', 'out var x'
    if (m->recordGen) {
        emitRecordBody(m);
        usings_.pop_back();
        popHoist();
        indent_ = 0;
        out_ << "}\n\n";
        curMethod_ = nullptr;
        return;
    }
    std::vector<VarInfo*> params;
    for (Param& p : m->params) params.push_back(p.var);
    boxParams(params);  // parámetros capturados por lambdas
    for (Param& p : m->params)  // ver emitLocalDecl: 'volatile' y pasados por 'ref' dentro de un 'try'
        if (p.var && p.var->isVolatile && !p.var->captured && !p.isRef()) line("FASET_ESCAPE(&p_" + p.name + ");");
    if (m->kind == MethodKind::Ctor) emitCtorPrologue(m);
    for (Stmt* s : m->body->stmts) emitStmt(s);
    if (std::string clean = usingCleanup(0); !clean.empty()) line(clean);
    usings_.pop_back();
    popHoist();
    indent_ = 0;
    lineDirective(m->body->endLoc);  // epílogo en la '}' del método
    out_ << "}\n\n";
    curMethod_ = nullptr;
}

// ------------------------------------------------------------------ sentencias

void CodeGen::emitBody(Stmt* s) {
    if (s->kind == SK::Block) {
        emitStmt(s);
        return;
    }
    line("{");
    indent_++;
    emitStmt(s);
    indent_--;
    line("}");
}

void CodeGen::emitStmt(Stmt* s) {
    if (s->kind != SK::Block && s->kind != SK::Empty) setLoc(s->loc);
    if (async_ && s->kind == SK::Return && !s->lowered) {  // 'return' de un método async (CodeGenAsync.cpp)
        emitAsyncReturn(static_cast<ReturnStmt*>(s));
        return;
    }
    if (emitSugarStmt(s)) return;  // formas reescritas, bloques y 'using' (SugarGen.cpp)
    switch (s->kind) {
        case SK::Empty: break;
        case SK::Block: {
            line("{");
            indent_++;
            for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) emitStmt(c);
            indent_--;
            line("}");
            break;
        }
        case SK::VarDecl: {
            auto* d = static_cast<VarDeclStmt*>(s);
            for (auto& dc : d->decls) {
                Type* t = dc.var->type;
                std::string vq = dc.var->isVolatile ? " volatile " : " ";  // modificada dentro de un 'try'
                if (dc.var->captured) declareLocalVar(dc.var, dc.init ? expr(dc.init) : "");  // caja compartida con lambdas
                else if (dc.var->isRef) emitLocalDecl(ctype(t) + "*", dc.var->cname, "&" + expr(dc.init));
                else emitLocalDecl(localType(t), dc.var->cname, dc.init ? expr(dc.init) : zeroInit(t), vq);
            }
            break;
        }
        case SK::ExprStmt: line(expr(static_cast<ExprStmt*>(s)->expr) + ";"); break;
        case SK::If: {
            auto* is = static_cast<IfStmt*>(s);
            line("if (" + expr(is->cond) + ")");
            emitBody(is->then);
            if (is->els) {
                line("else");
                emitBody(is->els);
            }
            break;
        }
        case SK::While: {
            auto* ws = static_cast<WhileStmt*>(s);
            line("while (" + expr(ws->cond) + ")");
            emitBody(ws->body);
            break;
        }
        case SK::DoWhile: {
            auto* ds = static_cast<DoWhileStmt*>(s);
            line("do");
            emitBody(ds->body);
            setLoc(ds->cond->loc);
            line("while (" + expr(ds->cond) + ");");
            break;
        }
        case SK::For: {
            auto* fs = static_cast<ForStmt*>(s);
            line("{");
            indent_++;
            if (fs->initDecl) emitStmt(fs->initDecl);
            setLoc(fs->loc);
            std::string init, iter;
            for (size_t i = 0; i < fs->initExprs.size(); i++) init += (i ? ", " : "") + expr(fs->initExprs[i]);
            for (size_t i = 0; i < fs->iter.size(); i++) iter += (i ? ", " : "") + expr(fs->iter[i]);
            line("for (" + init + "; " + (fs->cond ? expr(fs->cond) : "") + "; " + iter + ")");
            emitBody(fs->body);
            indent_--;
            line("}");
            break;
        }
        case SK::Break: if (!emitExcJump(s)) line("break;"); break;
        case SK::Continue: if (!emitExcJump(s)) line("continue;"); break;
        case SK::Return: {
            auto* rs = static_cast<ReturnStmt*>(s);
            if (emitExcJump(s)) break;  // sale de un 'try': pasa por los 'finally' (Exceptions.cpp)
            if (!rs->value) line("return;");
            else if (curMethod_ && curMethod_->retIsRef()) line("return &" + expr(rs->value) + ";");
            else line("return " + expr(rs->value) + ";");
            break;
        }
        case SK::Switch: {
            auto* ss = static_cast<SwitchStmt*>(s);
            line("switch (" + expr(ss->subject) + ") {");
            for (auto& sec : ss->sections) {
                std::string labels;
                for (int64_t v : sec.values) labels += "case " + std::to_string(v) + (v < 0 ? "LL" : "") + ": ";
                if (sec.hasDefault) labels += "default: ";
                line(labels + "{");
                indent_++;
                for (Stmt* b : sec.body) emitStmt(b);
                indent_--;
                line("}");
            }
            line("}");
            break;
        }
        case SK::Delete: {
            auto* ds = static_cast<DeleteStmt*>(s);
            Type* t = ds->expr->type;
            ClassDecl* target = nullptr;
            if (t->isClass()) target = t->decl;
            else if (t->isPointer() && t->elem->isStruct()) target = t->elem->decl;
            if (t->isClass()) {
                // Objeto de clase: ejecuta su destructor una vez; la memoria la recupera el
                // recolector cuando ya nadie la alcanza (con checks, el uso posterior es un panic).
                line("faset_obj_delete((void*)" + expr(ds->expr) + ", " + callerLoc(ds->loc) + ");");
            } else if (target && target->dtor && !ds->isArray) {
                std::string tmp = "faset_tmp" + std::to_string(tmp_++);
                line("{");
                indent_++;
                line(target->cname + "* " + tmp + " = " + expr(ds->expr) + ";");
                line("if (" + tmp + ") { " + target->dtor->cname + "(" + tmp + "); faset_free(" + tmp + "); }");
                indent_--;
                line("}");
            } else {
                line("faset_free((void*)" + expr(ds->expr) + ");");
            }
            break;
        }
        case SK::Try: emitTry(static_cast<TryStmt*>(s)); break;
        case SK::Throw: emitThrow(static_cast<ThrowStmt*>(s)); break;
        case SK::Await: emitAwait(static_cast<AwaitStmt*>(s)); break;  // CodeGenAsync.cpp
        case SK::Yield: emitYield(static_cast<YieldStmt*>(s)); break;  // CodeGenIterators.cpp
        default: break;  // SK del azúcar: SugarGen.cpp
    }
}

// ------------------------------------------------------------------ expresiones

std::string CodeGen::memberAccess(Expr* obj, bool arrow, const std::string& field) {
    Type* ot = obj->type;
    std::string o = expr(obj);
    if (arrow) {
        if (ot->elem->isClass()) return "(*" + o + ")->" + field;
        return "(" + o + ")->" + field;
    }
    if (ot->isClass()) return "(" + chkObj(obj, o) + ")->" + field;
    return "(" + o + ")." + field;
}

std::string CodeGen::receiverPtr(Expr* recv, bool arrow) {
    std::string r = expr(recv);
    Type* t = recv->type;
    if (arrow) return t->elem->isClass() ? "(*" + r + ")" : r;
    if (t->isClass()) return chkObj(recv, r);
    if (isLValue(recv)) return "(&" + r + ")";
    // Receptor temporal (p. ej. resultado de una llamada): literal compuesto de C99.
    return "((" + t->decl->cname + "[]){" + r + "})";
}

std::string CodeGen::call(MethodDecl* m, const std::string& self, const std::vector<Expr*>& args, SourceLoc at,
                          bool nonVirtual, Expr* recv, bool recvArrow) {
    // Receptor y argumentos en el orden de C# (EvalOrder.cpp).
    std::vector<EvalOp> ops;
    if (recv) ops.push_back(recvOp(recv, recvArrow));
    for (size_t i = 0; i < args.size(); i++) {
        EvalOp op;
        op.e = args[i];
        op.code = expr(args[i]);
        op.ct = ctype(args[i]->type);
        op.addr = i < m->params.size() && m->params[i].isRef();
        ops.push_back(op);
    }
    std::string pre = sequenceArgs(ops, recv ? 1 : 0);  // en el orden del código (argumentos con nombre)
    std::string selfCode = recv ? recvCode(ops[0], recv, recvArrow) : self;
    std::vector<std::string> codes;
    for (size_t i = recv ? 1 : 0; i < ops.size(); i++) codes.push_back(ops[i].addr ? "(&" + ops[i].code + ")" : ops[i].code);
    std::string s = callCode(m, selfCode, codes, at, nonVirtual);
    return m->retIsRef() ? seqWrapLv(pre, s) : seqWrap(pre, s);
}

std::string CodeGen::callCode(MethodDecl* m, const std::string& self, const std::vector<std::string>& args, SourceLoc at,
                              bool nonVirtual) {
    std::vector<std::string> parts;
    if (!m->isStatic()) parts.push_back(selfArg(m, self));
    for (size_t i = 0; i < args.size(); i++) {
        parts.push_back(args[i]);
        if (m->trackCaller && i + 1 == m->params.size()) parts.push_back(callerLoc(at));
    }
    if (m->trackCaller && m->params.empty()) parts.push_back(callerLoc(at));
    std::string s = calleeName(m, nonVirtual) + "(";
    for (size_t i = 0; i < parts.size(); i++) s += (i ? ", " : "") + parts[i];
    s += ")";
    return m->retIsRef() ? "(*" + s + ")" : s;
}

// Valor convertido a cadena para la concatenación con '+' (mismo formato que Console.Write).
std::string CodeGen::toStr(Expr* e) {
    Type* t = e->type;
    std::string v = expr(e);
    if (t->is(TK::String)) return v;
    if (t->is(TK::Bool)) return "((" + v + ") ? FASET_STR(\"True\", 4) : FASET_STR(\"False\", 5))";
    if (t->is(TK::Char)) return "faset_char_to_str(" + v + ")";
    if (t->is(TK::Float)) return "faset_f32_to_str(" + v + ")";
    if (t->is(TK::Double)) return "faset_f64_to_str(" + v + ")";
    if (t->isClass()) return strOf(t, v);  // ToString() virtual; null -> ""
    if (t->isUnsignedInt()) return "faset_u64_to_str((uint64_t)(" + v + "))";
    if (t->isAggregate()) return toStrCode(t, v);  // tuplas, T? y ToString() (SugarGen.cpp)
    return "faset_i64_to_str((int64_t)(" + v + "))";
}

std::string CodeGen::expr(Expr* e) {
    if (e->lowered) return expr(e->lowered);           // forma reescrita por Sema (Sugar.cpp)
    if (isSugarKind(e->kind)) return sugarExpr(e);     // SugarGen.cpp
    switch (e->kind) {
        case EK::IntLit: {
            uint64_t v = static_cast<IntLitExpr*>(e)->value;
            switch (e->type->kind) {
                case TK::Int: return std::to_string(v);
                case TK::UInt: return std::to_string(v) + "u";
                case TK::Long: return std::to_string(v) + "LL";
                default: return std::to_string(v) + "ULL";
            }
        }
        case EK::FloatLit: {
            auto* f = static_cast<FloatLitExpr*>(e);
            char buf[64];
            std::snprintf(buf, sizeof buf, "%.17g", f->value);
            std::string s = buf;
            if (s.find_first_of(".en") == std::string::npos) s += ".0";
            return f->isFloat32 ? s + "f" : s;
        }
        case EK::BoolLit: return static_cast<BoolLitExpr*>(e)->value ? "1" : "0";
        case EK::CharLit: return "((uint32_t)" + std::to_string(static_cast<CharLitExpr*>(e)->value) + "u)";
        case EK::StringLit: {
            auto* s = static_cast<StringLitExpr*>(e);
            return "FASET_STR(" + cstring(s->value) + ", " + std::to_string(s->value.size()) + ")";
        }
        case EK::Null: return "((void*)0)";
        case EK::This: return curClass_->kind == ClassKind::Struct ? "(*self)" : "self";
        case EK::Default: {
            Type* t = e->type;
            if (t->isStruct() || t->is(TK::String)) return "((" + ctype(t) + "){0})";
            return "((" + ctype(t) + ")0)";
        }
        case EK::Name: {
            auto* n = static_cast<NameExpr*>(e);
            switch (n->ref) {
                case NameExpr::Ref::Local: return localRef(n->var);
                case NameExpr::Ref::Field: return "self->" + fieldPath(curClass_, n->field);
                case NameExpr::Ref::Base: return "((" + n->type->decl->cname + "*)self)";
                case NameExpr::Ref::StaticField: return n->field->cname;
                case NameExpr::Ref::Property: return call(n->getter, "self", {}, n->loc);
                default: return "/*?*/0";
            }
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            switch (m->ref) {
                case MemberExpr::Ref::Field: {
                    Type* ot = m->arrow ? m->obj->type->elem : m->obj->type;
                    return memberAccess(m->obj, m->arrow, ot->isAggregate() ? fieldPath(ot->decl, m->field) : m->field->cname);
                }
                case MemberExpr::Ref::StaticField: return m->field->cname;
                case MemberExpr::Ref::EnumConst: return "((int32_t)" + std::to_string((int64_t)m->constBits) + "LL)";
                case MemberExpr::Ref::ConstInt: return "((" + ctype(m->type) + ")" + std::to_string(m->constBits) + "ULL)";
                case MemberExpr::Ref::StrLength: return "((int32_t)" + memberAccess(m->obj, m->arrow, "len") + ")";
                case MemberExpr::Ref::StrPtr: return "((uint8_t*)" + memberAccess(m->obj, m->arrow, "ptr") + ")";
                case MemberExpr::Ref::Property:
                    if (std::string s; arrayLengthCode(m, s)) return s;  // a.Length (CodeGenArrays.cpp)
                    return call(m->getter, m->getter->isStatic() ? "" : receiverPtr(m->obj, m->arrow), {}, m->loc,
                                m->nonVirtual);
                case MemberExpr::Ref::DelegateInvoke: return expr(m->obj);
                default: return "/*?*/0";
            }
        }
        case EK::Call: {
            auto* c = static_cast<CallExpr*>(e);
            if (!c->target && c->callee->type->isDelegate()) return delegateCall(c);
            if (!c->target) {  // puntero a función: primero el puntero, después los argumentos
                std::vector<EvalOp> ops(1 + c->args.size());
                ops[0] = {c->callee, expr(c->callee), ctype(c->callee->type)};
                for (size_t i = 0; i < c->args.size(); i++) ops[i + 1] = {c->args[i], expr(c->args[i]), ctype(c->args[i]->type)};
                std::string pre = sequence(ops);
                std::string fn = "((" + ctype(c->callee->type) + ")faset_chk_fn((void*)" + ops[0].code + ", " + callerLoc(c->loc) + "))";
                std::string s = "(" + fn + ")(";
                for (size_t i = 0; i < c->args.size(); i++) s += (i ? ", " : "") + ops[i + 1].code;
                return seqWrap(pre, s + ")");
            }
            if (c->intrinsic == 1)  // ToString() de un enum: nombre del miembro
                return c->receiver->type->decl->cname + "__name(" + expr(c->receiver) + ")";
            if (!c->target->isStatic() && !c->implicitThis)  // el receptor se evalúa antes que los argumentos
                return call(c->target, "", c->args, c->loc, c->nonVirtual, c->receiver, c->receiverArrow);
            return call(c->target, c->target->isStatic() ? "" : "self", c->args, c->loc, c->nonVirtual);
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            if (std::string s; arrayIndexCode(ix, s)) return s;  // T[]: límites + acceso directo (CodeGenArrays.cpp)
            if (ix->opMethod) return call(ix->opMethod, "", {ix->index}, ix->loc, false, ix->obj, false);
            std::vector<EvalOp> ops = {{ix->obj, expr(ix->obj), ctype(ix->obj->type)},
                                       {ix->index, expr(ix->index), ctype(ix->index->type)}};
            std::string pre = sequence(ops);  // a[i]: primero 'a', después 'i' (EvalOrder.cpp)
            if (ix->obj->type->is(TK::String))
                return seqWrap(pre, "faset_str_at(" + ops[0].code + ", " + ops[1].code + ", " + callerLoc(ix->loc) + ")");
            return seqWrapLv(pre, "(" + ops[0].code + ")[" + ops[1].code + "]");
        }
        case EK::Unary: {
            auto* u = static_cast<UnaryExpr*>(e);
            if (u->funcRef) return "(&" + u->funcRef->cname + ")";
            if (u->opMethod) return call(u->opMethod, "", {u->operand}, u->loc);
            if (u->op == "-" && u->operand->kind == EK::IntLit) {
                uint64_t v = static_cast<IntLitExpr*>(u->operand)->value;
                return "((" + ctype(e->type) + ")(0ULL - " + std::to_string(v) + "ULL))";
            }
            return "(" + u->op + expr(u->operand) + ")";
        }
        case EK::Postfix: {
            auto* p = static_cast<PostfixExpr*>(e);
            return "(" + expr(p->operand) + p->op + ")";
        }
        case EK::Binary: {
            auto* b = static_cast<BinaryExpr*>(e);
            if (b->opMethod) {
                std::string c = call(b->opMethod, "", {b->lhs, b->rhs}, b->loc);
                return b->negate ? "(!" + c + ")" : c;
            }
            // Operandos de izquierda a derecha (EvalOrder.cpp); && y || ya están secuenciados en C.
            bool seq = b->op != "&&" && b->op != "||";
            if (b->op == "+" && e->type->is(TK::String)) {
                std::vector<EvalOp> ops = {{b->lhs, toStr(b->lhs), "faset_string"}, {b->rhs, toStr(b->rhs), "faset_string"}};
                ops[0].conv = ops[1].conv = true;
                std::string pre = sequence(ops);
                return seqWrap(pre, "faset_str_concat(" + ops[0].code + ", " + ops[1].code + ")");
            }
            std::vector<EvalOp> ops = {{b->lhs, expr(b->lhs), ctype(b->lhs->type)}, {b->rhs, expr(b->rhs), ctype(b->rhs->type)}};
            std::string pre = seq ? sequence(ops) : "";
            std::string l = ops[0].code, r = ops[1].code;
            auto wrap = [&](const std::string& c) { return seqWrap(pre, c); };
            if ((b->op == "==" || b->op == "!=") && b->lhs->type->isDelegate() && b->rhs->type->isDelegate()) {
                std::string c = "faset_dlg_eq(" + l + ", " + r + ")";
                return wrap(b->op == "==" ? c : "(!" + c + ")");
            }
            Type* lt = b->lhs->type;
            if (lt->is(TK::String) && b->rhs->type->is(TK::String)) {
                if (b->op == "==" || b->op == "!=") {
                    std::string c = "faset_str_eq(" + l + ", " + r + ")";
                    return wrap(b->op == "==" ? c : "(!" + c + ")");
                }
                return wrap("(faset_str_cmp(" + l + ", " + r + ") " + b->op + " 0)");
            }
            if (b->op == "-" && lt->isPointer() && b->rhs->type->isPointer()) return wrap("((int64_t)(" + l + " - " + r + "))");
            if ((b->op == "<<" || b->op == ">>") && e->type->isIntegral()) {
                // Como en C#: la cuenta se toma módulo el ancho y '<<' no tiene comportamiento indefinido.
                bool wide = e->type->is(TK::Long) || e->type->is(TK::ULong);
                std::string n = "((" + r + ") & " + (wide ? "63" : "31") + ")";
                if (b->op == "<<") {
                    std::string ut = wide ? "uint64_t" : "uint32_t";
                    return wrap("((" + ctype(e->type) + ")((" + ut + ")(" + l + ") << " + n + "))");
                }
                return wrap("(" + l + " >> " + n + ")");
            }
            if ((b->op == "/" || b->op == "%") && e->type->isIntegral()) {
                // División entera: el cero (y MIN / -1) terminaría el programa con SIGFPE.
                int64_t k = 0;
                bool safeConst = sema_.constEval(b->rhs, k) && k != 0 && k != -1;
                const char* suffix = e->type->is(TK::Int) ? "i32" : e->type->is(TK::Long) ? "i64"
                                     : e->type->is(TK::UInt) ? "u32" : e->type->is(TK::ULong) ? "u64" : nullptr;
                if (!safeConst && suffix)
                    return wrap(std::string(b->op == "/" ? "faset_div_" : "faset_mod_") + suffix + "(" + l + ", " + r + ", " +
                                callerLoc(b->loc) + ")");
            }
            return wrap("(" + l + " " + b->op + " " + r + ")");
        }
        case EK::Assign: return assignExpr(static_cast<AssignExpr*>(e));  // EvalOrder.cpp
        case EK::Cond: {
            auto* c = static_cast<CondExpr*>(e);
            return "(" + expr(c->cond) + " ? " + expr(c->a) + " : " + expr(c->b) + ")";
        }
        case EK::Cast: {
            auto* c = static_cast<CastExpr*>(e);
            if (c->type == c->operand->type) return expr(c->operand);
            if (std::string s; sugarCast(c, s)) return s;  // T? y tuplas (SugarGen.cpp)
            if (c->checkedDown)  // (Perro)animal: panic si el objeto no es un Perro
                return "((" + ctype(c->type) + ")faset_cast((void*)(" + expr(c->operand) + "), " + tiOf(c->type->decl) + ", " +
                       callerLoc(c->loc) + "))";
            if (c->operand->type->isFloating() && (c->type->isIntegral() || c->type->isEnum())) {
                // Real -> entero: saturado (en C, un valor fuera de rango es comportamiento indefinido).
                Type* t = c->type;
                const char* fn = t->is(TK::SByte) ? "i8" : t->is(TK::Byte) ? "u8" : t->is(TK::Short) ? "i16"
                               : t->is(TK::UShort) ? "u16" : t->is(TK::UInt) || t->is(TK::Char) ? "u32"
                               : t->is(TK::Long) ? "i64" : t->is(TK::ULong) ? "u64" : "i32";
                return "((" + ctype(t) + ")faset_f2i_" + fn + "((double)" + expr(c->operand) + "))";
            }
            return "((" + ctype(c->type) + ")" + expr(c->operand) + ")";
        }
        case EK::New: {
            auto* n = static_cast<NewExpr*>(e);
            ClassDecl* c = n->type->decl;
            bool isClass = c->kind == ClassKind::Class;
            std::string fn = c->cname + (isClass ? "__new" : "__make");
            if (!n->ctor) return fn + "d()";
            size_t idx = 0;
            while (c->ctors[idx] != n->ctor) idx++;
            std::vector<EvalOp> ops;  // argumentos de izquierda a derecha (EvalOrder.cpp)
            for (size_t i = 0; i < n->args.size(); i++) {
                EvalOp op{n->args[i], expr(n->args[i]), ctype(n->args[i]->type)};
                op.addr = n->ctor->params[i].isRef();
                ops.push_back(op);
            }
            std::string pre = sequenceArgs(ops, 0);
            std::string s = fn + std::to_string(idx) + "(";
            for (size_t i = 0; i < ops.size(); i++) s += (i ? ", " : "") + (ops[i].addr ? "(&" + ops[i].code + ")" : ops[i].code);
            return seqWrap(pre, s + ")");
        }
        case EK::NewArray: {
            auto* na = static_cast<NewArrayExpr*>(e);
            std::string et = ctype(e->type->elem);
            // Los arrays sin referencias (números, structs de números) no los recorre el recolector.
            if (pointerFree(e->type->elem))
                return "((" + et + "*)faset_gc_alloc_atomic_zeroed((int64_t)sizeof(" + et + ") * (int64_t)(" + expr(na->count) + ")))";
            return "((" + et + "*)faset_alloc_zeroed((int64_t)sizeof(" + et + ") * (int64_t)(" + expr(na->count) + ")))";
        }
        case EK::SizeOf: {
            auto* so = static_cast<SizeOfExpr*>(e);
            std::string t = so->target->isClass() ? so->target->decl->cname : ctype(so->target);
            return "((int32_t)sizeof(" + t + "))";
        }
        case EK::Lambda: return lambdaExpr(static_cast<LambdaExpr*>(e));
        case EK::DelegateConv: return delegateConv(static_cast<DelegateConvExpr*>(e));
        case EK::Is: case EK::As: case EK::TypeOf: case EK::NameOf: case EK::With: return ooExpr(e);
        default: break;  // EK del azúcar: SugarGen.cpp
    }
    return "0";
}
