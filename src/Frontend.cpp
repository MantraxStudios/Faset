#include "Frontend.h"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <set>
#include <sstream>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#endif

#include "Lexer.h"
#include "Parser.h"
#include "UiGen.h"

namespace fs = std::filesystem;

std::string normalizePath(const std::string& path) {
    std::error_code ec;
    fs::path p = fs::weakly_canonical(fs::absolute(path, ec), ec);
    return p.lexically_normal().string();
}

std::string findProgram(const std::string& name) {
    if (name.find('/') != std::string::npos || name.find('\\') != std::string::npos)
        return fs::exists(name) ? name : "";
    const char* pathEnv = std::getenv("PATH");
    std::string path = pathEnv ? pathEnv : "";
#if defined(_WIN32)
    const char sep = ';';
    const std::vector<std::string> exts = {".exe", ".cmd", ".bat", ""};
#else
    const char sep = ':';
    const std::vector<std::string> exts = {""};
#endif
    std::stringstream ss(path);
    std::string dir;
    while (std::getline(ss, dir, sep)) {
        if (dir.empty()) continue;
        for (const std::string& ext : exts) {
            fs::path p = fs::path(dir) / (name + ext);
            std::error_code ec;
            if (fs::is_regular_file(p, ec)) return p.string();
        }
    }
    return "";
}

std::string selfExePath(const std::string& argv0) {
    std::error_code ec;
#if defined(_WIN32)
    char buf[MAX_PATH];
    DWORD n = GetModuleFileNameA(nullptr, buf, MAX_PATH);
    if (n > 0) return std::string(buf, n);
#elif defined(__linux__)
    fs::path self = fs::read_symlink("/proc/self/exe", ec);
    if (!ec) return self.string();
#endif
    fs::path p = fs::path(argv0);
    if (!p.has_parent_path()) {
        std::string found = findProgram(argv0);
        if (!found.empty()) p = found;
    }
    return fs::weakly_canonical(p, ec).string();
}

std::string findLibDir(const std::string& argv0) {
    std::vector<fs::path> cands;
    if (const char* env = std::getenv("FASET_LIB")) cands.emplace_back(env);
    fs::path d = fs::path(selfExePath(argv0)).parent_path();
    cands.push_back(d / "lib");
    cands.push_back(d / ".." / "lib");
    cands.push_back(d / ".." / "lib" / "faset");
    cands.push_back(d / ".." / "share" / "faset" / "lib");
    for (const fs::path& c : cands) {
        std::error_code ec;
        if (fs::exists(c / "std" / "core.fst", ec)) return fs::weakly_canonical(c, ec).string();
    }
    return "";
}

static bool readFile(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

std::set<std::string> definesFor(const std::string& target, const std::string& configuration) {
    std::set<std::string> d = {"FASET"};
    if (target == "windows") d.insert("WINDOWS");
    else if (target == "android") d.insert("ANDROID");
    else if (target == "macos") d.insert("MACOS");
    else d.insert("LINUX");
    d.insert(configuration == "Release" ? "RELEASE" : "DEBUG");
    return d;
}

FrontendResult runFrontend(const FrontendOptions& opts) {
    FrontendResult res;
    setDefines(opts.defines);
    res.prog = new Program();
    res.tc = new TypeCtx();
    Program& prog = *res.prog;
    const std::string& lib = opts.libDir;

    std::set<std::string> libRoots;
    std::error_code ec;
    for (auto& e : fs::directory_iterator(lib, ec))
        if (e.is_directory()) libRoots.insert(e.path().filename().string());

    std::set<std::string> loaded;
    std::vector<std::pair<std::string, std::string>> queue;  // ruta absoluta, nombre a mostrar
    auto enqueue = [&](const std::string& path, const std::string& shown) {
        std::string key = normalizePath(path);
        if (loaded.insert(key).second) queue.push_back({key, shown});
    };
    enqueue((fs::path(lib) / "std" / "core.fst").string(), "<std/core>.fst");
    for (const std::string& in : opts.inputs) {
        std::string shown = in;
        fs::path rel = fs::path(in).lexically_relative(fs::current_path());
        if (!rel.empty() && rel.string().rfind("..", 0) != 0) shown = rel.string();
        enqueue(in, shown);
    }

    std::set<std::string> modulesDone;
    size_t qi = 0;
    for (;;) {
        while (qi < queue.size()) {
            auto [path, shown] = queue[qi++];
            std::string src;
            bool have = false;
            if (opts.overrides) {
                auto it = opts.overrides->find(path);
                if (it != opts.overrides->end()) {
                    src = it->second;
                    have = true;
                }
            }
            if (!have && !readFile(path, src)) {
                diag.fatal("no se puede leer '" + path + "'");
                continue;
            }
            auto* file = new FileScope();
            file->fileId = diag.addFile(shown, path);
            file->unsafeCtx = opts.unsafeFiles.count(path) != 0;
            prog.files.push_back(file);
            if (fs::path(path).extension() == ".fstui") {
                std::string gen = generateUiSource(src, file->fileId);
                // En el editor, mientras el XML está a medio escribir se usa la última versión guardada
                // para generar la clase: así el código de la ventana no se llena de errores.
                std::string disk;
                if (gen.empty() && have && opts.ideMode && readFile(path, disk) && disk != src) {
                    size_t keep = diag.captured.size();
                    int errors = diag.errorCount;
                    gen = generateUiSource(disk, file->fileId);
                    diag.captured.resize(keep);
                    diag.errorCount = errors;
                }
                src = gen;
            }
            auto toks = std::make_shared<std::vector<Token>>(tokenize(src, file->fileId));
            Parser(toks, prog, file, fs::path(path).parent_path().string(), &libRoots).parseFile();
        }
        for (const std::string& mod : std::set<std::string>(prog.requestedModules)) {
            if (!modulesDone.insert(mod).second) continue;
            std::string rel = mod;
            std::replace(rel.begin(), rel.end(), '.', '/');
            fs::path p = fs::path(lib) / (rel + ".fst");
            if (fs::exists(p, ec)) enqueue(p.string(), "<" + rel + ">.fst");
        }
        for (const std::string& f : prog.requestedFiles) {
            if (!fs::exists(f, ec) && !(opts.overrides && opts.overrides->count(normalizePath(f))))
                diag.fatal("import: no existe el archivo '" + f + "'");
            else
                enqueue(f, fs::path(f).lexically_relative(fs::current_path()).string());
        }
        prog.requestedFiles.clear();
        if (qi >= queue.size()) break;
    }
    if (diag.errorCount && !opts.analyzeWithParseErrors) return res;
    res.sema = new Sema(prog, *res.tc);
    res.sema->ideMode = opts.ideMode;
    res.ok = res.sema->run() && diag.errorCount == 0;
    return res;
}
