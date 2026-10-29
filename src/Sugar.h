// Faset - utilidades compartidas por Sema (Sugar.cpp) y CodeGen (SugarGen.cpp) para el azúcar
// sintáctico: T? (Nullable<T> de std), tuplas (structs anónimos) y ToString() del usuario.
#pragma once
#include "AST.h"

// T de un Nullable<T> (o nulo si el tipo no lo es).
inline Type* nullableElem(Type* t) {
    if (!t || !t->isStruct() || !t->decl->templateOf) return nullptr;
    ClassDecl* tm = t->decl->templateOf;
    if (tm->name != "Nullable" || tm->ns != "std" || t->decl->typeArgs.size() != 1) return nullptr;
    return t->decl->typeArgs[0];
}

inline bool isTupleType(Type* t) { return t && t->isStruct() && t->decl->isTuple; }

// 'string ToString()' de instancia de una clase o struct del usuario (o nulo).
inline MethodDecl* findToString(Type* t) {
    if (!t || !t->isAggregate() || isTupleType(t) || nullableElem(t)) return nullptr;
    for (MethodDecl* m : t->decl->methods)
        if (m->kind == MethodKind::Normal && m->name == "ToString" && m->params.empty() && !m->isStatic() && m->ret &&
            m->ret->is(TK::String))
            return m;
    return nullptr;
}

inline bool isDefaultLiteral(Expr* e) { return e && e->kind == EK::Default && !static_cast<DefaultExpr*>(e)->tref; }
