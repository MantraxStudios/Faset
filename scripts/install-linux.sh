#!/usr/bin/env sh
# Instalador de Faset para Linux (va dentro del paquete faset-<versión>-linux-x86_64.tar.gz).
#   ./install.sh               ~/.local/share/faset + enlaces en ~/.local/bin (sin sudo)
#   ./install.sh --system      /usr/local/share/faset + enlaces en /usr/local/bin (con sudo)
#   ./install.sh --android     también el módulo de Android (SDK, NDK, Java y emulador)
#   ./install.sh --all         todos los módulos (Linux, multimedia, Windows y Android)
#   ./install.sh --yes         sin preguntas (acepta las licencias del SDK de Android)
#   ./install.sh --no-setup    solo copia los archivos (sin 'faset setup')
#   ./install.sh --uninstall   quita la instalación (añade --system si fue con --system)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX="$HOME/.local"
SUDO=""
UNINSTALL=0
SETUP=1
MODULES=""
YES=""
for a in "$@"; do
    case "$a" in
        --system) PREFIX=/usr/local; [ "$(id -u)" -eq 0 ] || SUDO=sudo ;;
        --uninstall) UNINSTALL=1 ;;
        --android) MODULES="$MODULES android" ;;
        --all) MODULES="all" ;;
        --yes|-y) YES="--yes" ;;
        --no-setup) SETUP=0 ;;
        *) echo "opción desconocida: $a" >&2; exit 2 ;;
    esac
done
DEST="$PREFIX/share/faset"
APPS="$PREFIX/share/applications"
[ "$PREFIX" = /usr/local ] || APPS="$HOME/.local/share/applications"

if [ "$UNINSTALL" -eq 1 ]; then
    $SUDO rm -rf "$DEST" "$PREFIX/bin/faset" "$PREFIX/bin/fasetstudio" "$APPS/fasetstudio.desktop"
    echo "Faset desinstalado de $PREFIX"
    exit 0
fi

if [ "$HERE" != "$DEST" ]; then
    $SUDO rm -rf "$DEST"
    $SUDO mkdir -p "$DEST"
    $SUDO cp -r "$HERE"/. "$DEST"/
fi
$SUDO mkdir -p "$PREFIX/bin" "$APPS"
$SUDO ln -sf "$DEST/faset" "$PREFIX/bin/faset"
$SUDO ln -sf "$DEST/FasetStudio" "$PREFIX/bin/fasetstudio"
$SUDO sh -c "cat > '$APPS/fasetstudio.desktop'" <<DESKTOP
[Desktop Entry]
Type=Application
Name=FasetStudio
Comment=IDE del lenguaje Faset
Exec=$DEST/FasetStudio %F
Icon=$DEST/share/faset.png
Terminal=false
Categories=Development;IDE;
DESKTOP

echo "Faset instalado en $DEST"
echo "  faset        -> $PREFIX/bin/faset"
echo "  fasetstudio  -> $PREFIX/bin/fasetstudio (también en el menú de aplicaciones)"
case ":$PATH:" in
    *":$PREFIX/bin:"*) ;;
    *) echo "Añade $PREFIX/bin a tu PATH:  echo 'export PATH=\"$PREFIX/bin:\$PATH\"' >> ~/.bashrc" ;;
esac
"$DEST/faset" --version
[ "$SETUP" -eq 1 ] || exit 0

# Módulos: el de esta plataforma siempre; Android si se pide (o se acepta al preguntar).
echo
"$DEST/faset" setup linux $YES || true
if [ -z "$MODULES" ] && [ -z "$YES" ] && [ -t 0 ]; then
    printf '¿Instalar también el módulo de Android (SDK, NDK, Java y emulador, ~4 GB)? [s/N] '
    read -r r || r=""
    case "$r" in s*|S*|y*|Y*) MODULES="android" ;; esac
fi
[ -z "$MODULES" ] || "$DEST/faset" setup $MODULES $YES || true
echo
echo "Listo. Abre FasetStudio desde el menú de aplicaciones o con 'fasetstudio'."
