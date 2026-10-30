// Faset - generación de código C11 portable a partir del AST comprobado.
// El C resultante se compila a código máquina nativo con gcc/clang/NDK.
#pragma once
#include <map>
#include <set>
#include <sstream>
#include <unordered_map>

#include "Sema.h"

// Efectos de una expresión para el orden de evaluación (EvalOrder.cpp). Lo que se lee o se
// escribe directamente se anota por "clave": una variable local, un campo (todos los objetos a
// la vez) o kEvalElems (elementos de arrays, '*p', referencias T&). "Memoria" es lo que una
// llamada puede ver o cambiar (campos, elementos, variables capturadas); las variables locales
// simples no. Una llamada lee (y si no es pura, escribe) memoria desconocida: 'Any'.
struct EvalEffects {
    bool readsMem = false, writesMem = false;
    bool readsAny = false, writesAny = false;
    std::vector<const void*> reads, writes;
    void merge(const EvalEffects& o);
    void read(const void* key, bool mem);
    void write(const void* key, bool mem);
    void call(int level);  // 2: solo lee memoria; 3: también la escribe (o hace E/S)
    bool any() const { return readsMem || writesMem || !reads.empty() || !writes.empty(); }
    bool hasWrites() const { return writesMem || !writes.empty(); }
    // ¿Importa el orden entre esta expresión y 'later' (que en C# se evalúa después)?
    bool conflictsWith(const EvalEffects& later) const;
};
extern const char kEvalElems[];

// ¿Es un lvalue de C? (se puede tomar '&': receptores struct, ref, temporales de dirección)
bool cgIsLValue(Expr* e);

class CodeGen {
public:
    CodeGen(Program& prog, Sema& sema, TypeCtx& tc) : prog_(prog), sema_(sema), tc_(tc) {}
    // shared = biblioteca (.so/.dll): sin main(), con inicialización automática.
    std::string generate(bool shared);
    // Comprobaciones en tiempo de ejecución (nulos, objetos liberados, índices, división por cero).
    bool checks = false;
    // Información de depuración: directivas '#line N "archivo.fst"' para que gdb/lldb asocien el
    // código máquina con las líneas de Faset (CodeGenDebug.cpp). Solo en Debug o con -g.
    bool lineDirectives = false;

    // Declara una variable local en C con su valor inicial (código C; "" = cero). Si alguna lambda
    // la captura, vive en una caja del recolector: una caja nueva cada vez que se ejecuta la
    // declaración (así 'foreach' y los bucles tienen una variable nueva por iteración, como en C#).
    // Las sentencias nuevas que declaran variables deben usar esta función.
    void declareLocalVar(VarInfo* v, const std::string& init);

private:
    Program& prog_;
    Sema& sema_;
    TypeCtx& tc_;
    std::ostringstream out_;
    int indent_ = 0;
    int tmp_ = 0;
    ClassDecl* curClass_ = nullptr;
    MethodDecl* curMethod_ = nullptr;

    std::string ctype(Type* t);
    std::string zeroInit(Type* t);
    std::string signature(MethodDecl* m);
    std::string ctorParams(MethodDecl* ctor, bool withTypes);
    std::string cstring(const std::string& s);

    void line(const std::string& s);
    void emitMethod(MethodDecl* m);
    void emitConstructionHelpers(ClassDecl* c);
    void emitStmt(Stmt* s);
    void emitBody(Stmt* s);  // emite como bloque

    std::string expr(Expr* e);
    std::string toStr(Expr* e);
    std::string receiverPtr(Expr* recv, bool arrow);
    // Llamada a un método. Con 'recv', el receptor es esa expresión (se evalúa antes que los
    // argumentos, como en C#) y 'self' se ignora.
    std::string call(MethodDecl* m, const std::string& self, const std::vector<Expr*>& args, SourceLoc loc,
                     bool nonVirtual = false, Expr* recv = nullptr, bool recvArrow = false);
    // Llamada con el receptor y los argumentos ya generados (los 'ref' ya llevan '&').
    std::string callCode(MethodDecl* m, const std::string& self, const std::vector<std::string>& args, SourceLoc loc,
                         bool nonVirtual);
    std::string memberAccess(Expr* obj, bool arrow, const std::string& field);
    std::string loc(SourceLoc l);        // "fs__fN, línea"
    std::string callerLoc(SourceLoc l);  // ubicación para un método [TrackCaller]
    std::string chkObj(Expr* obj, const std::string& code);

    // lambdas, cierres y delegados (CodeGenLambdas.cpp)
    LambdaExpr* curLambda_ = nullptr;
    std::string localRef(VarInfo* v);  // acceso a una variable local o parámetro
    std::string boxRef(VarInfo* v);    // puntero a la caja de una variable capturada
    void boxParams(const std::vector<VarInfo*>& params);
    void emitDelegateSupport();        // invocadores por tipo delegado y entornos de las lambdas
    void emitLambdaDecls();            // adaptadores de métodos, prototipos y constructores de cierres
    void emitLambdaBodies();
    std::string lambdaSig(LambdaExpr* l);
    std::string lambdaExpr(LambdaExpr* l);
    std::string delegateConv(DelegateConvExpr* dc);
    std::string delegateCall(CallExpr* c);
    // excepciones (Exceptions.cpp)
    struct ExcRegion {
        bool finally = false;  // marco de un try/finally (si no, de un try/catch)
        std::string frame;     // variable C con el marco (faset_exc_frame)
        int id = 0;
        int breakRemain = -1, contRemain = -1;  // break/continue que pasan por este finally
        bool ret = false;                       // algún 'return' pasa por este finally
        MethodDecl* method = nullptr;           // método que la abrió (un cuerpo anidado no la ve)
        size_t usingsAt = 0;                    // ámbitos de 'using' abiertos al entrar (los de dentro se liberan antes del finally)
    };
    std::vector<ExcRegion> excRegions_;
    std::vector<std::string> excCatchFrames_;  // marco de la cláusula catch actual ('throw;')
    std::string excRetVar_;                    // valor de 'return' pendiente mientras corre un finally
    void emitExcDecls();
    void emitExcHelpers();
    void emitExcInit(ClassDecl* c);
    void emitTry(TryStmt* t);
    void emitTryCatch(TryStmt* t);
    void emitThrow(ThrowStmt* t);
    bool emitExcJump(Stmt* s);
    void emitExcJumpChain(int kind, int cross);
    // ---- azúcar sintáctico (SugarGen.cpp)
    // Temporales de expresión: se declaran al principio de la función que se está emitiendo.
    struct HoistFrame {
        std::ostringstream saved;
        std::vector<std::string> decls;
        std::set<std::string> names;
    };
    std::vector<HoistFrame*> hoist_;
    std::string helpers_;                       // funciones auxiliares (texto de tuplas y T?)
    std::map<std::string, std::string> strFns_;  // tipo C -> función auxiliar de texto
    int sugarTmp_ = 0;
    // Objetos de 'using' pendientes de liberar, por ámbito (bloque, bucle o switch).
    struct UsingScope {
        std::vector<std::string> objs;
        int kind = 0;  // 0 = bloque, 1 = bucle, 2 = switch
    };
    std::vector<UsingScope> usings_;
    bool rawNext_ = false;  // la próxima emitStmt usa el camino normal (sin emitSugarStmt)
    void pushHoist();
    void popHoist();
    void hoistDecl(const std::string& ctype, const std::string& name);
    std::string newTemp(const std::string& ctype);
    bool isSugarKind(EK k) const;
    std::string sugarExpr(Expr* e);
    bool sugarCast(CastExpr* c, std::string& out);
    bool emitSugarStmt(Stmt* s);
    std::string toStrCode(Type* t, const std::string& v);
    std::string strFn(Type* t);
    std::string nullValue(Type* t);
    std::string usingCleanup(int upToKind);  // destructores pendientes hasta el bucle/switch (o todos)
    // orientación a objetos (CodeGenClasses.cpp)
    std::string objC();
    std::string tiOf(ClassDecl* c);
    std::string tiOfType(Type* t);
    std::string fieldPath(ClassDecl* from, FieldDecl* f);
    std::string selfArg(MethodDecl* m, const std::string& self);
    std::string calleeName(MethodDecl* m, bool nonVirtual);
    bool hasDtorChain(ClassDecl* c);
    std::string baseDefaultCtor(ClassDecl* c);
    std::string fnPtrDecl(MethodDecl* m, const std::string& name);
    void emitClassStructPrefix(ClassDecl* c);
    void emitCtorPrologue(MethodDecl* m);
    void emitRecordBody(MethodDecl* m);
    void emitOO(int phase);
    std::string ooExpr(Expr* e);
    std::string strOf(Type* t, const std::string& v, int depth = 0);
    std::string eqOf(Type* t, const std::string& a, const std::string& b, int depth = 0);
    std::string hashOf(Type* t, const std::string& v, int depth = 0);
    void emitUnionBody(MethodDecl* m);  // uniones: ToString, GetHashCode y == (Unions.cpp)
    // ---- orden de evaluación de C# (EvalOrder.cpp)
    // C no fija el orden de los operandos ni de los argumentos; C# los evalúa de izquierda a
    // derecha. Cuando un operando posterior tiene efectos que un operando anterior vería (o al
    // revés), los anteriores se guardan antes en temporales: (t1 = A, t2 = B, F(t1, t2, C)).
    struct EvalOp {
        Expr* e = nullptr;     // operando (para el análisis)
        std::string code;      // su código C (se reemplaza por el temporal si hace falta)
        std::string ct;        // tipo C del valor
        bool addr = false;     // lvalue que se pasa por dirección (ref, receptor struct): se guarda '&code'
        bool conv = false;     // incluye su conversión a texto (ToString del usuario)
        bool hoisted = false;  // (salida) se evaluó antes en un temporal
        std::string tmp;       // (salida) nombre del temporal
        EvalOp() = default;
        EvalOp(Expr* x, std::string c, std::string t) : e(x), code(std::move(c)), ct(std::move(t)) {}
    };
    std::unordered_map<Expr*, EvalEffects> effCache_;
    std::map<MethodDecl*, int> methodEff_;  // 1 puro, 2 solo lee memoria, 3 escribe (punto fijo)
    int effState_ = 0;                      // 0 sin calcular, 1 calculando la tabla, 2 lista
    void computeMethodEffects();
    EvalEffects effects(Expr* e);           // efectos de evaluar el valor
    EvalEffects effectsImpl(Expr* e);
    EvalEffects locEffects(Expr* e);        // efectos de calcular la dirección de un lvalue
    EvalEffects storeEffects(Expr* e);      // escribir en el lvalue
    EvalEffects convEffects(Expr* e);       // convertir el valor a texto (concatenación)
    EvalEffects callEffects(MethodDecl* m, Expr* recv, bool arrow, bool nonVirtual, const std::vector<Expr*>& args);
    int methodEffect(MethodDecl* m, bool nonVirtual);
    int bodyEffect(MethodDecl* m);
    int stmtEffect(Stmt* s, MethodDecl* ctor);
    bool ctorPure(ClassDecl* c, MethodDecl* ctor);
public:
    // ¿Puede tener efectos visibles (llamadas, asignaciones, ++/--, new, await...)? Los nodos
    // que este análisis no conoce (p. ej. 'await') cuentan como efectos.
    bool hasSideEffects(Expr* e) { return effects(e).hasWrites(); }
private:
    std::string sequence(std::vector<EvalOp>& ops);  // prefijo "t1 = A, t2 = B, " (o "")
    static std::string seqWrap(const std::string& pre, const std::string& code);    // (pre, code)
    static std::string seqWrapLv(const std::string& pre, const std::string& code);  // lvalue: (*(pre, &code))
    EvalOp recvOp(Expr* recv, bool arrow);
    std::string recvCode(const EvalOp& op, Expr* recv, bool arrow);
    std::string assignExpr(AssignExpr* a);
    // Directivas #line (CodeGenDebug.cpp)
    SourceLoc curLoc_{-1, 0, 0};          // sentencia de Faset que se está emitiendo (file < 0: ninguna)
    void setLoc(SourceLoc l);             // las líneas siguientes pertenecen a esta ubicación
    void lineDirective(SourceLoc l);      // escribe '#line' ya (para código emitido con out_ <<)
    void resetLoc();                      // vuelve al C generado (main, inicialización...)
    std::string finishLineDirectives(const std::string& c);
    void emitDebugEnums();                // tipos enum de C para que gdb muestre los nombres
    std::string localType(Type* t);       // tipo de C de una variable local o campo (enum con nombre en Debug)
    // ---- async / await (CodeGenAsync.cpp): máquinas de estados con el marco en el recolector.
    AsyncInfo* async_ = nullptr;          // método o lambda async que se está emitiendo
    int asyncCounter_ = 0;
    std::vector<std::pair<std::string, std::string>> asyncFields_;  // (tipo C, nombre) de los campos del marco
    std::set<std::string> asyncFieldNames_;
    struct AsyncRegion {                  // zona protegida de un 'try' con algún 'await' dentro
        std::string label;                // etiqueta de reentrada (antes de FASET_TRY)
        std::vector<std::pair<int, std::string>> dispatch;  // estado -> etiqueta siguiente
    };
    std::map<std::pair<const TryStmt*, char>, AsyncRegion> asyncRegions_;
    std::vector<std::pair<int, std::string>> asyncTop_;  // despacho al entrar en la función de paso
    std::map<const Stmt*, int> asyncStates_;  // 'await' y 'yield' (iteradores) -> número de estado
    void emitAsyncMethod(MethodDecl* m);
    void emitAsyncLambda(LambdaExpr* l);
    void emitAsyncMachine(AsyncInfo* a, const std::string& entrySig, const std::string& selfType,
                          const std::string& selfInit, const std::vector<VarInfo*>& params, BlockStmt* body);
    void asyncAnalyze(Stmt* s, std::vector<std::pair<const TryStmt*, char>>& chain, int& states);
    void asyncField(const std::string& ctype, const std::string& name);
    void emitAwait(AwaitStmt* s);
    void emitAsyncReturn(ReturnStmt* rs);
    std::string asyncDispatch(const std::vector<std::pair<int, std::string>>& d);
    // Declara una variable local de C (en un método async, asigna el campo del marco).
    void emitLocalDecl(const std::string& ct, const std::string& name, const std::string& init,
                       const std::string& qual = " ");
    // FASET_TRY(marco) { — y, en un método async, la reentrada tras una suspensión.
    void emitTryOpen(TryStmt* t, char kind, const std::string& frame);
    // ---- iteradores (CodeGenIterators.cpp): la misma máquina con 'yield' como suspensión
    void emitIterMachine(AsyncInfo* a, const std::string& entrySig, const std::string& selfType,
                         const std::string& selfInit, const std::vector<VarInfo*>& params, BlockStmt* body);
    void emitYield(YieldStmt* y);
    void emitYieldBreak();
};

// Runtime de los delegados (se añade al C generado tras la cabecera del runtime).
extern const char* const kDelegateRuntime;
