#!/usr/bin/env node
// Construye public/search-index.json para la búsqueda del lado del cliente:
// páginas .mdx (título, secciones y texto) + la API extraída de lib/std.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const docsDir = path.resolve(here, "..");
const appDocs = path.join(docsDir, "app", "(docs)");
const api = JSON.parse(fs.readFileSync(path.join(docsDir, "generated", "api.json"), "utf8"));

// Secciones de la barra lateral (se leen de lib/nav.ts con una expresión regular sencilla).
const navSrc = fs.readFileSync(path.join(docsDir, "lib", "nav.ts"), "utf8");
const sectionOf = {};
{
  let current = "";
  for (const line of navSrc.split("\n")) {
    const sec = /^\s{4}title: "([^"]+)",$/.exec(line);
    if (sec) current = sec[1];
    const item = /href: "([^"]+)"/.exec(line);
    if (item && current) sectionOf[item[1]] = current;
  }
}

function slugify(text) {
  return text
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
}

function plain(md) {
  return md
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/^(import|export)\s.*$/gm, " ")
    .replace(/<\/?[A-Za-z][^>]*>/g, " ")
    .replace(/\{\/\*[\s\S]*?\*\/\}/g, " ")
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[`*_>#|]/g, " ")
    .replace(/-{3,}/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function walk(dir, out = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name === "page.mdx") out.push(p);
  }
  return out;
}

const docs = [];
for (const file of walk(appDocs)) {
  const src = fs.readFileSync(file, "utf8");
  const rel = path.relative(appDocs, path.dirname(file)).split(path.sep).join("/");
  const href = "/" + (rel ? rel + "/" : "");
  const title = /title:\s*"([^"]+)"/.exec(src)?.[1] ?? /^#\s+(.+)$/m.exec(src)?.[1] ?? rel;
  const section = sectionOf[href] ?? "";
  // Texto por secciones (## / ###)
  const parts = src.split(/^(?=#{2,3}\s)/m);
  const intro = plain(parts[0]);
  docs.push({ t: title, h: href, s: section, x: intro.slice(0, 600), k: "page" });
  for (const part of parts.slice(1)) {
    const hm = /^#{2,3}\s+(.+)$/m.exec(part);
    if (!hm) continue;
    const heading = hm[1].replace(/[`*]/g, "").trim();
    const body = plain(part.slice(hm[0].length));
    docs.push({ t: heading, h: `${href}#${slugify(heading)}`, s: title, x: body.slice(0, 400), k: "section" });
  }
}

for (const m of api.modules) {
  const href = `/std/${m.id}/`;
  const modTitle = m.id === "core" ? "std" : m.namespace ?? `std.${m.id}`;
  docs.push({ t: modTitle, h: href, s: "Biblioteca estándar", x: m.summary.replace(/\s+/g, " ").slice(0, 400), k: "page" });
  for (const f of m.functions) {
    docs.push({ t: f.name, h: `${href}#funciones-globales`, s: modTitle, x: `${f.signature} ${f.doc}`.trim(), k: "api" });
  }
  for (const t of m.types) {
    const anchor = t.name.replace(/<.*/, "").toLowerCase();
    docs.push({ t: t.name, h: `${href}#${anchor}`, s: modTitle, x: `${t.signature} ${t.doc} ${t.values.map((v) => v.name).join(" ")}`.trim(), k: "api" });
    const seen = new Set();
    for (const mem of t.members) {
      const key = mem.name;
      if (seen.has(key)) continue; // las sobrecargas comparten entrada
      seen.add(key);
      const base = t.name.replace(/<.*/, "");
      docs.push({ t: `${base}.${mem.name}`, h: `${href}#${anchor}`, s: modTitle, x: `${mem.signature} ${mem.doc}`.trim(), k: "api" });
    }
  }
}

fs.writeFileSync(path.join(docsDir, "public", "search-index.json"), JSON.stringify(docs));
console.log(`build-search-index: ${docs.length} entradas -> public/search-index.json`);
