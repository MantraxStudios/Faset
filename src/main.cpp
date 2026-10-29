// Faset - interfaz de línea de comandos.
//
//   faset new <Nombre> [--lib | --winexe]   crea un proyecto (.fstproj)
//   faset build [proyecto|archivos]         compila a un ejecutable nativo
//   faset run   [proyecto|archivos] [-- args]
//   faset check [proyecto|archivos]
//   faset emit-c [proyecto|archivos] [-o x.c]
//   faset clean [proyecto]
//   faset android <devices|avds|emulator|logcat|stop|uninstall>
//   faset doctor | setup | version | help
#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <memory>
#include <random>
#include <sstream>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#else
#include <sys/wait.h>
#endif

#include "Android.h"
#include "Setup.h"
#include "CodeGen.h"
#include "Frontend.h"
#include "Lsp.h"
#include "Lexer.h"
#include "Packages.h"
#include "Parser.h"
#include "Project.h"
#include "Runtime.h"
#include "Sema.h"
#include "Solution.h"
#include "Xml.h"

namespace fs = std::filesystem;

static const char* const kVersion = "0.3.0";

#if defined(_WIN32)
static const char* const kHostOS = "windows";
#elif defined(__APPLE__)
static const char* const kHostOS = "macos";
#else
static const char* const kHostOS = "linux";
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
static const char* const kHostArch = "arm64";
#elif defined(__i386__) || defined(_M_IX86)
static const char* const kHostArch = "x86";
#else
static const char* const kHostArch = "x86_64";
#endif

struct Options {
    std::string command;
    std::vector<std::string> inputs;
    std::string output;
    std::string target;  // vacío = del proyecto o nativo
    std::string arch;
    int androidApi = 0;
    int shared = -1, debug = -1, gui = -1, staticLink = -1;  // -1 = no indicado
    int checks = -1;          // comprobaciones en ejecución; -1 = según la configuración
    bool allowUnsafe = false;  // --allow-unsafe: todos los archivos son memory_unsafe
    std::set<std::string> unsafeFiles;  // archivos de proyectos con <AllowUnsafe>
    bool keepC = false, verbose = false, sanitize = false;
    std::string cc;
    std::string device;      // Android: número de serie para 'run'
    bool archGiven = false;  // --arch o <TargetArch> explícitos
    std::vector<std::string> androidPermissions;
    bool noApk = false;      // Android: ejecutable ELF suelto en vez de APK
    std::string configuration;
    std::vector<std::string> libs, libDirs;
    std::vector<std::string> extraC;  // fuentes C de los módulos (lib/std/ui/*.c)
    std::vector<std::string> uiAssets;  // imágenes de los .fstui (Source/Icon), relativas a la entrada
    std::vector<std::string> runArgs;
    std::vector<std::pair<std::string, std::string>> platformLibs;  // (biblioteca, plataforma)
    std::vector<std::string> extraSources;  // C de la biblioteca estándar (p. ej. el WebView de std.ui)
    bool video = false;      // el programa usa std.video (VideoPlayer): se compila su runtime
    std::vector<std::string> cSources;  // fuentes C de la biblioteca estándar (p. ej. lib/audio/faset_audio.c)
    std::vector<std::pair<std::string, std::string>> assets;  // <Asset Include="..."/>: (ruta relativa, archivo)
    bool singleFile = false;
    Project* project = nullptr;
    std::string argv0;
};

// ------------------------------------------------------------------ utilidades

static void usage() {
    std::printf(
        "Faset %s - lenguaje nativo que mezcla C# y C++\n\n"
        "Uso:\n"
        "  faset new <Nombre> [plantilla]        Crea un proyecto (Nombre/Nombre.fstproj)\n"
        "         plantillas: --console (por defecto), --lib [--package], --winexe, --ui (AppUI),\n"
        "                     --android (AppUI para Android), --android --console\n"
        "  faset build  [entrada] [opciones]     Compila a un ejecutable nativo\n"
        "  faset run    [entrada] [-- args]      Compila y ejecuta\n"
        "  faset check  [entrada]                Comprueba errores sin compilar\n"
        "  faset emit-c [entrada] [-o f.c]       Genera el código C intermedio\n"
        "  faset clean  [proyecto]               Borra bin/ y obj/\n"
        "  faset new sln [Nombre]                Crea una solución .fstp (sin nombre: en la carpeta actual)\n"
        "  faset new <Nombre> --solution [...]   Solución con un primer proyecto (Nombre/Nombre.fstp)\n"
        "  faset sln <orden>                     add, remove, list, startup, folder, move, rename, ref\n"
        "                                        (faset sln help)\n"
        "  faset add <paquete> [--version X]     Añade un paquete: nombre del índice, URL git o carpeta\n"
        "                                        (faset add --help)\n"
        "  faset remove <paquete>                Quita un paquete del .fstproj\n"
        "  faset restore [proyecto|solución]     Descarga los paquetes (respeta paquetes.lock)\n"
        "  faset update [paquete]                Busca versiones nuevas y actualiza paquetes.lock\n"
        "  faset list paquetes [--json]          Árbol de dependencias resuelto\n"
        "  faset pack | faset publish            Comprueba los metadatos de un paquete y explica cómo publicarlo\n"
        "  faset android <comando>               devices, avds, emulator, logcat, stop, uninstall\n"
        "                                        (faset android help)\n"
        "  faset doctor                          Muestra los compiladores y el SDK de Android detectados\n"
        "  faset setup [linux|windows|android|multimedia|all] [--list] [--yes]\n"
        "                                        Instala lo que necesita cada plataforma (sin módulo: la actual)\n"
        "  faset lsp                             Servidor de lenguaje (para VS Code y otros editores)\n"
        "  faset version | help\n\n"
        "Entrada: un .fstproj, una solución .fstp, una carpeta con uno de ellos, o archivos .fst sueltos.\n"
        "         Sin entrada se usa el .fstproj de la carpeta actual (o su .fstp si no hay .fstproj).\n"
        "         Con una solución se compilan todos sus proyectos en orden de dependencias,\n"
        "         'run' ejecuta el proyecto de inicio y -o se aplica a ese proyecto.\n\n"
        "Opciones:\n"
        "  -o <ruta>            Archivo de salida\n"
        "  -c <Debug|Release>   Configuración\n"
        "  --target <t>         native, linux, windows, android\n"
        "  --arch <a>           x86_64, x86, arm64, armv7\n"
        "  --api <n>            Nivel de API mínimo de Android (por defecto 24)\n"
        "  --device <serie>     Android: dispositivo para 'run' (ver 'faset android devices')\n"
        "  --no-apk             Android: ejecutable ELF suelto en vez de un APK\n"
        "  --shared             Biblioteca (.so / .dll)\n"
        "  --gui                Windows: aplicación de ventana (sin consola)\n"
        "  --static             Enlazado estático\n"
        "  --debug / --release  Atajos de -c Debug / -c Release\n"
        "  --cc <compilador>    Compilador de C (también: variable FASET_CC)\n"
        "  -l <lib>  -L <dir>   Bibliotecas nativas\n"
        "  --checks/--no-checks Diagnósticos extra: uso tras delete y delete doble (por defecto\n"
        "                       solo en Debug; nulos, índices y división por cero se comprueban siempre)\n"
        "  --allow-unsafe       Trata todos los archivos como contexto memory_unsafe\n"
        "  --sanitize           Detecta errores de memoria en ejecución (ASan + UBSan)\n"
        "  --keep-c             Conserva el C generado junto a la salida\n"
        "  -v, --verbose        Muestra los comandos ejecutados\n\n"
        "Android: 'faset build --target android' genera un APK firmado (bin/<Config>/android/<App>.apk)\n"
        "y 'faset run --target android' lo instala, lo abre y muestra su logcat.\n",
        kVersion);
}

static bool writeFile(const fs::path& path, const std::string& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << data;
    return (bool)f;
}

static bool readText(const fs::path& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

static std::string quote(const std::string& s) {
#if defined(_WIN32)
    return "\"" + s + "\"";
#else
    std::string r = "'";
    for (char c : s) r += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return r + "'";
#endif
}

static int runCommand(const std::vector<std::string>& args, bool verbose) {
    std::string cmd;
    for (size_t i = 0; i < args.size(); i++) cmd += (i ? " " : "") + quote(args[i]);
    if (verbose) std::fprintf(stderr, "$ %s\n", cmd.c_str());
#if defined(_WIN32)
    cmd = "\"" + cmd + "\"";  // cmd.exe elimina las comillas exteriores
#endif
    std::fflush(stdout);
    int r = std::system(cmd.c_str());
#if !defined(_WIN32)
    if (r != -1 && WIFEXITED(r)) r = WEXITSTATUS(r);
#endif
    return r;
}

static std::string envOr(const char* name) {
    const char* v = std::getenv(name);
    return v ? v : "";
}

static std::string resolveCompiler(const Options& o, std::string& why) {
    if (!o.cc.empty()) return o.cc;
    if (!envOr("FASET_CC").empty()) return envOr("FASET_CC");
    const std::string& t = o.target;
    if (t == "android") {
        std::string ndk = findAndroidNdk();
        if (ndk.empty()) {
            why = "no se encontró el Android NDK; instálalo con 'sdkmanager --install \"ndk;<versión>\"' (queda en "
                  "<SDK>/ndk/<versión>) o define ANDROID_NDK_HOME";
            return "";
        }
#if defined(_WIN32)
        std::string hostTag = "windows-x86_64", ext = ".cmd";
#elif defined(__APPLE__)
        std::string hostTag = "darwin-x86_64", ext = "";
#else
        std::string hostTag = "linux-x86_64", ext = "";
#endif
        fs::path cc = fs::path(ndk) / "toolchains" / "llvm" / "prebuilt" / hostTag / "bin" /
                      (androidTriple(o.arch) + std::to_string(o.androidApi) + "-clang" + ext);
        if (!fs::exists(cc)) {
            why = "no existe " + cc.string() + " (¿nivel de API o arquitectura no soportados por tu NDK?)";
            return "";
        }
        return cc.string();
    }
    if (t == kHostOS && o.arch == kHostArch) {
        for (const char* c : {"cc", "gcc", "clang"})
            if (!findProgram(c).empty()) return c;
        // Windows: el toolchain llvm-mingw de 'faset setup windows'.
        if (t == "windows" && !managedMingwCompiler(o.arch).empty()) return managedMingwCompiler(o.arch);
        why = std::string("no se encontró un compilador de C: ejecuta 'faset setup") + (t == "windows" ? " windows'" : "' (o instala gcc o clang)");
        return "";
    }
    if (t == "windows") {
        std::string triple = o.arch == "x86" ? "i686-w64-mingw32" : o.arch == "arm64" ? "aarch64-w64-mingw32" : "x86_64-w64-mingw32";
        for (const std::string& c : {triple + "-gcc", triple + "-clang"})
            if (!findProgram(c).empty()) return c;
        if (!managedMingwCompiler(o.arch).empty()) return managedMingwCompiler(o.arch);
        why = "no se encontró " + triple + "-gcc: ejecuta 'faset setup windows' (descarga llvm-mingw) o 'sudo apt install mingw-w64'";
        return "";
    }
    if (t == "linux") {
        std::string triple = o.arch == "arm64" ? "aarch64-linux-gnu" : o.arch == "armv7" ? "arm-linux-gnueabihf"
                             : o.arch == "x86" ? "i686-linux-gnu" : "x86_64-linux-gnu";
        std::string c = triple + "-gcc";
        if (!findProgram(c).empty()) return c;
        why = "no se encontró " + c + " para compilación cruzada";
        return "";
    }
    why = "no se puede compilar para '" + t + "' desde " + kHostOS;
    return "";
}

static void collectInputs(const std::string& p, std::vector<std::string>& out) {
    std::error_code ec;
    if (fs::is_directory(p, ec)) {
        std::vector<std::string> found;
        for (auto& e : fs::recursive_directory_iterator(p, ec))
            if (e.is_regular_file() && (e.path().extension() == ".fst" || e.path().extension() == ".fstui")) found.push_back(e.path().string());
        std::sort(found.begin(), found.end());
        out.insert(out.end(), found.begin(), found.end());
    } else {
        out.push_back(p);
    }
}

static std::string findProjectIn(const fs::path& dir) {
    std::error_code ec;
    std::vector<std::string> found;
    for (auto& e : fs::directory_iterator(dir, ec))
        if (e.path().extension() == ".fstproj") found.push_back(e.path().string());
    if (found.size() > 1) {
        diag.fatal("hay varios .fstproj en '" + dir.string() + "'; indica cuál compilar");
        std::exit(1);
    }
    return found.empty() ? "" : found[0];
}

// ------------------------------------------------------------------ proyectos

// Carga el proyecto y sus referencias; reúne archivos y bibliotecas nativas.
static bool loadProjectTree(const std::string& path, Options& o) {
    std::vector<std::string> stack;
    std::set<std::string> done;
    std::function<bool(const std::string&, bool)> visit = [&](const std::string& p, bool isRoot) -> bool {
        std::string key = fs::weakly_canonical(p).string();
        if (std::find(stack.begin(), stack.end(), key) != stack.end()) {
            diag.fatal("referencia circular entre proyectos: " + key);
            return false;
        }
        if (!done.insert(key).second) return true;
        auto* proj = new Project();
        std::string err;
        if (!loadProject(p, *proj, err)) {
            diag.fatal(err);
            return false;
        }
        if (!isRoot && proj->prop("OutputType", "Exe") != "Library") {
            diag.fatal("'" + p + "' está referenciado como dependencia pero su OutputType no es Library");
            return false;
        }
        if (isRoot) o.project = proj;
        if (isRoot) {
            // <PackageReference>: se restauran (paquetes.lock + caché) y cuentan como ProjectReference.
            std::vector<std::string> pkgs;
            if (!packagesForBuild(p, pkgs, err)) {
                diag.fatal(err);
                return false;
            }
            proj->references.insert(proj->references.end(), pkgs.begin(), pkgs.end());
        }
        stack.push_back(key);
        for (const std::string& ref : proj->references) {
            if (!fs::exists(ref)) {
                diag.fatal(proj->path + ": no existe el proyecto referenciado '" + ref + "'");
                return false;
            }
            if (!visit(ref, false)) return false;
        }
        stack.pop_back();
        bool allowUnsafe = proj->boolProp("AllowUnsafe", false);
        for (const std::string& f : projectSources(*proj)) {
            if (std::find(o.inputs.begin(), o.inputs.end(), f) == o.inputs.end()) o.inputs.push_back(f);
            if (allowUnsafe) o.unsafeFiles.insert(normalizePath(f));
        }
        o.libs.insert(o.libs.end(), proj->nativeLibs.begin(), proj->nativeLibs.end());
        o.platformLibs.insert(o.platformLibs.end(), proj->platformLibs.begin(), proj->platformLibs.end());
        o.libDirs.insert(o.libDirs.end(), proj->libPaths.begin(), proj->libPaths.end());
        for (const std::string& perm : proj->androidPermissions)
            if (std::find(o.androidPermissions.begin(), o.androidPermissions.end(), perm) == o.androidPermissions.end())
                o.androidPermissions.push_back(perm);
        for (const auto& a : projectAssets(*proj))
            if (std::none_of(o.assets.begin(), o.assets.end(), [&](const auto& b) { return b.first == a.first; }))
                o.assets.push_back(a);
        return true;
    };
    return visit(path, true);
}

static void applyProjectSettings(Options& o) {
    Project* p = o.project;
    if (!p) return;
    if (o.target.empty()) o.target = p->prop("TargetPlatform", "native");
    if (o.arch.empty()) o.arch = p->prop("TargetArch");
    if (o.androidApi == 0) o.androidApi = std::atoi(p->prop("AndroidApi", "0").c_str());
    std::string ot = p->prop("OutputType", "Exe");
    if (o.shared < 0) o.shared = ot == "Library";
    if (o.gui < 0) o.gui = ot == "WinExe";
    if (o.staticLink < 0) o.staticLink = p->boolProp("StaticLink", false);
    if (o.configuration.empty()) o.configuration = p->prop("Configuration", "Debug");
    if (o.checks < 0 && !p->prop("RuntimeChecks").empty()) o.checks = p->boolProp("RuntimeChecks", false);
}

// ------------------------------------------------------------------ compilación

// ¿Usa el programa el control WebView? (un <WebView> en un .fstui o WidgetKind.WebView en el código)
static bool usesWebView(const std::vector<std::string>& inputs) {
    for (const std::string& f : inputs) {
        std::ifstream in(f, std::ios::binary);
        std::string src((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        if (src.find("<WebView") != std::string::npos || src.find("WidgetKind.WebView") != std::string::npos) return true;
    }
    return false;
}

static bool frontEnd(Options& o, std::string* csrc) {
    FrontendOptions fo;
    fo.inputs = o.inputs;
    fo.defines = definesFor(o.target, o.configuration);
    if (o.checks == 1) fo.defines.insert("RUNTIME_CHECKS");
    fo.libDir = findLibDir(o.argv0);
    fo.unsafeFiles = o.unsafeFiles;
    if (o.allowUnsafe)
        for (const std::string& f : o.inputs) fo.unsafeFiles.insert(normalizePath(f));
    if (fo.libDir.empty()) {
        diag.fatal("no se encontró la biblioteca estándar (carpeta 'lib' con std/core.fst); define FASET_LIB");
        return false;
    }
    FrontendResult r = runFrontend(fo);
    if (!r.sema || !r.ok) return false;
    if (!r.sema->entry && o.shared != 1 && o.command != "check") {
        diag.fatal("no se encontró el punto de entrada ('static void Main()' o 'void main()'); para una biblioteca usa "
                   "OutputType=Library o --shared");
        return false;
    }
    // Bibliotecas del sistema que necesitan algunos módulos de la biblioteca estándar.
    for (const std::string& mod : r.prog->requestedModules) {
        std::vector<std::string> need;
        if (mod == "std.ui")
            need = o.target == "windows" ? std::vector<std::string>{"user32", "gdi32"}
                 : o.target == "android" ? std::vector<std::string>{"android", "log"}
                                         : std::vector<std::string>{"X11", "freetype"};
        else if (mod == "std.thread" && o.target != "windows" && o.target != "android")
            need = {"pthread"};  // en Android y Windows los hilos están en la biblioteca de C / kernel32
        else if (mod == "std.net") {
            // TLS en C: Schannel en Windows, OpenSSL con dlopen en Linux y BearSSL en Android.
            need = o.target == "windows" ? std::vector<std::string>{"ws2_32", "secur32"}
                 : o.target == "android" ? std::vector<std::string>{}
                                         : std::vector<std::string>{"dl"};
            std::string c = (fs::path(fo.libDir) / "net" / "faset_tls.c").string();
            if (std::find(o.cSources.begin(), o.cSources.end(), c) == o.cSources.end()) o.cSources.push_back(c);
        }
        else if (mod == "std.video") {
            o.video = true;  // GStreamer / libmediandk se cargan con dlopen
            if (o.target != "windows" && o.target != "android") need = {"dl", "pthread"};
        }
        else if (mod == "std.audio") {
            // Mezclador en C; PulseAudio/ALSA (Linux) y AAudio (Android) se cargan con dlopen.
            need = o.target == "windows" ? std::vector<std::string>{"winmm"}
                 : o.target == "android" ? std::vector<std::string>{"OpenSLES", "android", "log"}
                                         : std::vector<std::string>{"dl", "pthread"};
            std::string c = (fs::path(fo.libDir) / "audio" / "faset_audio.c").string();
            if (std::find(o.cSources.begin(), o.cSources.end(), c) == o.cSources.end()) o.cSources.push_back(c);
        }
        for (const std::string& l : need)
            if (std::find(o.libs.begin(), o.libs.end(), l) == o.libs.end()) o.libs.push_back(l);
        // Un módulo puede traer código C en la carpeta del mismo nombre (lib/std/ui/*.c).
        std::string rel = mod;
        std::replace(rel.begin(), rel.end(), '.', '/');
        fs::path dir = fs::path(fo.libDir) / rel;
        std::error_code dec;
        if (fs::exists(fs::path(fo.libDir) / (rel + ".fst"), dec) && fs::is_directory(dir, dec)) {
            std::vector<std::string> found;
            for (auto& e : fs::directory_iterator(dir, dec))
                if (e.is_regular_file() && e.path().extension() == ".c") found.push_back(e.path().string());
            std::sort(found.begin(), found.end());
            for (const std::string& f : found)
                if (std::find(o.extraC.begin(), o.extraC.end(), f) == o.extraC.end()) o.extraC.push_back(f);
        }
    }
    // std.ui: capa nativa del WebView (WebKitGTK en Linux con dlopen, android.webkit en Android).
    if (r.prog->requestedModules.count("std.ui") && o.target != "windows") {
        fs::path c = fs::path(fo.libDir) / (o.target == "android" ? "android" : "linux") / "faset_webview.c";
        if (fs::exists(c) && std::find(o.extraSources.begin(), o.extraSources.end(), c.string()) == o.extraSources.end())
            o.extraSources.push_back(c.string());
        if (o.target != "android" && std::find(o.libs.begin(), o.libs.end(), "dl") == o.libs.end()) o.libs.push_back("dl");
        // Android: un WebView carga páginas de la red, así que la app necesita el permiso INTERNET.
        if (o.target == "android" && usesWebView(o.inputs) &&
            std::find(o.androidPermissions.begin(), o.androidPermissions.end(), "INTERNET") == o.androidPermissions.end() &&
            std::find(o.androidPermissions.begin(), o.androidPermissions.end(), "android.permission.INTERNET") == o.androidPermissions.end())
            o.androidPermissions.push_back("INTERNET");
    }
    // Android: std.net hace peticiones de red (HTTP/HTTPS), así que la app necesita el permiso INTERNET.
    if (r.prog->requestedModules.count("std.net") && o.target == "android" &&
        std::find(o.androidPermissions.begin(), o.androidPermissions.end(), "INTERNET") == o.androidPermissions.end() &&
        std::find(o.androidPermissions.begin(), o.androidPermissions.end(), "android.permission.INTERNET") == o.androidPermissions.end())
        o.androidPermissions.push_back("INTERNET");
    if (csrc) {
        CodeGen cg(*r.prog, *r.sema, *r.tc);
        cg.checks = o.checks == 1;
        *csrc = cg.generate(o.shared == 1);
    }
    return true;
}

static std::string defaultOutput(const Options& o) {
    std::string stem;
    fs::path dir;
    if (o.project) {
        stem = o.project->prop("AssemblyName", fs::path(o.project->path).stem().string());
        fs::path outRoot = o.project->prop("OutputPath", "bin");
        dir = fs::path(o.project->dir) / outRoot / o.configuration / (o.target + "-" + o.arch);
    } else if (o.singleFile) {
        stem = fs::path(o.inputs[0]).stem().string();
    } else {
        stem = fs::current_path().filename().string();
    }
    if (stem.empty()) stem = "app";
    std::string name;
    if (o.shared == 1) name = o.target == "windows" ? stem + ".dll" : "lib" + stem + ".so";
    else name = o.target == "windows" ? stem + ".exe" : stem;
    return dir.empty() ? name : (dir / name).string();
}

// std.net en Android: TLS con BearSSL (lib/net/bearssl). Se compila una sola vez por compilador
// y arquitectura en <datos de faset>/cache/bearssl/ y se enlaza como biblioteca estática ("" si falla).
static std::string bearsslArchive(const Options& o, const std::string& cc) {
    fs::path root = fs::path(findLibDir(o.argv0)) / "net" / "bearssl";
    std::error_code ec;
    if (!fs::is_directory(root / "src", ec)) {
        diag.fatal("falta " + (root / "src").string() + " (BearSSL, para TLS en Android)");
        return "";
    }
    char key[32];
    std::snprintf(key, sizeof key, "%016llx",
                  (unsigned long long)std::hash<std::string>{}(cc + "|" + o.arch + "|" + fs::absolute(root).string()));
    fs::path dir = fs::path(fasetDataDir()) / "cache" / "bearssl" / key;
    fs::path lib = dir / "libfaset_bearssl.a";
    if (fs::exists(lib, ec)) return lib.string();
    std::vector<std::string> sources;
    for (auto it = fs::recursive_directory_iterator(root / "src", ec); it != fs::recursive_directory_iterator(); it.increment(ec))
        if (it->is_regular_file(ec) && it->path().extension() == ".c") sources.push_back(it->path().generic_string());
    std::sort(sources.begin(), sources.end());
    fs::path obj = dir / "obj";
    fs::remove_all(obj, ec);
    fs::create_directories(obj, ec);
    std::fprintf(stderr, "faset: compilando BearSSL para TLS (%s, solo la primera vez)...\n", o.arch.c_str());
    // Archivos de respuesta (@archivo): la lista no cabe en la línea de órdenes de Windows.
    auto rsp = [](const fs::path& f, const std::vector<std::string>& args) {
        std::string t;
        for (const std::string& a : args) t += "\"" + a + "\"\n";
        return writeFile(f, t);
    };
    std::vector<std::string> args = {"-std=gnu11", "-O2", "-w", "-fPIC", "-I" + (root / "inc").generic_string(),
                                     "-I" + (root / "src").generic_string(), "-c"};
    args.insert(args.end(), sources.begin(), sources.end());
    std::vector<std::string> objs;
    for (const std::string& s : sources) objs.push_back((obj / fs::path(s).filename().replace_extension(".o")).generic_string());
    fs::path ar = fs::path(cc).parent_path() / "llvm-ar";
#if defined(_WIN32)
    ar += ".exe";
#endif
    fs::path tmpLib = dir / "libfaset_bearssl.tmp.a";
    if (!rsp(dir / "cc.rsp", args) || !rsp(dir / "ar.rsp", objs)) {
        diag.fatal("no se pudo escribir en " + dir.string());
        return "";
    }
    fs::path old = fs::current_path(ec);
    fs::current_path(obj, ec);  // 'clang -c' deja los .o en la carpeta actual
    int r = runCommand({cc, "@" + (dir / "cc.rsp").string()}, o.verbose);
    fs::current_path(old, ec);
    if (r == 0) r = runCommand({ar.string(), "rcs", tmpLib.string(), "@" + (dir / "ar.rsp").string()}, o.verbose);
    if (r != 0) {
        diag.fatal("no se pudo compilar BearSSL (código " + std::to_string(r) + "); usa -v para ver el comando");
        return "";
    }
    fs::rename(tmpLib, lib, ec);
    std::error_code ignore;
    fs::remove_all(obj, ignore);
    fs::remove(dir / "cc.rsp", ignore);
    fs::remove(dir / "ar.rsp", ignore);
    if (ec) {
        diag.fatal("no se pudo crear " + lib.string());
        return "";
    }
    return lib.string();
}

// Compila el C generado (y fuentes C adicionales) con el compilador del objetivo.
static int compileC(const Options& o, const std::string& csrc, const std::string& outPath,
                    const std::vector<std::string>& extraSources = {}, const std::vector<std::string>& extraArgs = {}) {
    std::string why;
    std::string cc = resolveCompiler(o, why);
    if (cc.empty()) {
        diag.fatal(why);
        return 1;
    }
    std::error_code ec;
    if (fs::path(outPath).has_parent_path()) fs::create_directories(fs::path(outPath).parent_path(), ec);

    std::mt19937_64 rng((uint64_t)std::chrono::steady_clock::now().time_since_epoch().count());
    fs::path tmp = fs::temp_directory_path() / ("faset-" + std::to_string(rng() % 100000000));
    fs::create_directories(tmp);
    std::string stem = fs::path(outPath).stem().string();
    fs::path mainC = tmp / (stem + ".c");
    fs::path rtC = tmp / "faset_rt.c";
    fs::path gcC = tmp / "faset_gc.c";
    std::string runtime = std::string(kRuntimeSource) + kRuntimeOsSource + kRuntimeSugarSource;
    if (o.video) runtime += kRuntimeVideoSource;
    runtime += kRuntimeExcSource;
    if (!writeFile(mainC, csrc) || !writeFile(tmp / "faset_rt.h", std::string(kRuntimeHeader) + kRuntimeExcHeader) ||
        !writeFile(rtC, runtime) ||
        !writeFile(gcC, kRuntimeGcSource)) {
        diag.fatal("no se pudo escribir en " + tmp.string());
        return 1;
    }

    std::vector<std::string> cmd = {cc, "-std=c11", "-fwrapv", "-fno-strict-aliasing", "-w"};
    if (o.debug == 1) {
        cmd.push_back("-O0");
        cmd.push_back("-g");
    } else {
        cmd.push_back("-O2");
    }
    if (o.shared == 1) {
        cmd.push_back("-shared");
        if (o.target != "windows") cmd.push_back("-fPIC");
    }
    if (o.gui == 1 && o.target == "windows") cmd.push_back("-mwindows");
    if (o.staticLink == 1) cmd.push_back("-static");
    if (o.checks == 1) cmd.push_back("-DFASET_CHECKS=1");
    if (o.sanitize) {
        cmd.push_back("-fsanitize=address,undefined");
        cmd.push_back("-fno-omit-frame-pointer");
        if (o.debug != 1) cmd.push_back("-g");
    }
    cmd.push_back(mainC.string());
    cmd.push_back(rtC.string());
    cmd.push_back(gcC.string());
    cmd.insert(cmd.end(), extraSources.begin(), extraSources.end());
    cmd.insert(cmd.end(), o.extraSources.begin(), o.extraSources.end());
    cmd.insert(cmd.end(), o.cSources.begin(), o.cSources.end());
    cmd.insert(cmd.end(), o.extraC.begin(), o.extraC.end());
    if (o.target == "android" && std::any_of(o.cSources.begin(), o.cSources.end(), [](const std::string& f) {
            return fs::path(f).filename() == "faset_tls.c";
        })) {
        std::string bear = bearsslArchive(o, cc);
        if (bear.empty()) return 1;
        cmd.push_back(bear);
    }
    cmd.push_back("-o");
    cmd.push_back(outPath);
    cmd.insert(cmd.end(), extraArgs.begin(), extraArgs.end());
    for (const std::string& d : o.libDirs) cmd.push_back("-L" + d);
    for (const std::string& l : o.libs) cmd.push_back("-l" + l);
    cmd.push_back("-lm");
    if (o.target != "windows" && o.target != "android") cmd.push_back("-pthread");  // el recolector usa hilos

    int r = runCommand(cmd, o.verbose);
    if (o.keepC) fs::copy_file(mainC, fs::path(outPath).replace_extension(".c"), fs::copy_options::overwrite_existing, ec);
    fs::remove_all(tmp, ec);
    if (r != 0) {
        diag.fatal("el compilador de C falló (código " + std::to_string(r) + "); usa -v para ver el comando");
        return 1;
    }
    return 0;
}

// ------------------------------------------------------------------ imágenes de la interfaz

// Archivos que la interfaz carga en ejecución: la carpeta Assets/ del proyecto y las imágenes que
// nombran los .fstui (Source, Icon). Devuelve (ruta relativa al proyecto, archivo local).
static std::vector<std::pair<std::string, std::string>> uiAssets(const Options& o) {
    std::vector<std::pair<std::string, std::string>> out;
    fs::path base = o.project ? fs::path(o.project->dir)
                    : o.singleFile ? fs::absolute(o.inputs[0]).parent_path()
                                   : fs::current_path();
    std::set<std::string> seen;
    std::error_code ec;
    auto add = [&](const std::string& rel) {
        fs::path r = fs::path(rel).lexically_normal();
        if (rel.empty() || r.is_absolute() || r.generic_string().rfind("..", 0) == 0) return;
        fs::path local = base / r;
        if (!fs::is_regular_file(local, ec) || !seen.insert(r.generic_string()).second) return;
        out.push_back({r.generic_string(), local.string()});
    };
    fs::path assets = base / "Assets";
    if (fs::is_directory(assets, ec)) {
        std::vector<std::string> found;
        for (auto it = fs::recursive_directory_iterator(assets, ec); it != fs::recursive_directory_iterator(); it.increment(ec))
            if (it->is_regular_file(ec)) found.push_back(fs::relative(it->path(), base, ec).generic_string());
        std::sort(found.begin(), found.end());
        for (const std::string& f : found) add(f);
    }
    std::function<void(const XmlNode&)> walk = [&](const XmlNode& n) {
        for (const char* key : {"Source", "Icon"}) {
            auto it = n.attrs.find(key);
            if (it != n.attrs.end()) add(it->second);
        }
        for (const XmlNode& c : n.children) walk(c);
    };
    for (const std::string& in : o.inputs) {
        if (fs::path(in).extension() != ".fstui") continue;
        std::string xml, err;
        XmlNode root;
        if (readText(in, xml) && parseXml(xml, root, err)) walk(root);
    }
    return out;
}

// Copia las imágenes de la interfaz junto al ejecutable (conservando la ruta relativa).
static void copyUiAssets(const Options& o, const std::string& outPath) {
    fs::path dir = fs::absolute(outPath).parent_path();
    std::error_code ec;
    for (auto& [rel, local] : uiAssets(o)) {
        fs::path dest = dir / rel;
        if (fs::exists(dest, ec) && fs::equivalent(dest, local, ec)) continue;
        fs::create_directories(dest.parent_path(), ec);
        fs::copy_file(local, dest, fs::copy_options::update_existing, ec);
    }
}

// ------------------------------------------------------------------ Android (APK)

static std::string androidName(const Options& o) {
    std::string stem = o.project ? o.project->prop("AssemblyName", fs::path(o.project->path).stem().string())
                       : o.singleFile ? fs::path(o.inputs[0]).stem().string()
                                      : fs::current_path().filename().string();
    std::string n;
    for (char c : stem) n += isalnum((unsigned char)c) || c == '_' ? c : '_';
    return n.empty() ? "app" : n;
}

// Paquete de la app: <AndroidPackage> o com.faset.<nombre en minúsculas>.
static std::string androidPackage(const Options& o) {
    if (o.project && !o.project->prop("AndroidPackage").empty()) return o.project->prop("AndroidPackage");
    std::string n;
    for (char c : androidName(o)) n += isalnum((unsigned char)c) ? (char)tolower((unsigned char)c) : '_';
    if (n.empty() || !isalpha((unsigned char)n[0])) n = "app" + n;
    return "com.faset." + n;
}

static std::vector<std::string> splitSemicolons(const std::string& v) {
    std::vector<std::string> out;
    std::stringstream ss(v);
    std::string item;
    while (std::getline(ss, item, ';')) {
        item.erase(0, item.find_first_not_of(" \t\r\n,"));
        item.erase(item.find_last_not_of(" \t\r\n,") + 1);
        if (!item.empty()) out.push_back(item);
    }
    return out;
}

static std::string replaceAll(std::string s, const std::string& from, const std::string& to) {
    for (size_t k = s.find(from); k != std::string::npos; k = s.find(from, k + to.size())) s.replace(k, from.size(), to);
    return s;
}

// Compila lib<App>.so para cada ABI y lo empaqueta en un APK firmado (NativeActivity, sin Gradle).
static int buildApk(Options& o, const std::string& csrc, std::string& outPath) {
    Project* p = o.project;
    std::string name = androidName(o);
    std::string libDir = findLibDir(o.argv0);
    fs::path glueC = fs::path(libDir) / "android" / "faset_android.c";
    std::string ndk = findAndroidNdk();
    if (ndk.empty()) {
        std::string why;
        resolveCompiler(o, why);
        diag.fatal(why.empty() ? "no se encontró el Android NDK" : why);
        return 1;
    }
    fs::path appGlue = fs::path(ndk) / "sources" / "android" / "native_app_glue";
    if (!fs::exists(glueC) || !fs::exists(appGlue / "android_native_app_glue.c")) {
        diag.fatal("falta " + (fs::exists(glueC) ? (appGlue / "android_native_app_glue.c").string() : glueC.string()));
        return 1;
    }

    // ABIs: --arch, <TargetArch>, <AndroidAbis> o arm64-v8a + x86_64 (móviles y el emulador).
    std::vector<std::string> abis;
    if (o.archGiven) abis.push_back(androidArchToAbi(o.arch));
    else abis = splitSemicolons(p ? p->prop("AndroidAbis", "arm64-v8a;x86_64") : "arm64-v8a;x86_64");
    for (const std::string& abi : abis)
        if (androidAbiToArch(abi).empty()) {
            diag.fatal("ABI de Android desconocida '" + abi + "' (usa arm64-v8a, armeabi-v7a, x86 o x86_64)");
            return 1;
        }

    fs::path objDir = p ? fs::path(p->dir) / "obj" / o.configuration / "android"
                        : fs::temp_directory_path() / ("faset-apk-" + name);
    fs::path outRoot = p ? fs::path(p->dir) / p->prop("OutputPath", "bin") / o.configuration / "android" : fs::path();
    outPath = !o.output.empty() ? o.output : (outRoot / (name + ".apk")).string();
    if (fs::path(outPath).extension() != ".apk") outPath += ".apk";
    std::error_code ec;
    fs::create_directories(objDir, ec);
    fs::path tagC = objDir / "faset_app.c";
    std::string tagSrc = "/* Generado por faset. */\nconst char faset_android_tag[] = \"" +
                         replaceAll(replaceAll(name, "\\", "\\\\"), "\"", "\\\"") + "\";\n";
    if (!writeFile(tagC, tagSrc)) {
        diag.fatal("no se pudo escribir " + tagC.string());
        return 1;
    }

    ApkSpec spec;
    for (const std::string& abi : abis) {
        Options oa = o;
        oa.arch = androidAbiToArch(abi);
        oa.shared = 0;  // el C conserva 'main'; se enlaza como biblioteca compartida
        for (std::string& d : oa.libDirs) d = replaceAll(d, "$(AndroidAbi)", abi);
        fs::path so = objDir / "lib" / abi / ("lib" + name + ".so");
        std::vector<std::string> extra = {"-shared", "-fPIC", "-I" + appGlue.string(), "-I" + (fs::path(libDir) / "android").string(),
                                          "-DNDEBUG", "-u", "ANativeActivity_onCreate", "-Wl,-z,max-page-size=16384", "-landroid", "-llog"};
        if (o.debug != 1) extra.push_back("-s");
        if (o.verbose) std::fprintf(stderr, "faset: compilando %s\n", abi.c_str());
        if (int r = compileC(oa, csrc, so.string(),
                             {(appGlue / "android_native_app_glue.c").string(), glueC.string(), tagC.string()}, extra))
            return r;
        spec.files.push_back({"lib/" + abi + "/lib" + name + ".so", so.string()});
        // Bibliotecas nativas propias (<NativeLibrary> + <LibraryPath>, que puede usar $(AndroidAbi)).
        for (const std::string& l : oa.libs)
            for (const std::string& d : oa.libDirs) {
                fs::path f = fs::path(d) / ("lib" + l + ".so");
                if (fs::exists(f)) {
                    spec.files.push_back({"lib/" + abi + "/lib" + l + ".so", f.string()});
                    break;
                }
            }
    }

    // Recursos (<Asset>): assets/<ruta relativa>, sin comprimir (AAssetManager los lee directamente).
    for (const auto& [rel, src] : o.assets) {
        std::error_code aec;
        if (!fs::is_regular_file(src, aec)) {
            diag.fatal("no existe el recurso '" + rel + "' (<Asset Include=\"" + rel + "\"/>)");
            return 1;
        }
        spec.files.push_back({"assets/" + rel, src});
    }
    // Imágenes de la interfaz (sin repetir las que ya son <Asset>): se leen con AAssetManager.
    for (auto& [rel, local] : uiAssets(o)) {
        bool dup = false;
        for (const auto& f : spec.files) dup |= f.first == "assets/" + rel;
        if (!dup) spec.files.push_back({"assets/" + rel, local});
    }

    spec.name = name;
    spec.package = androidPackage(o);
    spec.label = p ? p->prop("AppName", name) : name;
    spec.versionCode = p ? std::atoi(p->prop("VersionCode", "1").c_str()) : 1;
    if (spec.versionCode <= 0) spec.versionCode = 1;
    spec.versionName = p ? p->prop("VersionName", p->prop("Version", "1.0")) : "1.0";
    spec.minSdk = o.androidApi;
    spec.targetSdk = p ? std::atoi(p->prop("AndroidTargetSdk", "0").c_str()) : 0;
    if (p && !p->prop("AndroidIcon").empty()) spec.icon = (fs::path(p->dir) / p->prop("AndroidIcon")).string();
    spec.orientation = p ? p->prop("AndroidOrientation") : "";
    spec.permissions = o.androidPermissions;
    spec.debuggable = o.configuration == "Debug";
    if (p && !p->prop("AndroidKeystore").empty()) {
        spec.keystore = (fs::path(p->dir) / p->prop("AndroidKeystore")).string();
        spec.keyAlias = p->prop("AndroidKeyAlias");
        const char* sp = std::getenv("FASET_ANDROID_KEYSTORE_PASSWORD");
        const char* kp = std::getenv("FASET_ANDROID_KEY_PASSWORD");
        spec.storePass = sp ? sp : p->prop("AndroidKeystorePassword");
        spec.keyPass = kp ? kp : p->prop("AndroidKeyPassword", spec.storePass);
    }
    spec.objDir = objDir.string();
    spec.output = outPath;
    spec.verbose = o.verbose;
    std::string err;
    if (!androidPackageApk(spec, err)) {
        diag.fatal(err);
        return 1;
    }
    o.arch = "";
    for (size_t i = 0; i < abis.size(); i++) o.arch += (i ? "," : "") + abis[i];
    if (!p) fs::remove_all(objDir, ec);
    return 0;
}

// <Asset Include="..."/>: copia los recursos junto al ejecutable, con la misma ruta relativa
// (solo si cambiaron), para que el programa los encuentre esté donde esté la carpeta actual.
static int copyAssets(const Options& o, const std::string& outPath) {
    fs::path dir = fs::absolute(outPath).parent_path();
    for (const auto& [rel, src] : o.assets) {
        std::error_code ec;
        if (!fs::is_regular_file(src, ec)) {
            diag.fatal("no existe el recurso '" + rel + "' (<Asset Include=\"" + rel + "\"/>)");
            return 1;
        }
        fs::path dst = dir / rel;
        if (fs::exists(dst, ec) && fs::file_size(dst, ec) == fs::file_size(src, ec) &&
            fs::last_write_time(dst, ec) >= fs::last_write_time(src, ec))
            continue;
        fs::create_directories(dst.parent_path(), ec);
        if (!fs::copy_file(src, dst, fs::copy_options::overwrite_existing, ec)) {
            diag.fatal("no se pudo copiar el recurso '" + rel + "' a " + dst.string() + ": " + ec.message());
            return 1;
        }
    }
    return 0;
}

static int build(Options& o, std::string& outPath) {
    std::string csrc;
    if (!frontEnd(o, &csrc)) {
        std::fprintf(stderr, "compilación fallida: %d error(es)\n", diag.errorCount);
        return 1;
    }
    if (o.target == "android" && o.shared != 1 && !o.noApk) return buildApk(o, csrc, outPath);
    outPath = o.output.empty() ? defaultOutput(o) : o.output;
    if (o.target == "windows" && o.shared != 1 && fs::path(outPath).extension() != ".exe") outPath += ".exe";
    if (int r = compileC(o, csrc, outPath)) return r;
    if (!o.extraC.empty()) copyUiAssets(o, outPath);  // imágenes de los .fstui (solo programas con std.ui)
    return copyAssets(o, outPath);
}

static std::string identifierFrom(const std::string& name) {
    std::string id;
    for (char c : name) id += isalnum((unsigned char)c) ? c : '_';
    if (id.empty() || isdigit((unsigned char)id[0])) id = "App" + id;
    id[0] = (char)toupper((unsigned char)id[0]);
    return id;
}

static int cmdNew(const std::vector<std::string>& args) {
    std::string name, kind = "Exe";
    bool android = false, console = false;
    for (const std::string& a : args) {
        if (a == "--lib" || a == "lib" || a == "classlib") kind = "Library";
        else if (a == "--winexe" || a == "winexe") kind = "WinExe";
        else if (a == "console" || a == "--console") {
            kind = "Exe";
            console = true;
        } else if (a == "--ui" || a == "ui" || a == "appui" || a == "--appui") kind = "AppUI";
        else if (a == "--android" || a == "android") android = true;
        else if (!a.empty() && a[0] == '-') {
            diag.fatal("plantilla desconocida '" + a + "' (usa --console, --lib, --winexe, --ui o --android)");
            return 1;
        } else name = a;
    }
    if (name.empty()) {
        diag.fatal("uso: faset new <Nombre> [--console | --lib | --winexe | --ui | --android [--console]]");
        return 1;
    }
    if (android && kind == "Exe" && !console) kind = "AppUI";  // --android: interfaz táctil por defecto
    fs::path dir(name);
    if (fs::exists(dir)) {
        diag.fatal("'" + name + "' ya existe");
        return 1;
    }
    std::string proj = fs::path(name).filename().string();
    std::string ns = identifierFrom(proj);
    fs::create_directories(dir);
    std::string xml = newProjectXml(proj, kind == "AppUI" ? "WinExe" : kind);
    if (android) {
        // Propiedades de Android ya rellenas (ver README: "Android").
        std::string pkg;
        for (char c : proj) pkg += isalnum((unsigned char)c) ? (char)tolower((unsigned char)c) : '_';
        if (pkg.empty() || !isalpha((unsigned char)pkg[0])) pkg = "app" + pkg;
        size_t k = xml.find("<TargetPlatform>native</TargetPlatform>");
        if (k != std::string::npos) xml.replace(k, 39, "<TargetPlatform>android</TargetPlatform>");
        k = xml.find("  </PropertyGroup>");
        if (k != std::string::npos)
            xml.insert(k, "    <AndroidPackage>com.faset." + pkg + "</AndroidPackage>\n"
                          "    <AppName>" + proj + "</AppName>\n"
                          "    <VersionCode>1</VersionCode>\n"
                          "    <VersionName>1.0</VersionName>\n"
                          "    <AndroidApi>24</AndroidApi>                     <!-- versión mínima de Android (7.0) -->\n"
                          "    <AndroidAbis>arm64-v8a;x86_64</AndroidAbis>     <!-- móviles + emulador -->\n"
                          "    <!-- <AndroidOrientation>portrait</AndroidOrientation> -->\n"
                          "    <!-- <AndroidIcon>icon.png</AndroidIcon> -->\n");
    }
    writeFile(dir / (proj + ".fstproj"), xml);
    if (kind == "AppUI" && android) {
        // Diseño para un móvil (360 x 640 unidades lógicas); se adapta con los anclajes.
        writeFile(dir / "MainWindow.fstui",
                  "<Window Class=\"MainWindow\" Namespace=\"" + ns + "\" Title=\"" + proj +
                      "\" Width=\"360\" Height=\"640\" Theme=\"Dark\">\n"
                      "  <Label Name=\"lblTitle\" X=\"24\" Y=\"32\" Width=\"312\" Height=\"36\" Text=\"Hello, Faset\" FontSize=\"24\" Bold=\"true\" Anchor=\"Left,Top,Right\" />\n"
                      "  <Label Name=\"lblSubtitle\" X=\"24\" Y=\"70\" Width=\"312\" Height=\"22\" Text=\"Native Android app written in Faset.\" Style=\"Subtle\" Anchor=\"Left,Top,Right\" />\n"
                      "  <Panel Name=\"card\" X=\"24\" Y=\"112\" Width=\"312\" Height=\"220\" Anchor=\"Left,Top,Right\">\n"
                      "    <Label X=\"16\" Y=\"14\" Width=\"200\" Height=\"20\" Text=\"Your name\" FontSize=\"13\" Style=\"Subtle\" />\n"
                      "    <TextBox Name=\"txtName\" X=\"16\" Y=\"38\" Width=\"280\" Height=\"40\" Placeholder=\"Type your name...\" Anchor=\"Left,Top,Right\" Changed=\"OnNameChanged\" />\n"
                      "    <CheckBox Name=\"chkExcited\" X=\"16\" Y=\"94\" Width=\"240\" Height=\"28\" Text=\"Add excitement\" Changed=\"OnNameChanged\" />\n"
                      "    <Slider Name=\"sldVolume\" X=\"16\" Y=\"140\" Width=\"280\" Height=\"28\" Value=\"30\" Anchor=\"Left,Top,Right\" Changed=\"OnVolumeChanged\" />\n"
                      "    <ProgressBar Name=\"prgVolume\" X=\"16\" Y=\"188\" Width=\"280\" Height=\"6\" Value=\"30\" Anchor=\"Left,Top,Right\" />\n"
                      "  </Panel>\n"
                      "  <Button Name=\"btnClose\" X=\"24\" Y=\"568\" Width=\"150\" Height=\"48\" Text=\"Close\" Anchor=\"Left,Bottom\" Click=\"OnCloseClick\" />\n"
                      "  <Button Name=\"btnGreet\" X=\"186\" Y=\"568\" Width=\"150\" Height=\"48\" Text=\"Greet\" Style=\"Primary\" Anchor=\"Right,Bottom\" Click=\"OnGreetClick\" />\n"
                      "</Window>\n");
    }
    if (kind == "AppUI") {
        if (!android) writeFile(dir / "MainWindow.fstui",
                  "<Window Class=\"MainWindow\" Namespace=\"" + ns + "\" Title=\"" + proj +
                      "\" Width=\"560\" Height=\"380\" Theme=\"Dark\">\n"
                      "  <Label Name=\"lblTitle\" X=\"32\" Y=\"28\" Width=\"496\" Height=\"34\" Text=\"Hello, Faset\" FontSize=\"24\" Bold=\"true\" Anchor=\"Left,Top,Right\" />\n"
                      "  <Label Name=\"lblSubtitle\" X=\"32\" Y=\"62\" Width=\"496\" Height=\"22\" Text=\"Edit MainWindow.fstui in the FasetStudio designer.\" Style=\"Subtle\" Anchor=\"Left,Top,Right\" />\n"
                      "  <Panel Name=\"card\" X=\"32\" Y=\"104\" Width=\"496\" Height=\"180\" Anchor=\"Left,Top,Right,Bottom\">\n"
                      "    <Label X=\"20\" Y=\"16\" Width=\"200\" Height=\"20\" Text=\"Your name\" FontSize=\"13\" Style=\"Subtle\" />\n"
                      "    <TextBox Name=\"txtName\" X=\"20\" Y=\"40\" Width=\"456\" Height=\"36\" Placeholder=\"Type your name...\" Anchor=\"Left,Top,Right\" Changed=\"OnNameChanged\" />\n"
                      "    <CheckBox Name=\"chkExcited\" X=\"20\" Y=\"92\" Width=\"240\" Height=\"24\" Text=\"Add excitement\" Changed=\"OnNameChanged\" />\n"
                      "    <Slider Name=\"sldVolume\" X=\"20\" Y=\"130\" Width=\"300\" Height=\"24\" Value=\"30\" Changed=\"OnVolumeChanged\" />\n"
                      "    <ProgressBar Name=\"prgVolume\" X=\"336\" Y=\"139\" Width=\"140\" Height=\"6\" Value=\"30\" Anchor=\"Left,Top,Right\" />\n"
                      "  </Panel>\n"
                      "  <Button Name=\"btnClose\" X=\"300\" Y=\"312\" Width=\"108\" Height=\"38\" Text=\"Close\" Anchor=\"Right,Bottom\" Click=\"OnCloseClick\" />\n"
                      "  <Button Name=\"btnGreet\" X=\"420\" Y=\"312\" Width=\"108\" Height=\"38\" Text=\"Greet\" Style=\"Primary\" Anchor=\"Right,Bottom\" Click=\"OnGreetClick\" />\n"
                      "</Window>\n");
        writeFile(dir / "MainWindow.fst",
                  "using std.ui;\n\nnamespace " + ns +
                      "\n{\n"
                      "    // Code-behind of MainWindow.fstui: the designer generates the controls\n"
                      "    // (lblTitle, txtName, btnGreet...) in the other half of this partial class.\n"
                      "    public partial class MainWindow\n    {\n"
                      "        int greetings;\n\n"
                      "        public MainWindow() { InitializeComponent(); }\n\n"
                      "        ~MainWindow() { delete Window; }\n\n"
                      "        void OnNameChanged(Widget sender)\n        {\n"
                      "            string name = txtName.Text.Length > 0 ? txtName.Text : \"Faset\";\n"
                      "            lblTitle.Text = \"Hello, \" + name + (chkExcited.Checked ? \"!\" : \"\");\n        }\n\n"
                      "        void OnVolumeChanged(Widget sender) { prgVolume.Value = sldVolume.Value; }\n\n"
                      "        void OnGreetClick(Widget sender)\n        {\n"
                      "            greetings++;\n"
                      "            lblSubtitle.Text = \"Greeted \" + greetings + (greetings == 1 ? \" time\" : \" times\");\n        }\n\n"
                      "        void OnCloseClick(Widget sender) { Window.Close(); }\n"
                      "    }\n}\n");
        writeFile(dir / "Program.fst",
                  "using std.ui;\n\nnamespace " + ns +
                      "\n{\n    public static class Program\n    {\n        public static int Main()\n        {\n"
                      "            auto window = new MainWindow();\n"
                      "            return Application.Run(window.Window);\n        }\n    }\n}\n");
    } else if (kind == "Library") {
        writeFile(dir / "Biblioteca.fst",
                  "namespace " + ns + "\n{\n    public static class Saludo\n    {\n"
                  "        public static string Texto() => \"¡Hola desde la biblioteca " + proj + "!\";\n    }\n}\n");
    } else {
        writeFile(dir / "Program.fst",
                  "using std::collections;\n\nnamespace " + ns +
                      "\n{\n    public static class Program\n    {\n        public static void Main()\n        {\n"
                      "            Console::WriteLine(\"¡Hola desde Faset!\");\n\n"
                      "            auto numeros = new List<int>();\n"
                      "            for (int i = 1; i <= 5; i++) numeros.Add(i * i);\n"
                      "            Console::WriteLine(numeros.Sum());\n        }\n    }\n}\n");
    }
    writeFile(dir / ".gitignore", "bin/\nobj/\n");
    std::string shown = android ? (kind == "AppUI" ? "Android, AppUI" : "Android, consola") : kind;
    std::printf("Proyecto '%s' creado (%s).\n\n  cd %s\n  faset run\n", proj.c_str(), shown.c_str(), name.c_str());
    if (android)
        std::printf("\n  faset android emulator <avd>   (si no hay un móvil conectado; 'faset android avds')\n"
                    "  faset run --target native      (versión de escritorio)\n");
    return 0;
}

static int cmdDoctor(const Options& o) {
    std::printf("Faset %s  (host: %s-%s)\n\n", kVersion, kHostOS, kHostArch);
    auto show = [](const std::string& label, const std::string& found, const std::string& hint) {
        std::printf("  %-26s %s\n", label.c_str(), found.empty() ? ("no encontrado  -> " + hint).c_str() : found.c_str());
    };
    std::string native;
    for (const char* c : {"cc", "gcc", "clang"})
        if (native.empty()) native = findProgram(c);
    show("Biblioteca std", findLibDir(o.argv0), "define FASET_LIB con la ruta de la carpeta lib/");
    if (native.empty() && std::string(kHostOS) == "windows") native = managedMingwCompiler(kHostArch);
    show("Nativo (" + std::string(kHostOS) + ")", native, std::string("faset setup ") + kHostOS);
    std::string mingw = findProgram("x86_64-w64-mingw32-gcc");
    if (mingw.empty()) mingw = managedMingwCompiler("x86_64");
    show("Windows x86_64 (MinGW)", mingw, "faset setup windows");
    std::printf("\n");
    androidDoctor();
    std::printf("\n");
    return 0;
}

int main(int argc, char** argv) {
#if defined(_WIN32)
    SetConsoleOutputCP(CP_UTF8);  // los mensajes son UTF-8 (tildes, ✓)
#endif
    Options o;
    o.argv0 = argv[0];
    std::vector<std::string> args(argv + 1, argv + argc);
    if (args.empty()) {
        usage();
        return 0;
    }
    o.command = args[0];
    if (o.command == "help" || o.command == "-h" || o.command == "--help") {
        usage();
        return 0;
    }
    if (o.command == "version" || o.command == "--version") {
        std::printf("faset %s\n", kVersion);
        return 0;
    }
    if (o.command == "doctor") return cmdDoctor(o);
    if (o.command == "setup") return cmdSetup(std::vector<std::string>(args.begin() + 1, args.end()));
    if (o.command == "lsp") return runLanguageServer(o.argv0);
    if (o.command == "__analyze") {
        if (args.size() < 3) return 2;
        return runAnalyzer(args[1], args[2], o.argv0);
    }
    // Soluciones .fstp: 'faset sln', 'faset new sln' y build/run/check/clean de una solución (src/SolutionCli.cpp).
    if (int code = 0; solutionCommand(args, o.argv0, code)) return code;
    // Paquetes: add, remove, restore, update, list paquetes, pack, publish, new --package (src/Packages.cpp).
    if (int code = 0; packageCommand(args, o.argv0, code)) return code;
    if (o.command == "new") return cmdNew(std::vector<std::string>(args.begin() + 1, args.end()));
    if (o.command == "android") {
        // El paquete del proyecto de la carpeta actual (para stop, uninstall y logcat --app).
        std::string pkg, projPath = findProjectIn(fs::current_path());
        if (!projPath.empty() && loadProjectTree(projPath, o)) pkg = androidPackage(o);
        return androidCommand(std::vector<std::string>(args.begin() + 1, args.end()), pkg);
    }
    static const std::vector<std::string> cmds = {"build", "run", "check", "emit-c", "clean"};
    if (std::find(cmds.begin(), cmds.end(), o.command) == cmds.end()) {
        std::string ext = fs::path(o.command).extension().string();
        if (ext == ".fst" || ext == ".fstproj") {
            args.insert(args.begin(), "build");
            o.command = "build";
        } else {
            diag.fatal("comando desconocido '" + o.command + "' (usa 'faset help')");
            return 1;
        }
    }

    std::vector<std::string> positional;
    for (size_t i = 1; i < args.size(); i++) {
        const std::string& a = args[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= args.size()) {
                diag.fatal("falta el valor de '" + a + "'");
                std::exit(1);
            }
            return args[++i];
        };
        if (a == "--") {
            o.runArgs.assign(args.begin() + (long)i + 1, args.end());
            break;
        } else if (a == "-o") o.output = next();
        else if (a == "-c" || a == "--configuration") o.configuration = next();
        else if (a == "--target") o.target = next();
        else if (a == "--arch") o.arch = next();
        else if (a == "--api") o.androidApi = std::atoi(next().c_str());
        else if (a == "--device" || a == "-s") o.device = next();
        else if (a == "--no-apk") o.noApk = true;
        else if (a == "--shared") o.shared = 1;
        else if (a == "--gui") o.gui = 1;
        else if (a == "--static") o.staticLink = 1;
        else if (a == "--debug") o.configuration = "Debug";
        else if (a == "--release") o.configuration = "Release";
        else if (a == "--keep-c") o.keepC = true;
        else if (a == "--sanitize") o.sanitize = true;
        else if (a == "--checks" || a == "--runtime-checks") o.checks = 1;
        else if (a == "--no-checks" || a == "--no-runtime-checks") o.checks = 0;
        else if (a == "--allow-unsafe") o.allowUnsafe = true;
        else if (a == "--cc") o.cc = next();
        else if (a == "-v" || a == "--verbose") o.verbose = true;
        else if (a == "-l") o.libs.push_back(next());
        else if (a.rfind("-l", 0) == 0 && a.size() > 2) o.libs.push_back(a.substr(2));
        else if (a == "-L") o.libDirs.push_back(next());
        else if (a.rfind("-L", 0) == 0 && a.size() > 2) o.libDirs.push_back(a.substr(2));
        else if (!a.empty() && a[0] == '-') {
            diag.fatal("opción desconocida '" + a + "'");
            return 1;
        } else positional.push_back(a);
    }

    // ¿Proyecto o archivos sueltos?
    std::string projPath;
    if (positional.empty()) {
        projPath = findProjectIn(fs::current_path());
    } else if (positional.size() == 1) {
        std::error_code ec;
        if (fs::path(positional[0]).extension() == ".fstproj") projPath = positional[0];
        else if (fs::is_directory(positional[0], ec)) projPath = findProjectIn(positional[0]);
    }
    if (!projPath.empty()) {
        if (!loadProjectTree(projPath, o)) return 1;
        applyProjectSettings(o);
    } else {
        for (const std::string& p : positional) collectInputs(p, o.inputs);
        o.singleFile = positional.size() == 1 && fs::path(positional[0]).extension() == ".fst";
        if (positional.empty()) collectInputs(fs::exists("src") ? "src" : ".", o.inputs);
    }

    if (o.command == "clean") {
        if (!o.project) {
            diag.fatal("'clean' necesita un proyecto .fstproj");
            return 1;
        }
        std::error_code ec;
        for (const char* d : {"bin", "obj"}) fs::remove_all(fs::path(o.project->dir) / d, ec);
        std::printf("Limpio: %s\n", o.project->dir.c_str());
        return 0;
    }

    if (o.target.empty() || o.target == "native") o.target = kHostOS;
    o.archGiven = !o.arch.empty();
    if (o.arch.empty()) o.arch = o.target == "android" ? "arm64" : kHostArch;
    if (o.androidApi == 0) o.androidApi = 24;
    if (o.configuration.empty()) o.configuration = "Debug";
    if (o.configuration != "Debug" && o.configuration != "Release") {
        diag.fatal("configuración desconocida '" + o.configuration + "' (usa Debug o Release)");
        return 1;
    }
    if (o.debug < 0) o.debug = o.configuration == "Debug";
    if (o.checks < 0) o.checks = o.configuration == "Debug";
    for (auto& [lib, platform] : o.platformLibs)
        if (platform == o.target) o.libs.push_back(lib);
    if (o.target != "linux" && o.target != "windows" && o.target != "android" && o.target != "macos") {
        diag.fatal("objetivo desconocido '" + o.target + "' (usa native, linux, windows o android)");
        return 1;
    }
    if (o.inputs.empty()) {
        diag.fatal("no hay archivos .fst que compilar (¿falta un .fstproj?)");
        return 1;
    }

    if (o.command == "check") {
        if (!frontEnd(o, nullptr)) {
            std::fprintf(stderr, "%d error(es)\n", diag.errorCount);
            return 1;
        }
        std::printf("Sin errores (%zu archivo(s)).\n", o.inputs.size());
        return 0;
    }
    if (o.command == "emit-c") {
        std::string csrc;
        if (!frontEnd(o, &csrc)) return 1;
        if (o.output.empty()) std::fwrite(csrc.data(), 1, csrc.size(), stdout);
        else if (!writeFile(o.output, csrc)) {
            diag.fatal("no se pudo escribir '" + o.output + "'");
            return 1;
        }
        return 0;
    }

    std::string outPath;
    if (int r = build(o, outPath)) return r;
    if (o.command == "build") {
        std::fprintf(stderr, "Compilado: %s  [%s-%s, %s]\n", outPath.c_str(), o.target.c_str(), o.arch.c_str(),
                     o.configuration.c_str());
        return 0;
    }
    if (o.target == "android" && o.shared != 1 && !o.noApk)
        return androidRunApk(outPath, androidPackage(o), androidName(o), o.device, o.verbose);
    if (o.target != kHostOS || o.shared == 1) {
        diag.fatal("'run' solo puede ejecutar programas para esta máquina; usa 'build' para otros objetivos");
        return 1;
    }
    std::vector<std::string> cmd = {fs::absolute(outPath).string()};
    cmd.insert(cmd.end(), o.runArgs.begin(), o.runArgs.end());
    return runCommand(cmd, o.verbose);
}
