// Faset - runtime en C embebido en el compilador (la biblioteca estándar está en lib/std/*.fst).
#pragma once

// Cabecera común a todo código C generado y al runtime.
extern const char* const kRuntimeHeader;
// Implementación del runtime (se compila junto al programa).
extern const char* const kRuntimeSource;
// Capa POSIX de std.io / std.os (se añade a kRuntimeSource; ver RuntimeOs.cpp).
extern const char* const kRuntimeOsSource;
// Recolector de basura (se compila aparte como faset_gc.c; ver RuntimeGc.cpp).
extern const char* const kRuntimeGcSource;
// Reproducción de vídeo de std.ui (VideoPlayer): se añade al runtime cuando se usa std.video.
extern const char* const kRuntimeVideoSource;
