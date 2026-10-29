#!/usr/bin/env node
// Extrae la API pública de la biblioteca estándar (lib/std/*.fst) y la guarda en
// generated/api.json. Se ejecuta antes de `next build` / `next dev` (prebuild/predev),
// así los módulos nuevos (net.fst, thread.fst...) aparecen solos en la documentación.
//
// No es un parser completo de Faset: recorre el texto llevando la cuenta de llaves,
// cadenas y comentarios, y clasifica cada declaración a nivel de namespace o de tipo.
// Se queda con lo público y con los comentarios `//` que la preceden (o la siguen en la
// misma línea).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const docsDir = path.resolve(here, "..");
const libDir = process.env.FASET_STD_DIR || path.resolve(docsDir, "..", "lib", "std");
const outDir = path.join(docsDir, "generated");

const MODIFIERS = new Set([
  "public", "private", "protected", "internal", "static", "extern", "const", "readonly",
  "unsafe", "memory_unsafe", "partial", "virtual", "override", "abstract", "sealed", "inline", "new",
]);
const ACCESS = new Set(["public", "private", "protected", "internal"]);

// Comentarios de una línea que solo sirven de separador visual.
function isDecorative(line) {
  return /^[-=*_\s]{6,}/.test(line) || /-{6,}/.test(line) || /={6,}/.test(line);
}

function cleanDoc(lines) {
  const out = [];
  for (const l of lines) {
    if (isDecorative(l)) continue;
    out.push(l.replace(/^\/\/\/?\s?/, ""));
  }
  while (out.length && !out[0].trim()) out.shift();
  while (out.length && !out[out.length - 1].trim()) out.pop();
  return out.join("\n");
}

function squash(s) {
  return s.replace(/\s+/g, " ").replace(/\s*,\s*/g, ", ").replace(/\(\s+/g, "(").replace(/\s+\)/g, ")").trim();
}

// Índice del primer '=' de asignación (no '==', '=>', '<=', '>=', '!=') fuera de < > ( ).
function assignIndex(h) {
  let depth = 0;
  for (let i = 0; i < h.length; i++) {
    const c = h[i];
    if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") depth--;
    else if (c === "=" && depth === 0) {
      const p = h[i - 1], n = h[i + 1];
      if (n === "=" || n === ">" || p === "=" || p === "!" || p === "<" || p === ">") {
        if (n === "=" || n === ">") i++;
        continue;
      }
      return i;
    }
  }
  return -1;
}

function splitModifiers(h) {
  const mods = [];
  let rest = h;
  for (;;) {
    const m = /^([A-Za-z_]\w*)\s+/.exec(rest);
    if (!m || !MODIFIERS.has(m[1])) break;
    mods.push(m[1]);
    rest = rest.slice(m[0].length);
  }
  return { mods, rest };
}

// Separa la parte de "declaración" de un cuerpo por expresión (=> ...).
function cutArrow(h) {
  let depth = 0;
  for (let i = 0; i < h.length - 1; i++) {
    const c = h[i];
    if (c === "(") depth++;
    else if (c === ")") depth--;
    else if (c === "=" && h[i + 1] === ">" && depth === 0) return { decl: h.slice(0, i).trim(), body: h.slice(i + 2).trim() };
  }
  return { decl: h.trim(), body: null };
}

function parseFile(file) {
  const src = fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
  const moduleId = path.basename(file, ".fst");

  // Comentario de cabecera del archivo.
  const headLines = [];
  for (const line of src.split("\n")) {
    const t = line.trim();
    if (t.startsWith("//")) headLines.push(t);
    else if (t === "") { if (headLines.length) headLines.push("//"); }
    else break;
  }
  const header = cleanDoc(headLines);

  const mod = {
    id: moduleId,
    file: path.relative(path.resolve(docsDir, ".."), file).split(path.sep).join("/"),
    namespace: null,
    summary: header,
    types: [],
    functions: [],
    lines: src.split("\n").length,
  };

  // Estado del recorrido.
  const stack = [{ kind: "root" }];
  let buf = "";
  let bufLine = 1;
  let docLines = [];
  let line = 1;
  let lastDecl = null;
  let lastDeclLine = -1;
  let sawBlank = false;

  const top = () => stack[stack.length - 1];
  const memberLevel = () => ["root", "namespace", "type"].includes(top().kind);
  const currentType = () => {
    for (let i = stack.length - 1; i >= 0; i--) if (stack[i].kind === "type") return stack[i];
    return null;
  };
  const currentNamespace = () => {
    const parts = [];
    for (const s of stack) if (s.kind === "namespace") parts.push(s.name);
    return parts.join(".");
  };

  function takeDoc() {
    const d = cleanDoc(docLines);
    docLines = [];
    return d;
  }

  // Procesa una cabecera terminada en ';' o '{'. Devuelve el tipo de bloque a abrir.
  function declaration(raw, terminator) {
    let h = raw.replace(/\s+/g, " ").trim();
    const doc = takeDoc();
    // Atributos [Export("...")]
    while (/^\[[^\]]*\]\s*/.test(h)) h = h.replace(/^\[[^\]]*\]\s*/, "");
    const type = currentType();
    // Secciones al estilo C++: public: / private:
    for (;;) {
      const m = /^(public|private|protected|internal)\s*:(?!:)\s*/.exec(h);
      if (!m) break;
      if (type) type.section = m[1];
      h = h.slice(m[0].length);
    }
    if (!h) return terminator === "{" ? { kind: "skip" } : null;
    if (/^(using|import)\b/.test(h) || h.startsWith("=") || h.startsWith("#")) return terminator === "{" ? { kind: "skip" } : null;

    const ns = /^namespace\s+([\w.:]+)/.exec(h);
    if (ns) {
      const name = ns[1].replace(/::/g, ".");
      if (!mod.namespace) mod.namespace = name;
      if (terminator === "{") return { kind: "namespace", name };
      // namespace X;  (para todo el archivo)
      stack.push({ kind: "namespace", name, fileScoped: true });
      return null;
    }

    const { mods, rest } = splitModifiers(h);
    const explicitAccess = mods.find((m) => ACCESS.has(m));
    let isPublic;
    if (!type) isPublic = explicitAccess === "public";
    else if (explicitAccess) isPublic = explicitAccess === "public";
    else isPublic = (type.section || type.defaultAccess) === "public";
    if (type && !type.public) isPublic = false;

    const tm = /^(class|struct|enum|interface)\s+([A-Za-z_]\w*(?:\s*<[^>]*>)?)/.exec(rest);
    if (tm && terminator === "{") {
      const t = {
        kind: tm[1],
        name: tm[2].replace(/\s+/g, ""),
        namespace: currentNamespace(),
        parent: type ? type.name : null,
        modifiers: mods.filter((m) => !ACCESS.has(m)),
        signature: squash([...mods, rest].join(" ")),
        doc,
        members: [],
        values: [],
        line: bufLine,
      };
      const isPub = explicitAccess === "public" && (!type || type.public);
      const frame = {
        kind: tm[1] === "enum" ? "enum" : "type",
        name: t.name,
        baseName: t.name.replace(/<.*/, ""),
        defaultAccess: tm[1] === "struct" ? "public" : "private",
        public: isPub,
        info: t,
        enumText: "",
      };
      if (isPub) mod.types.push(t);
      return frame;
    }

    if (!isPublic) return terminator === "{" ? { kind: "skip" } : null;
    if (rest.startsWith("~")) return terminator === "{" ? { kind: "skip" } : null; // destructor

    const flags = mods.filter((m) => !ACCESS.has(m));
    const { decl, body } = cutArrow(rest);
    const paren = decl.indexOf("(");
    const assign = assignIndex(decl);
    let member;
    if (/\boperator\b/.test(decl)) {
      member = { kind: "operator", name: "operator" + (/operator\s*([^\s(]+)/.exec(decl)?.[1] ?? "") };
    } else if (paren >= 0 && (assign < 0 || paren < assign)) {
      const nm = /([A-Za-z_]\w*)\s*(?:<[^()]*>)?\s*$/.exec(decl.slice(0, paren));
      const name = nm ? nm[1] : decl.slice(0, paren);
      const isCtor = type && name === type.baseName && !/\S\s+\S/.test(decl.slice(0, paren).trim());
      member = { kind: isCtor ? "constructor" : "method", name };
      if (/\(\s*this\s+/.test(decl)) {
        member.extension = true;
        member.extends = /\(\s*this\s+([^\s,)]+)/.exec(decl)[1];
      }
    } else if (terminator === "{") {
      const nm = /([A-Za-z_]\w*)\s*$/.exec(decl);
      member = { kind: "property", name: nm ? nm[1] : decl };
    } else if (body !== null) {
      const nm = /([A-Za-z_]\w*)\s*$/.exec(decl);
      member = { kind: "property", name: nm ? nm[1] : decl, access: "get" };
      member.signature = squash([...flags, decl].join(" ")) + " { get; }";
    } else {
      const left = assign >= 0 ? decl.slice(0, assign) : decl;
      const nm = /([A-Za-z_]\w*)\s*$/.exec(left.split(",")[0].trim());
      member = { kind: flags.includes("const") ? "const" : "field", name: nm ? nm[1] : left };
      // En las constantes se conserva el valor; en los campos, solo la declaración.
      if (!flags.includes("const") && assign >= 0) {
        member.signature = squash([...flags, decl.slice(0, assign)].join(" "));
      }
    }
    if (!member.signature) member.signature = squash([...flags, decl].join(" "));
    member.static = flags.includes("static") || flags.includes("const");
    if (flags.includes("extern")) member.extern = true;
    member.doc = doc;
    member.line = bufLine;
    // Requiere un contexto memory_unsafe: marcado así o con punteros en la firma.
    if (flags.includes("memory_unsafe") || /\b[A-Za-z_]\w*\s*\*(?!<)/.test(member.signature.replace(/delegate\*</g, "delegate<")))
      member.unsafe = true;
    // Las ramas de #if WINDOWS / #else declaran lo mismo dos veces: una sola entrada.
    const list = type ? type.info.members : mod.functions;
    const dup = list.find((m) => m.signature === member.signature);
    if (dup) {
      if (!dup.doc) dup.doc = member.doc;
    } else if (type) list.push(member);
    else {
      member.namespace = currentNamespace();
      list.push(member);
    }
    lastDecl = member;
    lastDeclLine = line;
    if (terminator === "{") return { kind: member.kind === "property" ? "property" : "skip", member, text: "" };
    return null;
  }

  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    const next = src[i + 1];

    // Comentarios
    if (c === "/" && next === "/") {
      const end = src.indexOf("\n", i);
      const text = src.slice(i, end < 0 ? n : end).trim();
      if (memberLevel()) {
        if (!buf.trim()) {
          if (lastDecl && lastDeclLine === line && !lastDecl.doc) {
            lastDecl.doc = cleanDoc([text]);
          } else {
            if (sawBlank) docLines = [];
            sawBlank = false;
            docLines.push(text);
          }
        }
      }
      i = end < 0 ? n : end;
      continue;
    }
    if (c === "/" && next === "*") {
      const end = src.indexOf("*/", i + 2);
      const chunk = src.slice(i, end < 0 ? n : end + 2);
      line += (chunk.match(/\n/g) || []).length;
      i = end < 0 ? n : end + 2;
      continue;
    }
    // Cadenas y caracteres
    if (c === '"' || c === "'" || (c === "@" && next === '"')) {
      const verbatim = c === "@";
      const q = verbatim ? '"' : c;
      let j = i + (verbatim ? 2 : 1);
      while (j < n) {
        if (!verbatim && src[j] === "\\") { j += 2; continue; }
        if (src[j] === q) {
          if (verbatim && src[j + 1] === '"') { j += 2; continue; }
          break;
        }
        if (src[j] === "\n") line++;
        j++;
      }
      const lit = src.slice(i, j + 1);
      if (memberLevel()) buf += lit;
      else if (top().kind === "enum") top().enumText += lit;
      i = j + 1;
      continue;
    }
    // Directivas del preprocesador (#if WINDOWS...) a principio de línea
    if (c === "#" && /(^|\n)[ \t]*$/.test(src.slice(Math.max(0, i - 200), i))) {
      const end = src.indexOf("\n", i);
      i = end < 0 ? n : end;
      continue;
    }
    if (c === "\n") {
      line++;
      if (memberLevel()) {
        if (!buf.trim()) {
          // ¿línea en blanco? separa los comentarios de lo que viene después
          const prevNl = src.lastIndexOf("\n", i - 1);
          if (!src.slice(prevNl + 1, i).trim()) sawBlank = true;
        } else buf += " ";
      } else if (top().kind === "enum") top().enumText += "\n";
      i++;
      continue;
    }

    const t = top();
    if (memberLevel()) {
      if (c === "{") {
        if (/=>|=(?![=>])/.test(buf) && !/^\s*(public|private|static|\w)/.test("") ) {
          // ¿Inicializador o expresión con llaves? Solo si ya hay '=' / '=>' en la cabecera.
          const ai = assignIndex(buf);
          if (buf.includes("=>") || ai >= 0) {
            stack.push({ kind: "inner" });
            i++;
            continue;
          }
        }
        const frame = declaration(buf, "{") || { kind: "skip" };
        stack.push(frame);
        buf = "";
        sawBlank = false;
        i++;
        continue;
      }
      if (c === ";") {
        declaration(buf, ";");
        buf = "";
        sawBlank = false;
        i++;
        continue;
      }
      if (c === "}") {
        // fin de namespace o tipo
        const popped = stack.pop();
        buf = "";
        docLines = [];
        if (popped && popped.kind === "root") stack.push(popped);
        i++;
        continue;
      }
      if (!buf.trim()) bufLine = line;
      buf += c;
      if (sawBlank && c.trim()) { docLines = []; sawBlank = false; }
      i++;
      continue;
    }

    // Dentro de un cuerpo (método, propiedad, enum, inicializador)
    if (c === "{") {
      stack.push({ kind: t.kind === "enum" ? "skip" : t.kind === "property" ? "propinner" : "skip" });
      i++;
      continue;
    }
    if (c === "}") {
      const popped = stack.pop();
      if (popped.kind === "enum") {
        popped.info.values = popped.enumText
          .split(",")
          .map((v) => v.replace(/\/\/.*$/gm, "").trim())
          .filter(Boolean)
          .map((v) => {
            const [name, value] = v.split("=").map((s) => s.trim());
            return value ? { name, value } : { name };
          });
      } else if (popped.kind === "property") {
        const txt = popped.text;
        const hasGet = /\bget\b/.test(txt);
        const hasSet = /\bset\b/.test(txt);
        popped.member.access = hasGet && hasSet ? "get; set" : hasSet ? "set" : "get";
        popped.member.signature += ` { ${popped.member.access}; }`;
      }
      if (popped.kind === "type" || popped.kind === "enum" || popped.kind === "namespace") {
        docLines = [];
      }
      i++;
      continue;
    }
    if (t.kind === "enum") t.enumText += c;
    if (t.kind === "property") t.text += c;
    i++;
  }

  // Limpieza: quita los tipos sin miembros públicos que solo agrupan bindings `extern`.
  for (const t of mod.types) {
    const pub = t.members;
    t.native = pub.length > 0 && pub.every((m) => m.extern);
    delete t.line;
  }
  return mod;
}

function main() {
  if (!fs.existsSync(libDir)) {
    console.error(`extract-api: no existe ${libDir}`);
    process.exit(1);
  }
  const files = fs
    .readdirSync(libDir)
    .filter((f) => f.endsWith(".fst"))
    .sort()
    .map((f) => path.join(libDir, f));
  const modules = files.map(parseFile);
  // 'core' primero; el resto por orden alfabético.
  modules.sort((a, b) => (a.id === "core" ? -1 : b.id === "core" ? 1 : a.id.localeCompare(b.id)));
  fs.mkdirSync(outDir, { recursive: true });
  const data = { generatedFrom: "lib/std", modules };
  fs.writeFileSync(path.join(outDir, "api.json"), JSON.stringify(data, null, 1) + "\n");
  let members = 0;
  for (const m of modules) members += m.functions.length + m.types.reduce((s, t) => s + t.members.length, 0);
  console.log(`extract-api: ${modules.length} módulos, ${members} miembros públicos -> generated/api.json`);
}

main();
