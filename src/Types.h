// Faset - representación de tipos semánticos.
#pragma once
#include <map>
#include <string>
#include <vector>

struct ClassDecl;

// El orden importa: Char..ULong son los tipos integrales (ver isIntegral).
enum class TK {
    Void, Bool, Char, SByte, Byte, Short, UShort, Int, UInt, Long, ULong, Float, Double,
    String, Null, Pointer, Class, Struct, Enum, FuncPtr, Error
};

struct Type {
    TK kind;
    Type* elem = nullptr;       // para punteros
    ClassDecl* decl = nullptr;  // para clases, structs y enums
    Type* ptr = nullptr;        // caché de pointerTo(this)
    std::vector<Type*> params;  // FuncPtr: parámetros
    Type* ret = nullptr;        // FuncPtr: retorno
    int id = 0;                 // FuncPtr: índice para el typedef en C

    explicit Type(TK k) : kind(k) {}

    bool is(TK k) const { return kind == k; }
    bool isError() const { return kind == TK::Error; }
    bool isVoid() const { return kind == TK::Void; }
    bool isIntegral() const { return kind >= TK::Char && kind <= TK::ULong; }
    bool isFloating() const { return kind == TK::Float || kind == TK::Double; }
    bool isNumeric() const { return isIntegral() || isFloating(); }
    bool isSignedInt() const {
        return kind == TK::SByte || kind == TK::Short || kind == TK::Int || kind == TK::Long;
    }
    bool isUnsignedInt() const {
        return kind == TK::Char || kind == TK::Byte || kind == TK::UShort || kind == TK::UInt || kind == TK::ULong;
    }
    bool isPointer() const { return kind == TK::Pointer; }
    bool isVoidPointer() const { return kind == TK::Pointer && elem->kind == TK::Void; }
    bool isClass() const { return kind == TK::Class; }
    bool isStruct() const { return kind == TK::Struct; }
    bool isEnum() const { return kind == TK::Enum; }
    bool isFuncPtr() const { return kind == TK::FuncPtr; }
    bool isAggregate() const { return kind == TK::Class || kind == TK::Struct; }
    // Tipos que admiten 'null'.
    bool isRefLike() const {
        return kind == TK::Pointer || kind == TK::Class || kind == TK::Null || kind == TK::FuncPtr;
    }
    int bits() const;  // ancho en bits de los tipos integrales
    std::string str() const;
};

class TypeCtx {
public:
    TypeCtx();
    Type* get(TK k) { return prims_[(int)k]; }
    Type* error() { return prims_[(int)TK::Error]; }
    Type* pointerTo(Type* t);
    Type* funcPtr(const std::vector<Type*>& params, Type* ret);
    const std::vector<Type*>& funcPtrs() const { return funcPtrs_; }
    // Tipo primitivo a partir de su palabra clave, o nullptr.
    Type* fromKeyword(const std::string& kw);

private:
    Type* prims_[(int)TK::Error + 1];
    std::map<std::vector<Type*>, Type*> funcPtrCache_;
    std::vector<Type*> funcPtrs_;
};
