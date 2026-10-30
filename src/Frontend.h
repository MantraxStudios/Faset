// Faset - carga de archivos y módulos, análisis sintáctico y semántico.
// Lo comparten el compilador (faset build) y el servidor de lenguaje (faset lsp).
#pragma once
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Sema.h"

struct FrontendOptions {
    std::vector<std::string> inputs;  // archivos .fst del usuario
    std::string libDir;               // carpeta con std/core.fst
    // Contenido en memoria que reemplaza al del disco (ruta absoluta normalizada -> texto).
    const std::map<std::string, std::string>* overrides = nullptr;
    bool analyzeWithParseErrors = false;  // seguir con el análisis semántico aunque haya errores de sintaxis
    bool ideMode = false;                 // registrar referencias y autocompletado
    std::set<std::string> defines = {"FASET", "LINUX", "DEBUG"};  // compilación condicional
    // Archivos (rutas normalizadas) que son por completo un contexto memory_unsafe:
    // los de proyectos con <AllowUnsafe>true</AllowUnsafe> o compilados con --allow-unsafe.
    std::set<std::string> unsafeFiles;
};

// Símbolos de compilación condicional para una plataforma y configuración.
std::set<std::string> definesFor(const std::string& target, const std::string& configuration);

struct FrontendResult {
    Program* prog = nullptr;
    TypeCtx* tc = nullptr;
    Sema* sema = nullptr;  // nulo si no se llegó al análisis semántico
    bool ok = false;       // sin errores
};

FrontendResult runFrontend(const FrontendOptions& opts);

// Ruta absoluta normalizada (clave para comparar archivos).
std::string normalizePath(const std::string& path);

// Busca un programa en el PATH.
std::string findProgram(const std::string& name);
// Ruta del ejecutable actual.
std::string selfExePath(const std::string& argv0);
// Carpeta de la biblioteca estándar, o "" si no se encuentra.
std::string findLibDir(const std::string& argv0);

// Rutas del sistema <-> UTF-8. En Windows las cadenas estrechas de std::filesystem, argv y getenv
// están en la página de códigos ANSI (cp1252...), no en UTF-8; en el resto no cambian.
std::string nativeToUtf8(const std::string& s);
std::string utf8ToNative(const std::string& s);

#if defined(_WIN32)
// Entrecomilla un argumento según las reglas del CRT de Windows (CommandLineToArgvW): las '\'
// antes de una comilla se duplican y las comillas internas se escapan.
std::string windowsQuote(const std::string& arg);
// Ejecuta un programa con argumentos (CreateProcessW, sin cmd.exe: sin el límite de 8191
// caracteres ni la expansión de %VAR%), heredando la consola. Devuelve el código de salida, o -1
// si no arranca. Las cadenas están en la página de códigos ANSI, como las de std::filesystem.
int runProgramWindows(const std::vector<std::string>& args);
#endif
