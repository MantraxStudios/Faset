// Faset - utilidades compartidas por Sema (Arrays.cpp) y CodeGen (CodeGenArrays.cpp) para los
// arreglos: T[] es una instancia de std.Array<T> (T[,] de Array2D<T>, T[,,] de Array3D<T>).
#pragma once
#include "AST.h"

// T de una instancia de una plantilla de la biblioteca (std.Array<T>, std.collections.List<T>...).
inline Type* stdTemplateArg(Type* t, const char* name, const char* ns, size_t index = 0) {
    if (!t || !t->isAggregate() || !t->decl->templateOf) return nullptr;
    ClassDecl* tm = t->decl->templateOf;
    if (tm->name != name || tm->ns != ns || t->decl->typeArgs.size() <= index) return nullptr;
    return t->decl->typeArgs[index];
}

// Elemento de un arreglo (y su número de dimensiones), o nulo si el tipo no es un arreglo.
inline Type* arrayElemOf(Type* t, int* rank = nullptr) {
    static const char* const names[] = {"Array", "Array2D", "Array3D"};
    for (int r = 0; r < 3; r++)
        if (Type* e = stdTemplateArg(t, names[r], "std")) {
            if (rank) *rank = r + 1;
            return e;
        }
    return nullptr;
}

// Elemento de un T[] de una dimensión (o nulo).
inline Type* vectorElemOf(Type* t) {
    int rank = 0;
    Type* e = arrayElemOf(t, &rank);
    return rank == 1 ? e : nullptr;
}
