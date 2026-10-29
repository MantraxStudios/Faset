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
let col = 0; // columna en la que empiezan las descripciones de la sección actual
for (const line of lines) {
  if (/^Uso:/.test(line)) { section = "uso"; col = 0; continue; }
  if (/^Opciones:/.test(line)) { section = "opciones"; col = 0; continue; }
  if (line.trim() && !line.startsWith("  ")) { section = "otro"; continue; }
  if (section !== "uso" && section !== "opciones") continue;
  if (!line.trim()) continue;
  const list = section === "uso" ? commands : options;
  const key = section === "uso" ? "usage" : "flag";
  // Línea de continuación: más sangría de la normal.
  if (/^ {5,}/.test(line) && list.length) {
    const last = list[list.length - 1];
    last.description = (last.description + " " + line.trim()).trim();
    continue;
  }
  if (!col) {
    const m = /^  (\S.*\S)\s{2,}(\S.*)$/.exec(line);
    if (m) col = line.length - m[2].length;
  }
  let left = line, right = "";
  if (col && line.length > col && line[col - 1] === " ") {
    left = line.slice(0, col);
    right = line.slice(col);
  }
  list.push({ [key]: left.trim().replace(/\s{2,}/g, key === "usage" ? " " : "  "), description: right.trim() });
}
const versionMatch = /Faset (\d+\.\d+\.\d+)/.exec(got.text);
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(
  path.join(outDir, "cli.json"),
  JSON.stringify({ source: got.source, version: versionMatch?.[1] ?? "", text: got.text.trimEnd(), commands, options }, null, 1) + "\n",
);
console.log(`extract-cli: ${commands.length} órdenes, ${options.length} opciones (desde ${got.source})`);
