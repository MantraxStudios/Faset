// Faset - analizador sintáctico (descenso recursivo, sintaxis mixta C# / C++).
#pragma once
#include <algorithm>
#include <functional>

#include "AST.h"
#include "Lexer.h"

class Parser {
public:
    // libRoots: nombres de las carpetas raíz de la biblioteca (p. ej. "std"), para detectar
    // rutas cualificadas como std::io::File que requieren cargar un módulo.
    Parser(TokenList toks, Program& prog, FileScope* file, std::string fileDir,
           const std::set<std::string>* libRoots = nullptr)
        : toks_(std::move(toks)), prog_(prog), file_(file), fileDir_(std::move(fileDir)), libRoots_(libRoots) {}

    void parseFile();

    // Vuelve a analizar una plantilla desde sus tokens para crear una instancia nueva.
    static ClassDecl* reparseType(ClassDecl* tmpl, Program& prog);
    static MethodDecl* reparseMethod(MethodDecl* tmpl, Program& prog);
    // Copia nueva de una lambda (se comprueba con otros tipos de parámetros; ver Lambdas.cpp).
    static LambdaExpr* reparseLambda(LambdaExpr* l, Program& prog);
    // Copia nueva de una sentencia desde sus tokens (cuerpo de 'comptime foreach'; ParserComptime.cpp).
    static Stmt* reparseStmt(const TokenList& toks, size_t begin, FileScope* file, Program& prog);

private:
    struct ParseError {};

    TokenList toks_;
    size_t p_ = 0;
    Program& prog_;
    FileScope* file_;
    std::string fileDir_;
    const std::set<std::string>* libRoots_;
    bool reparse_ = false;
    bool halfGt_ = false;     // se consumió la primera mitad de un '>>' al cerrar genéricos
    bool sawMarker_ = false;  // se vio el marcador de autocompletado: se toleran ';' y ')' ausentes
    std::map<std::string, ClassDecl*> hidden_;
    bool hasSection_ = false;
    Access section_ = Access::Private;
    bool nsUnsafe_ = false;   // dentro de 'memory_unsafe namespace X { ... }'
    const Token& cur() const { return (*toks_)[p_]; }
    const Token& peekTok(size_t n = 1) const { return (*toks_)[std::min(p_ + n, toks_->size() - 1)]; }
    bool atEnd() const { return cur().kind == TokKind::End; }
    bool isP(const char* s) const { return cur().kind == TokKind::Punct && cur().text == s; }
    bool isK(const char* s) const { return cur().kind == TokKind::Keyword && cur().text == s; }
    bool isDot() const { return isP(".") || isP("::"); }
    bool acceptP(const char* s);
    bool acceptK(const char* s);
    void expectP(const char* s);
    std::string expectIdent();
    [[noreturn]] void fail(const std::string& msg);
    [[noreturn]] void fail(const SourceLoc& loc, const std::string& msg);
    bool isUnsafeKw() const { return isK("memory_unsafe") || isK("unsafe"); }
    void unsafeKeywordError();
    void skipTo(const char* stop);

    // declaraciones
    std::string attributeArgText();  // argumento de atributo que no es una cadena (TestRunner.cpp)
    void parseNamespaceBody(const std::string& ns, bool braced);
    void parseUsing(bool isImport);
    std::vector<std::string> parseDottedPath();
    void requestModule(const std::vector<std::string>& path);
    void scanQualifiedNames();
    ClassDecl* hiddenFor(const std::string& ns);
    ClassDecl* parseTypeDecl(const std::string& ns, std::vector<Attribute> attrs, Modifiers mods, size_t begin);
    void parseMember(ClassDecl* c, std::vector<Attribute> attrs, Modifiers mods, size_t begin);
    void parseEnumBody(ClassDecl* c);
    std::vector<Attribute> parseAttributes();
    Modifiers parseModifiers();
    void parseParams(MethodDecl* m, bool rustStyle = false);
    std::vector<std::string> parseTypeParams();
    void skipWhereClauses();

    // tipos
    bool isPrimitiveKw() const;
    bool closeAngle();
    bool parseTypeArgs(std::vector<TypeRef*>& out);
    bool tryExprTypeArgs(std::vector<TypeRef*>& out);
    TypeRef* parseType();
    TypeRef* tryParseType();

    // sentencias
    Stmt* parseStatement();
    BlockStmt* parseBlock();
    bool looksLikeDecl();
    VarDeclStmt* parseVarDecl(bool requireSemicolon);
    Stmt* parseSwitch();
    Stmt* parseTry();    // Exceptions.cpp
    Stmt* parseThrow();  // Exceptions.cpp

    // expresiones
    Expr* parseExpr();
    Expr* parseAssign();
    Expr* parseConditional();
    Expr* parseBinary(int prec);
    Expr* parseUnary();
    Expr* parsePostfix(Expr* e);
    Expr* parsePrimary();
    std::vector<Expr*> parseArgs();

    // lambdas y delegados (ParserLambdas.cpp)
    Expr* tryParseLambda();
    void parseDelegateDecl(ClassDecl* owner, std::vector<Attribute> attrs, Modifiers mods);
    // ---- azúcar sintáctico (ParserSugar.cpp)
    bool allowArraySuffix_ = false;  // 'params T[] xs' (se convierte en List<T>)
    bool isIdentText(const char* s) const { return cur().kind == TokKind::Ident && cur().text == s; }
    bool nullableMarkFollows() const;
    TypeRef* tryParseTupleType();
    Expr* parseInterpolated();
    Expr* parseParenOrTuple(SourceLoc loc);
    Expr* parseConditionalAccess(Expr* obj);
    Expr* parseCoalesce(Expr* lhs);
    Expr* parseSwitchExpr(Expr* subject);
    Expr* parseIsPattern(Expr* subject);
    Expr* parseNameof(SourceLoc loc);
    Pattern* parsePattern();
    Pattern* parseAndPattern();
    Pattern* parseNotPattern();
    Pattern* parsePrimaryPattern();
    Stmt* parseForeach();
    Stmt* parseUsingStmt();
    Stmt* tryParseDeconstruct();
    // ---- iteradores (ParserIterators.cpp): yield, await foreach, funciones locales e
    // implementaciones explícitas de interfaces
    Stmt* parseIterStmt();
    Stmt* parseLocalFunction();
    TypeRef* parseExplicitIface();
    void parseSwitchLabel(SwitchStmt::Section& sec);
    // orientación a objetos (ParserClasses.cpp)
    bool isRecordStart() const;
    void parseWhereClauses(std::vector<TypeConstraint>& out);
    void synthesizeRecord(ClassDecl* c, const std::vector<Param>& params, bool positional);
    Expr* parseIsAs(Expr* lhs);
    Expr* parseWith(Expr* operand);
    // ---- métodos, construcción y organización de tipos (ParserMembers.cpp)
    int inTemplateType_ = 0;  // dentro del cuerpo de una clase genérica (sus tipos anidados)
    using FinishFn = std::function<void(MethodDecl*)>;
    void parseNestedType(ClassDecl* outer, std::vector<Attribute> attrs, Modifiers mods, size_t begin);
    void finishStaticCtor(ClassDecl* c, MethodDecl* m, const FinishFn& finish);
    void parseConversionOperator(ClassDecl* c, std::vector<Attribute> attrs, Modifiers mods, const FinishFn& finish);
    void parseIndexer(ClassDecl* c, std::vector<Attribute> attrs, Modifiers mods, TypeRef* type, bool ctxUnsafe,
                      const FinishFn& finish);
    // Shared get/set body of an indexer, after the parameters and element type are known. Used by both
    // the C# form (T this[...] { ... }) and the modern 'subscript(...) -> T { ... }' form.
    void parseIndexerBody(ClassDecl* c, std::vector<Attribute> attrs, Modifiers mods, TypeRef* type,
                          std::vector<Param> params, SourceLoc loc, const FinishFn& finish);
    ObjInit* parseObjInit();
    Expr* tryParseOutVar();
    static void hoistLocalFunctions(BlockStmt* b);
    // uniones (tipos algebraicos), '?' de propagación, defer/errdefer, |> y 'match' (ParserUnions.cpp)
    bool isUnionStart() const;
    void parseUnionBody(ClassDecl* c);
    void synthesizeUnion(ClassDecl* c);
    Pattern* parseCasePattern(TypeRef* tr, SourceLoc loc);
    bool propagateFollows() const;
    bool isMatchKw() const;
    Stmt* tryParseDefer();
    Expr* parsePipe(Expr* lhs);
    // arreglos, índices, rangos, expresiones de colección y patrones de lista (ParserArrays.cpp)
    TypeRef* parseArraySuffix(TypeRef* tr);               // T[], T[,], T[][] (después del tipo base)
    std::vector<int> parseArrayRanks();                   // [] [,] ... (puede no haber ninguno)
    static TypeRef* arrayTypeRef(TypeRef* elem, int rank);
    Expr* parseNewArray(SourceLoc loc, TypeRef* tr);      // new T[n], new T[] { ... }, new T[a, b]
    Expr* parseImplicitNewArray(SourceLoc loc);           // new[] { ... }
    Expr* parseCollectionExpr();                          // [1, 2, ..otra]
    Expr* parseBraceInit();                               // { 1, 2 } / { {1, 2}, {3, 4} }
    Expr* parseRangeTail(Expr* start);                    // a..b (el cursor está en '..')
    Expr* parseFromEnd();                                 // ^n
    Expr* parseIndexList(Expr* first);                    // a[i, j]: índice (i, j)
    Pattern* parseListPattern();                          // [1, .., var x]
    bool startsRangeEnd() const;
    // ---- tiempo de compilación y atributos (ParserComptime.cpp)
    bool isComptimeKw() const { return cur().kind == TokKind::Ident && cur().text == "comptime"; }
    void parseAttributeArgs(Attribute& a);
    Stmt* tryParseComptimeStmt();
    Expr* tryParseComptimeExpr();
    bool tryParseStaticAssertMember(ClassDecl* c);
};
