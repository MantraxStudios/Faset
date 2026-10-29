#!/usr/bin/env bash
# Ejecuta los tests de Faset:
#   tests/cases/*.fst      compara la salida con su .expected (y el código con .exitcode);
#                          si hay un .panic, stderr debe contener ese texto (Faset panic: ...);
#                          un programa que termina con el código 77 se omite (p. ej. sin red)
#   tests/errors/*.fst     deben producir errores de compilación; si hay un .expected, cada
#                          línea 'N|regex' debe aparecer como error en la línea N
#   tests/projects/*/      compila el proyecto indicado en 'main' y compara con 'expected'
#   tests/async_ui/        async/await en std.ui sin pantalla (continuaciones en el hilo de la interfaz)
#   tests/debug/           información de depuración: '#line' en el C de Debug y gdb (si está) para
#                          en una línea de Faset, muestra sus variables y avanza paso a paso
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

# async/await en std.ui sin pantalla: el manejador 'async void' de un botón espera (Task.Delay y
# Task.Run) y sigue en el hilo de la interfaz (UiSynchronizationContext), donde cambia la etiqueta.
if ! $FASET build tests/async_ui/MainWindow.fstui tests/async_ui/Main.fst -o "$TMP/async_ui" > /dev/null 2> "$TMP/async_ui.err"; then
    echo "FALLO  async_ui (no compila)"; cat "$TMP/async_ui.err"; fail=$((fail+1))
elif aout=$(cd tests/async_ui && FASET_UI_SCREENSHOT="$TMP/async_ui.bmp" FASET_UI_SCRIPT="click 50 25 | wait 400" \
            timeout 30 "$TMP/async_ui" 2>&1) && [ "$aout" = "$(cat tests/async_ui/expected)" ] && [ -s "$TMP/async_ui.bmp" ]; then
    echo "ok     async_ui"; pass=$((pass+1))
else
    echo "FALLO  async_ui: $aout"; fail=$((fail+1))
fi

# Depurador: el C de Debug (o con -g) lleva '#line N "archivo.fst"', el de Release no, y gdb
# pone un punto de interrupción en una línea de Faset, lee las variables y entra en una llamada.
debug_check() {
    local src=tests/debug/depurar.fst
    $FASET emit-c -g "$src" -o "$TMP/dbg.c" 2> /dev/null || { echo "emit-c -g"; return 1; }
    grep -qE '^#line 12 ".*/tests/debug/depurar\.fst"$' "$TMP/dbg.c" || { echo "falta '#line 12' en el C con -g"; return 1; }
    $FASET emit-c --release "$src" -o "$TMP/rel.c" 2> /dev/null || { echo "emit-c --release"; return 1; }
    grep -q '^#line' "$TMP/rel.c" && { echo "Release no debe llevar '#line'"; return 1; }
    $FASET build "$src" -o "$TMP/depurar" > /dev/null 2>&1 || { echo "build Debug"; return 1; }
    [ "$("$TMP/depurar")" = "total 22" ] || { echo "salida del programa"; return 1; }
    command -v gdb > /dev/null || return 0
    local out
    out=$(LC_ALL=C timeout 60 gdb -q -nx -batch -ex "set debuginfod enabled off" -ex "skip -rfu ^faset_" \
          -ex "break depurar.fst:13" -ex "run > /dev/null" -ex "info locals" -ex "step" -ex "info args" \
          -ex "finish" -ex "next" -ex "info locals" "$TMP/depurar" 2>&1)
    echo "$out" | grep -qE "Breakpoint 1, .* at .*depurar\.fst:13" || { echo "gdb no paró en depurar.fst:13"; echo "$out"; return 1; }
    echo "$out" | grep -q "^l_total = 20" || { echo "gdb no ve 'total' (l_total = 20)"; echo "$out"; return 1; }
    echo "$out" | grep -qE "Doble .* at .*depurar\.fst:6" || { echo "'step' no entró en Doble (depurar.fst:6)"; echo "$out"; return 1; }
    echo "$out" | grep -q "^p_n = 1" || { echo "gdb no ve el parámetro n (p_n = 1)"; echo "$out"; return 1; }
    echo "$out" | grep -q "^l_total = 22" || { echo "'next' no completó la línea 13 (l_total = 22)"; echo "$out"; return 1; }
    return 0
}
if why=$(debug_check); then echo "ok     depurador"; pass=$((pass+1)); else echo "FALLO  depurador ($why)"; fail=$((fail+1)); fi

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
