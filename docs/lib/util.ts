import type { ReactNode } from "react";
import { isValidElement } from "react";

export const basePath = process.env.NEXT_PUBLIC_BASE_PATH || "";

// Ruta a un archivo de public/ respetando basePath.
export function asset(path: string) {
  return basePath + path;
}

export function textOf(node: ReactNode): string {
  if (node == null || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  if (isValidElement(node)) return textOf((node.props as { children?: ReactNode }).children);
  return "";
}

export function slugify(text: string) {
  return text
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-");
}

export function formatBytes(n: number) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1).replace(".", ",")} KB`;
  return `${(n / 1024 / 1024).toFixed(2).replace(".", ",")} MB`;
}

export function formatNum(n: number, digits = 2) {
  return n.toLocaleString("es-ES", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}
