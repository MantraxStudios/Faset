#include "Solution.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <sstream>

#include "Project.h"
#include "Xml.h"

namespace fs = std::filesystem;

namespace {

std::string lowerCase(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), ::tolower);
    return s;
}

std::string escapeAttr(const std::string& v) {
    std::string r;
    for (char c : v) {
        if (c == '&') r += "&amp;";
        else if (c == '<') r += "&lt;";
        else if (c == '>') r += "&gt;";
        else if (c == '"') r += "&quot;";
        else r += c;
    }
    return r;
}

std::string canonical(const std::string& p) {
    std::error_code ec;
    return fs::weakly_canonical(fs::absolute(p, ec), ec).lexically_normal().string();
}

}  // namespace

std::string relativeSlash(const std::string& path, const std::string& base) {
    std::error_code ec;
    fs::path rel = fs::path(canonical(path)).lexically_relative(canonical(base));
    if (rel.empty()) return fs::path(path).generic_string();
    return rel.generic_string();
}

int Solution::startup() const {
    for (size_t i = 0; i < projects.size(); i++)
        if (projects[i].startup) return (int)i;
    return -1;
}

int Solution::find(const std::string& projectPath) const {
    std::error_code ec;
    // Ruta tal cual (desde la carpeta actual) o relativa a la solución.
    std::vector<std::string> cands = {canonical(projectPath), canonical((fs::path(dir) / projectPath).string())};
    // Una carpeta: su .fstproj.
    for (size_t k = 0, n = cands.size(); k < n; k++)
        if (fs::is_directory(cands[k], ec)) {
            std::string p = findProjectFor((fs::path(cands[k]) / "x").string());
            if (!p.empty()) cands.push_back(canonical(p));
        }
    for (size_t i = 0; i < projects.size(); i++)
        for (const std::string& c : cands)
            if (canonical(projects[i].path) == c) return (int)i;
    // Por nombre (sin extensión).
    for (size_t i = 0; i < projects.size(); i++)
        if (fs::path(projects[i].path).stem().string() == projectPath) return (int)i;
    return -1;
}

bool loadSolution(const std::string& path, Solution& out, std::string& error) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        error = "no se puede leer '" + path + "'";
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    XmlNode root;
    std::string xmlError;
    if (!parseXml(ss.str(), root, xmlError)) {
        error = path + ": XML no válido: " + xmlError;
        return false;
    }
    if (root.name != "Solution") {
        error = path + ": el elemento raíz debe ser <Solution>";
        return false;
    }
    out = Solution();
    out.path = fs::absolute(path).lexically_normal().string();
    out.dir = fs::path(out.path).parent_path().string();
    for (const std::string& a : root.attrOrder) {
        if (a != "Name" && a != "Configuration" && a != "TargetPlatform") {
            error = path + ": atributo desconocido '" + a + "' en <Solution> (válidos: Name, Configuration, TargetPlatform)";
            return false;
        }
    }
    auto attr = [](const XmlNode& n, const char* k) {
        auto it = n.attrs.find(k);
        return it == n.attrs.end() ? std::string() : it->second;
    };
    out.name = attr(root, "Name");
    if (out.name.empty()) out.name = fs::path(out.path).stem().string();
    out.configuration = attr(root, "Configuration");
    out.targetPlatform = attr(root, "TargetPlatform");
    if (!out.configuration.empty() && out.configuration != "Debug" && out.configuration != "Release") {
        error = path + ": Configuration debe ser Debug o Release (no '" + out.configuration + "')";
        return false;
    }
    int startups = 0;
    std::function<bool(const XmlNode&, const std::string&)> walk = [&](const XmlNode& n, const std::string& folder) -> bool {
        for (const XmlNode& c : n.children) {
            if (c.name == "Project") {
                SolutionProject p;
                p.rel = attr(c, "Path");
                std::replace(p.rel.begin(), p.rel.end(), '\\', '/');
                if (p.rel.empty()) {
                    error = path + ":" + std::to_string(c.line) + ": <Project> necesita el atributo Path";
                    return false;
                }
                p.path = (fs::path(out.dir) / p.rel).lexically_normal().string();
                p.folder = folder;
                std::string st = lowerCase(attr(c, "Startup"));
                p.startup = st == "true" || st == "1" || st == "yes";
                if (p.startup) startups++;
                for (const auto& sp : out.projects)
                    if (canonical(sp.path) == canonical(p.path)) {
                        error = path + ":" + std::to_string(c.line) + ": el proyecto '" + p.rel + "' está repetido";
                        return false;
                    }
                out.projects.push_back(p);
            } else if (c.name == "Folder") {
                std::string name = attr(c, "Name");
                if (name.empty() || name.find('/') != std::string::npos) {
                    error = path + ":" + std::to_string(c.line) + ": <Folder> necesita un Name sin '/'";
                    return false;
                }
                std::string full = folder.empty() ? name : folder + "/" + name;
                if (std::find(out.folders.begin(), out.folders.end(), full) == out.folders.end()) out.folders.push_back(full);
                if (!walk(c, full)) return false;
            } else {
                error = path + ":" + std::to_string(c.line) + ": elemento desconocido <" + c.name + "> (se esperaba Project o Folder)";
                return false;
            }
        }
        return true;
    };
    if (!walk(root, "")) return false;
    if (startups > 1) {
        error = path + ": solo un proyecto puede tener Startup=\"true\"";
        return false;
    }
    return true;
}

std::string solutionXml(const Solution& s) {
    std::string x = "<Solution Name=\"" + escapeAttr(s.name) + "\"";
    if (!s.configuration.empty()) x += " Configuration=\"" + escapeAttr(s.configuration) + "\"";
    if (!s.targetPlatform.empty()) x += " TargetPlatform=\"" + escapeAttr(s.targetPlatform) + "\"";
    x += ">\n";
    // Proyectos de cada carpeta y después sus subcarpetas, en el orden en que se declararon.
    std::function<void(const std::string&, int)> emit = [&](const std::string& folder, int depth) {
        std::string pad((size_t)(depth + 1) * 2, ' ');
        for (const SolutionProject& p : s.projects) {
            if (p.folder != folder) continue;
            x += pad + "<Project Path=\"" + escapeAttr(p.rel) + "\"" + (p.startup ? " Startup=\"true\"" : "") + " />\n";
        }
        for (const std::string& f : s.folders) {
            size_t slash = f.rfind('/');
            std::string parent = slash == std::string::npos ? "" : f.substr(0, slash);
            if (parent != folder) continue;
            x += pad + "<Folder Name=\"" + escapeAttr(f.substr(slash == std::string::npos ? 0 : slash + 1)) + "\">\n";
            emit(f, depth + 1);
            x += pad + "</Folder>\n";
        }
    };
    emit("", 0);
    x += "</Solution>\n";
    return x;
}

bool saveSolution(const Solution& s, std::string& error) {
    std::ofstream f(s.path, std::ios::binary);
    if (!f) {
        error = "no se puede escribir '" + s.path + "'";
        return false;
    }
    f << solutionXml(s);
    if (!f) {
        error = "no se pudo guardar '" + s.path + "'";
        return false;
    }
    return true;
}

bool solutionBuildOrder(const Solution& s, std::vector<int>& order, std::string& error, std::vector<std::vector<int>>* depsOut) {
    order.clear();
    std::map<std::string, int> index;
    for (size_t i = 0; i < s.projects.size(); i++) index[canonical(s.projects[i].path)] = (int)i;
    // Dependencias dentro de la solución (también a través de proyectos que no están en ella).
    std::vector<std::vector<int>> deps(s.projects.size());
    for (size_t i = 0; i < s.projects.size(); i++) {
        std::vector<std::string> seen;
        std::function<void(const std::string&)> visit = [&](const std::string& p) {
            Project proj;
            std::string err;
            if (!loadProject(p, proj, err)) return;
            for (const std::string& ref : proj.references) {
                std::string key = canonical(ref);
                if (std::find(seen.begin(), seen.end(), key) != seen.end()) continue;
                seen.push_back(key);
                auto it = index.find(key);
                if (it != index.end()) deps[i].push_back(it->second);
                else visit(ref);
            }
        };
        visit(s.projects[i].path);
    }
    if (depsOut) *depsOut = deps;
    std::vector<int> state(s.projects.size(), 0);  // 0 sin visitar, 1 en curso, 2 hecho
    std::function<bool(int)> dfs = [&](int i) -> bool {
        if (state[i] == 2) return true;
        if (state[i] == 1) {
            error = "referencia circular entre proyectos: " + s.projects[i].rel;
            return false;
        }
        state[i] = 1;
        for (int d : deps[i])
            if (!dfs(d)) return false;
        state[i] = 2;
        order.push_back(i);
        return true;
    };
    for (size_t i = 0; i < s.projects.size(); i++)
        if (!dfs((int)i)) return false;
    return true;
}

int solutionStartupProject(const Solution& s) {
    int st = s.startup();
    if (st >= 0) return st;
    for (size_t i = 0; i < s.projects.size(); i++) {
        Project p;
        std::string err;
        if (loadProject(s.projects[i].path, p, err) && p.prop("OutputType", "Exe") != "Library") return (int)i;
    }
    return -1;
}

std::string findSolutionIn(const std::string& dir) {
    std::error_code ec;
    std::vector<std::string> found;
    for (auto& e : fs::directory_iterator(dir, ec))
        if (e.path().extension() == ".fstp" && e.is_regular_file(ec)) found.push_back(e.path().string());
    return found.size() == 1 ? found[0] : "";
}

namespace {

bool projectContains(const std::string& projPath, const std::string& file) {
    Project p;
    std::string err;
    if (!loadProject(projPath, p, err)) return false;
    std::string target = canonical(file);
    for (const std::string& f : projectSources(p))
        if (canonical(f) == target) return true;
    return false;
}

int projectsInDir(const fs::path& dir) {
    std::error_code ec;
    int n = 0;
    for (auto& e : fs::directory_iterator(dir, ec))
        if (e.path().extension() == ".fstproj") n++;
    return n;
}

}  // namespace

std::string findSolutionFor(const std::string& file) {
    std::error_code ec;
    fs::path dir = fs::absolute(file, ec).parent_path();
    for (int depth = 0; depth < 16 && !dir.empty(); depth++) {
        std::string s = findSolutionIn(dir.string());
        if (!s.empty()) return s;
        if (dir == dir.parent_path()) break;
        dir = dir.parent_path();
    }
    return "";
}

std::string projectForFile(const std::string& file, const std::string& solutionHint) {
    std::string nearest = findProjectFor(file);
    // Lo normal: el .fstproj más cercano compila el archivo y está solo en su carpeta.
    if (!nearest.empty() && projectsInDir(fs::path(nearest).parent_path()) <= 1 && projectContains(nearest, file)) return nearest;
    std::string sln = !solutionHint.empty() ? solutionHint : findSolutionFor(file);
    Solution s;
    std::string err;
    if (!sln.empty() && loadSolution(sln, s, err)) {
        // El proyecto de la solución que compila el archivo (el de carpeta más profunda si hay varios).
        std::string best;
        for (const SolutionProject& p : s.projects)
            if (p.path.size() > best.size() && projectContains(p.path, file)) best = p.path;
        if (!best.empty()) return best;
    }
    return nearest;
}
