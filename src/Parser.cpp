#include "Parser.h"

#include <filesystem>

// ------------------------------------------------------------------ utilidades

bool Parser::acceptP(const char* s) {
    if (!isP(s)) return false;
    p_++;
    return true;
}

bool Parser::acceptK(const char* s) {
    if (!isK(s)) return false;
    p_++;
    return true;
}

void Parser::fail(const std::string& msg) { fail(cur().loc, msg); }

void Parser::fail(const SourceLoc& loc, const std::string& msg) {
    diag.error(loc, msg);
    throw ParseError{};
}

// 'unsafe' (de C#) no existe: el contexto inseguro se escribe 'memory_unsafe' para que se vea
// claramente dónde vive el código que manipula memoria a mano.
void Parser::unsafeKeywordError() {
    if (!isK("unsafe")) return;
    diag.error(cur().loc, "'unsafe' no existe en Faset; usa 'memory_unsafe' (sustituye 'unsafe' por 'memory_unsafe')");
}

void Parser::expectP(const char* s) {
    if (sawMarker_ && !isP(s) && (std::string(s) == ";" || std::string(s) == ")")) return;
    if (!acceptP(s)) fail(std::string("se esperaba '") + s + "' pero se encontró '" + cur().text + "'");
}

std::string Parser::expectIdent() {
    if (cur().kind == TokKind::Ident && cur().text == kCompletionMarker) sawMarker_ = true;
    if (cur().kind != TokKind::Ident) fail("se esperaba un identificador pero se encontró '" + cur().text + "'");
    return (*toks_)[p_++].text;
}

// Avanza hasta el siguiente 'stop' (consumiéndolo) o hasta una '}' de cierre (sin consumirla).
void Parser::skipTo(const char* stop) {
    halfGt_ = false;
    int depth = 0;
    while (!atEnd()) {
        if (depth == 0 && isP(stop)) {
            p_++;
            return;
        }
        if (isP("{")) depth++;
        if (isP("}")) {
            if (depth == 0) return;
            depth--;
            if (depth == 0 && std::string(stop) == "}") {
                p_++;
                return;
            }
        }
        p_++;
    }
}

// ------------------------------------------------------------------ archivo y namespaces

void Parser::parseFile() {
    scanQualifiedNames();
    parseNamespaceBody("", false);
}

// Detecta rutas como std::io::File o std.text.StringBuilder para cargar sus módulos.
void Parser::scanQualifiedNames() {
    if (!libRoots_) return;
    const auto& t = *toks_;
    for (size_t i = 0; i + 2 < t.size(); i++) {
        if (t[i].kind != TokKind::Ident || !libRoots_->count(t[i].text)) continue;
        if (i > 0 && t[i - 1].kind == TokKind::Punct && (t[i - 1].text == "." || t[i - 1].text == "::")) continue;
        std::vector<std::string> path = {t[i].text};
        size_t j = i + 1;
        while (j + 1 < t.size() && t[j].kind == TokKind::Punct && (t[j].text == "." || t[j].text == "::") &&
               t[j + 1].kind == TokKind::Ident) {
            path.push_back(t[j + 1].text);
            j += 2;
        }
        requestModule(path);
    }
}

void Parser::requestModule(const std::vector<std::string>& path) {
    std::string s;
    for (const std::string& part : path) {
        s += (s.empty() ? "" : ".") + part;
        prog_.requestedModules.insert(s);
    }
}

std::vector<std::string> Parser::parseDottedPath() {
    std::vector<std::string> path = {expectIdent()};
    while (isDot() && peekTok().kind == TokKind::Ident) {
        p_++;
        path.push_back(expectIdent());
    }
    return path;
}

// using X.Y;   using namespace X::Y;   using Alias = X.Y.Tipo<int>;   import X.Y;   import "archivo.fst";
void Parser::parseUsing(bool isImport) {
    UsingDirective u;
    u.loc = cur().loc;
    p_++;
    if (isImport && cur().kind == TokKind::String) {
        std::filesystem::path path(cur().text);
        if (path.is_relative() && !fileDir_.empty()) path = std::filesystem::path(fileDir_) / path;
        prog_.requestedFiles.push_back(path.lexically_normal().string());
        p_++;
        expectP(";");
        return;
    }
    acceptK("namespace");
    if (isK("static")) fail("'using static' aún no está soportado");
    if (cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct && peekTok().text == "=") {
        u.alias = expectIdent();
        p_++;
        u.aliasType = parseType();
        u.path = u.aliasType->parts;
    } else {
        u.path = parseDottedPath();
    }
    expectP(";");
    requestModule(u.path);
    file_->usings.push_back(u);
}

ClassDecl* Parser::hiddenFor(const std::string& ns) {
    auto it = hidden_.find(ns);
    if (it != hidden_.end()) return it->second;
    auto* c = new ClassDecl();
    c->kind = ClassKind::Class;
    c->mods.isStatic = true;
    c->isNamespaceScope = true;
    c->name = c->displayName = "<global>";
    c->ns = ns;
    c->file = file_;
    hidden_[ns] = c;
    prog_.types.push_back(c);
    return c;
}

void Parser::parseNamespaceBody(const std::string& ns, bool braced) {
    while (!atEnd() && !(braced && isP("}"))) {
        try {
            if (isK("using") || isK("import")) {
                // Un 'using' ocupa una línea: si está mal escrito, se salta solo esa línea.
                int line = cur().loc.line;
                try {
                    parseUsing(isK("import"));
                } catch (ParseError&) {
                    while (!atEnd() && cur().loc.line == line) p_++;
                    acceptP(";");
                }
                continue;
            }
            // 'memory_unsafe;' : todo el archivo es un contexto memory_unsafe.
            if (isUnsafeKw() && peekTok().kind == TokKind::Punct && peekTok().text == ";") {
                unsafeKeywordError();
                file_->unsafeCtx = true;
                p_ += 2;
                continue;
            }
            // 'memory_unsafe namespace X { ... }' : todo lo declarado dentro es confiable.
            bool unsafeNs = false;
            if (isUnsafeKw() && peekTok().kind == TokKind::Keyword && peekTok().text == "namespace") {
                unsafeKeywordError();
                p_++;
                unsafeNs = true;
            }
            if (acceptK("namespace")) {
                std::vector<std::string> path = parseDottedPath();
                std::string name;
                for (const std::string& s : path) name += (name.empty() ? "" : ".") + s;
                std::string full = ns.empty() ? name : ns + "." + name;
                bool savedUnsafe = nsUnsafe_;
                nsUnsafe_ = nsUnsafe_ || unsafeNs;
                if (acceptP(";")) {  // namespace con alcance de archivo
                    parseNamespaceBody(full, false);
                    nsUnsafe_ = savedUnsafe;
                    return;
                }
                expectP("{");
                parseNamespaceBody(full, true);
                nsUnsafe_ = savedUnsafe;
                expectP("}");
                continue;
            }
            if (acceptP(";")) continue;
            size_t begin = p_;
            std::vector<Attribute> attrs = parseAttributes();
            Modifiers mods = parseModifiers();
            if (isK("class") || isK("struct") || isK("enum") || isK("interface")) {
                parseTypeDecl(ns, attrs, mods, begin);
            } else if (isK("delegate") && !(peekTok().kind == TokKind::Punct && peekTok().text == "*")) {
                parseDelegateDecl(hiddenFor(ns), attrs, mods);
            } else {
                hasSection_ = false;
                parseMember(hiddenFor(ns), attrs, mods, begin);
            }
        } catch (ParseError&) {
            skipTo("}");
            if (isP("}") && !braced) p_++;
        }
    }
}

std::vector<Attribute> Parser::parseAttributes() {
    std::vector<Attribute> attrs;
    while (isP("[")) {
        p_++;
        do {
            Attribute a;
            a.loc = cur().loc;
            a.name = expectIdent();
            if (acceptP("(")) {
                if (!isP(")")) {
                    do {
                        if (cur().kind != TokKind::String) fail("los argumentos de atributo deben ser cadenas");
                        a.args.push_back(cur().text);
                        p_++;
                    } while (acceptP(","));
                }
                expectP(")");
            }
            attrs.push_back(a);
        } while (acceptP(","));
        expectP("]");
    }
    return attrs;
}

Modifiers Parser::parseModifiers() {
    Modifiers m;
    for (;;) {
        // 'public:' (sección al estilo C++) se trata en parseMember
        if ((isK("public") || isK("private") || isK("internal") || isK("protected")) &&
            peekTok().kind == TokKind::Punct && peekTok().text == ":")
            break;
        if (acceptK("public")) m.access = Access::Public, m.hasAccess = true;
        else if (acceptK("private")) m.access = Access::Private, m.hasAccess = true;
        else if (acceptK("internal")) m.access = Access::Internal, m.hasAccess = true;
        else if (acceptK("protected")) m.access = Access::Protected, m.hasAccess = true;
        else if (acceptK("static")) m.isStatic = true;
        else if (acceptK("extern")) m.isExtern = true;
        else if (acceptK("const")) m.isConst = true;
        else if (acceptK("readonly")) m.isReadonly = true;
        else if (isUnsafeKw()) {
            unsafeKeywordError();
            p_++;
            m.isMemoryUnsafe = true;
        }
        else if (cur().kind == TokKind::Ident && cur().text == "partial" && (peekTok().text == "class" || peekTok().text == "struct"))
            p_++, m.isPartial = true;
        else if (cur().kind == TokKind::Ident && (cur().text == "inline" || cur().text == "constexpr")) p_++;
        else if (cur().kind == TokKind::Ident && cur().text == "event" &&
                 (peekTok().kind == TokKind::Ident || peekTok().kind == TokKind::Keyword))
            p_++, m.isEvent = true;
        else if (isK("virtual") || isK("override") || isK("abstract") || isK("sealed"))
            fail("'" + cur().text + "' aún no está soportado (la herencia llegará en una versión futura)");
        else break;
    }
    return m;
}

std::vector<std::string> Parser::parseTypeParams() {
    std::vector<std::string> ps;
    expectP("<");
    do {
        if (cur().kind == TokKind::Ident && (cur().text == "typename")) p_++;
        else if (isK("class")) p_++;
        ps.push_back(expectIdent());
    } while (acceptP(","));
    if (!closeAngle() || halfGt_) fail("se esperaba '>' al final de los parámetros de tipo");
    return ps;
}

// 'where T : algo' se acepta y se ignora: las plantillas se comprueban al instanciarse.
void Parser::skipWhereClauses() {
    auto atWhere = [&]() { return cur().kind == TokKind::Ident && cur().text == "where"; };
    while (atWhere()) {
        p_++;
        while (!atEnd() && !isP("{") && !isP(";") && !isP("=>") && !atWhere()) p_++;
    }
}

ClassDecl* Parser::parseTypeDecl(const std::string& ns, std::vector<Attribute> attrs, Modifiers mods, size_t begin) {
    auto* c = new ClassDecl();
    c->attrs = std::move(attrs);
    c->mods = mods;
    c->loc = cur().loc;
    c->ns = ns;
    c->file = file_;
    if (acceptK("class")) c->kind = ClassKind::Class;
    else if (acceptK("struct")) c->kind = ClassKind::Struct;
    else if (acceptK("enum")) c->kind = ClassKind::Enum;
    else if (isK("interface")) fail("las interfaces aún no están soportadas");
    else fail("se esperaba 'class', 'struct' o 'enum' pero se encontró '" + cur().text + "'");
    c->name = c->displayName = expectIdent();
    c->unsafeCtx = mods.isMemoryUnsafe || nsUnsafe_;
    if (isP("<")) {
        if (c->kind == ClassKind::Enum) fail("los enums no pueden ser genéricos");
        c->typeParams = parseTypeParams();
        c->tokens = toks_;
        c->tokBegin = begin;
    }
    if (acceptP(":")) {
        if (c->kind == ClassKind::Enum && acceptK("int")) {
            // el tipo subyacente de los enums siempre es int
        } else {
            fail("la herencia aún no está soportada");
        }
    }
    skipWhereClauses();
    if (!reparse_) prog_.types.push_back(c);
    expectP("{");
    if (c->kind == ClassKind::Enum) {
        parseEnumBody(c);
    } else {
        bool savedHas = hasSection_;
        Access savedSec = section_;
        hasSection_ = false;
        while (!atEnd() && !isP("}")) {
            try {
                size_t mb = p_;
                std::vector<Attribute> ma = parseAttributes();
                Modifiers mm = parseModifiers();
                parseMember(c, ma, mm, mb);
            } catch (ParseError&) {
                skipTo(";");
            }
        }
        hasSection_ = savedHas;
        section_ = savedSec;
    }
    expectP("}");
    acceptP(";");
    return c;
}

void Parser::parseEnumBody(ClassDecl* c) {
    while (!isP("}") && !atEnd()) {
        EnumMember m;
        m.loc = cur().loc;
        m.name = expectIdent();
        if (acceptP("=")) m.value = parseExpr();
        c->enumMembers.push_back(m);
        if (!acceptP(",")) break;
    }
}

void Parser::parseParams(MethodDecl* m) {
    expectP("(");
    if (!isP(")")) {
        do {
            if (acceptP("...")) {
                m->variadic = true;
                break;
            }
            Param prm;
            prm.loc = cur().loc;
            if (acceptK("this")) prm.isThis = true;
            bool byRef = false;
            if (acceptK("ref") || acceptK("out")) byRef = true;
            acceptK("const");
            if (acceptK("params")) {  // params List<T> xs  /  params T[] xs (= List<T>)
                prm.isParams = true;
                allowArraySuffix_ = true;
            }
            prm.tref = parseType();
            allowArraySuffix_ = false;
            if (byRef) prm.tref->isRef = true;
            prm.name = expectIdent();
            if (isP("=")) fail("los parámetros con valor por defecto aún no están soportados");
            m->params.push_back(prm);
        } while (acceptP(","));
    }
    expectP(")");
}

void Parser::parseMember(ClassDecl* c, std::vector<Attribute> attrs, Modifiers mods, size_t begin) {
    // Sección de acceso al estilo C++: 'public:'
    if (!mods.hasAccess && (isK("public") || isK("private") || isK("internal") || isK("protected")) &&
        peekTok().kind == TokKind::Punct && peekTok().text == ":") {
        if (c->isNamespaceScope) fail("las secciones de acceso solo son válidas dentro de clases y structs");
        section_ = cur().text == "public" ? Access::Public : cur().text == "private" ? Access::Private
                   : cur().text == "protected" ? Access::Protected : Access::Internal;
        hasSection_ = true;
        p_ += 2;
        return;
    }
    if (!mods.hasAccess) {
        if (c->isNamespaceScope) mods.access = Access::Public;
        else if (hasSection_) mods.access = section_;
        else mods.access = c->kind == ClassKind::Struct ? Access::Public : Access::Private;
    }
    if (c->isNamespaceScope) mods.isStatic = true;
    SourceLoc loc = cur().loc;
    // Contexto memory_unsafe de los miembros: el suyo propio, el de su clase o el del namespace.
    bool ctxUnsafe = mods.isMemoryUnsafe || (c->isNamespaceScope ? nsUnsafe_ : c->unsafeCtx);
    auto stamp = [&](MethodDecl* m) {
        m->unsafeBody = ctxUnsafe;
        m->unsafeApi = mods.isMemoryUnsafe;
        for (Attribute& a : attrs)
            if (a.name == "TrackCaller") m->trackCaller = true;
        return m;
    };

    if (isK("class") || isK("struct") || isK("enum")) fail("los tipos anidados aún no están soportados");
    if (isK("delegate") && !(peekTok().kind == TokKind::Punct && peekTok().text == "*")) {
        parseDelegateDecl(c, attrs, mods);
        return;
    }

    auto finishMethod = [&](MethodDecl* m) {
        skipWhereClauses();
        if (acceptP(";")) {
            m->body = nullptr;
        } else if (isP("=>")) {
            SourceLoc al = cur().loc;
            p_++;
            if (isK("throw")) {  // T F() => throw new X(...);  (ver Exceptions.cpp)
                m->body = new BlockStmt(al);
                m->body->stmts.push_back(parseThrow());
                return;
            }
            Expr* e = parseExpr();
            expectP(";");
            auto* b = new BlockStmt(al);
            bool isVoid = m->retRef && m->retRef->parts.size() == 1 && m->retRef->parts[0] == "void" &&
                          m->retRef->ptrDepth == 0;
            if (isVoid || m->kind == MethodKind::Ctor || m->kind == MethodKind::Dtor) {
                auto* s = new ExprStmt(al);
                s->expr = e;
                b->stmts.push_back(s);
            } else {
                auto* r = new ReturnStmt(al);
                r->value = e;
                b->stmts.push_back(r);
            }
            m->body = b;
        } else {
            m->body = parseBlock();
        }
    };

    // Destructor: ~Nombre()
    if (acceptP("~")) {
        auto* m = new MethodDecl();
        m->loc = loc;
        m->mods = mods;
        m->attrs = attrs;
        m->kind = MethodKind::Dtor;
        stamp(m);
        std::string name = expectIdent();
        if (name != c->name) fail(loc, "el destructor debe llamarse '~" + c->name + "'");
        m->name = "~" + name;
        parseParams(m);
        if (!m->params.empty()) fail(loc, "los destructores no pueden tener parámetros");
        finishMethod(m);
        if (c->dtor) diag.error(loc, "'" + c->name + "' ya tiene un destructor");
        c->dtor = m;
        return;
    }

    // Constructor: Nombre(...)
    if (!c->isNamespaceScope && cur().kind == TokKind::Ident && cur().text == c->name &&
        peekTok().kind == TokKind::Punct && peekTok().text == "(") {
        p_++;
        auto* m = new MethodDecl();
        m->loc = loc;
        m->mods = mods;
        m->attrs = attrs;
        m->kind = MethodKind::Ctor;
        stamp(m);
        m->name = c->name;
        parseParams(m);
        if (isP(":")) fail("los inicializadores de constructor (: this(...)) aún no están soportados");
        finishMethod(m);
        c->ctors.push_back(m);
        return;
    }

    TypeRef* type = parseType();

    // Sobrecarga de operadores: static T operator+(T a, T b)  /  T& operator[](int i)
    if (acceptK("operator")) {
        auto* m = new MethodDecl();
        m->loc = cur().loc;
        m->mods = mods;
        m->attrs = attrs;
        m->kind = MethodKind::Operator;
        stamp(m);
        m->retRef = type;
        static const char* const ops[] = {"==", "!=", "<=", ">=", "<<", ">>", "+", "-", "*", "/", "%",
                                          "&",  "|",  "^",  "!",  "~",  "<",  ">"};
        std::string op;
        if (acceptP("[")) {
            expectP("]");
            op = "[]";
        } else {
            for (const char* o : ops)
                if (acceptP(o)) {
                    op = o;
                    break;
                }
        }
        if (op.empty()) fail("operador no sobrecargable '" + cur().text + "'");
        m->name = "operator" + op;
        parseParams(m);
        finishMethod(m);
        c->methods.push_back(m);
        return;
    }

    SourceLoc nameLoc = cur().loc;
    std::string name = expectIdent();
    if (mods.isEvent && (isP("(") || isP("<") || isP("=>") || isP("{")))
        fail(nameLoc, "'event' solo se puede aplicar a campos de tipo delegado (public event Action<T> Nombre;)");

    if (isP("(") || isP("<")) {
        auto* m = new MethodDecl();
        m->loc = nameLoc;
        m->mods = mods;
        m->attrs = attrs;
        m->retRef = type;
        m->name = name;
        stamp(m);
        if (isP("<")) {
            m->typeParams = parseTypeParams();
            m->tokens = toks_;
            m->tokBegin = begin;
        }
        parseParams(m);
        finishMethod(m);
        c->methods.push_back(m);
        return;
    }

    // Propiedades:  T N => expr;   T N { get { ... } set { ... } }   T N { get; set; } = valor;
    if (isP("=>") || isP("{")) {
        if (c->isNamespaceScope) fail("las propiedades solo pueden declararse dentro de clases y structs");
        auto* m = new MethodDecl();
        m->loc = nameLoc;
        m->mods = mods;
        m->attrs = attrs;
        m->retRef = type;
        m->name = name;
        m->kind = MethodKind::Getter;
        stamp(m);
        MethodDecl* setter = nullptr;
        FieldDecl* backing = nullptr;  // propiedad automática
        auto backingField = [&]() {
            if (backing) return;
            backing = new FieldDecl();
            backing->loc = nameLoc;
            backing->mods = mods;
            backing->mods.access = Access::Private;
            backing->tref = type;
            backing->name = name + "__valor";
            backing->unsafeCtx = ctxUnsafe;
            c->fields.push_back(backing);
        };
        auto fieldRef = [&](SourceLoc l) {
            auto* n = new NameExpr(l);
            n->name = name + "__valor";
            return n;
        };
        if (isP("=>")) {
            finishMethod(m);
        } else {
            p_++;
            bool got = false;
            while (!isP("}") && !atEnd()) {
                Modifiers accessorMods = parseModifiers();
                SourceLoc al = cur().loc;
                if (cur().kind == TokKind::Ident && cur().text == "get") {
                    p_++;
                    if (got) fail("la propiedad ya tiene 'get'");
                    got = true;
                    if (acceptP(";")) {  // get; automático
                        backingField();
                        auto* b = new BlockStmt(al);
                        auto* ret = new ReturnStmt(al);
                        ret->value = fieldRef(al);
                        b->stmts.push_back(ret);
                        m->body = b;
                    } else {
                        finishMethod(m);
                    }
                } else if (cur().kind == TokKind::Ident && cur().text == "set") {
                    p_++;
                    if (setter) fail("la propiedad ya tiene 'set'");
                    setter = new MethodDecl();
                    setter->loc = al;
                    setter->mods = mods;
                    if (accessorMods.hasAccess) setter->mods.access = accessorMods.access;
                    setter->attrs = attrs;
                    setter->kind = MethodKind::Setter;
                    stamp(setter);
                    setter->name = name;
                    auto* voidRef = new TypeRef();
                    voidRef->loc = al;
                    voidRef->parts = {"void"};
                    setter->retRef = voidRef;
                    Param value;
                    value.loc = al;
                    value.tref = type;
                    value.name = "value";
                    setter->params.push_back(value);
                    if (acceptP(";")) {  // set; automático
                        backingField();
                        auto* b = new BlockStmt(al);
                        auto* st = new ExprStmt(al);
                        auto* as = new AssignExpr(al);
                        as->op = "=";
                        as->lhs = fieldRef(al);
                        auto* v = new NameExpr(al);
                        v->name = "value";
                        as->rhs = v;
                        st->expr = as;
                        b->stmts.push_back(st);
                        setter->body = b;
                    } else {
                        finishMethod(setter);
                    }
                } else {
                    fail("se esperaba 'get' o 'set'");
                }
            }
            expectP("}");
            if (!got) fail(nameLoc, "la propiedad '" + name + "' necesita un 'get'");
            if (acceptP("=")) {  // valor inicial de una propiedad automática
                if (!backing) fail("solo las propiedades automáticas ({ get; set; }) pueden tener valor inicial");
                backing->init = parseExpr();
                expectP(";");
            }
        }
        c->methods.push_back(m);
        if (setter) c->methods.push_back(setter);
        return;
    }

    // Campo(s): T a = 1, b;
    for (;;) {
        auto* f = new FieldDecl();
        f->loc = nameLoc;
        f->mods = mods;
        f->attrs = attrs;
        f->tref = type;
        f->name = name;
        f->unsafeCtx = ctxUnsafe;
        f->isEvent = mods.isEvent;
        if (acceptP("=")) f->init = parseExpr();
        c->fields.push_back(f);
        if (!acceptP(",")) break;
        nameLoc = cur().loc;
        name = expectIdent();
    }
    expectP(";");
}

ClassDecl* Parser::reparseType(ClassDecl* tmpl, Program& prog) {
    Parser p(tmpl->tokens, prog, tmpl->file, "");
    p.reparse_ = true;
    p.p_ = tmpl->tokBegin;
    try {
        std::vector<Attribute> attrs = p.parseAttributes();
        Modifiers mods = p.parseModifiers();
        return p.parseTypeDecl(tmpl->ns, attrs, mods, tmpl->tokBegin);
    } catch (ParseError&) {
        return nullptr;
    }
}

MethodDecl* Parser::reparseMethod(MethodDecl* tmpl, Program& prog) {
    Parser p(tmpl->tokens, prog, tmpl->owner->file, "");
    p.reparse_ = true;
    p.p_ = tmpl->tokBegin;
    ClassDecl tmp;
    tmp.kind = tmpl->owner->kind;
    tmp.name = tmpl->owner->templateOf ? tmpl->owner->templateOf->name : tmpl->owner->name;
    tmp.isNamespaceScope = tmpl->owner->isNamespaceScope;
    tmp.unsafeCtx = tmpl->owner->unsafeCtx;
    try {
        std::vector<Attribute> attrs = p.parseAttributes();
        Modifiers mods = p.parseModifiers();
        p.parseMember(&tmp, attrs, mods, tmpl->tokBegin);
    } catch (ParseError&) {
        return nullptr;
    }
    return tmp.methods.empty() ? nullptr : tmp.methods.back();
}

// ------------------------------------------------------------------ tipos

bool Parser::isPrimitiveKw() const {
    static const char* const prims[] = {"void", "bool", "char", "sbyte", "byte", "short", "ushort", "int",
                                         "uint", "long", "ulong", "float", "double", "string"};
    if (cur().kind != TokKind::Keyword) return false;
    for (const char* p : prims)
        if (cur().text == p) return true;
    return false;
}

// Cierra una lista de argumentos genéricos; sabe partir '>>' en dos.
bool Parser::closeAngle() {
    if (!halfGt_ && acceptP(">")) return true;
    if (isP(">>")) {
        if (halfGt_) {
            halfGt_ = false;
            p_++;
        } else {
            halfGt_ = true;
        }
        return true;
    }
    return false;
}

bool Parser::parseTypeArgs(std::vector<TypeRef*>& out) {
    if (!isP("<")) return false;
    p_++;
    if (closeAngle()) return true;  // List<>: se reporta después
    for (;;) {
        TypeRef* t = tryParseType();
        if (!t) return false;
        out.push_back(t);
        if (acceptP(",")) continue;
        return closeAngle();
    }
}

// Argumentos genéricos en una expresión (Max<int>(a, b)); se distinguen de '<' por el token siguiente.
bool Parser::tryExprTypeArgs(std::vector<TypeRef*>& out) {
    if (!isP("<")) return false;
    size_t save = p_;
    std::vector<TypeRef*> args;
    if (parseTypeArgs(args) && !halfGt_) {
        const Token& n = cur();
        static const char* const follow[] = {"(", ")", "]", ";", ",", ".", "::", "->", "?", ":", "==", "!=", "}"};
        if (n.kind == TokKind::Punct)
            for (const char* f : follow)
                if (n.text == f) {
                    out = args;
                    return true;
                }
    }
    p_ = save;
    halfGt_ = false;
    return false;
}

TypeRef* Parser::tryParseType() {
    size_t save = p_;
    bool saveHalf = halfGt_;
    auto* tr = new TypeRef();
    tr->loc = cur().loc;
    auto failType = [&]() -> TypeRef* {
        p_ = save;
        halfGt_ = saveHalf;
        return nullptr;
    };
    if (isP("(")) {  // tupla: (int, string) / (int x, int y)
        TypeRef* t = tryParseTupleType();
        if (!t) return failType();
        tr = t;
    } else if (isK("delegate")) {
        p_++;
        if (!acceptP("*") || !isP("<")) return failType();
        tr->isFuncPtr = true;
        if (!parseTypeArgs(tr->typeArgs) || tr->typeArgs.empty()) return failType();
    } else if (isPrimitiveKw()) {
        tr->parts.push_back(cur().text);
        p_++;
    } else if (cur().kind == TokKind::Ident) {
        if (cur().text == kCompletionMarker) sawMarker_ = true;
        tr->parts.push_back(cur().text);
        p_++;
        while (isDot() && peekTok().kind == TokKind::Ident) {
            p_++;
            if (cur().text == kCompletionMarker) sawMarker_ = true;
            tr->parts.push_back(cur().text);
            p_++;
        }
        if (isP("<") && !parseTypeArgs(tr->typeArgs)) return failType();
    } else {
        return failType();
    }
    if (halfGt_ && !saveHalf) return tr;  // el '>' pendiente pertenece a la lista exterior
    if (isP("?") && nullableMarkFollows()) {  // int? x
        tr->nullable = true;
        p_++;
    }
    while (isP("*")) {
        tr->ptrDepth++;
        p_++;
    }
    if (isP("&") && !halfGt_) {
        tr->isRef = true;
        p_++;
    }
    if (isP("[") && peekTok().kind == TokKind::Punct && peekTok().text == "]") {
        if (!allowArraySuffix_) return failType();
        p_ += 2;  // params T[] xs: se representa como List<T>
        auto* list = new TypeRef();
        list->loc = tr->loc;
        list->parts = {"std", "collections", "List"};
        list->typeArgs = {tr};
        requestModule({"std", "collections"});
        return list;
    }
    return tr;
}

TypeRef* Parser::parseType() {
    TypeRef* tr = tryParseType();
    if (!tr) {
        size_t save = p_;
        if (isPrimitiveKw() || cur().kind == TokKind::Ident) {
            p_++;
            while (isP("*")) p_++;
            if (isP("[")) {
                p_ = save;
                fail("los arreglos administrados (T[]) no existen; usa un puntero (T* datos = new T[n]) o List<T>");
            }
        }
        p_ = save;
        fail("se esperaba un tipo pero se encontró '" + cur().text + "'");
    }
    return tr;
}

// ------------------------------------------------------------------ sentencias

BlockStmt* Parser::parseBlock() {
    auto* b = new BlockStmt(cur().loc);
    expectP("{");
    while (!atEnd() && !isP("}")) {
        try {
            b->stmts.push_back(parseStatement());
        } catch (ParseError&) {
            skipTo(";");
        }
    }
    expectP("}");
    return b;
}

bool Parser::looksLikeDecl() {
    if (isK("const") || isK("delegate")) return true;
    if (isPrimitiveKw() && !(peekTok().kind == TokKind::Punct && (peekTok().text == "." || peekTok().text == "::")))
        return true;
    if (cur().kind != TokKind::Ident && !isP("(")) return false;  // '(' : (int, string) t = ...
    size_t save = p_;
    TypeRef* tr = tryParseType();
    bool r = false;
    if (tr && !halfGt_ && cur().kind == TokKind::Ident) {
        const Token& n = peekTok();
        r = n.kind == TokKind::Punct && (n.text == "=" || n.text == ";" || n.text == ",");
    }
    p_ = save;
    halfGt_ = false;
    return r;
}

VarDeclStmt* Parser::parseVarDecl(bool requireSemicolon) {
    auto* d = new VarDeclStmt(cur().loc);
    if (acceptK("const")) d->isConst = true;
    d->tref = parseType();
    do {
        VarDeclStmt::Declarator dc;
        dc.loc = cur().loc;
        dc.name = expectIdent();
        if (acceptP("=")) dc.init = parseExpr();
        d->decls.push_back(dc);
    } while (acceptP(","));
    if (requireSemicolon) expectP(";");
    return d;
}

Stmt* Parser::parseSwitch() {
    auto* s = new SwitchStmt(cur().loc);
    p_++;
    expectP("(");
    s->subject = parseExpr();
    expectP(")");
    expectP("{");
    while (!atEnd() && !isP("}")) {
        SwitchStmt::Section sec;
        bool any = false;
        for (;;) {
            if (acceptK("case")) {
                parseSwitchLabel(sec);  // patrón [when guarda] (ParserSugar.cpp)
                expectP(":");
                any = true;
            } else if (isK("default")) {
                p_++;
                expectP(":");
                sec.hasDefault = true;
                any = true;
            } else {
                break;
            }
        }
        if (!any) fail("se esperaba 'case' o 'default'");
        while (!atEnd() && !isP("}") && !isK("case") && !isK("default")) {
            try {
                sec.body.push_back(parseStatement());
            } catch (ParseError&) {
                skipTo(";");
            }
        }
        s->sections.push_back(std::move(sec));
    }
    expectP("}");
    return s;
}

Stmt* Parser::parseStatement() {
    SourceLoc loc = cur().loc;
    if (isP("{")) return parseBlock();
    if (acceptP(";")) return new EmptyStmt(loc);
    if (isUnsafeKw()) {  // memory_unsafe { ... }
        unsafeKeywordError();
        p_++;
        if (!isP("{")) fail("se esperaba '{' después de 'memory_unsafe' (bloque: memory_unsafe { ... })");
        BlockStmt* b = parseBlock();
        b->memoryUnsafe = true;
        return b;
    }
    if (acceptK("if")) {
        auto* s = new IfStmt(loc);
        expectP("(");
        s->cond = parseExpr();
        expectP(")");
        s->then = parseStatement();
        if (acceptK("else")) s->els = parseStatement();
        return s;
    }
    if (acceptK("while")) {
        auto* s = new WhileStmt(loc);
        expectP("(");
        s->cond = parseExpr();
        expectP(")");
        s->body = parseStatement();
        return s;
    }
    if (acceptK("do")) {
        auto* s = new DoWhileStmt(loc);
        s->body = parseStatement();
        if (!acceptK("while")) fail("se esperaba 'while'");
        expectP("(");
        s->cond = parseExpr();
        expectP(")");
        expectP(";");
        return s;
    }
    if (acceptK("for")) {
        auto* s = new ForStmt(loc);
        expectP("(");
        if (!isP(";")) {
            if (looksLikeDecl()) {
                s->initDecl = parseVarDecl(false);
            } else {
                do s->initExprs.push_back(parseExpr());
                while (acceptP(","));
            }
        }
        expectP(";");
        if (!isP(";")) s->cond = parseExpr();
        expectP(";");
        if (!isP(")")) {
            do s->iter.push_back(parseExpr());
            while (acceptP(","));
        }
        expectP(")");
        s->body = parseStatement();
        return s;
    }
    if (isK("foreach")) return parseForeach();
    if (isK("using")) return parseUsingStmt();
    if (Stmt* d = tryParseDeconstruct()) return d;  // var (a, b) = ...;  (int a, string b) = ...;
    if (acceptK("break")) {
        expectP(";");
        return new BreakStmt(loc);
    }
    if (acceptK("continue")) {
        expectP(";");
        return new ContinueStmt(loc);
    }
    if (acceptK("return")) {
        auto* s = new ReturnStmt(loc);
        if (!isP(";")) s->value = parseExpr();
        expectP(";");
        return s;
    }
    if (isK("switch")) return parseSwitch();
    if (acceptK("delete")) {
        auto* s = new DeleteStmt(loc);
        if (acceptP("[")) {
            expectP("]");
            s->isArray = true;
        }
        s->expr = parseExpr();
        expectP(";");
        return s;
    }
    if (isK("try")) return parseTry();      // excepciones: Exceptions.cpp
    if (isK("throw")) return parseThrow();
    if (isK("goto")) fail("'goto' no está soportado");
    if (looksLikeDecl()) return parseVarDecl(true);

    auto* s = new ExprStmt(loc);
    s->expr = parseExpr();
    expectP(";");
    return s;
}

// ------------------------------------------------------------------ expresiones

Expr* Parser::parseExpr() { return parseAssign(); }

Expr* Parser::parseAssign() {
    if (Expr* lambda = tryParseLambda()) return lambda;
    Expr* lhs = parseConditional();
    static const char* const ops[] = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "?\?="};
    for (const char* op : ops) {
        if (isP(op)) {
            auto* a = new AssignExpr(cur().loc);
            p_++;
            a->op = op;
            a->lhs = lhs;
            a->rhs = parseAssign();
            return a;
        }
    }
    return lhs;
}

Expr* Parser::parseConditional() {
    Expr* c = parseBinary(1);
    if (isP("??")) c = parseCoalesce(c);  // a ?? b (ParserSugar.cpp)
    if (isP("?")) {
        auto* e = new CondExpr(cur().loc);
        p_++;
        e->cond = c;
        e->a = parseAssign();
        expectP(":");
        e->b = parseAssign();
        return e;
    }
    return c;
}

static int binaryPrec(const Token& t) {
    if (t.kind != TokKind::Punct) {
        if (t.kind == TokKind::Keyword && (t.text == "is" || t.text == "as")) return -2;
        return -1;
    }
    const std::string& s = t.text;
    if (s == "||") return 1;
    if (s == "&&") return 2;
    if (s == "|") return 3;
    if (s == "^") return 4;
    if (s == "&") return 5;
    if (s == "==" || s == "!=") return 6;
    if (s == "<" || s == ">" || s == "<=" || s == ">=") return 7;
    if (s == "<<" || s == ">>") return 8;
    if (s == "+" || s == "-") return 9;
    if (s == "*" || s == "/" || s == "%") return 10;
    return -1;
}

Expr* Parser::parseBinary(int minPrec) {
    Expr* lhs = parseUnary();
    for (;;) {
        if (isK("switch")) {  // x switch { ... } (ParserSugar.cpp)
            lhs = parseSwitchExpr(lhs);
            continue;
        }
        int prec = binaryPrec(cur());
        if (prec == -2) {
            if (minPrec > 7) return lhs;
            if (isK("is")) {  // x is > 0 and < 10 (patrones; ParserSugar.cpp)
                lhs = parseIsPattern(lhs);
                continue;
            }
            fail("el operador 'as' aún no está soportado");
        }
        if (prec < minPrec) return lhs;
        auto* b = new BinaryExpr(cur().loc);
        b->op = cur().text;
        p_++;
        b->lhs = lhs;
        b->rhs = parseBinary(prec + 1);
        lhs = b;
    }
}

Expr* Parser::parseUnary() {
    SourceLoc loc = cur().loc;
    static const char* const ops[] = {"-", "+", "!", "~", "++", "--", "*", "&"};
    for (const char* op : ops) {
        if (isP(op)) {
            p_++;
            auto* u = new UnaryExpr(loc);
            u->op = op;
            u->operand = parseUnary();
            return u;
        }
    }
    // ¿Conversión explícita (T)x?
    if (isP("(")) {
        size_t save = p_;
        p_++;
        TypeRef* tr = tryParseType();
        if (tr && !tr->isRef && !halfGt_ && isP(")")) {
            p_++;
            bool keywordType = tr->parts.size() == 1 && isKeyword(tr->parts[0]);
            const Token& n = cur();
            bool startsOperand =
                n.kind == TokKind::Ident || n.kind == TokKind::Int || n.kind == TokKind::Float ||
                n.kind == TokKind::Char || n.kind == TokKind::String ||
                (n.kind == TokKind::Punct && (n.text == "(" || n.text == "!" || n.text == "~")) ||
                (n.kind == TokKind::Keyword &&
                 (n.text == "this" || n.text == "new" || n.text == "sizeof" || n.text == "true" ||
                  n.text == "false" || n.text == "null" || n.text == "nullptr"));
            bool castAnyOperand = keywordType || tr->ptrDepth > 0 || tr->isFuncPtr;
            if (startsOperand ||
                (castAnyOperand && !(n.kind == TokKind::Punct && (n.text == ")" || n.text == ";" || n.text == ",")))) {
                auto* c = new CastExpr(loc);
                c->tref = tr;
                c->operand = parseUnary();
                return c;
            }
        }
        p_ = save;
        halfGt_ = false;
    }
    return parsePostfix(parsePrimary());
}

std::vector<Expr*> Parser::parseArgs() {
    std::vector<Expr*> args;
    expectP("(");
    if (!isP(")")) {
        do {
            if (!acceptK("ref")) acceptK("out");  // C#: f(ref x) -> parámetro T&
            args.push_back(parseExpr());
        } while (acceptP(","));
    }
    expectP(")");
    return args;
}

Expr* Parser::parsePostfix(Expr* e) {
    for (;;) {
        SourceLoc loc = cur().loc;
        if (isDot() || isP("->")) {
            bool arrow = isP("->");
            p_++;
            auto* m = new MemberExpr(loc);
            m->obj = e;
            m->arrow = arrow;
            m->nameLoc = cur().loc;
            m->name = expectIdent();
            tryExprTypeArgs(m->typeArgs);
            e = m;
        } else if (isP("(")) {
            auto* c = new CallExpr(loc);
            c->callee = e;
            c->args = parseArgs();
            e = c;
        } else if (acceptP("[")) {
            auto* ix = new IndexExpr(loc);
            ix->obj = e;
            ix->index = parseExpr();
            expectP("]");
            e = ix;
        } else if (isP("?") && peekTok().kind == TokKind::Punct && (peekTok().text == "." || peekTok().text == "[")) {
            return parseConditionalAccess(e);  // obj?.Campo, obj?[i] (ParserSugar.cpp)
        } else if (isP("++") || isP("--")) {
            auto* pe = new PostfixExpr(loc);
            pe->op = cur().text;
            p_++;
            pe->operand = e;
            e = pe;
        } else {
            return e;
        }
    }
}

Expr* Parser::parsePrimary() {
    const Token& tk = cur();
    SourceLoc loc = tk.loc;
    switch (tk.kind) {
        case TokKind::Int: {
            auto* e = new IntLitExpr(loc);
            e->value = tk.intVal;
            e->suffixU = tk.isUnsigned;
            e->suffixL = tk.isLong;
            p_++;
            return e;
        }
        case TokKind::Float: {
            auto* e = new FloatLitExpr(loc);
            e->value = tk.floatVal;
            e->isFloat32 = tk.isFloat32;
            p_++;
            return e;
        }
        case TokKind::Char: {
            auto* e = new CharLitExpr(loc);
            e->value = tk.charVal;
            p_++;
            return e;
        }
        case TokKind::String: {
            auto* e = new StringLitExpr(loc);
            e->value = tk.text;
            p_++;
            // Concatenación de literales adyacentes en tiempo de compilación: "a" + "b"
            while (isP("+") && peekTok().kind == TokKind::String) {
                p_++;
                e->value += cur().text;
                p_++;
            }
            return e;
        }
        case TokKind::InterpBegin: return parseInterpolated();  // $"..." (ParserSugar.cpp)
        case TokKind::Ident: {
            if (tk.text == "nameof" && peekTok().kind == TokKind::Punct && peekTok().text == "(") return parseNameof(loc);
            auto* e = new NameExpr(loc);
            e->name = tk.text;
            if (tk.text == kCompletionMarker) sawMarker_ = true;
            p_++;
            tryExprTypeArgs(e->typeArgs);
            return e;
        }
        case TokKind::Keyword: {
            if (acceptK("true") || acceptK("false")) {
                auto* e = new BoolLitExpr(loc);
                e->value = (*toks_)[p_ - 1].text == "true";
                return e;
            }
            if (acceptK("null") || acceptK("nullptr")) return new NullExpr(loc);
            if (acceptK("this")) return new ThisExpr(loc);
            if (isK("default") && peekTok().kind == TokKind::Punct && peekTok().text == "(") {
                p_ += 2;
                auto* e = new DefaultExpr(loc);
                e->tref = parseType();
                expectP(")");
                return e;
            }
            if (acceptK("default")) return new DefaultExpr(loc);  // literal 'default' (tipo por el destino)
            if (acceptK("sizeof")) {
                auto* e = new SizeOfExpr(loc);
                expectP("(");
                e->tref = parseType();
                expectP(")");
                return e;
            }
            if (acceptK("new")) {
                TypeRef* tr = tryParseType();
                if (!tr || halfGt_) fail("se esperaba un tipo después de 'new'");
                if (acceptP("[")) {
                    auto* e = new NewArrayExpr(loc);
                    e->elemRef = tr;
                    e->count = parseExpr();
                    expectP("]");
                    return e;
                }
                if (isP("(")) {
                    auto* e = new NewExpr(loc);
                    e->tref = tr;
                    e->args = parseArgs();
                    if (isP("{")) fail("los inicializadores de objeto aún no están soportados");
                    return e;
                }
                fail("se esperaba '(' o '[' después de 'new " + tr->str() + "'");
            }
            if (isPrimitiveKw()) {  // int.MaxValue, int::MaxValue
                auto* e = new NameExpr(loc);
                e->name = tk.text;
                p_++;
                return e;
            }
            if (isK("typeof") || isK("stackalloc") || isK("fixed"))
                fail("'" + tk.text + "' aún no está soportado");
            break;
        }
        case TokKind::Punct:
            if (acceptP("(")) return parseParenOrTuple(loc);  // (e) o tupla (1, "a")
            break;
        default:
            break;
    }
    fail("se esperaba una expresión pero se encontró '" + tk.text + "'");
}
