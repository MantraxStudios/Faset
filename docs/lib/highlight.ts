// Resaltado de sintaxis en tiempo de compilación con Shiki (los bloques llegan ya
// coloreados al HTML estático). Incluye la gramática TextMate de Faset, basada en la
// de editors/vscode, y trata .fstui y .fstproj como XML.
import { createHighlighter, type Highlighter } from "shiki";
import fasetGrammar from "@/grammars/faset.tmLanguage.json";

const LANGS = ["xml", "bash", "c", "cpp", "json", "python", "javascript", "ini", "text"] as const;

const ALIASES: Record<string, string> = {
  fst: "faset",
  faset: "faset",
  csharp: "faset",
  cs: "faset",
  fstui: "xml",
  fstproj: "xml",
  sh: "bash",
  shell: "bash",
  console: "bash",
  js: "javascript",
  py: "python",
  txt: "text",
  plaintext: "text",
};

let highlighter: Promise<Highlighter> | null = null;

function getHighlighter() {
  if (!highlighter) {
    highlighter = createHighlighter({
      themes: ["github-dark-default", "github-light-default"],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      langs: [{ ...(fasetGrammar as any), name: "faset", aliases: ["fst"] }, ...LANGS],
    });
  }
  return highlighter;
}

export function resolveLang(lang: string | undefined) {
  const l = (lang || "text").toLowerCase();
  return ALIASES[l] ?? ((LANGS as readonly string[]).includes(l) ? l : "text");
}

export async function highlight(code: string, lang: string | undefined) {
  const h = await getHighlighter();
  return h.codeToHtml(code, {
    lang: resolveLang(lang),
    themes: { dark: "github-dark-default", light: "github-light-default" },
    defaultColor: false,
  });
}
