// Faset - programación en tiempo de compilación: valores del intérprete y estado compartido
// entre Comptime.cpp (intérprete, comptime if/foreach/var, static_assert, Tipo<T>),
// Attributes.cpp (atributos de usuario) y Reflection.cpp (metadatos de reflexión al ejecutar).
#pragma once
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "Sema.h"

struct CtObj;

// Valor de tiempo de compilación. Los enteros guardan su tipo (int, long, byte, un enum...) para
// volver a escribirse como constantes del mismo tipo; los tipos, campos, métodos y atributos son
// valores de reflexión que solo existen mientras compila.
struct CtValue {
    enum K { Void, Null, Bool, Int, Float, Char, Str, List, TypeV, Member, Method, Param, EnumItem, Obj, Group } k = Void;
    int64_t i = 0;
    double f = 0;
    std::string s;
    Type* t = nullptr;  // Int/Float/Char: su tipo; TypeV: el tipo; List: tipo del elemento; Member/Param: su tipo
    std::shared_ptr<std::vector<CtValue>> list;
    std::shared_ptr<CtObj> obj;
    ClassDecl* owner = nullptr;      // Member/Method/EnumItem: tipo que lo declara
    FieldDecl* field = nullptr;      // Member: campo
    MethodDecl* getter = nullptr;    // Member: propiedad
    MethodDecl* setter = nullptr;
    MethodDecl* method = nullptr;    // Method/Param
    std::vector<MethodDecl*> group;  // Group: funciones con ese nombre (solo para llamarlas)
    int index = 0;                   // Member/Param/EnumItem: posición

    static CtValue boolean(bool b) {
        CtValue v;
        v.k = Bool;
        v.i = b;
        return v;
    }
    static CtValue str(const std::string& s) {
        CtValue v;
        v.k = Str;
        v.s = s;
        return v;
    }
    static CtValue type(Type* t) {
        CtValue v;
        v.k = TypeV;
        v.t = t;
        return v;
    }
    static CtValue null() {
        CtValue v;
        v.k = Null;
        return v;
    }
    bool isScalar() const { return k == Bool || k == Int || k == Float || k == Char || k == Str || k == Null; }
};

struct CtObj {
    ClassDecl* cls = nullptr;
    std::map<std::string, CtValue> fields;
    Attribute* attr = nullptr;  // atributo del que sale (a.Crear() lo construye al ejecutar)
};

struct CtFrame {
    std::string what;  // "Fib(int n)"
    SourceLoc callLoc;
};

struct CtError {
    SourceLoc loc;
    std::string msg;
    std::vector<CtFrame> stack;
};

struct CtState {
    std::map<VarInfo*, CtValue> binds;  // variables de tiempo de compilación (comptime var, comptime foreach)
    long long steps = 0;                // pasos de la evaluación actual
    long long cells = 0;                // elementos de listas y objetos creados en la evaluación actual
    long long unrolled = 0;             // vueltas de 'comptime foreach' en todo el programa
    std::vector<CtFrame> stack;         // llamadas en curso (para los mensajes de error)
    std::map<TypeRef*, Type*> typeCache;
    bool callerScanned = false;
    std::set<std::string> callerArgMethods;  // métodos con un parámetro [CallerArgumentExpression]
    // Reflexión al ejecutar (Reflection.cpp): tipos que necesitan metadatos.
    std::set<ClassDecl*> reflectSet;
    std::vector<std::pair<ClassDecl*, SourceLoc>> reflectQueue;
    size_t reflectDone = 0;
    ClassDecl* reflectHolder = nullptr;  // clase oculta con los campos que registran los metadatos
    std::set<std::string> obsoleteSeen;  // (archivo:línea) de avisos [Obsolete] ya mostrados
    bool attrsChecked = false;
    // Atributos de usuario evaluados (Attributes.cpp): el objeto de tiempo de compilación, los
    // argumentos del constructor y las propiedades con nombre (para crearlo también al ejecutar).
    std::map<Attribute*, std::shared_ptr<CtObj>> attrObjs;
    std::map<Attribute*, std::vector<CtValue>> attrArgs;
    std::map<Attribute*, std::vector<std::pair<std::string, CtValue>>> attrNamed;
};

// Límites del intérprete.
constexpr long long kCtMaxSteps = 20000000;  // sentencias y vueltas de bucle por evaluación
constexpr int kCtMaxDepth = 200;             // llamadas anidadas
constexpr int kCtMaxUnroll = 10000;          // vueltas de un 'comptime foreach'
constexpr long long kCtMaxUnrollTotal = 100000;  // vueltas de 'comptime foreach' en todo el programa
constexpr long long kCtMaxCells = 1000000;   // elementos de listas y objetos creados por evaluación
constexpr size_t kCtMaxString = 16u << 20;   // bytes de una cadena

// Destinos de los atributos (deben coincidir con std.AttributeTargets en lib/std/attributes.fst).
enum CtTarget {
    kTgClass = 1, kTgStruct = 2, kTgEnum = 4, kTgInterface = 8, kTgField = 16, kTgProperty = 32,
    kTgMethod = 64, kTgConstructor = 128, kTgParameter = 256, kTgAll = 511
};
