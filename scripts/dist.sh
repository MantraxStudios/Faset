#!/usr/bin/env bash
# Genera los paquetes de distribución en dist/:
#   faset-linux-x86_64.tar.gz    faset + FasetStudio + lib/ + lang/ + install.sh
#   faset-windows-x86_64.zip     faset.exe + FasetStudio.exe + lib/ + lang/ + install.ps1
#                                (MinGW-w64 o el llvm-mingw de 'faset setup windows')
# Los nombres no llevan la versión: así .../releases/latest/download/<nombre> siempre funciona.
#
# Uso: scripts/dist.sh [linux|windows|all]   (por defecto: all)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
WHAT=${1:-all}
VERSION=$(grep -oP 'kVersion = "\K[^"]+' src/main.cpp)
OUT=$ROOT/dist
mkdir -p "$OUT"
SRCS=(src/*.cpp)
CXXFLAGS=(-std=c++17 -O2 -DNDEBUG -Wno-unused-parameter)

linux() {
    local name="faset-linux-x86_64" stage="$OUT/stage/faset"
    echo "== $name"
    rm -rf "$OUT/stage" && mkdir -p "$stage"
    # libstdc++ y libgcc estáticas: el ejecutable solo depende de la glibc del sistema.
    g++ "${CXXFLAGS[@]}" -static-libstdc++ -static-libgcc "${SRCS[@]}" -o "$stage/faset"
    strip "$stage/faset"
    # FasetStudio, compilado con el faset recién hecho (Release).
    FASET_LIB="$ROOT/lib" "$stage/faset" build studio -c Release > /dev/null
    install -m755 studio/bin/Release/linux-x86_64/FasetStudio "$stage/FasetStudio"
    strip "$stage/FasetStudio"
    cp -r lib "$stage/lib"
    cp -r studio/lang "$stage/lang"
    install -Dm644 studio/assets/logo.png "$stage/share/faset.png"
    install -m755 scripts/install-linux.sh "$stage/install.sh"
    cp LICENSE "$stage/" 2>/dev/null || true
    printf 'Faset %s para Linux x86_64\n\n  ./install.sh            instala en ~/.local (sin sudo) y configura el módulo de Linux\n  ./install.sh --system   instala en /usr/local (con sudo)\n  ./install.sh --android  además instala el SDK/NDK de Android (o --all para todo)\n\nEl instalador ejecuta "faset setup": comprueba el compilador de C y las bibliotecas\nde FasetStudio y las instala con el gestor de paquetes si faltan.\nTambién funciona sin instalar: ./faset y ./FasetStudio desde esta carpeta.\n' "$VERSION" > "$stage/LEEME.txt"
    tar -C "$OUT/stage" -czf "$OUT/$name.tar.gz" faset
    rm -rf "$OUT/stage"
    echo "   $OUT/$name.tar.gz ($(du -h "$OUT/$name.tar.gz" | cut -f1))"
}

windows() {
    local name="faset-windows-x86_64" stage="$OUT/stage/faset"
    # MinGW-w64 del sistema o el llvm-mingw de 'faset setup windows'.
    local cxx strip
    if command -v x86_64-w64-mingw32-g++ > /dev/null; then
        cxx=x86_64-w64-mingw32-g++ strip=x86_64-w64-mingw32-strip
    else
        local tc="${XDG_DATA_HOME:-$HOME/.local/share}/faset/toolchains/llvm-mingw/bin"
        if [ ! -x "$tc/x86_64-w64-mingw32-clang++" ]; then
            echo "== $name: falta un toolchain de Windows (./faset setup windows)" >&2
            return 1
        fi
        cxx="$tc/x86_64-w64-mingw32-clang++" strip="$tc/x86_64-w64-mingw32-strip"
    fi
    echo "== $name"
    rm -rf "$OUT/stage" && mkdir -p "$stage"
    "$cxx" "${CXXFLAGS[@]}" -static "${SRCS[@]}" -o "$stage/faset.exe"
    "$strip" "$stage/faset.exe"
    # FasetStudio.exe (aplicación de ventana), compilado de forma cruzada con un faset para Linux.
    local host="$ROOT/faset"
    [ -x "$host" ] || { echo "== $name: falta ./faset para compilar FasetStudio (make)" >&2; return 1; }
    FASET_LIB="$ROOT/lib" "$host" build studio -c Release --target windows > /dev/null
    install -m755 studio/bin/Release/windows-x86_64/FasetStudio.exe "$stage/FasetStudio.exe"
    "$strip" "$stage/FasetStudio.exe"
    # Solo DLL que trae Windows 10 o posterior (el CRT universal 'api-ms-win-crt-*' incluido):
    # el zip no lleva DLL propias, así que cualquier otra dependencia sería un error al arrancar.
    local objdump="${strip%strip}objdump" exe dll bad=""
    for exe in "$stage/faset.exe" "$stage/FasetStudio.exe"; do
        for dll in $("$objdump" -p "$exe" | sed -n 's/^\s*DLL Name: //p'); do
            echo "$dll" | grep -qiE '^(kernel32|user32|gdi32|advapi32|shell32|ole32|ws2_32|secur32|winmm|api-ms-win-crt-[a-z0-9-]+)\.dll$' \
                || bad="$bad $(basename "$exe"):$dll"
        done
    done
    if [ -n "$bad" ]; then
        echo "== $name: dependencias que no trae Windows:$bad" >&2
        return 1
    fi
    cp -r lib "$stage/lib"
    cp -r studio/lang "$stage/lang"
    install -m644 studio/assets/faset.ico "$stage/faset.ico"
    install -m644 scripts/install-windows.ps1 "$stage/install.ps1"
    cp LICENSE "$stage/" 2>/dev/null || true
    printf 'Faset %s para Windows x86_64\r\n\r\n  powershell -ExecutionPolicy Bypass -File install.ps1\r\n\r\nInstala en %%LOCALAPPDATA%%\\Faset, lo añade al PATH del usuario y ejecuta\r\n"faset setup windows" (descarga el compilador de C llvm-mingw).\r\nCrea el acceso directo de FasetStudio en el menú Inicio (y en el escritorio con -Desktop).\r\nOpciones: -Desktop, -Android (también el SDK/NDK de Android), -Yes, -NoSetup, -Uninstall.\r\n\r\nFasetStudio.exe: compilado pero aún sin probar en un Windows real (probado con Wine).\r\nNecesita Windows 10 o posterior y un controlador de la tarjeta gráfica con Vulkan.\r\n' "$VERSION" > "$stage/LEEME.txt"
    (cd "$OUT/stage" && rm -f "$OUT/$name.zip" && zip -qr "$OUT/$name.zip" faset)
    rm -rf "$OUT/stage"
    echo "   $OUT/$name.zip ($(du -h "$OUT/$name.zip" | cut -f1))"
}

case "$WHAT" in
    linux) linux ;;
    windows) windows ;;
    all) linux; windows || true ;;
    *) echo "uso: $0 [linux|windows|all]" >&2; exit 2 ;;
esac
