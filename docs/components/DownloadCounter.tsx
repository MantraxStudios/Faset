"use client";

import { useEffect, useState } from "react";
import { asset } from "@/lib/util";

type Datos = { total: number | null; linux?: number; windows?: number };

// Descargas de las versiones publicadas. En faset.lat las sirve deploy/serve.mjs (/api/descargas, con
// caché); si no existe (npm run dev), se suman directamente desde la API de GitHub.
async function cargar(): Promise<Datos | null> {
  try {
    const r = await fetch(asset("/api/descargas"));
    if (r.ok) {
      const d = (await r.json()) as Datos;
      if (typeof d.total === "number") return d;
    }
  } catch {}
  try {
    const r = await fetch("https://api.github.com/repos/MantraxStudios/Faset/releases?per_page=100");
    if (!r.ok) return null;
    const rels = (await r.json()) as { assets?: { name: string; download_count: number }[] }[];
    const d = { total: 0, linux: 0, windows: 0 };
    for (const rel of rels)
      for (const a of rel.assets || []) {
        d.total += a.download_count;
        if (a.name.includes("linux")) d.linux += a.download_count;
        if (a.name.includes("windows")) d.windows += a.download_count;
      }
    return d;
  } catch {
    return null;
  }
}

export default function DownloadCounter({ detalle = false }: { detalle?: boolean }) {
  const [datos, setDatos] = useState<Datos | null>(null);
  useEffect(() => {
    cargar().then(setDatos);
  }, []);
  if (!datos || datos.total === null) return null;
  const fmt = (n: number) => n.toLocaleString("es");
  return (
    <div className="download-counter" title="Descargas de las versiones publicadas en GitHub">
      <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
        <path d="M8 2v8M4.5 6.5 8 10l3.5-3.5M3 13h10" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <strong>{fmt(datos.total)}</strong>
      <span>{datos.total === 1 ? "descarga" : "descargas"}</span>
      {detalle && datos.linux !== undefined && (
        <span className="dim">
          · Linux {fmt(datos.linux)} · Windows {fmt(datos.windows ?? 0)}
        </span>
      )}
    </div>
  );
}
