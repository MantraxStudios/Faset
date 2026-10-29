// Faset - runtime en C embebido en el compilador (la biblioteca estándar está en lib/std/*.fst).
#pragma once

// Cabecera común a todo código C generado y al runtime.
extern const char* const kRuntimeHeader;
// Implementación del runtime (se compila junto al programa).
extern const char* const kRuntimeSource;
