#include "Project.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <functional>
#include <regex>
#include <sstream>

namespace fs = std::filesystem;

namespace {

// ---- XML mínimo: elementos, atributos, texto y comentarios.

struct XmlNode {
    std::string name, text;
    std::map<std::string, std::string> attrs;
    std::vector<XmlNode> children;
};

struct XmlParser {
    const std::string& s;
    size_t i = 0;
    std::string error;

    explicit XmlParser(const std::string& src) : s(src) {}

    int lineAt(size_t pos) const { return 1 + (int)std::count(s.begin(), s.begin() + (long)std::min(pos, s.size()), '\n'); }
    bool fail(const std::string& msg) {
        if (error.empty()) error = "línea " + std::to_string(lineAt(i)) + ": " + msg;
        return false;
    }
    void skipWs() {
        for (;;) {
            while (i < s.size() && isspace((unsigned char)s[i])) i++;
            if (s.compare(i, 4, "<!--") == 0) {
                size_t e = s.find("-->", i);
                i = e == std::string::npos ? s.size() : e + 3;
            } else if (s.compare(i, 2, "<?") == 0) {
                size_t e = s.find("?>", i);
                i = e == std::string::npos ? s.size() : e + 2;
            } else {
                return;
            }
        }
    }
    static std::string unescape(const std::string& v) {
        std::string r;
        for (size_t k = 0; k < v.size(); k++) {
            if (v[k] == '&') {
                size_t e = v.find(';', k);
                if (e != std::string::npos) {
                    std::string ent = v.substr(k + 1, e - k - 1);
                    if (ent == "lt") r += '<';
                    else if (ent == "gt") r += '>';
                    else if (ent == "amp") r += '&';
                    else if (ent == "quot") r += '"';
                    else if (ent == "apos") r += '\'';
                    else r += "&" + ent + ";";
                    k = e;
                    continue;
                }
            }
            r += v[k];
        }
        return r;
    }
    std::string name() {
        size_t b = i;
        while (i < s.size() && (isalnum((unsigned char)s[i]) || s[i] == '_' || s[i] == '-' || s[i] == '.' || s[i] == ':')) i++;
        return s.substr(b, i - b);
    }
    bool element(XmlNode& n) {
        skipWs();
        if (i >= s.size() || s[i] != '<') return fail("se esperaba '<'");
        i++;
        n.name = name();
        if (n.name.empty()) return fail("nombre de elemento vacío");
        for (;;) {
            skipWs();
            if (i >= s.size()) return fail("fin de archivo dentro de <" + n.name + ">");
            if (s.compare(i, 2, "/>") == 0) {
                i += 2;
                return true;
            }
            if (s[i] == '>') {
                i++;
                break;
            }
            std::string a = name();
            if (a.empty()) return fail("atributo mal formado en <" + n.name + ">");
            skipWs();
            if (i >= s.size() || s[i] != '=') return fail("se esperaba '=' en el atributo '" + a + "'");
            i++;
            skipWs();
            if (i >= s.size() || (s[i] != '"' && s[i] != '\'')) return fail("se esperaban comillas en '" + a + "'");
            char q = s[i++];
            size_t e = s.find(q, i);
            if (e == std::string::npos) return fail("atributo sin cerrar");
            n.attrs[a] = unescape(s.substr(i, e - i));
            i = e + 1;
        }
        for (;;) {
            size_t b = i;
            while (i < s.size() && s[i] != '<') i++;
            n.text += s.substr(b, i - b);
            if (s.compare(i, 4, "<!--") == 0) {
                skipWs();
                continue;
            }
            if (i >= s.size()) return fail("falta </" + n.name + ">");
            if (s.compare(i, 2, "</") == 0) {
                i += 2;
                std::string close = name();
                skipWs();
                if (close != n.name) return fail("se esperaba </" + n.name + "> pero se encontró </" + close + ">");
                if (i >= s.size() || s[i] != '>') return fail("se esperaba '>'");
                i++;
                n.text = unescape(n.text);
                size_t a = n.text.find_first_not_of(" \t\r\n"), z = n.text.find_last_not_of(" \t\r\n");
                n.text = a == std::string::npos ? "" : n.text.substr(a, z - a + 1);
                return true;
            }
            XmlNode child;
            if (!element(child)) return false;
            n.children.push_back(std::move(child));
        }
    }
};

std::vector<std::string> splitList(const std::string& v) {
    std::vector<std::string> out;
    std::stringstream ss(v);
    std::string item;
    while (std::getline(ss, item, ';')) {
        size_t a = item.find_first_not_of(" \t\r\n"), z = item.find_last_not_of(" \t\r\n");
        if (a != std::string::npos) out.push_back(item.substr(a, z - a + 1));
    }
    return out;
}

std::string norm(const std::string& p) {
    std::string r = p;
    std::replace(r.begin(), r.end(), '\\', '/');
    while (r.rfind("./", 0) == 0) r = r.substr(2);
    return r;
}

// Patrón tipo MSBuild: '**' = cualquier ruta, '*' = cualquier nombre, '?' = un carácter.
bool globMatch(const std::string& pattern, const std::string& path) {
    std::string re;
    std::string p = norm(pattern);
    for (size_t k = 0; k < p.size(); k++) {
        char c = p[k];
        if (c == '*' && k + 1 < p.size() && p[k + 1] == '*') {
            re += ".*";
            k++;
            if (k + 1 < p.size() && p[k + 1] == '/') k++;
        } else if (c == '*') {
            re += "[^/]*";
        } else if (c == '?') {
            re += "[^/]";
        } else if (std::string(".+()^$|{}[]\\").find(c) != std::string::npos) {
            re += '\\';
            re += c;
        } else {
            re += c;
        }
    }
    return std::regex_match(norm(path), std::regex(re));
}

}  // namespace

std::string Project::prop(const std::string& name, const std::string& def) const {
    auto it = props.find(name);
    return it == props.end() || it->second.empty() ? def : it->second;
}

bool Project::boolProp(const std::string& name, bool def) const {
    std::string v = prop(name);
    if (v.empty()) return def;
    std::transform(v.begin(), v.end(), v.begin(), ::tolower);
    return v == "true" || v == "1" || v == "yes";
}

bool loadProject(const std::string& path, Project& out, std::string& error) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        error = "no se puede leer '" + path + "'";
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    std::string src = ss.str();
    XmlParser xp(src);
    XmlNode root;
    if (!xp.element(root)) {
        error = path + ": XML no válido: " + xp.error;
        return false;
    }
    if (root.name != "Project") {
        error = path + ": el elemento raíz debe ser <Project>";
        return false;
    }
    out.path = fs::absolute(path).lexically_normal().string();
    out.dir = fs::path(out.path).parent_path().string();
    static const std::vector<std::string> known = {
        "OutputType", "AssemblyName", "RootNamespace", "TargetPlatform", "TargetArch", "AndroidApi",
        "Configuration", "OutputPath", "StaticLink", "EnableDefaultCompileItems", "Version", "Description",
        "Authors", "Optimize", "DebugSymbols"};
    for (XmlNode& g : root.children) {
        if (g.name == "PropertyGroup") {
            for (XmlNode& p : g.children) {
                if (std::find(known.begin(), known.end(), p.name) == known.end()) {
                    error = path + ": propiedad desconocida <" + p.name + ">";
                    return false;
                }
                out.props[p.name] = p.text;
            }
        } else if (g.name == "ItemGroup") {
            for (XmlNode& it : g.children) {
                auto inc = splitList(it.attrs["Include"]);
                auto rem = splitList(it.attrs["Remove"]);
                if (it.name == "Compile") {
                    out.compileInclude.insert(out.compileInclude.end(), inc.begin(), inc.end());
                    out.compileRemove.insert(out.compileRemove.end(), rem.begin(), rem.end());
                } else if (it.name == "NativeLibrary") {
                    out.nativeLibs.insert(out.nativeLibs.end(), inc.begin(), inc.end());
                } else if (it.name == "LibraryPath") {
                    for (auto& d : inc) out.libPaths.push_back((fs::path(out.dir) / d).lexically_normal().string());
                } else if (it.name == "ProjectReference") {
                    for (auto& r : inc) out.references.push_back((fs::path(out.dir) / r).lexically_normal().string());
                } else {
                    error = path + ": elemento desconocido <" + it.name + "> en <ItemGroup>";
                    return false;
                }
            }
        } else {
            error = path + ": elemento desconocido <" + g.name + "> (se esperaba PropertyGroup o ItemGroup)";
            return false;
        }
    }
    std::string ot = out.prop("OutputType", "Exe");
    if (ot != "Exe" && ot != "WinExe" && ot != "Library") {
        error = path + ": <OutputType> debe ser Exe, WinExe o Library (no '" + ot + "')";
        return false;
    }
    return true;
}

std::vector<std::string> projectSources(const Project& p) {
    std::vector<std::string> files;
    std::error_code ec;
    fs::path root(p.dir);
    if (p.boolProp("EnableDefaultCompileItems", true)) {
        auto it = fs::recursive_directory_iterator(root, fs::directory_options::skip_permission_denied, ec);
        for (; it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec) break;
            const fs::path& f = it->path();
            std::string name = f.filename().string();
            if (it->is_directory()) {
                bool otherProject = false;
                for (auto& e : fs::directory_iterator(f, ec))
                    if (e.path().extension() == ".fstproj") otherProject = true;
                if (name == "bin" || name == "obj" || (!name.empty() && name[0] == '.') || otherProject)
                    it.disable_recursion_pending();
                continue;
            }
            if (f.extension() == ".fst") files.push_back(fs::relative(f, root).generic_string());
        }
    }
    for (const std::string& inc : p.compileInclude) {
        if (inc.find('*') == std::string::npos) {
            files.push_back(norm(inc));
            continue;
        }
        for (auto it = fs::recursive_directory_iterator(root, ec); it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec) break;
            if (it->is_regular_file() && it->path().extension() == ".fst") {
                std::string rel = fs::relative(it->path(), root).generic_string();
                if (globMatch(inc, rel)) files.push_back(rel);
            }
        }
    }
    std::vector<std::string> out;
    for (const std::string& rel : files) {
        bool removed = false;
        for (const std::string& r : p.compileRemove) removed |= globMatch(r, rel);
        std::string full = (root / rel).lexically_normal().string();
        if (!removed && std::find(out.begin(), out.end(), full) == out.end()) out.push_back(full);
    }
    std::sort(out.begin(), out.end());
    return out;
}

std::string findProjectFor(const std::string& file) {
    std::error_code ec;
    fs::path dir = fs::absolute(file, ec).parent_path();
    for (int depth = 0; depth < 64 && !dir.empty(); depth++) {
        for (auto& e : fs::directory_iterator(dir, ec))
            if (e.path().extension() == ".fstproj") return e.path().string();
        if (dir == dir.parent_path()) break;
        dir = dir.parent_path();
    }
    return "";
}

bool projectTreeSources(const std::string& projPath, std::vector<std::string>& files, std::string& error) {
    std::vector<std::string> visited;
    std::function<bool(const std::string&)> visit = [&](const std::string& p) -> bool {
        std::string key = fs::weakly_canonical(p).string();
        if (std::find(visited.begin(), visited.end(), key) != visited.end()) return true;
        visited.push_back(key);
        Project proj;
        if (!loadProject(p, proj, error)) return false;
        for (const std::string& ref : proj.references)
            if (fs::exists(ref) && !visit(ref)) return false;
        for (const std::string& f : projectSources(proj))
            if (std::find(files.begin(), files.end(), f) == files.end()) files.push_back(f);
        return true;
    };
    return visit(projPath);
}

std::string newProjectXml(const std::string& name, const std::string& outputType) {
    return "<Project>\n"
           "  <PropertyGroup>\n"
           "    <OutputType>" + outputType + "</OutputType>\n"
           "    <AssemblyName>" + name + "</AssemblyName>\n"
           "    <RootNamespace>" + name + "</RootNamespace>\n"
           "    <TargetPlatform>native</TargetPlatform>\n"
           "    <Configuration>Debug</Configuration>\n"
           "  </PropertyGroup>\n"
           "\n"
           "  <!-- Todos los .fst de esta carpeta se compilan automáticamente.\n"
           "  <ItemGroup>\n"
           "    <Compile Remove=\"experimentos/**\" />\n"
           "    <NativeLibrary Include=\"user32\" />\n"
           "    <ProjectReference Include=\"../OtraBiblioteca/OtraBiblioteca.fstproj\" />\n"
           "  </ItemGroup>\n"
           "  -->\n"
           "</Project>\n";
}
