#!/usr/bin/env bash
# Ejecuta los tests de Faset:
#   tests/cases/*.fst      compara la salida con su .expected (y el código con .exitcode);
#                          si hay un .panic, stderr debe contener ese texto (Faset panic: ...);
#                          un programa que termina con el código 77 se omite (p. ej. sin red)
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
    if [ "$code" = 77 ] && [ "$want_code" != 77 ]; then
        echo "omit.  $name ($(head -n 1 "$TMP/$name.out"))"; continue   # código 77: sin red, sin TLS...
    elif [ "$code" != "$want_code" ]; then
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

# Soluciones (.fstp): 'faset new sln', 'faset sln add/remove/ref/startup/list' y 'faset run' de la solución.
sln_check() {
    local d="$TMP/sln" F="$PWD/$FASET"
    rm -rf "$d" && mkdir -p "$d" && cd "$d" || return 1
    "$F" new sln Sol > /dev/null && cd Sol || { echo "new sln"; return 1; }
    "$F" new Base --lib > /dev/null && "$F" new App > /dev/null || { echo "new proyectos"; return 1; }
    "$F" sln add Base/Base.fstproj --folder Bibliotecas/Nucleo > /dev/null || { echo "sln add"; return 1; }
    "$F" sln add App > /dev/null || { echo "sln add carpeta"; return 1; }
    "$F" sln add App/App.fstproj | grep -q "ya está" || { echo "sln add repetido"; return 1; }
    grep -q '<Folder Name="Bibliotecas">' Sol.fstp && grep -q '<Folder Name="Nucleo">' Sol.fstp || { echo "carpetas"; return 1; }
    "$F" sln startup App > /dev/null && grep -q 'Path="App/App.fstproj" Startup="true"' Sol.fstp || { echo "sln startup"; return 1; }
    "$F" sln startup Base > /dev/null 2>&1 && { echo "startup de una biblioteca"; return 1; }
    "$F" sln ref App Base > /dev/null && grep -q 'ProjectReference Include="../Base/Base.fstproj"' App/App.fstproj || { echo "sln ref"; return 1; }
    "$F" sln ref Base App > /dev/null 2>&1 && { echo "sln ref a un Exe"; return 1; }
    "$F" sln list | grep -q "^\* *App" || { echo "sln list"; return 1; }
    "$F" sln list --json | grep -q '"startup":true' || { echo "sln list --json"; return 1; }
    "$F" run 2> /dev/null | grep -q "Hola desde Faset" || { echo "run de la solución"; return 1; }
    "$F" sln remove Base > /dev/null && ! grep -q "Base.fstproj" Sol.fstp && [ -f Base/Base.fstproj ] || { echo "sln remove"; return 1; }
    "$F" sln remove Nada > /dev/null 2>&1 && { echo "sln remove inexistente"; return 1; }
    cd "$d" && "$F" new Juego --solution > /dev/null && [ -f Juego/Juego.fstp ] && [ -f Juego/Juego/Juego.fstproj ] || { echo "new --solution"; return 1; }
    "$F" build Juego/Juego.fstp > /dev/null 2>&1 || { echo "build de new --solution"; return 1; }
    return 0
}
if why=$(sln_check); then echo "ok     soluciones"; pass=$((pass+1)); else echo "FALLO  soluciones ($why)"; fail=$((fail+1)); fi
cd "$(dirname "$0")/.." 2>/dev/null || true

# Paquetes (tests/paquetes.sh): repositorios git locales, paquetes.lock, update, conflictos y sin conexión.
if command -v git > /dev/null; then
    pout=$(timeout 300 bash tests/paquetes.sh "$PWD/$FASET" 2>&1)
    if [ "$(echo "$pout" | tail -n 1)" = ok ]; then echo "ok     paquetes"; pass=$((pass+1)); else echo "FALLO  paquetes: $pout"; fail=$((fail+1)); fi
fi

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

# VideoPlayer (si GStreamer decodifica H.264): reproduce tests/video/clip.mp4 sin pantalla con cada
# guion de tests/video/cases ("guion=>salida esperada", líneas unidas con ';').
if command -v gst-inspect-1.0 > /dev/null && gst-inspect-1.0 playbin > /dev/null 2>&1 && gst-inspect-1.0 avdec_h264 > /dev/null 2>&1; then
    if ! $FASET build tests/video/MainWindow.fstui tests/video/Main.fst -o "$TMP/video" > /dev/null 2> "$TMP/video.err"; then
        echo "FALLO  video (no compila)"; cat "$TMP/video.err"; fail=$((fail+1))
    else
        vbad=""
        while IFS= read -r line; do
            vscript="${line%%=>*}"; vwant="${line#*=>}"
            vgot=$(cd tests/video && FASET_UI_SCREENSHOT="$TMP/video.bmp" FASET_UI_SCRIPT="$vscript" timeout 30 "$TMP/video" 2>&1 | tr '\n' ';')
            [ "$vgot" = "$vwant" ] || vbad="$vbad\n  '$vscript': $vgot (se esperaba $vwant)"
        done < tests/video/cases
        if [ -z "$vbad" ]; then echo "ok     video"; pass=$((pass+1)); else echo -e "FALLO  video:$vbad"; fail=$((fail+1)); fi
    fi
fi

echo
echo "$pass correctos, $fail fallidos"
[ "$fail" = 0 ]
