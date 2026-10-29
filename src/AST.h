// Faset - árbol de sintaxis abstracta.
//
// Los nodos se reservan con 'new' y viven hasta el final del proceso
// (el compilador es de corta duración, igual que un arena).
#pragma once
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "Common.h"
#include "Lexer.h"
#include "Types.h"

struct ClassDecl;
struct MethodDecl;
struct FieldDecl;
struct Expr;
struct NamespaceSym;

using TokenList = std::shared_ptr<const std::vector<Token>>;

// Identificador que el servidor de lenguaje inserta en la posición del cursor
// para pedir sugerencias de autocompletado.
inline const char* const kCompletionMarker = "__faset_completar__";

struct TypeRef {
    SourceLoc loc;
    std::vector<std::string> parts;  // "int" o A.B.Tipo / A::B::Tipo
    std::vector<TypeRef*> typeArgs;  // List<int>; en delegate*<...> son parámetros + retorno
    int ptrDepth = 0;
    bool isRef = false;              // T&
    bool isFuncPtr = false;          // delegate*<A, B, R>
    bool isVar() const {
        return parts.size() == 1 && (parts[0] == "var" || parts[0] == "auto") && ptrDepth == 0 && typeArgs.empty() &&
               !isFuncPtr;
    }
    std::string str() const {
        std::string s;
        if (isFuncPtr) s = "delegate*";
        for (size_t i = 0; i < parts.size(); i++) s += (i ? "." : "") + parts[i];
        if (!typeArgs.empty()) {
            s += "<";
            for (size_t i = 0; i < typeArgs.size(); i++) s += (i ? ", " : "") + typeArgs[i]->str();
            s += ">";
        }
        return s + std::string(ptrDepth, '*') + (isRef ? "&" : "");
    }
};

enum class Access { Private, Public, Internal, Protected };

struct Modifiers {
    Access access = Access::Private;
    bool hasAccess = false;
    bool isStatic = false, isExtern = false, isConst = false, isReadonly = false, isPartial = false;
    bool isMemoryUnsafe = false;  // modificador 'memory_unsafe'
    bool isEvent = false;         // modificador contextual 'event' (campos de tipo delegado)
};

struct Attribute {
    SourceLoc loc;
    std::string name;
    std::vector<std::string> args;
};

// Directiva 'using' / 'import' de un archivo.
struct UsingDirective {
    SourceLoc loc;
    std::vector<std::string> path;
    std::string alias;                 // using Alias = X.Y;
    TypeRef* aliasType = nullptr;      // destino del alias si tiene argumentos genéricos
};

// Contexto de un archivo fuente: sus 'using' (resueltos por Sema).
struct FileScope {
    int fileId = 0;
    // Todo el archivo es un contexto memory_unsafe: directiva 'memory_unsafe;' o
    // proyecto con <AllowUnsafe>true</AllowUnsafe>.
    bool unsafeCtx = false;
    std::vector<UsingDirective> usings;
    std::vector<NamespaceSym*> nsUsings;
    bool resolved = false;
};

struct VarInfo {
    std::string name, cname;
    Type* type = nullptr;
    bool isConst = false;
    bool isRef = false;  // referencia (T&): se guarda como puntero en C
    Expr* constInit = nullptr;
    SourceLoc loc;
    // Cierres (ver Lambdas.cpp): nivel de anidamiento de lambdas donde se declaró y si alguna
    // lambda la captura. Una variable capturada vive en una caja del recolector compartida por
    // el método y todas sus lambdas (captura por referencia, como en C#).
    int fnDepth = 0;
    bool captured = false;
};

// ---------------------------------------------------------------- expresiones

enum class EK {
    IntLit, FloatLit, BoolLit, CharLit, StringLit, Null, Name, Member, Call, Index, Unary, Postfix,
    Binary, Assign, Cond, Cast, New, NewArray, SizeOf, This, Default,
    Lambda, DelegateConv
};

// Qué denota una expresión tras el análisis semántico.
enum class ValKind { Value, TypeName, Namespace, MethodGroup };

struct Expr {
    EK kind;
    SourceLoc loc;
    Type* type = nullptr;
    ValKind vk = ValKind::Value;
    Type* typeValue = nullptr;          // vk == TypeName
    NamespaceSym* nsValue = nullptr;    // vk == Namespace
    std::vector<MethodDecl*> group;     // vk == MethodGroup
    Expr(EK k, SourceLoc l) : kind(k), loc(l) {}
    virtual ~Expr() = default;
};

struct IntLitExpr : Expr {
    uint64_t value = 0;
    bool suffixU = false, suffixL = false;
    explicit IntLitExpr(SourceLoc l) : Expr(EK::IntLit, l) {}
};
struct FloatLitExpr : Expr {
    double value = 0;
    bool isFloat32 = false;
    explicit FloatLitExpr(SourceLoc l) : Expr(EK::FloatLit, l) {}
};
struct BoolLitExpr : Expr {
    bool value = false;
    explicit BoolLitExpr(SourceLoc l) : Expr(EK::BoolLit, l) {}
};
struct CharLitExpr : Expr {
    uint32_t value = 0;
    explicit CharLitExpr(SourceLoc l) : Expr(EK::CharLit, l) {}
};
struct StringLitExpr : Expr {
    std::string value;
    explicit StringLitExpr(SourceLoc l) : Expr(EK::StringLit, l) {}
};
struct NullExpr : Expr {
    explicit NullExpr(SourceLoc l) : Expr(EK::Null, l) {}
};
struct ThisExpr : Expr {
    explicit ThisExpr(SourceLoc l) : Expr(EK::This, l) {}
};

struct NameExpr : Expr {
    std::string name;
    std::vector<TypeRef*> typeArgs;  // Max<int>(...)
    enum class Ref { None, Local, Field, StaticField, Property } ref = Ref::None;
    VarInfo* var = nullptr;
    FieldDecl* field = nullptr;
    MethodDecl* getter = nullptr;    // Property
    MethodDecl* setter = nullptr;    // Property con 'set'
    explicit NameExpr(SourceLoc l) : Expr(EK::Name, l) {}
};

struct MemberExpr : Expr {
    Expr* obj = nullptr;
    std::string name;
    std::vector<TypeRef*> typeArgs;
    SourceLoc nameLoc;   // posición del nombre (tras '.', '::' o '->')
    bool arrow = false;  // obj->name
    enum class Ref { None, Field, StaticField, EnumConst, ConstInt, StrLength, StrPtr, Property, DelegateInvoke } ref = Ref::None;
    FieldDecl* field = nullptr;
    MethodDecl* getter = nullptr;    // Property
    MethodDecl* setter = nullptr;    // Property con 'set'
    uint64_t constBits = 0;          // EnumConst / ConstInt
    bool extension = false;          // grupo de métodos de extensión sobre 'obj'
    explicit MemberExpr(SourceLoc l) : Expr(EK::Member, l) {}
};

struct CallExpr : Expr {
    Expr* callee = nullptr;
    std::vector<Expr*> args;
    MethodDecl* target = nullptr;    // nulo si se llama a través de un puntero a función
    Expr* receiver = nullptr;        // para métodos de instancia con receptor explícito
    bool receiverArrow = false;
    bool implicitThis = false;
    explicit CallExpr(SourceLoc l) : Expr(EK::Call, l) {}
};

struct IndexExpr : Expr {
    Expr* obj = nullptr;
    Expr* index = nullptr;
    MethodDecl* opMethod = nullptr;  // operator[]
    explicit IndexExpr(SourceLoc l) : Expr(EK::Index, l) {}
};

struct UnaryExpr : Expr {  // prefijo: - + ! ~ ++ -- * &
    std::string op;
    Expr* operand = nullptr;
    MethodDecl* opMethod = nullptr;  // operador sobrecargado
    MethodDecl* funcRef = nullptr;   // &Funcion -> puntero a función
    explicit UnaryExpr(SourceLoc l) : Expr(EK::Unary, l) {}
};

struct PostfixExpr : Expr {  // x++ x--
    std::string op;
    Expr* operand = nullptr;
    explicit PostfixExpr(SourceLoc l) : Expr(EK::Postfix, l) {}
};

struct BinaryExpr : Expr {
    std::string op;
    Expr* lhs = nullptr;
    Expr* rhs = nullptr;
    MethodDecl* opMethod = nullptr;  // operador sobrecargado
    bool negate = false;             // '!=' derivado de 'operator=='
    explicit BinaryExpr(SourceLoc l) : Expr(EK::Binary, l) {}
};

struct AssignExpr : Expr {
    std::string op;  // "=", "+=", ...
    Expr* lhs = nullptr;
    Expr* rhs = nullptr;
    MethodDecl* opMethod = nullptr;  // a += b con operator+
    MethodDecl* setter = nullptr;    // obj.Propiedad = valor
    explicit AssignExpr(SourceLoc l) : Expr(EK::Assign, l) {}
};

struct CondExpr : Expr {
    Expr* cond = nullptr;
    Expr* a = nullptr;
    Expr* b = nullptr;
    explicit CondExpr(SourceLoc l) : Expr(EK::Cond, l) {}
};

struct CastExpr : Expr {
    TypeRef* tref = nullptr;  // nulo en conversiones implícitas insertadas por Sema
    Expr* operand = nullptr;
    bool implicit = false;
    explicit CastExpr(SourceLoc l) : Expr(EK::Cast, l) {}
};

struct NewExpr : Expr {  // new T(args)
    TypeRef* tref = nullptr;
    std::vector<Expr*> args;
    MethodDecl* ctor = nullptr;
    explicit NewExpr(SourceLoc l) : Expr(EK::New, l) {}
};

struct NewArrayExpr : Expr {  // new T[n]  ->  T*
    TypeRef* elemRef = nullptr;
    Expr* count = nullptr;
    explicit NewArrayExpr(SourceLoc l) : Expr(EK::NewArray, l) {}
};

struct SizeOfExpr : Expr {
    TypeRef* tref = nullptr;
    Type* target = nullptr;
    explicit SizeOfExpr(SourceLoc l) : Expr(EK::SizeOf, l) {}
};

struct DefaultExpr : Expr {  // default(T): valor cero del tipo
    TypeRef* tref = nullptr;
    explicit DefaultExpr(SourceLoc l) : Expr(EK::Default, l) {}
};

struct BlockStmt;
struct ReturnStmt;

// Expresión lambda: x => x * 2, (a, b) => a + b, (int x) => { ... }, () => 0.
// No tiene tipo propio: lo recibe del delegado de destino (ver Lambdas.cpp).
struct LambdaExpr : Expr {
    struct LParam {
        SourceLoc loc;
        std::string name;
        TypeRef* tref = nullptr;  // nulo si el tipo se infiere del delegado
        VarInfo* var = nullptr;
    };
    std::vector<LParam> params;
    Expr* exprBody = nullptr;        // x => expr
    BlockStmt* blockBody = nullptr;  // x => { ... }
    TokenList tokens;                // para volver a analizarla con otros tipos de parámetros
    size_t tokBegin = 0;
    FileScope* file = nullptr;

    // Semántica
    bool bound = false;
    std::vector<Type*> paramTypes;
    Type* ret = nullptr;              // nulo mientras se infiere el tipo de retorno
    MethodDecl* fn = nullptr;         // función sintética (contexto: retorno, genéricos, memory_unsafe)
    ClassDecl* ownerClass = nullptr;
    int depth = 0;                    // nivel de anidamiento de su cuerpo (1 = lambda dentro de un método)
    std::vector<VarInfo*> captures;   // variables externas que usa (también desde lambdas anidadas)
    bool usesThis = false;
    bool trial = false;               // copia de prueba (inferencia/sobrecargas): no se emite
    int trialErrors = 0;
    int retCost = 0;                  // coste de convertir lo que devuelve al retorno del delegado
    std::vector<ReturnStmt*> returns;
    std::map<std::string, LambdaExpr*> trials;  // copias de prueba por tipos de parámetros
    int id = -1;                      // índice en Sema::lambdas (se emite como fs_lamN)
    explicit LambdaExpr(SourceLoc l) : Expr(EK::Lambda, l) {}
};

// Conversión de un grupo de métodos a delegado: Func<int, int> f = Doble;  obj.Metodo
struct DelegateConvExpr : Expr {
    MethodDecl* target = nullptr;
    Expr* receiver = nullptr;  // instancia explícita (nulo: método estático o 'this' implícito)
    bool receiverArrow = false;
    bool implicitThis = false;
    int thunk = -1;            // índice en Sema::thunks
    explicit DelegateConvExpr(SourceLoc l) : Expr(EK::DelegateConv, l) {}
};

// ---------------------------------------------------------------- sentencias

enum class SK { Block, VarDecl, ExprStmt, If, While, DoWhile, For, Break, Continue, Return, Switch, Delete, Empty };

struct Stmt {
    SK kind;
    SourceLoc loc;
    Stmt(SK k, SourceLoc l) : kind(k), loc(l) {}
    virtual ~Stmt() = default;
};

struct BlockStmt : Stmt {
    std::vector<Stmt*> stmts;
    bool memoryUnsafe = false;  // memory_unsafe { ... }
    explicit BlockStmt(SourceLoc l) : Stmt(SK::Block, l) {}
};

struct VarDeclStmt : Stmt {
    struct Declarator {
        SourceLoc loc;
        std::string name;
        Expr* init = nullptr;
        VarInfo* var = nullptr;
    };
    TypeRef* tref = nullptr;
    bool isConst = false;
    std::vector<Declarator> decls;
    explicit VarDeclStmt(SourceLoc l) : Stmt(SK::VarDecl, l) {}
};

struct ExprStmt : Stmt {
    Expr* expr = nullptr;
    explicit ExprStmt(SourceLoc l) : Stmt(SK::ExprStmt, l) {}
};

struct IfStmt : Stmt {
    Expr* cond = nullptr;
    Stmt* then = nullptr;
    Stmt* els = nullptr;
    explicit IfStmt(SourceLoc l) : Stmt(SK::If, l) {}
};

struct WhileStmt : Stmt {
    Expr* cond = nullptr;
    Stmt* body = nullptr;
    explicit WhileStmt(SourceLoc l) : Stmt(SK::While, l) {}
};

struct DoWhileStmt : Stmt {
    Stmt* body = nullptr;
    Expr* cond = nullptr;
    explicit DoWhileStmt(SourceLoc l) : Stmt(SK::DoWhile, l) {}
};

struct ForStmt : Stmt {
    VarDeclStmt* initDecl = nullptr;
    std::vector<Expr*> initExprs;
    Expr* cond = nullptr;
    std::vector<Expr*> iter;
    Stmt* body = nullptr;
    explicit ForStmt(SourceLoc l) : Stmt(SK::For, l) {}
};

struct BreakStmt : Stmt {
    explicit BreakStmt(SourceLoc l) : Stmt(SK::Break, l) {}
};
struct ContinueStmt : Stmt {
    explicit ContinueStmt(SourceLoc l) : Stmt(SK::Continue, l) {}
};
struct EmptyStmt : Stmt {
    explicit EmptyStmt(SourceLoc l) : Stmt(SK::Empty, l) {}
};

struct ReturnStmt : Stmt {
    Expr* value = nullptr;
    explicit ReturnStmt(SourceLoc l) : Stmt(SK::Return, l) {}
};

struct SwitchStmt : Stmt {
    struct Section {
        std::vector<Expr*> labels;
        std::vector<int64_t> values;
        bool hasDefault = false;
        std::vector<Stmt*> body;
    };
    Expr* subject = nullptr;
    std::vector<Section> sections;
    explicit SwitchStmt(SourceLoc l) : Stmt(SK::Switch, l) {}
};

struct DeleteStmt : Stmt {
    Expr* expr = nullptr;
    bool isArray = false;
    explicit DeleteStmt(SourceLoc l) : Stmt(SK::Delete, l) {}
};

// ---------------------------------------------------------------- declaraciones

struct Param {
    SourceLoc loc;
    TypeRef* tref = nullptr;
    std::string name;
    bool isThis = false;  // primer parámetro de un método de extensión
    Type* type = nullptr;
    VarInfo* var = nullptr;
    bool isRef() const { return tref && tref->isRef; }
};

struct FieldDecl {
    SourceLoc loc;
    FileScope* file = nullptr;  // archivo de origen si viene de otra parte de una clase 'partial'
    Modifiers mods;
    std::vector<Attribute> attrs;
    TypeRef* tref = nullptr;
    std::string name;
    Expr* init = nullptr;
    ClassDecl* owner = nullptr;
    Type* type = nullptr;
    std::string cname;
    bool unsafeCtx = false;  // su tipo e inicializador están en un contexto memory_unsafe
    bool isEvent = false;    // 'event': fuera de su clase solo admite += y -=
    bool isStatic() const { return mods.isStatic || mods.isConst; }
};

enum class MethodKind { Normal, Ctor, Dtor, Getter, Setter, Operator };

struct MethodDecl {
    SourceLoc loc;
    FileScope* file = nullptr;  // archivo de origen si viene de otra parte de una clase 'partial'
    Modifiers mods;
    std::vector<Attribute> attrs;
    MethodKind kind = MethodKind::Normal;
    TypeRef* retRef = nullptr;
    std::string name;  // los operadores se llaman "operator+", "operator[]", ...
    std::vector<Param> params;
    bool variadic = false;  // solo métodos extern: f(int a, ...)
    BlockStmt* body = nullptr;
    ClassDecl* owner = nullptr;
    Type* ret = nullptr;
    std::string cname;

    // Seguridad de memoria:
    //   unsafeBody: el cuerpo y la firma son un contexto memory_unsafe (método, clase,
    //               namespace o archivo marcados).
    //   unsafeApi:  el propio método está marcado 'memory_unsafe': solo se puede llamar
    //               desde un contexto memory_unsafe (como 'unsafe fn' en Rust).
    //   trackCaller: [TrackCaller]: recibe la ubicación de quien lo llama (para panic).
    bool unsafeBody = false, unsafeApi = false, trackCaller = false;

    // Plantillas (genéricos): se vuelven a analizar desde los tokens por cada instancia.
    std::vector<std::string> typeParams;
    MethodDecl* templateOf = nullptr;
    std::map<std::string, Type*> typeArgMap;
    std::map<std::string, MethodDecl*> instances;
    TokenList tokens;
    size_t tokBegin = 0;

    bool signatureDone = false;
    bool queued = false;   // cuerpo pendiente o ya comprobado
    bool checked = false;  // cuerpo comprobado: se emite en C
    bool hasUsedAt = false;
    SourceLoc usedAt;      // primer uso (para notas de error en plantillas)
    MethodDecl* usedBy = nullptr;

    bool isStatic() const { return mods.isStatic; }
    bool isTemplate() const { return !typeParams.empty() && !templateOf; }
    bool retIsRef() const { return retRef && retRef->isRef; }
    bool isExtension() const { return !params.empty() && params[0].isThis; }
};

struct EnumMember {
    SourceLoc loc;
    std::string name;
    Expr* value = nullptr;
    int64_t val = 0;
};

enum class ClassKind { Class, Struct, Enum };

struct ClassDecl {
    SourceLoc loc;
    ClassKind kind = ClassKind::Class;
    Modifiers mods;
    std::vector<Attribute> attrs;
    std::string name, displayName, ns;
    std::vector<FieldDecl*> fields;
    std::vector<MethodDecl*> methods;
    std::vector<MethodDecl*> ctors;
    MethodDecl* dtor = nullptr;
    std::vector<EnumMember> enumMembers;
    Type* type = nullptr;
    std::string cname;
    FileScope* file = nullptr;
    NamespaceSym* nsSym = nullptr;
    bool isNamespaceScope = false;  // contenedor oculto de funciones/variables globales
    bool unsafeCtx = false;         // 'memory_unsafe class': implementación confiable

    // Plantillas (genéricos)
    std::vector<std::string> typeParams;
    ClassDecl* templateOf = nullptr;
    std::vector<Type*> typeArgs;
    std::map<std::string, Type*> typeArgMap;
    std::map<std::string, ClassDecl*> instances;
    TokenList tokens;
    size_t tokBegin = 0;
    bool signaturesDone = false;

    bool isStaticClass() const { return mods.isStatic; }
    bool isTemplate() const { return !typeParams.empty() && !templateOf; }
    // ¿Necesita una definición de struct en C? (clases no estáticas y structs)
    bool hasLayout() const { return kind != ClassKind::Enum && !mods.isStatic && !isTemplate(); }
};

struct Program {
    std::vector<ClassDecl*> types;
    std::vector<FileScope*> files;
    // Módulos pedidos por 'using'/'import' y rutas cualificadas (los carga el driver).
    std::set<std::string> requestedModules;
    // Archivos pedidos por import "ruta.fst" (rutas ya resueltas).
    std::vector<std::string> requestedFiles;
    // Tipos delegado declarados: delegate int Comparador(string a, string b);
    // (la firma se guarda como un MethodDecl; 'owner' da el namespace y el archivo)
    std::vector<MethodDecl*> delegates;
};
