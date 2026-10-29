import api from "@/generated/api.json";

export type ApiMember = {
  kind: "method" | "constructor" | "property" | "field" | "const" | "operator";
  name: string;
  signature: string;
  static?: boolean;
  extern?: boolean;
  unsafe?: boolean;
  extension?: boolean;
  extends?: string;
  access?: string;
  doc: string;
  line: number;
  namespace?: string;
};

export type ApiType = {
  kind: "class" | "struct" | "enum" | "interface";
  name: string;
  namespace: string;
  modifiers: string[];
  signature: string;
  doc: string;
  members: ApiMember[];
  values: { name: string; value?: string }[];
  native?: boolean;
};

export type ApiModule = {
  id: string;
  file: string;
  namespace: string | null;
  summary: string;
  types: ApiType[];
  functions: ApiMember[];
  lines: number;
};

export const modules = (api as unknown as { modules: ApiModule[] }).modules;

export function getModule(id: string) {
  return modules.find((m) => m.id === id);
}

export function moduleTitle(m: ApiModule) {
  return m.id === "core" ? "std" : m.namespace ?? `std.${m.id}`;
}

// Primer párrafo del comentario de cabecera, sin la línea "std.x — ".
export function moduleBlurb(m: ApiModule) {
  const first = m.summary.split("\n").find((l) => l.trim()) ?? "";
  return first.replace(/^\s*std(\.\w+)?\s*[—-]+\s*/, "").trim();
}

export function typeAnchor(t: ApiType) {
  return t.name.replace(/<.*/, "").toLowerCase();
}
