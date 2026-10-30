// Faset - caché de objetos del compilador de C (compilaciones incrementales).
//
// Antes, cada 'faset build' compilaba con una sola orden el C generado, el runtime (faset_rt.c,
// faset_gc.c) y el C de la biblioteca (stb_image, TLS, audio, WebView...). Ahora cada .c se compila
// por separado ('-c') y su objeto se guarda en una caché indexada por un hash de:
//   - el compilador (ruta, tamaño y fecha del ejecutable),
//   - las opciones que afectan a la compilación (-O, -g, -D, -I, -f..., -m..., --target...),
//   - el contenido del .c y de los archivos que incluye con #include "..." (recursivamente).
// Debug y Release, cada objetivo y arquitectura y cada combinación de opciones tienen su propia
// entrada, así que nunca se mezclan objetos viejos. Los objetos del runtime y de la biblioteca van
// a <datos de faset>/cache/obj (compartidos entre proyectos); el del programa, a obj/ del proyecto
// (lo borra 'faset clean'). Después se enlaza todo con la misma orden de antes.
//
// La caché compartida tiene un límite de tamaño (FASET_CACHE_MAX_MB, por defecto 1024): al pasarlo se
// borran los objetos usados hace más tiempo; los que no se usan en 30 días se borran siempre.
// Los .c que faltan se compilan a la vez en FASET_JOBS procesos (por defecto, la mitad de los
// núcleos, como mucho 4). FASET_NO_CACHE=1 desactiva la caché (se compila como antes, con una sola orden).
#pragma once
#include <functional>
#include <string>
#include <vector>

struct CompileCacheOptions {
    // Carpeta para el objeto del primer .c de la orden (el C generado del programa); "" = no se
    // guarda (archivos sueltos: se compila siempre).
    std::string programCacheDir;
    bool verbose = false;
    // Ejecuta una orden y devuelve su código de salida.
    std::function<int(const std::vector<std::string>&, bool verbose)> run;
};

// Ejecuta 'cmd' (cc [opciones] a.c b.c ... -o salida [bibliotecas]) compilando cada .c con la caché
// y enlazando después. Devuelve el código de salida del compilador (0 si todo fue bien).
int compileWithCache(const std::vector<std::string>& cmd, const CompileCacheOptions& opts);

// Carpeta de la caché compartida de objetos.
std::string objectCacheDir();

// Borra la caché compartida de objetos (faset clean --cache). Devuelve los bytes liberados.
unsigned long long clearObjectCache();
