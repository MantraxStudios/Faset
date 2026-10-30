// Faset - 'faset test' (ver TestRunner.h).
//
// Cómo se ejecutan las pruebas:
//   1. Descubrimiento: cada archivo del usuario se analiza (solo sintaxis) y se buscan los métodos
//      con [Test] o [TestCase(...)], y los [Setup] / [Teardown] de su clase. Los argumentos de
//      [TestCase] se copian tal cual del código fuente.
//   2. Se genera obj/<Config>/pruebas/__pruebas.fst: la clase __FasetPruebas, con un método por
//      prueba y un Main que los llama en orden. Cada prueba va dentro de un 'try': una aserción
//      que falla (AssertException), una excepción o un error del runtime con 'try' activo
//      (referencia nula, índice, división por cero) la marcan como fallida y se sigue.
//   3. Se compila el proyecto con ese Main (se ignora el del proyecto) y se ejecuta. El programa
//      informa de cada prueba con líneas "##faset-test## ..." en la salida estándar.
//   4. Un panic (panic(), assert(), uso tras delete...) o un fallo grave terminan el proceso: no se
//      pueden atrapar. El ejecutor marca como fallida la prueba que estaba en marcha (con el
//      mensaje del panic) y vuelve a lanzar el programa desde la siguiente (--faset-test-desde N).
//      Así se paga un proceso por panic, no uno por prueba, y cada fallo queda aislado.
#include "TestRunner.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#if defined(_WIN32)
#define NOMINMAX
#include <io.h>
#include <windows.h>
#define popen _popen
#define pclose _pclose
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "Frontend.h"
#include "Json.h"
#include "Parser.h"
#include "Project.h"
#include "Solution.h"

namespace fs = std::filesystem;

bool testHarnessEntry = false;
const char* const kTestHarnessClass = "__FasetPruebas";

bool isTestAttribute(const std::string& name) {
    return name == "Test" || name == "TestCase" || name == "Ignore" || name == "Setup" || name == "Teardown";
}

// Argumento de atributo que no es una cadena: [TestCase(1, -2.5, true, 'x')]. Se consumen sus
// tokens hasta la ',' o el ')' que lo terminan; el texto exacto lo lee 'faset test' del fuente.
std::string Parser::attributeArgText() {
    std::string text;
    int depth = 0;
    while (!atEnd() && !(depth == 0 && (isP(",") || isP(")")))) {
        if (isP("(") || isP("[") || isP("{")) depth++;
        else if (isP(")") || isP("]") || isP("}")) depth--;
        text += cur().text.empty() ? "?" : cur().text;
        p_++;
    }
    if (text.empty()) fail("falta el argumento del atributo");
    return text;
}

bool isTestSourceFile(const std::string& file, const std::string& projectDir) {
    fs::path f(file);
    std::string name = f.filename().string();
    if (name.size() > 9 && name.compare(name.size() - 9, 9, "Tests.fst") == 0) return true;
    std::error_code ec;
    fs::path rel = fs::path(file).lexically_relative(projectDir);
    if (rel.empty() || *rel.begin() == "..") return false;
    for (auto it = rel.begin(); it != rel.end(); ++it) {
        auto next = it;
        if (++next == rel.end()) break;  // el propio archivo
        if (*it == "tests") return true;
    }
    return false;
}

namespace {

// ------------------------------------------------------------------ utilidades

bool readAll(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

bool writeAll(const std::string& path, const std::string& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << data;
    return (bool)f;
}

std::string shellQuote(const std::string& s) {
#if defined(_WIN32)
    return windowsQuote(s);
#else
    std::string r = "'";
    for (char c : s) r += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return r + "'";
#endif
}

std::string lower(std::string s) {
    for (char& c : s) c = (char)std::tolower((unsigned char)c);
    return s;
}

bool useColor() {
    if (std::getenv("NO_COLOR")) return false;
    if (std::getenv("FASET_COLOR") || std::getenv("FORCE_COLOR")) return true;
#if defined(_WIN32)
    HANDLE h = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0;
    if (!GetConsoleMode(h, &mode)) return false;
    return SetConsoleMode(h, mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */) != 0;
#else
    return isatty(1);
#endif
}

struct Colors {
    bool on = false;
    std::string c(const char* code, const std::string& s) const { return on ? std::string("\x1b[") + code + "m" + s + "\x1b[0m" : s; }
    std::string green(const std::string& s) const { return c("32", s); }
    std::string red(const std::string& s) const { return c("31", s); }
    std::string yellow(const std::string& s) const { return c("33", s); }
    std::string dim(const std::string& s) const { return c("2", s); }
    std::string bold(const std::string& s) const { return c("1", s); }
};

// Milisegundos con coma decimal ("0,42 ms", "1,3 s").
std::string showDuration(double ms) {
    char buf[64];
    if (ms >= 1000) std::snprintf(buf, sizeof buf, "%.2f s", ms / 1000);
    else if (ms >= 10) std::snprintf(buf, sizeof buf, "%.0f ms", ms);
    else std::snprintf(buf, sizeof buf, "%.2f ms", ms);
    std::string s = buf;
    std::replace(s.begin(), s.end(), '.', ',');
    return s;
}

std::string shownPath(const std::string& abs) {
    std::error_code ec;
    fs::path rel = fs::path(abs).lexically_relative(fs::current_path(ec));
    if (!rel.empty() && rel.begin()->string() != "..") return rel.generic_string();
    return abs;
}

// ------------------------------------------------------------------ argumentos de [TestCase]

// Salta un literal (cadena, @"", $"", carácter) o comentario que empieza en s[i]; devuelve el
// índice siguiente o 'i' si no hay ninguno.
size_t skipLiteral(const std::string& s, size_t i) {
    size_t n = s.size();
    if (s.compare(i, 2, "//") == 0) {
        while (i < n && s[i] != '\n') i++;
        return i;
    }
    if (s.compare(i, 2, "/*") == 0) {
        size_t e = s.find("*/", i + 2);
        return e == std::string::npos ? n : e + 2;
    }
    size_t j = i;
    bool verbatim = false, interp = false;
    while (j < n && (s[j] == '$' || s[j] == '@')) {
        if (s[j] == '@') verbatim = true;
        else interp = true;
        j++;
    }
    if (j >= n || (s[j] != '"' && !(s[j] == '\'' && j == i))) return i;
    if (s[j] == '\'') {
        j++;
        while (j < n && s[j] != '\'' && s[j] != '\n') j += s[j] == '\\' ? 2 : 1;
        return std::min(n, j + 1);
    }
    j++;
    int depth = 0;
    while (j < n) {
        char c = s[j];
        if (interp && depth > 0) {
            size_t k = skipLiteral(s, j);
            if (k != j) {
                j = k;
                continue;
            }
            if (c == '{') depth++;
            else if (c == '}') depth--;
            j++;
            continue;
        }
        if (interp && c == '{') {
            if (j + 1 < n && s[j + 1] == '{') j += 2;
            else depth++, j++;
            continue;
        }
        if (c == '"') {
            if (verbatim && j + 1 < n && s[j + 1] == '"') {
                j += 2;
                continue;
            }
            return j + 1;
        }
        if (!verbatim && c == '\\') {
            j += 2;
            continue;
        }
        if (!verbatim && c == '\n') return j;
        j++;
    }
    return n;
}

std::string squeeze(const std::string& s) {
    std::string out;
    size_t i = 0;
    while (i < s.size()) {
        size_t k = skipLiteral(s, i);
        if (k != i) {
            if (s.compare(i, 2, "//") != 0 && s.compare(i, 2, "/*") != 0) out += s.substr(i, k - i);
            i = k;
            continue;
        }
        char c = s[i++];
        if (std::isspace((unsigned char)c)) {
            if (!out.empty() && out.back() != ' ') out += ' ';
        } else {
            out += c;
        }
    }
    while (!out.empty() && out.back() == ' ') out.pop_back();
    if (!out.empty() && out[0] == ' ') out.erase(0, 1);
    return out;
}

// Argumentos del atributo que empieza en (línea, columna) del texto: "TestCase(1, \"a,b\", 3)"
// -> {"1", "\"a,b\"", "3"}, copiados del código.
bool attributeArgsAt(const std::string& src, int line, int col, std::vector<std::string>& args) {
    size_t i = 0;
    for (int l = 1; l < line && i < src.size(); i++)
        if (src[i] == '\n') l++;
    i += (size_t)std::max(0, col - 1);
    while (i < src.size() && (std::isalnum((unsigned char)src[i]) || src[i] == '_')) i++;
    while (i < src.size() && std::isspace((unsigned char)src[i])) i++;
    if (i >= src.size() || src[i] != '(') return false;
    i++;
    int depth = 0;
    size_t start = i;
    while (i < src.size()) {
        size_t k = skipLiteral(src, i);
        if (k != i) {
            i = k;
            continue;
        }
        char c = src[i];
        if (c == '(' || c == '[' || c == '{') depth++;
        else if ((c == ')' || c == ']' || c == '}') && depth > 0) depth--;
        else if (depth == 0 && (c == ',' || c == ')')) {
            std::string a = squeeze(src.substr(start, i - start));
            if (!a.empty() || c == ',') args.push_back(a);
            if (c == ')') return true;
            start = i + 1;
        }
        i++;
    }
    return false;
}

// ------------------------------------------------------------------ descubrimiento

struct HookMethod {
    std::string name;
    bool isStatic = false;
};

struct TestInfo {
    std::string file;   // ruta absoluta
    int line = 0;
    std::string ns;     // "Mi.Espacio" ("" = global)
    std::string cls;    // "Calculadora" ("" = función de un namespace)
    std::string method;
    std::string args;   // "1, 2, 3" para [TestCase]
    bool isCase = false;
    bool isStatic = false;
    bool isTask = false;  // async Task: se espera con .Wait()
    bool ignored = false;
    std::string ignoreReason;
    std::vector<HookMethod> setups, teardowns;
    std::string fullName() const {
        std::string n = ns.empty() ? "" : ns + ".";
        if (!cls.empty()) n += cls + ".";
        n += method;
        if (isCase) n += "(" + args + ")";
        return n;
    }
    std::string className() const {
        std::string n = ns;
        if (!cls.empty()) n += (n.empty() ? "" : ".") + cls;
        return n;
    }
    std::string qualifier() const { return className(); }
};

const Attribute* attr(const std::vector<Attribute>& attrs, const char* name) {
    for (const Attribute& a : attrs)
        if (a.name == name) return &a;
    return nullptr;
}

std::string dotted(std::string ns) {
    for (size_t k = ns.find("::"); k != std::string::npos; k = ns.find("::")) ns.replace(k, 2, ".");
    return ns;
}

struct Discovery {
    std::vector<TestInfo> tests;
    std::vector<std::string> errors;  // "archivo:línea: error: mensaje"
};

void discoverFile(const std::string& path, const std::string& src, Discovery& out) {
    Program prog;
    auto* file = new FileScope();
    file->fileId = diag.addFile(path, path);
    prog.files.push_back(file);
    std::set<std::string> roots = {"std"};
    auto toks = std::make_shared<std::vector<Token>>(tokenize(src, file->fileId));
    Parser(toks, prog, file, fs::path(path).parent_path().string(), &roots).parseFile();
    auto err = [&](int line, const std::string& msg) {
        out.errors.push_back(shownPath(path) + ":" + std::to_string(line) + ": error: " + msg);
    };
    for (ClassDecl* c : prog.types) {
        std::vector<HookMethod> setups, teardowns;
        std::vector<MethodDecl*> tests;
        for (MethodDecl* m : c->methods) {
            bool isTest = attr(m->attrs, "Test") || attr(m->attrs, "TestCase");
            bool isSetup = attr(m->attrs, "Setup"), isTeardown = attr(m->attrs, "Teardown");
            if (!isTest && !isSetup && !isTeardown) continue;
            std::string what = isTest ? "[Test]" : isSetup ? "[Setup]" : "[Teardown]";
            if (m->kind != MethodKind::Normal) {
                err(m->loc.line, what + " solo se aplica a métodos");
                continue;
            }
            if (!c->isNamespaceScope && m->mods.access != Access::Public) {
                err(m->loc.line, "el método " + what + " '" + m->name + "' debe ser public");
                continue;
            }
            if (!m->typeParams.empty() || !c->typeParams.empty()) {
                err(m->loc.line, "un método " + what + " no puede ser genérico ni estar en una clase genérica");
                continue;
            }
            if (isTest) {
                tests.push_back(m);
                continue;
            }
            if (!m->params.empty()) {
                err(m->loc.line, "el método " + what + " '" + m->name + "' no debe tener parámetros");
                continue;
            }
            (isSetup ? setups : teardowns).push_back({m->name, m->isStatic() || c->isNamespaceScope});
        }
        if (tests.empty()) continue;
        bool needsInstance = false;
        for (MethodDecl* m : tests) needsInstance |= !m->isStatic() && !c->isNamespaceScope;
        for (const HookMethod& h : setups) needsInstance |= !h.isStatic;
        for (const HookMethod& h : teardowns) needsInstance |= !h.isStatic;
        if (needsInstance) {
            bool defaultCtor = c->ctors.empty();
            for (MethodDecl* k : c->ctors)
                if (k->params.empty() && k->mods.access == Access::Public) defaultCtor = true;
            std::string why = c->kind != ClassKind::Class ? "no es una clase"
                              : c->mods.isStatic          ? "es estática"
                              : c->mods.isAbstract        ? "es abstracta"
                              : !defaultCtor              ? "no tiene un constructor público sin parámetros"
                                                          : "";
            if (c->mods.access != Access::Public && !c->isNamespaceScope && c->mods.hasAccess) why = "no es public";
            if (!why.empty()) {
                err(c->loc.line, "la clase '" + c->name + "' tiene pruebas de instancia pero " + why);
                continue;
            }
        }
        for (MethodDecl* m : tests) {
            TestInfo base;
            base.file = path;
            base.line = m->loc.line;
            base.ns = dotted(c->ns);
            base.cls = c->isNamespaceScope ? "" : c->name;
            base.method = m->name;
            base.isStatic = m->isStatic() || c->isNamespaceScope;
            base.isTask = m->retRef && !m->retRef->parts.empty() && m->retRef->parts.back() == "Task";
            base.setups = setups;
            base.teardowns = teardowns;
            if (const Attribute* ig = attr(m->attrs, "Ignore")) {
                base.ignored = true;
                base.ignoreReason = ig->args.empty() ? "" : ig->args[0];
            }
            bool any = false;
            bool hasParams = !m->params.empty() && m->params.back().isParams;
            for (const Attribute& a : m->attrs) {
                if (a.name != "TestCase") continue;
                any = true;
                std::vector<std::string> args;
                if (!attributeArgsAt(src, a.loc.line, a.loc.col, args)) {
                    err(a.loc.line, "no se pudieron leer los argumentos de [TestCase]");
                    continue;
                }
                if (!hasParams && args.size() != m->params.size()) {
                    err(a.loc.line, "[TestCase] tiene " + std::to_string(args.size()) + " argumento(s) pero '" + m->name + "' tiene " +
                                        std::to_string(m->params.size()) + " parámetro(s)");
                    continue;
                }
                TestInfo t = base;
                t.isCase = true;
                for (size_t i = 0; i < args.size(); i++) t.args += (i ? ", " : "") + args[i];
                t.line = a.loc.line;
                out.tests.push_back(t);
            }
            if (attr(m->attrs, "Test") && !m->params.empty()) {
                err(m->loc.line, "la prueba '" + m->name + "' tiene parámetros: usa [TestCase(...)] para darles valores");
                continue;
            }
            if (!any) out.tests.push_back(base);
        }
    }
}

Discovery discover(const std::vector<std::string>& inputs, const std::set<std::string>& defines) {
    Discovery d;
    setDefines(defines);
    for (const std::string& in : inputs) {
        if (fs::path(in).extension() != ".fst") continue;
        std::string src;
        if (!readAll(in, src)) continue;
        // Filtro rápido: sin '[Test' ni 'TestCase' no hace falta analizar el archivo.
        if (src.find("Test") == std::string::npos) continue;
        diag.reset();
        diag.capture = true;
        discoverFile(normalizePath(in), src, d);
    }
    diag.reset();  // los errores de sintaxis los dará la compilación
    return d;
}

// ------------------------------------------------------------------ opciones

struct TestOptions {
    std::vector<std::string> filters;
    bool exact = false;
    bool list = false, json = false;
    std::string report;
    bool quiet = false;     // solo fallos y resumen
    double timeoutSec = 0;  // 0 = sin límite (reservado)
};

bool parseTestOptions(const std::vector<std::string>& args, TestOptions& o) {
    for (size_t i = 0; i < args.size(); i++) {
        const std::string& a = args[i];
        auto next = [&](std::string& v) {
            if (i + 1 >= args.size()) {
                std::fprintf(stderr, "faset: error: falta el valor de '%s'\n", a.c_str());
                return false;
            }
            v = args[++i];
            return true;
        };
        std::string v;
        if (a == "--filter" || a == "-f") {
            if (!next(v)) return false;
            o.filters.push_back(v);
        } else if (a == "--exact") o.exact = true;
        else if (a == "--list") o.list = true;
        else if (a == "--json") o.json = true;
        else if (a == "-q" || a == "--quiet") o.quiet = true;
        else if (a == "--report") {
            if (!next(o.report)) return false;
        }
    }
    return true;
}

bool selected(const TestInfo& t, const TestOptions& o) {
    if (o.filters.empty()) return true;
    std::string full = t.fullName();
    std::string noArgs = full.substr(0, full.find('('));
    for (const std::string& f : o.filters) {
        if (o.exact) {
            if (f == full || f == noArgs) return true;
        } else if (lower(full).find(lower(f)) != std::string::npos) {
            return true;
        }
    }
    return false;
}

// ------------------------------------------------------------------ main generado

std::string generateHarness(const std::vector<const TestInfo*>& run) {
    std::string s =
        "// Generado por 'faset test': ejecuta las pruebas del proyecto. No lo edites.\n"
        "using std.test;\n\n"
        "static class " + std::string(kTestHarnessClass) + "\n{\n";
    for (size_t i = 0; i < run.size(); i++) {
        const TestInfo& t = *run[i];
        std::string q = t.qualifier();
        std::string self = t.isStatic ? (q.empty() ? "" : q + ".") : "__o.";
        bool instance = !t.isStatic;
        for (const HookMethod& h : t.setups) instance |= !h.isStatic;
        for (const HookMethod& h : t.teardowns) instance |= !h.isStatic;
        auto call = [&](const std::string& name, bool isStatic) { return (isStatic ? (q.empty() ? "" : q + ".") : std::string("__o.")) + name; };
        s += "    // " + t.fullName() + "\n";
        s += "    static void __Prueba" + std::to_string(i) + "(TestHarness __r)\n    {\n";
        s += "        if (!__r.Start(" + std::to_string(i) + ")) return;\n";
        s += "        try\n        {\n";
        std::string in = "            ";
        if (instance) s += in + "var __o = new " + q + "();\n";
        std::string body;
        for (const HookMethod& h : t.setups) body += call(h.name, h.isStatic) + "();\n";
        body += call(t.method, t.isStatic) + "(" + t.args + ")" + (t.isTask ? ".Wait()" : "") + ";\n";
        if (t.teardowns.empty()) {
            std::stringstream ss(body);
            std::string l;
            while (std::getline(ss, l)) s += in + l + "\n";
        } else {
            s += in + "try\n" + in + "{\n";
            std::stringstream ss(body);
            std::string l;
            while (std::getline(ss, l)) s += in + "    " + l + "\n";
            s += in + "}\n" + in + "finally\n" + in + "{\n";
            for (const HookMethod& h : t.teardowns) s += in + "    " + call(h.name, h.isStatic) + "();\n";
            s += in + "}\n";
        }
        (void)self;
        s += in + "__r.Pass();\n";
        s += "        }\n        catch (Exception __e)\n        {\n            __r.Fail(__e);\n        }\n    }\n\n";
    }
    s += "    static int Main()\n    {\n        var __r = new TestHarness();\n";
    for (size_t i = 0; i < run.size(); i++) s += "        __Prueba" + std::to_string(i) + "(__r);\n";
    s += "        return __r.Finish();\n    }\n}\n";
    return s;
}

// ------------------------------------------------------------------ resultados

enum class Status { NotRun, Passed, Failed, Skipped };

struct Result {
    const TestInfo* test = nullptr;
    Status status = Status::NotRun;
    double ms = 0;
    std::string type, message, trace, expected, actual, output;
    bool hasValues = false, panicked = false;
    std::string failFile;
    int failLine = 0;
};

std::string unescape(const std::string& s) {
    std::string r;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '\\' && i + 1 < s.size()) {
            char c = s[++i];
            r += c == 'n' ? '\n' : c == 'r' ? '\r' : c;
        } else {
            r += s[i];
        }
    }
    return r;
}

// "...archivo.fst:12" o "... (archivo.fst:12)" -> (archivo, 12)
bool parseWhere(std::string s, std::string& file, int& line) {
    while (!s.empty() && (s.back() == ')' || std::isspace((unsigned char)s.back()))) s.pop_back();
    size_t colon = s.rfind(':');
    if (colon == std::string::npos || colon + 1 >= s.size()) return false;
    for (size_t k = colon + 1; k < s.size(); k++)
        if (!std::isdigit((unsigned char)s[k])) return false;
    size_t start = s.rfind('(', colon);
    size_t en = s.rfind(" en ", colon);
    size_t at = s.rfind(" at ", colon);
    size_t from = 0;
    if (start != std::string::npos) from = start + 1;
    else if (at != std::string::npos) from = at + 4;
    else if (en != std::string::npos) from = en + 4;
    file = s.substr(from, colon - from);
    while (!file.empty() && file[0] == ' ') file.erase(0, 1);
    line = std::atoi(s.c_str() + colon + 1);
    return !file.empty() && line > 0;
}

std::string absoluteFrom(const std::string& file, const fs::path& base) {
    fs::path p(file);
    if (p.is_relative()) p = base / p;
    return p.lexically_normal().string();
}

// Ejecuta el programa de pruebas desde 'from' y lee sus resultados. Devuelve el índice de la
// prueba que estaba en marcha si el proceso terminó a medias (-1 si llegó al final).
int runBatch(const std::string& exe, int from, const std::string& errFile, std::vector<Result>& results, const Colors& col,
             const TestOptions& opt, const fs::path& compileDir, bool& ended, std::string& stray,
             const std::function<void(Result&)>& onDone) {
    std::string cmd = shellQuote(exe) + " --faset-test-desde " + std::to_string(from) + " 2> " + shellQuote(errFile);
#if defined(_WIN32)
    cmd = "\"" + cmd + "\"";  // cmd /c quita las comillas exteriores
#endif
    std::fflush(stdout);
    FILE* p = popen(cmd.c_str(), "r");
    if (!p) return from;
    int current = -1;
    ended = false;
    const std::string mark = "##faset-test## ";
    std::string line;
    char buf[4096];
    auto handle = [&](std::string l) {
        if (!l.empty() && l.back() == '\r') l.pop_back();
        size_t k = l.find(mark);
        std::string before = k == std::string::npos ? l : l.substr(0, k);
        if (k == std::string::npos || !before.empty()) {
            if (current >= 0 && current < (int)results.size()) results[current].output += before + (k == std::string::npos ? "\n" : "");
            else stray += before + "\n";
        }
        if (k == std::string::npos) return;
        std::string rest = l.substr(k + mark.size());
        std::string verb = rest.substr(0, rest.find(' '));
        rest = rest.size() > verb.size() ? rest.substr(verb.size() + 1) : "";
        if (verb == "end") {
            ended = true;
            current = -1;
            return;
        }
        int idx = std::atoi(rest.c_str());
        std::string val = rest.find(' ') == std::string::npos ? "" : rest.substr(rest.find(' ') + 1);
        if (idx < 0 || idx >= (int)results.size()) return;
        Result& r = results[idx];
        if (verb == "begin") current = idx;
        else if (verb == "type") r.type = unescape(val);
        else if (verb == "msg") r.message = unescape(val);
        else if (verb == "trace") r.trace = unescape(val);
        else if (verb == "expected") r.expected = unescape(val), r.hasValues = true;
        else if (verb == "actual") r.actual = unescape(val);
        else if (verb == "pass" || verb == "fail") {
            r.ms = std::atof(val.c_str()) / 1000.0;
            r.status = verb == "pass" ? Status::Passed : Status::Failed;
            if (r.status == Status::Failed) {
                std::string first = r.trace.substr(0, r.trace.find('\n'));
                if (parseWhere(first, r.failFile, r.failLine)) r.failFile = absoluteFrom(r.failFile, compileDir);
                else r.failFile.clear();
            }
            current = -1;
            onDone(r);
        }
    };
    while (std::fgets(buf, sizeof buf, p)) {
        line += buf;
        if (!line.empty() && line.back() == '\n') {
            line.pop_back();
            handle(line);
            line.clear();
        }
    }
    if (!line.empty()) handle(line);
    pclose(p);
    (void)col;
    (void)opt;
    return ended ? -1 : current;
}

std::string xmlEscape(const std::string& s) {
    std::string r;
    for (unsigned char c : s) {
        if (c == '&') r += "&amp;";
        else if (c == '<') r += "&lt;";
        else if (c == '>') r += "&gt;";
        else if (c == '"') r += "&quot;";
        else if (c < 0x20 && c != '\n' && c != '\t' && c != '\r') r += "?";
        else r += (char)c;
    }
    return r;
}

const char* statusName(Status s) {
    return s == Status::Passed ? "passed" : s == Status::Failed ? "failed" : s == Status::Skipped ? "skipped" : "notRun";
}

Json resultJson(const Result& r) {
    const TestInfo& t = *r.test;
    Json j = Json::object();
    j["name"] = t.fullName();
    j["className"] = t.className();
    j["method"] = t.method;
    j["file"] = t.file;
    j["line"] = t.line;
    j["status"] = statusName(r.status);
    j["durationMs"] = r.ms;
    if (r.status == Status::Skipped) j["reason"] = t.ignoreReason;
    if (r.status == Status::Failed) {
        j["exceptionType"] = r.type;
        j["message"] = r.message;
        if (r.hasValues) {
            j["expected"] = r.expected;
            j["actual"] = r.actual;
        }
        j["failureFile"] = r.failFile.empty() ? t.file : r.failFile;
        j["failureLine"] = r.failFile.empty() ? t.line : r.failLine;
        j["trace"] = r.trace;
        j["panic"] = r.panicked;
    }
    if (!r.output.empty()) j["output"] = r.output;
    return j;
}

// Informe JUnit (para CI) a partir del JSON de uno o varios proyectos.
std::string junitXml(const Json& projects) {
    int total = 0, failures = 0, skipped = 0;
    double ms = 0;
    std::string suites;
    for (const Json& p : projects.elements()) {
        int pt = 0, pf = 0, ps = 0;
        double pms = 0;
        std::string cases;
        for (const Json& t : p.get("tests").elements()) {
            pt++;
            pms += t.get("durationMs").asNumber();
            std::string st = t.get("status").asString();
            char time[32];
            std::snprintf(time, sizeof time, "%.6f", t.get("durationMs").asNumber() / 1000);
            std::string name = t.get("name").asString();
            std::string cls = t.get("className").asString();
            std::string shortName = cls.empty() || name.compare(0, cls.size() + 1, cls + ".") != 0 ? name : name.substr(cls.size() + 1);
            cases += "    <testcase classname=\"" + xmlEscape(cls.empty() ? p.get("project").asString() : cls) + "\" name=\"" +
                     xmlEscape(shortName) + "\" time=\"" + time + "\" file=\"" + xmlEscape(t.get("file").asString()) +
                     "\" line=\"" + std::to_string(t.get("line").asInt()) + "\"";
            std::string inner;
            if (st == "failed") {
                pf++;
                std::string body = t.get("message").asString();
                if (t.has("expected"))
                    body += "\nesperado: " + t.get("expected").asString() + "\nobtenido: " + t.get("actual").asString();
                body += "\n" + t.get("failureFile").asString() + ":" + std::to_string(t.get("failureLine").asInt());
                inner += "      <failure message=\"" + xmlEscape(t.get("message").asString()) + "\" type=\"" +
                         xmlEscape(t.get("exceptionType").asString()) + "\">" + xmlEscape(body) + "</failure>\n";
            } else if (st == "skipped" || st == "notRun") {
                ps++;
                inner += "      <skipped message=\"" + xmlEscape(t.get("reason").asString()) + "\"/>\n";
            }
            if (t.has("output")) inner += "      <system-out>" + xmlEscape(t.get("output").asString()) + "</system-out>\n";
            cases += inner.empty() ? "/>\n" : ">\n" + inner + "    </testcase>\n";
        }
        char time[32];
        std::snprintf(time, sizeof time, "%.6f", pms / 1000);
        suites += "  <testsuite name=\"" + xmlEscape(p.get("project").asString()) + "\" tests=\"" + std::to_string(pt) +
                  "\" failures=\"" + std::to_string(pf) + "\" errors=\"0\" skipped=\"" + std::to_string(ps) + "\" time=\"" + time +
                  "\">\n" + cases + "  </testsuite>\n";
        total += pt, failures += pf, skipped += ps, ms += pms;
    }
    char time[32];
    std::snprintf(time, sizeof time, "%.6f", ms / 1000);
    return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites name=\"faset test\" tests=\"" + std::to_string(total) +
           "\" failures=\"" + std::to_string(failures) + "\" errors=\"0\" skipped=\"" + std::to_string(skipped) + "\" time=\"" + time +
           "\">\n" + suites + "</testsuites>\n";
}

bool writeReport(const std::string& path, const Json& projects) {
    bool xml = fs::path(path).extension() == ".xml";
    std::string data;
    if (xml) {
        data = junitXml(projects);
    } else {
        Json root = Json::object();
        int total = 0, passed = 0, failed = 0, skipped = 0;
        for (const Json& p : projects.elements())
            for (const Json& t : p.get("tests").elements()) {
                total++;
                std::string st = t.get("status").asString();
                if (st == "passed") passed++;
                else if (st == "failed") failed++;
                else skipped++;
            }
        root["total"] = total;
        root["passed"] = passed;
        root["failed"] = failed;
        root["skipped"] = skipped;
        root["projects"] = projects;
        data = root.dump() + "\n";
    }
    std::error_code ec;
    if (fs::path(path).has_parent_path()) fs::create_directories(fs::path(path).parent_path(), ec);
    if (!writeAll(path, data)) {
        std::fprintf(stderr, "faset: error: no se pudo escribir el informe '%s'\n", path.c_str());
        return false;
    }
    return true;
}

// Muestra las líneas de 'text' con sangría.
void printIndented(const std::string& text, const std::string& indent) {
    std::stringstream ss(text);
    std::string l;
    while (std::getline(ss, l)) std::printf("%s%s\n", indent.c_str(), l.c_str());
}

}  // namespace

// ------------------------------------------------------------------ faset test

bool takeTestOptions(std::vector<std::string>& args, std::vector<std::string>& testArgs) {
    std::vector<std::string> keep;
    for (size_t i = 0; i < args.size(); i++) {
        const std::string& a = args[i];
        if (a == "--") {
            keep.insert(keep.end(), args.begin() + (long)i, args.end());
            break;
        }
        bool withValue = a == "--filter" || a == "-f" || a == "--report";
        bool flag = a == "--exact" || a == "--list" || a == "--json" || a == "-q" || a == "--quiet";
        if (withValue) {
            if (i + 1 >= args.size()) {
                std::fprintf(stderr, "faset: error: falta el valor de '%s'\n", a.c_str());
                return false;
            }
            testArgs.push_back(a);
            testArgs.push_back(args[++i]);
        } else if (flag) {
            testArgs.push_back(a);
        } else {
            keep.push_back(a);
        }
    }
    args = keep;
    return true;
}

int runTests(const TestBuildHost& host) {
    TestOptions opt;
    if (!parseTestOptions(host.args, opt)) return 1;
    Colors col;
    col.on = !opt.list && !opt.json && useColor();
    std::string title = host.projectName.empty() ? "archivos" : host.projectName;

    Discovery d = discover(host.inputs, host.defines);
    for (const std::string& e : d.errors) std::fprintf(stderr, "%s\n", e.c_str());
    if (!d.errors.empty()) {
        std::fprintf(stderr, "faset test: %zu error(es) en las pruebas\n", d.errors.size());
        return 1;
    }
    std::vector<Result> results;
    for (const TestInfo& t : d.tests)
        if (selected(t, opt)) {
            Result r;
            r.test = &t;
            results.push_back(r);
        }

    if (opt.list) {
        if (opt.json) {
            Json arr = Json::array();
            for (const Result& r : results) {
                Json j = Json::object();
                j["name"] = r.test->fullName();
                j["className"] = r.test->className();
                j["method"] = r.test->method;
                j["file"] = r.test->file;
                j["line"] = r.test->line;
                if (r.test->ignored) j["ignored"] = r.test->ignoreReason.empty() ? "" : r.test->ignoreReason;
                arr.push(j);
            }
            Json root = Json::object();
            root["project"] = host.projectPath;
            root["tests"] = arr;
            std::printf("%s\n", root.dump().c_str());
        } else {
            for (const Result& r : results)
                std::printf("%s  %s:%d%s\n", r.test->fullName().c_str(), shownPath(r.test->file).c_str(), r.test->line,
                            r.test->ignored ? "  (ignorada)" : "");
        }
        return 0;
    }

    auto started = std::chrono::steady_clock::now();
    Json projectJson = Json::object();
    projectJson["project"] = title;
    projectJson["path"] = host.projectPath;
    if (results.empty()) {
        std::printf("%s: no se encontraron pruebas%s.\n", title.c_str(), opt.filters.empty() ? "" : " que coincidan con el filtro");
        projectJson["tests"] = Json::array();
        if (!opt.report.empty()) {
            Json arr = Json::array();
            arr.push(projectJson);
            if (!writeReport(opt.report, arr)) return 1;
        }
        return opt.filters.empty() ? 0 : 1;
    }

    std::vector<const TestInfo*> run;
    std::vector<int> runIndex;  // prueba del programa -> posición en 'results'
    for (size_t i = 0; i < results.size(); i++) {
        if (results[i].test->ignored) {
            results[i].status = Status::Skipped;
            continue;
        }
        run.push_back(results[i].test);
        runIndex.push_back((int)i);
    }

    std::printf("%s\n", col.bold("Pruebas de " + title + " (" + std::to_string(results.size()) + ")").c_str());
    std::fflush(stdout);
    std::vector<Result> ran(run.size());
    for (size_t i = 0; i < run.size(); i++) ran[i].test = run[i];
    std::error_code ec;
    if (!run.empty()) {
        fs::create_directories(host.objDir, ec);
        std::string harness = (fs::path(host.objDir) / "__pruebas.fst").string();
        if (!writeAll(harness, generateHarness(run))) {
            std::fprintf(stderr, "faset: error: no se pudo escribir '%s'\n", harness.c_str());
            return 1;
        }
#if defined(_WIN32)
        std::string exe = (fs::path(host.objDir) / "pruebas.exe").string();
#else
        std::string exe = (fs::path(host.objDir) / "pruebas").string();
#endif
        std::vector<std::string> inputs = host.inputs;
        inputs.push_back(harness);
        testHarnessEntry = true;
        int rc = host.build(inputs, exe);
        testHarnessEntry = false;
        if (rc != 0) {
            std::fprintf(stderr, "faset test: no se pudo compilar el programa de pruebas\n");
            return 1;
        }
        fs::path compileDir = fs::current_path(ec);
        fs::path runDir = host.projectPath.empty() ? compileDir : fs::path(host.projectPath).parent_path();
        std::string errFile = (fs::path(host.objDir) / "pruebas.stderr").string();
        exe = fs::absolute(exe, ec).string();
        errFile = fs::absolute(errFile, ec).string();
        auto showDone = [&](Result& r) {
            if (opt.quiet && r.status == Status::Passed) return;
            std::string mark = r.status == Status::Passed ? col.green("✓") : col.red("✗");
            std::printf("  %s %s %s\n", mark.c_str(), r.test->fullName().c_str(), col.dim("(" + showDuration(r.ms) + ")").c_str());
            std::fflush(stdout);
        };
        fs::current_path(runDir, ec);
        int from = 0;
        std::string stray;
        while (from < (int)ran.size()) {
            bool ended = false;
            auto t0 = std::chrono::steady_clock::now();
            int crashed = runBatch(exe, from, errFile, ran, col, opt, compileDir, ended, stray, showDone);
            if (crashed < 0 && ended) break;
            std::string err;
            readAll(errFile, err);
            if (crashed < 0) {
                // El programa terminó sin empezar ninguna prueba nueva (p. ej. un panic al iniciar).
                int next = from;
                while (next < (int)ran.size() && ran[next].status != Status::NotRun) next++;
                if (next >= (int)ran.size()) break;
                crashed = next;
            }
            Result& r = ran[crashed];
            r.status = Status::Failed;
            r.panicked = true;
            r.ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
            r.type = "panic";
            // "Faset panic: <mensaje> at archivo:línea"
            size_t k = err.rfind("Faset panic: ");
            if (k != std::string::npos) {
                std::string l = err.substr(k + 13);
                l = l.substr(0, l.find('\n'));
                size_t at = l.rfind(" at ");
                r.message = at == std::string::npos ? l : l.substr(0, at);
                if (at != std::string::npos && parseWhere(l, r.failFile, r.failLine)) r.failFile = absoluteFrom(r.failFile, compileDir);
                else r.failFile.clear();
            } else {
                r.message = "el programa de pruebas terminó de forma inesperada";
            }
            if (!err.empty()) r.output += err;
            showDone(r);
            from = crashed + 1;
        }
        fs::current_path(compileDir, ec);
        if (!stray.empty() && host.verbose) std::printf("%s", stray.c_str());
        for (size_t i = 0; i < ran.size(); i++) results[runIndex[i]] = ran[i];
    }
    for (const Result& r : results)
        if (r.status == Status::Skipped && !opt.quiet)
            std::printf("  %s %s %s\n", col.yellow("○").c_str(), r.test->fullName().c_str(),
                        col.dim(r.test->ignoreReason.empty() ? "(ignorada)" : "(ignorada: " + r.test->ignoreReason + ")").c_str());

    int passed = 0, failed = 0, skipped = 0;
    for (const Result& r : results) {
        if (r.status == Status::Passed) passed++;
        else if (r.status == Status::Failed) failed++;
        else skipped++;
    }
    if (failed) {
        std::printf("\n%s\n", col.bold("Fallos:").c_str());
        int n = 0;
        for (const Result& r : results) {
            if (r.status != Status::Failed) continue;
            const TestInfo& t = *r.test;
            std::string where = r.failFile.empty() ? shownPath(t.file) + ":" + std::to_string(t.line)
                                                   : shownPath(r.failFile) + ":" + std::to_string(r.failLine);
            std::printf("\n  %d) %s\n", ++n, col.red(t.fullName()).c_str());
            std::printf("     %s\n", where.c_str());
            std::string msg = r.panicked ? "panic: " + r.message
                              : r.type == "AssertException" ? r.message
                                                            : r.type + ": " + r.message;
            printIndented(msg, "     ");
            if (r.hasValues) {
                std::printf("       esperado: %s\n", col.green(r.expected).c_str());
                std::printf("       obtenido: %s\n", col.red(r.actual).c_str());
            }
            if (r.type != "AssertException" && !r.panicked && r.trace.find('\n') != std::string::npos)
                printIndented(r.trace, "    ");
            if (!r.output.empty()) {
                std::printf("     %s\n", col.dim("salida:").c_str());
                std::string out = r.output;
                if (out.size() > 4000) out = "...\n" + out.substr(out.size() - 4000);
                printIndented(out, "       ");
            }
        }
    }
    double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    std::string summary = std::to_string(passed) + (passed == 1 ? " correcta" : " correctas") + ", " + std::to_string(failed) +
                          (failed == 1 ? " fallida" : " fallidas");
    if (skipped) summary += ", " + std::to_string(skipped) + (skipped == 1 ? " ignorada" : " ignoradas");
    summary += " (" + std::to_string(results.size()) + (results.size() == 1 ? " prueba" : " pruebas") + ", " +
               showDuration(secs * 1000) + ")";
    std::printf("\n%s %s\n", col.bold("Resultado:").c_str(), failed ? col.red(summary).c_str() : col.green(summary).c_str());

    if (!opt.report.empty()) {
        Json tests = Json::array();
        for (const Result& r : results) tests.push(resultJson(r));
        projectJson["tests"] = tests;
        Json arr = Json::array();
        arr.push(projectJson);
        if (!writeReport(opt.report, arr)) return 1;
    }
    return failed ? 1 : 0;
}

// ------------------------------------------------------------------ soluciones

namespace {

int runSelfTest(const std::string& self, const std::vector<std::string>& args) {
#if defined(_WIN32)
    std::vector<std::string> all = {self};
    all.insert(all.end(), args.begin(), args.end());
    return runProgramWindows(all);
#else
    std::string cmd = shellQuote(self);
    for (const std::string& a : args) cmd += " " + shellQuote(a);
    std::fflush(stdout);
    std::fflush(stderr);
    int r = std::system(cmd.c_str());
    if (r != -1 && WIFEXITED(r)) return WEXITSTATUS(r);
    return 1;
#endif
}

// ¿Tiene pruebas el proyecto? (<IsTestProject> o algún archivo con [Test] / [TestCase])
bool projectHasTests(const std::string& path) {
    Project p;
    std::string err;
    if (!loadProject(path, p, err)) return true;  // que el error lo dé 'faset test' del proyecto
    if (p.boolProp("IsTestProject", false)) return true;
    for (const std::string& f : projectSources(p)) {
        std::string src;
        if (fs::path(f).extension() != ".fst" || !readAll(f, src)) continue;
        for (size_t k = src.find("Test"); k != std::string::npos; k = src.find("Test", k + 4)) {
            size_t b = k, e = k + 4;
            while (b > 0 && std::isspace((unsigned char)src[b - 1])) b--;
            if (src.compare(e, 4, "Case") == 0) e += 4;
            char prev = b > 0 ? src[b - 1] : 0, next = e < src.size() ? src[e] : 0;
            if ((prev == '[' || prev == ',') && !std::isalnum((unsigned char)next) && next != '_') return true;
        }
    }
    return false;
}

}  // namespace

bool solutionTestCommand(const std::vector<std::string>& args, const std::string& argv0, int& code) {
    if (args.empty() || args[0] != "test") return false;
    std::vector<std::string> rest(args.begin() + 1, args.end()), testArgs;
    if (!takeTestOptions(rest, testArgs)) {
        code = 1;
        return true;
    }
    static const std::set<std::string> valueOpts = {"-c", "--configuration", "--target", "--arch", "--cc", "-l", "-L"};
    std::vector<std::string> positional, opts;
    for (size_t i = 0; i < rest.size(); i++) {
        if (valueOpts.count(rest[i]) && i + 1 < rest.size()) {
            opts.push_back(rest[i]);
            opts.push_back(rest[++i]);
        } else if (!rest[i].empty() && rest[i][0] == '-') {
            opts.push_back(rest[i]);
        } else {
            positional.push_back(rest[i]);
        }
    }
    auto hasProject = [](const fs::path& dir) {
        std::error_code ec;
        for (auto& e : fs::directory_iterator(dir, ec))
            if (e.path().extension() == ".fstproj") return true;
        return false;
    };
    std::string sln;
    std::error_code ec;
    if (positional.empty()) {
        if (!hasProject(fs::current_path())) sln = findSolutionIn(fs::current_path().string());
    } else if (positional.size() == 1) {
        if (fs::path(positional[0]).extension() == ".fstp") sln = positional[0];
        else if (fs::is_directory(positional[0], ec) && !hasProject(positional[0])) sln = findSolutionIn(positional[0]);
    }
    if (sln.empty()) return false;
    Solution s;
    std::string err;
    if (!loadSolution(sln, s, err)) {
        std::fprintf(stderr, "faset: error: %s\n", err.c_str());
        code = 1;
        return true;
    }
    TestOptions opt;
    parseTestOptions(testArgs, opt);
    std::vector<int> order;
    if (!solutionBuildOrder(s, order, err)) {
        std::fprintf(stderr, "faset: error: %s: %s\n", s.path.c_str(), err.c_str());
        code = 1;
        return true;
    }
    std::string self = selfExePath(argv0);
    Json projects = Json::array();
    int withTests = 0, brokenProjects = 0;
    std::string tmpBase = (fs::temp_directory_path(ec) / ("faset-pruebas-" + std::to_string((unsigned long long)std::chrono::steady_clock::now().time_since_epoch().count()))).string();
    for (int i : order) {
        const SolutionProject& p = s.projects[i];
        if (!fs::exists(p.path) || !projectHasTests(p.path)) continue;
        withTests++;
        std::vector<std::string> a = {"test", p.path};
        a.insert(a.end(), opts.begin(), opts.end());
        for (size_t k = 0; k < testArgs.size(); k++) {
            if (testArgs[k] == "--report") {
                k++;
                continue;
            }
            a.push_back(testArgs[k]);
        }
        std::string part = tmpBase + "-" + std::to_string(i) + ".json";
        if (!opt.list) {
            a.push_back("--report");
            a.push_back(part);
            std::printf("\n");
        }
        int rc = runSelfTest(self, a);
        std::string text;
        Json j;
        bool report = !opt.list && readAll(part, text) && Json::parse(text, j);
        if (report)
            for (const Json& pj : j.get("projects").elements()) projects.push(pj);
        fs::remove(part, ec);
        // Sin informe, el proyecto no compiló; con informe, cuentan sus pruebas fallidas (un proyecto
        // en el que el filtro no encuentra nada no es un fallo de la solución).
        if (rc != 0 && (opt.list || !report)) brokenProjects++;
    }
    if (opt.list) {
        code = brokenProjects ? 1 : 0;
        return true;
    }
    if (withTests == 0) {
        std::printf("Solución '%s': ningún proyecto tiene pruebas.\n", s.name.c_str());
        code = 0;
        return true;
    }
    int total = 0, failed = 0, skipped = 0;
    for (const Json& p : projects.elements())
        for (const Json& t : p.get("tests").elements()) {
            total++;
            std::string st = t.get("status").asString();
            if (st == "failed") failed++;
            else if (st != "passed") skipped++;
        }
    Colors col;
    col.on = useColor();
    std::string summary = "Solución '" + s.name + "': " + std::to_string(withTests) + (withTests == 1 ? " proyecto" : " proyectos") +
                          " con pruebas, " + std::to_string(total - failed - skipped) + " correctas, " + std::to_string(failed) +
                          " fallidas";
    if (skipped) summary += ", " + std::to_string(skipped) + " ignoradas";
    if (brokenProjects) summary += " (" + std::to_string(brokenProjects) + " proyecto(s) no compilan)";
    bool bad = failed || brokenProjects || (total == 0 && !opt.filters.empty());
    if (total == 0 && !opt.filters.empty()) summary += " (ninguna prueba coincide con el filtro)";
    std::printf("\n%s\n", bad ? col.red(summary).c_str() : col.green(summary).c_str());
    if (!opt.report.empty() && !writeReport(opt.report, projects)) bad = true;
    code = bad ? 1 : 0;
    return true;
}
