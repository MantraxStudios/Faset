// Faset - async / await: información compartida por Sema (Async.cpp) y CodeGen (CodeGenAsync.cpp).
#pragma once
#include "AST.h"

// Un método o lambda 'async' se compila como una máquina de estados (ver Async.cpp).
struct AsyncInfo {
    MethodDecl* fn = nullptr;      // el método (o la función sintética de la lambda)
    LambdaExpr* lambda = nullptr;  // lambda async (nulo en un método)
    Type* ret = nullptr;           // tipo declarado: Task, Task<T> o void (async void)
    Type* result = nullptr;        // T de Task<T>; void en Task y en async void (nulo: infiriendo)
    bool isVoid = false;           // async void: sin tarea; una excepción no atrapada termina el programa
    int depth = 0;                 // nivel de lambdas de su cuerpo (VarInfo::fnDepth de sus variables)
    VarInfo* task = nullptr;       // <task>: la tarea que devuelve
    VarInfo* res = nullptr;        // <res>: valor de 'return' (si result no es void)
    VarInfo* exc = nullptr;        // <exc>: excepción no atrapada
    VarInfo* cont = nullptr;       // <cont>: Action que reanuda la máquina (se registra con OnCompleted)
    Expr* newTask = nullptr;       // <task> = new Task<T>()             (comprobadas)
    Expr* setResult = nullptr;     // <task>.SetResult(<res>) / SetResult()
    Expr* setException = nullptr;  // <task>.SetException(<exc>)
    std::vector<VarInfo*> vars;    // todas sus variables locales: viven en el marco (objeto del recolector)
    int awaits = 0;
    // Iteradores (ver Iterators.cpp): la misma máquina de estados con 'yield' como punto de suspensión.
    //   1 IEnumerable<T>, 2 IEnumerator<T>, 3 IAsyncEnumerable<T>, 4 IAsyncEnumerator<T>; -1 tipo no válido.
    int iterKind = 0;
    Type* elem = nullptr;          // T de los elementos
    Type* gen = nullptr;           // Generador<T> / GeneradorAsync<T> (el objeto que se devuelve)
    VarInfo* iterObj = nullptr;    // <it>: el generador (recibe Current)
    VarInfo* stepDlg = nullptr;    // <paso>: Func<int, bool> / Func<int, Task<bool>> (env = marco)
    VarInfo* cloneDlg = nullptr;   // <clon>: Func<Generador<T>> (otro recorrido desde el principio)
    Expr* newIter = nullptr;       // <it> = new Generador<T>(<paso>, <clon>)   (comprobada)
    int yields = 0;
    bool isAsyncIter() const { return iterKind == 3 || iterKind == 4; }
};
