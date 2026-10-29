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
    std::string call(MethodDecl* m, const std::string& self, const std::vector<Expr*>& args, SourceLoc loc,
                     bool nonVirtual = false);
    std::string memberAccess(Expr* obj, bool arrow, const std::string& field);
    std::string loc(SourceLoc l);        // "fs__fN, línea"
    std::string callerLoc(SourceLoc l);  // ubicación para un método [TrackCaller]
    std::string chkObj(Expr* obj, const std::string& code);

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
};
