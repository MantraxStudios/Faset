#!/usr/bin/env node
// Genera generated/cli.json con la ayuda de la línea de órdenes (`faset help`).
// Si el compilador ya está construido (../faset) se ejecuta; si no, se lee el texto de
// usage() directamente de src/main.cpp, así la documentación compila sin el binario.
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const docsDir = path.resolve(here, "..");
const repo = path.resolve(docsDir, "..");
const outDir = path.join(docsDir, "generated");

function fromBinary() {
  for (const exe of ["faset", "faset.exe"]) {
    const p = path.join(repo, exe);
    if (!fs.existsSync(p)) continue;
    try {
      return { text: execFileSync(p, ["help"], { encoding: "utf8" }), source: "faset help" };
    } catch {
      /* se intenta con el código fuente */
    }
  }
  return null;
}

function fromSource() {
  const src = fs.readFileSync(path.join(repo, "src", "main.cpp"), "utf8");
  const start = src.indexOf("static void usage()");
  const body = src.slice(start, src.indexOf("kVersion);", start));
  const version = /kVersion\s*=\s*"([^"]+)"/.exec(src)?.[1] ?? "";
  let text = "";
  for (const m of body.matchAll(/"((?:[^"\\]|\\.)*)"/g)) {
    text += m[1].replace(/\\n/g, "\n").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
  }
  return { text: text.replace("%s", version), source: "src/main.cpp" };
}

const got = fromBinary() ?? fromSource();
const lines = got.text.split("\n");
const commands = [];
const options = [];
let section = "";
for (const line of lines) {
  if (/^Uso:/.test(line)) { section = "uso"; continue; }
  if (/^Opciones:/.test(line)) { section = "opciones"; continue; }
  if (/^Entrada:/.test(line) || (!line.startsWith("  ") && line.trim())) { if (section !== "") section = "otro"; }
  const m = /^  (\S.*\S)\s{2,}(\S.*)$/.exec(line);
  if (section === "uso") {
    if (m) commands.push({ usage: m[1].replace(/\s+/g, " "), description: m[2].trim() });
    else if (line.trim()) commands.push({ usage: line.trim(), description: "" });
  } else if (section === "opciones" && m) {
    options.push({ flag: m[1].replace(/\s{2,}/g, "  "), description: m[2].trim() });
  }
}
const versionMatch = /Faset (\d+\.\d+\.\d+)/.exec(got.text);
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(
  path.join(outDir, "cli.json"),
  JSON.stringify({ source: got.source, version: versionMatch?.[1] ?? "", text: got.text.trimEnd(), commands, options }, null, 1) + "\n",
);
console.log(`extract-cli: ${commands.length} órdenes, ${options.length} opciones (desde ${got.source})`);
