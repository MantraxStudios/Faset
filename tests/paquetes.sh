#!/usr/bin/env bash
# Pruebas del gestor de paquetes (sin red): repositorios git "remotos" locales (bare) con
# etiquetas v1.0.0, v1.1.0 y v2.0.0, una dependencia indirecta, el índice como archivo local,
# paquetes.lock, update, conflictos y compilación sin conexión.
#   tests/paquetes.sh [ruta de faset]     imprime 'ok' o el paso que falla
set -u
F=$(cd "$(dirname "${1:-./faset}")" && pwd)/$(basename "${1:-./faset}")
T=$(mktemp -d)
[ -n "${CONSERVAR:-}" ] && echo "$T" || trap 'rm -rf "$T"' EXIT
export XDG_DATA_HOME="$T/datos"            # caché: $T/datos/faset/paquetes
export FASET_PAQUETES_INDICE="$T/indice.json"
unset FASET_OFFLINE FASET_PAQUETES_CACHE
export GIT_AUTHOR_NAME=Prueba GIT_AUTHOR_EMAIL=prueba@faset.lat GIT_COMMITTER_NAME=Prueba GIT_COMMITTER_EMAIL=prueba@faset.lat
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G="git -c init.defaultBranch=main -c commit.gpgsign=false -c tag.gpgsign=false"
CACHE="$T/datos/faset/paquetes"

die() { echo "$1"; exit 1; }

# Paquete de prueba: biblioteca 'nombre' en 'dir' cuya clase devuelve su versión.
# paquete <dir> <nombre> <versión> [PackageReference...]
paquete() {
    local dir=$1 name=$2 ver=$3; shift 3
    mkdir -p "$dir"
    {
        echo "<Project>"
        echo "  <PropertyGroup>"
        echo "    <OutputType>Library</OutputType>"
        echo "    <PackageId>$name</PackageId>"
        echo "    <Version>$ver</Version>"
        echo "  </PropertyGroup>"
        if [ $# -gt 0 ]; then
            echo "  <ItemGroup>"
            for r in "$@"; do echo "    $r"; done
            echo "  </ItemGroup>"
        fi
        echo "</Project>"
    } > "$dir/$name.fstproj"
    cat > "$dir/Info.fst" <<FST
namespace $name
{
    public static class Info
    {
        public static string Version() => "$ver";
        public static string Todo() => "$name $ver" + $( [ "$name" = Json5 ] && echo '" usa Texto " + Texto.Info.Version()' || echo '""' );
    }
}
FST
}

R="$T/remotos"
mkdir -p "$R"
# Texto: v1.0.0, v1.1.0, v2.0.0 (sin dependencias)
w="$T/w/texto"; mkdir -p "$w"; (cd "$w" && $G init -q) || die "git init"
for v in 1.0.0 1.1.0 2.0.0; do
    paquete "$w" Texto $v
    (cd "$w" && $G add -A && $G commit -qm "Texto $v" && $G tag "v$v") || die "commit Texto $v"
done
$G clone -q --bare "$w" "$R/texto.git" || die "bare texto"
# Json5: v1.0.0 y v1.1.0 dependen de Texto ^1.0; v2.0.0 de Texto ^2.0 (etiqueta anotada)
w="$T/w/json5"; mkdir -p "$w"; (cd "$w" && $G init -q) || die "git init"
for v in 1.0.0 1.1.0 2.0.0; do
    case $v in 2.*) c="^2.0" ;; *) c="^1.0" ;; esac
    paquete "$w" Json5 $v "<PackageReference Include=\"Texto\" Git=\"$R/texto.git\" Version=\"$c\" />"
    (cd "$w" && $G add -A && $G commit -qm "Json5 $v") || die "commit Json5 $v"
    if [ $v = 2.0.0 ]; then (cd "$w" && $G tag -a "v$v" -m "Json5 $v"); else (cd "$w" && $G tag "v$v"); fi
done
$G clone -q --bare "$w" "$R/json5.git" || die "bare json5"
cat > "$T/indice.json" <<EOF
{ "formato": 1, "paquetes": { "Texto": { "git": "$R/texto.git", "descripcion": "Texto de prueba", "versiones": ["1.0.0", "1.1.0", "2.0.0"] } } }
EOF

# Restricciones semver
s() { "$F" __semver "$@"; }
[ "$(s '^1.0' 1.0.0 1.1.0 2.0.0)" = 1.1.0 ] || die "semver ^1.0"
[ "$(s '~1.0' 1.0.0 1.0.5 1.1.0)" = 1.0.5 ] || die "semver ~1.0"
[ "$(s '1.0.0' 1.0.0 1.1.0)" = 1.0.0 ] || die "semver exacta"
[ "$(s '>=1.0 <2.0' 0.9.0 1.9.9 2.0.0)" = 1.9.9 ] || die "semver rango"
[ "$(s '^0.2' 0.2.1 0.3.0)" = 0.2.1 ] || die "semver ^0.2"
[ "$(s '1.x' 1.4.0 2.0.0)" = 1.4.0 ] || die "semver 1.x"
[ "$(s '^1.0 || ^3.0' 1.2.0 2.0.0 3.1.0)" = 3.1.0 ] || die "semver ||"
[ "$(s '^1.0' 1.1.0 1.2.0-beta)" = 1.1.0 ] || die "semver preliminar"
[ "$(s '^3.0' 1.0.0)" = ninguna ] || die "semver ninguna"

cd "$T" && "$F" new App > /dev/null && cd App || die "new App"
cat > Program.fst <<'FST'
namespace App
{
    public static class Program
    {
        public static void Main() { Console.WriteLine(Json5.Info.Todo()); }
    }
}
FST

# add con una URL git y una restricción: la más alta compatible y su dependencia
"$F" add "$R/json5.git" --version "^1.0" > "$T/add.log" 2>&1 || { cat "$T/add.log"; die "add git"; }
grep -q "<PackageReference Include=\"Json5\" Version=\"^1.0\" Git=\"../remotos/json5.git\" />" App.fstproj || { cat App.fstproj; die "add no escribió el .fstproj"; }
grep -q '"version": "1.1.0"' paquetes.lock && grep -q '"nombre": "Texto"' paquetes.lock || { cat paquetes.lock; die "lock"; }
grep -q '"commit": "[0-9a-f]\{40\}"' paquetes.lock || die "lock sin commit"
grep -q '"git": "../remotos/json5.git"' paquetes.lock || die "lock con la ruta absoluta del repositorio"
[ -d "$CACHE/json5/1.1.0/.git" ] && [ -d "$CACHE/texto/1.1.0" ] || die "caché"
out=$("$F" run 2>"$T/run.err") || { cat "$T/run.err"; die "run"; }
[ "$out" = "Json5 1.1.0 usa Texto 1.1.0" ] || die "salida: $out"
"$F" list paquetes | grep -q "└── Texto 1.1.0" || { "$F" list paquetes; die "list paquetes"; }
"$F" list paquetes --json | grep -q '"nombre":"Json5"' || die "list --json"

# IntelliSense: "ir a la definición" llega a las fuentes del paquete (en la caché) y el .fstproj
# avisa de los paquetes que no están en paquetes.lock.
printf '{"focus":"%s"}' "$PWD/Program.fst" > "$T/req.json"
"$F" __analyze "$T/req.json" "$T/res.json" || die "__analyze"
grep -q "\"defPath\":\"$CACHE/json5/1.1.0/Info.fst\"" "$T/res.json" || { cat "$T/res.json"; die "definición en el paquete"; }
sed 's|</ItemGroup>|  <PackageReference Include="Falta" Git="https://example.com/falta" Version="^x" />\n  </ItemGroup>|' App.fstproj > "$T/App.fstproj"
printf '{"focus":"%s","overrides":{"%s":%s}}' "$PWD/App.fstproj" "$PWD/App.fstproj" "$(sed 's/\\/\\\\/g; s/"/\\"/g' "$T/App.fstproj" | awk '{printf "%s\\n", $0}' | sed 's/^/"/; s/$/"/')" > "$T/req2.json"
"$F" __analyze "$T/req2.json" "$T/res2.json" || die "__analyze .fstproj"
grep -q "'Falta' no está restaurado" "$T/res2.json" && grep -q "versión no válida" "$T/res2.json" || { cat "$T/res2.json"; die "diagnósticos de PackageReference"; }
grep -q "'Json5' no está restaurado" "$T/res2.json" && die "Json5 sí está restaurado"

# Una versión nueva no cambia nada hasta 'faset update' (paquetes.lock)
w="$T/w/json5"
paquete "$w" Json5 1.2.0 "<PackageReference Include=\"Texto\" Git=\"$R/texto.git\" Version=\"^1.0\" />"
(cd "$w" && $G add -A && $G commit -qm "Json5 1.2.0" && $G tag v1.2.0 && $G push -q "$R/json5.git" v1.2.0) || die "push 1.2.0"
out=$("$F" run 2>/dev/null)
[ "$out" = "Json5 1.1.0 usa Texto 1.1.0" ] || die "el lock no se respetó: $out"
"$F" restore | grep -q "sin cambios" || die "restore"
"$F" update Json5 | grep -q "Json5 1.1.0 -> 1.2.0" || die "update Json5"
out=$("$F" run 2>/dev/null)
[ "$out" = "Json5 1.2.0 usa Texto 1.1.0" ] || die "tras update: $out"

# Sin conexión: los remotos desaparecen, se borra bin/obj y se compila desde la caché + lock
mv "$R" "$R.fuera"
rm -rf bin obj
out=$(FASET_OFFLINE=1 "$F" run 2>"$T/off.err") || { cat "$T/off.err"; die "compilación sin conexión"; }
[ "$out" = "Json5 1.2.0 usa Texto 1.1.0" ] || die "sin conexión: $out"
"$F" restore --offline > /dev/null || die "restore --offline"
"$F" update --offline > /dev/null 2>&1 && die "update --offline debería fallar"
mv "$R.fuera" "$R"

# Conflicto: el proyecto pide Texto ^2.0 directamente y Json5 1.x pide Texto ^1.0
"$F" add Texto --version "^2.0" > "$T/conf.log" 2>&1 && die "el conflicto no se detectó"
grep -q "conflicto" "$T/conf.log" && grep -q "Json5 1.2.0 pide ^1.0" "$T/conf.log" && grep -q "App.fstproj pide ^2.0" "$T/conf.log" ||
    { cat "$T/conf.log"; die "mensaje de conflicto"; }
grep -q 'Include="Texto"' App.fstproj && die "el .fstproj cambió tras el conflicto"
# Con Json5 sin restricción se retrocede/avanza a una combinación válida (Json5 2.0.0 usa Texto ^2.0)
"$F" add Json5 --version ">=1.0" > /dev/null 2>&1 || die "add con otra versión"
"$F" add Texto --version "^2.0" > "$T/idx.log" 2>&1 || { cat "$T/idx.log"; die "add desde el índice"; }
grep -q 'Include="Texto" Version="^2.0"' App.fstproj || die "Texto del índice"
out=$("$F" run 2>/dev/null)
[ "$out" = "Json5 2.0.0 usa Texto 2.0.0" ] || die "combinación: $out"
# Retroceso: Json5 sin límite pero Texto ^1.0 -> la versión más alta de Json5 compatible (1.2.0)
"$F" add Texto --version "^1.0" > /dev/null 2>&1 || die "retroceso"
out=$("$F" run 2>/dev/null)
[ "$out" = "Json5 1.2.0 usa Texto 1.1.0" ] || die "retroceso: $out"

# remove
"$F" remove Texto > /dev/null || die "remove"
grep -q 'Include="Texto"' App.fstproj && die "remove no quitó la línea"
grep -q 'Include="Json5"' App.fstproj || die "remove quitó otra cosa"
"$F" remove Nada > /dev/null 2>&1 && die "remove de un paquete inexistente"

# Branch y Commit
c100=$($G --git-dir="$R/texto.git" rev-parse "v1.0.0^{commit}")
sed -i "s|<PackageReference Include=\"Json5\"[^>]*>|<PackageReference Include=\"Json5\" Git=\"../remotos/json5.git\" Branch=\"main\" />|" App.fstproj
cat > Program.fst <<'FST'
namespace App
{
    public static class Program
    {
        public static void Main() { Console.WriteLine(Json5.Info.Todo()); }
    }
}
FST
"$F" restore > /dev/null 2>"$T/br.err" || { cat "$T/br.err"; die "Branch"; }
grep -q '"rama": "main"' paquetes.lock || die "lock con rama"
out=$("$F" run 2>/dev/null)
[ "$out" = "Json5 2.0.0 usa Texto 2.0.0" ] || die "Branch: $out"
# Commit (abreviado) fija Texto aunque Json5 pida ^2.0: Branch/Commit mandan sobre Version
"$F" add "$R/texto.git" --commit "${c100:0:9}" > "$T/commit.log" 2>&1 || { cat "$T/commit.log"; die "add --commit"; }
grep -q '"fijo": true' paquetes.lock && grep -q "\"commit\": \"$c100\"" paquetes.lock || { cat paquetes.lock; die "lock con commit"; }
out=$("$F" run 2>/dev/null)
[ "$out" = "Json5 2.0.0 usa Texto 1.0.0" ] || die "Commit: $out"
"$F" remove Texto > /dev/null || die "remove Texto fijo"

# Path: biblioteca local
cd "$T" && "$F" new MiLib --lib > /dev/null || die "new MiLib"
cd "$T/App" && "$F" add ../MiLib > /dev/null || die "add ruta"
grep -q 'Include="MiLib" Path="../MiLib"' App.fstproj || { cat App.fstproj; die "Path"; }
"$F" list paquetes | grep -q "MiLib (ruta ../MiLib)" || die "list ruta"

# Quitar todos: desaparecen el <ItemGroup> y paquetes.lock, y el proyecto sigue compilando
cp App.fstproj "$T/App.antes"
cp Program.fst "$T/Program.antes"
printf 'namespace App { public static class Program { public static void Main() { Console.WriteLine("sin paquetes"); } } }\n' > Program.fst
"$F" remove Json5 > /dev/null && "$F" remove MiLib > /dev/null || die "remove de todos"
grep -q "PackageReference" App.fstproj && die "quedó un PackageReference"
[ "$(grep -c "<ItemGroup>" App.fstproj)" = 1 ] || { cat App.fstproj; die "quedó un <ItemGroup> vacío"; }
[ -f paquetes.lock ] && die "paquetes.lock debería borrarse"
[ "$("$F" run 2>/dev/null)" = "sin paquetes" ] || die "run sin paquetes"
cp "$T/App.antes" App.fstproj
cp "$T/Program.antes" Program.fst

# Paquete desconocido sin índice
FASET_PAQUETES_INDICE="$T/no-existe.json" "$F" add NoExiste > "$T/nx.log" 2>&1 && die "paquete desconocido"
grep -q "no está disponible" "$T/nx.log" || { cat "$T/nx.log"; die "mensaje sin índice"; }

# new --package y pack
cd "$T" && "$F" new MiPaquete --lib --package > /dev/null || die "new --package"
grep -q "<PackageId>MiPaquete</PackageId>" MiPaquete/MiPaquete.fstproj && [ -f MiPaquete/README.md ] || die "plantilla de paquete"
(cd MiPaquete && "$F" pack | grep -q "git tag v0.1.0") || die "pack"
(cd MiPaquete && "$F" publish | grep -q '"versiones":\["0.1.0"\]') || die "publish"
(cd App && "$F" pack > /dev/null 2>&1) && die "pack de un Exe"
echo ok
