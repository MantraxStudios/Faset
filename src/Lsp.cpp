#include "Lsp.h"

#include "Formatter.h"

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <thread>
#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#include <process.h>
#define getpid _getpid
#else
#include <unistd.h>
#endif

#include "Frontend.h"
#include "Json.h"
#include "Project.h"
#include "Solution.h"
#include "XmlIntel.h"

namespace fs = std::filesystem;

namespace {

bool readText(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

// Línea 'line0' (desde 0) de un texto, sin el salto de línea.
std::string textLine(const std::string& text, int line0) {
    size_t start = 0;
    for (int i = 0; i < line0; i++) {
        start = text.find('\n', start);
        if (start == std::string::npos) return "";
        start++;
    }
    size_t end = text.find('\n', start);
    std::string l = text.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (!l.empty() && l.back() == '\r') l.pop_back();
    return l;
}

bool writeText(const std::string& path, const std::string& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << data;
    return (bool)f;
}

// ---- Símbolos del documento (esquema / outline)

enum { skFunction = 12, skVariable = 13, skClass = 5, skStruct = 23, skEnum = 10, skMethod = 6, skProperty = 7,
       skField = 8, skConstructor = 9, skEnumMember = 22, skOperator = 25, skConstant = 14 };

Json symbolAt(const std::string& name, int kind, const std::string& detail, SourceLoc loc) {
    Json s = Json::object();
    s["name"] = name;
    s["kind"] = kind;
    s["detail"] = detail;
    s["line"] = loc.line;
    s["col"] = loc.col;
    return s;
}

Json methodSymbol(MethodDecl* m) {
    int kind = m->kind == MethodKind::Ctor       ? skConstructor
               : m->kind == MethodKind::Getter   ? skProperty
               : m->kind == MethodKind::Operator ? skOperator
               : m->owner->isNamespaceScope      ? skFunction
                                                 : skMethod;
    std::string name = m->kind == MethodKind::Ctor ? m->owner->name : m->name;
    return symbolAt(name, kind, Sema::methodSignature(m), m->loc);
}

}  // namespace

// ================================================================== analizador (subproceso)

int runAnalyzer(const std::string& requestPath, const std::string& resultPath, const std::string& argv0) {
    std::string reqText;
    Json req;
    if (!readText(requestPath, reqText) || !Json::parse(reqText, req)) return 2;

    diag.reset();
    diag.capture = true;
    // Las rutas se comparan normalizadas (sin enlaces simbólicos), pero se devuelven tal como las
    // escribió el cliente: si abrió el proyecto por un enlace, sus documentos tienen esas rutas.
    std::vector<std::pair<std::string, std::string>> clientDirs;  // carpeta normalizada -> carpeta del cliente
    std::map<std::string, std::string> clientNames;
    auto remember = [&](const std::string& raw) {
        std::string norm = normalizePath(raw);
        if (norm == raw || raw.empty()) return norm;
        clientNames.emplace(norm, raw);
        std::string nd = fs::path(norm).parent_path().string(), rd = fs::path(raw).parent_path().string();
        if (nd != rd && std::find(clientDirs.begin(), clientDirs.end(), std::make_pair(nd, rd)) == clientDirs.end())
            clientDirs.push_back({nd, rd});
        return norm;
    };
    auto clientPath = [&](const std::string& p) -> std::string {
        auto it = clientNames.find(p);
        if (it != clientNames.end()) return it->second;
        for (const auto& [nd, rd] : clientDirs)
            if (p.size() > nd.size() && p.compare(0, nd.size(), nd) == 0 && (p[nd.size()] == '/' || p[nd.size()] == '\\'))
                return rd + p.substr(nd.size());
        return p;
    };
    std::map<std::string, std::string> overrides;
    for (auto& [path, text] : req.get("overrides").items()) overrides[remember(path)] = text.asString();
    std::set<std::string> interest;
    for (const Json& p : req.get("interest").elements()) interest.insert(remember(p.asString()));

    // Autocompletado en un .fstproj o .fstui: el marcador no es XML válido, así que se quita
    // del texto y se recuerda su posición.
    std::string xmlCompletePath;
    size_t xmlCompleteOffset = 0;
    for (auto& [path, text] : overrides) {
        if (xmlDocKind(path) == XmlDocKind::None) continue;
        size_t m = text.find(kCompletionMarker);
        if (m == std::string::npos) continue;
        text.erase(m, std::strlen(kCompletionMarker));
        xmlCompletePath = path;
        xmlCompleteOffset = m;
    }
    std::map<std::string, std::string> diskCache;
    auto textOf = [&](const std::string& path) -> const std::string& {
        auto it = overrides.find(path);
        if (it != overrides.end()) return it->second;
        auto c = diskCache.find(path);
        if (c == diskCache.end()) {
            std::string t;
            readText(path, t);
            c = diskCache.emplace(path, t).first;
        }
        return c->second;
    };

    FrontendOptions fo;
    std::set<std::string> projects;  // .fstproj que se validan aunque no estén abiertos
    std::string projectError, projectPath;
    for (const Json& p : req.get("inputs").elements())
        if (xmlDocKind(p.asString()) != XmlDocKind::Project) fo.inputs.push_back(p.asString());
    // Sin 'inputs': se usa el proyecto (.fstproj) del archivo 'focus'. Con una solución ('solution',
    // o la .fstp más cercana) se elige el proyecto de la solución que compila ese archivo.
    std::string solutionHint = req.has("solution") ? req.get("solution").asString() : "";
    if (!solutionHint.empty()) interest.insert(remember(solutionHint));
    if (fo.inputs.empty() && req.has("focus") && xmlDocKind(req.get("focus").asString()) == XmlDocKind::Solution) {
        interest.insert(remember(req.get("focus").asString()));  // una .fstp solo se valida
    } else if (fo.inputs.empty() && req.has("focus")) {
        std::string focus = remember(req.get("focus").asString());
        bool focusIsProject = xmlDocKind(focus) == XmlDocKind::Project;
        projectPath = focusIsProject ? focus : projectForFile(focus, solutionHint);
        if (!projectPath.empty()) {
            projectPath = normalizePath(projectPath);
            projects.insert(projectPath);
            if (!projectTreeSources(projectPath, fo.inputs, projectError)) {
                // Proyecto no válido (o a medio editar): se analizan igualmente los archivos de su
                // carpeta, para que el resto del IntelliSense siga funcionando.
                Project p;
                p.dir = fs::path(projectPath).parent_path().string();
                fo.inputs = projectSources(p);
            }
        }
        for (auto& f : fo.inputs) f = normalizePath(f);
        if (!focusIsProject && std::find(fo.inputs.begin(), fo.inputs.end(), focus) == fo.inputs.end()) fo.inputs.push_back(focus);
        interest.insert(focus);
    }
    fo.libDir = findLibDir(argv0);
    for (const std::string& f : fo.inputs)
        if (projectAllowsUnsafe(f)) fo.unsafeFiles.insert(normalizePath(f));
    fo.overrides = &overrides;
    fo.analyzeWithParseErrors = true;
#if defined(_WIN32)
    fo.defines = definesFor("windows", "Debug");
#else
    fo.defines = definesFor("linux", "Debug");
#endif
    fo.ideMode = true;

    Json out = Json::object();
    FrontendResult r;
    if (fo.libDir.empty()) diag.fatal("no se encontró la biblioteca estándar de Faset (define FASET_LIB)");
    else if (!fo.inputs.empty()) r = runFrontend(fo);

    auto pathOf = [](int file) -> std::string {
        return file >= 0 && file < (int)diag.paths.size() ? diag.paths[file] : "";
    };

    Json diags = Json::array();
    auto addDiag = [&](const std::string& path, int line, int col, int severity, const std::string& message) {
        Json j = Json::object();
        j["path"] = clientPath(path);
        j["line"] = line;
        j["col"] = col;
        j["severity"] = severity;
        j["message"] = message;
        diags.push(std::move(j));
    };
    for (const auto& d : diag.captured) {
        std::string path = d.hasLoc ? pathOf(d.loc.file) : "";
        int line = d.loc.line, col = d.loc.col;
        // El código generado de un .fstui no se corresponde columna a columna con el XML.
        if (xmlDocKind(path) == XmlDocKind::Ui) xmlRefineUiDiagnostic(textOf(path), d.message, line, col);
        addDiag(path, line, col, d.severity == Diagnostics::Severity::Error ? 1 : d.severity == Diagnostics::Severity::Warning ? 2 : 3, d.message);
    }
    // Validación de los proyectos: el abierto, los que se están editando y el del archivo enfocado.
    for (const std::string& p : interest)
        if (xmlDocKind(p) == XmlDocKind::Project) projects.insert(p);
    for (const std::string& p : projects) {
        std::vector<XmlDiagnostic> list = xmlValidateProject(p, textOf(p));
        for (const XmlDiagnostic& d : list) addDiag(p, d.line, d.col, d.severity, d.message);
        if (p == projectPath && !projectError.empty() && list.empty()) addDiag(p, 1, 1, 1, projectError);
    }
    std::set<std::string> solutions;
    for (const std::string& p : interest)
        if (xmlDocKind(p) == XmlDocKind::Solution) solutions.insert(p);
    for (const std::string& p : solutions)
        for (const XmlDiagnostic& d : xmlValidateSolution(p, textOf(p))) addDiag(p, d.line, d.col, d.severity, d.message);
    for (const std::string& p : solutions) projects.insert(p);  // también cuentan como analizados
    out["diagnostics"] = std::move(diags);

    Json analyzed = Json::array();
    for (const std::string& p : diag.paths)
        if (!p.empty()) analyzed.push(clientPath(p));
    for (const std::string& p : projects) analyzed.push(clientPath(p));
    out["analyzed"] = std::move(analyzed);

    // Clase de cada ventana .fstui: manejadores para Click/Changed y destinos de 'ir a la definición'.
    auto uiCodeInfo = [&](const std::string& uiPath) {
        XmlUiCodeInfo info;
        std::string cls, ns;
        if (!r.sema || !xmlUiClass(textOf(uiPath), cls, ns)) return info;
        ClassDecl* found = nullptr;
        for (ClassDecl* c : r.prog->types)
            if (!c->templateOf && !c->isNamespaceScope && c->displayName == cls && (c->ns == ns || ns.empty())) found = c;
        if (!found) return info;
        info.found = true;
        info.classSignature = "partial class " + (found->ns.empty() ? "" : found->ns + ".") + cls;
        std::vector<MethodDecl*> all = found->ctors;
        all.insert(all.end(), found->methods.begin(), found->methods.end());
        for (MethodDecl* m : all) {
            std::string path = pathOf(m->loc.file);
            if (path.empty() || xmlDocKind(path) != XmlDocKind::None) continue;
            if (info.classPath.empty()) {
                // Línea de 'class Nombre' en el código de la ventana.
                info.classPath = path;
                info.classLine = m->loc.line;
                info.classCol = m->loc.col;
                const std::string& src = textOf(path);
                size_t k = src.find("class " + cls);
                while (k != std::string::npos && k + 6 + cls.size() < src.size() && isalnum((unsigned char)src[k + 6 + cls.size()]))
                    k = src.find("class " + cls, k + 1);
                if (k != std::string::npos) {
                    info.classLine = 1 + (int)std::count(src.begin(), src.begin() + (long)k, '\n');
                    size_t ls = src.rfind('\n', k);
                    info.classCol = (int)(k + 6 - (ls == std::string::npos ? 0 : ls + 1)) + 1;
                }
            }
            if (m->kind != MethodKind::Normal || m->name.rfind("__", 0) == 0) continue;
            XmlUiCodeInfo::Method mi;
            mi.name = m->name;
            mi.signature = Sema::methodSignature(m);
            mi.path = path;
            mi.line = m->loc.line;
            mi.col = m->loc.col;
            // void Nombre(Widget sender), o (Widget sender, string message) para MessageReceived del WebView.
            mi.handler = !m->isStatic() && (m->params.size() == 1 || (m->params.size() == 2 && m->params[1].tref &&
                                                                       m->params[1].tref->str() == "string")) &&
                         m->params[0].tref && m->params[0].tref->str().size() >= 6 &&
                         m->params[0].tref->str().compare(m->params[0].tref->str().size() - 6, 6, "Widget") == 0;
            info.methods.push_back(mi);
        }
        return info;
    };

    Json refs = Json::array();
    Json completions = Json::array();
    Json symbols = Json::object();
    if (r.sema) {
        for (const auto& ref : r.sema->refs) {
            std::string path = pathOf(ref.loc.file);
            if (!interest.count(path) || xmlDocKind(path) != XmlDocKind::None) continue;
            Json j = Json::object();
            j["path"] = clientPath(path);
            j["line"] = ref.loc.line;
            j["col"] = ref.loc.col;
            j["len"] = ref.length;
            j["hover"] = ref.hover;
            if (ref.hasDef) {
                std::string defPath = pathOf(ref.def.file);
                int defLine = ref.def.line, defCol = ref.def.col;
                if (xmlDocKind(defPath) == XmlDocKind::Ui) {
                    // Campo generado de un control: se va a su Name="..." en el .fstui.
                    std::string line = textLine(textOf(path), ref.loc.line - 1);
                    std::string ident = ref.loc.col >= 1 && ref.loc.col - 1 < (int)line.size()
                                            ? line.substr(ref.loc.col - 1, ref.length) : "";
                    if (!xmlUiControlPos(textOf(defPath), ident, defLine, defCol)) defLine = defCol = 1;
                }
                j["defPath"] = clientPath(defPath);
                j["defLine"] = defLine;
                j["defCol"] = defCol;
            }
            refs.push(std::move(j));
        }
        if (req.has("usingPath")) {
            // 'using a.b.' -> namespaces hijos
            std::vector<std::string> path;
            for (const Json& p : req.get("usingPath").elements()) path.push_back(p.asString());
            std::set<std::string> seen;
            auto addNs = [&](const std::string& name, const std::string& detail) {
                if (name.empty() || !seen.insert(name).second) return;
                Json c = Json::object();
                c["label"] = name;
                c["kind"] = 9;
                c["detail"] = detail;
                completions.push(std::move(c));
            };
            NamespaceSym* ns = path.empty() ? r.sema->globalNs() : r.sema->namespaceByPath(path);
            if (ns)
                for (auto& [name, child] : ns->children) addNs(name, "namespace " + child->name);
            // Módulos de la biblioteca que aún no se han cargado.
            fs::path dir(fo.libDir);
            std::string prefix;
            for (const std::string& part : path) {
                dir /= part;
                prefix += part + ".";
            }
            std::error_code ec;
            for (auto& e : fs::directory_iterator(dir, ec)) {
                std::string stem = e.path().stem().string();
                if (e.is_directory()) addNs(e.path().filename().string(), "namespace " + prefix + e.path().filename().string());
                else if (e.path().extension() == ".fst" && stem != "core" && stem != "exceptions") addNs(stem, "módulo " + prefix + stem);
            }
        } else if (xmlCompletePath.empty()) {
            for (const auto& c : r.sema->completions) {
                Json j = Json::object();
                j["label"] = c.label;
                j["kind"] = c.kind;
                j["detail"] = c.detail;
                completions.push(std::move(j));
            }
        }
        for (ClassDecl* c : r.prog->types) {
            if (c->templateOf) continue;
            std::string path = pathOf(c->loc.file);
            if (c->isNamespaceScope && !c->methods.empty()) path = pathOf(c->methods[0]->loc.file);
            else if (c->isNamespaceScope && !c->fields.empty()) path = pathOf(c->fields[0]->loc.file);
            if (!interest.count(path) || xmlDocKind(path) != XmlDocKind::None) continue;
            Json& list = symbols[clientPath(path)];
            if (!list.isArray()) list = Json::array();
            if (c->isNamespaceScope) {
                for (MethodDecl* m : c->methods)
                    if (m->owner) list.push(methodSymbol(m));
                for (FieldDecl* f : c->fields) list.push(symbolAt(f->name, skVariable, f->tref->str(), f->loc));
                continue;
            }
            int kind = c->kind == ClassKind::Struct ? skStruct : c->kind == ClassKind::Enum ? skEnum
                       : c->kind == ClassKind::Interface ? 11 /* Interface */ : skClass;
            Json s = symbolAt(c->displayName, kind, c->ns, c->loc);
            Json children = Json::array();
            for (EnumMember& em : c->enumMembers) children.push(symbolAt(em.name, skEnumMember, "", em.loc));
            for (FieldDecl* f : c->fields)
                children.push(symbolAt(f->name, f->mods.isConst ? skConstant : skField, f->tref->str(), f->loc));
            for (MethodDecl* m : c->ctors)
                if (m->owner) children.push(methodSymbol(m));
            for (MethodDecl* m : c->methods)
                if (m->owner) children.push(methodSymbol(m));
            if (c->dtor) children.push(symbolAt(c->dtor->name, skMethod, "destructor", c->dtor->loc));
            s["children"] = std::move(children);
            list.push(std::move(s));
        }
    }

    // .fstproj y .fstui: información emergente y autocompletado según su esquema.
    for (const std::string& path : interest) {
        XmlDocKind kind = xmlDocKind(path);
        if (kind == XmlDocKind::None) continue;
        XmlUiCodeInfo info = kind == XmlDocKind::Ui ? uiCodeInfo(path) : XmlUiCodeInfo();
        for (const XmlSymbolRef& x : xmlRefs(kind, path, textOf(path), &info)) {
            Json j = Json::object();
            j["path"] = clientPath(path);
            j["line"] = x.line;
            j["col"] = x.col;
            j["len"] = x.len;
            j["hover"] = x.hover;
            j["doc"] = true;  // texto, no código
            if (!x.defPath.empty()) {
                j["defPath"] = clientPath(normalizePath(x.defPath));
                j["defLine"] = x.defLine;
                j["defCol"] = x.defCol;
            }
            refs.push(std::move(j));
        }
    }
    if (!xmlCompletePath.empty()) {
        XmlDocKind kind = xmlDocKind(xmlCompletePath);
        XmlUiCodeInfo info = kind == XmlDocKind::Ui ? uiCodeInfo(xmlCompletePath) : XmlUiCodeInfo();
        for (const XmlCompletionItem& c : xmlComplete(kind, xmlCompletePath, textOf(xmlCompletePath), xmlCompleteOffset, &info)) {
            Json j = Json::object();
            j["label"] = c.label;
            j["kind"] = c.kind;
            j["detail"] = c.detail;
            if (!c.insert.empty()) j["insert"] = c.insert;
            completions.push(std::move(j));
        }
    }
    out["refs"] = std::move(refs);
    out["completions"] = std::move(completions);
    out["symbols"] = std::move(symbols);
    return writeText(resultPath, out.dump()) ? 0 : 3;
}

// ================================================================== servidor

namespace {

std::string percentDecode(const std::string& s) {
    std::string r;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '%' && i + 2 < s.size()) {
            r += (char)std::strtol(s.substr(i + 1, 2).c_str(), nullptr, 16);
            i += 2;
        } else {
            r += s[i];
        }
    }
    return r;
}

std::string uriToPath(const std::string& uri) {
    std::string p = uri.rfind("file://", 0) == 0 ? percentDecode(uri.substr(7)) : uri;
#if defined(_WIN32)
    if (p.size() > 2 && p[0] == '/' && p[2] == ':') p = p.substr(1);
#endif
    return normalizePath(utf8ToNative(p));  // la URI es UTF-8; las rutas, de la página ANSI en Windows
}

std::string pathToUri(const std::string& path) {
    std::string p = nativeToUtf8(path);
    std::replace(p.begin(), p.end(), '\\', '/');
    if (p.empty() || p[0] != '/') p = "/" + p;
    std::string r = "file://";
    for (unsigned char c : p) {
        if (isalnum(c) || c == '/' || c == '-' || c == '_' || c == '.' || c == '~' || c >= 0x80) {
            r += (char)c;
        } else {
            char buf[4];
            std::snprintf(buf, sizeof buf, "%%%02X", c);
            r += buf;
        }
    }
    return r;
}

bool isIdentChar(unsigned char c) { return isalnum(c) || c == '_' || c >= 0x80; }

// Columna en bytes (0) -> unidades UTF-16 (LSP).
int byteToUtf16(const std::string& line, int byteCol) {
    int units = 0;
    for (int i = 0; i < byteCol && i < (int)line.size();) {
        unsigned char c = (unsigned char)line[i];
        int len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
        units += len == 4 ? 2 : 1;
        i += len;
    }
    return units;
}

int utf16ToByte(const std::string& line, int units) {
    int i = 0, u = 0;
    while (i < (int)line.size() && u < units) {
        unsigned char c = (unsigned char)line[i];
        int len = c < 0x80 ? 1 : c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : c >= 0xC0 ? 2 : 1;
        u += len == 4 ? 2 : 1;
        i += len;
    }
    return i;
}

std::string lineOf(const std::string& text, int line0) {
    size_t start = 0;
    for (int i = 0; i < line0; i++) {
        start = text.find('\n', start);
        if (start == std::string::npos) return "";
        start++;
    }
    size_t end = text.find('\n', start);
    std::string l = text.substr(start, end == std::string::npos ? std::string::npos : end - start);
    if (!l.empty() && l.back() == '\r') l.pop_back();
    return l;
}

size_t offsetOf(const std::string& text, int line0, int byteCol) {
    size_t start = 0;
    for (int i = 0; i < line0; i++) {
        size_t n = text.find('\n', start);
        if (n == std::string::npos) return text.size();
        start = n + 1;
    }
    return std::min(text.size(), start + (size_t)byteCol);
}

#if !defined(_WIN32)
std::string quoteArg(const std::string& s) {
    std::string r = "'";
    for (char c : s) r += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return r + "'";
}
#endif

class Server {
public:
    explicit Server(std::string argv0) : argv0_(std::move(argv0)), self_(selfExePath(argv0_)) {}
    int run();

private:
    struct Doc {
        std::string uri;
        std::string text;
    };

    std::string argv0_, self_;
    std::map<std::string, Doc> docs_;  // ruta normalizada -> documento abierto
    std::mutex outMutex_;
    std::mutex qMutex_;
    std::condition_variable qCv_;
    std::deque<Json> queue_;
    bool eof_ = false;
    bool shutdown_ = false;
    int tmpCounter_ = 0;

    Json cache_;                      // último análisis
    bool cacheValid_ = false;
    std::string cacheFocus_;
    std::set<std::string> published_;  // archivos con diagnósticos publicados
    std::map<std::string, std::string> diskCache_;

    // E/S
    void readerLoop();
    void send(const Json& msg);
    void reply(const Json& id, Json result);
    void replyError(const Json& id, int code, const std::string& msg);
    void notify(const std::string& method, Json params);

    // análisis
    Json analyze(const std::string& focus, const std::map<std::string, std::string>* focusOverride,
                 const Json* usingPath);
    void refreshDiagnostics(const std::string& focus);
    const Json& ensureCache(const std::string& focus);
    std::string fileLine(const std::string& path, int line0);
    Json range(const std::string& path, int line1, int col1, int len);

    // mensajes
    void handle(const Json& msg, std::set<std::string>& dirty);
    Json hover(const Json& params);
    Json definition(const Json& params);
    Json completion(const Json& params);
    Json documentSymbols(const Json& params);
    const Json* refAt(const std::string& path, int line0, int ch);
};

void Server::readerLoop() {
    for (;;) {
        size_t length = 0;
        bool any = false;
        std::string header;
        for (;;) {
            header.clear();
            int c;
            while ((c = std::fgetc(stdin)) != EOF && c != '\n') header += (char)c;
            if (c == EOF) {
                std::lock_guard<std::mutex> lk(qMutex_);
                eof_ = true;
                qCv_.notify_all();
                return;
            }
            if (!header.empty() && header.back() == '\r') header.pop_back();
            if (header.empty()) {
                if (any) break;
                continue;
            }
            any = true;
            if (header.rfind("Content-Length:", 0) == 0) length = (size_t)std::strtoul(header.c_str() + 15, nullptr, 10);
        }
        std::string body(length, '\0');
        if (length && std::fread(&body[0], 1, length, stdin) != length) {
            std::lock_guard<std::mutex> lk(qMutex_);
            eof_ = true;
            qCv_.notify_all();
            return;
        }
        Json msg;
        if (!Json::parse(body, msg)) continue;
        std::lock_guard<std::mutex> lk(qMutex_);
        queue_.push_back(std::move(msg));
        qCv_.notify_all();
    }
}

void Server::send(const Json& msg) {
    std::string body = msg.dump();
    std::lock_guard<std::mutex> lk(outMutex_);
    std::fprintf(stdout, "Content-Length: %zu\r\n\r\n", body.size());
    std::fwrite(body.data(), 1, body.size(), stdout);
    std::fflush(stdout);
}

void Server::reply(const Json& id, Json result) {
    Json m = Json::object();
    m["jsonrpc"] = "2.0";
    m["id"] = id;
    m["result"] = std::move(result);
    send(m);
}

void Server::replyError(const Json& id, int code, const std::string& msg) {
    Json m = Json::object();
    m["jsonrpc"] = "2.0";
    m["id"] = id;
    Json e = Json::object();
    e["code"] = code;
    e["message"] = msg;
    m["error"] = std::move(e);
    send(m);
}

void Server::notify(const std::string& method, Json params) {
    Json m = Json::object();
    m["jsonrpc"] = "2.0";
    m["method"] = method;
    m["params"] = std::move(params);
    send(m);
}

// Lanza 'faset __analyze' en un subproceso con el estado actual de los documentos.
Json Server::analyze(const std::string& focus, const std::map<std::string, std::string>* focusOverride,
                     const Json* usingPath) {
    Json req = Json::object();
    // El subproceso calcula los archivos del proyecto de 'focus' (y sabe tratar los .fstproj).
    req["focus"] = focus;
    Json ov = Json::object();
    Json interest = Json::array();
    for (const auto& [path, doc] : docs_) {
        ov[path] = doc.text;
        interest.push(path);
    }
    if (focusOverride)
        for (const auto& [path, text] : *focusOverride) ov[path] = text;
    req["overrides"] = std::move(ov);
    req["interest"] = std::move(interest);
    if (usingPath) req["usingPath"] = *usingPath;

    fs::path tmp = fs::temp_directory_path();
    std::string base = "faset-lsp-" + std::to_string(getpid()) + "-" + std::to_string(++tmpCounter_);
    std::string reqPath = (tmp / (base + "-req.json")).string();
    std::string resPath = (tmp / (base + "-res.json")).string();
    Json result;
    if (writeText(reqPath, req.dump())) {
#if defined(_WIN32)
        int rc = runProgramWindows({self_, "__analyze", reqPath, resPath});  // sin cmd.exe
#else
        std::string cmd = quoteArg(self_) + " __analyze " + quoteArg(reqPath) + " " + quoteArg(resPath);
        int rc = std::system(cmd.c_str());
#endif
        std::string text;
        if (rc == 0 && readText(resPath, text)) Json::parse(text, result);
    }
    std::error_code ec;
    fs::remove(reqPath, ec);
    fs::remove(resPath, ec);
    if (!result.isObject()) {
        result = Json::object();
        Json d = Json::array();
        Json e = Json::object();
        e["path"] = focus;
        e["line"] = 1;
        e["col"] = 1;
        e["severity"] = 1;
        e["message"] = "el analizador de Faset falló de forma inesperada";
        d.push(std::move(e));
        result["diagnostics"] = std::move(d);
    }
    diskCache_.clear();
    return result;
}

std::string Server::fileLine(const std::string& path, int line0) {
    auto it = docs_.find(path);
    if (it != docs_.end()) return lineOf(it->second.text, line0);
    auto c = diskCache_.find(path);
    if (c == diskCache_.end()) {
        std::string text;
        readText(path, text);
        c = diskCache_.emplace(path, text).first;
    }
    return lineOf(c->second, line0);
}

// Rango LSP para (línea, columna en bytes, longitud en bytes); longitud 0 = el identificador en esa posición.
Json Server::range(const std::string& path, int line1, int col1, int len) {
    int line0 = std::max(0, line1 - 1);
    std::string l = fileLine(path, line0);
    int start = std::max(0, col1 - 1);
    int end = start + len;
    if (len <= 0) {
        end = start;
        while (end < (int)l.size() && isIdentChar((unsigned char)l[end])) end++;
        if (end == start) end = std::min((int)l.size(), start + 1);
    }
    auto pos = [&](int b) {
        Json p = Json::object();
        p["line"] = line0;
        p["character"] = byteToUtf16(l, b);
        return p;
    };
    Json r = Json::object();
    r["start"] = pos(start);
    r["end"] = pos(end);
    return r;
}

void Server::refreshDiagnostics(const std::string& focus) {
    cache_ = analyze(focus, nullptr, nullptr);
    cacheValid_ = true;
    cacheFocus_ = focus;
    std::map<std::string, Json> byFile;
    for (const auto& p : cache_.get("analyzed").elements())
        if (docs_.count(p.asString())) byFile[p.asString()] = Json::array();
    for (const auto& d : cache_.get("diagnostics").elements()) {
        std::string path = d.get("path").asString();
        if (path.empty()) path = focus;  // error sin ubicación: se muestra en el documento actual
        Json diag = Json::object();
        diag["range"] = range(path, d.get("line").asInt(), d.get("col").asInt(), 0);
        diag["severity"] = d.get("severity").asInt();
        diag["source"] = "faset";
        diag["message"] = d.get("message").asString();
        Json& list = byFile[path];
        if (!list.isArray()) list = Json::array();
        list.push(std::move(diag));
    }
    std::set<std::string> now;
    for (auto& [path, list] : byFile) {
        Json p = Json::object();
        auto it = docs_.find(path);
        p["uri"] = it != docs_.end() ? it->second.uri : pathToUri(path);
        p["diagnostics"] = std::move(list);
        notify("textDocument/publishDiagnostics", std::move(p));
        now.insert(path);
    }
    for (const std::string& path : published_) {
        if (now.count(path)) continue;
        Json p = Json::object();
        auto it = docs_.find(path);
        p["uri"] = it != docs_.end() ? it->second.uri : pathToUri(path);
        p["diagnostics"] = Json::array();
        notify("textDocument/publishDiagnostics", std::move(p));
    }
    published_ = now;
}

const Json& Server::ensureCache(const std::string& focus) {
    if (!cacheValid_) refreshDiagnostics(focus);
    return cache_;
}

const Json* Server::refAt(const std::string& path, int line0, int ch) {
    const Json& c = ensureCache(path);
    std::string l = fileLine(path, line0);
    int col1 = utf16ToByte(l, ch) + 1;
    const Json* best = nullptr;
    for (const auto& r : c.get("refs").elements()) {
        if (r.get("path").asString() != path || r.get("line").asInt() != line0 + 1) continue;
        int start = r.get("col").asInt(), len = r.get("len").asInt();
        if (col1 >= start && col1 <= start + len) best = &r;  // el último registrado gana
    }
    return best;
}

Json Server::hover(const Json& params) {
    std::string path = uriToPath(params.get("textDocument").get("uri").asString());
    const Json& pos = params.get("position");
    const Json* r = refAt(path, pos.get("line").asInt(), pos.get("character").asInt());
    if (!r) return Json();
    Json h = Json::object();
    Json contents = Json::object();
    contents["kind"] = "markdown";
    if (r->get("doc").asBool()) contents["value"] = r->get("hover").asString();
    else contents["value"] = "```faset\n" + r->get("hover").asString() + "\n```";
    h["contents"] = std::move(contents);
    h["range"] = range(path, r->get("line").asInt(), r->get("col").asInt(), r->get("len").asInt());
    return h;
}

Json Server::definition(const Json& params) {
    std::string path = uriToPath(params.get("textDocument").get("uri").asString());
    const Json& pos = params.get("position");
    const Json* r = refAt(path, pos.get("line").asInt(), pos.get("character").asInt());
    if (!r || !r->has("defPath") || r->get("defPath").asString().empty()) return Json();
    std::string defPath = r->get("defPath").asString();
    Json loc = Json::object();
    auto it = docs_.find(defPath);
    loc["uri"] = it != docs_.end() ? it->second.uri : pathToUri(defPath);
    loc["range"] = range(defPath, r->get("defLine").asInt(), r->get("defCol").asInt(), 0);
    return loc;
}

Json Server::completion(const Json& params) {
    std::string path = uriToPath(params.get("textDocument").get("uri").asString());
    auto it = docs_.find(path);
    Json items = Json::array();
    if (it == docs_.end()) return items;
    const std::string& text = it->second.text;
    int line0 = params.get("position").get("line").asInt();
    std::string l = lineOf(text, line0);
    int byteCol = utf16ToByte(l, params.get("position").get("character").asInt());
    std::string trigger = params.get("context").get("triggerCharacter").asString();
    std::string before = l.substr(0, (size_t)byteCol);
    bool xml = xmlDocKind(path) != XmlDocKind::None;
    if (xml) {
        // En XML: '<', comillas, ',' y espacio (dentro de una etiqueta).
        if (trigger == "." || trigger == ":" || trigger == ">") return items;
        if (trigger == " " && before.rfind('<') == std::string::npos) return items;
        if (trigger == " " && before.rfind('>') != std::string::npos && before.rfind('>') > before.rfind('<')) return items;
    } else {
        if (trigger == "<" || trigger == "\"" || trigger == " " || trigger == ",") return items;
        // ':' y '>' solo cuentan como '::' y '->'.
        if (trigger == ":" && (before.size() < 2 || before.compare(before.size() - 2, 2, "::") != 0)) return items;
        if (trigger == ">" && (before.size() < 2 || before.compare(before.size() - 2, 2, "->") != 0)) return items;
    }

    Json result;
    // using / import: sugerir namespaces
    size_t k = before.find_first_not_of(" \t");
    std::string trimmed = k == std::string::npos ? "" : before.substr(k);
    if (!xml && (trimmed.rfind("using ", 0) == 0 || trimmed.rfind("import ", 0) == 0)) {
        std::string rest = trimmed.substr(trimmed.find(' ') + 1);
        if (rest.rfind("namespace ", 0) == 0) rest = rest.substr(10);
        if (rest.find('=') == std::string::npos && rest.find('"') == std::string::npos) {
            std::string norm;
            for (size_t i = 0; i < rest.size(); i++) {
                if (rest[i] == ':' && i + 1 < rest.size() && rest[i + 1] == ':') {
                    norm += '.';
                    i++;
                } else {
                    norm += rest[i];
                }
            }
            size_t lastDot = norm.rfind('.');
            Json nsPath = Json::array();
            if (lastDot != std::string::npos) {
                std::stringstream ss(norm.substr(0, lastDot));
                std::string part;
                while (std::getline(ss, part, '.'))
                    if (!part.empty()) nsPath.push(part);
            }
            result = analyze(path, nullptr, &nsPath);
        }
    }
    if (!result.isObject()) {
        size_t off = offsetOf(text, line0, byteCol);
        size_t start = off, end = off;
        while (start > 0 && isIdentChar((unsigned char)text[start - 1])) start--;
        while (end < text.size() && isIdentChar((unsigned char)text[end])) end++;
        std::map<std::string, std::string> ov;
        ov[path] = text.substr(0, start) + kCompletionMarker + text.substr(end);
        result = analyze(path, &ov, nullptr);
    }
    for (const auto& c : result.get("completions").elements()) {
        Json item = Json::object();
        item["label"] = c.get("label").asString();
        item["kind"] = c.get("kind").asInt();
        if (!c.get("detail").asString().empty()) item["detail"] = c.get("detail").asString();
        if (c.has("insert")) {
            // "$0" marca la posición del cursor: se envía como fragmento (snippet).
            item["insertText"] = c.get("insert").asString();
            item["insertTextFormat"] = 2;
        }
        // Los miembros del ámbito local aparecen antes que las palabras clave.
        item["sortText"] = (c.get("kind").asInt() == 14 ? "9" : "1") + c.get("label").asString();
        items.push(std::move(item));
    }
    return items;
}

Json Server::documentSymbols(const Json& params) {
    std::string path = uriToPath(params.get("textDocument").get("uri").asString());
    const Json& c = ensureCache(path);
    std::function<Json(const Json&)> convert = [&](const Json& s) {
        Json o = Json::object();
        o["name"] = s.get("name").asString().empty() ? "?" : s.get("name").asString();
        if (!s.get("detail").asString().empty()) o["detail"] = s.get("detail").asString();
        o["kind"] = s.get("kind").asInt();
        Json r = range(path, s.get("line").asInt(), s.get("col").asInt(), 0);
        o["range"] = r;
        o["selectionRange"] = r;
        if (s.has("children")) {
            Json ch = Json::array();
            for (const auto& x : s.get("children").elements()) ch.push(convert(x));
            o["children"] = std::move(ch);
        }
        return o;
    };
    Json out = Json::array();
    for (const auto& s : c.get("symbols").get(path).elements()) out.push(convert(s));
    return out;
}

void Server::handle(const Json& msg, std::set<std::string>& dirty) {
    const std::string& method = msg.get("method").asString();
    const Json& params = msg.get("params");
    bool isRequest = msg.has("id");
    const Json& id = msg.get("id");

    if (method == "initialize") {
        Json caps = Json::object();
        Json sync = Json::object();
        sync["openClose"] = true;
        sync["change"] = 1;  // documento completo
        Json save = Json::object();
        save["includeText"] = false;
        sync["save"] = std::move(save);
        caps["textDocumentSync"] = std::move(sync);
        Json comp = Json::object();
        Json triggers = Json::array();
        for (const char* t : {".", ":", ">", "<", "\"", " ", ","}) triggers.push(t);
        comp["triggerCharacters"] = std::move(triggers);
        caps["completionProvider"] = std::move(comp);
        caps["hoverProvider"] = true;
        caps["definitionProvider"] = true;
        caps["documentSymbolProvider"] = true;
        caps["documentFormattingProvider"] = true;  // faset fmt (Formatter.cpp)
        Json res = Json::object();
        res["capabilities"] = std::move(caps);
        Json info = Json::object();
        info["name"] = "faset";
        info["version"] = "0.4.0";
        res["serverInfo"] = std::move(info);
        reply(id, std::move(res));
        return;
    }
    if (method == "shutdown") {
        shutdown_ = true;
        reply(id, Json());
        return;
    }
    if (method == "exit") {
        // _Exit: el hilo lector puede estar bloqueado en stdin y exit() esperaría su cerrojo.
        std::fflush(stdout);
        std::_Exit(shutdown_ ? 0 : 1);
    }
    if (method == "textDocument/didOpen") {
        const Json& td = params.get("textDocument");
        std::string path = uriToPath(td.get("uri").asString());
        docs_[path] = {td.get("uri").asString(), td.get("text").asString()};
        dirty.insert(path);
        return;
    }
    if (method == "textDocument/didChange") {
        std::string path = uriToPath(params.get("textDocument").get("uri").asString());
        auto it = docs_.find(path);
        const Json& changes = params.get("contentChanges");
        if (it != docs_.end() && changes.size() > 0)
            it->second.text = changes.at(changes.size() - 1).get("text").asString();
        dirty.insert(path);
        return;
    }
    if (method == "textDocument/didSave") {
        dirty.insert(uriToPath(params.get("textDocument").get("uri").asString()));
        return;
    }
    if (method == "textDocument/didClose") {
        std::string path = uriToPath(params.get("textDocument").get("uri").asString());
        auto it = docs_.find(path);
        if (it != docs_.end()) {
            Json p = Json::object();
            p["uri"] = it->second.uri;
            p["diagnostics"] = Json::array();
            notify("textDocument/publishDiagnostics", std::move(p));
            published_.erase(path);
            docs_.erase(it);
        }
        cacheValid_ = false;
        return;
    }
    if (!isRequest) return;  // otras notificaciones: se ignoran

    // Antes de responder, aplica los cambios pendientes.
    if (!dirty.empty()) {
        cacheValid_ = false;
        dirty.clear();
    }
    if (method == "textDocument/hover") reply(id, hover(params));
    else if (method == "textDocument/definition") reply(id, definition(params));
    else if (method == "textDocument/completion") reply(id, completion(params));
    else if (method == "textDocument/documentSymbol") reply(id, documentSymbols(params));
    else if (method == "textDocument/formatting") {
        auto it = docs_.find(uriToPath(params.get("textDocument").get("uri").asString()));
        reply(id, it != docs_.end() ? formattingEdits(it->second.text) : Json::array());
    }
    else replyError(id, -32601, "método no soportado: " + method);
}

int Server::run() {
#if defined(_WIN32)
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    std::thread reader(&Server::readerLoop, this);
    reader.detach();
    for (;;) {
        std::deque<Json> batch;
        {
            std::unique_lock<std::mutex> lk(qMutex_);
            qCv_.wait(lk, [&] { return !queue_.empty() || eof_; });
            if (queue_.empty() && eof_) return 0;
            batch.swap(queue_);
        }
        // Se procesan juntos todos los mensajes acumulados: si se escribe rápido,
        // solo se analiza una vez con el texto más reciente.
        std::set<std::string> dirty;
        for (const Json& msg : batch) handle(msg, dirty);
        if (!dirty.empty()) {
            std::string focus = *dirty.rbegin();
            cacheValid_ = false;
            if (docs_.count(focus)) refreshDiagnostics(focus);
        }
    }
}

}  // namespace

int runLanguageServer(const std::string& argv0) {
    Server s(argv0);
    return s.run();
}
