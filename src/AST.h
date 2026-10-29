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
    // Azúcar (Sugar.cpp): (int, string) / (int x, int y) usan typeArgs como elementos;
    // T? es un tipo que admite null (Nullable<T> para los tipos por valor).
    bool isTuple = false;
    std::vector<std::string> tupleNames;
    bool nullable = false;
    bool isVar() const {
        return parts.size() == 1 && (parts[0] == "var" || parts[0] == "auto") && ptrDepth == 0 && typeArgs.empty() &&
               !isFuncPtr;
    }
    std::string str() const {
        std::string s;
        if (isFuncPtr) s = "delegate*";
        if (isTuple) {
            s = "(";
            for (size_t i = 0; i < typeArgs.size(); i++)
                s += (i ? ", " : "") + typeArgs[i]->str() +
                     (i < tupleNames.size() && !tupleNames[i].empty() ? " " + tupleNames[i] : "");
            return s + ")" + (nullable ? "?" : "");
        }
        for (size_t i = 0; i < parts.size(); i++) s += (i ? "." : "") + parts[i];
        if (!typeArgs.empty()) {
            s += "<";
            for (size_t i = 0; i < typeArgs.size(); i++) s += (i ? ", " : "") + typeArgs[i]->str();
            s += ">";
        }
        return s + (nullable ? "?" : "") + std::string(ptrDepth, '*') + (isRef ? "&" : "");
    }
};

enum class Access { Private, Public, Internal, Protected };

struct Modifiers {
    Access access = Access::Private;
    bool hasAccess = false;
    bool isStatic = false, isExtern = false, isConst = false, isReadonly = false, isPartial = false;
    bool isMemoryUnsafe = false;  // modificador 'memory_unsafe'
    bool isEvent = false;         // modificador contextual 'event' (campos de tipo delegado)
    // Herencia: virtual / override / abstract / sealed / new (ocultar un miembro heredado).
    bool isVirtual = false, isOverride = false, isAbstract = false, isSealed = false, isNew = false;
    bool isAsync = false;  // modificador contextual 'async' (ver Async.cpp)
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
    // Excepciones: 'try' abiertos al declararla y si debe ser 'volatile' en C (se modifica dentro
    // de un 'try' declarado fuera de él: tras un longjmp su valor debe seguir en memoria).
    int excDepth = 0;
    bool isVolatile = false;
    bool hoisted = false;  // temporal de Sugar.cpp: se declara al principio de la función en C
    // Se tomó su dirección (&x, ref x, T& r = x): una llamada puede modificarla (EvalOrder.cpp).
    bool addrTaken = false;
};

// ---------------------------------------------------------------- expresiones

enum class EK {
    IntLit, FloatLit, BoolLit, CharLit, StringLit, Null, Name, Member, Call, Index, Unary, Postfix,
    Binary, Assign, Cond, Cast, New, NewArray, SizeOf, This, Default,
    Lambda, DelegateConv,
    // Azúcar sintáctico (Sugar.cpp / SugarGen.cpp)
    Interp, CondAccess, CondRecv, Tuple, Let, SwitchExpr, IsPattern, ParamsList, MatchFail, CoalesceAssign,
    Is, As, TypeOf, NameOf, With,  // orientación a objetos (ver SemaClasses.cpp)
    Await                          // async/await (ver Async.cpp)
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
    // Forma reescrita por Sema (Sugar.cpp): si existe, CodeGen emite esta en su lugar.
    Expr* lowered = nullptr;
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
    enum class Ref { None, Local, Field, StaticField, Property, Base } ref = Ref::None;  // Base: 'base'
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
    bool nonVirtual = false;         // base.Propiedad: sin despacho virtual
    explicit MemberExpr(SourceLoc l) : Expr(EK::Member, l) {}
};

struct CallExpr : Expr {
    Expr* callee = nullptr;
    std::vector<Expr*> args;
    MethodDecl* target = nullptr;    // nulo si se llama a través de un puntero a función
    Expr* receiver = nullptr;        // para métodos de instancia con receptor explícito
    bool receiverArrow = false;
    bool implicitThis = false;
    bool nonVirtual = false;         // base.Metodo(): llamada directa, sin despacho virtual
    int intrinsic = 0;               // 1: ToString() de un enum
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
    bool checkedDown = false;  // (Derivada)base o conversión a/desde interfaz: se comprueba al ejecutar
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
    bool isAsync = false;             // async () => ... (ver Async.cpp)
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

// x is T / x is T nombre / x is null / x is not null
struct IsExpr : Expr {
    Expr* operand = nullptr;
    TypeRef* tref = nullptr;   // nulo en 'is null'
    bool negate = false;       // 'is not ...'
    std::string varName;       // patrón con variable: 'x is Perro p'
    SourceLoc varLoc;
    VarInfo* var = nullptr;
    Type* target = nullptr;
    bool always = false;       // el tipo estático ya es T: solo se comprueba que no sea null
    Type* preset = nullptr;    // tipo ya resuelto (patrones de tipo de Sugar.cpp: 'case Perro p:')
    explicit IsExpr(SourceLoc l) : Expr(EK::Is, l) {}
};

struct AsExpr : Expr {  // x as T: null si x no es un T
    Expr* operand = nullptr;
    TypeRef* tref = nullptr;
    bool always = false;
    Type* preset = nullptr;    // tipo ya resuelto (patrones de tipo de Sugar.cpp)
    explicit AsExpr(SourceLoc l) : Expr(EK::As, l) {}
};

struct TypeOfExpr : Expr {  // typeof(T) -> Type
    TypeRef* tref = nullptr;
    Type* target = nullptr;
    explicit TypeOfExpr(SourceLoc l) : Expr(EK::TypeOf, l) {}
};

struct NameOfExpr : Expr {  // nameof(x) -> "x"
    Expr* operand = nullptr;
    std::string value;
    explicit NameOfExpr(SourceLoc l) : Expr(EK::NameOf, l) {}
};

struct WithExpr : Expr {  // registro with { X = 1, Y = 2 }
    struct Init {
        SourceLoc loc;
        std::string name;
        Expr* value = nullptr;
        FieldDecl* field = nullptr;  // campo de respaldo de la propiedad
    };
    Expr* operand = nullptr;
    std::vector<Init> inits;
    int id = -1;  // índice en Sema::withExprs (función auxiliar en C)
    explicit WithExpr(SourceLoc l) : Expr(EK::With, l) {}
};

// ---------------------------------------------------------------- sentencias

enum class SK { Block, VarDecl, ExprStmt, If, While, DoWhile, For, Break, Continue, Return, Switch, Delete, Empty, Try, Throw,
    Foreach, Deconstruct, Using,
    Await };  // punto de espera de un método async (lo genera Async.cpp)

struct Stmt {
    SK kind;
    SourceLoc loc;
    Stmt* lowered = nullptr;  // forma reescrita por Sema (Sugar.cpp)
    Stmt(SK k, SourceLoc l) : kind(k), loc(l) {}
    virtual ~Stmt() = default;
};

struct BlockStmt : Stmt {
    std::vector<Stmt*> stmts;
    bool memoryUnsafe = false;  // memory_unsafe { ... }
    bool noScope = false;       // generado: sus declaraciones quedan en el ámbito de fuera
    SourceLoc endLoc{-1, 0, 0};  // la '}' de cierre (para la información de depuración)
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
    bool fromExprBody = false;  // cuerpo de expresión de una lambda async (async () => expr)
    explicit ReturnStmt(SourceLoc l) : Stmt(SK::Return, l) {}
};

struct Pattern;
struct SwitchStmt : Stmt {
    struct Section {
        std::vector<Expr*> labels;
        std::vector<int64_t> values;
        bool hasDefault = false;
        std::vector<Stmt*> body;
        // Patrones (Sugar.cpp): uno por 'case', con su guarda 'when' opcional. Los 'case' de
        // constante simple también están en 'labels'.
        std::vector<Pattern*> patterns;
        std::vector<Expr*> guards;
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

// ---------------------------------------------------------------- excepciones (ver Exceptions.cpp)

// try { } catch (T e) when (cond) { } catch { } finally { }
struct TryStmt : Stmt {
    struct Catch {
        SourceLoc loc;
        TypeRef* tref = nullptr;  // nulo: 'catch { }' (atrapa cualquier excepción)
        std::string name;         // vacío: 'catch (T) { }'
        SourceLoc nameLoc;
        Expr* filter = nullptr;   // when (cond)
        BlockStmt* body = nullptr;
        Type* type = nullptr;     // tipo atrapado (clase de excepción)
        VarInfo* var = nullptr;
    };
    BlockStmt* body = nullptr;
    std::vector<Catch> catches;
    BlockStmt* finallyBody = nullptr;
    explicit TryStmt(SourceLoc l) : Stmt(SK::Try, l) {}
};

// throw expr;  /  throw;  (relanza la excepción de la cláusula 'catch' actual)
struct ThrowStmt : Stmt {
    Expr* value = nullptr;
    explicit ThrowStmt(SourceLoc l) : Stmt(SK::Throw, l) {}
};

// ---------------------------------------------------------------- declaraciones

struct Param {
    SourceLoc loc;
    TypeRef* tref = nullptr;
    std::string name;
    bool isThis = false;  // primer parámetro de un método de extensión
    bool isParams = false;  // 'params List<T> xs' (o 'params T[] xs'): último parámetro
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

// Restricción genérica: where T : class, struct, new(), Base, IComparable<T>
struct TypeConstraint {
    SourceLoc loc;
    std::string param;
    bool isClass = false, isStruct = false, isNew = false;
    std::vector<TypeRef*> types;
};

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

    // Orientación a objetos (ver SemaClasses.cpp / CodeGenClasses.cpp)
    std::vector<TypeConstraint> constraints;
    int vslot = -1;                    // entrada en la vtable (métodos virtuales y override)
    MethodDecl* vroot = nullptr;       // método que introdujo la entrada (virtual/abstract)
    MethodDecl* overridden = nullptr;  // miembro de la base que reemplaza
    bool objSelf = false;              // en C recibe 'fs_std_Object*' (virtual o implementa una interfaz)
    int ctorInit = 0;                  // constructor: 1 = ': base(...)', 2 = ': this(...)'
    std::vector<Expr*> ctorInitArgs;
    SourceLoc ctorInitLoc;
    MethodDecl* ctorInitTarget = nullptr;
    int recordGen = 0;                 // miembro generado por 'record' (1 ToString, 2 GetHashCode, 3 ==)
    std::vector<VarInfo*> patternVars; // variables de patrones 'is T x' (se declaran al inicio en C)
    struct AsyncInfo* async = nullptr; // método o lambda 'async': máquina de estados (ver Async.cpp)
    bool isVirtualish() const { return mods.isVirtual || mods.isOverride || mods.isAbstract; }

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

enum class ClassKind { Class, Struct, Enum, Interface };

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
    bool isTuple = false;           // struct anónimo de una tupla (Sugar.cpp): Item1..ItemN
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

    // Orientación a objetos (ver SemaClasses.cpp)
    std::vector<TypeRef*> baseRefs;        // ': Base, I1, I2'
    std::vector<TypeConstraint> constraints;
    ClassDecl* base = nullptr;             // clase base (std.Object si no se indica)
    std::vector<ClassDecl*> interfaces;    // interfaces declaradas
    std::vector<ClassDecl*> allInterfaces; // todas (heredadas incluidas), sin repetir
    std::vector<MethodDecl*> vtable;       // implementación final de cada entrada
    std::vector<std::vector<MethodDecl*>> itabs;  // por cada allInterfaces: implementación de cada método
    int hierarchyState = 0;                // 0 sin resolver, 1 resolviendo, 2 lista
    bool isRecord = false;
    // Mismo nombre con y sin parámetros de tipo en un namespace (Task y Task<T>): el otro.
    ClassDecl* arityTwin = nullptr;
    bool isInterface() const { return kind == ClassKind::Interface; }

    bool isStaticClass() const { return mods.isStatic; }
    bool isTemplate() const { return !typeParams.empty() && !templateOf; }
    // ¿Necesita una definición de struct en C? (clases no estáticas y structs)
    bool hasLayout() const {
        return kind != ClassKind::Enum && kind != ClassKind::Interface && !mods.isStatic && !isTemplate();
    }
};

// ---------------------------------------------------------------- azúcar sintáctico (Sugar.cpp)

// $"Hola {nombre,10:F2}": texto literal y huecos con alineación y formato opcionales.
struct InterpExpr : Expr {
    struct Part {
        std::string text;
        Expr* expr = nullptr;  // nulo: texto literal
        bool hasAlign = false;
        int align = 0;
        std::string format;
        MethodDecl* toString = nullptr;  // ToString() del usuario
    };
    std::vector<Part> parts;
    explicit InterpExpr(SourceLoc l) : Expr(EK::Interp, l) {}
};

// obj?.resto  /  obj?[i]: 'access' es la cadena de miembros aplicada a un CondRecvExpr.
struct CondAccessExpr : Expr {
    Expr* obj = nullptr;
    Expr* access = nullptr;
    Type* recvType = nullptr;  // tipo del receptor (T si obj es T?)
    VarInfo* tmp = nullptr;
    bool objNullable = false;  // obj es Nullable<T>
    explicit CondAccessExpr(SourceLoc l) : Expr(EK::CondAccess, l) {}
};
struct CondRecvExpr : Expr {
    CondAccessExpr* owner = nullptr;
    explicit CondRecvExpr(SourceLoc l) : Expr(EK::CondRecv, l) {}
};

// (1, "a")  /  (x: 1, y: 2)
struct TupleExpr : Expr {
    std::vector<Expr*> elems;
    std::vector<std::string> names;  // "" si el elemento no tiene nombre
    explicit TupleExpr(SourceLoc l) : Expr(EK::Tuple, l) {}
};

// (t1 = e1, t2 = e2, seq...): temporales con nombre oculto (generado por Sema).
struct LetExpr : Expr {
    std::vector<std::pair<VarInfo*, Expr*>> binds;
    std::vector<Expr*> seq;
    explicit LetExpr(SourceLoc l) : Expr(EK::Let, l) {}
};

enum class PK { Constant, Relational, And, Or, Not, Discard, Var, Property, Positional, Type };

// Patrones de 'switch', 'case' e 'is'.
struct Pattern {
    PK kind;
    SourceLoc loc;
    Expr* value = nullptr;      // Constant / Relational
    std::string op;             // Relational: < > <= >= (y == !=)
    Pattern* a = nullptr;       // And / Or / Not
    Pattern* b = nullptr;
    std::string name;           // Var: 'var x'; Type: designación opcional 'Perro p'
    SourceLoc nameLoc;
    TypeRef* tref = nullptr;    // Type (y Property con tipo: Perro { Edad: > 3 })
    std::vector<std::pair<std::string, Pattern*>> props;  // Property: { Edad: > 18 }
    std::vector<SourceLoc> propLocs;
    std::vector<Pattern*> elems;  // Positional: (0, _)
    Pattern(PK k, SourceLoc l) : kind(k), loc(l) {}
};

// x switch { 1 => "uno", > 5 => "muchos", _ => "otro" }
struct SwitchExpr : Expr {
    struct Arm {
        SourceLoc loc;
        Pattern* pat = nullptr;
        Expr* guard = nullptr;
        Expr* value = nullptr;
    };
    Expr* subject = nullptr;
    std::vector<Arm> arms;
    explicit SwitchExpr(SourceLoc l) : Expr(EK::SwitchExpr, l) {}
};

// x is > 0 and < 10
struct IsPatternExpr : Expr {
    Expr* subject = nullptr;
    Pattern* pat = nullptr;
    explicit IsPatternExpr(SourceLoc l) : Expr(EK::IsPattern, l) {}
};

// Argumentos de un parámetro 'params': se empaquetan en una List<T> nueva.
struct ParamsListExpr : Expr {
    std::vector<Expr*> items;
    MethodDecl* ctor = nullptr;  // List<T>(int capacidad)
    size_t ctorIndex = 0;
    MethodDecl* add = nullptr;   // List<T>.Add
    explicit ParamsListExpr(SourceLoc l) : Expr(EK::ParamsList, l) {}
};

// Ningún brazo de un 'switch' de expresión coincidió: panic en tiempo de ejecución.
struct MatchFailExpr : Expr {
    Expr* value = nullptr;  // valor que no coincidió (para el mensaje), si se puede mostrar
    explicit MatchFailExpr(SourceLoc l) : Expr(EK::MatchFail, l) {}
};

// a ??= b (lhs es un lvalue; se evalúa una sola vez)
struct CoalesceAssignExpr : Expr {
    Expr* lhs = nullptr;
    Expr* rhs = nullptr;
    bool nullableLhs = false;
    explicit CoalesceAssignExpr(SourceLoc l) : Expr(EK::CoalesceAssign, l) {}
};

// foreach (var x in c) / foreach (int x in c) / foreach (var (k, v) in dic)
struct ForeachStmt : Stmt {
    TypeRef* tref = nullptr;            // tipo del elemento (o 'var')
    std::string name;                   // vacío si se deconstruye
    SourceLoc nameLoc;
    std::vector<std::string> names;     // foreach (var (a, b) in ...)
    std::vector<TypeRef*> types;        // tipo de cada nombre (nulo = var)
    std::vector<SourceLoc> nameLocs;
    Expr* coll = nullptr;
    Stmt* body = nullptr;
    explicit ForeachStmt(SourceLoc l) : Stmt(SK::Foreach, l) {}
};

// var (a, b) = expr;   (int a, string b) = expr;
struct DeconstructStmt : Stmt {
    std::vector<std::string> names;  // "_" descarta
    std::vector<TypeRef*> types;     // nulo = var
    std::vector<SourceLoc> locs;
    Expr* init = nullptr;
    explicit DeconstructStmt(SourceLoc l) : Stmt(SK::Deconstruct, l) {}
};

// using var x = expr;  /  using (var x = expr) cuerpo  /  using (expr) cuerpo
struct UsingStmt : Stmt {
    VarDeclStmt* decl = nullptr;  // declaración (o nulo si es una expresión)
    Expr* expr = nullptr;
    Stmt* body = nullptr;         // nulo en 'using var' (llega hasta el final del bloque)
    std::vector<VarInfo*> vars;   // objetos a liberar (destructor) al salir
    explicit UsingStmt(SourceLoc l) : Stmt(SK::Using, l) {}
};

// ---------------------------------------------------------------- async / await (ver Async.cpp)

// await operando. Sema lo comprueba con el patrón de C#: operando.GetAwaiter(), y sobre el
// 'awaiter' IsCompleted, OnCompleted(Action) y GetResult(). Después lo saca de la expresión a una
// sentencia AwaitStmt propia (los temporales de la izquierda se evalúan antes, en orden).
struct AwaitExpr : Expr {
    Expr* operand = nullptr;
    VarInfo* opVar = nullptr;       // <op> = operando
    VarInfo* awVar = nullptr;       // <aw> = <op>.GetAwaiter()
    Expr* getAwaiter = nullptr;     // comprobadas, sobre las variables ocultas
    Expr* isCompleted = nullptr;
    Expr* onCompleted = nullptr;    // <aw>.OnCompleted(<continuación>)
    Expr* getResult = nullptr;
    bool spilled = false;           // ya se convirtió en un AwaitStmt
    explicit AwaitExpr(SourceLoc l) : Expr(EK::Await, l) {}
};

// Punto de suspensión: evalúa el operando, y si no ha terminado guarda el estado, registra la
// continuación y vuelve; al reanudar sigue aquí. 'result' recibe GetResult() (nulo si es void).
struct AwaitStmt : Stmt {
    AwaitExpr* aw = nullptr;
    VarInfo* result = nullptr;
    explicit AwaitStmt(SourceLoc l) : Stmt(SK::Await, l) {}
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
