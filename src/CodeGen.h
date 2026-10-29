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

    // excepciones (Exceptions.cpp)
    struct ExcRegion {
        bool finally = false;  // marco de un try/finally (si no, de un try/catch)
        std::string frame;     // variable C con el marco (faset_exc_frame)
        int id = 0;
        int breakRemain = -1, contRemain = -1;  // break/continue que pasan por este finally
        bool ret = false;                       // algún 'return' pasa por este finally
        MethodDecl* method = nullptr;           // método que la abrió (un cuerpo anidado no la ve)
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
};
