#include "Setup.h"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>

#if defined(_WIN32)
#include <io.h>
#include <windows.h>
#define popen _popen
#define pclose _pclose
#define isatty _isatty
#define fileno _fileno
#else
#include <sys/wait.h>
#include <unistd.h>
#endif

#include "Android.h"
#include "Frontend.h"
#include "Json.h"

namespace fs = std::filesystem;

namespace {

#if defined(_WIN32)
const char* const kHost = "windows";
const char* const kExe = ".exe";
const char* const kBat = ".bat";
#else
const char* const kHost = "linux";
const char* const kExe = "";
const char* const kBat = "";
#endif
#if defined(__aarch64__) || defined(_M_ARM64)
const char* const kArch = "arm64";
#else
const char* const kArch = "x86_64";
#endif

struct Opts {
    bool yes = false;         // no preguntar (y aceptar las licencias del SDK de Android)
    bool emulator = true;     // android: emulador + imagen del sistema + AVD
    bool verbose = false;
    bool dryRun = false;      // android: muestra los paquetes del SDK sin instalarlos
};

std::string env(const char* name) {
    const char* v = std::getenv(name);
    return v ? v : "";
}

void setEnv(const char* name, const std::string& value) {
#if defined(_WIN32)
    _putenv_s(name, value.c_str());
#else
    setenv(name, value.c_str(), 1);
#endif
}

std::string quote(const std::string& s) {
#if defined(_WIN32)
    return windowsQuote(s);
#else
    std::string r = "'";
    for (char c : s) r += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return r + "'";
#endif
}

std::string join(const std::vector<std::string>& args) {
    std::string cmd;
    for (size_t i = 0; i < args.size(); i++) cmd += (i ? " " : "") + quote(args[i]);
    return cmd;
}

// Ejecuta una orden (con redirección opcional, p. ej. "< respuestas.txt") y devuelve su código.
int run(const std::vector<std::string>& args, const std::string& redirect = "") {
    std::string cmd = join(args) + (redirect.empty() ? "" : " " + redirect);
    std::printf("  $ %s\n", cmd.c_str());
#if defined(_WIN32)
    cmd = "\"" + cmd + "\"";
#endif
    std::fflush(stdout);
    int r = std::system(cmd.c_str());
#if !defined(_WIN32)
    if (r != -1 && WIFEXITED(r)) r = WEXITSTATUS(r);
#endif
    return r;
}

// Salida estándar de una orden (stderr se descarta).
bool capture(const std::vector<std::string>& args, std::string& out) {
#if defined(_WIN32)
    std::string cmd = "\"" + join(args) + " 2>NUL\"";
#else
    std::string cmd = join(args) + " 2>/dev/null";
#endif
    FILE* p = popen(cmd.c_str(), "r");
    if (!p) return false;
    char buf[4096];
    size_t n;
    out.clear();
    while ((n = std::fread(buf, 1, sizeof buf, p)) > 0) out.append(buf, n);
    int r = pclose(p);
#if !defined(_WIN32)
    if (r != -1 && WIFEXITED(r)) r = WEXITSTATUS(r);
#endif
    return r == 0;
}

bool have(const char* prog) { return !findProgram(prog).empty(); }

bool pathOk(const fs::path& p) {
    std::error_code ec;
    return fs::exists(p, ec);
}

bool ask(const Opts& o, const std::string& question, bool def) {
    if (o.yes) return true;
    if (!isatty(fileno(stdin))) return def;
    std::printf("%s %s ", question.c_str(), def ? "[S/n]" : "[s/N]");
    std::fflush(stdout);
    std::string line;
    if (!std::getline(std::cin, line)) return def;
    if (line.empty()) return def;
    char c = (char)std::tolower((unsigned char)line[0]);
    return c == 's' || c == 'y';
}

// Descarga con curl (Linux y Windows 10+) o wget.
bool download(const std::string& url, const fs::path& dest) {
    std::error_code ec;
    fs::create_directories(dest.parent_path(), ec);
    int r;
    if (have("curl")) r = run({"curl", "-fL", "--retry", "3", "--progress-bar", "-o", dest.string(), url});
    else if (have("wget")) r = run({"wget", "-q", "--show-progress", "-O", dest.string(), url});
    else {
        std::fprintf(stderr, "faset: hace falta curl o wget para descargar %s\n", url.c_str());
        return false;
    }
    return r == 0 && pathOk(dest);
}

bool fetchText(const std::string& url, std::string& out) {
    std::vector<std::string> cmd;
    if (have("curl")) cmd = {"curl", "-fsSL", "--retry", "3", url};
    else if (have("wget")) cmd = {"wget", "-qO-", url};
    else return false;
    return capture(cmd, out) && !out.empty();
}

bool endsWith(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Descomprime .zip, .tar.gz o .tar.xz en 'dest' (que se crea).
bool extract(const fs::path& archive, const fs::path& dest, const std::string& javaHome = "") {
    std::error_code ec;
    fs::create_directories(dest, ec);
    std::string a = archive.string();
    if (!endsWith(a, ".zip")) return run({"tar", "-xf", a, "-C", dest.string()}) == 0;
#if defined(_WIN32)
    return run({"tar", "-xf", a, "-C", dest.string()}) == 0;  // bsdtar de Windows 10+ abre .zip
#else
    if (have("unzip")) return run({"unzip", "-q", "-o", a, "-d", dest.string()}) == 0;
    if (have("bsdtar")) return run({"bsdtar", "-xf", a, "-C", dest.string()}) == 0;
    if (have("python3"))
        return run({"python3", "-c", "import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])", a, dest.string()}) == 0;
    if (!javaHome.empty()) {
        // 'jar' del JDK también descomprime .zip.
        std::string jar = (fs::path(javaHome) / "bin" / "jar").string();
        return run({"sh", "-c", "cd " + quote(dest.string()) + " && " + quote(jar) + " xf " + quote(a)}) == 0;
    }
    std::fprintf(stderr, "faset: hace falta unzip para descomprimir %s (sudo apt install unzip)\n", a.c_str());
    return false;
#endif
}

// Única subcarpeta de 'dir' (los archivos suelen traer una carpeta raíz con la versión).
fs::path singleChild(const fs::path& dir) {
    std::error_code ec;
    fs::path found;
    int n = 0;
    for (auto& e : fs::directory_iterator(dir, ec))
        if (e.is_directory(ec)) found = e.path(), n++;
    return n == 1 ? found : fs::path();
}

// Descarga 'url', la descomprime y deja su carpeta raíz en 'dest' (sustituye la anterior).
bool installArchive(const std::string& url, const fs::path& dest, const std::string& javaHome = "") {
    fs::path dl = fs::path(fasetDataDir()) / "downloads";
    std::string file = url.substr(url.find_last_of('/') + 1);
    size_t qm = file.find('?');
    if (qm != std::string::npos) file = file.substr(0, qm);
    fs::path archive = dl / file;
    fs::path tmp = dest.parent_path() / (dest.filename().string() + ".tmp");
    std::error_code ec;
    fs::remove_all(tmp, ec);
    if (!download(url, archive)) return false;
    if (!extract(archive, tmp, javaHome)) return false;
    fs::path root = singleChild(tmp);
    if (root.empty()) root = tmp;
    fs::remove_all(dest, ec);
    fs::create_directories(dest.parent_path(), ec);
    fs::rename(root, dest, ec);
    if (ec) {
        std::fprintf(stderr, "faset: no se pudo mover %s a %s: %s\n", root.string().c_str(), dest.string().c_str(),
                     ec.message().c_str());
        return false;
    }
    fs::remove_all(tmp, ec);
    fs::remove(archive, ec);
    return true;
}

void title(const std::string& s) { std::printf("\n== %s\n", s.c_str()); }
void ok(const std::string& s) { std::printf("  ✓ %s\n", s.c_str()); }
void miss(const std::string& s) { std::printf("  ✗ %s\n", s.c_str()); }

// ------------------------------------------------------------------ gestor de paquetes (Linux)

struct PkgManager {
    std::string name;                 // apt, dnf, pacman, zypper, apk
    std::vector<std::string> install; // orden sin los paquetes
};

PkgManager pkgManager() {
    if (have("apt-get")) return {"apt", {"apt-get", "install", "-y"}};
    if (have("dnf")) return {"dnf", {"dnf", "install", "-y"}};
    if (have("pacman")) return {"pacman", {"pacman", "-S", "--needed", "--noconfirm"}};
    if (have("zypper")) return {"zypper", {"zypper", "install", "-y"}};
    if (have("apk")) return {"apk", {"apk", "add"}};
    return {};
}

// Paquete de cada gestor para una necesidad (compilador, vulkan...).
std::string pkgFor(const std::string& pm, const std::string& what) {
    struct Row { const char *what, *apt, *dnf, *pacman, *zypper, *apk; };
    static const Row rows[] = {
        {"cc", "build-essential", "gcc", "gcc", "gcc", "build-base"},
        {"vulkan", "libvulkan1", "vulkan-loader", "vulkan-icd-loader", "libvulkan1", "vulkan-loader"},
        {"vulkan-driver", "mesa-vulkan-drivers", "mesa-vulkan-drivers", "vulkan-radeon", "libvulkan_radeon", "mesa-vulkan-ati"},
        {"x11", "libx11-6", "libX11", "libx11", "libX11-6", "libx11"},
        {"freetype", "libfreetype6", "freetype", "freetype2", "libfreetype6", "freetype"},
        {"unzip", "unzip", "unzip", "unzip", "unzip", "unzip"},
        {"webkit", "libwebkit2gtk-4.1-0", "webkit2gtk4.1", "webkit2gtk-4.1", "libwebkit2gtk-4_1-0", "webkit2gtk-4.1"},
        {"gstreamer", "gstreamer1.0-plugins-good", "gstreamer1-plugins-good", "gst-plugins-good", "gstreamer-plugins-good",
         "gst-plugins-good"},
        {"gst-libav", "gstreamer1.0-libav", "gstreamer1-plugin-libav", "gst-libav", "gstreamer-plugins-libav", "gst-libav"},
        {"pulse", "libpulse0", "pulseaudio-libs", "libpulse", "libpulse0", "libpulse"},
    };
    for (const Row& r : rows)
        if (what == r.what)
            return pm == "apt" ? r.apt : pm == "dnf" ? r.dnf : pm == "pacman" ? r.pacman : pm == "zypper" ? r.zypper : r.apk;
    return what;
}

bool sharedLibPresent(const std::string& soname) {
#if defined(_WIN32)
    (void)soname;
    return true;
#else
    static std::string cache;
    static bool loaded = false;
    if (!loaded) {
        loaded = true;
        capture({"ldconfig", "-p"}, cache);
        if (cache.empty()) capture({"/sbin/ldconfig", "-p"}, cache);
    }
    if (cache.find(soname) != std::string::npos) return true;
    for (const char* dir : {"/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib", "/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu"})
        if (pathOk(fs::path(dir) / soname)) return true;
    return false;
#endif
}

// Instala paquetes del sistema (con sudo si hace falta), tras preguntar.
bool installPackages(const Opts& o, const std::vector<std::string>& needs, const std::string& why) {
    PkgManager pm = pkgManager();
    if (pm.name.empty()) {
        std::printf("  Instala a mano: %s (no se reconoce el gestor de paquetes)\n", why.c_str());
        return false;
    }
    std::vector<std::string> cmd;
#if !defined(_WIN32)
    if (geteuid() != 0) cmd.push_back("sudo");
#endif
    cmd.insert(cmd.end(), pm.install.begin(), pm.install.end());
    for (const std::string& n : needs) cmd.push_back(pkgFor(pm.name, n));
    std::printf("  Hace falta %s:\n    %s\n", why.c_str(), join(cmd).c_str());
    if (!ask(o, "  ¿Instalarlo ahora?", true)) return false;
    if (pm.name == "apt") {
        std::vector<std::string> upd = cmd;
        upd.resize(upd.size() - needs.size() - 2);  // sudo apt-get
        upd.push_back("update");
        run(upd);
    }
    return run(cmd) == 0;
}

// ------------------------------------------------------------------ módulo: linux

std::string nativeCC() {
    for (const char* c : {"cc", "gcc", "clang"}) {
        std::string p = findProgram(c);
        if (!p.empty()) return p;
    }
    return "";
}

bool setupLinux(const Opts& o, bool listOnly) {
    title("Linux (programas nativos y FasetStudio)");
    bool good = true;
    std::string cc = nativeCC();
    if (!cc.empty()) ok("compilador de C: " + cc);
    else {
        miss("compilador de C (gcc o clang)");
        good = listOnly ? false : installPackages(o, {"cc"}, "un compilador de C") && !nativeCC().empty();
    }
    std::vector<std::string> needs;
    for (auto [so, pkg] : {std::pair<const char*, const char*>{"libvulkan.so.1", "vulkan"}, {"libX11.so.6", "x11"},
                           {"libfreetype.so.6", "freetype"}}) {
        if (sharedLibPresent(so)) ok(std::string("FasetStudio: ") + so);
        else miss(std::string("FasetStudio: ") + so), needs.push_back(pkg);
    }
    if (!needs.empty()) {
        if (listOnly) good = false;
        else {
            needs.push_back("vulkan-driver");
            good = installPackages(o, needs, "las bibliotecas de FasetStudio (Vulkan, X11, FreeType)") && good;
        }
    }
    return good;
}

// ------------------------------------------------------------------ módulo: multimedia (Linux)

bool setupMultimedia(const Opts& o, bool listOnly) {
    title("Multimedia de std.ui (WebView, VideoPlayer, std.audio) — opcional");
#if defined(_WIN32)
    (void)o;
    (void)listOnly;
    ok("en Windows se usan las bibliotecas del sistema");
    return true;
#else
    std::vector<std::string> needs;
    struct Item { const char *so, *pkg, *label; };
    for (const Item& it : {Item{"libwebkit2gtk-4.1.so.0", "webkit", "WebView (WebKitGTK 4.1)"},
                           Item{"libgstreamer-1.0.so.0", "gstreamer", "VideoPlayer (GStreamer)"},
                           Item{"libgstapp-1.0.so.0", "gstreamer", "VideoPlayer (appsink)"},
                           Item{"libpulse-simple.so.0", "pulse", "std.audio (PulseAudio)"}}) {
        if (sharedLibPresent(it.so)) ok(it.label);
        else {
            miss(it.label);
            if (std::find(needs.begin(), needs.end(), it.pkg) == needs.end()) needs.push_back(it.pkg);
        }
    }
    if (needs.empty()) return true;
    if (listOnly) return false;
    if (std::find(needs.begin(), needs.end(), "gstreamer") != needs.end()) needs.push_back("gst-libav");
    return installPackages(o, needs, "las bibliotecas multimedia");
#endif
}

// ------------------------------------------------------------------ módulo: windows (llvm-mingw)

fs::path mingwDir() { return fs::path(fasetDataDir()) / "toolchains" / "llvm-mingw"; }

bool setupWindows(const Opts& o, bool listOnly) {
    title(std::string("Windows (") + (std::string(kHost) == "windows" ? "programas nativos" : "compilación cruzada desde Linux") +
          ")");
    std::string managed = managedMingwCompiler("x86_64");
    if (!managed.empty()) {
        ok("toolchain llvm-mingw: " + mingwDir().string());
        return true;
    }
#if defined(_WIN32)
    std::string sys = nativeCC();
#else
    std::string sys = findProgram("x86_64-w64-mingw32-gcc");
#endif
    if (!sys.empty()) {
        ok("compilador de C: " + sys);
        return true;
    }
    miss("toolchain de C para Windows");
    if (listOnly) return false;
    std::printf("  Se descargará llvm-mingw (clang + MinGW-w64, ~150 MB) en %s\n", mingwDir().string().c_str());
    if (!ask(o, "  ¿Continuar?", true)) return false;
    std::string json;
    if (!fetchText("https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest", json)) {
        std::fprintf(stderr, "faset: no se pudo consultar la última versión de llvm-mingw\n");
        return false;
    }
    Json rel;
    if (!Json::parse(json, rel)) return false;
    std::string want;
#if defined(_WIN32)
    want = std::string(kArch) == "arm64" ? "ucrt-aarch64.zip" : "ucrt-x86_64.zip";
#else
    want = std::string(kArch) == "arm64" ? "aarch64.tar.xz" : "x86_64.tar.xz";
#endif
    std::string url;
    for (const Json& a : rel.get("assets").elements()) {
        std::string n = a.get("name").asString();
#if defined(_WIN32)
        if (endsWith(n, want) && n.find("ucrt") != std::string::npos) url = a.get("browser_download_url").asString();
#else
        if (n.find("ucrt-ubuntu") != std::string::npos && endsWith(n, want)) url = a.get("browser_download_url").asString();
#endif
        if (!url.empty()) break;
    }
    if (url.empty()) {
        std::fprintf(stderr, "faset: no hay un paquete de llvm-mingw para este sistema (%s)\n", want.c_str());
        return false;
    }
    if (!installArchive(url, mingwDir())) return false;
    managed = managedMingwCompiler("x86_64");
    if (managed.empty()) return false;
    ok("llvm-mingw instalado: " + managed);
    return true;
}

// ------------------------------------------------------------------ módulo: android

fs::path defaultSdk() {
#if defined(_WIN32)
    return fs::path(env("LOCALAPPDATA")) / "Android" / "Sdk";
#else
    return fs::path(env("HOME")) / "Android" / "Sdk";
#endif
}

fs::path existingSdk() {
    for (const char* v : {"ANDROID_HOME", "ANDROID_SDK_ROOT"})
        if (!env(v).empty()) return env(v);
    fs::path d = defaultSdk();
    return d;
}

std::string javaHomeFor() {
    const AndroidTools& t = androidTools();
    if (!t.javaHome.empty()) return t.javaHome;
    return managedJavaHome();
}

bool ensureJava(const Opts& o, bool listOnly, std::string& javaHome) {
    javaHome = javaHomeFor();
    if (!javaHome.empty()) {
        ok("Java: " + javaHome);
        return true;
    }
    if (!androidTools().java.empty()) {
        // 'java' en el PATH sin JAVA_HOME: sdkmanager lo encuentra solo.
        ok("Java: " + androidTools().java);
        return true;
    }
    miss("Java (JDK 17 o posterior, para sdkmanager y apksigner)");
    if (listOnly) return false;
    std::printf("  Se descargará Eclipse Temurin JDK 21 (~200 MB) en %s\n", (fs::path(fasetDataDir()) / "jdk").string().c_str());
    if (!ask(o, "  ¿Continuar?", true)) return false;
    std::string arch = std::string(kArch) == "arm64" ? "aarch64" : "x64";
    std::string url = "https://api.adoptium.net/v3/binary/latest/21/ga/" + std::string(kHost) + "/" + arch +
                      "/jdk/hotspot/normal/eclipse";
    // La API redirige a un archivo .tar.gz (Linux) o .zip (Windows): se le da nombre fijo.
    fs::path dl = fs::path(fasetDataDir()) / "downloads" / (std::string("temurin-21") + (std::string(kHost) == "windows" ? ".zip" : ".tar.gz"));
    if (!download(url, dl)) return false;
    fs::path dest = fs::path(fasetDataDir()) / "jdk";
    fs::path tmp = fs::path(fasetDataDir()) / "jdk.tmp";
    std::error_code ec;
    fs::remove_all(tmp, ec);
    if (!extract(dl, tmp)) return false;
    fs::path root = singleChild(tmp);
    fs::remove_all(dest, ec);
    fs::rename(root.empty() ? tmp : root, dest, ec);
    fs::remove_all(tmp, ec);
    fs::remove(dl, ec);
    javaHome = managedJavaHome();
    if (javaHome.empty()) return false;
    ok("JDK instalado: " + javaHome);
    return true;
}

fs::path sdkmanagerPath(const fs::path& sdk) { return sdk / "cmdline-tools" / "latest" / "bin" / (std::string("sdkmanager") + kBat); }
fs::path avdmanagerPath(const fs::path& sdk) { return sdk / "cmdline-tools" / "latest" / "bin" / (std::string("avdmanager") + kBat); }

// URL de las cmdline-tools más recientes según el repositorio de Google.
std::string cmdlineToolsUrl() {
    std::string xml;
    if (!fetchText("https://dl.google.com/android/repository/repository2-3.xml", xml)) return "";
    size_t pkg = xml.find("path=\"cmdline-tools;latest\"");
    if (pkg == std::string::npos) return "";
    size_t end = xml.find("</remotePackage>", pkg);
    std::string block = xml.substr(pkg, end - pkg);
    std::string host = std::string(kHost) == "windows" ? "windows" : "linux";
    for (size_t a = block.find("<archive>"); a != std::string::npos; a = block.find("<archive>", a + 1)) {
        size_t ae = block.find("</archive>", a);
        std::string arc = block.substr(a, ae - a);
        if (arc.find("<host-os>" + host + "</host-os>") == std::string::npos) continue;
        size_t u = arc.find("<url>"), ue = arc.find("</url>");
        if (u == std::string::npos || ue == std::string::npos) continue;
        return "https://dl.google.com/android/repository/" + arc.substr(u + 5, ue - u - 5);
    }
    return "";
}

bool stableVersion(const std::string& v) {
    for (const char* bad : {"rc", "beta", "alpha", "preview", "-"})
        if (v.find(bad) != std::string::npos) return false;
    return !v.empty() && std::isdigit((unsigned char)v[0]);
}

bool versionLess2(const std::string& a, const std::string& b) {
    auto parts = [](const std::string& s) {
        std::vector<long> p;
        std::string cur;
        for (char c : s + ".") {
            if (std::isdigit((unsigned char)c)) cur += c;
            else {
                if (!cur.empty()) p.push_back(std::atol(cur.c_str()));
                cur.clear();
            }
        }
        return p;
    };
    return parts(a) < parts(b);
}

bool setupAndroid(const Opts& o, bool listOnly) {
    title("Android (APK, NDK y emulador) — opcional");
    const AndroidTools& t = androidTools();
    bool complete = !t.sdk.empty() && !t.ndk.empty() && !t.aapt2.empty() && !t.androidJar.empty() && !t.adb.empty() &&
                    (!t.java.empty() || !managedJavaHome().empty());
    if (!t.sdk.empty()) ok("SDK: " + t.sdk);
    if (!t.ndk.empty()) ok("NDK " + t.ndkVersion);
    if (!t.buildToolsVersion.empty()) ok("build-tools " + t.buildToolsVersion);
    if (t.platformApi) ok("plataforma android-" + std::to_string(t.platformApi));
    if (!t.emulator.empty()) ok("emulador");
    if (complete && (!o.emulator || !t.emulator.empty())) {
        if (!t.java.empty() || !managedJavaHome().empty()) ok("Java");
        return true;
    }
    if (listOnly) {
        miss("faltan componentes: ejecuta 'faset setup android'");
        return false;
    }

    std::string javaHome;
    if (!ensureJava(o, false, javaHome)) return false;
    if (!javaHome.empty()) setEnv("JAVA_HOME", javaHome);

    fs::path sdk = t.sdk.empty() ? existingSdk() : fs::path(t.sdk);
    std::error_code ec;
    fs::create_directories(sdk, ec);
    if (!pathOk(sdkmanagerPath(sdk))) {
        std::printf("  Se descargarán las Android cmdline-tools en %s\n", sdk.string().c_str());
        if (!ask(o, "  ¿Continuar?", true)) return false;
        std::string url = cmdlineToolsUrl();
        if (url.empty()) {
            std::fprintf(stderr, "faset: no se encontró la descarga de cmdline-tools en el repositorio de Google\n");
            return false;
        }
        if (!installArchive(url, sdk / "cmdline-tools" / "latest", javaHome)) return false;
        if (!pathOk(sdkmanagerPath(sdk))) return false;
        ok("cmdline-tools");
    }
    std::string sm = sdkmanagerPath(sdk).string();
    std::string root = "--sdk_root=" + sdk.string();

    // Licencias: el usuario las acepta (con --yes se aceptan todas sin preguntar).
    std::printf("  Licencias del SDK de Android (https://developer.android.com/studio/terms):\n");
    if (o.dryRun) {
        std::printf("  (--dry-run: no se aceptan)\n");
    } else if (o.yes) {
        fs::path answers = fs::path(fasetDataDir()) / "downloads" / "licencias.txt";
        fs::create_directories(answers.parent_path(), ec);
        std::ofstream f(answers);
        for (int i = 0; i < 40; i++) f << "y\n";
        f.close();
        run({sm, root, "--licenses"}, "< " + quote(answers.string()));
    } else {
        run({sm, root, "--licenses"});
    }

    // Versiones más recientes y estables de cada paquete. Las cmdline-tools antiguas separan con ';'
    // (ndk;30.0.1) y las nuevas con '/' (ndk/30.0.1, platforms/android-37.0): se aceptan las dos y se
    // instala con el mismo nombre que da la lista. La primera ejecución descarga su CLI y puede no listar.
    std::string list;
    for (int attempt = 0; attempt < 2 && list.find("ndk") == std::string::npos; attempt++) capture({sm, root, "--list"}, list);
    auto numeric = [](const std::string& v) {  // 36, 37.0, 37.1 (sin -ext, -beta, rc...)
        if (v.empty() || !std::isdigit((unsigned char)v[0])) return false;
        int dots = 0;
        for (char c : v) {
            if (c == '.') dots++;
            else if (!std::isdigit((unsigned char)c)) return false;
        }
        return dots <= 1;
    };
    std::string bt, ndk, plat, platV, sysImg, sysImgV;
    std::string img = std::string(kArch) == "arm64" ? "arm64-v8a" : "x86_64";
    std::istringstream ls(list);
    std::string line;
    while (std::getline(ls, line)) {
        size_t a = line.find_first_not_of(" \t");
        if (a == std::string::npos) continue;
        std::string id = line.substr(a, line.find_first_of(" \t|", a) - a);
        std::string n = id;
        std::replace(n.begin(), n.end(), '/', ';');
        std::vector<std::string> part;
        std::stringstream ps(n);
        for (std::string x; std::getline(ps, x, ';');) part.push_back(x);
        if (part.size() == 2 && part[0] == "build-tools" && stableVersion(part[1])) {
            if (bt.empty() || versionLess2(bt.substr(bt.find_first_of(";/") + 1), part[1])) bt = id;
        } else if (part.size() == 2 && part[0] == "ndk" && stableVersion(part[1])) {
            if (ndk.empty() || versionLess2(ndk.substr(ndk.find_first_of(";/") + 1), part[1])) ndk = id;
        } else if (part.size() == 2 && part[0] == "platforms" && part[1].rfind("android-", 0) == 0 && numeric(part[1].substr(8))) {
            if (platV.empty() || versionLess2(platV, part[1].substr(8))) plat = id, platV = part[1].substr(8);
        } else if (part.size() == 4 && part[0] == "system-images" && part[1].rfind("android-", 0) == 0 && part[2] == "google_apis" &&
                   part[3] == img && numeric(part[1].substr(8))) {
            if (sysImgV.empty() || versionLess2(sysImgV, part[1].substr(8))) sysImg = id, sysImgV = part[1].substr(8);
        }
    }
    int sysImgApi = std::atoi(sysImgV.c_str());
    if (bt.empty() || ndk.empty() || plat.empty()) {
        std::fprintf(stderr, "faset: sdkmanager no devolvió la lista de paquetes (¿sin conexión?)\n");
        return false;
    }
    std::vector<std::string> pkgs = {"platform-tools", bt, plat, ndk};
    if (o.emulator) {
        pkgs.push_back("emulator");
        if (!sysImg.empty()) pkgs.push_back(sysImg);
    }
    std::printf("  Paquetes: ");
    for (const std::string& p : pkgs) std::printf("%s  ", p.c_str());
    std::printf("\n  (el NDK ocupa ~2 GB y la imagen del emulador ~1,5 GB)\n");
    if (o.dryRun) {
        std::printf("  --dry-run: no se instala nada más.\n");
        return true;
    }
    if (!ask(o, "  ¿Instalarlos?", true)) return false;
    std::vector<std::string> cmd = {sm, root, "--install"};
    cmd.insert(cmd.end(), pkgs.begin(), pkgs.end());
    if (run(cmd) != 0) return false;

    // Un emulador listo para 'faset run' / FasetStudio.
    if (o.emulator && !sysImg.empty()) {
        std::string avds;
        fs::path emu = sdk / "emulator" / (std::string("emulator") + kExe);
        capture({emu.string(), "-list-avds"}, avds);
        if (avds.find_first_not_of(" \r\n") == std::string::npos) {
            std::string name = "Faset_API_" + std::to_string(sysImgApi);
            fs::path answers = fs::path(fasetDataDir()) / "downloads" / "avd.txt";
            std::ofstream(answers) << "no\n";
            run({avdmanagerPath(sdk).string(), "create", "avd", "-n", name, "-k", sysImg, "-d", "pixel_7"}, "< " + quote(answers.string()));
            fs::remove(answers, ec);
            ok("emulador " + name + " (faset android emulator " + name + ")");
        }
    }
    std::printf("\n  Android listo. Si el SDK no está en %s, define ANDROID_HOME=%s\n", defaultSdk().string().c_str(),
                sdk.string().c_str());
    return true;
}

void usage() {
    std::printf(
        "Uso: faset setup [módulos...] [opciones]\n\n"
        "Instala lo que necesita cada plataforma. Sin módulos instala el del sistema actual (%s).\n\n"
        "Módulos:\n"
        "  linux        compilador de C y bibliotecas de FasetStudio (gestor de paquetes del sistema)\n"
        "  windows      toolchain llvm-mingw (en Windows: programas nativos; en Linux: compilación cruzada)\n"
        "  android      JDK, SDK (cmdline-tools, platform-tools, build-tools, plataforma), NDK y emulador\n"
        "  multimedia   WebKitGTK, GStreamer y PulseAudio para WebView, VideoPlayer y std.audio (Linux)\n"
        "  all          todos los anteriores que tengan sentido en este sistema\n\n"
        "Opciones:\n"
        "  --list         muestra qué está instalado, sin instalar nada\n"
        "  --yes, -y      no pregunta y acepta las licencias del SDK de Android\n"
        "  --no-emulator  android: sin emulador ni imagen del sistema\n"
        "  --dry-run      android: prepara Java y sdkmanager y muestra los paquetes, sin instalarlos\n",
        kHost);
}

}  // namespace

std::string fasetDataDir() {
#if defined(_WIN32)
    std::string base = env("LOCALAPPDATA");
    return base.empty() ? "" : (fs::path(base) / "Faset").string();
#else
    std::string xdg = env("XDG_DATA_HOME");
    if (!xdg.empty()) return (fs::path(xdg) / "faset").string();
    std::string home = env("HOME");
    return home.empty() ? "" : (fs::path(home) / ".local" / "share" / "faset").string();
#endif
}

std::string managedMingwCompiler(const std::string& arch) {
    std::string dir = fasetDataDir();
    if (dir.empty()) return "";
    std::string triple = arch == "x86" ? "i686-w64-mingw32" : arch == "arm64" ? "aarch64-w64-mingw32" : "x86_64-w64-mingw32";
    fs::path cc = fs::path(dir) / "toolchains" / "llvm-mingw" / "bin" / (triple + "-clang" + kExe);
    return pathOk(cc) ? cc.string() : "";
}

std::string managedJavaHome() {
    std::string dir = fasetDataDir();
    if (dir.empty()) return "";
    fs::path h = fs::path(dir) / "jdk";
    if (pathOk(h / "bin" / (std::string("java") + kExe))) return h.string();
    return "";
}

int cmdSetup(const std::vector<std::string>& args) {
    Opts o;
    bool listOnly = false;
    std::vector<std::string> mods;
    for (const std::string& a : args) {
        if (a == "--list" || a == "-l") listOnly = true;
        else if (a == "--yes" || a == "-y") o.yes = true;
        else if (a == "--no-emulator") o.emulator = false;
        else if (a == "--dry-run") o.dryRun = true;
        else if (a == "-h" || a == "--help") {
            usage();
            return 0;
        } else if (a == "linux" || a == "windows" || a == "android" || a == "multimedia" || a == "all") mods.push_back(a);
        else {
            std::fprintf(stderr, "faset setup: módulo u opción desconocida '%s'\n\n", a.c_str());
            usage();
            return 2;
        }
    }
    if (std::find(mods.begin(), mods.end(), "all") != mods.end()) {
        mods.clear();
        if (std::string(kHost) == "linux") mods = {"linux", "multimedia", "windows", "android"};
        else mods = {"windows", "android"};
    }
    if (mods.empty()) {
        if (listOnly) mods = std::string(kHost) == "linux" ? std::vector<std::string>{"linux", "multimedia", "windows", "android"}
                                                           : std::vector<std::string>{"windows", "android"};
        else mods = {kHost};
    }
    if (fasetDataDir().empty()) {
        std::fprintf(stderr, "faset setup: no se pudo determinar la carpeta del usuario (HOME / LOCALAPPDATA)\n");
        return 1;
    }
    std::printf("faset setup (%s-%s)\n", kHost, kArch);
    int failed = 0;
    for (const std::string& m : mods) {
        bool good = m == "linux"        ? setupLinux(o, listOnly)
                    : m == "windows"    ? setupWindows(o, listOnly)
                    : m == "android"    ? setupAndroid(o, listOnly)
                    : m == "multimedia" ? setupMultimedia(o, listOnly)
                                        : false;
        if (!good) failed++;
    }
    std::printf("\n");
    if (listOnly) return 0;
    if (failed) {
        std::printf("Algún módulo no quedó completo (%d). Revisa los mensajes de arriba.\n", failed);
        return 1;
    }
    std::printf("Todo listo. Comprueba con 'faset doctor'.\n");
    return 0;
}

bool fetchUrlText(const std::string& url, std::string& out) { return fetchText(url, out); }
