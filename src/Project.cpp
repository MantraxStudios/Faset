#include "Project.h"
#include "Packages.h"
#include "Xml.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <fstream>
#include <functional>
#include <regex>
#include <sstream>

namespace fs = std::filesystem;

namespace {

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
        error = "cannot read '" + path + "'";
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    std::string src = ss.str();
    XmlNode root;
    std::string xmlError;
    if (!parseXml(src, root, xmlError)) {
        error = path + ": invalid XML: " + xmlError;
        return false;
    }
    if (root.name != "Project") {
        error = path + ": the root element must be <Project>";
        return false;
    }
    out.path = fs::absolute(path).lexically_normal().string();
    out.dir = fs::path(out.path).parent_path().string();
    static const std::vector<std::string> known = {
        "OutputType", "AssemblyName", "RootNamespace", "TargetPlatform", "TargetArch", "AndroidApi",
        "Configuration", "OutputPath", "StaticLink", "EnableDefaultCompileItems", "Version", "Description",
        "Authors", "Optimize",
        // Paquetes (ver src/Packages.h)
        "PackageId", "License", "RepositoryUrl", "PackageIndex", "DebugSymbols", "RuntimeChecks", "AllowUnsafe",
        // Pruebas (ver src/TestRunner.h)
        "IsTestProject",
        // Android (APK)
        "AndroidPackage", "AppName", "VersionCode", "VersionName", "AndroidAbis", "AndroidTargetSdk", "AndroidIcon",
        "AndroidOrientation", "AndroidKeystore", "AndroidKeyAlias", "AndroidKeystorePassword", "AndroidKeyPassword"};
    for (XmlNode& g : root.children) {
        if (g.name == "PropertyGroup") {
            for (XmlNode& p : g.children) {
                if (std::find(known.begin(), known.end(), p.name) == known.end()) {
                    error = path + ": unknown property <" + p.name + ">";
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
                    std::string platform = it.attrs["Platform"];
                    std::transform(platform.begin(), platform.end(), platform.begin(), ::tolower);
                    if (platform.empty()) out.nativeLibs.insert(out.nativeLibs.end(), inc.begin(), inc.end());
                    else
                        for (auto& l : inc) out.platformLibs.push_back({l, platform});
                } else if (it.name == "NativeSource") {
                    // Fuentes C propias del proyecto (opcionalmente solo para una plataforma).
                    std::string platform = it.attrs["Platform"];
                    std::transform(platform.begin(), platform.end(), platform.begin(), ::tolower);
                    for (auto& f : inc)
                        out.nativeSources.push_back({(fs::path(out.dir) / f).lexically_normal().string(), platform});
                } else if (it.name == "LibraryPath") {
                    for (auto& d : inc) out.libPaths.push_back((fs::path(out.dir) / d).lexically_normal().string());
                } else if (it.name == "AndroidPermission") {
                    out.androidPermissions.insert(out.androidPermissions.end(), inc.begin(), inc.end());
                } else if (it.name == "Asset") {
                    out.assetInclude.insert(out.assetInclude.end(), inc.begin(), inc.end());
                    out.assetRemove.insert(out.assetRemove.end(), rem.begin(), rem.end());
                } else if (it.name == "PackageReference") {
                    PackageRef pr;
                    pr.name = it.attrs["Include"];
                    pr.version = it.attrs["Version"];
                    pr.git = it.attrs["Git"];
                    pr.branch = it.attrs["Branch"];
                    pr.commit = it.attrs["Commit"];
                    pr.path = it.attrs["Path"];
                    pr.folder = it.attrs["Folder"];
                    pr.line = it.line;
                    std::string where = path + ":" + std::to_string(it.line) + ": <PackageReference Include=\"" + pr.name + "\">: ";
                    static const std::vector<std::string> attrs = {"Include", "Version", "Git", "Branch", "Commit", "Path", "Folder"};
                    for (const std::string& a : it.attrOrder)
                        if (std::find(attrs.begin(), attrs.end(), a) == attrs.end()) {
                            error = where + "unknown attribute '" + a + "'";
                            return false;
                        }
                    if (pr.name.empty() || pr.name.find(';') != std::string::npos) {
                        error = where + "Include must be a package name";
                        return false;
                    }
                    if (!pr.git.empty() && !pr.path.empty()) {
                        error = where + "Git and Path cannot be used together";
                        return false;
                    }
                    if (!pr.branch.empty() && !pr.commit.empty()) {
                        error = where + "Branch and Commit cannot be used together";
                        return false;
                    }
                    if (!pr.path.empty() && (!pr.branch.empty() || !pr.commit.empty())) {
                        error = where + "Branch and Commit are only valid for git packages";
                        return false;
                    }
                    out.packages.push_back(pr);
                } else if (it.name == "ProjectReference") {
                    for (auto& r : inc) out.references.push_back((fs::path(out.dir) / r).lexically_normal().string());
                } else {
                    error = path + ": unknown element <" + it.name + "> in <ItemGroup>";
                    return false;
                }
            }
        } else {
            error = path + ": unknown element <" + g.name + "> (expected PropertyGroup or ItemGroup)";
            return false;
        }
    }
    std::string ot = out.prop("OutputType", "Exe");
    if (ot != "Exe" && ot != "WinExe" && ot != "Library") {
        error = path + ": <OutputType> must be Exe, WinExe or Library (not '" + ot + "')";
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
            if (f.extension() == ".fst" || f.extension() == ".fstui") files.push_back(fs::relative(f, root).generic_string());
        }
    }
    for (const std::string& inc : p.compileInclude) {
        if (inc.find('*') == std::string::npos) {
            files.push_back(norm(inc));
            continue;
        }
        for (auto it = fs::recursive_directory_iterator(root, ec); it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec) break;
            if (it->is_regular_file() && (it->path().extension() == ".fst" || it->path().extension() == ".fstui")) {
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

std::vector<std::pair<std::string, std::string>> projectAssets(const Project& p) {
    std::vector<std::pair<std::string, std::string>> out;
    std::error_code ec;
    fs::path root(p.dir);
    auto add = [&](const std::string& rel) {
        for (const std::string& r : p.assetRemove)
            if (globMatch(r, rel)) return;
        for (const auto& a : out)
            if (a.first == rel) return;
        out.push_back({rel, (root / rel).lexically_normal().string()});
    };
    // Recorre la carpeta del proyecto sin entrar en bin/, obj/ ni carpetas ocultas.
    auto walk = [&](const fs::path& dir, const std::function<void(const std::string&)>& fn) {
        auto it = fs::recursive_directory_iterator(dir, fs::directory_options::skip_permission_denied, ec);
        for (; it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec) break;
            std::string name = it->path().filename().string();
            if (it->is_directory(ec)) {
                if (name == "bin" || name == "obj" || (!name.empty() && name[0] == '.')) it.disable_recursion_pending();
                continue;
            }
            if (it->is_regular_file(ec)) fn(fs::relative(it->path(), root).generic_string());
        }
    };
    for (const std::string& raw : p.assetInclude) {
        std::string inc = norm(raw);
        if (inc.find('*') != std::string::npos || inc.find('?') != std::string::npos) {
            walk(root, [&](const std::string& rel) {
                if (globMatch(inc, rel)) add(rel);
            });
        } else if (fs::is_directory(root / inc, ec)) {
            walk(root / inc, [&](const std::string& rel) { add(rel); });
        } else {
            add(fs::path(inc).lexically_normal().generic_string());
        }
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
        // Paquetes ya restaurados (paquetes.lock + caché, sin red): su código cuenta como el de
        // una referencia más, así el IntelliSense y "ir a la definición" llegan a sus fuentes.
        if (visited.size() == 1)
            for (const std::string& pkg : lockedPackageProjects(p)) proj.references.push_back(pkg);
        for (const std::string& ref : proj.references)
            if (fs::exists(ref) && !visit(ref)) return false;
        for (const std::string& f : projectSources(proj))
            if (std::find(files.begin(), files.end(), f) == files.end()) files.push_back(f);
        return true;
    };
    return visit(projPath);
}

bool projectAllowsUnsafe(const std::string& file) {
    static std::map<std::string, bool> cache;
    std::string proj = findProjectFor(file);
    if (proj.empty()) return false;
    auto it = cache.find(proj);
    if (it != cache.end()) return it->second;
    Project p;
    std::string err;
    bool allow = loadProject(proj, p, err) && p.boolProp("AllowUnsafe", false);
    cache[proj] = allow;
    return allow;
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
           "  <!-- All .fst files in this folder are compiled automatically.\n"
           "  <ItemGroup>\n"
           "    <Compile Remove=\"experiments/**\" />\n"
           "    <NativeLibrary Include=\"user32\" />\n"
           "    <ProjectReference Include=\"../OtherLibrary/OtherLibrary.fstproj\" />\n"
           "  </ItemGroup>\n"
           "  -->\n"
           "</Project>\n";
}
