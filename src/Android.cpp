#include "Android.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <sstream>
#include <thread>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#define popen _popen
#define pclose _pclose
#else
#include <sys/wait.h>
#endif

#include "Frontend.h"

namespace fs = std::filesystem;

namespace {

#if defined(_WIN32)
const char* const kExe = ".exe";
const char* const kBat = ".bat";
#else
const char* const kExe = "";
const char* const kBat = "";
#endif

// ------------------------------------------------------------------ procesos

std::string env(const char* name) {
    const char* v = std::getenv(name);
    return v ? v : "";
}

void setEnv(const std::string& name, const std::string& value) {
#if defined(_WIN32)
    _putenv_s(name.c_str(), value.c_str());
#else
    setenv(name.c_str(), value.c_str(), 1);
#endif
}

std::string homeDir() {
    std::string h = env("HOME");
    return h.empty() ? env("USERPROFILE") : h;
}

std::string quote(const std::string& s) {
#if defined(_WIN32)
    return "\"" + s + "\"";
#else
    std::string r = "'";
    for (char c : s) r += c == '\'' ? std::string("'\\''") : std::string(1, c);
    return r + "'";
#endif
}

std::string commandLine(const std::vector<std::string>& args) {
    std::string cmd;
    for (size_t i = 0; i < args.size(); i++) cmd += (i ? " " : "") + quote(args[i]);
    return cmd;
}

std::string shellWrap(std::string cmd) {
#if defined(_WIN32)
    cmd = "\"" + cmd + "\"";  // cmd.exe elimina las comillas exteriores
#endif
    return cmd;
}

int exitCode(int r) {
#if !defined(_WIN32)
    if (r != -1 && WIFEXITED(r)) r = WEXITSTATUS(r);
#endif
    return r;
}

int run(const std::vector<std::string>& args, bool verbose, bool quiet = false) {
    std::string cmd = commandLine(args);
    if (verbose) std::fprintf(stderr, "$ %s\n", cmd.c_str());
#if defined(_WIN32)
    if (quiet) cmd += " >NUL 2>&1";
#else
    if (quiet) cmd += " >/dev/null 2>&1";
#endif
    std::fflush(stdout);
    return exitCode(std::system(shellWrap(cmd).c_str()));
}

// Ejecuta y devuelve la salida (stdout + stderr) línea a línea a 'onLine'.
int stream(const std::vector<std::string>& args, bool verbose, const std::function<void(const std::string&)>& onLine) {
    std::string cmd = commandLine(args) + " 2>&1";
    if (verbose) std::fprintf(stderr, "$ %s\n", cmd.c_str());
    std::fflush(stdout);
    FILE* p = popen(shellWrap(cmd).c_str(), "r");
    if (!p) return -1;
    std::string line;
    char buf[4096];
    while (std::fgets(buf, sizeof buf, p)) {
        line += buf;
        if (!line.empty() && line.back() == '\n') {
            while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) line.pop_back();
            onLine(line);
            line.clear();
        }
    }
    if (!line.empty()) onLine(line);
    return exitCode(pclose(p));
}

int capture(const std::vector<std::string>& args, std::string& out, bool verbose = false) {
    out.clear();
    return stream(args, verbose, [&](const std::string& l) { out += l + "\n"; });
}

std::string trim(std::string s) {
    while (!s.empty() && isspace((unsigned char)s.back())) s.pop_back();
    size_t a = 0;
    while (a < s.size() && isspace((unsigned char)s[a])) a++;
    return s.substr(a);
}

bool writeText(const fs::path& path, const std::string& data) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << data;
    return (bool)f;
}

bool readBinary(const fs::path& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

// ------------------------------------------------------------------ versiones

std::vector<long> versionParts(const std::string& s) {
    std::vector<long> parts;
    std::string cur;
    for (char c : s + ".") {
        if (isdigit((unsigned char)c)) cur += c;
        else {
            if (!cur.empty()) parts.push_back(std::atol(cur.c_str()));
            cur.clear();
        }
    }
    return parts;
}

bool versionLess(const std::string& a, const std::string& b) { return versionParts(a) < versionParts(b); }

// Subcarpeta con la versión más alta (que cumpla 'ok').
std::string newestSubdir(const fs::path& dir, const std::function<bool(const fs::path&)>& ok) {
    std::error_code ec;
    std::string best;
    if (!fs::is_directory(dir, ec)) return "";
    for (auto& e : fs::directory_iterator(dir, ec)) {
        if (!e.is_directory(ec) || !ok(e.path())) continue;
        std::string n = e.path().filename().string();
        if (best.empty() || versionLess(best, n)) best = n;
    }
    return best;
}

bool pathExists(const fs::path& p) {
    std::error_code ec;
    return fs::exists(p, ec);
}

std::vector<fs::path> sdkCandidates() {
    std::vector<fs::path> c;
    for (const char* var : {"ANDROID_HOME", "ANDROID_SDK_ROOT"})
        if (!env(var).empty()) c.emplace_back(env(var));
    // Un NDK en <SDK>/ndk/<versión> también delata dónde está el SDK.
    for (const char* var : {"ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK"})
        if (!env(var).empty()) {
            fs::path p = fs::path(env(var)).lexically_normal();
            if (p.filename().empty()) p = p.parent_path();
            if (p.parent_path().filename() == "ndk") c.push_back(p.parent_path().parent_path());
        }
    std::string home = homeDir();
    if (!home.empty()) {
        c.push_back(fs::path(home) / "Android" / "Sdk");
        c.push_back(fs::path(home) / "AppData" / "Local" / "Android" / "Sdk");
        c.push_back(fs::path(home) / "Library" / "Android" / "sdk");
    }
    if (!env("LOCALAPPDATA").empty()) c.push_back(fs::path(env("LOCALAPPDATA")) / "Android" / "Sdk");
    c.emplace_back("/opt/android-sdk");
    c.emplace_back("/usr/lib/android-sdk");
    return c;
}

std::string findSdk() {
    for (const fs::path& p : sdkCandidates()) {
        if (pathExists(p / "platform-tools") || pathExists(p / "build-tools") || pathExists(p / "platforms") || pathExists(p / "ndk"))
            return p.lexically_normal().string();
    }
    return "";
}

bool isNdk(const fs::path& p) { return pathExists(p / "toolchains" / "llvm" / "prebuilt"); }

void findJava(AndroidTools& t) {
    auto javaIn = [](const fs::path& home) { return home / "bin" / (std::string("java") + kExe); };
    std::vector<fs::path> homes;
    if (!env("JAVA_HOME").empty()) homes.emplace_back(env("JAVA_HOME"));
    std::string onPath = findProgram("java");
    std::string home = homeDir();
    std::vector<fs::path> studio;
    if (!home.empty()) {
        studio.push_back(fs::path(home) / "android-studio" / "jbr");
        studio.push_back(fs::path(home) / ".local" / "share" / "JetBrains" / "Toolbox" / "apps" / "android-studio" / "jbr");
    }
    studio.emplace_back("/opt/android-studio/jbr");
    studio.emplace_back("/usr/local/android-studio/jbr");
    studio.emplace_back("/snap/android-studio/current/jbr");
    studio.emplace_back("/Applications/Android Studio.app/Contents/jbr/Contents/Home");
    studio.emplace_back("C:/Program Files/Android/Android Studio/jbr");
    if (!env("LOCALAPPDATA").empty()) studio.push_back(fs::path(env("LOCALAPPDATA")) / "Programs" / "Android Studio" / "jbr");
    for (const fs::path& h : homes)
        if (pathExists(javaIn(h))) {
            t.javaHome = h.string();
            t.java = javaIn(h).string();
            break;
        }
    if (t.java.empty() && !onPath.empty()) t.java = onPath;
    if (t.java.empty())
        for (const fs::path& h : studio)
            if (pathExists(javaIn(h))) {
                t.javaHome = h.string();
                t.java = javaIn(h).string();
                break;
            }
    if (!t.javaHome.empty()) {
        fs::path kt = fs::path(t.javaHome) / "bin" / (std::string("keytool") + kExe);
        if (pathExists(kt)) t.keytool = kt.string();
    }
    if (t.keytool.empty()) t.keytool = findProgram("keytool");
}

// Las herramientas de Java (apksigner, keytool) usan el JDK encontrado aunque no esté en el PATH.
void prepareJavaEnv() {
    const AndroidTools& t = androidTools();
    static bool done = false;
    if (done || t.javaHome.empty()) return;
    done = true;
    setEnv("JAVA_HOME", t.javaHome);
#if defined(_WIN32)
    setEnv("PATH", (fs::path(t.javaHome) / "bin").string() + ";" + env("PATH"));
#else
    setEnv("PATH", (fs::path(t.javaHome) / "bin").string() + ":" + env("PATH"));
#endif
}

std::string xmlEscape(const std::string& s) {
    std::string r;
    for (char c : s) {
        if (c == '&') r += "&amp;";
        else if (c == '<') r += "&lt;";
        else if (c == '>') r += "&gt;";
        else if (c == '"') r += "&quot;";
        else if (c == '\'') r += "&apos;";
        else r += c;
    }
    return r;
}

// ------------------------------------------------------------------ ZIP (para añadir lib/<abi>/*.so)

uint32_t crc32(const std::string& data) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (unsigned char b : data) c = table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

struct ZipEntry {
    std::string name;
    uint16_t method = 0, time = 0, date = 0x21;  // 1980-01-01
    uint32_t crc = 0, csize = 0, usize = 0;
    std::string data;  // datos tal cual (comprimidos si method = 8)
};

uint16_t rd16(const std::string& s, size_t o) { return (uint16_t)((unsigned char)s[o] | ((unsigned char)s[o + 1] << 8)); }
uint32_t rd32(const std::string& s, size_t o) { return rd16(s, o) | ((uint32_t)rd16(s, o + 2) << 16); }
void wr16(std::string& s, uint16_t v) {
    s += (char)(v & 0xFF);
    s += (char)(v >> 8);
}
void wr32(std::string& s, uint32_t v) {
    wr16(s, (uint16_t)(v & 0xFFFF));
    wr16(s, (uint16_t)(v >> 16));
}

bool readZip(const fs::path& path, std::vector<ZipEntry>& out, std::string& err) {
    std::string z;
    if (!readBinary(path, z)) {
        err = "no se puede leer " + path.string();
        return false;
    }
    if (z.size() < 22) {
        err = path.string() + " no es un ZIP";
        return false;
    }
    size_t eocd = std::string::npos;
    for (size_t i = z.size() - 22 + 1; i-- > 0 && z.size() - i < 65557;)
        if (rd32(z, i) == 0x06054b50) {
            eocd = i;
            break;
        }
    if (eocd == std::string::npos) {
        err = path.string() + " no es un ZIP válido";
        return false;
    }
    uint16_t count = rd16(z, eocd + 10);
    size_t p = rd32(z, eocd + 16);
    for (int k = 0; k < count; k++) {
        if (p + 46 > z.size() || rd32(z, p) != 0x02014b50) {
            err = path.string() + ": directorio central dañado";
            return false;
        }
        ZipEntry e;
        e.method = rd16(z, p + 10);
        e.time = rd16(z, p + 12);
        e.date = rd16(z, p + 14);
        e.crc = rd32(z, p + 16);
        e.csize = rd32(z, p + 20);
        e.usize = rd32(z, p + 24);
        uint16_t nlen = rd16(z, p + 28), xlen = rd16(z, p + 30), clen = rd16(z, p + 32);
        size_t lho = rd32(z, p + 42);
        e.name = z.substr(p + 46, nlen);
        if (lho + 30 > z.size()) {
            err = path.string() + ": entrada dañada";
            return false;
        }
        size_t data = lho + 30 + rd16(z, lho + 26) + rd16(z, lho + 28);
        if (data + e.csize > z.size()) {
            err = path.string() + ": entrada dañada";
            return false;
        }
        e.data = z.substr(data, e.csize);
        out.push_back(std::move(e));
        p += 46 + nlen + xlen + clen;
    }
    return true;
}

bool writeZip(const fs::path& path, const std::vector<ZipEntry>& entries) {
    std::string z, cd;
    for (const ZipEntry& e : entries) {
        uint32_t off = (uint32_t)z.size();
        wr32(z, 0x04034b50);
        wr16(z, 20);
        wr16(z, 0x0800);  // nombres en UTF-8
        wr16(z, e.method);
        wr16(z, e.time);
        wr16(z, e.date);
        wr32(z, e.crc);
        wr32(z, e.csize);
        wr32(z, e.usize);
        wr16(z, (uint16_t)e.name.size());
        wr16(z, 0);
        z += e.name;
        z += e.data;

        wr32(cd, 0x02014b50);
        wr16(cd, 20);
        wr16(cd, 20);
        wr16(cd, 0x0800);
        wr16(cd, e.method);
        wr16(cd, e.time);
        wr16(cd, e.date);
        wr32(cd, e.crc);
        wr32(cd, e.csize);
        wr32(cd, e.usize);
        wr16(cd, (uint16_t)e.name.size());
        wr16(cd, 0);
        wr16(cd, 0);
        wr16(cd, 0);
        wr16(cd, 0);
        wr32(cd, 0);
        wr32(cd, off);
        cd += e.name;
    }
    uint32_t cdOff = (uint32_t)z.size();
    z += cd;
    wr32(z, 0x06054b50);
    wr16(z, 0);
    wr16(z, 0);
    wr16(z, (uint16_t)entries.size());
    wr16(z, (uint16_t)entries.size());
    wr32(z, (uint32_t)cd.size());
    wr32(z, cdOff);
    wr16(z, 0);
    return writeText(path, z);
}

// ------------------------------------------------------------------ adb

struct Device {
    std::string serial, state, model;
};

std::vector<Device> listDevices() {
    std::vector<Device> devs;
    const AndroidTools& t = androidTools();
    if (t.adb.empty()) return devs;
    std::string out;
    capture({t.adb, "devices", "-l"}, out);
    std::stringstream ss(out);
    std::string line;
    while (std::getline(ss, line)) {
        line = trim(line);
        if (line.empty() || line[0] == '*' || line.rfind("List of devices", 0) == 0) continue;
        std::stringstream ls(line);
        Device d;
        ls >> d.serial >> d.state;
        if (d.state.empty()) continue;
        std::string tok;
        while (ls >> tok)
            if (tok.rfind("model:", 0) == 0) d.model = tok.substr(6);
        if (d.model.empty()) d.model = "-";
        devs.push_back(d);
    }
    return devs;
}

std::vector<std::string> listAvds() {
    std::vector<std::string> avds;
    std::vector<fs::path> dirs;
    if (!env("ANDROID_AVD_HOME").empty()) dirs.emplace_back(env("ANDROID_AVD_HOME"));
    if (!env("ANDROID_USER_HOME").empty()) dirs.push_back(fs::path(env("ANDROID_USER_HOME")) / "avd");
    if (!homeDir().empty()) dirs.push_back(fs::path(homeDir()) / ".android" / "avd");
    std::error_code ec;
    for (const fs::path& d : dirs) {
        if (!fs::is_directory(d, ec)) continue;
        for (auto& e : fs::directory_iterator(d, ec))
            if (e.path().extension() == ".ini") {
                std::string n = e.path().stem().string();
                if (std::find(avds.begin(), avds.end(), n) == avds.end()) avds.push_back(n);
            }
        if (!avds.empty()) break;
    }
    if (avds.empty() && !androidTools().emulator.empty()) {
        std::string out;
        capture({androidTools().emulator, "-list-avds"}, out);
        std::stringstream ss(out);
        std::string line;
        while (std::getline(ss, line)) {
            line = trim(line);
            if (!line.empty() && line.find(' ') == std::string::npos && line.rfind("INFO", 0) != 0) avds.push_back(line);
        }
    }
    std::sort(avds.begin(), avds.end());
    return avds;
}

std::vector<std::string> adbBase(const std::string& serial) {
    std::vector<std::string> a = {androidTools().adb};
    if (!serial.empty()) {
        a.push_back("-s");
        a.push_back(serial);
    }
    return a;
}

std::string adbShell(const std::string& serial, const std::vector<std::string>& cmd) {
    std::vector<std::string> a = adbBase(serial);
    a.push_back("shell");
    a.insert(a.end(), cmd.begin(), cmd.end());
    std::string out;
    capture(a, out);
    return trim(out);
}

// Dispositivo a usar: el indicado, ANDROID_SERIAL o el primero conectado.
bool pickDevice(std::string& serial, std::string& err) {
    if (androidTools().adb.empty()) {
        err = "no se encontró adb (instala 'platform-tools' del SDK de Android)";
        return false;
    }
    if (serial.empty()) serial = env("ANDROID_SERIAL");
    std::vector<Device> devs = listDevices();
    if (!serial.empty()) {
        for (const Device& d : devs)
            if (d.serial == serial) {
                if (d.state != "device") {
                    err = "el dispositivo '" + serial + "' está en estado '" + d.state + "'";
                    return false;
                }
                return true;
            }
        err = "no está conectado el dispositivo '" + serial + "' (mira 'faset android devices')";
        return false;
    }
    for (const Device& d : devs)
        if (d.state == "device") {
            serial = d.serial;
            int n = 0;
            for (const Device& o : devs) n += o.state == "device";
            if (n > 1) std::fprintf(stderr, "faset: hay %d dispositivos; se usa %s (elige otro con --device)\n", n, serial.c_str());
            return true;
        }
    err = "no hay ningún dispositivo Android conectado; conecta uno o arranca un emulador con 'faset android emulator <avd>'";
    return false;
}

void sleepMs(int ms) { std::this_thread::sleep_for(std::chrono::milliseconds(ms)); }

bool waitForBoot(const std::string& serial, int timeoutSec) {
    auto start = std::chrono::steady_clock::now();
    auto elapsed = [&] {
        return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now() - start).count();
    };
    bool online = false;
    while (elapsed() < timeoutSec) {
        if (!online) {
            for (const Device& d : listDevices())
                if (d.serial == serial && d.state == "device") online = true;
        }
        static const std::vector<std::string> bootProp = {"getprop", "sys.boot_completed"};
        if (online && adbShell(serial, bootProp) == "1") return true;
        sleepMs(1000);
    }
    return false;
}

}  // namespace

// ------------------------------------------------------------------ detección

std::string findAndroidNdk() {
    for (const char* var : {"ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK"}) {
        std::string v = env(var);
        if (!v.empty() && isNdk(v)) return fs::path(v).lexically_normal().string();
    }
    for (const fs::path& sdk : sdkCandidates()) {
        std::string v = newestSubdir(sdk / "ndk", isNdk);
        if (!v.empty()) return (sdk / "ndk" / v).lexically_normal().string();
        if (isNdk(sdk / "ndk-bundle")) return (sdk / "ndk-bundle").lexically_normal().string();
    }
    return "";
}

const AndroidTools& androidTools() {
    static AndroidTools t;
    static bool done = false;
    if (done) return t;
    done = true;
    t.sdk = findSdk();
    t.ndk = findAndroidNdk();
    if (!t.ndk.empty()) {
        std::ifstream f(fs::path(t.ndk) / "source.properties");
        std::string line;
        while (std::getline(f, line))
            if (line.rfind("Pkg.Revision", 0) == 0) t.ndkVersion = trim(line.substr(line.find('=') + 1));
        if (t.ndkVersion.empty()) t.ndkVersion = fs::path(t.ndk).filename().string();
    }
    if (!t.sdk.empty()) {
        fs::path sdk(t.sdk);
        t.buildToolsVersion = newestSubdir(sdk / "build-tools", [](const fs::path& p) {
            return pathExists(p / (std::string("aapt2") + kExe));
        });
        if (!t.buildToolsVersion.empty()) {
            fs::path bt = sdk / "build-tools" / t.buildToolsVersion;
            t.buildTools = bt.string();
            t.aapt2 = (bt / (std::string("aapt2") + kExe)).string();
            if (pathExists(bt / (std::string("zipalign") + kExe))) t.zipalign = (bt / (std::string("zipalign") + kExe)).string();
            if (pathExists(bt / (std::string("apksigner") + kBat))) t.apksigner = (bt / (std::string("apksigner") + kBat)).string();
        }
        // platforms/android-36, android-36.1... (se ignoran las vistas previas con nombre).
        std::string best;
        std::error_code ec;
        for (auto& e : fs::directory_iterator(sdk / "platforms", ec)) {
            std::string n = e.path().filename().string();
            if (n.rfind("android-", 0) != 0 || !isdigit((unsigned char)n[8]) || !pathExists(e.path() / "android.jar")) continue;
            if (best.empty() || versionLess(best, n)) best = n;
        }
        if (!best.empty()) {
            t.platformDir = (sdk / "platforms" / best).string();
            t.androidJar = (sdk / "platforms" / best / "android.jar").string();
            t.platformApi = std::atoi(best.c_str() + 8);
        }
        fs::path adb = sdk / "platform-tools" / (std::string("adb") + kExe);
        if (pathExists(adb)) t.adb = adb.string();
        fs::path emu = sdk / "emulator" / (std::string("emulator") + kExe);
        if (pathExists(emu)) t.emulator = emu.string();
    }
    if (t.adb.empty()) t.adb = findProgram("adb");
    if (t.emulator.empty()) t.emulator = findProgram("emulator");
    findJava(t);
    return t;
}

std::string androidTriple(const std::string& arch) {
    if (arch == "arm64") return "aarch64-linux-android";
    if (arch == "armv7") return "armv7a-linux-androideabi";
    if (arch == "x86") return "i686-linux-android";
    return "x86_64-linux-android";
}

std::string androidAbiToArch(const std::string& abi) {
    if (abi == "arm64-v8a" || abi == "arm64" || abi == "aarch64") return "arm64";
    if (abi == "armeabi-v7a" || abi == "armv7" || abi == "arm") return "armv7";
    if (abi == "x86" || abi == "i686") return "x86";
    if (abi == "x86_64" || abi == "x64") return "x86_64";
    return "";
}

std::string androidArchToAbi(const std::string& arch) {
    if (arch == "arm64") return "arm64-v8a";
    if (arch == "armv7") return "armeabi-v7a";
    if (arch == "x86") return "x86";
    return "x86_64";
}

// ------------------------------------------------------------------ APK

bool androidPackageApk(const ApkSpec& s, std::string& error) {
    const AndroidTools& t = androidTools();
    if (t.sdk.empty()) {
        error = "no se encontró el SDK de Android (define ANDROID_HOME)";
        return false;
    }
    if (t.aapt2.empty() || t.zipalign.empty() || t.apksigner.empty()) {
        error = "faltan las build-tools del SDK (aapt2, zipalign, apksigner): instala 'build-tools;<versión>' con sdkmanager";
        return false;
    }
    if (t.androidJar.empty()) {
        error = "no hay ninguna plataforma instalada en " + t.sdk + "/platforms (instala 'platforms;android-<n>')";
        return false;
    }
    if (t.java.empty()) {
        error = "apksigner necesita Java: instala un JDK o Android Studio, o define JAVA_HOME";
        return false;
    }
    prepareJavaEnv();
    std::error_code ec;
    fs::path obj(s.objDir);
    fs::create_directories(obj, ec);
    if (fs::path(s.output).has_parent_path()) fs::create_directories(fs::path(s.output).parent_path(), ec);
    int target = s.targetSdk > 0 ? s.targetSdk : t.platformApi;
    if (target < s.minSdk) target = s.minSdk;

    // 1. Manifiesto: NativeActivity sin código Java (hasCode=false) que carga lib<name>.so.
    std::string label = xmlEscape(s.label.empty() ? s.name : s.label);
    std::string m =
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        "<!-- Generado por faset. No editar: usa las propiedades Android* del .fstproj. -->\n"
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"\n"
        "    package=\"" + xmlEscape(s.package) + "\"\n"
        "    android:versionCode=\"" + std::to_string(s.versionCode) + "\"\n"
        "    android:versionName=\"" + xmlEscape(s.versionName) + "\">\n"
        "    <uses-sdk android:minSdkVersion=\"" + std::to_string(s.minSdk) + "\" android:targetSdkVersion=\"" +
        std::to_string(target) + "\" />\n";
    for (const std::string& p : s.permissions)
        m += "    <uses-permission android:name=\"" + xmlEscape(p.find('.') == std::string::npos ? "android.permission." + p : p) + "\" />\n";
    m += "    <application android:label=\"" + label + "\" android:hasCode=\"false\" android:extractNativeLibs=\"false\"" +
         std::string(s.debuggable ? " android:debuggable=\"true\"" : "") +
         std::string(s.icon.empty() ? "" : " android:icon=\"@mipmap/ic_launcher\"") + ">\n"
         "        <activity android:name=\"android.app.NativeActivity\"\n"
         "            android:label=\"" + label + "\"\n"
         "            android:exported=\"true\"\n"
         "            android:theme=\"@android:style/Theme.NoTitleBar.Fullscreen\"\n"
         "            android:windowSoftInputMode=\"adjustResize\"\n" +
         std::string(s.orientation.empty() ? "" : "            android:screenOrientation=\"" + xmlEscape(s.orientation) + "\"\n") +
         "            android:configChanges=\"orientation|screenSize|screenLayout|smallestScreenSize|keyboard|keyboardHidden|navigation|uiMode|density\">\n"
         "            <meta-data android:name=\"android.app.lib_name\" android:value=\"" + xmlEscape(s.name) + "\" />\n"
         "            <intent-filter>\n"
         "                <action android:name=\"android.intent.action.MAIN\" />\n"
         "                <category android:name=\"android.intent.category.LAUNCHER\" />\n"
         "            </intent-filter>\n"
         "        </activity>\n"
         "    </application>\n"
         "</manifest>\n";
    fs::path manifest = obj / "AndroidManifest.xml";
    if (!writeText(manifest, m)) {
        error = "no se pudo escribir " + manifest.string();
        return false;
    }

    // 2. Recursos (solo el icono) y enlace con aapt2.
    std::vector<std::string> link = {t.aapt2, "link", "-o", (obj / "base.apk").string(), "--manifest", manifest.string(),
                                     "-I", t.androidJar};
    if (!s.icon.empty()) {
        if (!pathExists(s.icon)) {
            error = "no existe el icono '" + s.icon + "'";
            return false;
        }
        fs::path res = obj / "res";
        fs::remove_all(res, ec);
        fs::create_directories(res / "mipmap", ec);
        fs::copy_file(s.icon, res / "mipmap" / "ic_launcher.png", fs::copy_options::overwrite_existing, ec);
        fs::path flat = obj / "res.zip";
        if (run({t.aapt2, "compile", "--dir", res.string(), "-o", flat.string()}, s.verbose) != 0) {
            error = "aapt2 compile falló con el icono '" + s.icon + "'";
            return false;
        }
        link.push_back(flat.string());
    }
    if (run(link, s.verbose) != 0) {
        error = "aapt2 link falló (usa -v para ver el comando)";
        return false;
    }

    // 3. Bibliotecas nativas sin comprimir (se cargan directamente desde el APK).
    std::vector<ZipEntry> entries;
    if (!readZip(obj / "base.apk", entries, error)) return false;
    for (const auto& [inApk, local] : s.files) {
        ZipEntry e;
        e.name = inApk;
        if (!readBinary(local, e.data)) {
            error = "no se puede leer " + local;
            return false;
        }
        e.method = 0;
        e.crc = crc32(e.data);
        e.csize = e.usize = (uint32_t)e.data.size();
        entries.erase(std::remove_if(entries.begin(), entries.end(), [&](const ZipEntry& o) { return o.name == e.name; }),
                      entries.end());
        entries.push_back(std::move(e));
    }
    fs::path unaligned = obj / "unaligned.apk", aligned = obj / "aligned.apk";
    if (!writeZip(unaligned, entries)) {
        error = "no se pudo escribir " + unaligned.string();
        return false;
    }

    // 4. Alineación (16 KB para las .so: páginas de 16 KB de Android 15+).
    if (run({t.zipalign, "-f", "-P", "16", "4", unaligned.string(), aligned.string()}, s.verbose) != 0) {
        error = "zipalign falló";
        return false;
    }

    // 5. Firma: la clave indicada o la de depuración (~/.android/debug.keystore, se crea si falta).
    std::string ks = s.keystore, alias = s.keyAlias, storePass = s.storePass, keyPass = s.keyPass;
    if (ks.empty()) {
        fs::path dir = !env("ANDROID_USER_HOME").empty() ? fs::path(env("ANDROID_USER_HOME")) : fs::path(homeDir()) / ".android";
        ks = (dir / "debug.keystore").string();
        alias = "androiddebugkey";
        storePass = keyPass = "android";
        if (!pathExists(ks)) {
            if (t.keytool.empty()) {
                error = "no se encontró keytool para crear la clave de depuración " + ks;
                return false;
            }
            fs::create_directories(dir, ec);
            std::fprintf(stderr, "faset: creando la clave de depuración %s\n", ks.c_str());
            if (run({t.keytool, "-genkeypair", "-keystore", ks, "-storepass", "android", "-alias", "androiddebugkey",
                     "-keypass", "android", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-dname",
                     "CN=Android Debug,O=Android,C=US"},
                    s.verbose, !s.verbose) != 0) {
                error = "keytool no pudo crear " + ks;
                return false;
            }
        }
    }
    if (alias.empty()) alias = "androiddebugkey";
    if (storePass.empty()) storePass = "android";
    if (keyPass.empty()) keyPass = storePass;
    fs::remove(s.output, ec);
    // La salida solo se muestra si falla (la JVM avisa de cosas irrelevantes).
    std::string signLog;
    if (capture({t.apksigner, "sign", "--ks", ks, "--ks-key-alias", alias, "--ks-pass", "pass:" + storePass, "--key-pass",
                 "pass:" + keyPass, "--v4-signing-enabled", "false", "--out", s.output, aligned.string()},
                signLog, s.verbose) != 0 || !pathExists(s.output)) {
        error = signLog + "apksigner no pudo firmar el APK con " + ks;
        return false;
    }
    return true;
}

// ------------------------------------------------------------------ ejecutar

int androidRunApk(const std::string& apk, const std::string& package, const std::string& tag, const std::string& device,
                  bool verbose) {
    std::string serial = device, err;
    if (!pickDevice(serial, err)) {
        std::fprintf(stderr, "faset: error: %s\n", err.c_str());
        return 1;
    }
    const AndroidTools& t = androidTools();
    std::vector<std::string> base = adbBase(serial);
    std::fprintf(stderr, "faset: instalando en %s...\n", serial.c_str());
    auto install = [&](std::string& out) {
        std::vector<std::string> a = base;
        a.insert(a.end(), {"install", "-r", "-t", apk});
        return capture(a, out, verbose);
    };
    std::string out;
    int r = install(out);
    if (r != 0 && (out.find("INSTALL_FAILED_UPDATE_INCOMPATIBLE") != std::string::npos ||
                   out.find("INSTALL_FAILED_VERSION_DOWNGRADE") != std::string::npos)) {
        std::fprintf(stderr, "faset: la versión instalada tiene otra firma; se desinstala\n");
        std::vector<std::string> u = base;
        u.insert(u.end(), {"uninstall", package});
        run(u, verbose, true);
        r = install(out);
    }
    if (r != 0) {
        std::fprintf(stderr, "%sfaset: error: adb install falló\n", out.c_str());
        return 1;
    }

    // El seguimiento se hace en el dispositivo: arranca la actividad, espera su proceso y
    // muestra su logcat hasta que termina; después, los fallos nativos (búfer 'crash').
    // Sin -v solo se ve la salida del programa (su etiqueta) y los errores del proceso.
    std::string filter = verbose ? "" : "'" + tag + ":V' '*:E'";
    std::string script =
        "P=" + package + "\n"
        "T=\"$(date '+%m-%d %H:%M:%S.000')\"\n"
        "am force-stop $P\n"
        "am start -n $P/android.app.NativeActivity >/dev/null || exit 1\n"
        "PID=''; i=0\n"
        "while [ -z \"$PID\" ] && [ $i -lt 200 ]; do PID=$(pidof $P); [ -z \"$PID\" ] && sleep 0.02; i=$((i+1)); done\n"
        "if [ -z \"$PID\" ]; then\n"
        "  logcat -d -v tag -T \"$T\" -s '" + tag + ":*'\n"
        "else\n"
        "  echo \"[faset] $P en ejecución (pid $PID)\"\n"
        "  logcat -v tag --pid=$PID " + filter + " & L=$!\n"
        "  while [ -d /proc/$PID ]; do sleep 0.2; done\n"
        "  sleep 0.5; kill $L 2>/dev/null\n"
        "fi\n"
        "logcat -d -b crash -v tag -T \"$T\"\n";
    std::error_code ec;
    fs::path local = fs::temp_directory_path() / "faset_android_run.sh";
    if (!writeText(local, script)) {
        std::fprintf(stderr, "faset: error: no se pudo escribir %s\n", local.string().c_str());
        return 1;
    }
    std::vector<std::string> push = base;
    push.insert(push.end(), {"push", local.string(), "/data/local/tmp/faset_run.sh"});
    if (run(push, verbose, true) != 0) {
        std::fprintf(stderr, "faset: error: adb push falló\n");
        return 1;
    }
    fs::remove(local, ec);
    std::fprintf(stderr, "faset: iniciando %s (Ctrl+C para dejar de seguir el log)\n", package.c_str());
    int code = 0;
    const std::string marker = "[faset] fin del programa (código ";
    std::vector<std::string> sh = base;
    sh.insert(sh.end(), {"shell", "sh /data/local/tmp/faset_run.sh"});
    int rs = stream(sh, verbose, [&](const std::string& line) {
        if (line.rfind("--------- beginning of", 0) == 0) return;
        size_t k = line.find(marker);
        if (k != std::string::npos) code = std::atoi(line.c_str() + k + marker.size());
        std::fwrite(line.data(), 1, line.size(), stdout);
        std::fputc('\n', stdout);
        std::fflush(stdout);
    });
    (void)t;
    if (rs != 0 && code == 0) code = rs;
    return code;
}

// ------------------------------------------------------------------ faset android ...

static int androidUsage() {
    std::printf(
        "Uso: faset android <comando>\n\n"
        "  devices                         Dispositivos conectados: serie<TAB>estado<TAB>modelo\n"
        "  avds                            Emuladores (AVD) disponibles, uno por línea\n"
        "  emulator <avd> [--headless] [--no-wait] [-- opciones del emulador]\n"
        "                                  Arranca el emulador, espera a que inicie e imprime su serie\n"
        "  logcat [--device s] [--app] [--clear] [-- args]\n"
        "                                  Muestra el logcat (--app: solo la app del proyecto)\n"
        "  stop [--device s]               Detiene la app del proyecto\n"
        "  uninstall [--device s]          Desinstala la app del proyecto\n");
    return 0;
}

int androidCommand(const std::vector<std::string>& args, const std::string& projectPackage) {
    if (args.empty() || args[0] == "help" || args[0] == "--help" || args[0] == "-h") return androidUsage();
    const AndroidTools& t = androidTools();
    const std::string& sub = args[0];
    std::string device, avd;
    bool headless = false, noWait = false, appOnly = false, clear = false;
    std::vector<std::string> extra;
    for (size_t i = 1; i < args.size(); i++) {
        const std::string& a = args[i];
        if (a == "--") {
            extra.assign(args.begin() + (long)i + 1, args.end());
            break;
        } else if ((a == "--device" || a == "-s") && i + 1 < args.size()) device = args[++i];
        else if (a == "--headless") headless = true;
        else if (a == "--no-wait") noWait = true;
        else if (a == "--app") appOnly = true;
        else if (a == "--clear" || a == "-c") clear = true;
        else if (!a.empty() && a[0] == '-') extra.push_back(a);
        else if (avd.empty()) avd = a;
        else extra.push_back(a);
    }
    if (sub != "avds" && sub != "emulator" && t.adb.empty()) {
        std::fprintf(stderr, "faset: error: no se encontró adb (instala 'platform-tools' del SDK de Android)\n");
        return 1;
    }

    if (sub == "devices") {
        for (const Device& d : listDevices()) std::printf("%s\t%s\t%s\n", d.serial.c_str(), d.state.c_str(), d.model.c_str());
        return 0;
    }
    if (sub == "avds") {
        for (const std::string& a : listAvds()) std::printf("%s\n", a.c_str());
        return 0;
    }
    if (sub == "emulator") {
        if (avd.empty()) {
            std::fprintf(stderr, "uso: faset android emulator <avd> [--headless] [--no-wait]\n");
            return 1;
        }
        if (t.emulator.empty()) {
            std::fprintf(stderr, "faset: error: no se encontró el emulador (instala 'emulator' con sdkmanager)\n");
            return 1;
        }
        std::vector<Device> devs = listDevices();
        // ¿Ya está en marcha?
        for (const Device& d : devs)
            if (d.serial.rfind("emulator-", 0) == 0) {
                std::string out;
                capture({t.adb, "-s", d.serial, "emu", "avd", "name"}, out);
                if (trim(out.substr(0, out.find('\n'))) == avd) {
                    if (!noWait && !waitForBoot(d.serial, 300)) {
                        std::fprintf(stderr, "faset: error: %s no terminó de arrancar\n", d.serial.c_str());
                        return 1;
                    }
                    std::printf("%s\n", d.serial.c_str());
                    return 0;
                }
            }
        int port = 5554;
        for (; port < 5700; port += 2) {
            bool used = false;
            for (const Device& d : devs) used |= d.serial == "emulator-" + std::to_string(port);
            if (!used) break;
        }
        std::string serial = "emulator-" + std::to_string(port);
        std::vector<std::string> cmd = {t.emulator, "-avd", avd, "-port", std::to_string(port)};
        if (headless) cmd.insert(cmd.end(), {"-no-window", "-no-audio", "-no-boot-anim"});
        cmd.insert(cmd.end(), extra.begin(), extra.end());
        std::string line = commandLine(cmd);
#if defined(_WIN32)
        line = "start \"\" /B " + line + " >NUL 2>&1";
#else
        line = "nohup " + line + " >/dev/null 2>&1 &";
#endif
        std::fprintf(stderr, "faset: arrancando %s en %s...\n", avd.c_str(), serial.c_str());
        if (std::system(shellWrap(line).c_str()) != 0) std::fprintf(stderr, "faset: aviso: no se pudo lanzar el emulador\n");
        if (!noWait) {
            if (!waitForBoot(serial, 300)) {
                std::fprintf(stderr, "faset: error: el emulador no arrancó en 5 minutos\n");
                return 1;
            }
            std::fprintf(stderr, "faset: %s listo\n", serial.c_str());
        }
        std::printf("%s\n", serial.c_str());
        return 0;
    }
    if (sub == "logcat" || sub == "stop" || sub == "uninstall") {
        std::string err;
        if (!pickDevice(device, err)) {
            std::fprintf(stderr, "faset: error: %s\n", err.c_str());
            return 1;
        }
        std::vector<std::string> base = adbBase(device);
        if ((sub != "logcat" || appOnly) && projectPackage.empty()) {
            std::fprintf(stderr, "faset: error: '%s' necesita un proyecto (.fstproj) en la carpeta actual\n", sub.c_str());
            return 1;
        }
        if (sub == "stop") {
            base.insert(base.end(), {"shell", "am", "force-stop", projectPackage});
            return run(base, false);
        }
        if (sub == "uninstall") {
            base.insert(base.end(), {"uninstall", projectPackage});
            return run(base, false);
        }
        if (clear) {
            std::vector<std::string> c = base;
            c.insert(c.end(), {"logcat", "-c"});
            run(c, false);
        }
        std::vector<std::string> cmd = base;
        cmd.insert(cmd.end(), {"logcat", "-v", "tag"});
        if (appOnly) {
            std::string pid = adbShell(device, {"pidof", projectPackage});
            if (pid.empty()) {
                std::fprintf(stderr, "faset: error: %s no se está ejecutando\n", projectPackage.c_str());
                return 1;
            }
            cmd.push_back("--pid=" + pid);
        }
        cmd.insert(cmd.end(), extra.begin(), extra.end());
        return run(cmd, false);
    }
    std::fprintf(stderr, "faset: error: comando desconocido 'android %s'\n", sub.c_str());
    androidUsage();
    return 1;
}

// ------------------------------------------------------------------ doctor

void androidDoctor() {
    const AndroidTools& t = androidTools();
    auto show = [](const std::string& label, const std::string& found, const std::string& hint) {
        std::printf("  %-26s %s\n", label.c_str(), found.empty() ? ("no encontrado  -> " + hint).c_str() : found.c_str());
    };
    std::string sdkm = "sdkmanager --install";
    show("Android SDK", t.sdk, "instala Android Studio o las cmdline-tools y define ANDROID_HOME");
    show("Android NDK", t.ndk.empty() ? "" : t.ndk + "  (" + t.ndkVersion + ")", sdkm + " \"ndk;<versión>\"");
    show("Android build-tools", t.buildToolsVersion.empty() ? "" : t.buildToolsVersion + "  (aapt2, zipalign, apksigner)",
         sdkm + " \"build-tools;<versión>\"");
    show("Android plataforma", t.platformDir.empty() ? "" : fs::path(t.platformDir).filename().string() + "  (targetSdk " + std::to_string(t.platformApi) + ")",
         sdkm + " \"platforms;android-<n>\"");
    show("adb", t.adb, sdkm + " platform-tools");
    show("Emulador", t.emulator, sdkm + " emulator");
    show("Java (apksigner)", t.java, "instala un JDK 17+ o Android Studio, o define JAVA_HOME");
    std::string avds;
    for (const std::string& a : listAvds()) avds += (avds.empty() ? "" : ", ") + a;
    show("AVDs", avds, "crea uno con Android Studio (Device Manager) o avdmanager");
}
