// Faset - generación de código C11 portable a partir del AST comprobado.
// El C resultante se compila a código máquina nativo con gcc/clang/NDK.
#pragma once
#include <sstream>

#include "Sema.h"

class CodeGen {
public:
    CodeGen(Program& prog, Sema& sema, TypeCtx& tc) : prog_(prog), sema_(sema), tc_(tc) {}
    // shared = biblioteca (.so/.dll): sin main(), con inicialización automática.
    std::string generate(bool shared);
    // Comprobaciones en tiempo de ejecución (nulos, objetos liberados, índices, división por cero).
    bool checks = false;

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
    std::string call(MethodDecl* m, const std::string& self, const std::vector<Expr*>& args, SourceLoc loc);
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
};

// Runtime de los delegados (se añade al C generado tras la cabecera del runtime).
extern const char* const kDelegateRuntime;
