// Faset - análisis sintáctico de métodos, construcción y organización de tipos:
//   tipos anidados            class Externa { public class Interna { } }
//   constructores estáticos   static Clase() { ... }
//   conversiones del usuario  public static implicit operator Celsius(double d) => ...;
//   indizadores               public T this[int i] { get { ... } set { ... } }
//   inicializadores           new Persona { Nombre = "Ana", Dir = { Calle = "x" } }, new List<int> { 1, 2 }
//   out var                   F(out var x), F(out int x)
//   funciones locales         se pueden llamar antes de su declaración (hoistLocalFunctions)
// La semántica está en Members.cpp, Nested.cpp y StaticInit.cpp.
#include <set>

#include "Parser.h"

namespace {

TypeRef* voidRef(SourceLoc loc) {
    auto* t = new TypeRef();
    t->loc = loc;
    t->parts = {"void"};
    return t;
}

}  // namespace

// ------------------------------------------------------------------ tipos anidados

void Parser::parseNestedType(ClassDecl* outer, std::vector<Attribute> attrs, Modifiers mods, size_t begin) {
    if (outer->isNamespaceScope) fail("expected a declaration");
    if (outer->kind == ClassKind::Interface) fail("interfaces cannot declare nested types");
    if (mods.isStatic && !isK("class")) fail("only classes can be 'static'");
    ClassDecl* n = parseTypeDecl(outer->ns, std::move(attrs), mods, begin);
    n->outer = outer;
    n->displayName = outer->displayName + "." + n->name;
    outer->nested.push_back(n);
}

// ------------------------------------------------------------------ constructores estáticos

// 'static Clase() { ... }' se guarda como un método estático sin nombre visible (".cctor") que la
// inicialización estática llama después de los inicializadores de los campos de la clase.
void Parser::finishStaticCtor(ClassDecl* c, MethodDecl* m, const FinishFn& finish) {
    if (!m->params.empty()) fail(m->loc, "a static constructor cannot have parameters");
    if (m->mods.hasAccess) fail(m->loc, "a static constructor does not allow access modifiers");
    if (isP(":")) fail("a static constructor cannot call 'base(...)' or 'this(...)'");
    m->kind = MethodKind::Normal;
    m->name = ".cctor";
    m->retRef = voidRef(m->loc);
    m->mods.access = Access::Private;
    finish(m);
    for (MethodDecl* o : c->methods)
        if (o->name == ".cctor") {
            diag.error(m->loc, "'" + c->name + "' already has a static constructor");
            return;
        }
    c->methods.push_back(m);
}

// ------------------------------------------------------------------ conversiones del usuario

// public static implicit operator Destino(Origen x) ...   /   explicit operator ...
void Parser::parseConversionOperator(ClassDecl* c, std::vector<Attribute> attrs, Modifiers mods, const FinishFn& finish) {
    bool isImplicit = cur().text == "implicit";
    p_ += 2;  // implicit|explicit operator
    auto* m = new MethodDecl();
    m->loc = cur().loc;
    m->mods = mods;
    m->attrs = std::move(attrs);
    m->kind = MethodKind::Operator;
    m->retRef = parseType();
    m->name = isImplicit ? "operator implicit" : "operator explicit";
    parseParams(m);
    finish(m);
    c->methods.push_back(m);
}

// ------------------------------------------------------------------ indizadores

// T this[int i] { get ...; set ...; }   /   T this[int x, int y] => expr;
// Se guardan como un 'get' y un 'set' llamados "this[]" (el 'set' recibe los índices y 'value').
void Parser::parseIndexer(ClassDecl* c, std::vector<Attribute> attrs, Modifiers mods, TypeRef* type, bool ctxUnsafe,
                          const FinishFn& finish) {
    (void)ctxUnsafe;
    SourceLoc loc = cur().loc;
    if (c->isNamespaceScope) fail("indexers can only be declared inside classes and structs");
    p_++;  // this
    expectP("[");
    std::vector<Param> params;
    do {
        Param prm;
        if (isP("[")) prm.attrs = parseAttributes();
        prm.loc = cur().loc;
        if (isK("ref") || isK("out") || isK("this") || isK("params"))
            fail("the parameters of an indexer cannot be 'ref', 'out', 'this', or 'params'");
        prm.tref = parseType();
        prm.name = expectIdent();
        if (acceptP("=")) prm.defaultValue = parseExpr();
        params.push_back(prm);
    } while (acceptP(","));
    expectP("]");

    auto* g = new MethodDecl();
    g->loc = loc;
    g->mods = mods;
    g->attrs = attrs;
    g->kind = MethodKind::Getter;
    g->retRef = type;
    g->name = "this[]";
    g->params = params;
    if (isP("=>")) {  // T this[int i] => expr;
        finish(g);
        c->methods.push_back(g);
        return;
    }
    bool noBody = c->kind == ClassKind::Interface || mods.isAbstract;
    MethodDecl* setter = nullptr;
    bool got = false;
    expectP("{");
    while (!isP("}") && !atEnd()) {
        Modifiers am = parseModifiers();
        SourceLoc al = cur().loc;
        if (cur().kind == TokKind::Ident && cur().text == "get") {
            p_++;
            if (got) fail("the indexer already has 'get'");
            got = true;
            if (acceptP(";")) {
                if (!noBody) fail(al, "the 'get' of an indexer needs a body");
                g->body = nullptr;
            } else {
                finish(g);
            }
        } else if (cur().kind == TokKind::Ident && (cur().text == "set" || cur().text == "init")) {
            bool initOnly = cur().text == "init";
            p_++;
            if (setter) fail("the indexer already has 'set'");
            setter = new MethodDecl();
            setter->loc = al;
            setter->mods = mods;
            if (am.hasAccess) setter->mods.access = am.access;
            setter->attrs = attrs;
            setter->kind = MethodKind::Setter;
            setter->name = "this[]";
            setter->isInit = initOnly;
            setter->retRef = voidRef(al);
            setter->params = params;
            Param value;
            value.loc = al;
            value.tref = type;
            value.name = "value";
            for (Param& p : setter->params) p.defaultValue = nullptr;  // los valores por defecto son del 'get'
            setter->params.push_back(value);
            if (acceptP(";")) {
                if (!noBody) fail(al, "the 'set' of an indexer needs a body");
                setter->body = nullptr;
            } else {
                finish(setter);
            }
        } else {
            fail("expected 'get' or 'set'");
        }
    }
    expectP("}");
    if (!got && !setter) fail(loc, "the indexer needs a 'get' or a 'set'");
    if (got) c->methods.push_back(g);
    if (setter) {
        if (!got)  // indizador de solo escritura: los valores por defecto quedan en el 'set'
            for (size_t i = 0; i < params.size(); i++) setter->params[i].defaultValue = params[i].defaultValue;
        c->methods.push_back(setter);
    }
}

// ------------------------------------------------------------------ inicializadores de objeto y colección

// { Miembro = valor, Miembro = { ... }, [índices] = valor, valor, { arg1, arg2 } }
ObjInit* Parser::parseObjInit() {
    auto* oi = new ObjInit();
    oi->loc = cur().loc;
    expectP("{");
    while (!isP("}") && !atEnd()) {
        ObjInit::Entry en;
        en.loc = cur().loc;
        auto valueOrNested = [&]() {
            if (isP("{")) en.nested = parseObjInit();
            else en.value = parseExpr();
        };
        if (cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct && peekTok().text == "=") {
            en.kind = ObjInit::Entry::Member;
            en.name = cur().text;
            if (en.name == kCompletionMarker) sawMarker_ = true;
            p_ += 2;
            valueOrNested();
        } else if (acceptP("[")) {
            en.kind = ObjInit::Entry::Index;
            do en.args.push_back(parseExpr());
            while (acceptP(","));
            expectP("]");
            expectP("=");
            valueOrNested();
        } else if (acceptP("{")) {  // { "b", 2 } -> Add("b", 2)
            en.kind = ObjInit::Entry::Add;
            if (!isP("}")) {
                do en.args.push_back(parseExpr());
                while (acceptP(","));
            }
            expectP("}");
        } else {
            en.kind = ObjInit::Entry::Add;
            en.args.push_back(parseExpr());
        }
        oi->entries.push_back(en);
        if (!acceptP(",")) break;
    }
    if (sawMarker_ && !isP("}")) return oi;  // escribiendo: se tolera la '}' ausente
    expectP("}");
    return oi;
}

// ------------------------------------------------------------------ out var

// Después de 'out' en un argumento: 'var x' o 'T x' seguidos de ',' o ')' declaran la variable.
Expr* Parser::tryParseOutVar() {
    size_t save = p_;
    bool saveHalf = halfGt_;
    SourceLoc loc = cur().loc;
    TypeRef* t = (isPrimitiveKw() || cur().kind == TokKind::Ident) ? tryParseType() : nullptr;
    if (t && !halfGt_ && cur().kind == TokKind::Ident && peekTok().kind == TokKind::Punct &&
        (peekTok().text == "," || peekTok().text == ")")) {
        auto* o = new OutVarExpr(loc);
        o->tref = t;
        o->name = cur().text;
        p_++;
        return o;
    }
    p_ = save;
    halfGt_ = saveHalf;
    return nullptr;
}

// ------------------------------------------------------------------ funciones locales

// ParserIterators.cpp convierte 'int Ayuda(int x) { ... }' en un bloque sin ámbito propio con
// 'Func<int, int> Ayuda = null; Ayuda = (int x) => { ... };'. Aquí la declaración se sube al
// principio del bloque que la contiene, para poder llamarla antes de su declaración y entre
// funciones locales (recursión mutua), como en C#.

namespace {

// Nombres que usa una expresión o sentencia sin comprobar (para colocar la lambda de una función
// local). 'unknown' se activa si aparece un nodo que no se sabe recorrer.
struct NameCollector {
    std::set<std::string> names;
    bool unknown = false;
    void expr(Expr* e) {
        if (!e) return;
        switch (e->kind) {
            case EK::IntLit: case EK::FloatLit: case EK::BoolLit: case EK::CharLit: case EK::StringLit: case EK::Null:
            case EK::This: case EK::Default: case EK::SizeOf: case EK::TypeOf: case EK::NameOf: case EK::CondRecv:
                break;
            case EK::Name: names.insert(static_cast<NameExpr*>(e)->name); break;
            case EK::Member: expr(static_cast<MemberExpr*>(e)->obj); break;
            case EK::Call: {
                auto* c = static_cast<CallExpr*>(e);
                expr(c->callee);
                for (Expr* a : c->args) expr(a);
                break;
            }
            case EK::Index: {
                auto* ix = static_cast<IndexExpr*>(e);
                expr(ix->obj);
                expr(ix->index);
                for (Expr* a : ix->moreIndices) expr(a);
                break;
            }
            case EK::Unary: expr(static_cast<UnaryExpr*>(e)->operand); break;
            case EK::Postfix: expr(static_cast<PostfixExpr*>(e)->operand); break;
            case EK::Binary:
                expr(static_cast<BinaryExpr*>(e)->lhs);
                expr(static_cast<BinaryExpr*>(e)->rhs);
                break;
            case EK::Assign:
                expr(static_cast<AssignExpr*>(e)->lhs);
                expr(static_cast<AssignExpr*>(e)->rhs);
                break;
            case EK::Cond: {
                auto* c = static_cast<CondExpr*>(e);
                expr(c->cond);
                expr(c->a);
                expr(c->b);
                break;
            }
            case EK::Cast: expr(static_cast<CastExpr*>(e)->operand); break;
            case EK::New: {
                auto* n = static_cast<NewExpr*>(e);
                for (Expr* a : n->args) expr(a);
                if (n->init) init(n->init);
                break;
            }
            case EK::NewArray: expr(static_cast<NewArrayExpr*>(e)->count); break;
            case EK::Lambda: {
                auto* l = static_cast<LambdaExpr*>(e);
                expr(l->exprBody);
                stmt(l->blockBody);
                break;
            }
            case EK::Interp:
                for (auto& p : static_cast<InterpExpr*>(e)->parts) expr(p.expr);
                break;
            case EK::Tuple:
                for (Expr* x : static_cast<TupleExpr*>(e)->elems) expr(x);
                break;
            case EK::CondAccess:
                expr(static_cast<CondAccessExpr*>(e)->obj);
                expr(static_cast<CondAccessExpr*>(e)->access);
                break;
            case EK::Is: expr(static_cast<IsExpr*>(e)->operand); break;
            case EK::As: expr(static_cast<AsExpr*>(e)->operand); break;
            case EK::With: {
                auto* w = static_cast<WithExpr*>(e);
                expr(w->operand);
                for (auto& in : w->inits) expr(in.value);
                break;
            }
            case EK::Await: expr(static_cast<AwaitExpr*>(e)->operand); break;
            case EK::Pipe:
                expr(static_cast<PipeExpr*>(e)->lhs);
                expr(static_cast<PipeExpr*>(e)->rhs);
                break;
            case EK::Propagate: expr(static_cast<PropagateExpr*>(e)->operand); break;
            case EK::UnionCase:
                for (Expr* a : static_cast<UnionCaseExpr*>(e)->args) expr(a);
                break;
            default: unknown = true; break;
        }
    }
    void init(ObjInit* oi) {
        for (auto& en : oi->entries) {
            for (Expr* a : en.args) expr(a);
            expr(en.value);
            if (en.nested) init(en.nested);
        }
    }
    void stmt(Stmt* s) {
        if (!s) return;
        switch (s->kind) {
            case SK::Block:
                for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) stmt(c);
                break;
            case SK::VarDecl:
                for (auto& d : static_cast<VarDeclStmt*>(s)->decls) expr(d.init);
                break;
            case SK::ExprStmt: expr(static_cast<ExprStmt*>(s)->expr); break;
            case SK::If: {
                auto* i = static_cast<IfStmt*>(s);
                expr(i->cond);
                stmt(i->then);
                stmt(i->els);
                break;
            }
            case SK::While:
                expr(static_cast<WhileStmt*>(s)->cond);
                stmt(static_cast<WhileStmt*>(s)->body);
                break;
            case SK::DoWhile:
                expr(static_cast<DoWhileStmt*>(s)->cond);
                stmt(static_cast<DoWhileStmt*>(s)->body);
                break;
            case SK::For: {
                auto* f = static_cast<ForStmt*>(s);
                stmt(f->initDecl);
                for (Expr* x : f->initExprs) expr(x);
                expr(f->cond);
                for (Expr* x : f->iter) expr(x);
                stmt(f->body);
                break;
            }
            case SK::Foreach:
                expr(static_cast<ForeachStmt*>(s)->coll);
                stmt(static_cast<ForeachStmt*>(s)->body);
                break;
            case SK::Return: expr(static_cast<ReturnStmt*>(s)->value); break;
            case SK::Throw: expr(static_cast<ThrowStmt*>(s)->value); break;
            case SK::Break: case SK::Continue: case SK::Empty: break;
            case SK::Switch: {
                auto* sw = static_cast<SwitchStmt*>(s);
                expr(sw->subject);
                for (auto& sec : sw->sections) {
                    for (Expr* g : sec.guards) expr(g);
                    for (Stmt* b : sec.body) stmt(b);
                }
                break;
            }
            case SK::Try: {
                auto* t = static_cast<TryStmt*>(s);
                stmt(t->body);
                for (auto& c : t->catches) {
                    expr(c.filter);
                    stmt(c.body);
                }
                stmt(t->finallyBody);
                break;
            }
            case SK::Using: {
                auto* u = static_cast<UsingStmt*>(s);
                stmt(u->decl);
                expr(u->expr);
                stmt(u->body);
                break;
            }
            case SK::Deconstruct: expr(static_cast<DeconstructStmt*>(s)->init); break;
            case SK::Yield: expr(static_cast<YieldStmt*>(s)->value); break;
            case SK::Defer: stmt(static_cast<DeferStmt*>(s)->body); break;
            default: unknown = true; break;
        }
    }
};

// Nombres que declara una sentencia en el ámbito del bloque.
void declaredNames(Stmt* s, std::set<std::string>& out) {
    if (s->kind == SK::Block && static_cast<BlockStmt*>(s)->noScope) {  // declaraciones generadas
        for (Stmt* c : static_cast<BlockStmt*>(s)->stmts) declaredNames(c, out);
    } else if (s->kind == SK::VarDecl) {
        for (auto& d : static_cast<VarDeclStmt*>(s)->decls) out.insert(d.name);
    } else if (s->kind == SK::Deconstruct) {
        for (auto& n : static_cast<DeconstructStmt*>(s)->names) out.insert(n);
    } else if (s->kind == SK::Using) {
        auto* u = static_cast<UsingStmt*>(s);
        if (u->decl && !u->body)
            for (auto& d : u->decl->decls) out.insert(d.name);
    }
}

}  // namespace

// Funciones locales de un bloque: la variable delegado se declara al principio (así se pueden
// llamar entre sí y antes de su declaración) y la lambda se asigna justo después de la última
// declaración del bloque que usa (las variables que captura ya existen), o al principio si no usa
// ninguna. Si el cuerpo tiene construcciones que no se saben recorrer, se queda en su sitio.
void Parser::hoistLocalFunctions(BlockStmt* b) {
    // { Func<...> F = null; F = lambda; } (sin ámbito propio): la forma de ParserIterators.cpp
    auto localFn = [](Stmt* s) -> BlockStmt* {
        if (s->kind != SK::Block) return nullptr;
        auto* blk = static_cast<BlockStmt*>(s);
        if (!blk->noScope || blk->stmts.size() != 2 || blk->stmts[0]->kind != SK::VarDecl ||
            !static_cast<VarDeclStmt*>(blk->stmts[0])->isLocalFunction || blk->stmts[1]->kind != SK::ExprStmt)
            return nullptr;
        return blk;
    };
    bool any = false;
    for (Stmt* s : b->stmts)
        if (localFn(s)) any = true;
    if (!any) return;
    struct Pending {
        Stmt* assign;
        std::set<std::string> uses;
        bool stay;
        size_t original;  // número de sentencias normales que la preceden
    };
    std::vector<Stmt*> decls;
    std::vector<Pending> pend;
    std::vector<Stmt*> body;  // las sentencias que no son funciones locales, en orden
    for (Stmt* s : b->stmts) {
        BlockStmt* lf = localFn(s);
        if (!lf) {
            body.push_back(s);
            continue;
        }
        decls.push_back(lf->stmts[0]);
        Stmt* st = lf->stmts[1];
        NameCollector nc;
        nc.expr(static_cast<AssignExpr*>(static_cast<ExprStmt*>(st)->expr)->rhs);
        pend.push_back({st, nc.names, nc.unknown, body.size()});
    }
    std::vector<std::vector<Stmt*>> before(body.size() + 1);  // before[k]: se insertan antes de body[k]
    for (Pending& p : pend) {
        size_t pos = 0;
        if (p.stay) {
            pos = p.original;
        } else {
            for (size_t k = 0; k < body.size(); k++) {  // también las declaradas después (C#: asignadas antes de llamarla)
                std::set<std::string> names;
                declaredNames(body[k], names);
                for (const std::string& nm : names)
                    if (p.uses.count(nm)) pos = k + 1;
            }
        }
        before[pos].push_back(p.assign);
    }
    std::vector<Stmt*> out = decls;
    for (size_t k = 0; k <= body.size(); k++) {
        for (Stmt* s : before[k]) out.push_back(s);
        if (k < body.size()) out.push_back(body[k]);
    }
    b->stmts = out;
}
