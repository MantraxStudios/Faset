// Faset - análisis sintáctico de los tipos algebraicos (union), el operador '?' de propagación,
// defer / errdefer, el operador |> y el alias 'match' del 'switch' de expresión.
//
//   union Forma { Circulo(double Radio), Rect(double Ancho, double Alto), Punto; ...miembros }
//   union Arbol<T> { Hoja(T Valor), Nodo(Arbol<T> Izq, Arbol<T> Der) }
//   union class X { ... }   union struct Y { ... }   (forzar referencia o valor)
//
// La unión se convierte aquí mismo en un struct (o una clase si es recursiva o 'union class') con
// miembros generados como código Faset, igual que los 'record' (ver ParserClasses.cpp):
//
//   public int __caso;                         etiqueta: índice del caso (0 = el primero)
//   public double __Circulo_Radio; ...          un campo por cada campo de cada caso
//   public static Forma Circulo(double Radio)   construcción: Forma.Circulo(2)
//   public static Forma Punto { get; }          casos sin campos: Forma.Punto
//   ToString, GetHashCode, ==, !=, Equals       los cuerpos los escribe CodeGen (Unions.cpp)
//
// La disposición es plana (un campo por cada campo de cada caso, sin 'union' de C): así el
// recolector ve siempre los punteros y no hay lecturas de un miembro distinto del escrito.
#include "Parser.h"

// 'union' es una palabra clave contextual: union Nombre, union class Nombre, union struct Nombre.
bool Parser::isUnionStart() const {
    if (cur().kind != TokKind::Ident || cur().text != "union") return false;
    const Token& n = peekTok();
    if (n.kind == TokKind::Ident) return true;
    return n.kind == TokKind::Keyword && (n.text == "class" || n.text == "struct") && peekTok(2).kind == TokKind::Ident;
}

namespace {

// ¿Aparece el nombre de la unión en el tipo (directamente o como argumento genérico)?
bool mentions(const TypeRef* t, const std::string& name) {
    if (!t) return false;
    for (const std::string& p : t->parts)
        if (p == name) return true;
    for (const TypeRef* a : t->typeArgs)
        if (mentions(a, name)) return true;
    return false;
}

}  // namespace

// Lista de casos (separados por ',', terminada en ';' o '}') y después los miembros.
void Parser::parseUnionBody(ClassDecl* c) {
    UnionInfo* u = c->unionInfo;
    bool members = false;
    while (!atEnd() && !isP("}")) {
        if (cur().kind != TokKind::Ident) fail("se esperaba el nombre de un caso de la unión '" + c->name + "'");
        UnionCaseInfo uc;
        uc.loc = cur().loc;
        uc.name = expectIdent();
        if (isP("(")) {
            MethodDecl tmp;
            parseParams(&tmp);
            if (tmp.variadic) diag.error(uc.loc, "un caso de una unión no puede tener '...'");
            uc.fields = tmp.params;
        }
        bool dup = u->find(uc.name) >= 0;
        if (dup) diag.error(uc.loc, "el caso '" + uc.name + "' está repetido en la unión '" + c->name + "'");
        if (uc.name == c->name) diag.error(uc.loc, "un caso no puede llamarse igual que su unión ('" + c->name + "')");
        std::set<std::string> seen;
        for (Param& p : uc.fields) {
            if (p.tref->isRef || p.isThis || p.isParams)
                diag.error(p.loc, "los campos de un caso no pueden ser 'ref', 'out', 'this' ni 'params'");
            if (!seen.insert(p.name).second)
                diag.error(p.loc, "el campo '" + p.name + "' está repetido en el caso '" + uc.name + "'");
        }
        if (!dup) u->cases.push_back(uc);
        if (acceptP(",")) continue;
        if (acceptP(";")) {
            members = true;
            break;
        }
        if (!isP("}")) fail("se esperaba ',' entre los casos de la unión (o ';' antes de sus miembros)");
    }
    if (u->cases.empty()) diag.error(c->loc, "la unión '" + c->name + "' necesita al menos un caso");
    if (members) {
        bool savedHas = hasSection_;
        Access savedSec = section_;
        hasSection_ = false;
        while (!atEnd() && !isP("}")) {
            try {
                size_t mb = p_;
                std::vector<Attribute> ma = parseAttributes();
                Modifiers mm = parseModifiers();
                parseMember(c, ma, mm, mb);  // acceso por defecto: público (la unión es aún un struct)
            } catch (ParseError&) {
                skipTo(";");
            }
        }
        hasSection_ = savedHas;
        section_ = savedSec;
    }
    // Recursiva (se contiene a sí misma): tipo por referencia, si no tendría tamaño infinito.
    for (UnionCaseInfo& uc : u->cases)
        for (Param& p : uc.fields)
            if (mentions(p.tref, c->name)) u->isRef = true;
    if (u->isRef) c->kind = ClassKind::Class;
    for (MethodDecl* m : c->ctors)
        diag.error(m->loc, "una unión no puede declarar constructores: se crea con sus casos (" + c->name + "." +
                               (u->cases.empty() ? std::string("Caso") : u->cases[0].name) + "(...))");
    synthesizeUnion(c);
}

void Parser::synthesizeUnion(ClassDecl* c) {
    UnionInfo* u = c->unionInfo;
    bool isRef = u->isRef;
    std::string self = c->name;
    if (!c->typeParams.empty()) {
        self += "<";
        for (size_t i = 0; i < c->typeParams.size(); i++) self += (i ? ", " : "") + c->typeParams[i];
        self += ">";
    }
    auto has = [&](const std::string& name, size_t nparams) {
        for (MethodDecl* m : c->methods)
            if (m->name == name && m->params.size() == nparams && m->kind == MethodKind::Normal) return true;
        return false;
    };
    std::string init = isRef ? "new " + self + "()" : "default";
    std::vector<std::pair<std::string, int>> members;
    members.push_back({"public int __caso;", 0});
    if (isRef) members.push_back({"private " + c->name + "() { }", 0});
    for (size_t k = 0; k < u->cases.size(); k++) {
        UnionCaseInfo& uc = u->cases[k];
        std::string body = self + " __u = " + init + "; __u.__caso = " + std::to_string(k) + "; ";
        std::string params;
        for (size_t i = 0; i < uc.fields.size(); i++) {
            const Param& p = uc.fields[i];
            std::string f = unionFieldName(uc.name, p.name);
            members.push_back({"public " + p.tref->str() + " " + f + ";", 0});
            params += (i ? ", " : "") + p.tref->str() + " " + p.name;
            body += "__u." + f + " = " + p.name + "; ";
        }
        body += "return __u;";
        if (uc.unit()) members.push_back({"public static " + self + " " + uc.name + " { get { " + body + " } }", 0});
        else members.push_back({"public static " + self + " " + uc.name + "(" + params + ") { " + body + " }", 0});
    }
    if (!has("ToString", 0))
        members.push_back({std::string("public ") + (isRef ? "override " : "") + "string ToString() { return \"\"; }", 4});
    if (!has("GetHashCode", 0))
        members.push_back({std::string("public ") + (isRef ? "override " : "") + "int GetHashCode() { return 0; }", 5});
    members.push_back({"public static bool operator==(" + self + " a, " + self + " b) { return false; }", 6});
    members.push_back({"public static bool operator!=(" + self + " a, " + self + " b) { return !(a == b); }", 0});
    if (isRef && !has("Equals", 1))
        members.push_back({"public override bool Equals(object o) { return o is " + self + " r && this == r; }", 0});
    members.push_back({"public bool Equals(" + self + " o) { return this == o; }", 0});

    for (auto& [text, gen] : members) {
        auto toks = std::make_shared<std::vector<Token>>(tokenize(text, file_->fileId));
        for (Token& t : *toks) t.loc = c->loc;
        Parser sub(toks, prog_, file_, fileDir_);
        sub.reparse_ = true;
        sub.nsUnsafe_ = nsUnsafe_;
        size_t before = c->methods.size();
        try {
            std::vector<Attribute> attrs = sub.parseAttributes();
            Modifiers mods = sub.parseModifiers();
            sub.parseMember(c, attrs, mods, 0);
        } catch (ParseError&) {
        }
        if (gen && c->methods.size() > before) c->methods.back()->recordGen = gen;
    }
}

// Forma.Circulo(var r), Some(> 0), Rect(_, var alto) r  — el '(' ya es el token actual.
Pattern* Parser::parseCasePattern(TypeRef* tr, SourceLoc loc) {
    auto* p = new Pattern(PK::Case, loc);
    p->tref = tr;
    expectP("(");
    if (!isP(")")) {
        do p->elems.push_back(parsePattern());
        while (acceptP(","));
    }
    expectP(")");
    if (cur().kind == TokKind::Ident && !isIdentText("and") && !isIdentText("or") && !isIdentText("when")) {
        p->nameLoc = cur().loc;
        p->name = expectIdent();
    }
    return p;
}

// ¿El '?' actual es el operador de propagación (expr?) y no el de 'c ? a : b'? Lo es si lo que
// sigue no puede empezar una expresión (; ) , ] } : == && ...) o si no hay un ':' que lo cierre.
bool Parser::propagateFollows() const {
    const Token& n = peekTok();
    if (n.kind == TokKind::End) return true;
    if (n.kind == TokKind::Punct) {
        static const char* const ends[] = {";", ")", ",", "]", "}", ":", "?", "??", "==", "!=", "&&", "||", "|>",
                                           "/", "%", "<=", ">=", ">", "|", "^", "=", "+=", "-=", "*=", "/=", "=>"};
        for (const char* e : ends)
            if (n.text == e) return true;
    }
    if (n.kind == TokKind::Keyword && (n.text == "is" || n.text == "as")) return true;
    if (n.kind == TokKind::Ident && (n.text == "switch" || n.text == "match" || n.text == "with")) return true;
    // Puede empezar una expresión: es un '?:' si hay un ':' a la misma profundidad antes del final.
    // 'angle' cuenta los '<' que siguen a un nombre (posibles argumentos de tipo: c ? R<int, E>.Ok(1) : x),
    // para no tomar su ',' por el final de la expresión.
    int depth = 0, pending = 0, angle = 0;
    for (size_t i = p_ + 1; i < toks_->size(); i++) {
        const Token& t = (*toks_)[i];
        if (t.kind == TokKind::End) break;
        if (t.kind != TokKind::Punct) continue;
        const std::string& s = t.text;
        if (s == "<" && depth == 0 && (*toks_)[i - 1].kind == TokKind::Ident) angle++;
        else if (s == ">" && angle > 0) angle--;
        else if (s == ">>" && angle > 0) angle = angle > 1 ? angle - 2 : 0;
        else if (s == "," && depth == 0 && angle > 0) continue;
        else if (s == "(" || s == "[" || s == "{") depth++;
        else if (s == ")" || s == "]" || s == "}") {
            if (depth == 0) return true;
            depth--;
        } else if (depth == 0) {
            if (s == ";" || s == ",") return true;
            if (s == "?") pending++;
            else if (s == ":") {
                if (pending == 0) return false;
                pending--;
            }
        }
    }
    return true;
}

bool Parser::isMatchKw() const {
    return cur().kind == TokKind::Ident && cur().text == "match" && peekTok().kind == TokKind::Punct &&
           peekTok().text == "{";
}

// defer sentencia;  defer { ... }  errdefer ...;  (palabras clave contextuales)
Stmt* Parser::tryParseDefer() {
    if (cur().kind != TokKind::Ident || (cur().text != "defer" && cur().text != "errdefer")) return nullptr;
    const Token& n = peekTok();
    bool ok = n.kind == TokKind::Ident || n.kind == TokKind::Keyword || (n.kind == TokKind::Punct && n.text == "{");
    if (!ok) return nullptr;
    auto* d = new DeferStmt(cur().loc);
    d->onError = cur().text == "errdefer";
    p_++;
    d->body = parseStatement();
    if (d->body->kind == SK::VarDecl)
        diag.error(d->body->loc, std::string("'") + (d->onError ? "errdefer" : "defer") +
                                     "' no admite una declaración (no se vería después); usa un bloque { ... }");
    return d;
}

// a |> f |> g  (asocia por la izquierda; la parte derecha puede ser una lambda: a |> x => ...)
Expr* Parser::parsePipe(Expr* lhs) {
    while (isP("|>")) {
        auto* e = new PipeExpr(cur().loc);
        p_++;
        e->lhs = lhs;
        if (Expr* l = tryParseLambda()) {  // su cuerpo llega hasta el final: a |> x => f(x) |> g es f(x) |> g
            e->rhs = l;
            return e;
        }
        size_t start = p_;
        e->rhs = parseBinary(1);
        if (isP("??")) e->rhs = parseCoalesce(e->rhs);
        // a |> (expr): los paréntesis abarcan toda la parte derecha
        if ((*toks_)[start].kind == TokKind::Punct && (*toks_)[start].text == "(") {
            int depth = 0;
            size_t i = start;
            for (; i < p_; i++) {
                const Token& t = (*toks_)[i];
                if (t.kind != TokKind::Punct) continue;
                if (t.text == "(" || t.text == "[" || t.text == "{") depth++;
                else if (t.text == ")" || t.text == "]" || t.text == "}") {
                    if (--depth == 0) break;
                }
            }
            e->rhsParen = i + 1 == p_;
        }
        lhs = e;
    }
    return lhs;
}
