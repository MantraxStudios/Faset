// Faset - interfaz de línea de comandos.
//
//   faset new <Nombre> [--lib | --winexe]   crea un proyecto (.fstproj)
//   faset build [proyecto|archivos]         compila a un ejecutable nativo
//   faset run   [proyecto|archivos] [-- args]
//   faset check [proyecto|archivos]
//   faset emit-c [proyecto|archivos] [-o x.c]
//   faset clean [proyecto]
//   faset doctor | version | help
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

#include "CodeGen.h"
#include "Frontend.h"
#include "Lsp.h"
#include "Lexer.h"
#include "Parser.h"
#include "Project.h"
#include "Runtime.h"
#include "Sema.h"

namespace fs = std::filesystem;

static const char* const kVersion = "0.2.0";

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
    bool keepC = false, verbose = false, sanitize = false;
    std::string cc;
    std::string configuration;
    std::vector<std::string> libs, libDirs;
    std::vector<std::string> runArgs;
    bool singleFile = false;
    Project* project = nullptr;
    std::string argv0;
};

// ------------------------------------------------------------------ utilidades

static void usage() {
    std::printf(
        "Faset %s - lenguaje nativo que mezcla C# y C++\n\n"
        "Uso:\n"
        "  faset new <Nombre> [--lib|--winexe]   Crea un proyecto (Nombre/Nombre.fstproj)\n"
        "  faset build  [entrada] [opciones]     Compila a un ejecutable nativo\n"
        "  faset run    [entrada] [-- args]      Compila y ejecuta\n"
        "  faset check  [entrada]                Comprueba errores sin compilar\n"
        "  faset emit-c [entrada] [-o f.c]       Genera el código C intermedio\n"
        "  faset clean  [proyecto]               Borra bin/ y obj/\n"
        "  faset doctor                          Muestra los compiladores detectados\n"
        "  faset lsp                             Servidor de lenguaje (para VS Code y otros editores)\n"
        "  faset version | help\n\n"
        "Entrada: un .fstproj, una carpeta con un .fstproj, o archivos .fst sueltos.\n"
        "         Sin entrada se usa el .fstproj de la carpeta actual.\n\n"
        "Opciones:\n"
        "  -o <ruta>            Archivo de salida\n"
        "  -c <Debug|Release>   Configuración\n"
        "  --target <t>         native, linux, windows, android\n"
        "  --arch <a>           x86_64, x86, arm64, armv7\n"
        "  --api <n>            Nivel de API de Android (por defecto 24)\n"
        "  --shared             Biblioteca (.so / .dll)\n"
        "  --gui                Windows: aplicación de ventana (sin consola)\n"
        "  --static             Enlazado estático\n"
        "  --debug / --release  Atajos de -c Debug / -c Release\n"
        "  --cc <compilador>    Compilador de C (también: variable FASET_CC)\n"
        "  -l <lib>  -L <dir>   Bibliotecas nativas\n"
        "  --sanitize           Detecta errores de memoria en ejecución (ASan + UBSan)\n"
        "  --keep-c             Conserva el C generado junto a la salida\n"
        "  -v, --verbose        Muestra los comandos ejecutados\n",
        kVersion);
}

static bool writeFile(const fs::path& path, const std::string& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << data;
    return (bool)f;
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

static std::string findNdk() {
    for (const char* var : {"ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK"}) {
        std::string v = envOr(var);
        if (!v.empty() && fs::exists(v)) return v;
    }
    std::vector<fs::path> sdks;
    for (const char* var : {"ANDROID_HOME", "ANDROID_SDK_ROOT"})
        if (!envOr(var).empty()) sdks.emplace_back(envOr(var));
    std::string home = envOr("HOME").empty() ? envOr("USERPROFILE") : envOr("HOME");
    if (!home.empty()) {
        sdks.push_back(fs::path(home) / "Android" / "Sdk");
        sdks.push_back(fs::path(home) / "AppData" / "Local" / "Android" / "Sdk");
        sdks.push_back(fs::path(home) / "Library" / "Android" / "sdk");
    }
    for (const fs::path& sdk : sdks) {
        std::error_code ec;
        fs::path ndkDir = sdk / "ndk";
        if (!fs::is_directory(ndkDir, ec)) continue;
        std::vector<fs::path> versions;
        for (auto& e : fs::directory_iterator(ndkDir, ec))
            if (e.is_directory()) versions.push_back(e.path());
        if (!versions.empty()) {
            std::sort(versions.begin(), versions.end());
            return versions.back().string();
        }
    }
    return "";
}

static std::string androidTriple(const std::string& arch) {
    if (arch == "arm64") return "aarch64-linux-android";
    if (arch == "armv7") return "armv7a-linux-androideabi";
    if (arch == "x86") return "i686-linux-android";
    return "x86_64-linux-android";
}

static std::string resolveCompiler(const Options& o, std::string& why) {
    if (!o.cc.empty()) return o.cc;
    if (!envOr("FASET_CC").empty()) return envOr("FASET_CC");
    const std::string& t = o.target;
    if (t == "android") {
        std::string ndk = findNdk();
        if (ndk.empty()) {
            why = "no se encontró el Android NDK; instálalo y define ANDROID_NDK_HOME";
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
        why = "no se encontró un compilador de C (instala gcc o clang)";
        return "";
    }
    if (t == "windows") {
        std::string triple = o.arch == "x86" ? "i686-w64-mingw32" : o.arch == "arm64" ? "aarch64-w64-mingw32" : "x86_64-w64-mingw32";
        for (const std::string& c : {triple + "-gcc", triple + "-clang"})
            if (!findProgram(c).empty()) return c;
        why = "no se encontró " + triple + "-gcc (instala MinGW-w64, p. ej. 'sudo apt install mingw-w64')";
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
            if (e.is_regular_file() && e.path().extension() == ".fst") found.push_back(e.path().string());
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
        stack.push_back(key);
        for (const std::string& ref : proj->references) {
            if (!fs::exists(ref)) {
                diag.fatal(proj->path + ": no existe el proyecto referenciado '" + ref + "'");
                return false;
            }
            if (!visit(ref, false)) return false;
        }
        stack.pop_back();
        for (const std::string& f : projectSources(*proj))
            if (std::find(o.inputs.begin(), o.inputs.end(), f) == o.inputs.end()) o.inputs.push_back(f);
        o.libs.insert(o.libs.end(), proj->nativeLibs.begin(), proj->nativeLibs.end());
        o.libDirs.insert(o.libDirs.end(), proj->libPaths.begin(), proj->libPaths.end());
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
}

// ------------------------------------------------------------------ compilación

static bool frontEnd(const Options& o, std::string* csrc) {
    FrontendOptions fo;
    fo.inputs = o.inputs;
    fo.libDir = findLibDir(o.argv0);
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
    if (csrc) *csrc = CodeGen(*r.prog, *r.sema, *r.tc).generate(o.shared == 1);
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

static int build(Options& o, std::string& outPath) {
    std::string csrc;
    if (!frontEnd(o, &csrc)) {
        std::fprintf(stderr, "compilación fallida: %d error(es)\n", diag.errorCount);
        return 1;
    }
    std::string why;
    std::string cc = resolveCompiler(o, why);
    if (cc.empty()) {
        diag.fatal(why);
        return 1;
    }
    outPath = o.output.empty() ? defaultOutput(o) : o.output;
    if (o.target == "windows" && o.shared != 1 && fs::path(outPath).extension() != ".exe") outPath += ".exe";
    std::error_code ec;
    if (fs::path(outPath).has_parent_path()) fs::create_directories(fs::path(outPath).parent_path(), ec);

    std::mt19937_64 rng((uint64_t)std::chrono::steady_clock::now().time_since_epoch().count());
    fs::path tmp = fs::temp_directory_path() / ("faset-" + std::to_string(rng() % 100000000));
    fs::create_directories(tmp);
    std::string stem = fs::path(outPath).stem().string();
    fs::path mainC = tmp / (stem + ".c");
    fs::path rtC = tmp / "faset_rt.c";
    if (!writeFile(mainC, csrc) || !writeFile(tmp / "faset_rt.h", kRuntimeHeader) || !writeFile(rtC, kRuntimeSource)) {
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
    if (o.sanitize) {
        cmd.push_back("-fsanitize=address,undefined");
        cmd.push_back("-fno-omit-frame-pointer");
        if (o.debug != 1) cmd.push_back("-g");
    }
    cmd.push_back(mainC.string());
    cmd.push_back(rtC.string());
    cmd.push_back("-o");
    cmd.push_back(outPath);
    for (const std::string& d : o.libDirs) cmd.push_back("-L" + d);
    for (const std::string& l : o.libs) cmd.push_back("-l" + l);
    cmd.push_back("-lm");

    int r = runCommand(cmd, o.verbose);
    if (o.keepC) fs::copy_file(mainC, fs::path(outPath).replace_extension(".c"), fs::copy_options::overwrite_existing, ec);
    fs::remove_all(tmp, ec);
    if (r != 0) {
        diag.fatal("el compilador de C falló (código " + std::to_string(r) + "); usa -v para ver el comando");
        return 1;
    }
    return 0;
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
    for (const std::string& a : args) {
        if (a == "--lib" || a == "lib" || a == "classlib") kind = "Library";
        else if (a == "--winexe" || a == "winexe") kind = "WinExe";
        else if (a == "console" || a == "--console") kind = "Exe";
        else if (!a.empty() && a[0] != '-') name = a;
    }
    if (name.empty()) {
        diag.fatal("uso: faset new <Nombre> [--lib | --winexe]");
        return 1;
    }
    fs::path dir(name);
    if (fs::exists(dir)) {
        diag.fatal("'" + name + "' ya existe");
        return 1;
    }
    std::string proj = fs::path(name).filename().string();
    std::string ns = identifierFrom(proj);
    fs::create_directories(dir);
    writeFile(dir / (proj + ".fstproj"), newProjectXml(proj, kind));
    if (kind == "Library") {
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
                      "            Console::WriteLine(numeros.Sum());\n"
                      "            delete numeros;\n        }\n    }\n}\n");
    }
    writeFile(dir / ".gitignore", "bin/\nobj/\n");
    std::printf("Proyecto '%s' creado (%s).\n\n  cd %s\n  faset run\n", proj.c_str(), kind.c_str(), name.c_str());
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
    show("Nativo (" + std::string(kHostOS) + ")", native, "instala gcc o clang");
    show("Windows x86_64 (MinGW)", findProgram("x86_64-w64-mingw32-gcc"), "sudo apt install mingw-w64");
    show("Android NDK", findNdk(), "instala el NDK y define ANDROID_NDK_HOME");
    std::printf("\n");
    return 0;
}

int main(int argc, char** argv) {
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
    if (o.command == "lsp") return runLanguageServer(o.argv0);
    if (o.command == "__analyze") {
        if (args.size() < 3) return 2;
        return runAnalyzer(args[1], args[2], o.argv0);
    }
    if (o.command == "new") return cmdNew(std::vector<std::string>(args.begin() + 1, args.end()));
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
        else if (a == "--shared") o.shared = 1;
        else if (a == "--gui") o.gui = 1;
        else if (a == "--static") o.staticLink = 1;
        else if (a == "--debug") o.configuration = "Debug";
        else if (a == "--release") o.configuration = "Release";
        else if (a == "--keep-c") o.keepC = true;
        else if (a == "--sanitize") o.sanitize = true;
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
    if (o.arch.empty()) o.arch = o.target == "android" ? "arm64" : kHostArch;
    if (o.androidApi == 0) o.androidApi = 24;
    if (o.configuration.empty()) o.configuration = "Debug";
    if (o.configuration != "Debug" && o.configuration != "Release") {
        diag.fatal("configuración desconocida '" + o.configuration + "' (usa Debug o Release)");
        return 1;
    }
    if (o.debug < 0) o.debug = o.configuration == "Debug";
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
    if (o.target != kHostOS || o.shared == 1) {
        diag.fatal("'run' solo puede ejecutar programas para esta máquina; usa 'build' para otros objetivos");
        return 1;
    }
    std::vector<std::string> cmd = {fs::absolute(outPath).string()};
    cmd.insert(cmd.end(), o.runArgs.begin(), o.runArgs.end());
    return runCommand(cmd, o.verbose);
}
