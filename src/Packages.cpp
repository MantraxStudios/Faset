// Faset - gestor de paquetes (ver Packages.h).
//
// Resolución: se reúnen los <PackageReference> del proyecto y de los proyectos que referencia
// (ProjectReference) y, después, los de cada paquete elegido. Para cada nombre se elige la versión
// más alta que cumple todas las restricciones (o la del paquetes.lock, si aún las cumple), y se
// repite hasta que nada cambia. Si una dependencia indirecta choca con otra, se prueba con una
// versión anterior del paquete que la pide; si no hay salida, se explica el conflicto.
#include "Packages.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <set>
#include <sstream>

#if defined(_WIN32)
#include <process.h>
#define popen _popen
#define pclose _pclose
#define getpid _getpid
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "Frontend.h"
#include "Json.h"
#include "Project.h"
#include "Setup.h"
#include "Solution.h"

namespace fs = std::filesystem;

namespace {

using Strings = std::vector<std::string>;

const char* const kLockName = "paquetes.lock";
const char* const kDefaultIndex = "https://faset.lat/paquetes/index.json";

bool gOffline = false;  // --offline o FASET_OFFLINE=1: nada de red, solo la caché
bool gVerbose = false;

void fail(const std::string& msg) { std::fprintf(stderr, "faset: error: %s\n", msg.c_str()); }
void warn(const std::string& msg) { std::fprintf(stderr, "faset: aviso: %s\n", msg.c_str()); }
void progress(const std::string& msg) {
    std::fprintf(stderr, "  %s\n", msg.c_str());
    std::fflush(stderr);
}

std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n"), z = s.find_last_not_of(" \t\r\n");
    return a == std::string::npos ? "" : s.substr(a, z - a + 1);
}

std::string lower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

bool startsWith(const std::string& s, const std::string& p) { return s.compare(0, p.size(), p) == 0; }
bool endsWith(const std::string& s, const std::string& p) {
    return s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0;
}

std::string join(const Strings& v, const std::string& sep) {
    std::string r;
    for (size_t i = 0; i < v.size(); i++) r += (i ? sep : "") + v[i];
    return r;
}

std::string readFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

bool writeFileText(const std::string& path, const std::string& text) {
    std::ofstream f(path, std::ios::binary);
    f << text;
    return (bool)f;
}

std::string slash(std::string p) {
    std::replace(p.begin(), p.end(), '\\', '/');
    return p;
}

// Ruta relativa con '/' (o absoluta si no hay forma relativa).
std::string relativeTo(const std::string& path, const std::string& base) {
    std::error_code ec;
    fs::path r = fs::relative(fs::weakly_canonical(path, ec), fs::weakly_canonical(base, ec), ec);
    if (ec || r.empty()) return slash(path);
    return r.generic_string();
}

std::string canonical(const std::string& p) {
    std::error_code ec;
    fs::path c = fs::weakly_canonical(p, ec);
    return (ec ? fs::path(p) : c).lexically_normal().string();
}

bool validName(const std::string& n) {
    if (n.empty() || n.size() > 100) return false;
    for (char c : n)
        if (!std::isalnum((unsigned char)c) && c != '.' && c != '_' && c != '-') return false;
    return n[0] != '.' && n[0] != '-';
}

bool looksLikeGitUrl(const std::string& s) {
    return s.find("://") != std::string::npos || startsWith(s, "git@") || endsWith(s, ".git") || endsWith(s, ".git/");
}

// Un repositorio en el disco (no una URL): ../repos/x.git
bool isLocalGitPath(const std::string& s) { return s.find("://") == std::string::npos && !startsWith(s, "git@"); }

// ------------------------------------------------------------------ procesos

std::string quote(const std::string& s) {
#if defined(_WIN32)
    return windowsQuote(s);
#else
    std::string r = "'";
    for (char c : s) r += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return r + "'";
#endif
}

// Ejecuta una orden y recoge su salida (stdout y stderr juntos). Devuelve el código de salida.
int runCapture(const Strings& args, std::string& out) {
    std::string cmd;
    for (size_t i = 0; i < args.size(); i++) cmd += (i ? " " : "") + quote(args[i]);
    if (gVerbose) std::fprintf(stderr, "  $ %s\n", cmd.c_str());
    cmd += " 2>&1";
#if defined(_WIN32)
    cmd = "\"" + cmd + "\"";
#endif
    std::fflush(stdout);
    std::fflush(stderr);
    FILE* p = popen(cmd.c_str(), "r");
    out.clear();
    if (!p) return -1;
    char buf[4096];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, p)) > 0) out.append(buf, n);
    int r = pclose(p);
#if !defined(_WIN32)
    if (r != -1 && WIFEXITED(r)) r = WEXITSTATUS(r);
    else if (r != -1) r = 1;
#endif
    return r;
}

// Últimas líneas de la salida de git (para los mensajes de error).
std::string gitTail(const std::string& out) {
    std::string t = trim(out);
    Strings lines;
    std::stringstream ss(t);
    std::string l;
    while (std::getline(ss, l))
        if (!trim(l).empty() && trim(l).rfind("warning:", 0) != 0) lines.push_back(trim(l));
    if (lines.size() > 3) lines.erase(lines.begin(), lines.end() - 3);
    return lines.empty() ? "" : " (" + join(lines, " / ") + ")";
}

bool haveGit(std::string& err) {
    static int known = -1;
    if (known < 0) known = findProgram("git").empty() ? 0 : 1;
    if (!known) err = "hace falta git para descargar paquetes (instálalo y vuelve a probar)";
    return known == 1;
}

int git(const Strings& args, std::string& out) {
    // Sin preguntas de usuario/contraseña en la terminal (la salida va a un tubo y parecería
    // colgado): los ayudantes de credenciales y las claves SSH siguen funcionando.
    static bool env = false;
    if (!env) {
        env = true;
        if (!std::getenv("GIT_TERMINAL_PROMPT")) {
#if defined(_WIN32)
            _putenv_s("GIT_TERMINAL_PROMPT", "0");
#else
            setenv("GIT_TERMINAL_PROMPT", "0", 1);
#endif
        }
    }
    Strings a = {"git", "-c", "advice.detachedHead=false", "-c", "core.autocrlf=false"};
    a.insert(a.end(), args.begin(), args.end());
    return runCapture(a, out);
}

bool offlineError(const std::string& what, std::string& err) {
    if (!gOffline) return false;
    err = "sin conexión (--offline / FASET_OFFLINE): hace falta " + what + " y no está en la caché";
    return true;
}

// ------------------------------------------------------------------ semver

struct Semver {
    long major = 0, minor = 0, patch = 0;
    std::string pre;  // 1.0.0-beta.1 -> "beta.1"
    std::string str() const {
        return std::to_string(major) + "." + std::to_string(minor) + "." + std::to_string(patch) + (pre.empty() ? "" : "-" + pre);
    }
};

// "v1.2.3", "1.2", "1", "1.2.x" -> versión y cuántas partes se escribieron (1-3). Las partes
// comodín (x, X, *) no cuentan.
bool parseSemver(std::string s, Semver& v, int* parts = nullptr) {
    s = trim(s);
    if (!s.empty() && (s[0] == 'v' || s[0] == 'V')) s = s.substr(1);
    size_t plus = s.find('+');
    if (plus != std::string::npos) s = s.substr(0, plus);
    v = Semver();
    size_t dash = s.find('-');
    if (dash != std::string::npos) {
        v.pre = s.substr(dash + 1);
        s = s.substr(0, dash);
        if (v.pre.empty()) return false;
    }
    long* fields[3] = {&v.major, &v.minor, &v.patch};
    int n = 0;
    size_t k = 0;
    while (k <= s.size() && n < 3) {
        size_t dot = s.find('.', k);
        std::string part = s.substr(k, dot == std::string::npos ? std::string::npos : dot - k);
        if (part == "x" || part == "X" || part == "*") {
            if (dot != std::string::npos && s.substr(dot + 1).find_first_not_of(".xX*") != std::string::npos) return false;
            break;
        }
        if (part.empty() || part.size() > 9 || part.find_first_not_of("0123456789") != std::string::npos) return false;
        *fields[n++] = std::atol(part.c_str());
        if (dot == std::string::npos) {
            k = std::string::npos;
            break;
        }
        k = dot + 1;
    }
    if (k != std::string::npos && n == 3) return false;  // más de tres partes
    if (n == 0) return false;
    if (parts) *parts = n;
    return true;
}

int cmpPre(const std::string& a, const std::string& b) {
    if (a == b) return 0;
    if (a.empty()) return 1;  // 1.0.0 > 1.0.0-beta
    if (b.empty()) return -1;
    std::stringstream sa(a), sb(b);
    std::string x, y;
    for (;;) {
        bool ha = (bool)std::getline(sa, x, '.'), hb = (bool)std::getline(sb, y, '.');
        if (!ha || !hb) return ha ? 1 : (hb ? -1 : 0);
        bool na = !x.empty() && x.find_first_not_of("0123456789") == std::string::npos;
        bool nb = !y.empty() && y.find_first_not_of("0123456789") == std::string::npos;
        if (na && nb) {
            long ia = std::atol(x.c_str()), ib = std::atol(y.c_str());
            if (ia != ib) return ia < ib ? -1 : 1;
        } else if (na != nb) {
            return na ? -1 : 1;
        } else if (x != y) {
            return x < y ? -1 : 1;
        }
    }
}

int cmpSemver(const Semver& a, const Semver& b) {
    if (a.major != b.major) return a.major < b.major ? -1 : 1;
    if (a.minor != b.minor) return a.minor < b.minor ? -1 : 1;
    if (a.patch != b.patch) return a.patch < b.patch ? -1 : 1;
    return cmpPre(a.pre, b.pre);
}

struct Comparator {
    enum Op { Eq, Gt, Ge, Lt, Le } op = Eq;
    Semver v;
};

// Restricción de versión: alternativas (||) de condiciones que se cumplen a la vez.
struct Range {
    std::vector<std::vector<Comparator>> alts;
    bool allowPre = false;  // solo si la restricción nombra una versión preliminar
    std::string text;
};

bool parseRange(const std::string& text, Range& r, std::string& err) {
    r = Range();
    r.text = trim(text);
    r.allowPre = r.text.find('-') != std::string::npos;
    std::string rest = r.text;
    Strings altTexts;
    for (size_t k; (k = rest.find("||")) != std::string::npos; rest = rest.substr(k + 2)) altTexts.push_back(rest.substr(0, k));
    altTexts.push_back(rest);
    for (std::string alt : altTexts) {
        for (char& c : alt)
            if (c == ',') c = ' ';
        Strings toks;
        std::stringstream ss(alt);
        std::string t;
        while (ss >> t) {
            // '>= 1.0' -> '>=1.0'
            if (!toks.empty() && toks.back().find_first_not_of("<>=^~") == std::string::npos) toks.back() += t;
            else toks.push_back(t);
        }
        std::vector<Comparator> all;
        for (const std::string& tok : toks) {
            if (tok == "*" || tok == "x" || tok == "X" || lower(tok) == "latest") continue;
            std::string op;
            size_t i = 0;
            while (i < tok.size() && std::string("<>=^~").find(tok[i]) != std::string::npos) op += tok[i++];
            Semver v;
            int parts = 0;
            if (!parseSemver(tok.substr(i), v, &parts)) {
                err = "versión no válida '" + tok + "' (ejemplos: 1.2.0, ^1.2, ~1.2, >=1.0 <2.0)";
                return false;
            }
            Semver lo = v, hi;
            hi.pre = "";
            auto bounds = [&](Semver up) {
                all.push_back({Comparator::Ge, lo});
                up.pre = "";
                all.push_back({Comparator::Lt, up});
            };
            if (op == "^") {
                if (v.major > 0 || parts == 1) hi.major = v.major + 1;
                else if (v.minor > 0 || parts == 2) hi.minor = v.minor + 1;
                else hi.patch = v.patch + 1;
                bounds(hi);
            } else if (op == "~") {
                hi.major = v.major;
                if (parts == 1) hi.major = v.major + 1;
                else hi.minor = v.minor + 1;
                bounds(hi);
            } else if (op.empty() || op == "=" || op == "==") {
                if (parts == 3) all.push_back({Comparator::Eq, v});
                else {
                    hi.major = v.major;
                    if (parts == 1) hi.major++;
                    else hi.minor = v.minor + 1;
                    bounds(hi);
                }
            } else if (op == ">") all.push_back({Comparator::Gt, v});
            else if (op == ">=") all.push_back({Comparator::Ge, v});
            else if (op == "<") all.push_back({Comparator::Lt, v});
            else if (op == "<=") all.push_back({Comparator::Le, v});
            else {
                err = "operador desconocido '" + op + "' en la versión '" + r.text + "'";
                return false;
            }
        }
        r.alts.push_back(all);
    }
    return true;
}

bool satisfies(const Range& r, const Semver& v) {
    if (!v.pre.empty() && !r.allowPre) return false;
    for (const auto& all : r.alts) {
        bool ok = true;
        for (const Comparator& c : all) {
            int k = cmpSemver(v, c.v);
            switch (c.op) {
                case Comparator::Eq: ok = k == 0; break;
                case Comparator::Gt: ok = k > 0; break;
                case Comparator::Ge: ok = k >= 0; break;
                case Comparator::Lt: ok = k < 0; break;
                case Comparator::Le: ok = k <= 0; break;
            }
            if (!ok) break;
        }
        if (ok) return true;
    }
    return false;
}

// ------------------------------------------------------------------ git

struct Tag {
    std::string name, commit;
    Semver v;
};

std::map<std::string, std::vector<Tag>> gTagCache;

// Etiquetas semver del repositorio (git ls-remote --tags), de mayor a menor.
bool listTags(const std::string& url, std::vector<Tag>& tags, std::string& err) {
    auto it = gTagCache.find(url);
    if (it != gTagCache.end()) {
        tags = it->second;
        return true;
    }
    if (offlineError("consultar las versiones de " + url, err) || !haveGit(err)) return false;
    std::string out;
    if (git({"ls-remote", "--tags", url}, out) != 0) {
        err = "no se pudo consultar el repositorio " + url + gitTail(out);
        return false;
    }
    std::map<std::string, Tag> byName;
    std::stringstream ss(out);
    std::string line;
    while (std::getline(ss, line)) {
        size_t tab = line.find('\t');
        if (tab == std::string::npos || tab < 7) continue;
        std::string sha = trim(line.substr(0, tab)), ref = trim(line.substr(tab + 1));
        if (!startsWith(ref, "refs/tags/")) continue;
        std::string name = ref.substr(10);
        bool peeled = endsWith(name, "^{}");
        if (peeled) name = name.substr(0, name.size() - 3);
        Semver v;
        int parts = 0;
        if (!parseSemver(name, v, &parts) || parts != 3) continue;
        Tag& t = byName[name];
        t.name = name;
        t.v = v;
        if (peeled || t.commit.empty()) t.commit = sha;  // etiquetas anotadas: el commit es el '^{}'
    }
    tags.clear();
    for (auto& [n, t] : byName) tags.push_back(t);
    std::sort(tags.begin(), tags.end(), [](const Tag& a, const Tag& b) {
        int c = cmpSemver(a.v, b.v);
        return c != 0 ? c > 0 : a.name < b.name;  // 'v1.0.0' antes que '1.0.0'
    });
    // Si existen 'v1.0.0' y '1.0.0', vale la primera.
    std::vector<Tag> unique;
    for (const Tag& t : tags)
        if (unique.empty() || cmpSemver(unique.back().v, t.v) != 0) unique.push_back(t);
    tags = unique;
    gTagCache[url] = tags;
    return true;
}

// Commit al que apunta una referencia remota (refs/heads/main, HEAD).
bool remoteRef(const std::string& url, const std::string& ref, std::string& sha, std::string& err) {
    if (offlineError("consultar " + ref + " de " + url, err) || !haveGit(err)) return false;
    std::string out;
    if (git({"ls-remote", url, ref}, out) != 0) {
        err = "no se pudo consultar el repositorio " + url + gitTail(out);
        return false;
    }
    std::stringstream ss(out);
    std::string line;
    while (std::getline(ss, line)) {
        size_t tab = line.find('\t');
        if (tab != std::string::npos && trim(line.substr(tab + 1)) == ref) {
            sha = trim(line.substr(0, tab));
            return true;
        }
    }
    err = "el repositorio " + url + " no tiene " + (startsWith(ref, "refs/heads/") ? "la rama '" + ref.substr(11) + "'" : ref);
    return false;
}

// Commit de una descarga de la caché. Allí HEAD siempre está separado (un sha en .git/HEAD), así
// que normalmente basta con leer el archivo, sin llamar a git.
std::string headCommit(const std::string& dir) {
    std::error_code ec;
    if (!fs::exists(fs::path(dir) / ".git", ec)) return "";
    {
        std::ifstream f(fs::path(dir) / ".git" / "HEAD");
        std::string line;
        if (f && std::getline(f, line)) {
            line = trim(line);
            if (line.size() == 40 && line.find_first_not_of("0123456789abcdef") == std::string::npos) return line;
        }
    }
    std::string out;
    if (git({"-C", dir, "rev-parse", "HEAD"}, out) != 0) return "";
    return trim(out);
}

std::string tempDirFor(const std::string& dest) {
    return dest + ".tmp-" + std::to_string((long)getpid());
}

// Mueve la descarga terminada a su sitio (si otro proceso ya la puso, se queda la suya).
bool settle(const std::string& tmp, const std::string& dest, std::string& err) {
    std::error_code ec;
    fs::rename(tmp, dest, ec);
    if (ec) {
        fs::remove_all(tmp, ec);
        if (!fs::exists(dest)) {
            err = "no se pudo crear " + dest;
            return false;
        }
    }
    return true;
}

// git clone --depth 1 --branch <etiqueta>
bool cloneTag(const std::string& url, const std::string& tag, const std::string& dest, std::string& err) {
    if (offlineError(url + " " + tag, err) || !haveGit(err)) return false;
    std::error_code ec;
    fs::create_directories(fs::path(dest).parent_path(), ec);
    std::string tmp = tempDirFor(dest), out;
    fs::remove_all(tmp, ec);
    if (git({"clone", "-q", "--depth", "1", "--branch", tag, url, tmp}, out) != 0) {
        fs::remove_all(tmp, ec);
        err = "no se pudo descargar " + url + " (" + tag + ")" + gitTail(out);
        return false;
    }
    return settle(tmp, dest, err);
}

// Un commit concreto: primero 'git fetch --depth 1 <sha>'; si el servidor no lo permite, clon completo.
bool cloneCommit(const std::string& url, const std::string& commit, const std::string& dest, std::string& err) {
    if (offlineError(url + " @" + commit, err) || !haveGit(err)) return false;
    std::error_code ec;
    fs::create_directories(fs::path(dest).parent_path(), ec);
    std::string tmp = tempDirFor(dest), out;
    fs::remove_all(tmp, ec);
    bool ok = false;
    if (commit.size() == 40) {
        ok = git({"init", "-q", tmp}, out) == 0 && git({"-C", tmp, "fetch", "-q", "--depth", "1", url, commit}, out) == 0 &&
             git({"-C", tmp, "checkout", "-q", "FETCH_HEAD"}, out) == 0;
        if (!ok) fs::remove_all(tmp, ec);
    }
    if (!ok) {
        ok = git({"clone", "-q", "--no-checkout", url, tmp}, out) == 0 && git({"-C", tmp, "checkout", "-q", commit}, out) == 0;
        if (!ok) {
            fs::remove_all(tmp, ec);
            err = "no se pudo descargar " + url + " en el commit " + commit + gitTail(out);
            return false;
        }
    }
    return settle(tmp, dest, err);
}

// ------------------------------------------------------------------ caché

std::string cacheRoot(std::string& err) {
    const char* over = std::getenv("FASET_PAQUETES_CACHE");
    if (over && *over) return over;
    std::string d = fasetDataDir();
    if (d.empty()) {
        err = "no se encuentra la carpeta de datos del usuario (HOME / LOCALAPPDATA)";
        return "";
    }
    return (fs::path(d) / "paquetes").string();
}

std::string cacheDirFor(const std::string& name, const std::string& version, const std::string& commit) {
    std::string err, root = cacheRoot(err);
    if (root.empty()) return "";
    // En minúsculas: 'Json5' y 'json5' son el mismo paquete (y así no importa si el disco distingue).
    return (fs::path(root) / lower(name) / (version.empty() ? commit.substr(0, 12) : version)).string();
}

// El .fstproj de una carpeta (o la ruta, si ya es un .fstproj).
std::string projectIn(const std::string& dir, std::string& err) {
    std::error_code ec;
    if (fs::path(dir).extension() == ".fstproj" && fs::is_regular_file(dir, ec)) return dir;
    if (!fs::is_directory(dir, ec)) {
        err = "no existe la carpeta '" + dir + "'";
        return "";
    }
    Strings found;
    for (auto& e : fs::directory_iterator(dir, ec))
        if (e.path().extension() == ".fstproj") found.push_back(e.path().string());
    if (found.size() == 1) return found[0];
    err = found.empty() ? "no hay ningún .fstproj en '" + dir + "' (¿falta Folder=\"...\"?)"
                        : "hay varios .fstproj en '" + dir + "'";
    return "";
}

std::string packageIdOf(const Project& p) {
    std::string id = p.prop("PackageId");
    if (id.empty()) id = p.prop("AssemblyName");
    if (id.empty()) id = fs::path(p.path).stem().string();
    return id;
}

// ------------------------------------------------------------------ índice

struct IndexEntry {
    std::string git, folder, description;
    Strings versions;
};

std::string gIndexUrl;  // la elige el proyecto raíz (FASET_PAQUETES_INDICE > <PackageIndex> > faset.lat)

std::string indexUrlFor(const Project* root) {
    const char* env = std::getenv("FASET_PAQUETES_INDICE");
    if (env && *env) return env;
    if (root && !root->prop("PackageIndex").empty()) return root->prop("PackageIndex");
    return kDefaultIndex;
}

// Lee el índice una vez por proceso. Si no se puede descargar se usa la última copia guardada.
const Json* loadIndex(std::string& why) {
    static bool loaded = false;
    static Json index;
    static bool ok = false;
    static std::string lastWhy;
    if (loaded) {
        why = lastWhy;
        return ok ? &index : nullptr;
    }
    loaded = true;
    std::string url = gIndexUrl.empty() ? kDefaultIndex : gIndexUrl, text, err;
    std::string root = cacheRoot(err);
    std::string copy = root.empty() ? "" : (fs::path(root) / ("indice-" + std::to_string(std::hash<std::string>()(url) % 100000000) + ".json")).string();
    bool got = false;
    std::error_code ec;
    if (startsWith(url, "file://") || url.find("://") == std::string::npos) {
        std::string p = startsWith(url, "file://") ? url.substr(7) : url;
        if (fs::is_regular_file(p, ec)) {
            text = readFile(p);
            got = true;
        }
    } else if (!gOffline) {
        got = fetchUrlText(url, text);
        if (got && !copy.empty()) {
            fs::create_directories(fs::path(copy).parent_path(), ec);
            writeFileText(copy, text);
        }
    }
    if (!got && !copy.empty() && fs::is_regular_file(copy, ec)) {
        text = readFile(copy);
        got = true;
    }
    if (!got) {
        lastWhy = "el índice de paquetes (" + url + ") no está disponible todavía";
        why = lastWhy;
        return nullptr;
    }
    std::string perr;
    if (!Json::parse(text, index, &perr) || !index.get("paquetes").isObject()) {
        lastWhy = "el índice de paquetes (" + url + ") no es válido" + (perr.empty() ? "" : ": " + perr);
        why = lastWhy;
        return nullptr;
    }
    ok = true;
    return &index;
}

bool indexLookup(const std::string& name, IndexEntry& e, std::string& why) {
    const Json* idx = loadIndex(why);
    if (!idx) return false;
    for (const auto& [k, v] : idx->get("paquetes").items()) {
        if (lower(k) != lower(name)) continue;
        e.git = v.get("git").asString();
        e.folder = v.get("carpeta").asString();
        e.description = v.get("descripcion").asString();
        for (const Json& x : v.get("versiones").elements()) e.versions.push_back(x.asString());
        if (e.git.empty()) {
            why = "el paquete '" + k + "' del índice no tiene \"git\"";
            return false;
        }
        return true;
    }
    why = "el paquete '" + name + "' no está en el índice (" + (gIndexUrl.empty() ? kDefaultIndex : gIndexUrl) + ")";
    return false;
}

// ------------------------------------------------------------------ paquetes.lock

struct Locked {
    std::string name, git, path, folder, version, tag, branch, commit;
    bool pinned = false;  // Commit="..." en el .fstproj
    Strings deps;
};

std::string lockPathFor(const std::string& projPath) {
    return (fs::path(projPath).parent_path() / kLockName).string();
}

bool readLock(const std::string& path, std::vector<Locked>& out) {
    out.clear();
    std::error_code ec;
    if (!fs::is_regular_file(path, ec)) return false;
    Json j;
    if (!Json::parse(readFile(path), j) || !j.get("paquetes").isArray()) {
        warn(path + " no es válido; se vuelve a resolver todo");
        return false;
    }
    for (const Json& e : j.get("paquetes").elements()) {
        Locked l;
        l.name = e.get("nombre").asString();
        l.git = e.get("git").asString();
        // Repositorios locales: relativos a la carpeta del paquetes.lock.
        if (!l.git.empty() && isLocalGitPath(l.git) && !fs::path(l.git).is_absolute())
            l.git = (fs::path(path).parent_path() / l.git).lexically_normal().string();
        l.path = e.get("ruta").asString();
        l.folder = e.get("carpeta").asString();
        l.version = e.get("version").asString();
        l.tag = e.get("etiqueta").asString();
        l.branch = e.get("rama").asString();
        l.commit = e.get("commit").asString();
        l.pinned = e.get("fijo").asBool();
        for (const Json& d : e.get("dependencias").elements()) l.deps.push_back(d.asString());
        if (!l.name.empty()) out.push_back(l);
    }
    return true;
}

std::string lockText(const std::vector<Locked>& entries) {
    auto str = [](const std::string& s) { return Json(s).dump(); };
    std::string t = "{\n  \"formato\": 1,\n  \"generadoPor\": \"faset\",\n  \"paquetes\": [";
    for (size_t i = 0; i < entries.size(); i++) {
        const Locked& l = entries[i];
        t += i ? ",\n" : "\n";
        t += "    {\n      \"nombre\": " + str(l.name);
        auto field = [&](const char* k, const std::string& v) {
            if (!v.empty()) t += ",\n      \"" + std::string(k) + "\": " + str(v);
        };
        field("git", l.git);
        field("ruta", l.path);
        field("carpeta", l.folder);
        field("version", l.version);
        field("etiqueta", l.tag);
        field("rama", l.branch);
        field("commit", l.commit);
        if (l.pinned) t += ",\n      \"fijo\": true";
        t += ",\n      \"dependencias\": [";
        for (size_t k = 0; k < l.deps.size(); k++) t += (k ? ", " : "") + str(l.deps[k]);
        t += "]\n    }";
    }
    t += entries.empty() ? "]\n}\n" : "\n  ]\n}\n";
    return t;
}

// ------------------------------------------------------------------ resolución

struct Source {
    bool isPath = false;
    std::string git, folder, path;  // path: carpeta o .fstproj absoluto
    std::string describe() const {
        if (isPath) return "ruta " + path;
        return "git " + git + (folder.empty() ? "" : " (carpeta " + folder + ")");
    }
};

std::string normGit(std::string u) {
    u = trim(u);
    while (endsWith(u, "/")) u.pop_back();
    if (endsWith(u, ".git")) u = u.substr(0, u.size() - 4);
    size_t scheme = u.find("://");
    if (scheme != std::string::npos) {
        size_t hostEnd = u.find('/', scheme + 3);
        u = lower(u.substr(0, hostEnd)) + (hostEnd == std::string::npos ? "" : u.substr(hostEnd));
    }
    return u;
}

bool sameSource(const Source& a, const Source& b) {
    if (a.isPath != b.isPath) return false;
    if (a.isPath) return canonical(a.path) == canonical(b.path);
    return normGit(a.git) == normGit(b.git) && slash(a.folder) == slash(b.folder);
}


struct Req {
    PackageRef ref;
    std::string by;       // quién lo pide (para los mensajes)
    std::string byKey;    // nombre del paquete que lo pide ("" = un proyecto local)
    bool local = false;   // lo pide el proyecto raíz o uno de sus ProjectReference
    Source src;
};

struct Node {
    std::string name;
    Source src;
    std::string version, tag, branch, commit;
    bool pinnedCommit = false;
    std::string dir, project;
    std::vector<Req> children;
};

struct Resolver {
    std::string rootProj, lockPath;
    Project root;
    std::vector<Locked> lock;
    bool hasLock = false;
    bool updateAll = false;
    std::set<std::string> updating;  // nombres en minúsculas
    std::vector<Req> localReqs;
    std::map<std::string, Node> chosen;               // nombre en minúsculas -> paquete elegido
    std::map<std::string, std::set<std::string>> excluded;  // versiones descartadas al retroceder
    std::map<std::string, std::string> displayName;
    bool announced = false;
    std::vector<Locked> result;

    void say(const std::string& msg) {
        if (!announced) {
            std::fprintf(stderr, "Restaurando paquetes de %s...\n", fs::path(rootProj).filename().string().c_str());
            announced = true;
        }
        progress(msg);
    }

    const Locked* locked(const std::string& name) const {
        for (const Locked& l : lock)
            if (lower(l.name) == lower(name)) return &l;
        return nullptr;
    }

    bool isUpdating(const std::string& key) const { return updateAll || updating.count(key); }

    // Origen de una referencia (Path, Git, el paquetes.lock o el índice).
    bool sourceOf(Req& r, const std::string& baseDir, std::string& err) {
        const PackageRef& p = r.ref;
        if (!p.path.empty()) {
            r.src.isPath = true;
            r.src.path = (fs::path(baseDir) / p.path).lexically_normal().string();
            r.src.folder = p.folder;
            if (!p.folder.empty()) r.src.path = (fs::path(r.src.path) / p.folder).lexically_normal().string();
            return true;
        }
        if (!p.git.empty()) {
            r.src.git = p.git;
            // Git="../repos/x.git": relativa al proyecto que la declara.
            if (isLocalGitPath(p.git) && !fs::path(p.git).is_absolute())
                r.src.git = (fs::path(baseDir) / p.git).lexically_normal().string();
            r.src.folder = p.folder;
            return true;
        }
        std::string key = lower(p.name);
        const Locked* l = locked(p.name);
        if (l && !l->git.empty() && !isUpdating(key)) {
            r.src.git = l->git;
            r.src.folder = p.folder.empty() ? l->folder : p.folder;
            return true;
        }
        IndexEntry e;
        std::string why;
        if (!indexLookup(p.name, e, why)) {
            err = r.by + ": paquete desconocido '" + p.name + "': " + why +
                  ".\n  Indica de dónde sale: Git=\"https://...\" o Path=\"../carpeta\"";
            return false;
        }
        r.src.git = e.git;
        r.src.folder = p.folder.empty() ? e.folder : p.folder;
        return true;
    }

    // Proyecto del paquete ya descargado: comprueba que es una biblioteca y lee sus referencias.
    bool loadNode(Node& n, std::string& err) {
        std::string base = n.src.isPath ? n.src.path : (n.src.folder.empty() ? n.dir : (fs::path(n.dir) / n.src.folder).string());
        std::string perr;
        n.project = projectIn(base, perr);
        if (n.project.empty()) {
            err = "paquete '" + n.name + "': " + perr;
            return false;
        }
        Project p;
        if (!loadProject(n.project, p, perr)) {
            err = "paquete '" + n.name + "': " + perr;
            return false;
        }
        if (p.prop("OutputType", "Exe") != "Library") {
            err = "paquete '" + n.name + "': " + n.project + " no es una biblioteca (OutputType debe ser Library)";
            return false;
        }
        n.children.clear();
        std::string by = n.name + (n.version.empty() ? (n.commit.empty() ? "" : " @" + n.commit.substr(0, 7)) : " " + n.version);
        for (const PackageRef& pr : p.packages) {
            Req r;
            r.ref = pr;
            r.by = by;
            r.byKey = lower(n.name);
            if (!sourceOf(r, p.dir, err)) return false;
            n.children.push_back(r);
        }
        return true;
    }

    // Deja el paquete en la caché (sin red si ya está).
    bool materialize(Node& n, bool fromLock, std::string& err) {
        if (n.src.isPath) {
            n.dir = n.src.path;
            return loadNode(n, err);
        }
        std::string dir = cacheDirFor(n.name, n.version, n.commit);
        if (dir.empty()) {
            err = "no se encuentra la carpeta de la caché de paquetes";
            return false;
        }
        std::string have = headCommit(dir);
        if (!have.empty() && (n.commit.empty() || startsWith(have, lower(n.commit)) || startsWith(have, n.commit))) {
            n.dir = dir;
            n.commit = have;
            return loadNode(n, err);
        }
        std::error_code ec;
        if (fs::exists(dir, ec)) {
            if (!n.tag.empty() && fromLock && !have.empty()) {
                // La caché tiene esa versión en otro commit (la etiqueta se movió): manda el
                // paquetes.lock, en una carpeta por commit.
                std::string cdir = cacheDirFor(n.name, "", n.commit);
                std::string h2 = headCommit(cdir);
                if (!h2.empty() && startsWith(h2, n.commit)) {
                    n.dir = cdir;
                    return loadNode(n, err);
                }
                if (!h2.empty() || fs::exists(cdir, ec)) fs::remove_all(cdir, ec);
                say("Descargando " + n.name + " @" + n.commit.substr(0, 7) + " (" + n.src.git + ")");
                if (!cloneCommit(n.src.git, n.commit, cdir, err)) return false;
                n.dir = cdir;
                n.commit = headCommit(cdir);
                return loadNode(n, err);
            }
            fs::remove_all(dir, ec);  // descarga incompleta o rota
        }
        if (!n.tag.empty()) {
            say("Descargando " + n.name + " " + n.version + " (" + n.src.git + ")");
            if (!cloneTag(n.src.git, n.tag, dir, err)) return false;
            std::string got = headCommit(dir);
            if (!n.commit.empty() && !startsWith(got, n.commit)) {
                fs::remove_all(dir, ec);
                if (fromLock)
                    warn("la etiqueta " + n.tag + " de '" + n.name + "' ya no apunta al commit de paquetes.lock (" +
                         n.commit.substr(0, 7) + "); se usa ese commit");
                std::string cdir = cacheDirFor(n.name, "", n.commit);
                if (!cloneCommit(n.src.git, n.commit, cdir, err)) return false;
                n.dir = cdir;
                n.commit = headCommit(cdir);
                return loadNode(n, err);
            }
            n.dir = dir;
            n.commit = got;
            return loadNode(n, err);
        }
        say("Descargando " + n.name + " @" + n.commit.substr(0, 7) + " (" + n.src.git + ")");
        if (!cloneCommit(n.src.git, n.commit, dir, err)) return false;
        n.dir = dir;
        n.commit = headCommit(dir);
        // Commit="abc1234" (abreviado): la carpeta se renombra con el commit completo.
        std::string full = cacheDirFor(n.name, "", n.commit);
        if (full != dir && !fs::exists(full, ec)) {
            fs::rename(dir, full, ec);
            if (!ec) n.dir = full;
        }
        return loadNode(n, err);
    }

    struct Pin {
        std::string commit, branch;
        const Req* req = nullptr;
    };

    bool accepts(const Node& n, const Pin& pin, const std::vector<std::pair<Range, const Req*>>& ranges) const {
        if (!pin.commit.empty()) return startsWith(lower(n.commit), lower(pin.commit));
        if (!pin.branch.empty()) return n.branch == pin.branch;
        if (!n.branch.empty() || n.pinnedCommit) return false;
        std::string key = lower(n.name);
        auto ex = excluded.find(key);
        if (ex != excluded.end() && ex->second.count(n.version)) return false;
        if (ranges.empty()) return true;
        Semver v;
        if (n.version.empty() || !parseSemver(n.version, v)) return false;
        for (const auto& [r, q] : ranges)
            if (!satisfies(r, v)) return false;
        return true;
    }

    // Elige (y descarga) una versión de 'name'. 'conflict' se rellena si ninguna versión vale.
    bool choose(const std::string& key, const std::vector<Req>& reqs, Node& out, std::string& err, bool& conflict) {
        conflict = false;
        const Req* lead = nullptr;
        for (const Req& r : reqs)
            if (r.local) {
                lead = &r;
                break;
            }
        if (!lead) lead = &reqs[0];
        std::string name = lead->ref.name;
        // Mismo origen para todos (el proyecto raíz manda sobre las dependencias indirectas).
        std::vector<const Req*> same;
        for (const Req& r : reqs) {
            if (sameSource(r.src, lead->src)) {
                same.push_back(&r);
                continue;
            }
            if (lead->local && !r.local) continue;
            err = "el paquete '" + name + "' se pide con orígenes distintos:\n  " + lead->by + ": " + lead->src.describe() + "\n  " +
                  r.by + ": " + r.src.describe();
            return false;
        }
        Node n;
        n.name = name;
        n.src = lead->src;
        if (n.src.isPath) {
            if (!materialize(n, false, err)) return false;
            out = n;
            return true;
        }
        Pin pin;
        std::vector<std::pair<Range, const Req*>> ranges;
        for (const Req* r : same) {
            if (!r->ref.commit.empty() || !r->ref.branch.empty()) {
                if (pin.req && (lower(pin.commit) != lower(r->ref.commit) || pin.branch != r->ref.branch)) {
                    err = "el paquete '" + name + "' se fija a dos versiones distintas:\n  " + pin.req->by + ": " +
                          (pin.commit.empty() ? "Branch=" + pin.branch : "Commit=" + pin.commit) + "\n  " + r->by + ": " +
                          (r->ref.commit.empty() ? "Branch=" + r->ref.branch : "Commit=" + r->ref.commit);
                    return false;
                }
                pin.commit = r->ref.commit;
                pin.branch = r->ref.branch;
                pin.req = r;
            }
            if (!trim(r->ref.version).empty()) {
                Range rg;
                std::string perr;
                if (!parseRange(r->ref.version, rg, perr)) {
                    err = r->by + ": paquete '" + name + "': " + perr;
                    return false;
                }
                ranges.push_back({rg, r});
            }
        }
        if (pin.req && !ranges.empty()) ranges.clear();  // Branch/Commit mandan sobre Version
        // 1) El que ya estaba elegido.
        auto cur = chosen.find(key);
        if (cur != chosen.end() && sameSource(cur->second.src, n.src) && accepts(cur->second, pin, ranges)) {
            out = cur->second;
            return true;
        }
        // 2) El del paquetes.lock (sin red si está en la caché).
        const Locked* l = locked(name);
        if (l && !isUpdating(key) && !l->commit.empty()) {
            Node ln = n;
            Source ls;
            ls.git = l->git;
            ls.folder = l->folder;
            if (sameSource(ls, n.src)) {
                ln.version = l->version;
                ln.tag = l->tag;
                ln.branch = l->branch;
                ln.commit = l->commit;
                ln.pinnedCommit = l->pinned;
                if (accepts(ln, pin, ranges)) {
                    if (!materialize(ln, true, err)) return false;
                    out = ln;
                    return true;
                }
            }
        }
        // 3) Una versión nueva.
        if (!pin.commit.empty()) {
            n.commit = pin.commit;
            n.pinnedCommit = true;
            if (!materialize(n, false, err)) return false;
            out = n;
            return true;
        }
        if (!pin.branch.empty()) {
            if (!remoteRef(n.src.git, "refs/heads/" + pin.branch, n.commit, err)) return false;
            n.branch = pin.branch;
            if (!materialize(n, false, err)) return false;
            out = n;
            return true;
        }
        std::vector<Tag> tags;
        if (!listTags(n.src.git, tags, err)) return false;
        auto ex = excluded.find(key);
        for (const Tag& t : tags) {
            if (ex != excluded.end() && ex->second.count(t.v.str())) continue;
            bool ok = true;
            if (ranges.empty()) ok = t.v.pre.empty();
            for (const auto& [r, q] : ranges) ok = ok && satisfies(r, t.v);
            if (!ok) continue;
            n.version = t.v.str();
            n.tag = t.name;
            n.commit = t.commit;
            if (!materialize(n, false, err)) return false;
            out = n;
            return true;
        }
        if (tags.empty() && ranges.empty()) {
            // Sin etiquetas: la rama principal (HEAD), fijada por commit en el paquetes.lock.
            if (!remoteRef(n.src.git, "HEAD", n.commit, err)) return false;
            if (!materialize(n, false, err)) return false;
            out = n;
            return true;
        }
        conflict = true;
        Strings avail;
        for (const Tag& t : tags) avail.push_back(t.v.str());
        std::reverse(avail.begin(), avail.end());
        err = "no hay ninguna versión de '" + name + "' que cumpla todas las restricciones:";
        for (const auto& [r, q] : ranges) err += "\n  " + q->by + " pide " + r.text;
        err += "\n  versiones disponibles: " + (avail.empty() ? std::string("ninguna (el repositorio no tiene etiquetas vX.Y.Z)") : join(avail, ", "));
        return false;
    }

    // Proyecto raíz + ProjectReference (recursivo): sus <PackageReference> son "locales".
    bool collectLocal(std::string& err) {
        std::set<std::string> seen;
        std::function<bool(const std::string&, bool)> visit = [&](const std::string& p, bool isRoot) -> bool {
            std::string key = canonical(p);
            if (!seen.insert(key).second) return true;
            Project proj;
            if (!loadProject(p, proj, err)) return false;
            if (isRoot) {
                root = proj;
                gIndexUrl = indexUrlFor(&root);
            }
            for (const PackageRef& pr : proj.packages) {
                Req r;
                r.ref = pr;
                r.by = fs::path(proj.path).filename().string();
                r.local = true;
                if (!validName(pr.name)) {
                    err = proj.path + ":" + std::to_string(pr.line) + ": nombre de paquete no válido '" + pr.name +
                          "' (letras, números, '.', '_' y '-')";
                    return false;
                }
                if (!sourceOf(r, proj.dir, err)) return false;
                localReqs.push_back(r);
            }
            std::error_code ec;
            for (const std::string& ref : proj.references)
                if (fs::exists(ref, ec) && !visit(ref, false)) return false;
            return true;
        };
        return visit(rootProj, true);
    }

    bool resolve(std::string& err) {
        lockPath = lockPathFor(rootProj);
        hasLock = readLock(lockPath, lock);
        if (!collectLocal(err)) return false;
        std::string firstConflict;
        for (int iter = 0; iter < 200; iter++) {
            // Requisitos actuales: los locales y los de los paquetes elegidos (alcanzables).
            std::map<std::string, std::vector<Req>> reqs;
            Strings order;
            std::set<std::string> expanded;
            std::vector<const Req*> queue;
            for (const Req& r : localReqs) queue.push_back(&r);
            for (size_t qi = 0; qi < queue.size(); qi++) {
                const Req* r = queue[qi];
                std::string key = lower(r->ref.name);
                if (!reqs.count(key)) order.push_back(key);
                reqs[key].push_back(*r);
                auto c = chosen.find(key);
                if (c != chosen.end() && expanded.insert(key).second)
                    for (const Req& child : c->second.children) queue.push_back(&child);
            }
            bool changed = false;
            for (const std::string& key : order) {
                Node n;
                bool conflict = false;
                std::string cerr;
                if (!choose(key, reqs[key], n, cerr, conflict)) {
                    if (!conflict) {
                        err = cerr;
                        return false;
                    }
                    // Retroceso: una versión anterior del paquete que pide la restricción imposible.
                    std::string blame;
                    for (const Req& r : reqs[key])
                        if (!r.local && !r.byKey.empty() && chosen.count(r.byKey) && !chosen[r.byKey].version.empty() &&
                            chosen[r.byKey].branch.empty() && !chosen[r.byKey].pinnedCommit && !lockedPinned(r.byKey, reqs)) {
                            blame = r.byKey;
                            break;
                        }
                    if (firstConflict.empty()) firstConflict = cerr;
                    if (blame.empty()) {
                        err = "conflicto de versiones: " + firstConflict;
                        return false;
                    }
                    excluded[blame].insert(chosen[blame].version);
                    chosen.erase(blame);
                    changed = true;
                    break;
                }
                auto cur = chosen.find(key);
                if (cur == chosen.end() || cur->second.commit != n.commit || !sameSource(cur->second.src, n.src)) {
                    chosen[key] = n;
                    changed = true;
                    break;  // los requisitos cambian: se recalculan
                }
            }
            if (!changed) {
                // Resultado: solo lo alcanzable.
                result.clear();
                for (const std::string& key : order) {
                    const Node& n = chosen[key];
                    Locked l;
                    l.name = n.name;
                    if (n.src.isPath) {
                        l.path = relativeTo(n.src.path, fs::path(rootProj).parent_path().string());
                    } else {
                        l.git = n.src.git;
                        if (isLocalGitPath(l.git)) l.git = relativeTo(l.git, fs::path(rootProj).parent_path().string());
                        l.folder = n.src.folder;
                        l.version = n.version;
                        l.tag = n.tag;
                        l.branch = n.branch;
                        l.commit = n.commit;
                        l.pinned = n.pinnedCommit;
                    }
                    for (const Req& c : n.children)
                        if (std::find(l.deps.begin(), l.deps.end(), c.ref.name) == l.deps.end()) l.deps.push_back(c.ref.name);
                    result.push_back(l);
                }
                std::sort(result.begin(), result.end(), [](const Locked& a, const Locked& b) { return lower(a.name) < lower(b.name); });
                return true;
            }
        }
        err = "no se pudieron resolver las versiones de los paquetes (demasiados intentos)" +
              (firstConflict.empty() ? "" : ":\n" + firstConflict);
        return false;
    }

    // ¿Algún requisito fija el paquete con Branch/Commit? (entonces no se puede retroceder)
    bool lockedPinned(const std::string& key, const std::map<std::string, std::vector<Req>>& reqs) const {
        auto it = reqs.find(key);
        if (it == reqs.end()) return false;
        for (const Req& r : it->second)
            if (!r.ref.commit.empty() || !r.ref.branch.empty()) return true;
        return false;
    }

    // Escribe paquetes.lock si ha cambiado (y lo borra si ya no hay paquetes).
    void saveLock() {
        std::error_code ec;
        if (result.empty()) {
            if (fs::exists(lockPath, ec)) fs::remove(lockPath, ec);
            return;
        }
        std::string text = lockText(result);
        if (readFile(lockPath) != text && !writeFileText(lockPath, text)) warn("no se pudo escribir " + lockPath);
    }

    Strings projects() const {
        Strings out;
        for (const Locked& l : result)
            for (const auto& [k, n] : chosen)
                if (lower(n.name) == lower(l.name) && !n.project.empty()) out.push_back(n.project);
        return out;
    }

    const Node* node(const std::string& name) const {
        auto it = chosen.find(lower(name));
        return it == chosen.end() ? nullptr : &it->second;
    }
};

// ¿Hay algún <PackageReference> en el proyecto o en los que referencia?
bool treeHasPackages(const std::string& projPath) {
    std::set<std::string> seen;
    std::function<bool(const std::string&)> visit = [&](const std::string& p) -> bool {
        if (!seen.insert(canonical(p)).second) return false;
        Project proj;
        std::string err;
        if (!loadProject(p, proj, err)) return true;  // que lo explique quien lo cargue
        if (!proj.packages.empty()) return true;
        std::error_code ec;
        for (const std::string& r : proj.references)
            if (fs::exists(r, ec) && visit(r)) return true;
        return false;
    };
    return visit(projPath);
}

// ------------------------------------------------------------------ edición del .fstproj

std::string xmlEscape(const std::string& s) {
    std::string r;
    for (char c : s) {
        if (c == '&') r += "&amp;";
        else if (c == '"') r += "&quot;";
        else if (c == '<') r += "&lt;";
        else if (c == '>') r += "&gt;";
        else r += c;
    }
    return r;
}

std::string xmlUnescape(std::string s) {
    const std::pair<const char*, const char*> ents[] = {{"&quot;", "\""}, {"&lt;", "<"}, {"&gt;", ">"}, {"&apos;", "'"}, {"&amp;", "&"}};
    for (auto& [e, c] : ents)
        for (size_t k; (k = s.find(e)) != std::string::npos;) s.replace(k, std::strlen(e), c);
    return s;
}

struct TextEl {
    size_t beg = 0, end = 0;
    std::map<std::string, std::string> attrs;
};

std::vector<std::pair<size_t, size_t>> commentZones(const std::string& text) {
    std::vector<std::pair<size_t, size_t>> zones;
    for (size_t k = text.find("<!--"); k != std::string::npos; k = text.find("<!--", k + 4)) {
        size_t e = text.find("-->", k + 4);
        zones.push_back({k, e == std::string::npos ? text.size() : e + 3});
        if (e == std::string::npos) break;
        k = e;
    }
    return zones;
}

bool inZones(const std::vector<std::pair<size_t, size_t>>& z, size_t off) {
    for (auto& [a, b] : z)
        if (off >= a && off < b) return true;
    return false;
}

// Elementos <PackageReference .../> (o con cierre) fuera de los comentarios.
std::vector<TextEl> packageElements(const std::string& text) {
    std::vector<TextEl> out;
    auto zones = commentZones(text);
    const std::string open = "<PackageReference";
    for (size_t k = text.find(open); k != std::string::npos; k = text.find(open, k + 1)) {
        size_t after = k + open.size();
        if (inZones(zones, k) || after >= text.size() || !(std::isspace((unsigned char)text[after]) || text[after] == '/' || text[after] == '>'))
            continue;
        TextEl el;
        el.beg = k;
        char q = 0;
        size_t i = after;
        for (; i < text.size(); i++) {
            char c = text[i];
            if (q) {
                if (c == q) q = 0;
            } else if (c == '"' || c == '\'') q = c;
            else if (c == '>') break;
        }
        if (i >= text.size()) break;
        std::string head = text.substr(after, i - after);
        bool selfClosing = !head.empty() && head.back() == '/';
        el.end = i + 1;
        if (!selfClosing) {
            size_t close = text.find("</PackageReference>", i);
            if (close != std::string::npos) el.end = close + 19;
        }
        // Atributos
        size_t p = 0;
        while (p < head.size()) {
            while (p < head.size() && (std::isspace((unsigned char)head[p]) || head[p] == '/')) p++;
            size_t ns = p;
            while (p < head.size() && (std::isalnum((unsigned char)head[p]) || head[p] == '_' || head[p] == '-' || head[p] == ':')) p++;
            std::string an = head.substr(ns, p - ns);
            while (p < head.size() && std::isspace((unsigned char)head[p])) p++;
            if (an.empty() || p >= head.size() || head[p] != '=') {
                if (an.empty()) p++;
                continue;
            }
            p++;
            while (p < head.size() && std::isspace((unsigned char)head[p])) p++;
            if (p >= head.size() || (head[p] != '"' && head[p] != '\'')) continue;
            char qq = head[p++];
            size_t ve = head.find(qq, p);
            if (ve == std::string::npos) break;
            el.attrs[an] = xmlUnescape(head.substr(p, ve - p));
            p = ve + 1;
        }
        out.push_back(el);
        k = el.end - 1;
    }
    return out;
}

std::string elementText(const PackageRef& r) {
    std::string t = "<PackageReference Include=\"" + xmlEscape(r.name) + "\"";
    auto a = [&](const char* n, const std::string& v) {
        if (!v.empty()) t += " " + std::string(n) + "=\"" + xmlEscape(v) + "\"";
    };
    a("Version", r.version);
    a("Git", r.git);
    a("Branch", r.branch);
    a("Commit", r.commit);
    a("Path", r.path);
    a("Folder", r.folder);
    return t + " />";
}

// Añade o sustituye <PackageReference Include="name"> conservando el resto del archivo.
bool upsertPackage(std::string& text, const PackageRef& r, std::string& err, bool& replaced) {
    replaced = false;
    std::string item = elementText(r);
    auto els = packageElements(text);
    for (const TextEl& e : els) {
        auto it = e.attrs.find("Include");
        if (it != e.attrs.end() && lower(it->second) == lower(r.name)) {
            text.replace(e.beg, e.end - e.beg, item);
            replaced = true;
            return true;
        }
    }
    auto zones = commentZones(text);
    if (!els.empty()) {
        size_t last = els.back().beg;
        size_t ls = text.rfind('\n', last);
        ls = ls == std::string::npos ? 0 : ls + 1;
        std::string indent = text.substr(ls, last - ls);
        if (indent.find_first_not_of(" \t") != std::string::npos) indent = "    ";
        size_t le = text.find('\n', els.back().end);
        if (le == std::string::npos) text += "\n" + indent + item;
        else text.insert(le + 1, indent + item + "\n");
        return true;
    }
    size_t end = std::string::npos;
    for (size_t k = text.find("</Project>"); k != std::string::npos; k = text.find("</Project>", k + 1))
        if (!inZones(zones, k)) end = k;
    if (end == std::string::npos) {
        err = "falta </Project> en el .fstproj";
        return false;
    }
    std::string block = "  <ItemGroup>\n    " + item + "\n  </ItemGroup>\n";
    size_t ls = text.rfind('\n', end == 0 ? 0 : end - 1);
    std::string beforeOnLine = ls == std::string::npos ? text.substr(0, end) : text.substr(ls + 1, end - ls - 1);
    if (!trim(beforeOnLine).empty()) block = "\n" + block;
    else {
        // </Project> al principio de su línea: el bloque va justo antes, con una línea en blanco.
        end = ls == std::string::npos ? 0 : ls + 1;
        if (end > 1 && text.compare(end - 2, 2, "\n\n") != 0) block = "\n" + block;
    }
    text.insert(end, block);
    return true;
}

// Quita <PackageReference Include="name"> (y su <ItemGroup> si se queda vacío).
bool removePackage(std::string& text, const std::string& name) {
    bool any = false;
    for (;;) {
        auto els = packageElements(text);
        const TextEl* found = nullptr;
        for (const TextEl& e : els) {
            auto it = e.attrs.find("Include");
            if (it != e.attrs.end() && lower(it->second) == lower(name)) found = &e;
        }
        if (!found) break;
        any = true;
        size_t b = found->beg, e = found->end;
        size_t ls = text.rfind('\n', b == 0 ? 0 : b - 1);
        ls = ls == std::string::npos ? 0 : ls + 1;
        size_t le = text.find('\n', e);
        size_t lend = le == std::string::npos ? text.size() : le + 1;
        if (trim(text.substr(ls, b - ls)).empty() && trim(text.substr(e, lend - e)).empty()) {
            b = ls;
            e = lend;
        }
        text.erase(b, e - b);
        // ¿<ItemGroup> vacío alrededor?
        size_t gOpen = text.rfind("<ItemGroup", b);
        size_t gClose = text.find("</ItemGroup>", b);
        if (gOpen != std::string::npos && gClose != std::string::npos) {
            size_t headEnd = text.find('>', gOpen);
            if (headEnd != std::string::npos && headEnd < gClose && text[headEnd - 1] != '/' &&
                trim(text.substr(headEnd + 1, gClose - headEnd - 1)).empty()) {
                size_t s = text.rfind('\n', gOpen == 0 ? 0 : gOpen - 1);
                s = s == std::string::npos ? 0 : s + 1;
                size_t f = text.find('\n', gClose);
                f = f == std::string::npos ? text.size() : f + 1;
                if (trim(text.substr(s, gOpen - s)).empty()) {
                    // Y la línea en blanco que lo separaba del grupo anterior.
                    if (s >= 2 && text[s - 1] == '\n' && text[s - 2] == '\n') s--;
                    text.erase(s, f - s);
                }
            }
        }
    }
    return any;
}

// ------------------------------------------------------------------ órdenes

struct CliOpts {
    std::string project, version, branch, commit, folder, name, index;
    bool json = false, noRestore = false;
    Strings positional;
};

bool parseOpts(const Strings& a, size_t from, CliOpts& o) {
    for (size_t i = from; i < a.size(); i++) {
        const std::string& s = a[i];
        auto next = [&](std::string& dst) {
            if (i + 1 >= a.size()) {
                fail("falta el valor de '" + s + "'");
                return false;
            }
            dst = a[++i];
            return true;
        };
        if (s == "--project" || s == "-p") {
            if (!next(o.project)) return false;
        } else if (s == "--version" || s == "-v") {
            if (!next(o.version)) return false;
        } else if (s == "--branch") {
            if (!next(o.branch)) return false;
        } else if (s == "--commit") {
            if (!next(o.commit)) return false;
        } else if (s == "--folder") {
            if (!next(o.folder)) return false;
        } else if (s == "--name") {
            if (!next(o.name)) return false;
        } else if (s == "--index" || s == "--indice") {
            if (!next(o.index)) return false;
        } else if (s == "--offline") gOffline = true;
        else if (s == "--json") o.json = true;
        else if (s == "--no-restore") o.noRestore = true;
        else if (s == "--verbose") gVerbose = true;
        else if (!s.empty() && s[0] == '-' && s.size() > 1) {
            fail("opción desconocida '" + s + "'");
            return false;
        } else o.positional.push_back(s);
    }
    if (!o.index.empty()) {
#if defined(_WIN32)
        _putenv_s("FASET_PAQUETES_INDICE", o.index.c_str());
#else
        setenv("FASET_PAQUETES_INDICE", o.index.c_str(), 1);
#endif
    }
    return true;
}

// El .fstproj sobre el que actúa la orden: --project, una ruta, o el de la carpeta actual.
bool findTarget(const std::string& given, std::string& proj) {
    std::string err;
    std::error_code ec;
    if (!given.empty()) {
        proj = projectIn(given, err);
        if (proj.empty()) fail(err);
        return !proj.empty();
    }
    proj = projectIn(fs::current_path().string(), err);
    if (proj.empty()) fail(err + "; indica el proyecto con --project <x.fstproj>");
    return !proj.empty();
}

int restoreCmd(const std::string& proj, bool updateAll, const Strings& names, bool quietList) {
    Resolver r;
    r.rootProj = fs::absolute(proj).lexically_normal().string();
    r.updateAll = updateAll;
    for (const std::string& n : names) r.updating.insert(lower(n));
    std::vector<Locked> before;
    readLock(lockPathFor(r.rootProj), before);
    std::string err;
    if (!r.resolve(err)) {
        fail(err);
        return 1;
    }
    for (const std::string& n : names)
        if (std::none_of(r.result.begin(), r.result.end(), [&](const Locked& l) { return lower(l.name) == lower(n); })) {
            fail("el proyecto no usa el paquete '" + n + "'");
            return 1;
        }
    r.saveLock();
    if (quietList) return 0;
    auto describe = [](const Locked& l) {
        if (!l.path.empty()) return std::string("ruta ") + l.path;
        if (!l.version.empty()) return l.version;
        return (l.branch.empty() ? std::string("") : l.branch + " ") + "@" + l.commit.substr(0, 7);
    };
    if (r.result.empty()) {
        std::printf("El proyecto no usa paquetes.\n");
        return 0;
    }
    int changes = 0;
    for (const Locked& l : r.result) {
        const Locked* old = nullptr;
        for (const Locked& b : before)
            if (lower(b.name) == lower(l.name)) old = &b;
        if (!old) std::printf("  + %s %s\n", l.name.c_str(), describe(l).c_str());
        else if (old->commit != l.commit || old->path != l.path)
            std::printf("  ~ %s %s -> %s\n", l.name.c_str(), describe(*old).c_str(), describe(l).c_str());
        else continue;
        changes++;
    }
    for (const Locked& b : before)
        if (std::none_of(r.result.begin(), r.result.end(), [&](const Locked& l) { return lower(l.name) == lower(b.name); })) {
            std::printf("  - %s %s\n", b.name.c_str(), describe(b).c_str());
            changes++;
        }
    std::printf("%s: %zu paquete%s%s (%s)\n", fs::path(proj).filename().string().c_str(), r.result.size(),
                r.result.size() == 1 ? "" : "s", changes ? "" : ", sin cambios", kLockName);
    return 0;
}

// faset add <nombre|url git|ruta> [--version X] [--branch B] [--commit C] [--folder F] [--name N]
int addCmd(const CliOpts& o) {
    if (o.positional.size() != 1) {
        fail("uso: faset add <nombre | url git | ruta> [--version X] [--branch rama | --commit sha] [--folder carpeta] [--project x.fstproj]");
        return 1;
    }
    std::string proj;
    if (!findTarget(o.project, proj)) return 1;
    proj = fs::absolute(proj).lexically_normal().string();
    std::string projDir = fs::path(proj).parent_path().string();
    Project self;
    std::string err;
    if (!loadProject(proj, self, err)) {
        fail(err);
        return 1;
    }
    gIndexUrl = indexUrlFor(&self);
    const std::string& what = o.positional[0];
    PackageRef ref;
    ref.version = o.version;
    ref.branch = o.branch;
    ref.commit = o.commit;
    ref.folder = o.folder;
    if (!ref.branch.empty() && !ref.commit.empty()) {
        fail("--branch y --commit no pueden ir juntos");
        return 1;
    }
    std::error_code ec;
    bool isGit = looksLikeGitUrl(what);
    bool isPath = !isGit && (fs::exists(what, ec) || what.find('/') != std::string::npos || what.find('\\') != std::string::npos);
    Resolver probe;
    probe.rootProj = proj;
    if (isPath) {
        if (!ref.branch.empty() || !ref.commit.empty()) {
            fail("--branch y --commit solo valen para paquetes git");
            return 1;
        }
        std::string dir = fs::absolute(what).lexically_normal().string();
        if (!ref.folder.empty()) dir = (fs::path(dir) / ref.folder).string();
        std::string p = projectIn(dir, err);
        Project lib;
        if (p.empty() || !loadProject(p, lib, err)) {
            fail(err);
            return 1;
        }
        if (lib.prop("OutputType", "Exe") != "Library") {
            fail("'" + p + "' no es una biblioteca (OutputType debe ser Library)");
            return 1;
        }
        if (canonical(p) == canonical(proj)) {
            fail("un proyecto no puede usarse a sí mismo como paquete");
            return 1;
        }
        ref.name = o.name.empty() ? packageIdOf(lib) : o.name;
        ref.path = relativeTo(fs::absolute(what).lexically_normal().string(), projDir);
    } else if (isGit) {
        ref.git = what;
        if (isLocalGitPath(what)) ref.git = relativeTo(fs::absolute(what).lexically_normal().string(), projDir);
        // Se descarga para saber su nombre (PackageId) y la versión más reciente.
        std::string guess = fs::path(normGit(what)).filename().string();
        if (!validName(guess)) guess = "paquete";
        Req r;
        r.ref = ref;
        r.ref.name = o.name.empty() ? guess : o.name;
        r.by = fs::path(proj).filename().string();
        r.local = true;
        if (!probe.sourceOf(r, projDir, err)) {
            fail(err);
            return 1;
        }
        Node n;
        bool conflict = false;
        if (!probe.choose(lower(r.ref.name), {r}, n, err, conflict)) {
            fail(err);
            return 1;
        }
        Project lib;
        std::string perr;
        if (o.name.empty() && loadProject(n.project, lib, perr)) {
            ref.name = packageIdOf(lib);
            // La caché va por nombre: se mueve la descarga si el nombre real es otro.
            if (lower(ref.name) != lower(r.ref.name) && !n.dir.empty()) {
                std::string to = cacheDirFor(ref.name, n.version, n.commit);
                if (!fs::exists(to, ec)) {
                    fs::create_directories(fs::path(to).parent_path(), ec);
                    fs::rename(n.dir, to, ec);
                }
            }
        } else ref.name = r.ref.name;
        if (ref.version.empty() && ref.branch.empty() && ref.commit.empty() && !n.version.empty()) ref.version = "^" + n.version;
    } else {
        ref.name = o.name.empty() ? what : o.name;
        if (!validName(ref.name)) {
            fail("nombre de paquete no válido '" + ref.name + "'");
            return 1;
        }
        const PackageRef* existing = nullptr;
        for (const PackageRef& p : self.packages)
            if (lower(p.name) == lower(ref.name)) existing = &p;
        if (existing && (!existing->git.empty() || !existing->path.empty())) {
            // Ya está en el .fstproj: se cambia la versión (o la rama/commit) y se conserva el origen.
            ref.name = existing->name;
            ref.git = existing->git;
            ref.path = existing->path;
            if (ref.folder.empty()) ref.folder = existing->folder;
            if (ref.version.empty() && ref.branch.empty() && ref.commit.empty()) {
                ref.version = existing->version;
                ref.branch = existing->branch;
                ref.commit = existing->commit;
            }
            if (!ref.path.empty()) ref.version.clear();
        }
        IndexEntry e;
        std::string why;
        if (!ref.git.empty() || !ref.path.empty()) {
            // (origen conocido: no hace falta el índice)
        } else if (!indexLookup(ref.name, e, why)) {
            fail(why + ".\n  Usa la URL del repositorio git (faset add https://...) o una carpeta (faset add ../MiLib)");
            return 1;
        } else if (ref.version.empty() && ref.branch.empty() && ref.commit.empty()) {
            Req r;
            r.ref = ref;
            r.by = fs::path(proj).filename().string();
            r.local = true;
            r.src.git = e.git;
            r.src.folder = ref.folder.empty() ? e.folder : ref.folder;
            Node n;
            bool conflict = false;
            if (!probe.choose(lower(ref.name), {r}, n, err, conflict)) {
                fail(err);
                return 1;
            }
            if (!n.version.empty()) ref.version = "^" + n.version;
        }
    }
    if (!validName(ref.name)) {
        fail("nombre de paquete no válido '" + ref.name + "' (usa --name)");
        return 1;
    }
    std::string original = readFile(proj), text = original;
    bool replaced = false;
    if (!upsertPackage(text, ref, err, replaced)) {
        fail(err);
        return 1;
    }
    if (!writeFileText(proj, text)) {
        fail("no se pudo escribir '" + proj + "'");
        return 1;
    }
    if (!o.noRestore) {
        Resolver r;
        r.rootProj = proj;
        r.updating.insert(lower(ref.name));
        if (!r.resolve(err)) {
            writeFileText(proj, original);
            fail(err + "\n(no se ha cambiado " + fs::path(proj).filename().string() + ")");
            return 1;
        }
        r.saveLock();
        const Node* n = r.node(ref.name);
        std::string got = !n ? "" : n->src.isPath ? "ruta " + ref.path : !n->version.empty() ? n->version : "@" + n->commit.substr(0, 7);
        std::printf("%s '%s' %s en %s (%s)\n", replaced ? "Actualizado" : "Añadido", ref.name.c_str(), got.c_str(),
                    fs::path(proj).filename().string().c_str(), elementText(ref).c_str());
    } else {
        std::printf("%s %s en %s\n", replaced ? "Actualizado" : "Añadido", elementText(ref).c_str(), fs::path(proj).filename().string().c_str());
    }
    return 0;
}

int removeCmd(const CliOpts& o) {
    if (o.positional.size() != 1) {
        fail("uso: faset remove <nombre> [--project x.fstproj]");
        return 1;
    }
    std::string proj;
    if (!findTarget(o.project, proj)) return 1;
    std::string text = readFile(proj);
    if (!removePackage(text, o.positional[0])) {
        fail(fs::path(proj).filename().string() + " no tiene <PackageReference Include=\"" + o.positional[0] + "\">");
        return 1;
    }
    if (!writeFileText(proj, text)) {
        fail("no se pudo escribir '" + proj + "'");
        return 1;
    }
    std::printf("Quitado '%s' de %s\n", o.positional[0].c_str(), fs::path(proj).filename().string().c_str());
    Resolver r;
    r.rootProj = fs::absolute(proj).lexically_normal().string();
    std::string err;
    if (r.resolve(err)) r.saveLock();
    else warn("no se pudo actualizar " + std::string(kLockName) + ": " + err);
    return 0;
}

// faset list paquetes [--json]: árbol de dependencias resuelto.
int listCmd(const CliOpts& o) {
    std::string proj;
    if (!findTarget(o.project, proj)) return 1;
    Resolver r;
    r.rootProj = fs::absolute(proj).lexically_normal().string();
    std::string err;
    if (!r.resolve(err)) {
        if (o.json) {
            Json j = Json::object();
            j["proyecto"] = r.rootProj;
            j["error"] = err;
            j["paquetes"] = Json::array();
            std::printf("%s\n", j.dump().c_str());
        } else fail(err);
        return 1;
    }
    r.saveLock();
    auto label = [&](const Locked& l) {
        if (!l.path.empty()) return "(ruta " + l.path + ")";
        std::string s = l.version.empty() ? (l.branch.empty() ? "" : l.branch + " ") + "@" + l.commit.substr(0, 7)
                                          : l.version + " (" + l.commit.substr(0, 7) + ")";
        return s + "  " + l.git + (l.folder.empty() ? "" : " /" + l.folder);
    };
    auto find = [&](const std::string& n) -> const Locked* {
        for (const Locked& l : r.result)
            if (lower(l.name) == lower(n)) return &l;
        return nullptr;
    };
    if (o.json) {
        Json j = Json::object();
        j["proyecto"] = r.rootProj;
        Json arr = Json::array();
        for (const Locked& l : r.result) {
            Json e = Json::object();
            e["nombre"] = l.name;
            bool direct = false;
            std::string wanted;
            for (const PackageRef& p : r.root.packages)
                if (lower(p.name) == lower(l.name)) {
                    direct = true;
                    wanted = !p.version.empty() ? p.version : !p.branch.empty() ? "rama " + p.branch : !p.commit.empty() ? "commit " + p.commit : "";
                }
            e["directo"] = direct;
            e["pedida"] = wanted;
            e["version"] = l.version;
            e["commit"] = l.commit;
            e["origen"] = l.path.empty() ? l.git : l.path;
            e["tipo"] = l.path.empty() ? "git" : "ruta";
            Json deps = Json::array();
            for (const std::string& d : l.deps) deps.push(d);
            e["dependencias"] = deps;
            const Node* n = r.node(l.name);
            e["proyectoPaquete"] = n ? n->project : "";
            arr.push(e);
        }
        j["paquetes"] = arr;
        std::printf("%s\n", j.dump().c_str());
        return 0;
    }
    std::printf("%s\n", fs::path(proj).filename().string().c_str());
    if (r.result.empty()) {
        std::printf("  (sin paquetes)\n");
        return 0;
    }
    Strings directs;
    for (const PackageRef& p : r.root.packages) directs.push_back(p.name);
    // Paquetes que solo piden otros proyectos locales (ProjectReference) también son "de arriba".
    for (const Req& q : r.localReqs)
        if (std::none_of(directs.begin(), directs.end(), [&](const std::string& d) { return lower(d) == lower(q.ref.name); }))
            directs.push_back(q.ref.name);
    std::function<void(const std::string&, const std::string&, bool, std::set<std::string>&)> print =
        [&](const std::string& name, const std::string& prefix, bool last, std::set<std::string>& path) {
            const Locked* l = find(name);
            std::string branch = last ? "└── " : "├── ";
            if (!l) {
                std::printf("%s%s%s (sin resolver)\n", prefix.c_str(), branch.c_str(), name.c_str());
                return;
            }
            bool cycle = path.count(lower(name));
            std::printf("%s%s%s %s%s\n", prefix.c_str(), branch.c_str(), l->name.c_str(), label(*l).c_str(), cycle ? " (ciclo)" : "");
            if (cycle) return;
            path.insert(lower(name));
            for (size_t i = 0; i < l->deps.size(); i++) print(l->deps[i], prefix + (last ? "    " : "│   "), i + 1 == l->deps.size(), path);
            path.erase(lower(name));
        };
    for (size_t i = 0; i < directs.size(); i++) {
        std::set<std::string> path;
        print(directs[i], "", i + 1 == directs.size(), path);
    }
    return 0;
}

// faset pack / faset publish: valida los metadatos y explica cómo publicar con una etiqueta git.
int packCmd(const CliOpts& o, bool publish) {
    std::string proj;
    if (!findTarget(o.positional.empty() ? o.project : o.positional[0], proj)) return 1;
    Project p;
    std::string err;
    if (!loadProject(proj, p, err)) {
        fail(err);
        return 1;
    }
    Strings errors, warnings;
    if (p.prop("OutputType", "Exe") != "Library") errors.push_back("<OutputType> debe ser Library (un paquete es una biblioteca)");
    std::string id = p.prop("PackageId");
    if (id.empty()) errors.push_back("falta <PackageId> (el nombre con el que se usa el paquete)");
    else if (!validName(id)) errors.push_back("<PackageId> no válido '" + id + "' (letras, números, '.', '_' y '-')");
    std::string version = p.prop("Version");
    Semver sv;
    int parts = 0;
    if (version.empty()) errors.push_back("falta <Version> (semver: 1.0.0)");
    else if (!parseSemver(version, sv, &parts) || parts != 3 || version[0] == 'v')
        errors.push_back("<Version> debe ser semver MAYOR.MENOR.PARCHE (p. ej. 1.2.0), no '" + version + "'");
    for (const char* k : {"Description", "Authors", "License", "RepositoryUrl"})
        if (p.prop(k).empty()) warnings.push_back("falta <" + std::string(k) + ">");
    for (const PackageRef& r : p.packages) {
        if (!r.path.empty()) errors.push_back("la dependencia '" + r.name + "' usa Path=: quien instale el paquete no tendrá esa carpeta (usa Git= o el índice)");
        else if (r.version.empty() && r.branch.empty() && r.commit.empty())
            warnings.push_back("la dependencia '" + r.name + "' no indica Version: se usará siempre la más reciente");
        else if (!r.branch.empty()) warnings.push_back("la dependencia '" + r.name + "' sigue la rama '" + r.branch + "': mejor una Version");
    }
    std::error_code ec;
    if (!fs::exists(fs::path(p.dir) / "README.md", ec)) warnings.push_back("no hay README.md");
    // Git: carpeta dentro del repositorio, cambios sin confirmar y etiqueta existente.
    std::string top, out, folder;
    std::string tag = "v" + version;
    bool inGit = false;
    if (!findProgram("git").empty() && git({"-C", p.dir, "rev-parse", "--show-toplevel"}, out) == 0) {
        inGit = true;
        top = trim(out);
        folder = relativeTo(p.dir, top);
        if (folder == ".") folder.clear();
        if (git({"-C", p.dir, "status", "--porcelain", "--", "."}, out) == 0 && !trim(out).empty())
            warnings.push_back("hay cambios sin confirmar (git commit) en la carpeta del paquete");
        if (git({"-C", p.dir, "tag", "-l", tag}, out) == 0 && trim(out) == tag)
            warnings.push_back("la etiqueta " + tag + " ya existe: sube <Version> antes de publicar");
    } else {
        warnings.push_back("la carpeta no es un repositorio git (git init) y los paquetes se publican con etiquetas git");
    }
    std::printf("Paquete %s %s  (%s)\n", id.empty() ? "?" : id.c_str(), version.empty() ? "?" : version.c_str(), proj.c_str());
    for (const std::string& w : warnings) std::printf("  aviso: %s\n", w.c_str());
    for (const std::string& e : errors) std::printf("  error: %s\n", e.c_str());
    if (!errors.empty()) {
        std::printf("\nCorrige los errores en %s y vuelve a probar.\n", fs::path(proj).filename().string().c_str());
        return 1;
    }
    std::string repo = p.prop("RepositoryUrl", "<url del repositorio>");
    std::printf("\nMetadatos correctos. Para publicar la versión %s:\n\n", version.c_str());
    if (!inGit) std::printf("  git init && git add . && git commit -m \"%s %s\"\n  git remote add origin %s\n", id.c_str(), version.c_str(), repo.c_str());
    std::printf("  git tag %s\n  git push origin %s\n\n", tag.c_str(), tag.c_str());
    std::printf("Quien quiera usarlo:\n\n  faset add %s --version ^%s%s\n\n  <PackageReference Include=\"%s\" Git=\"%s\" Version=\"^%s\"%s />\n",
                repo.c_str(), version.c_str(), folder.empty() ? "" : (" --folder " + folder).c_str(), id.c_str(), repo.c_str(),
                version.c_str(), folder.empty() ? "" : (" Folder=\"" + folder + "\"").c_str());
    if (publish) {
        Json e = Json::object();
        e["git"] = p.prop("RepositoryUrl");
        if (!folder.empty()) e["carpeta"] = folder;
        e["descripcion"] = p.prop("Description");
        e["autores"] = p.prop("Authors");
        e["licencia"] = p.prop("License");
        Json vs = Json::array();
        vs.push(version);
        e["versiones"] = vs;
        std::printf("\nTodavía no hay un registro central. Cuando exista, 'faset publish' enviará esta entrada al\n"
                    "índice (%s); mientras tanto puedes proponerla a mano:\n\n  \"%s\": %s\n",
                    kDefaultIndex, id.c_str(), e.dump().c_str());
    }
    return 0;
}

// faset new <Nombre> --package: biblioteca lista para publicar.
int newPackageCmd(const Strings& args) {
    std::string name;
    for (const std::string& a : args)
        if (a == "--package" || a == "--lib" || a == "lib" || a == "classlib" || a == "--paquete") continue;
        else if (!a.empty() && a[0] == '-') {
            fail("con --package solo vale --lib ('" + a + "' no)");
            return 1;
        } else name = a;
    if (name.empty()) {
        fail("uso: faset new <Nombre> --lib --package");
        return 1;
    }
    fs::path dir(name);
    std::error_code ec;
    if (fs::exists(dir, ec)) {
        fail("'" + name + "' ya existe");
        return 1;
    }
    std::string id = dir.filename().string();
    if (!validName(id)) {
        fail("nombre de paquete no válido '" + id + "' (letras, números, '.', '_' y '-')");
        return 1;
    }
    std::string ns;
    for (char c : id) ns += std::isalnum((unsigned char)c) || c == '_' ? c : '_';
    if (std::isdigit((unsigned char)ns[0])) ns = "_" + ns;
    fs::create_directories(dir, ec);
    writeFileText((dir / (id + ".fstproj")).string(),
                  "<Project>\n"
                  "  <PropertyGroup>\n"
                  "    <OutputType>Library</OutputType>\n"
                  "    <AssemblyName>" + id + "</AssemblyName>\n"
                  "    <RootNamespace>" + ns + "</RootNamespace>\n"
                  "\n"
                  "    <!-- Metadatos del paquete (faset pack los comprueba) -->\n"
                  "    <PackageId>" + id + "</PackageId>\n"
                  "    <Version>0.1.0</Version>\n"
                  "    <Description>Describe aquí qué hace " + id + ".</Description>\n"
                  "    <Authors>Tu nombre</Authors>\n"
                  "    <License>MIT</License>\n"
                  "    <RepositoryUrl>https://github.com/usuario/" + lower(id) + "</RepositoryUrl>\n"
                  "  </PropertyGroup>\n"
                  "\n"
                  "  <!-- Dependencias de este paquete (se instalan también en quien lo use):\n"
                  "  <ItemGroup>\n"
                  "    <PackageReference Include=\"Otro\" Git=\"https://github.com/usuario/otro\" Version=\"^1.0\" />\n"
                  "  </ItemGroup>\n"
                  "  -->\n"
                  "</Project>\n");
    writeFileText((dir / (id + ".fst")).string(),
                  "namespace " + ns + "\n{\n    public static class Saludo\n    {\n"
                  "        public static string Texto() => \"¡Hola desde el paquete " + id + "!\";\n    }\n}\n");
    writeFileText((dir / "README.md").string(),
                  "# " + id + "\n\n"
                  "Describe aquí qué hace " + id + ".\n\n"
                  "## Instalación\n\n"
                  "```sh\nfaset add https://github.com/usuario/" + lower(id) + "\n```\n\n"
                  "o en el `.fstproj`:\n\n"
                  "```xml\n<PackageReference Include=\"" + id + "\" Git=\"https://github.com/usuario/" + lower(id) +
                      "\" Version=\"^0.1\" />\n```\n\n"
                  "## Uso\n\n"
                  "```csharp\nConsole.WriteLine(" + ns + ".Saludo.Texto());\n```\n\n"
                  "## Publicar una versión\n\n"
                  "1. Sube `<Version>` en `" + id + ".fstproj`.\n"
                  "2. `faset pack` comprueba los metadatos.\n"
                  "3. `git tag v0.1.0 && git push origin v0.1.0`.\n\n"
                  "## Licencia\n\nMIT\n");
    writeFileText((dir / ".gitignore").string(), "bin/\nobj/\n");
    std::printf("Paquete '%s' creado (biblioteca con metadatos de paquete).\n\n  cd %s\n  faset pack       comprueba los metadatos\n"
                "  git init && git add . && git commit -m \"%s 0.1.0\"\n  git tag v0.1.0\n",
                id.c_str(), name.c_str(), id.c_str());
    return 0;
}

void packagesUsage() {
    std::printf(
        "Paquetes de Faset (git, carpetas locales y, en el futuro, el índice de faset.lat):\n\n"
        "  faset add <nombre | url git | ruta> [opciones]   Añade <PackageReference> al .fstproj y lo descarga\n"
        "      --version <restricción>   1.2.0, ^1.2, ~1.2, 1.2.x, \">=1.0 <2.0\" (por defecto ^ la más reciente)\n"
        "      --branch <rama> | --commit <sha>   en vez de una versión\n"
        "      --folder <carpeta>        el .fstproj del paquete está en una subcarpeta del repositorio\n"
        "      --name <nombre>           nombre del paquete (por defecto su PackageId)\n"
        "  faset remove <nombre>                          Quita el paquete del .fstproj\n"
        "  faset restore [--offline]                      Descarga lo que diga paquetes.lock (o lo resuelve)\n"
        "  faset update [nombre]                          Busca versiones nuevas y actualiza paquetes.lock\n"
        "  faset list paquetes [--json]                   Árbol de dependencias resuelto\n"
        "  faset new <Nombre> --lib --package             Biblioteca con metadatos, lista para publicar\n"
        "  faset pack | faset publish                     Comprueba los metadatos y explica cómo publicar\n\n"
        "Opciones comunes: --project <x.fstproj>, --offline (solo la caché), --index <url del índice>\n");
}

}  // namespace

// ------------------------------------------------------------------ API

bool packagesForBuild(const std::string& projPath, std::vector<std::string>& projects, std::string& error) {
    projects.clear();
    const char* off = std::getenv("FASET_OFFLINE");
    if (off && *off && std::string(off) != "0") gOffline = true;
    std::string abs = fs::absolute(projPath).lexically_normal().string();
    std::error_code ec;
    if (!treeHasPackages(abs) && !fs::exists(lockPathFor(abs), ec)) return true;
    Resolver r;
    r.rootProj = abs;
    if (!r.resolve(error)) return false;
    r.saveLock();
    projects = r.projects();
    return true;
}

namespace {

// .fstproj de un paquete del paquetes.lock que ya está en la caché ("" si no).
std::string lockedProject(const std::string& lp, const Locked& l) {
    Strings dirs;
    if (!l.path.empty()) dirs.push_back((fs::path(lp).parent_path() / l.path).lexically_normal().string());
    else {
        if (!l.version.empty()) dirs.push_back(cacheDirFor(l.name, l.version, l.commit));
        if (!l.commit.empty()) dirs.push_back(cacheDirFor(l.name, "", l.commit));
    }
    for (std::string d : dirs) {
        if (d.empty()) continue;
        if (l.path.empty() && !l.commit.empty() && headCommit(d) != l.commit) continue;
        if (!l.folder.empty() && l.path.empty()) d = (fs::path(d) / l.folder).string();
        std::string err, p = projectIn(d, err);
        if (!p.empty()) return p;
    }
    return "";
}

}  // namespace

PackageStatus lockedPackageStatus(const std::string& projPath, const std::string& name) {
    PackageStatus st;
    std::vector<Locked> lock;
    std::string lp = lockPathFor(fs::absolute(projPath).string());
    std::error_code ec;
    st.lockExists = fs::exists(lp, ec) && readLock(lp, lock);
    for (const Locked& l : lock) {
        if (lower(l.name) != lower(name)) continue;
        st.locked = true;
        st.project = lockedProject(lp, l);
        if (!l.path.empty()) st.description = "paquete " + l.name + " (ruta " + l.path + ")";
        else
            st.description = "paquete " + l.name + " " + (l.version.empty() ? (l.branch.empty() ? "" : "rama " + l.branch + " ") : l.version + " ") +
                             "· commit " + l.commit.substr(0, 7) + " · " + l.git + (l.folder.empty() ? "" : " /" + l.folder);
        if (!l.deps.empty()) st.description += " · depende de " + join(l.deps, ", ");
    }
    return st;
}

bool packageVersionValid(const std::string& version, std::string& error) {
    Range r;
    return parseRange(version, r, error);
}

std::vector<std::string> lockedPackageProjects(const std::string& projPath) {
    std::vector<std::string> out;
    std::vector<Locked> lock;
    std::string lp = lockPathFor(fs::absolute(projPath).string());
    std::error_code ec;
    if (!fs::exists(lp, ec) || !readLock(lp, lock)) return out;
    for (const Locked& l : lock) {
        std::string p = lockedProject(lp, l);
        if (!p.empty()) out.push_back(p);
    }
    return out;
}

bool packageCommand(const std::vector<std::string>& args, const std::string& self, int& code) {
    if (args.empty()) return false;
    const std::string& cmd = args[0];
    const char* off = std::getenv("FASET_OFFLINE");
    if (off && *off && std::string(off) != "0") gOffline = true;
    if (cmd == "new") {
        if (std::find(args.begin(), args.end(), "--package") == args.end() && std::find(args.begin(), args.end(), "--paquete") == args.end())
            return false;
        code = newPackageCmd(Strings(args.begin() + 1, args.end()));
        return true;
    }
    static const std::set<std::string> mine = {"add", "remove", "restore", "update", "list", "paquetes", "packages", "pack", "publish", "__semver"};
    if (!mine.count(cmd)) return false;
    if (cmd == "__semver") {
        // Pruebas: faset __semver "<restricción>" 1.0.0 1.2.0 ... -> la más alta que cumple (o "ninguna").
        Range r;
        std::string err;
        if (args.size() < 2 || !parseRange(args[1], r, err)) {
            std::printf("error: %s\n", err.c_str());
            code = 1;
            return true;
        }
        std::string best;
        Semver bv;
        for (size_t i = 2; i < args.size(); i++) {
            Semver v;
            if (parseSemver(args[i], v) && satisfies(r, v) && (best.empty() || cmpSemver(v, bv) > 0)) {
                best = args[i];
                bv = v;
            }
        }
        std::printf("%s\n", best.empty() ? "ninguna" : best.c_str());
        code = 0;
        return true;
    }
    CliOpts o;
    size_t from = 1;
    if (cmd == "list") {
        // 'faset list paquetes' (y 'faset list packages').
        if (args.size() < 2 || (args[1] != "paquetes" && args[1] != "packages")) {
            fail("uso: faset list paquetes [--json] [--project x.fstproj]");
            code = 1;
            return true;
        }
        from = 2;
    }
    if (std::find(args.begin() + (long)from, args.end(), "--help") != args.end() ||
        std::find(args.begin() + (long)from, args.end(), "-h") != args.end()) {
        packagesUsage();
        code = 0;
        return true;
    }
    if (!parseOpts(args, from, o)) {
        code = 1;
        return true;
    }
    if (cmd == "add") code = addCmd(o);
    else if (cmd == "remove") code = removeCmd(o);
    else if (cmd == "restore" || cmd == "update") {
        std::string proj;
        Strings names;
        std::string given = o.project;
        for (const std::string& p : o.positional) {
            std::error_code ec;
            if (given.empty() && (fs::path(p).extension() == ".fstproj" || fs::path(p).extension() == ".fstp" || fs::is_directory(p, ec)))
                given = p;
            else names.push_back(p);
        }
        // Una solución (.fstp, o la de la carpeta actual si no hay .fstproj): cada proyecto con paquetes.
        std::string sln;
        std::error_code ec;
        if (fs::path(given).extension() == ".fstp") sln = given;
        else if (given.empty() || fs::is_directory(given, ec)) {
            fs::path dir = given.empty() ? fs::current_path() : fs::path(given);
            int projs = 0, slns = 0;
            for (auto& e : fs::directory_iterator(dir, ec)) {
                if (e.path().extension() == ".fstproj") projs++;
                if (e.path().extension() == ".fstp") {
                    slns++;
                    sln = e.path().string();
                }
            }
            if (projs > 0 || slns != 1) sln.clear();
        }
        if (!sln.empty()) {
            Solution s;
            std::string err;
            if (!loadSolution(sln, s, err)) {
                fail(err);
                code = 1;
                return true;
            }
            code = 0;
            int used = 0;
            for (const SolutionProject& sp : s.projects) {
                if (!fs::exists(sp.path, ec) || (!treeHasPackages(sp.path) && !fs::exists(lockPathFor(sp.path), ec))) continue;
                used++;
                if (restoreCmd(sp.path, cmd == "update" && names.empty(), names, false) != 0) code = 1;
            }
            if (!used) std::printf("Ningún proyecto de %s usa paquetes.\n", fs::path(sln).filename().string().c_str());
            return true;
        }
        if (cmd == "restore" && !names.empty()) {
            fail("uso: faset restore [proyecto] [--offline]");
            code = 1;
        } else if (!findTarget(given, proj)) code = 1;
        else code = restoreCmd(proj, cmd == "update" && names.empty(), names, false);
    } else if (cmd == "list" || cmd == "paquetes" || cmd == "packages") code = listCmd(o);
    else if (cmd == "pack" || cmd == "publish") code = packCmd(o, cmd == "publish");
    (void)self;
    return true;
}
