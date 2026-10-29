// Faset - generación de código C11 portable a partir del AST comprobado.
// El C resultante se compila a código máquina nativo con gcc/clang/NDK.
#pragma once
#include <map>
#include <set>
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
};
