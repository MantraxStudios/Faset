#!/usr/bin/env bash
# Ejecuta los tests de Faset:
#   tests/cases/*.fst      compara la salida con su .expected (y el código con .exitcode);
#                          si hay un .panic, stderr debe contener ese texto (Faset panic: ...)
#   tests/errors/*.fst     deben producir errores de compilación; si hay un .expected, cada
#                          línea 'N|regex' debe aparecer como error en la línea N
#   tests/projects/*/      compila el proyecto indicado en 'main' y compara con 'expected'
#   tests/lsp/test.js      servidor de lenguaje (si hay Node)
set -u
cd "$(dirname "$0")/.."
FASET=./faset
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

for src in tests/cases/*.fst; do
    name=$(basename "$src" .fst)
    expected="tests/cases/$name.expected"
    want_code=0
    [ -f "tests/cases/$name.exitcode" ] && want_code=$(cat "tests/cases/$name.exitcode")
    if ! $FASET build "$src" -o "$TMP/$name" 2> "$TMP/$name.err"; then
        echo "FALLO  $name (no compila)"; cat "$TMP/$name.err"; fail=$((fail+1)); continue
    fi
    "$TMP/$name" > "$TMP/$name.out" 2> "$TMP/$name.rerr"; code=$?
    panic="tests/cases/$name.panic"
    if [ "$code" != "$want_code" ]; then
        echo "FALLO  $name (código de salida $code, se esperaba $want_code)"; cat "$TMP/$name.rerr"; fail=$((fail+1))
    elif ! diff -u "$expected" "$TMP/$name.out" > "$TMP/$name.diff"; then
        echo "FALLO  $name (salida distinta)"; cat "$TMP/$name.diff"; fail=$((fail+1))
    elif [ -f "$panic" ] && ! grep -qF "$(cat "$panic")" "$TMP/$name.rerr"; then
        echo "FALLO  $name (stderr no contiene: $(cat "$panic"))"; cat "$TMP/$name.rerr"; fail=$((fail+1))
    else
        echo "ok     $name"; pass=$((pass+1))
    fi
done

for src in tests/errors/*.fst; do
    name=$(basename "$src" .fst)
    if $FASET check "$src" > "$TMP/err_$name.log" 2>&1; then
        echo "FALLO  errors/$name (debería fallar al compilar)"; fail=$((fail+1)); continue
    fi
    missing=""
    if [ -f "tests/errors/$name.expected" ]; then
        while IFS='|' read -r ln rx; do
            [ -z "$ln" ] && continue
            grep -qE ":$ln:[0-9]+: error: .*$rx" "$TMP/err_$name.log" || missing="$missing\n  línea $ln: $rx"
        done < "tests/errors/$name.expected"
    fi
    if [ -n "$missing" ]; then
        echo -e "FALLO  errors/$name (faltan errores):$missing"; fail=$((fail+1))
    else
        echo "ok     errors/$name"; pass=$((pass+1))
    fi
done

for dir in tests/projects/*/; do
    name=$(basename "$dir")
    main="$dir$(cat "$dir/main")"
    if ! (cd "$main" && "$OLDPWD/$FASET" build -o "$TMP/proj_$name" > /dev/null 2> "$TMP/proj_$name.err"); then
        echo "FALLO  projects/$name (no compila)"; cat "$TMP/proj_$name.err"; fail=$((fail+1)); continue
    fi
    if "$TMP/proj_$name" | diff -u "$dir/expected" - > "$TMP/proj_$name.diff"; then
        echo "ok     projects/$name"; pass=$((pass+1))
    else
        echo "FALLO  projects/$name (salida distinta)"; cat "$TMP/proj_$name.diff"; fail=$((fail+1))
    fi
done

if command -v node > /dev/null; then
    if out=$(timeout 60 node tests/lsp/test.js "$PWD/$FASET" 2>&1); then
        echo "ok     lsp"; pass=$((pass+1))
    else
        echo "FALLO  lsp: $out"; fail=$((fail+1))
    fi
fi

# FasetStudio (si hay Vulkan, X11 y FreeType): compila el IDE y lo ejecuta fuera de pantalla.
if ldconfig -p 2>/dev/null | grep -q "libvulkan.so.1" && [ -f /usr/lib/x86_64-linux-gnu/libX11.so -o -f /usr/lib/libX11.so ]; then
    if ! $FASET build studio -o "$TMP/FasetStudio" > "$TMP/studio.err" 2>&1; then
        echo "FALLO  studio (no compila)"; cat "$TMP/studio.err"; fail=$((fail+1))
    elif (cd tests/projects/juego/MiJuego && HOME="$TMP" FASET="$OLDPWD/$FASET" timeout 120 "$TMP/FasetStudio" . --screenshot "$TMP/studio.ppm" \
            --size 900x600 --script "goto 13 59 | key enter | type heroe.Mo | hover 13 22" > "$TMP/studio.log" 2>&1) && [ -s "$TMP/studio.ppm" ]; then
        echo "ok     studio"; pass=$((pass+1))
    else
        echo "FALLO  studio (ejecución)"; cat "$TMP/studio.log"; fail=$((fail+1))
    fi
fi

echo
echo "$pass correctos, $fail fallidos"
[ "$fail" = 0 ]
