#!/usr/bin/env bash
# Regenera lib/android/faset_webview_dex.h a partir de WebViewBridge.java.
# Solo hace falta al cambiar el puente de Java (las apps usan el .h ya generado).
# Requiere: javac (JDK 11+), android.jar y d8 (build-tools) del SDK de Android.
set -euo pipefail
cd "$(dirname "$0")"
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
JAVAC=${JAVAC:-$(command -v javac || echo "$HOME/android-studio/jbr/bin/javac")}
export PATH="$(dirname "$JAVAC"):$PATH"   # d8 necesita 'java'
JAR=$(ls -d "$SDK"/platforms/android-*/android.jar | sort -V | tail -1)
D8=$(ls -d "$SDK"/build-tools/*/d8 | sort -V | tail -1)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
"$JAVAC" --release 8 -nowarn -cp "$JAR" -d "$OUT/classes" WebViewBridge.java 2>&1 | grep -v "^warning\|^Note\|^1 warning" || true
"$D8" --release --min-api 24 --lib "$JAR" --output "$OUT" $(find "$OUT/classes" -name '*.class')
python3 - "$OUT/classes.dex" ../faset_webview_dex.h <<'EOF'
import sys
data = open(sys.argv[1], 'rb').read()
lines = ["/* Generado por lib/android/webview/build_dex.sh a partir de WebViewBridge.java: no editar. */",
         "static const unsigned char faset_webview_dex[%d] = {" % len(data)]
for i in range(0, len(data), 20):
    lines.append("    " + ",".join(str(b) for b in data[i:i + 20]) + ",")
lines.append("};")
open(sys.argv[2], 'w').write("\n".join(lines) + "\n")
EOF
echo "faset_webview_dex.h: $(stat -c %s "$OUT/classes.dex") bytes de dex"
