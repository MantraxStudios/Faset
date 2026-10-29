#include "CodeGen.h"

#include <cstdio>

#include "Runtime.h"

namespace {

bool hasExportAttr(MethodDecl* m) {
    for (Attribute& a : m->attrs)
        if (a.name == "Export") return true;
    return false;
}

// Versión local de "es un lvalue" para decidir si podemos tomar '&' del receptor.
bool isLValue(Expr* e) {
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
    if (!m->isStatic()) ps.push_back(m->owner->cname + "* self");
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

void CodeGen::line(const std::string& s) { out_ << std::string(indent_ * 4, ' ') << s << "\n"; }

std::string CodeGen::loc(SourceLoc l) { return "fs__f" + std::to_string(l.file) + ", " + std::to_string(l.line); }

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
    out_ << kRuntimeHeader << kRuntimeExcHeader << "\n";
    // Nombres de archivo para los mensajes de 'panic' (Faset panic: ... at archivo.fst:línea).
    for (size_t i = 0; i < diag.files.size(); i++)
        out_ << "static const char fs__f" << i << "[] = " << cstring(diag.files[i]) << ";\n";
    out_ << "\n";

    for (ClassDecl* c : sema_.structOrder) out_ << "typedef struct " << c->cname << " " << c->cname << ";\n";
    out_ << "\n";
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
        for (FieldDecl* f : c->fields) {
            if (f->isStatic()) continue;
            out_ << "    " << ctype(f->type) << " " << f->cname << ";\n";
            n++;
        }
        if (n == 0) out_ << "    char faset_vacio;\n";
        out_ << "};\n\n";
    }
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

    // Campos estáticos y variables globales.
    for (ClassDecl* c : prog_.types) {
        if (c->isTemplate()) continue;
        for (FieldDecl* f : c->fields)
            if (f->isStatic()) out_ << ctype(f->type) << " " << f->cname << " = " << zeroInit(f->type) << ";\n";
    }
    out_ << "\n";

    // Cuerpos.
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

    emitExcHelpers();

    // Inicialización estática, en orden.
    out_ << "static void fs__static_init(void) {\n";
    indent_ = 1;
    if (sema_.exceptionClass) line("fs__exc_setup();");
    for (FieldDecl* f : sema_.staticInits) {
        curClass_ = f->owner;
        line(f->cname + " = " + expr(f->init) + ";");
    }
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
        if (m->ret->isVoid()) {
            out_ << "    " << call << ";\n";
            out_ << "    faset_rt_exit();\n    return 0;\n";
        } else {
            out_ << "    int32_t r = " << call << ";\n";
            out_ << "    faset_rt_exit();\n    return (int)r;\n";
        }
        out_ << "}\n";
    }
    return out_.str();
}

void CodeGen::emitConstructionHelpers(ClassDecl* c) {
    out_ << "static void " << c->cname << "__init(" << c->cname << "* self) {\n";
    indent_ = 1;
    line("(void)self;");
    emitExcInit(c);  // excepciones: tipo dinámico y nombre del tipo
    for (FieldDecl* f : c->fields)
        if (!f->isStatic() && f->init) line("self->" + f->cname + " = " + expr(f->init) + ";");
    indent_ = 0;
    out_ << "}\n\n";

    bool isClass = c->kind == ClassKind::Class;
    auto emitOne = [&](MethodDecl* ctor, const std::string& name) {
        std::string params = ctorParams(ctor, true);
        std::string args = ctorParams(ctor, false);
        if (isClass) {
            out_ << c->cname << "* " << name << "(" << params << ") {\n";
            // El destructor queda en la cabecera: lo ejecutan 'delete' o el recolector.
            std::string dtor = c->dtor && shouldEmit(c->dtor) ? "(void (*)(void*))" + c->dtor->cname : "0";
            out_ << "    " << c->cname << "* self = (" << c->cname << "*)faset_obj_alloc((int64_t)sizeof(" << c->cname
                 << "), " << dtor << ");\n";
            out_ << "    " << c->cname << "__init(self);\n";
            if (ctor) out_ << "    " << ctor->cname << "(self" << (args.empty() ? "" : ", " + args) << ");\n";
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
    curMethod_ = m;
    out_ << signature(m) << " {\n";
    indent_ = 1;
    if (!m->isStatic()) line("(void)self;");
    for (Stmt* s : m->body->stmts) emitStmt(s);
    indent_ = 0;
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
                if (dc.var->isRef) line(ctype(t) + "* " + dc.var->cname + " = &" + expr(dc.init) + ";");
                else line(ctype(t) + vq + dc.var->cname + " = " + (dc.init ? expr(dc.init) : zeroInit(t)) + ";");
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
            line("while (" + expr(ds->cond) + ");");
            break;
        }
        case SK::For: {
            auto* fs = static_cast<ForStmt*>(s);
            line("{");
            indent_++;
            if (fs->initDecl) emitStmt(fs->initDecl);
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

std::string CodeGen::call(MethodDecl* m, const std::string& self, const std::vector<Expr*>& args, SourceLoc at) {
    std::vector<std::string> parts;
    if (!m->isStatic()) parts.push_back(self);
    for (size_t i = 0; i < args.size(); i++) {
        bool byRef = i < m->params.size() && m->params[i].isRef();
        parts.push_back(byRef ? "(&" + expr(args[i]) + ")" : expr(args[i]));
        if (m->trackCaller && i + 1 == m->params.size()) parts.push_back(callerLoc(at));
    }
    if (m->trackCaller && m->params.empty()) parts.push_back(callerLoc(at));
    std::string s = m->cname + "(";
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
    if (t->isUnsignedInt()) return "faset_u64_to_str((uint64_t)(" + v + "))";
    return "faset_i64_to_str((int64_t)(" + v + "))";
}

std::string CodeGen::expr(Expr* e) {
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
                case NameExpr::Ref::Local: return n->var->isRef ? "(*" + n->var->cname + ")" : n->var->cname;
                case NameExpr::Ref::Field: return "self->" + n->field->cname;
                case NameExpr::Ref::StaticField: return n->field->cname;
                case NameExpr::Ref::Property: return call(n->getter, "self", {}, n->loc);
                default: return "/*?*/0";
            }
        }
        case EK::Member: {
            auto* m = static_cast<MemberExpr*>(e);
            switch (m->ref) {
                case MemberExpr::Ref::Field: return memberAccess(m->obj, m->arrow, m->field->cname);
                case MemberExpr::Ref::StaticField: return m->field->cname;
                case MemberExpr::Ref::EnumConst: return "((int32_t)" + std::to_string((int64_t)m->constBits) + "LL)";
                case MemberExpr::Ref::ConstInt: return "((" + ctype(m->type) + ")" + std::to_string(m->constBits) + "ULL)";
                case MemberExpr::Ref::StrLength: return "((int32_t)" + memberAccess(m->obj, m->arrow, "len") + ")";
                case MemberExpr::Ref::StrPtr: return "((uint8_t*)" + memberAccess(m->obj, m->arrow, "ptr") + ")";
                case MemberExpr::Ref::Property:
                    return call(m->getter, m->getter->isStatic() ? "" : receiverPtr(m->obj, m->arrow), {}, m->loc);
                default: return "/*?*/0";
            }
        }
        case EK::Call: {
            auto* c = static_cast<CallExpr*>(e);
            if (!c->target) {  // puntero a función
                std::string fn = expr(c->callee);
                fn = "((" + ctype(c->callee->type) + ")faset_chk_fn((void*)" + fn + ", " + callerLoc(c->loc) + "))";
                std::string s = "(" + fn + ")(";
                for (size_t i = 0; i < c->args.size(); i++) s += (i ? ", " : "") + expr(c->args[i]);
                return s + ")";
            }
            std::string self;
            if (!c->target->isStatic()) self = c->implicitThis ? "self" : receiverPtr(c->receiver, c->receiverArrow);
            return call(c->target, self, c->args, c->loc);
        }
        case EK::Index: {
            auto* ix = static_cast<IndexExpr*>(e);
            if (ix->opMethod) return call(ix->opMethod, receiverPtr(ix->obj, false), {ix->index}, ix->loc);
            if (ix->obj->type->is(TK::String)) {
                return "faset_str_at(" + expr(ix->obj) + ", " + expr(ix->index) + ", " + callerLoc(ix->loc) + ")";
            }
            return "(" + expr(ix->obj) + ")[" + expr(ix->index) + "]";
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
            if (b->op == "+" && e->type->is(TK::String))
                return "faset_str_concat(" + toStr(b->lhs) + ", " + toStr(b->rhs) + ")";
            std::string l = expr(b->lhs), r = expr(b->rhs);
            Type* lt = b->lhs->type;
            if (lt->is(TK::String) && b->rhs->type->is(TK::String)) {
                if (b->op == "==" || b->op == "!=") {
                    std::string c = "faset_str_eq(" + l + ", " + r + ")";
                    return b->op == "==" ? c : "(!" + c + ")";
                }
                return "(faset_str_cmp(" + l + ", " + r + ") " + b->op + " 0)";
            }
            if (b->op == "-" && lt->isPointer() && b->rhs->type->isPointer()) return "((int64_t)(" + l + " - " + r + "))";
            if ((b->op == "<<" || b->op == ">>") && e->type->isIntegral()) {
                // Como en C#: la cuenta se toma módulo el ancho y '<<' no tiene comportamiento indefinido.
                bool wide = e->type->is(TK::Long) || e->type->is(TK::ULong);
                std::string n = "((" + r + ") & " + (wide ? "63" : "31") + ")";
                if (b->op == "<<") {
                    std::string ut = wide ? "uint64_t" : "uint32_t";
                    return "((" + ctype(e->type) + ")((" + ut + ")(" + l + ") << " + n + "))";
                }
                return "(" + l + " >> " + n + ")";
            }
            if ((b->op == "/" || b->op == "%") && e->type->isIntegral()) {
                // División entera: el cero (y MIN / -1) terminaría el programa con SIGFPE.
                int64_t k = 0;
                bool safeConst = sema_.constEval(b->rhs, k) && k != 0 && k != -1;
                const char* suffix = e->type->is(TK::Int) ? "i32" : e->type->is(TK::Long) ? "i64"
                                     : e->type->is(TK::UInt) ? "u32" : e->type->is(TK::ULong) ? "u64" : nullptr;
                if (!safeConst && suffix)
                    return std::string(b->op == "/" ? "faset_div_" : "faset_mod_") + suffix + "(" + l + ", " + r + ", " +
                           callerLoc(b->loc) + ")";
            }
            return "(" + l + " " + b->op + " " + r + ")";
        }
        case EK::Assign: {
            auto* a = static_cast<AssignExpr*>(e);
            if (a->setter) {
                std::string self;
                if (!a->setter->isStatic()) {
                    if (a->lhs->kind == EK::Member) {
                        auto* m = static_cast<MemberExpr*>(a->lhs);
                        self = receiverPtr(m->obj, m->arrow);
                    } else {
                        self = "self";
                    }
                }
                return call(a->setter, self, {a->rhs}, a->loc);
            }
            if (a->opMethod) return "(" + expr(a->lhs) + " = " + call(a->opMethod, "", {a->lhs, a->rhs}, a->loc) + ")";
            if (a->op == "+=" && a->lhs->type->is(TK::String)) {
                std::string lhs = expr(a->lhs);
                return "(" + lhs + " = faset_str_concat(" + lhs + ", " + toStr(a->rhs) + "))";
            }
            if ((a->op == "<<=" || a->op == ">>=") && a->lhs->type->isIntegral()) {
                bool wide = a->lhs->type->is(TK::Long) || a->lhs->type->is(TK::ULong);
                std::string mask = wide ? "63" : "31";
                if (a->op == ">>=") return "(" + expr(a->lhs) + " >>= ((" + expr(a->rhs) + ") & " + mask + "))";
                std::string ut = wide ? "uint64_t" : "uint32_t";
                std::string lhs = expr(a->lhs);
                return "(" + lhs + " = (" + ctype(a->lhs->type) + ")((" + ut + ")(" + lhs + ") << ((" + expr(a->rhs) + ") & " +
                       mask + ")))";
            }
            if ((a->op == "/=" || a->op == "%=") && a->lhs->type->isIntegral()) {
                int64_t k = 0;
                if (!(sema_.constEval(a->rhs, k) && k != 0)) {
                    bool u64 = a->lhs->type->is(TK::ULong);
                    return "(" + expr(a->lhs) + " " + a->op + " " + (u64 ? "faset_divisor_u64(" : "faset_divisor_i64(") +
                           expr(a->rhs) + ", " + callerLoc(a->loc) + "))";
                }
            }
            return "(" + expr(a->lhs) + " " + a->op + " " + expr(a->rhs) + ")";
        }
        case EK::Cond: {
            auto* c = static_cast<CondExpr*>(e);
            return "(" + expr(c->cond) + " ? " + expr(c->a) + " : " + expr(c->b) + ")";
        }
        case EK::Cast: {
            auto* c = static_cast<CastExpr*>(e);
            if (c->type == c->operand->type) return expr(c->operand);
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
            std::string s = fn + std::to_string(idx) + "(";
            for (size_t i = 0; i < n->args.size(); i++) {
                bool byRef = n->ctor->params[i].isRef();
                s += (i ? ", " : "") + (byRef ? "(&" + expr(n->args[i]) + ")" : expr(n->args[i]));
            }
            return s + ")";
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
    }
    return "0";
}
