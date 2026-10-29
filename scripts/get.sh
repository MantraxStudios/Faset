#!/usr/bin/env sh
# Instalación de Faset en una línea (Linux x86_64):
#   curl -fsSL https://raw.githubusercontent.com/MantraxStudios/Faset/main/scripts/get.sh | sh
#   curl -fsSL .../get.sh | sh -s -- --android      (opciones de install.sh: --android, --all, --system, --yes)
set -eu
URL=${FASET_URL:-https://github.com/MantraxStudios/Faset/releases/latest/download/faset-linux-x86_64.tar.gz}
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) ;;
    *) echo "Faset: por ahora solo hay paquete para Linux x86_64 (en Windows usa get.ps1)." >&2; exit 1 ;;
esac
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Descargando $URL"
if command -v curl > /dev/null; then curl -fL --progress-bar "$URL" -o "$TMP/faset.tar.gz"
else wget -q --show-progress -O "$TMP/faset.tar.gz" "$URL"; fi
tar -xzf "$TMP/faset.tar.gz" -C "$TMP"
# El instalador pregunta (Android) leyendo de la terminal, no de la tubería de curl.
if [ -t 1 ] && [ -r /dev/tty ]; then sh "$TMP/faset/install.sh" "$@" < /dev/tty
else sh "$TMP/faset/install.sh" "$@"; fi
