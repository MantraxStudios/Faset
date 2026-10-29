// Faset - generación de C para el azúcar sintáctico (ver Sugar.cpp): cadenas interpoladas,
// ?. / ??= / T?, tuplas, temporales de expresión (LetExpr), 'params', 'switch' sin coincidencia
// y 'using' (destructor al salir del ámbito, también con return/break/continue).
#include "CodeGen.h"

bool CodeGen::isSugarKind(EK k) const {
    switch (k) {
        case EK::Interp: case EK::CondAccess: case EK::CondRecv: case EK::Tuple: case EK::Let: case EK::SwitchExpr:
        case EK::IsPattern: case EK::ParamsList: case EK::MatchFail: case EK::CoalesceAssign:
            return true;
        default: return false;
    }
}

// ------------------------------------------------------------------ temporales

void CodeGen::pushHoist() {
    auto* f = new HoistFrame();
    f->saved.swap(out_);
    hoist_.push_back(f);
}

void CodeGen::popHoist() {
    HoistFrame* f = hoist_.back();
    hoist_.pop_back();
    std::string body = out_.str();
    out_.swap(f->saved);
    for (const std::string& d : f->decls) out_ << "    " << d << "\n";
    out_ << body;
    delete f;
}

void CodeGen::hoistDecl(const std::string& ct, const std::string& name) {
    if (hoist_.empty()) {  // fuera de una función (no debería ocurrir): variable estática
        if (strFns_.emplace("var:" + name, name).second) helpers_ += "static " + ct + " " + name + ";\n";
        return;
    }
    HoistFrame* f = hoist_.back();
    if (f->names.insert(name).second) f->decls.push_back(ct + " " + name + ";");
}

std::string CodeGen::newTemp(const std::string& ct) {
    std::string name = "fs_t" + std::to_string(++sugarTmp_);
    hoistDecl(ct, name);
    return name;
}

std::string CodeGen::nullValue(Type* t) {
    if (t->isStruct() || t->is(TK::String)) return "((" + ctype(t) + "){0})";
    return "((" + ctype(t) + ")0)";
}

// ------------------------------------------------------------------ texto

// Función auxiliar static faset_string fs_str_N(T v) para tuplas, T? y tipos con ToString().
std::string CodeGen::strFn(Type* t) {
    std::string ct = ctype(t);
    auto it = strFns_.find(ct);
    if (it != strFns_.end()) return it->second;
    std::string name = "fs_str_" + std::to_string(strFns_.size() + 1);
    strFns_[ct] = name;
    std::string body;
    if (Type* el = nullableElem(t)) {
        body = "    return v.f_hasValue ? " + toStrCode(el, "v.f_value") + " : FASET_STR(\"\", 0);\n";
    } else if (isTupleType(t)) {
        std::vector<FieldDecl*>& fs = t->decl->fields;
        body = "    faset_string p[" + std::to_string(2 * fs.size() + 1) + "];\n";
        body += "    p[0] = FASET_STR(\"(\", 1);\n";
        for (size_t i = 0; i < fs.size(); i++) {
            body += "    p[" + std::to_string(2 * i + 1) + "] = " + toStrCode(fs[i]->type, "v." + fs[i]->cname) + ";\n";
            body += "    p[" + std::to_string(2 * i + 2) + "] = " +
                    (i + 1 < fs.size() ? "FASET_STR(\", \", 2)" : "FASET_STR(\")\", 1)") + ";\n";
        }
        body += "    return faset_str_concatv(" + std::to_string(2 * fs.size() + 1) + ", p);\n";
    } else if (MethodDecl* m = findToString(t)) {
        std::string loc = m->trackCaller ? ", fs__f0, 0" : "";
        if (t->isClass()) body = "    return v ? " + m->cname + "(v" + loc + ") : FASET_STR(\"\", 0);\n";
        else body = "    return " + m->cname + "(&v" + loc + ");\n";
    } else {
        body = "    (void)v;\n    return FASET_STR(\"\", 0);\n";
    }
    helpers_ += "static faset_string " + name + "(" + ct + " v) {\n" + body + "}\n\n";
    return name;
}

std::string CodeGen::toStrCode(Type* t, const std::string& v) {
    if (t->is(TK::String)) return v;
    if (t->is(TK::Bool)) return "((" + v + ") ? FASET_STR(\"True\", 4) : FASET_STR(\"False\", 5))";
    if (t->is(TK::Char)) return "faset_char_to_str(" + v + ")";
    if (t->is(TK::Float)) return "faset_f32_to_str(" + v + ")";
    if (t->is(TK::Double)) return "faset_f64_to_str(" + v + ")";
    if (t->isUnsignedInt()) return "faset_u64_to_str((uint64_t)(" + v + "))";
    if (t->isAggregate()) return strFn(t) + "(" + v + ")";
    return "faset_i64_to_str((int64_t)(" + v + "))";
}

// ------------------------------------------------------------------ expresiones

bool CodeGen::sugarCast(CastExpr* c, std::string& out) {
    Type* to = c->type;
    Type* from = c->operand->type;
    if (!to || !from) return false;
    if (Type* el = nullableElem(to)) {
        if (from->is(TK::Null)) {
            out = nullValue(to);
            return true;
        }
        if (from == el) {
            out = "((" + ctype(to) + "){1, " + expr(c->operand) + "})";
            return true;
        }
    }
    if (to->isStruct() && from->isStruct() && to->decl == from->decl) {  // tuplas con otros nombres
        out = expr(c->operand);
        return true;
    }
    return false;
}

std::string CodeGen::sugarExpr(Expr* e) {
    switch (e->kind) {
        case EK::Interp: {
            auto* ie = static_cast<InterpExpr*>(e);
            std::vector<std::string> parts;
            auto fmtCode = [&](Type* t, const std::string& v, const std::string& f) {
                std::string fs = cstring(f);
                if (t->isFloating()) return "faset_fmt_f64((double)(" + v + "), " + (t->is(TK::Float) ? "1" : "0") + ", " + fs + ")";
                std::string bits = std::to_string(t->isEnum() ? 32 : t->bits());
                if (t->isUnsignedInt()) return "faset_fmt_u64((uint64_t)(" + v + "), " + bits + ", " + fs + ")";
                return "faset_fmt_i64((int64_t)(" + v + "), " + bits + ", " + fs + ")";
            };
            for (auto& part : ie->parts) {
                if (!part.expr) {
                    if (!part.text.empty())
                        parts.push_back("FASET_STR(" + cstring(part.text) + ", " + std::to_string(part.text.size()) + ")");
                    continue;
                }
                Type* t = part.expr->type;
                std::string v = expr(part.expr);
                std::string s;
                if (!part.format.empty()) {
                    if (Type* nt = nullableElem(t)) {
                        std::string tmp = newTemp(ctype(t));
                        s = "((" + tmp + " = " + v + ").f_hasValue ? " + fmtCode(nt, tmp + ".f_value", part.format) +
                            " : FASET_STR(\"\", 0))";
                    } else {
                        s = fmtCode(t, v, part.format);
                    }
                } else {
                    s = toStrCode(t, v);
                }
                if (part.hasAlign) s = "faset_str_align(" + s + ", " + std::to_string(part.align) + ")";
                parts.push_back(s);
            }
            if (parts.empty()) return "FASET_STR(\"\", 0)";
            if (parts.size() == 1) return parts[0];
            if (parts.size() == 2) return "faset_str_concat(" + parts[0] + ", " + parts[1] + ")";
            std::string s = "faset_str_concatv(" + std::to_string(parts.size()) + ", (faset_string[]){";
            for (size_t i = 0; i < parts.size(); i++) s += (i ? ", " : "") + parts[i];
            return s + "})";
        }
        case EK::CondAccess: {
            auto* ca = static_cast<CondAccessExpr*>(e);
            std::string tmp = ca->tmp->cname;
            hoistDecl(ctype(ca->tmp->type), tmp);
            std::string test = ca->objNullable ? tmp + ".f_hasValue" : "(" + tmp + " != 0)";
            std::string head = "(" + tmp + " = " + expr(ca->obj) + ", " + test + " ? ";
            std::string acc = expr(ca->access);
            Type* A = ca->access->type;
            if (A->isVoid()) return head + "(void)(" + acc + ") : (void)0)";
            if (e->type == A) return head + acc + " : " + nullValue(A) + ")";
            return head + "((" + ctype(e->type) + "){1, " + acc + "}) : " + nullValue(e->type) + ")";  // T?
        }
        case EK::CondRecv: {
            auto* r = static_cast<CondRecvExpr*>(e);
            return r->owner->objNullable ? r->owner->tmp->cname + ".f_value" : r->owner->tmp->cname;
        }
        case EK::Tuple: {
            auto* t = static_cast<TupleExpr*>(e);
            std::string s = "((" + ctype(e->type) + "){";
            for (size_t i = 0; i < t->elems.size(); i++) s += (i ? ", " : "") + expr(t->elems[i]);
            return s + "})";
        }
        case EK::Let: {
            auto* l = static_cast<LetExpr*>(e);
            std::string s = "(";
            bool first = true;
            for (auto& [v, init] : l->binds) {
                hoistDecl(ctype(v->type), v->cname);
                s += (first ? "" : ", ") + v->cname + " = " + expr(init);
                first = false;
            }
            for (Expr* x : l->seq) {
                s += (first ? "" : ", ") + expr(x);
                first = false;
            }
            return s + ")";
        }
        case EK::ParamsList: {
            auto* pl = static_cast<ParamsListExpr*>(e);
            ClassDecl* c = e->type->decl;
            std::string tmp = newTemp(ctype(e->type));
            std::string s = "(" + tmp + " = " + c->cname + "__new" + std::to_string(pl->ctorIndex) + "(" +
                            std::to_string(pl->items.size()) + ")";
            for (Expr* item : pl->items) s += ", " + call(pl->add, tmp, {item}, item->loc);
            return s + ", " + tmp + ")";
        }
        case EK::MatchFail: {
            auto* mf = static_cast<MatchFailExpr*>(e);
            std::string shown = mf->value ? toStrCode(mf->value->type, expr(mf->value)) : "FASET_STR(\"\", 0)";
            return "(faset_match_fail(" + shown + ", " + (mf->value ? "1" : "0") + ", " + callerLoc(e->loc) + "), " +
                   nullValue(e->type) + ")";
        }
        case EK::CoalesceAssign: {
            auto* ca = static_cast<CoalesceAssignExpr*>(e);
            std::string tp = newTemp(ctype(ca->lhs->type) + "*");
            std::string head = "(" + tp + " = &(" + expr(ca->lhs) + "), ";
            if (ca->nullableLhs)
                return head + tp + "->f_hasValue ? " + tp + "->f_value : (*" + tp + " = " + expr(ca->rhs) + ").f_value)";
            return head + "*" + tp + " ? *" + tp + " : (*" + tp + " = " + expr(ca->rhs) + "))";
        }
        default: return "0";
    }
}

// ------------------------------------------------------------------ sentencias y 'using'

std::string CodeGen::usingCleanup(int stopKind) {
    std::string s;
    for (size_t i = usings_.size(); i-- > 0;) {
        UsingScope& sc = usings_[i];
        for (size_t j = sc.objs.size(); j-- > 0;) s += sc.objs[j];
        if (stopKind == 1 && sc.kind == 1) break;                  // continue: hasta el bucle
        if (stopKind == 2 && (sc.kind == 1 || sc.kind == 2)) break;  // break: hasta el bucle o switch
        if (stopKind == 0) break;                                  // solo el ámbito actual
    }
    return s;
}

bool CodeGen::emitSugarStmt(Stmt* s) {
    if (rawNext_) {
        rawNext_ = false;
        return false;
    }
    if (s->lowered) {
        emitStmt(s->lowered);
        return true;
    }
    switch (s->kind) {
        case SK::Block: {
            auto* b = static_cast<BlockStmt*>(s);
            if (b->noScope) {  // declaraciones generadas que deben quedar visibles después
                for (Stmt* c : b->stmts) emitStmt(c);
                return true;
            }
            line("{");
            indent_++;
            usings_.push_back({});
            for (Stmt* c : b->stmts) emitStmt(c);
            std::string clean = usingCleanup(0);
            if (!clean.empty()) line(clean);
            usings_.pop_back();
            indent_--;
            line("}");
            return true;
        }
        case SK::While: case SK::DoWhile: case SK::For: case SK::Switch: {
            usings_.push_back({{}, s->kind == SK::Switch ? 2 : 1});
            rawNext_ = true;
            emitStmt(s);
            usings_.pop_back();
            return true;
        }
        case SK::Using: {
            auto* u = static_cast<UsingStmt*>(s);
            if (u->body) {
                line("{");
                indent_++;
                usings_.push_back({});
            }
            if (u->decl) emitStmt(u->decl);
            if (usings_.empty()) usings_.push_back({});
            for (VarInfo* v : u->vars)
                usings_.back().objs.push_back("if (" + v->cname + ") faset_obj_delete((void*)" + v->cname + ", " +
                                              callerLoc(u->loc) + "); ");
            if (u->body) {
                emitBody(u->body);
                std::string clean = usingCleanup(0);
                if (!clean.empty()) line(clean);
                usings_.pop_back();
                indent_--;
                line("}");
            }
            return true;
        }
        case SK::Return: {
            std::string clean = usingCleanup(-1);
            if (clean.empty()) return false;
            auto* rs = static_cast<ReturnStmt*>(s);
            if (!rs->value) {
                line("{ " + clean + "return; }");
                return true;
            }
            bool ref = curMethod_ && curMethod_->retIsRef();
            std::string ct = ctype(curMethod_->ret) + (ref ? "*" : "");
            line("{ " + ct + " fs_ret = " + (ref ? "&" : "") + expr(rs->value) + "; " + clean + "return fs_ret; }");
            return true;
        }
        case SK::Break: case SK::Continue: {
            std::string clean = usingCleanup(s->kind == SK::Break ? 2 : 1);
            if (clean.empty()) return false;
            line("{ " + clean + (s->kind == SK::Break ? "break; }" : "continue; }"));
            return true;
        }
        default: return false;
    }
}
