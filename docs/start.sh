#!/usr/bin/env bash
# Compila la web de Faset y la sirve en el puerto 8871 (nginx la publica en faset.lat).
#
#   ./start.sh              compila (si hace falta el compilador 'faset', también) y sirve
#   ./start.sh --no-build   sirve lo que ya hay en out/
#   ./start.sh --build-only compila sin servir (para actualizar y reiniciar el servicio)
#   PORT=9000 HOST=0.0.0.0 ./start.sh
#
# La web necesita el repositorio completo: los scripts de docs/scripts leen ../lib y ejecutan ../faset.
set -euo pipefail
cd "$(dirname "$0")"
export PORT=${PORT:-8871}
export HOST=${HOST:-127.0.0.1}
# Caché de npm propia: así no molesta una ~/.npm con archivos de root (de algún 'sudo npm').
export npm_config_cache=${npm_config_cache:-$PWD/../.npm-cache}
BUILD=1
SERVE=1
for a in "$@"; do
    case "$a" in
        --no-build) BUILD=0 ;;
        --build-only) SERVE=0 ;;
        *) echo "opción desconocida: $a" >&2; exit 2 ;;
    esac
done

if [ "$BUILD" -eq 1 ]; then
    if [ ! -x ../faset ]; then
        echo "== compilando faset (la web genera la referencia de la CLI con él)"
        make -C .. -j"$(nproc 2>/dev/null || echo 2)"
    fi
    if [ ! -d node_modules ] || [ package-lock.json -nt node_modules ]; then
        echo "== instalando dependencias"
        npm ci --no-audit --no-fund
    fi
    echo "== compilando la web"
    npm run build
fi

[ "$SERVE" -eq 1 ] || exit 0
if [ ! -f out/index.html ]; then
    echo "No existe out/index.html: ejecuta ./start.sh sin --no-build" >&2
    exit 1
fi
echo "== sirviendo en http://$HOST:$PORT"
exec node deploy/serve.mjs --port "$PORT" --host "$HOST"
