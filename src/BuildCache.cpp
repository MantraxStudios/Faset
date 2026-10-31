// Faset - caché de objetos del compilador de C (ver BuildCache.h).
#include "BuildCache.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <random>
#include <set>
#include <sstream>
#include <thread>

#include "Frontend.h"
#include "Setup.h"

namespace fs = std::filesystem;

namespace {

// Hash de 128 bits (dos FNV-1a de 64 con semillas distintas): suficiente para una caché.
struct Hasher {
    uint64_t a = 1469598103934665603ULL, b = 0x9ae16a3b2f90404fULL;
    void add(const void* data, size_t n) {
        const unsigned char* p = (const unsigned char*)data;
        for (size_t i = 0; i < n; i++) {
            a = (a ^ p[i]) * 1099511628211ULL;
            b = (b ^ p[i]) * 0x100000001b3ULL + 0x9e3779b97f4a7c15ULL;
        }
    }
    void add(const std::string& s) {
        uint64_t n = s.size();
        add(&n, sizeof n);  // longitud: "ab"+"c" no es "a"+"bc"
        add(s.data(), s.size());
    }
    std::string hex() const {
        char buf[40];
        std::snprintf(buf, sizeof buf, "%016llx%016llx", (unsigned long long)a, (unsigned long long)b);
        return buf;
    }
};

bool readAll(const fs::path& p, std::string& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

// Identidad del compilador: su ruta real, tamaño y fecha (otro gcc u otra versión -> otra clave).
std::string compilerIdentity(const std::string& cc) {
    static std::map<std::string, std::string> memo;
    auto it = memo.find(cc);
    if (it != memo.end()) return it->second;
    std::string path = cc;
    std::error_code ec;
    if (!fs::path(cc).has_parent_path()) {
        std::string found = findProgram(cc);
        if (!found.empty()) path = found;
    }
    fs::path real = fs::weakly_canonical(path, ec);
    if (ec) real = path;
    std::string id = cc + "|" + real.string();
    auto size = fs::file_size(real, ec);
    if (!ec) id += "|" + std::to_string(size);
    auto time = fs::last_write_time(real, ec);
    if (!ec) id += "|" + std::to_string((long long)time.time_since_epoch().count());
    memo[cc] = id;
    return id;
}

// Opciones que cambian el objeto compilado (el resto solo importa al enlazar).
bool isCompileFlag(const std::string& a) {
    if (a.rfind("-Wl,", 0) == 0) return false;
    if (a == "-shared" || a == "-static" || a == "-s" || a == "-mwindows" || a == "-u") return false;
    if (a.size() > 2 && (a.rfind("-l", 0) == 0 || a.rfind("-L", 0) == 0)) return false;
    static const char* const prefixes[] = {"-std=", "-O", "-g", "-f", "-D", "-U", "-I", "-w", "-W", "-m", "--target=", "-target",
                                           "--sysroot=", "-isystem", "-pthread", "-march", "-include"};
    for (const char* p : prefixes)
        if (a.rfind(p, 0) == 0) return true;
    return false;
}

bool isCSource(const std::string& a) {
    return a.size() > 2 && a[0] != '-' && a.compare(a.size() - 2, 2, ".c") == 0;
}

// Contenido del archivo y de lo que incluye con #include "..." (relativo a su carpeta o a -I).
void hashSourceTree(const fs::path& file, const std::vector<std::string>& includeDirs, Hasher& h, std::set<std::string>& seen) {
    std::error_code ec;
    std::string key = fs::weakly_canonical(file, ec).string();
    if (!seen.insert(key).second) return;
    std::string src;
    if (!readAll(file, src)) return;
    h.add(file.filename().string());
    h.add(src);
    size_t i = 0;
    while ((i = src.find("include", i)) != std::string::npos) {
        size_t lineStart = src.rfind('\n', i);
        lineStart = lineStart == std::string::npos ? 0 : lineStart + 1;
        size_t k = lineStart;
        while (k < i && (src[k] == ' ' || src[k] == '\t')) k++;
        bool directive = k < i && src[k] == '#';
        i += 7;
        if (!directive) continue;
        size_t q = i;
        while (q < src.size() && (src[q] == ' ' || src[q] == '\t')) q++;
        if (q >= src.size() || (src[q] != '"' && src[q] != '<')) continue;
        bool angle = src[q] == '<';  // <...>: solo si está en una carpeta -I (las del sistema no cambian)
        size_t e = src.find(angle ? '>' : '"', q + 1);
        if (e == std::string::npos) continue;
        std::string name = src.substr(q + 1, e - q - 1);
        if (name.find('\n') != std::string::npos) continue;
        fs::path found = angle ? fs::path() : file.parent_path() / name;
        if (found.empty() || !fs::exists(found, ec)) {
            found.clear();
            for (const std::string& d : includeDirs)
                if (fs::exists(fs::path(d) / name, ec)) {
                    found = fs::path(d) / name;
                    break;
                }
        }
        if (angle && found.empty()) continue;
        h.add(name);
        if (!found.empty()) hashSourceTree(found, includeDirs, h, seen);
    }
}

std::string uniqueSuffix() {
    static std::mt19937_64 rng((uint64_t)std::chrono::steady_clock::now().time_since_epoch().count());
    static std::mutex m;
    std::lock_guard<std::mutex> lk(m);
    return std::to_string(rng() % 1000000000ULL);
}

// Tamaño máximo de la caché compartida: FASET_CACHE_MAX_MB (por defecto 1024 MB).
unsigned long long cacheLimit() {
    const char* env = std::getenv("FASET_CACHE_MAX_MB");
    long long mb = env && *env ? std::atoll(env) : 1024;
    return (unsigned long long)std::max(16LL, mb) * 1048576ULL;
}

// Poda la caché: borra los objetos que no se usan desde hace 30 días y, si aun así pasa del
// límite, los usados hace más tiempo hasta quedar en el 80 % (cada uso actualiza la fecha).
void pruneCache(const fs::path& dir) {
    std::error_code ec;
    auto now = fs::file_time_type::clock::now();
    struct Entry {
        fs::path path;
        fs::file_time_type time;
        unsigned long long size;
    };
    std::vector<Entry> all;
    unsigned long long total = 0;
    for (auto& e : fs::directory_iterator(dir, ec)) {
        if (!e.is_regular_file(ec)) continue;
        std::string name = e.path().filename().string();
        auto t = fs::last_write_time(e.path(), ec);
        if (name.find(".tmp") != std::string::npos) {  // restos de una compilación interrumpida
            if (now - t > std::chrono::hours(1)) fs::remove(e.path(), ec);
            continue;
        }
        if (e.path().extension() != ".o") continue;
        if (now - t > std::chrono::hours(24 * 30)) {
            fs::remove(e.path(), ec);
            continue;
        }
        unsigned long long sz = e.file_size(ec);
        all.push_back({e.path(), t, sz});
        total += sz;
    }
    unsigned long long limit = cacheLimit();
    if (total <= limit) return;
    std::sort(all.begin(), all.end(), [](const Entry& a, const Entry& b) { return a.time < b.time; });
    for (const Entry& e : all) {
        if (total <= limit / 10 * 8) break;
        fs::remove(e.path, ec);
        total -= e.size;
    }
}

// Compilaciones de C a la vez: FASET_JOBS o, por defecto, la mitad de los núcleos (máximo 4),
// para no llenar la memoria con varios compiladores de C a la vez.
size_t jobCount() {
    const char* env = std::getenv("FASET_JOBS");
    if (env && std::atoi(env) > 0) return (size_t)std::atoi(env);
    unsigned hw = std::max(2u, std::thread::hardware_concurrency());
    return std::min<size_t>(4, hw / 2);
}

}  // namespace

std::string objectCacheDir() { return (fs::path(fasetDataDir()) / "cache" / "obj").string(); }

unsigned long long clearObjectCache() {
    std::error_code ec;
    unsigned long long bytes = 0;
    fs::path dir = objectCacheDir();
    for (auto& e : fs::directory_iterator(dir, ec))
        if (e.is_regular_file(ec)) bytes += e.file_size(ec);
    fs::remove_all(dir, ec);
    return bytes;
}

int compileWithCache(const std::vector<std::string>& cmd, const CompileCacheOptions& opts) {
    const char* off = std::getenv("FASET_NO_CACHE");
    if (cmd.empty() || (off && *off && *off != '0')) return opts.run(cmd, opts.verbose);

    // cc [opciones] fuentes.c ... -o salida [bibliotecas]
    std::vector<std::string> sources, compileFlags, includeDirs;
    std::vector<std::string> link = {cmd[0]};
    size_t firstSource = 0;
    for (size_t i = 1; i < cmd.size(); i++) {
        const std::string& a = cmd[i];
        if (a == "-o" && i + 1 < cmd.size()) {
            link.push_back(a);
            link.push_back(cmd[++i]);
            continue;
        }
        if (isCSource(a)) {
            if (sources.empty()) firstSource = link.size();
            sources.push_back(a);
            continue;
        }
        if (a == "-c" || a == "-E" || a == "-S") return opts.run(cmd, opts.verbose);  // no es una compilación completa
        if (isCompileFlag(a)) {
            compileFlags.push_back(a);
            if (a.rfind("-I", 0) == 0 && a.size() > 2) includeDirs.push_back(a.substr(2));
        }
        link.push_back(a);
    }
    if (sources.empty()) return opts.run(cmd, opts.verbose);

    std::error_code ec;
    fs::path shared = objectCacheDir();
    fs::create_directories(shared, ec);
    if (ec) return opts.run(cmd, opts.verbose);  // sin caché (carpeta de datos no escribible)
    if (!opts.programCacheDir.empty()) fs::create_directories(opts.programCacheDir, ec);

    std::string flagsKey = compilerIdentity(cmd[0]);
    for (const std::string& f : compileFlags) flagsKey += "\n" + f;

    struct Job {
        std::string source, object;
        bool cached = false;
    };
    std::vector<Job> jobs;
    for (size_t i = 0; i < sources.size(); i++) {
        Hasher h;
        h.add(flagsKey);
        std::set<std::string> seen;
        hashSourceTree(sources[i], includeDirs, h, seen);
        bool program = i == 0 && !opts.programCacheDir.empty();
        fs::path dir = program ? fs::path(opts.programCacheDir) : shared;
        std::string name = (program ? "programa-" : fs::path(sources[i]).stem().string() + "-") + h.hex() + ".o";
        if (i == 0 && opts.programCacheDir.empty()) {
            // Archivos sueltos: el C del programa no se guarda (cambia en cada compilación).
            dir = fs::temp_directory_path(ec) / ("faset-obj-" + uniqueSuffix());
            fs::create_directories(dir, ec);
        }
        Job j;
        j.source = sources[i];
        j.object = (dir / name).string();
        j.cached = fs::exists(j.object, ec) && fs::file_size(j.object, ec) > 0;
        if (j.cached) fs::last_write_time(j.object, fs::file_time_type::clock::now(), ec);  // uso reciente
        if (opts.verbose && j.cached) std::fprintf(stderr, "faset: cached: %s\n", fs::path(j.source).filename().string().c_str());
        jobs.push_back(j);
    }

    // Compila en paralelo los que faltan.
    std::vector<size_t> pending;
    for (size_t i = 0; i < jobs.size(); i++)
        if (!jobs[i].cached) pending.push_back(i);
    std::atomic<size_t> next{0};
    std::atomic<int> failure{0};
    auto worker = [&]() {
        for (;;) {
            size_t k = next++;
            if (k >= pending.size() || failure) return;
            Job& j = jobs[pending[k]];
            std::string tmp = j.object + ".tmp" + uniqueSuffix();
            std::vector<std::string> c = {cmd[0]};
            c.insert(c.end(), compileFlags.begin(), compileFlags.end());
            c.push_back("-c");
            c.push_back(j.source);
            c.push_back("-o");
            c.push_back(tmp);
            int r = opts.run(c, opts.verbose);
            std::error_code e2;
            if (r != 0) {
                fs::remove(tmp, e2);
                int expected = 0;
                failure.compare_exchange_strong(expected, r);
                return;
            }
            fs::rename(tmp, j.object, e2);
            if (e2) {  // otro proceso lo dejó a la vez: vale cualquiera de los dos
                fs::remove(tmp, e2);
            }
        }
    };
    size_t nThreads = std::min<size_t>(pending.size(), jobCount());
    std::vector<std::thread> threads;
    for (size_t t = 1; t < nThreads; t++) threads.emplace_back(worker);
    if (!pending.empty()) worker();
    for (std::thread& t : threads) t.join();

    if (!pending.empty()) pruneCache(shared);  // solo crece cuando se añaden objetos
    int result = failure;
    if (result == 0) {
        std::vector<std::string> objects;
        for (const Job& j : jobs) objects.push_back(j.object);
        link.insert(link.begin() + (long)firstSource, objects.begin(), objects.end());
        result = opts.run(link, opts.verbose);
    }
    // Objeto del programa: solo se guarda el último; los de archivos sueltos se borran.
    if (!jobs.empty()) {
        fs::path dir = fs::path(jobs[0].object).parent_path();
        if (opts.programCacheDir.empty()) {
            fs::remove_all(dir, ec);
        } else {
            for (auto& e : fs::directory_iterator(dir, ec)) {
                std::string n = e.path().filename().string();
                if (n.rfind("programa-", 0) == 0 && e.path() != fs::path(jobs[0].object)) fs::remove(e.path(), ec);
            }
        }
    }
    return result;
}
