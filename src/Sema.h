// Faset - análisis semántico: namespaces, resolución de nombres, comprobación de tipos,
// sobrecargas, plantillas (instanciadas por tipo), operadores y conversiones.
#pragma once
#include <functional>
#include <map>
#include <set>

#include "AST.h"
#include "Sugar.h"

struct NamespaceSym {
    std::string name;  // nombre completo con puntos; "" = global
    NamespaceSym* parent = nullptr;
    std::map<std::string, NamespaceSym*> children;
    std::map<std::string, ClassDecl*> types;  // incluye plantillas
    std::map<std::string, std::vector<MethodDecl*>> funcs;
    std::map<std::string, FieldDecl*> globals;
    std::map<std::string, MethodDecl*> delegates;  // delegate int Comparador(string a, string b);
    std::string display() const { return name.empty() ? "<global>" : name; }
};

// Resultado de buscar un nombre en un namespace o en el ámbito actual.
struct Sym {
    enum Kind { None, Ns, TypeK, Funcs, Global } kind = None;
    NamespaceSym* ns = nullptr;
    ClassDecl* decl = nullptr;  // tipo declarado (puede ser plantilla)
    Type* type = nullptr;       // tipo ya resuelto (alias a int, List<int>, ...)
    std::vector<MethodDecl*> funcs;
    FieldDecl* global = nullptr;
    MethodDecl* dlg = nullptr;  // TypeK: tipo delegado declarado
};

class Sema {
public:
    Sema(Program& prog, TypeCtx& tc) : prog_(prog), tc_(tc) {}
    bool run();

    MethodDecl* entry = nullptr;               // Main / main
    std::vector<FieldDecl*> staticInits;       // campos estáticos/globales con inicializador, en orden
    std::vector<ClassDecl*> structOrder;       // tipos con layout, en orden de dependencia
    std::vector<MethodDecl*> genericMethods;   // instancias de métodos genéricos

    bool constEval(Expr* e, int64_t& out, int depth = 0);

    // ---- soporte para el servidor de lenguaje (IntelliSense)
    struct SymbolRef {  // un nombre en el código: para hover e "ir a la definición"
        SourceLoc loc;
        int length;
        std::string hover;
        SourceLoc def;
        bool hasDef;
    };
    struct Completion {
        std::string label;
        int kind;  // CompletionItemKind de LSP
        std::string detail;
    };
    bool ideMode = false;
    std::vector<SymbolRef> refs;
    std::vector<Completion> completions;
    bool completionRequested = false;
    NamespaceSym* globalNs() const { return global_; }
    NamespaceSym* namespaceByPath(const std::vector<std::string>& path) { return findNs(path); }
    void completeNamespaceMembers(NamespaceSym* ns, bool children);
    static std::string methodSignature(MethodDecl* m);
    static std::string typeDescription(ClassDecl* c);

    // ---- lambdas, cierres y delegados (Lambdas.cpp)
    std::vector<LambdaExpr*> lambdas;  // lambdas comprobadas que se emiten (fs_lamN)
    struct Thunk {                     // adaptador grupo de métodos -> delegado (fs_thkN)
        MethodDecl* target;
        Type* dlg;
        bool instance;
    };
    std::vector<Thunk> thunks;
    // ---- excepciones (Exceptions.cpp)
    ClassDecl* exceptionClass = nullptr;           // std.Exception: la raíz de las excepciones
    std::vector<ClassDecl*> exceptionTypes;        // clases de excepción (con descriptor en C), bases primero
    std::map<const Stmt*, int> excJumpCross;       // break/continue: zonas 'try' que atraviesa
    std::set<MethodDecl*> excMethods;              // métodos con algún 'try'
    // Gancho de la jerarquía de excepciones: la clase base de una excepción (nullptr en la raíz).
    // Hoy sale del atributo [ExceptionBase("Base")]; con herencia real será la clase base declarada.
    ClassDecl* exceptionBase(ClassDecl* c) const;
    bool isExceptionClass(ClassDecl* c) const;
    bool excIsSubclass(ClassDecl* derived, ClassDecl* base) const;  // derived == base o deriva de ella
    // ---- orientación a objetos (SemaClasses.cpp)
    ClassDecl* objectDecl = nullptr;           // std.Object: base universal ('object')
    ClassDecl* typeDecl = nullptr;             // std.Type: resultado de typeof(T) y GetType()
    MethodDecl* enumToString = nullptr;        // ToString() de los enums (intrínseco)
    std::vector<WithExpr*> withExprs;          // expresiones 'with' (función auxiliar en C)
    std::vector<Type*> typeofTypes;            // typeof(T) con T que no es clase, interfaz ni enum
    static bool derivesFrom(ClassDecl* c, ClassDecl* target);  // c es target, deriva o lo implementa
    static MethodDecl* paramlessCtor(ClassDecl* c);
    MethodDecl* typeFromHandle() const;

private:
    struct Ctx {
        FileScope* file = nullptr;
        NamespaceSym* ns = nullptr;
        ClassDecl* cls = nullptr;
        MethodDecl* method = nullptr;
        bool isStatic = true;
        FieldDecl* field = nullptr;  // campo cuyo tipo o inicializador se comprueba
        std::vector<std::map<std::string, VarInfo*>> scopes;
        int loopDepth = 0, switchDepth = 0;
        int unsafeDepth = 0;  // bloques 'memory_unsafe { }' abiertos
        // Excepciones: zonas protegidas por un marco de 'try' (o cuerpos de 'finally', de los que no
        // se puede salir con break/continue/return), con la profundidad de bucles/switch al entrar.
        struct ExcRegion { bool finallyBody; int loops, breaks; };
        std::vector<ExcRegion> excRegions;
        std::vector<char> excHandlers;  // 'C' dentro de un catch, 'F' dentro de un finally ('throw;')
        int excTryDepth = 0;            // sentencias 'try' abiertas (para las variables 'volatile')
    };
    struct CtxSave {
        Sema& s;
        Ctx saved;
        explicit CtxSave(Sema& se) : s(se), saved(se.ctx_) {}
        ~CtxSave() { s.ctx_ = std::move(saved); }
    };

    Program& prog_;
    TypeCtx& tc_;
    Ctx ctx_;
    NamespaceSym* global_ = nullptr;
    std::vector<MethodDecl*> work_;
    std::vector<std::pair<ClassDecl*, FieldDecl*>> fieldWork_;
    int instDepth_ = 0, instCounter_ = 0;

    // namespaces y búsqueda
    NamespaceSym* getNs(const std::string& name, bool create);
    NamespaceSym* findNs(const std::vector<std::string>& path);
    void buildNamespaces();
    void resolveUsings(FileScope* f);
    Sym lookupIn(NamespaceSym* ns, const std::string& name, bool includeChildren = true);
    Sym lookupUnqualified(const std::string& name, SourceLoc loc);
    std::vector<MethodDecl*> findExtensions(const std::string& name);
    void enter(ClassDecl* c, MethodDecl* m);

    // declaraciones
    Type* resolveType(TypeRef* tr, bool allowVoid = false);
    Type* typeFromSym(const Sym& s, TypeRef* tr);
    void resolveClassSignatures(ClassDecl* c);
    void resolveMethodSignature(MethodDecl* m);
    void assignFunctionNames();
    ClassDecl* instantiate(ClassDecl* tmpl, const std::vector<Type*>& args, SourceLoc loc);
    MethodDecl* instantiateMethod(MethodDecl* tmpl, const std::vector<Type*>& args, SourceLoc loc);
    bool inferTypeArgs(MethodDecl* tmpl, const std::vector<Expr*>& args, const std::vector<TypeRef*>& explicitArgs,
                       std::vector<Type*>& out);
    bool unify(TypeRef* p, Type* a, MethodDecl* tmpl, std::map<std::string, Type*>& b);
    void useMethod(MethodDecl* m, const SourceLoc* at = nullptr);
    void orderStructs();
    void processWork();
    void findEntry();

    void checkMethod(MethodDecl* m);
    VarInfo* declareLocal(const std::string& name, Type* t, SourceLoc loc, const std::string& prefix);
    VarInfo* lookupLocal(const std::string& name);

    // sentencias
    void checkStmt(Stmt* s);
    void checkCondition(Expr*& e);
    bool alwaysReturns(Stmt* s);
    bool containsBreak(Stmt* s);
    bool sectionEnds(const std::vector<Stmt*>& body);

    // expresiones
    Type* check(Expr* e);
    Type* checkValue(Expr* e);
    Type* checkInner(Expr* e);
    MethodDecl* FindSetter(MethodDecl* getter);
    void mergePartials();
    Type* checkName(NameExpr* e);
    Type* checkNameImpl(NameExpr* e);
    Type* checkMember(MemberExpr* e);
    Type* checkMemberImpl(MemberExpr* e);
    Type* fromSym(Expr* e, const Sym& s, const std::vector<TypeRef*>& typeArgs);
    Type* checkCall(CallExpr* e);
    Type* checkUnary(UnaryExpr* e);
    Type* checkBinary(BinaryExpr* e);
    std::string localRefRoot(Expr* e);
    Type* checkAssign(AssignExpr* e);
    Type* checkCond(CondExpr* e);
    Type* checkNew(NewExpr* e);
    Type* checkIndex(IndexExpr* e);

    MethodDecl* resolveOverload(const std::vector<MethodDecl*>& cands, std::vector<Expr*>& args, SourceLoc loc,
                                const std::string& what, const std::vector<TypeRef*>& typeArgs = {},
                                bool report = true);
    std::vector<MethodDecl*> operatorsFor(Type* a, Type* b, const std::string& name);
    void coerceArgs(MethodDecl* m, std::vector<Expr*>& args);
    void checkAccess(Access a, ClassDecl* owner, const std::string& what, SourceLoc loc);

    // seguridad de memoria (memory_unsafe)
    std::set<std::pair<int, int>> unsafeReported_;  // (archivo, línea): un error por línea
    bool unsafeCtx() const;
    void unsafeError(SourceLoc loc, const std::string& what);
    void requireSafeCall(MethodDecl* m, SourceLoc loc);
    void pointerExprError(Expr* e);

    // conversiones
    bool implicitNumeric(Type* from, Type* to);
    bool canImplicit(Expr* e, Type* from, Type* to);
    bool canExplicit(Type* from, Type* to);
    int convCost(Expr* e, Type* to);
    void coerce(Expr*& e, Type* to);
    Type* numericPromote(Expr* a, Expr* b);
    Type* unaryPromote(Type* t);
    bool isLValue(Expr* e);
    bool isConstTarget(Expr* e);

    // IntelliSense
    std::set<std::string> completionSeen_;
    void addRef(SourceLoc loc, int length, const std::string& hover, const SourceLoc* def);
    void addCompletion(const std::string& label, int kind, const std::string& detail);
    void completeScope();
    void completeMembers(Expr* obj, bool arrow, Type* ot);
    void completeTypes(const std::vector<std::string>& prefix);

    // lambdas, cierres, delegados y eventos (Lambdas.cpp)
    std::vector<LambdaExpr*> lambdaStack_;  // lambdas cuyo cuerpo se está comprobando
    int trialDepth_ = 0;                    // > 0: comprobando una copia de prueba (sin efectos visibles)
    Expr* eventLhs_ = nullptr;              // lado izquierdo de 'evento += h' / 'evento -= h'
    Expr* calleeExpr_ = nullptr;            // expresión que se está llamando (para Count(...) frente a Count)
    std::map<std::pair<MethodDecl*, Type*>, int> thunkIndex_;
    Type* requireValue(Expr* e);
    Type* checkOperand(Expr* e);  // como checkValue, pero admite lambdas y grupos de métodos
    Type* checkLambdaExpr(Expr* e);
    void registerDelegates();
    Type* delegateFromDecl(MethodDecl* d, TypeRef* tr);
    Type* builtinDelegateType(TypeRef* tr);
    void checkEventField(FieldDecl* f);
    bool eventAccessible(FieldDecl* f, Expr* e);
    void noteLocalUse(VarInfo* v, SourceLoc loc);
    void noteThisUse(SourceLoc loc);
    bool lambdaReturn(ReturnStmt* rs);
    bool bindLambda(LambdaExpr* l, const std::vector<Type*>& params, Type* ret);
    LambdaExpr* lambdaTrial(LambdaExpr* l, const std::vector<Type*>& params, Type* ret);
    Type* lambdaReturnType(LambdaExpr* trial);
    int lambdaCost(LambdaExpr* l, Type* d);
    int groupCost(Expr* e, Type* d);
    MethodDecl* groupMatch(Expr* e, Type* d, bool report);
    int pendingCost(Expr* e, Type* to);
    void convertPending(Expr*& e, Type* to);
    Type* naturalType(Expr*& e);
    void inferFromLambdas(MethodDecl* tmpl, const std::vector<Expr*>& args, std::map<std::string, Type*>& b);
    bool unifyDelegate(TypeRef* p, Type* a, MethodDecl* tmpl, std::map<std::string, Type*>& b);
    Type* checkDelegateCall(CallExpr* e);
    bool delegateAssign(AssignExpr* e, Type* L);
    bool hasCallableNamed(ClassDecl* c, const std::string& name);
    void explainPendingArgs(const std::vector<MethodDecl*>& group, std::vector<Expr*>& args);
    Type* resolveInTemplate(MethodDecl* tmpl, TypeRef* tr, const std::map<std::string, Type*>& b);
    // excepciones (Exceptions.cpp)
    std::map<ClassDecl*, ClassDecl*> excBase_;
    std::set<ClassDecl*> excClasses_;
    void excSetupHierarchy();
    void excAdoptInherited(ClassDecl* c);
    bool excPrepare(ClassDecl* c, std::set<ClassDecl*>& busy);
    void checkTry(TryStmt* t);
    void checkThrow(ThrowStmt* t);
    void excCheckJump(Stmt* s);
    void excNoteWrite(Expr* e);
    bool excAlwaysReturns(TryStmt* t);
    bool excContainsBreak(TryStmt* t);
    Type* primitiveStaticMember(MemberExpr* e, Type* t);  // int.Parse, double.TryParse, char.IsDigit...
    // ---- azúcar sintáctico (Sugar.cpp): foreach, interpolación, ?? ?. , T?, tuplas, patrones,
    // switch de expresión, params, deconstrucción y 'default'. Casi todo se reescribe (campo
    // 'lowered' de Expr/Stmt) en construcciones que CodeGen ya sabe emitir.
    int hiddenCounter_ = 0;
    std::map<std::string, ClassDecl*> tupleDecls_;
    std::map<std::pair<ClassDecl*, std::vector<std::string>>, Type*> tupleNamed_;
    using SubjectFn = std::function<Expr*()>;
    bool isSugarExpr(EK k) const;
    Type* checkSugar(Expr* e);
    bool checkSugarStmt(Stmt* s);
    VarInfo* hiddenLocal(Type* t, SourceLoc loc, bool hoisted);
    VarInfo* patternVar(const std::string& name, Type* t, SourceLoc loc);
    VarDeclStmt* bindDecl(VarInfo* v, Expr* checkedInit);
    void checkHiddenDecl(VarDeclStmt* d);
    Type* resolveSugarType(TypeRef* tr, bool allowVoid);
    ClassDecl* nullableTemplate();
    Type* nullableOf(Type* t, SourceLoc loc);
    ClassDecl* tupleDecl(const std::vector<Type*>& elems, SourceLoc loc);
    Type* tupleType(const std::vector<Type*>& elems, const std::vector<std::string>& names, SourceLoc loc);
    int sugarImplicit(Expr* e, Type* from, Type* to);  // -1: sin opinión, 0/1: resultado
    bool sugarCoerce(Expr*& e, Type* to);
    bool sugarUnify(TypeRef* p, Type* a, MethodDecl* tmpl, std::map<std::string, Type*>& b);
    Type* sugarBinary(BinaryExpr* e, Type*& L, Type*& R);  // nullptr: no es azúcar
    Type* sugarMember(MemberExpr* e, Type* base);         // nullptr: no es azúcar
    bool sugarConcatable(Type* t);
    bool toStringable(Type* t, int depth = 0);
    Type* checkInterp(InterpExpr* e);
    Type* checkCoalesce(BinaryExpr* e, Type* L);
    Type* checkCoalesceAssign(AssignExpr* e);
    Type* checkDeconstructAssign(AssignExpr* e);
    Type* checkCondAccess(CondAccessExpr* e);
    Type* checkTuple(TupleExpr* e);
    Type* checkSwitchExpr(SwitchExpr* e);
    Type* checkIsPattern(IsPatternExpr* e);
    // Condición (sin comprobar) de que subj() encaja con el patrón; subj() crea cada vez una
    // expresión nueva del sujeto (de tipo st). Las variables del patrón se declaran en el ámbito actual.
    Expr* patternTest(Pattern* p, const SubjectFn& subj, Type* st);
    Expr* propertyTests(Pattern* p, const SubjectFn& subj, Type* st);  // { Prop: patrón, ... }
    Expr* bindPatternVar(Pattern* p, const std::string& name, Type* t, Expr* value);  // (x = valor, true)
    // GANCHO para los patrones de tipo ('case Perro p:', 'x is Perro p', 'Perro { Edad: > 3 }',
    // 'case Perro:'): ver el comentario de la implementación en Sugar.cpp.
    Expr* lowerTypePattern(Pattern* p, Type* target, const SubjectFn& subj, Type* st);
    bool lowerSwitchStmt(SwitchStmt* s);
    void checkForeach(ForeachStmt* s);
    void checkDeconstruct(DeconstructStmt* s);
    void checkUsing(UsingStmt* s);
    bool paramsMethod(MethodDecl* m) const { return !m->params.empty() && m->params.back().isParams; }
    int paramsCost(MethodDecl* m, std::vector<Expr*>& args);
    void packParams(MethodDecl* m, std::vector<Expr*>& args);
    void checkParamsSignature(MethodDecl* m);
    void inferParamsTypeArgs(MethodDecl* tmpl, const std::vector<Expr*>& args, std::map<std::string, Type*>& b);
    // orientación a objetos (SemaClasses.cpp)
    struct PendingConstraint {
        ClassDecl* inst;
        SourceLoc loc;
    };
    std::vector<PendingConstraint> pendingConstraints_;
    std::string constraintError_;
    int patternCounter_ = 0;
    size_t fieldWorkDone_ = 0, workDone_ = 0;  // avance de processWork()
    void initObjectModel();
    void resolveHierarchy(ClassDecl* c);
    void finishClassLayout(ClassDecl* c);
    std::vector<ClassDecl*> lookupChain(ClassDecl* c);
    FieldDecl* findField(ClassDecl* c, const std::string& name);
    MethodDecl* findGetter(ClassDecl* c, const std::string& name);
    std::vector<MethodDecl*> findMethods(ClassDecl* c, const std::string& name, MethodKind kind = MethodKind::Normal);
    MethodDecl* findInterfaceImpl(ClassDecl* c, MethodDecl* im);
    bool accessible(Access a, ClassDecl* owner);
    bool checkedCastOk(Type* from, Type* to);
    int inheritCost(ClassDecl* from, ClassDecl* to);
    bool satisfies(Type* arg, const TypeConstraint& tc, std::string& what);
    bool checkConstraints(const std::vector<std::string>& params, const std::vector<TypeConstraint>& cons,
                          const std::map<std::string, Type*>& args, const std::string& owner, std::string& err);
    bool checkPendingConstraints();
    void checkCtorInit(MethodDecl* m);
    bool isBaseExpr(Expr* e) const;
    Type* checkOO(Expr* e);
    Type* checkIs(IsExpr* e);
    Type* checkAs(AsExpr* e);
    Type* checkWith(WithExpr* e);
};
