// Faset - herramientas de Android: detección del SDK/NDK, empaquetado de APK sin Gradle
// (aapt2 + zipalign + apksigner), instalación y ejecución con adb, y el emulador.
#pragma once
#include <string>
#include <utility>
#include <vector>

struct AndroidTools {
    std::string sdk;                       // carpeta del SDK ("" si no hay)
    std::string ndk, ndkVersion;           // NDK más reciente
    std::string buildTools, buildToolsVersion;
    std::string platformDir, androidJar;   // platforms/android-XX más reciente
    int platformApi = 0;                   // XX
    std::string adb, emulator, aapt2, zipalign, apksigner;
    std::string javaHome, java, keytool;   // JDK (JAVA_HOME, PATH o el JBR de Android Studio)
};

// Busca el SDK, el NDK, las build-tools, la plataforma, adb, el emulador y Java (se calcula una vez).
const AndroidTools& androidTools();

// NDK: ANDROID_NDK_HOME / ANDROID_NDK_ROOT / ANDROID_NDK o <SDK>/ndk/<versión más reciente>.
std::string findAndroidNdk();

// Triple de clang para una arquitectura de Faset (arm64, armv7, x86, x86_64).
std::string androidTriple(const std::string& arch);
// ABI de Android <-> arquitectura de Faset: arm64-v8a <-> arm64, armeabi-v7a <-> armv7, x86, x86_64.
std::string androidAbiToArch(const std::string& abi);
std::string androidArchToAbi(const std::string& arch);

struct ApkSpec {
    std::string name;            // la biblioteca nativa es lib<name>.so
    std::string package;         // com.faset.miapp
    std::string label;           // nombre visible
    std::string versionName = "1.0";
    int versionCode = 1;
    int minSdk = 24;
    int targetSdk = 0;           // 0 = la plataforma instalada más reciente
    std::string icon;            // PNG opcional
    std::string orientation;     // portrait, landscape, ... ("" = la del sistema)
    std::vector<std::string> permissions;
    bool debuggable = true;
    std::string keystore, keyAlias, storePass, keyPass;  // vacío = ~/.android/debug.keystore
    std::vector<std::pair<std::string, std::string>> files;  // (ruta dentro del APK, archivo local)
    std::string objDir;          // archivos intermedios
    std::string output;          // .apk final
    bool verbose = false;
};

// Genera AndroidManifest.xml, enlaza con aapt2, añade lib/<abi>/*.so, alinea y firma.
bool androidPackageApk(const ApkSpec& spec, std::string& error);

// Instala el APK, abre la actividad y muestra el logcat de la app hasta que termina.
// Devuelve el código de salida del programa (o != 0 si falla la instalación).
int androidRunApk(const std::string& apk, const std::string& package, const std::string& tag,
                  const std::string& device, bool verbose);

// faset android <devices|avds|emulator|logcat|stop> ...
int androidCommand(const std::vector<std::string>& args, const std::string& projectPackage);

// Líneas de 'faset doctor' para Android.
void androidDoctor();
