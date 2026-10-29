#include "Types.h"

#include "AST.h"

int Type::bits() const {
    switch (kind) {
        case TK::SByte: case TK::Byte: return 8;
        case TK::Short: case TK::UShort: return 16;
        case TK::Char: case TK::Int: case TK::UInt: case TK::Enum: return 32;
        case TK::Long: case TK::ULong: return 64;
        default: return 0;
    }
}

std::string Type::str() const {
    switch (kind) {
        case TK::Void: return "void";
        case TK::Bool: return "bool";
        case TK::Char: return "char";
        case TK::SByte: return "sbyte";
        case TK::Byte: return "byte";
        case TK::Short: return "short";
        case TK::UShort: return "ushort";
        case TK::Int: return "int";
        case TK::UInt: return "uint";
        case TK::Long: return "long";
        case TK::ULong: return "ulong";
        case TK::Float: return "float";
        case TK::Double: return "double";
        case TK::String: return "string";
        case TK::Null: return "null";
        case TK::Pointer: return elem->str() + "*";
        case TK::Class: case TK::Struct: case TK::Enum: return decl->displayName;
        case TK::FuncPtr: {
            std::string s = "delegate*<";
            for (Type* p : params) s += p->str() + ", ";
            return s + ret->str() + ">";
        }
        case TK::Error: return "<error>";
        case TK::Delegate: {
            if (ret->isVoid()) {
                if (params.empty()) return "Action";
                std::string s = "Action<";
                for (size_t i = 0; i < params.size(); i++) s += (i ? ", " : "") + params[i]->str();
                return s + ">";
            }
            std::string s = "Func<";
            for (Type* p : params) s += p->str() + ", ";
            return s + ret->str() + ">";
        }
        case TK::Pending: return id == 0 ? "expresión lambda" : "grupo de métodos";
    }
    return "?";
}

TypeCtx::TypeCtx() {
    for (int k = 0; k <= (int)TK::Error; k++) prims_[k] = new Type((TK)k);
    pendingGroup_.id = 1;
}

Type* TypeCtx::pointerTo(Type* t) {
    if (t->isError()) return t;
    if (!t->ptr) {
        t->ptr = new Type(TK::Pointer);
        t->ptr->elem = t;
    }
    return t->ptr;
}

Type* TypeCtx::funcPtr(const std::vector<Type*>& params, Type* ret) {
    std::vector<Type*> key = params;
    key.push_back(ret);
    auto it = funcPtrCache_.find(key);
    if (it != funcPtrCache_.end()) return it->second;
    Type* t = new Type(TK::FuncPtr);
    t->params = params;
    t->ret = ret;
    t->id = (int)funcPtrs_.size();
    funcPtrs_.push_back(t);
    funcPtrCache_[key] = t;
    return t;
}

Type* TypeCtx::delegateType(const std::vector<Type*>& params, Type* ret) {
    std::vector<Type*> key = params;
    key.push_back(ret);
    auto it = delegateCache_.find(key);
    if (it != delegateCache_.end()) return it->second;
    Type* t = new Type(TK::Delegate);
    t->params = params;
    t->ret = ret;
    t->id = (int)delegates_.size();
    delegates_.push_back(t);
    delegateCache_[key] = t;
    return t;
}

Type* TypeCtx::fromKeyword(const std::string& kw) {
    static const std::map<std::string, TK> m = {
        {"void", TK::Void},   {"bool", TK::Bool},     {"char", TK::Char},     {"sbyte", TK::SByte},
        {"byte", TK::Byte},   {"short", TK::Short},   {"ushort", TK::UShort}, {"int", TK::Int},
        {"uint", TK::UInt},   {"long", TK::Long},     {"ulong", TK::ULong},   {"float", TK::Float},
        {"double", TK::Double}, {"string", TK::String},
    };
    auto it = m.find(kw);
    return it == m.end() ? nullptr : get(it->second);
}
