// Faset - órdenes de soluciones (.fstp) de la línea de órdenes.
//
//   faset build|run|check|clean MiJuego.fstp   todos los proyectos en orden de dependencias;
//                                              'run' ejecuta el proyecto de inicio
//   faset new sln [Nombre]                     crea una solución (sin nombre: en la carpeta actual,
//                                              con los .fstproj que encuentre)
//   faset new Nombre --solution [plantilla]    solución + proyecto (Nombre/Nombre.fstp y Nombre/Nombre/)
//   faset sln [x.fstp] add|remove|list|startup|folder|move|rename|ref ...
//
// Cada proyecto se compila con el propio 'faset' en un subproceso, igual que si se escribiera
// 'faset build proyecto.fstproj' a mano: así la salida y los errores son los de siempre.
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <set>
#include <sstream>
#if !defined(_WIN32)
#include <sys/wait.h>
#endif

#include "Frontend.h"
#include "Json.h"
#include "Project.h"
#include "Solution.h"

namespace fs = std::filesystem;

namespace {

void fail(const std::string& msg) { std::fprintf(stderr, "faset: error: %s\n", msg.c_str()); }

std::string quoteArg(const std::string& s) {
#if defined(_WIN32)
    return windowsQuote(s);
#else
    std::string r = "'";
    for (char c : s) r += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return r + "'";
#endif
}

int runSelf(const std::string& self, const std::vector<std::string>& args, bool verbose) {
    std::string cmd = quoteArg(self);
    for (const std::string& a : args) cmd += " " + quoteArg(a);
    if (verbose) std::fprintf(stderr, "$ %s\n", cmd.c_str());
#if defined(_WIN32)
    std::vector<std::string> all = {self};
    all.insert(all.end(), args.begin(), args.end());
    return runProgramWindows(all);
#else
    std::fflush(stdout);
    std::fflush(stderr);
    int r = std::system(cmd.c_str());
    if (r != -1 && WIFEXITED(r)) r = WEXITSTATUS(r);
    else if (r != -1) r = 1;
    return r;
#endif
}

bool hasExt(const std::string& p, const char* ext) { return fs::path(p).extension() == ext; }

bool hasProjectIn(const fs::path& dir) {
    std::error_code ec;
    for (auto& e : fs::directory_iterator(dir, ec))
        if (e.path().extension() == ".fstproj") return true;
    return false;
}

// El .fstproj de una carpeta (o la propia ruta si ya es un archivo).
std::string projectFileOf(const std::string& p) {
    std::error_code ec;
    if (!fs::is_directory(p, ec)) return p;
    std::vector<std::string> found;
    for (auto& e : fs::directory_iterator(p, ec))
        if (e.path().extension() == ".fstproj") found.push_back(e.path().string());
    return found.size() == 1 ? found[0] : p;
}

std::string projectName(const SolutionProject& p) { return fs::path(p.path).stem().string(); }

std::string outputTypeOf(const std::string& path) {
    Project p;
    std::string err;
    return loadProject(path, p, err) ? p.prop("OutputType", "Exe") : "";
}

// Busca la solución: el .fstp indicado o el único de la carpeta actual.
bool locate(const std::string& given, std::string& path) {
    if (!given.empty()) {
        path = given;
        if (!fs::exists(path)) {
            fail("no existe la solución '" + given + "'");
            return false;
        }
        return true;
    }
    std::error_code ec;
    int count = 0;
    for (auto& e : fs::directory_iterator(fs::current_path(), ec))
        if (e.path().extension() == ".fstp") {
            count++;
            path = e.path().string();
        }
    if (count == 0) fail("no hay ninguna solución (.fstp) en la carpeta actual; créala con 'faset new sln'");
    else if (count > 1) fail("hay varias soluciones (.fstp) en la carpeta actual; indica cuál: faset sln <x.fstp> ...");
    return count == 1;
}

void addFolderChain(Solution& s, const std::string& folder) {
    if (folder.empty()) return;
    size_t k = 0;
    for (;;) {
        size_t slash = folder.find('/', k);
        std::string part = folder.substr(0, slash);
        if (std::find(s.folders.begin(), s.folders.end(), part) == s.folders.end()) s.folders.push_back(part);
        if (slash == std::string::npos) break;
        k = slash + 1;
    }
}

std::string trimSlashes(std::string f) {
    std::replace(f.begin(), f.end(), '\\', '/');
    while (!f.empty() && f.front() == '/') f.erase(f.begin());
    while (!f.empty() && f.back() == '/') f.pop_back();
    return f;
}

// ------------------------------------------------------------------ compilar la solución

const std::set<std::string> kValueOptions = {"-o", "-c", "--configuration", "--target", "--arch", "--api",
                                             "--device", "-s", "--cc", "-l", "-L"};

int buildSolution(const std::string& command, const std::string& slnPath, const std::vector<std::string>& opts,
                  const std::string& output, const std::vector<std::string>& runArgs, bool hasRunArgs,
                  const std::string& self) {
    Solution s;
    std::string err;
    if (!loadSolution(slnPath, s, err)) {
        fail(err);
        return 1;
    }
    if (command == "emit-c") {
        fail("'emit-c' necesita un proyecto (.fstproj), no una solución");
        return 1;
    }
    if (s.projects.empty()) {
        fail("la solución '" + s.name + "' no tiene proyectos (añade uno con 'faset sln add <proyecto.fstproj>')");
        return 1;
    }
    std::vector<int> order;
    std::vector<std::vector<int>> deps;
    if (!solutionBuildOrder(s, order, err, &deps)) {
        fail(s.path + ": " + err);
        return 1;
    }
    bool verbose = std::find(opts.begin(), opts.end(), "-v") != opts.end() ||
                   std::find(opts.begin(), opts.end(), "--verbose") != opts.end();
    std::vector<std::string> extra = opts;
    auto given = [&](std::initializer_list<const char*> names) {
        for (const char* n : names)
            if (std::find(opts.begin(), opts.end(), n) != opts.end()) return true;
        return false;
    };
    if (!s.configuration.empty() && !given({"-c", "--configuration", "--debug", "--release"})) {
        extra.push_back("-c");
        extra.push_back(s.configuration);
    }
    if (!s.targetPlatform.empty() && !given({"--target"})) {
        extra.push_back("--target");
        extra.push_back(s.targetPlatform);
    }
    int startup = command == "run" || !output.empty() ? solutionStartupProject(s) : -1;
    if (command == "run" && startup < 0) {
        fail("la solución '" + s.name + "' no tiene un proyecto ejecutable que iniciar (márcalo con 'faset sln startup <proyecto>')");
        return 1;
    }
    if (!output.empty() && startup < 0) {
        fail("'-o' se aplica al proyecto de inicio, pero la solución no tiene ninguno");
        return 1;
    }

    const char* verb = command == "check" ? "Comprobando" : command == "clean" ? "Limpiando" : "Compilando";
    std::fprintf(stderr, "Solución '%s' (%zu proyecto%s)\n", s.name.c_str(), s.projects.size(), s.projects.size() == 1 ? "" : "s");
    std::vector<bool> failed(s.projects.size(), false);
    int ok = 0, bad = 0, skipped = 0, step = 0;
    int total = (int)order.size();
    auto blockedBy = [&](int i) -> std::string {
        for (int d : deps[i])
            if (failed[d]) return projectName(s.projects[d]);
        return "";
    };
    for (int i : order) {
        if (command == "run" && i == startup) continue;  // se compila y ejecuta al final
        const SolutionProject& p = s.projects[i];
        step++;
        std::fprintf(stderr, "\n[%d/%d] %s %s  (%s)\n", step, total, verb, projectName(p).c_str(), p.rel.c_str());
        if (!fs::exists(p.path)) {
            fail("no existe el proyecto '" + p.rel + "'");
            failed[i] = true;
            bad++;
            continue;
        }
        std::string sub = command == "run" ? "build" : command;  // 'run': los demás solo se compilan
        std::string blocker = sub == "build" ? blockedBy(i) : "";
        if (!blocker.empty()) {
            std::fprintf(stderr, "omitido: depende de '%s', que tiene errores\n", blocker.c_str());
            failed[i] = true;
            skipped++;
            continue;
        }
        std::vector<std::string> args = {sub, p.path};
        args.insert(args.end(), extra.begin(), extra.end());
        if (sub == "build" && i == startup && !output.empty()) {
            args.push_back("-o");
            args.push_back(output);
        }
        if (runSelf(self, args, verbose) != 0) {
            failed[i] = true;
            bad++;
        } else {
            ok++;
        }
    }
    if (command == "run") {
        const SolutionProject& p = s.projects[startup];
        std::fprintf(stderr, "\n[%d/%d] Compilando y ejecutando %s  (%s, proyecto de inicio)\n", total, total,
                     projectName(p).c_str(), p.rel.c_str());
        std::string blocker = blockedBy(startup);
        if (bad > 0 || !blocker.empty()) {
            if (!blocker.empty()) std::fprintf(stderr, "omitido: depende de '%s', que tiene errores\n", blocker.c_str());
            std::fprintf(stderr, "\nSolución: %d correcto%s, %d con errores; no se ejecuta '%s'.\n", ok, ok == 1 ? "" : "s", bad,
                         projectName(p).c_str());
            return 1;
        }
        std::vector<std::string> args = {"run", p.path};
        args.insert(args.end(), extra.begin(), extra.end());
        if (!output.empty()) {
            args.push_back("-o");
            args.push_back(output);
        }
        if (hasRunArgs) {
            args.push_back("--");
            args.insert(args.end(), runArgs.begin(), runArgs.end());
        }
        return runSelf(self, args, verbose);
    }
    std::fprintf(stderr, "\nSolución '%s': %d correcto%s, %d con errores", s.name.c_str(), ok, ok == 1 ? "" : "s", bad);
    if (skipped) std::fprintf(stderr, ", %d omitido%s", skipped, skipped == 1 ? "" : "s");
    std::fprintf(stderr, ".\n");
    return bad || skipped ? 1 : 0;
}

// ------------------------------------------------------------------ faset new

int newSolution(const std::vector<std::string>& args) {
    // faset new sln [Nombre]
    std::string name;
    for (size_t i = 2; i < args.size(); i++)
        if (!args[i].empty() && args[i][0] != '-') name = args[i];
    Solution s;
    if (name.empty()) {
        // En la carpeta actual, con los proyectos que haya debajo (hasta tres niveles).
        fs::path dir = fs::current_path();
        s.name = dir.filename().string();
        s.path = (dir / (s.name + ".fstp")).string();
        s.dir = dir.string();
        if (fs::exists(s.path)) {
            fail("'" + s.path + "' ya existe");
            return 1;
        }
        std::error_code ec;
        std::vector<std::string> found;
        auto it = fs::recursive_directory_iterator(dir, fs::directory_options::skip_permission_denied, ec);
        for (; it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec) break;
            std::string fn = it->path().filename().string();
            if (it->is_directory(ec)) {
                if (fn == "bin" || fn == "obj" || (!fn.empty() && fn[0] == '.') || it.depth() >= 3) it.disable_recursion_pending();
                continue;
            }
            if (it->path().extension() == ".fstproj") found.push_back(relativeSlash(it->path().string(), s.dir));
        }
        std::sort(found.begin(), found.end());
        for (const std::string& rel : found) {
            SolutionProject p;
            p.rel = rel;
            p.path = (dir / rel).lexically_normal().string();
            s.projects.push_back(p);
        }
        int st = solutionStartupProject(s);
        if (st >= 0) s.projects[st].startup = true;
    } else {
        fs::path dir(name);
        s.name = dir.filename().string();
        if (fs::exists(dir / (s.name + ".fstp"))) {
            fail("'" + (dir / (s.name + ".fstp")).string() + "' ya existe");
            return 1;
        }
        std::error_code ec;
        fs::create_directories(dir, ec);
        s.dir = fs::absolute(dir).string();
        s.path = (fs::absolute(dir) / (s.name + ".fstp")).string();
    }
    std::string err;
    if (!saveSolution(s, err)) {
        fail(err);
        return 1;
    }
    std::printf("Solución '%s' creada (%zu proyecto%s): %s\n", s.name.c_str(), s.projects.size(), s.projects.size() == 1 ? "" : "s",
                relativeSlash(s.path, fs::current_path().string()).c_str());
    if (!name.empty())
        std::printf("\n  cd %s\n  faset new MiProyecto\n  faset sln add MiProyecto/MiProyecto.fstproj\n", name.c_str());
    return 0;
}

int newWithSolution(const std::vector<std::string>& args, const std::string& self) {
    // faset new Nombre --solution [plantilla]: Nombre/Nombre.fstp + Nombre/Nombre/Nombre.fstproj
    std::string name;
    std::vector<std::string> templ;
    for (size_t i = 1; i < args.size(); i++) {
        if (args[i] == "--solution" || args[i] == "--sln") continue;
        if (!args[i].empty() && args[i][0] == '-') templ.push_back(args[i]);
        else if (name.empty()) name = args[i];
        else templ.push_back(args[i]);
    }
    if (name.empty()) {
        fail("uso: faset new <Nombre> --solution [--console | --lib | --winexe | --ui | --android]");
        return 1;
    }
    fs::path dir(name);
    std::string stem = dir.filename().string();
    if (fs::exists(dir)) {
        fail("'" + name + "' ya existe");
        return 1;
    }
    std::error_code ec;
    fs::create_directories(dir, ec);
    fs::path back = fs::current_path();
    fs::current_path(dir, ec);
    std::vector<std::string> a = {"new", stem};
    a.insert(a.end(), templ.begin(), templ.end());
    int r = runSelf(self, a, false);
    fs::current_path(back, ec);
    if (r != 0) {
        fs::remove_all(dir, ec);
        return r;
    }
    Solution s;
    s.name = stem;
    s.dir = fs::absolute(dir).string();
    s.path = (fs::absolute(dir) / (stem + ".fstp")).string();
    SolutionProject p;
    p.rel = stem + "/" + stem + ".fstproj";
    p.path = (fs::path(s.dir) / p.rel).string();
    p.startup = outputTypeOf(p.path) != "Library";
    s.projects.push_back(p);
    std::string err;
    if (!saveSolution(s, err)) {
        fail(err);
        return 1;
    }
    std::printf("Solución '%s' creada: %s/%s.fstp\n\n  cd %s\n  faset run\n", stem.c_str(), name.c_str(), stem.c_str(), name.c_str());
    return 0;
}

// ------------------------------------------------------------------ faset sln

// Añade <ProjectReference Include="..."/> al .fstproj conservando el resto del archivo.
bool addReference(const std::string& projPath, const std::string& libPath, std::string& message) {
    Project from, lib;
    std::string err;
    if (!loadProject(projPath, from, err) || !loadProject(libPath, lib, err)) {
        message = err;
        return false;
    }
    std::string a = fs::weakly_canonical(projPath).string(), b = fs::weakly_canonical(libPath).string();
    if (a == b) {
        message = "un proyecto no puede referenciarse a sí mismo";
        return false;
    }
    if (lib.prop("OutputType", "Exe") != "Library") {
        message = "'" + fs::path(libPath).stem().string() + "' no es una biblioteca (OutputType debe ser Library)";
        return false;
    }
    for (const std::string& r : from.references)
        if (fs::weakly_canonical(r).string() == b) {
            message = "'" + fs::path(projPath).stem().string() + "' ya referencia a '" + fs::path(libPath).stem().string() + "'";
            return false;
        }
    // ¿La biblioteca depende (directa o indirectamente) del proyecto? Sería una referencia circular.
    std::vector<std::string> seen;
    std::function<bool(const std::string&)> reaches = [&](const std::string& p) -> bool {
        std::string key = fs::weakly_canonical(p).string();
        if (key == a) return true;
        if (std::find(seen.begin(), seen.end(), key) != seen.end()) return false;
        seen.push_back(key);
        Project q;
        std::string e;
        if (!loadProject(p, q, e)) return false;
        for (const std::string& r : q.references)
            if (reaches(r)) return true;
        return false;
    };
    if (reaches(libPath)) {
        message = "referencia circular: '" + fs::path(libPath).stem().string() + "' ya depende de '" + fs::path(projPath).stem().string() + "'";
        return false;
    }
    std::ifstream in(projPath, std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    std::string text = ss.str();
    in.close();
    // Zonas comentadas (no se tocan).
    std::vector<std::pair<size_t, size_t>> comments;
    for (size_t k = text.find("<!--"); k != std::string::npos; k = text.find("<!--", k + 4)) {
        size_t e = text.find("-->", k + 4);
        comments.push_back({k, e == std::string::npos ? text.size() : e + 3});
        if (e == std::string::npos) break;
        k = e;
    }
    auto commented = [&](size_t off) {
        for (auto& [x, y] : comments)
            if (off >= x && off < y) return true;
        return false;
    };
    auto lastOutside = [&](const std::string& what) -> size_t {
        size_t found = std::string::npos;
        for (size_t k = text.find(what); k != std::string::npos; k = text.find(what, k + 1))
            if (!commented(k)) found = k;
        return found;
    };
    std::string rel = relativeSlash(libPath, fs::path(projPath).parent_path().string());
    std::string item = "<ProjectReference Include=\"" + rel + "\" />";
    size_t last = lastOutside("<ProjectReference");
    if (last != std::string::npos) {
        // Junto a la última referencia, con la misma sangría.
        size_t ls = text.rfind('\n', last);
        ls = ls == std::string::npos ? 0 : ls + 1;
        std::string indent = text.substr(ls, last - ls);
        if (indent.find_first_not_of(" \t") != std::string::npos) indent = "    ";
        size_t le = text.find('\n', last);
        if (le == std::string::npos) {
            text += "\n" + indent + item;
        } else {
            text.insert(le + 1, indent + item + "\n");
        }
    } else {
        size_t end = lastOutside("</Project>");
        if (end == std::string::npos) {
            message = projPath + ": falta </Project>";
            return false;
        }
        std::string block = "  <ItemGroup>\n    " + item + "\n  </ItemGroup>\n";
        if (end > 0 && text[end - 1] != '\n') block = "\n" + block;
        if (end > 1 && text.compare(end - 2, 2, "\n\n") != 0 && text.find("</PropertyGroup>") != std::string::npos) block = "\n" + block;
        text.insert(end, block);
    }
    std::ofstream out(projPath, std::ios::binary);
    out << text;
    if (!out) {
        message = "no se pudo escribir '" + projPath + "'";
        return false;
    }
    message = "'" + fs::path(projPath).stem().string() + "' ahora referencia a '" + fs::path(libPath).stem().string() + "' (" + rel + ")";
    return true;
}

void slnUsage() {
    std::printf(
        "Uso: faset sln [solución.fstp] <orden>\n\n"
        "  add <proyecto.fstproj>... [--folder F]   Añade proyectos (F: carpeta de solución, 'A/B' anidada)\n"
        "  remove <proyecto>                        Quita un proyecto de la solución (no lo borra)\n"
        "  list [--json]                            Muestra los proyectos\n"
        "  startup <proyecto>                       Elige el proyecto de inicio ('faset run')\n"
        "  folder <Nombre> [--remove]               Crea (o quita) una carpeta de solución\n"
        "  move <proyecto> [carpeta]                Mueve un proyecto a una carpeta de solución\n"
        "  rename <Nombre>                          Cambia el nombre de la solución (y del .fstp)\n"
        "  ref <proyecto> <biblioteca>              Añade <ProjectReference> al .fstproj del proyecto\n\n"
        "<proyecto> puede ser la ruta del .fstproj, su carpeta o su nombre.\n"
        "Sin solución.fstp se usa la de la carpeta actual.\n");
}

int cmdSln(const std::vector<std::string>& all) {
    std::vector<std::string> args(all.begin() + 1, all.end());
    std::string given;
    if (!args.empty() && hasExt(args[0], ".fstp")) {
        given = args[0];
        args.erase(args.begin());
    }
    if (args.empty() || args[0] == "help" || args[0] == "--help" || args[0] == "-h") {
        slnUsage();
        return 0;
    }
    std::string sub = args[0];
    std::vector<std::string> rest(args.begin() + 1, args.end());
    std::string slnPath;
    if (!locate(given, slnPath)) return 1;
    Solution s;
    std::string err;
    if (!loadSolution(slnPath, s, err)) {
        fail(err);
        return 1;
    }
    auto save = [&]() {
        if (saveSolution(s, err)) return true;
        fail(err);
        return false;
    };
    auto findOr = [&](const std::string& p) {
        int i = s.find(p);
        if (i < 0) fail("'" + p + "' no está en la solución '" + s.name + "' (ver 'faset sln list')");
        return i;
    };

    if (sub == "add") {
        std::string folder;
        std::vector<std::string> paths;
        for (size_t i = 0; i < rest.size(); i++) {
            if (rest[i] == "--folder" && i + 1 < rest.size()) folder = trimSlashes(rest[++i]);
            else paths.push_back(rest[i]);
        }
        if (paths.empty()) {
            fail("uso: faset sln add <proyecto.fstproj>... [--folder Carpeta]");
            return 1;
        }
        int added = 0;
        for (const std::string& raw : paths) {
            std::string p = projectFileOf(raw);
            if (!fs::exists(p) && fs::exists(fs::path(s.dir) / raw)) p = projectFileOf((fs::path(s.dir) / raw).string());
            if (!hasExt(p, ".fstproj") || !fs::exists(p)) {
                fail("no existe el proyecto '" + raw + "'");
                return 1;
            }
            Project proj;
            if (!loadProject(p, proj, err)) {
                fail(err);
                return 1;
            }
            if (s.find(p) >= 0) {
                std::printf("'%s' ya está en la solución.\n", fs::path(p).stem().string().c_str());
                continue;
            }
            SolutionProject sp;
            sp.path = fs::absolute(p).lexically_normal().string();
            sp.rel = relativeSlash(sp.path, s.dir);
            sp.folder = folder;
            s.projects.push_back(sp);
            addFolderChain(s, folder);
            added++;
            std::printf("Añadido '%s' (%s) a la solución '%s'.\n", fs::path(p).stem().string().c_str(), sp.rel.c_str(), s.name.c_str());
        }
        return added && !save() ? 1 : 0;
    }
    if (sub == "remove" || sub == "rm") {
        if (rest.empty()) {
            fail("uso: faset sln remove <proyecto>");
            return 1;
        }
        for (const std::string& p : rest) {
            int i = findOr(p);
            if (i < 0) return 1;
            std::printf("Quitado '%s' de la solución '%s' (el proyecto sigue en el disco).\n", projectName(s.projects[i]).c_str(),
                        s.name.c_str());
            s.projects.erase(s.projects.begin() + i);
        }
        return save() ? 0 : 1;
    }
    if (sub == "list" || sub == "ls") {
        bool json = std::find(rest.begin(), rest.end(), "--json") != rest.end();
        int startup = solutionStartupProject(s);
        if (json) {
            Json j = Json::object();
            j["name"] = s.name;
            j["path"] = s.path;
            j["dir"] = s.dir;
            j["configuration"] = s.configuration;
            j["targetPlatform"] = s.targetPlatform;
            Json folders = Json::array();
            for (const std::string& f : s.folders) folders.push(f);
            j["folders"] = std::move(folders);
            Json projects = Json::array();
            for (size_t i = 0; i < s.projects.size(); i++) {
                const SolutionProject& p = s.projects[i];
                Json o = Json::object();
                o["name"] = projectName(p);
                o["path"] = p.path;
                o["rel"] = p.rel;
                o["folder"] = p.folder;
                o["startup"] = (int)i == startup;
                o["exists"] = fs::exists(p.path);
                Project proj;
                std::string e;
                bool loaded = loadProject(p.path, proj, e);
                o["outputType"] = loaded ? proj.prop("OutputType", "Exe") : "";
                o["targetPlatform"] = loaded ? proj.prop("TargetPlatform", "native") : "";
                Json refs = Json::array();
                for (const std::string& r : proj.references) refs.push(r);
                o["references"] = std::move(refs);
                projects.push(std::move(o));
            }
            j["projects"] = std::move(projects);
            std::printf("%s\n", j.dump().c_str());
            return 0;
        }
        std::printf("Solución '%s' (%zu proyecto%s)\n", s.name.c_str(), s.projects.size(), s.projects.size() == 1 ? "" : "s");
        std::function<void(const std::string&, int)> show = [&](const std::string& folder, int depth) {
            std::string pad((size_t)depth * 2, ' ');
            for (size_t i = 0; i < s.projects.size(); i++) {
                const SolutionProject& p = s.projects[i];
                if (p.folder != folder) continue;
                std::string ot = fs::exists(p.path) ? outputTypeOf(p.path) : "no existe";
                std::printf("%s %s%-16s %-32s %s%s\n", (int)i == startup ? "*" : " ", pad.c_str(), projectName(p).c_str(), p.rel.c_str(),
                            ot.c_str(), (int)i == startup ? "  (inicio)" : "");
            }
            for (const std::string& f : s.folders) {
                size_t slash = f.rfind('/');
                if ((slash == std::string::npos ? "" : f.substr(0, slash)) != folder) continue;
                std::printf("  %s%s/\n", pad.c_str(), f.substr(slash == std::string::npos ? 0 : slash + 1).c_str());
                show(f, depth + 1);
            }
        };
        show("", 0);
        return 0;
    }
    if (sub == "startup") {
        if (rest.size() != 1) {
            fail("uso: faset sln startup <proyecto>");
            return 1;
        }
        int i = findOr(rest[0]);
        if (i < 0) return 1;
        if (outputTypeOf(s.projects[i].path) == "Library") {
            fail("'" + projectName(s.projects[i]) + "' es una biblioteca: el proyecto de inicio debe ser Exe o WinExe");
            return 1;
        }
        for (auto& p : s.projects) p.startup = false;
        s.projects[i].startup = true;
        if (!save()) return 1;
        std::printf("Proyecto de inicio: '%s'.\n", projectName(s.projects[i]).c_str());
        return 0;
    }
    if (sub == "folder") {
        bool remove = std::find(rest.begin(), rest.end(), "--remove") != rest.end();
        std::string name;
        for (const std::string& r : rest)
            if (r != "--remove") name = trimSlashes(r);
        if (name.empty()) {
            fail("uso: faset sln folder <Nombre> [--remove]");
            return 1;
        }
        if (remove) {
            if (std::find(s.folders.begin(), s.folders.end(), name) == s.folders.end()) {
                fail("la solución no tiene la carpeta '" + name + "'");
                return 1;
            }
            // Sus proyectos (y los de sus subcarpetas) pasan a la carpeta superior.
            size_t slash = name.rfind('/');
            std::string parent = slash == std::string::npos ? "" : name.substr(0, slash);
            auto inside = [&](const std::string& f) { return f == name || f.rfind(name + "/", 0) == 0; };
            for (auto& p : s.projects)
                if (inside(p.folder)) p.folder = parent;
            s.folders.erase(std::remove_if(s.folders.begin(), s.folders.end(), inside), s.folders.end());
            if (!save()) return 1;
            std::printf("Carpeta '%s' quitada de la solución.\n", name.c_str());
            return 0;
        }
        if (std::find(s.folders.begin(), s.folders.end(), name) != s.folders.end()) {
            std::printf("La carpeta '%s' ya existe.\n", name.c_str());
            return 0;
        }
        addFolderChain(s, name);
        if (!save()) return 1;
        std::printf("Carpeta de solución '%s' creada.\n", name.c_str());
        return 0;
    }
    if (sub == "move") {
        if (rest.empty() || rest.size() > 2) {
            fail("uso: faset sln move <proyecto> [carpeta]");
            return 1;
        }
        int i = findOr(rest[0]);
        if (i < 0) return 1;
        std::string folder = rest.size() == 2 ? trimSlashes(rest[1]) : "";
        s.projects[i].folder = folder;
        addFolderChain(s, folder);
        if (!save()) return 1;
        std::printf("'%s' movido a %s.\n", projectName(s.projects[i]).c_str(),
                    folder.empty() ? "la raíz de la solución" : ("la carpeta '" + folder + "'").c_str());
        return 0;
    }
    if (sub == "rename") {
        if (rest.size() != 1 || rest[0].empty() || rest[0].find('/') != std::string::npos || rest[0].find('\\') != std::string::npos) {
            fail("uso: faset sln rename <NuevoNombre>");
            return 1;
        }
        std::string old = s.path;
        s.name = rest[0];
        fs::path dest = fs::path(s.dir) / (s.name + ".fstp");
        std::error_code ec;
        bool move = dest != fs::path(old) && !fs::exists(dest, ec);
        if (move) s.path = dest.string();
        if (!save()) return 1;
        if (move) fs::remove(old, ec);
        std::printf("Solución renombrada a '%s': %s\n", s.name.c_str(), s.path.c_str());
        return 0;
    }
    if (sub == "ref" || sub == "reference") {
        if (rest.size() != 2) {
            fail("uso: faset sln ref <proyecto> <biblioteca>");
            return 1;
        }
        int a = s.find(rest[0]), b = s.find(rest[1]);
        std::string pa = a >= 0 ? s.projects[a].path : projectFileOf(rest[0]);
        std::string pb = b >= 0 ? s.projects[b].path : projectFileOf(rest[1]);
        for (const std::string& p : {pa, pb})
            if (!fs::exists(p) || !hasExt(p, ".fstproj")) {
                fail("no existe el proyecto '" + p + "'");
                return 1;
            }
        std::string msg;
        if (!addReference(pa, pb, msg)) {
            fail(msg);
            return 1;
        }
        std::printf("%s.\n", msg.c_str());
        return 0;
    }
    fail("orden desconocida 'sln " + sub + "' (usa 'faset sln help')");
    return 1;
}

}  // namespace

bool solutionCommand(const std::vector<std::string>& args, const std::string& argv0, int& code) {
    if (args.empty()) return false;
    std::string self = selfExePath(argv0);
    const std::string& cmd = args[0];
    if (cmd == "sln" || cmd == "solution") {
        code = cmdSln(args);
        return true;
    }
    if (cmd == "new") {
        if (args.size() >= 2 && (args[1] == "sln" || args[1] == "solution")) {
            code = newSolution(args);
            return true;
        }
        if (std::find(args.begin(), args.end(), "--solution") != args.end() || std::find(args.begin(), args.end(), "--sln") != args.end()) {
            code = newWithSolution(args, self);
            return true;
        }
        return false;
    }
    std::vector<std::string> a = args;
    if (hasExt(cmd, ".fstp")) a.insert(a.begin(), "build");  // 'faset MiJuego.fstp'
    static const std::set<std::string> builds = {"build", "run", "check", "clean", "emit-c"};
    if (!builds.count(a[0])) return false;
    // Entrada: el .fstp indicado, una carpeta con un .fstp y sin .fstproj, o la carpeta actual.
    std::vector<std::string> positional, opts, runArgs;
    std::string output;
    bool hasRunArgs = false;
    for (size_t i = 1; i < a.size(); i++) {
        if (a[i] == "--") {
            hasRunArgs = true;
            runArgs.assign(a.begin() + (long)i + 1, a.end());
            break;
        }
        if (kValueOptions.count(a[i]) && i + 1 < a.size()) {
            if (a[i] == "-o") output = a[++i];
            else {
                opts.push_back(a[i]);
                opts.push_back(a[++i]);
            }
        } else if (!a[i].empty() && a[i][0] == '-') {
            opts.push_back(a[i]);
        } else {
            positional.push_back(a[i]);
        }
    }
    std::string sln;
    std::error_code ec;
    if (positional.empty()) {
        if (!hasProjectIn(fs::current_path())) sln = findSolutionIn(fs::current_path().string());
    } else if (positional.size() == 1) {
        if (hasExt(positional[0], ".fstp")) sln = positional[0];
        else if (fs::is_directory(positional[0], ec) && !hasProjectIn(positional[0])) sln = findSolutionIn(positional[0]);
    }
    if (sln.empty()) return false;
    if (!fs::exists(sln)) {
        fail("no existe la solución '" + sln + "'");
        code = 1;
        return true;
    }
    code = buildSolution(a[0], sln, opts, output, runArgs, hasRunArgs, self);
    return true;
}
