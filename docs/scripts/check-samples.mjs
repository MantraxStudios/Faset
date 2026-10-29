#!/usr/bin/env node
// Comprueba con `faset check` todos los ejemplos completos de la documentación: los bloques
// ```faset de los .mdx que contienen un punto de entrada (main / Main). Así los ejemplos no
// se quedan desfasados cuando cambia el compilador o la biblioteca estándar.
//
//   node scripts/check-samples.mjs            (requiere ../faset compilado)
//
// Los bloques ```fst (en lugar de ```faset) no se comprueban: se usan para funciones en
// desarrollo que el compilador de esta rama aún no acepta.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const docsDir = path.resolve(here, "..");
const faset = path.resolve(docsDir, "..", process.platform === "win32" ? "faset.exe" : "faset");

if (!fs.existsSync(faset)) {
  console.error("check-samples: compila primero el compilador (make en la raíz del repositorio)");
  process.exit(2);
}

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name.startsWith(".")) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith(".mdx")) out.push(p);
  }
  return out;
}

const files = [...walk(path.join(docsDir, "app")), ...walk(path.join(docsDir, "content"))];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "faset-docs-"));
let ok = 0;
let failed = 0;
let skipped = 0;
for (const file of files) {
  const src = fs.readFileSync(file, "utf8");
  const re = /```faset\n([\s\S]*?)```/g;
  let m;
  let n = 0;
  while ((m = re.exec(src))) {
    const code = m[1];
    n++;
    if (!/\b(main|Main)\s*\(/.test(code)) continue;
    if (/sin-comprobar/.test(code.split("\n")[0])) {
      skipped++;
      continue;
    }
    const f = path.join(tmp, `ejemplo_${ok + failed}.fst`);
    fs.writeFileSync(f, code);
    try {
      // Las ventanas (std.ui) y las APIs de Windows solo se comprueban, no se ejecutan.
      if (process.argv.includes("--run") && !/std\.ui|User32/.test(code)) {
        // Ejecuta el ejemplo y muestra su salida (para revisar los comentarios "// 42").
        const out = execFileSync(faset, ["run", f], { stdio: "pipe", encoding: "utf8", cwd: tmp, timeout: 20000 });
        console.log(`--- ${path.relative(docsDir, file)} (bloque ${n})\n${out.trimEnd()}`);
      } else {
        execFileSync(faset, ["check", f], { stdio: "pipe", encoding: "utf8" });
      }
      ok++;
    } catch (e) {
      // Ejemplos que muestran a propósito un 'Faset panic' (código 101): se marcan con "termina aquí".
      if (e.status === 101 && /termina aquí/.test(code) && /Faset panic/.test(e.stderr || "")) {
        console.log(`--- ${path.relative(docsDir, file)} (bloque ${n}) [panic esperado]\n${String(e.stderr).trimEnd()}`);
        ok++;
        continue;
      }
      failed++;
      const rel = path.relative(docsDir, file);
      console.error(`\n✗ ${rel} (bloque ${n})\n${(e.stdout || "") + (e.stderr || "")}`);
    }
  }
}
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`check-samples: ${ok} correctos, ${failed} con errores, ${skipped} omitidos`);
process.exit(failed ? 1 : 0);
