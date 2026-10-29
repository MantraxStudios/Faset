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
    // Información de depuración: directivas '#line N "archivo.fst"' para que gdb/lldb asocien el
    // código máquina con las líneas de Faset (CodeGenDebug.cpp). Solo en Debug o con -g.
    bool lineDirectives = false;

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

    // Directivas #line (CodeGenDebug.cpp)
    SourceLoc curLoc_{-1, 0, 0};          // sentencia de Faset que se está emitiendo (file < 0: ninguna)
    void setLoc(SourceLoc l);             // las líneas siguientes pertenecen a esta ubicación
    void lineDirective(SourceLoc l);      // escribe '#line' ya (para código emitido con out_ <<)
    void resetLoc();                      // vuelve al C generado (main, inicialización...)
    std::string finishLineDirectives(const std::string& c);
    void emitDebugEnums();                // tipos enum de C para que gdb muestre los nombres
    std::string localType(Type* t);       // tipo de C de una variable local o campo (enum con nombre en Debug)
};
