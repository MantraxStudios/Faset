"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { asset } from "@/lib/util";

type Doc = { t: string; h: string; s: string; x: string; k: "page" | "section" | "api" };
type Hit = Doc & { score: number };

const norm = (s: string) =>
  s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "");

let cache: Promise<Doc[]> | null = null;
function loadIndex() {
  if (!cache) cache = fetch(asset("/search-index.json")).then((r) => r.json());
  return cache;
}

function search(docs: Doc[], q: string): Hit[] {
  const terms = norm(q).split(/\s+/).filter(Boolean);
  if (!terms.length) return [];
  const hits: Hit[] = [];
  for (const d of docs) {
    const title = norm(d.t);
    const text = norm(d.x);
    let score = 0;
    let ok = true;
    for (const term of terms) {
      if (title === term) score += 30;
      else if (title.startsWith(term)) score += 16;
      else if (title.includes(term)) score += 10;
      else if (text.includes(term)) score += 2;
      else {
        ok = false;
        break;
      }
    }
    if (!ok) continue;
    if (d.k === "page") score += 3;
    if (d.k === "api") score += 1;
    hits.push({ ...d, score });
  }
  return hits.sort((a, b) => b.score - a.score).slice(0, 24);
}

function snippet(text: string, q: string) {
  const terms = norm(q).split(/\s+/).filter(Boolean);
  const n = norm(text);
  let at = -1;
  for (const t of terms) {
    at = n.indexOf(t);
    if (at >= 0) break;
  }
  if (at < 0) return text.slice(0, 110);
  const start = Math.max(0, at - 40);
  return (start > 0 ? "…" : "") + text.slice(start, start + 120) + (start + 120 < text.length ? "…" : "");
}

export default function Search() {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [docs, setDocs] = useState<Doc[]>([]);
  const [sel, setSel] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const router = useRouter();

  const show = useCallback(() => {
    setOpen(true);
    loadIndex().then(setDocs).catch(() => setDocs([]));
  }, []);

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const target = e.target as HTMLElement | null;
      const typing = target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.isContentEditable);
      if ((e.key === "k" && (e.metaKey || e.ctrlKey)) || (e.key === "/" && !typing)) {
        e.preventDefault();
        show();
      }
      if (e.key === "Escape") setOpen(false);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [show]);

  useEffect(() => {
    if (open) setTimeout(() => input.current?.focus(), 10);
    else setQ("");
  }, [open]);

  const hits = useMemo(() => search(docs, q), [docs, q]);
  useEffect(() => setSel(0), [q]);

  function go(h: Hit) {
    setOpen(false);
    router.push(h.h);
  }

  return (
    <>
      <button type="button" className="search-btn" onClick={show} aria-label="Buscar en la documentación">
        <svg viewBox="0 0 20 20" width="15" height="15" aria-hidden="true">
          <circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" strokeWidth="1.6" />
          <path d="m13 13 4 4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        <span className="search-label">Buscar…</span>
        <kbd className="kbd">Ctrl K</kbd>
      </button>
      {open ? (
        <div className="search-overlay" onClick={() => setOpen(false)} role="dialog" aria-modal="true" aria-label="Buscar">
          <div className="search-panel" onClick={(e) => e.stopPropagation()}>
            <div className="search-input">
              <svg viewBox="0 0 20 20" width="17" height="17" aria-hidden="true">
                <circle cx="8.5" cy="8.5" r="5.5" fill="none" stroke="currentColor" strokeWidth="1.6" />
                <path d="m13 13 4 4" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
              </svg>
              <input
                ref={input}
                value={q}
                placeholder="Buscar páginas, clases, métodos…"
                onChange={(e) => setQ(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === "ArrowDown") {
                    e.preventDefault();
                    setSel((s) => Math.min(s + 1, hits.length - 1));
                  } else if (e.key === "ArrowUp") {
                    e.preventDefault();
                    setSel((s) => Math.max(s - 1, 0));
                  } else if (e.key === "Enter" && hits[sel]) go(hits[sel]);
                }}
              />
              <kbd className="kbd">Esc</kbd>
            </div>
            <ul className="search-results">
              {q && !hits.length ? <li className="search-empty">Sin resultados para «{q}»</li> : null}
              {!q ? <li className="search-empty">Escribe para buscar en la guía, la CLI y la API de la biblioteca estándar.</li> : null}
              {hits.map((h, i) => (
                <li key={h.h + h.t + i}>
                  <button type="button" className={i === sel ? "sel" : undefined} onMouseEnter={() => setSel(i)} onClick={() => go(h)}>
                    <span className="sr-head">
                      <span className={`sr-kind k-${h.k}`}>{h.k === "api" ? "API" : h.k === "section" ? "#" : "Página"}</span>
                      <span className="sr-title">{h.t}</span>
                      <span className="sr-section">{h.s}</span>
                    </span>
                    <span className="sr-snippet">{snippet(h.x, q)}</span>
                  </button>
                </li>
              ))}
            </ul>
          </div>
        </div>
      ) : null}
    </>
  );
}
