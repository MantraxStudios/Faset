"use client";

import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";

type Entry = { id: string; text: string; level: number };

// Índice de la página: se construye a partir de los h2/h3 del artículo.
export default function Toc() {
  const pathname = usePathname();
  const [entries, setEntries] = useState<Entry[]>([]);
  const [active, setActive] = useState<string>("");

  useEffect(() => {
    const hs = Array.from(document.querySelectorAll<HTMLElement>("article.prose h2[id], article.prose h3[id]"));
    setEntries(
      hs.map((h) => ({
        id: h.id,
        text: (h.textContent || "").replace(/^#/, "").trim(),
        level: h.tagName === "H2" ? 2 : 3,
      })),
    );
    if (!hs.length) return;
    const obs = new IntersectionObserver(
      (items) => {
        const visible = items.filter((i) => i.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
        if (visible[0]) setActive(visible[0].target.id);
      },
      { rootMargin: "-72px 0px -70% 0px" },
    );
    hs.forEach((h) => obs.observe(h));
    return () => obs.disconnect();
  }, [pathname]);

  if (entries.length < 2) return <div className="toc" />;
  return (
    <div className="toc">
      <div className="toc-title">En esta página</div>
      <ul>
        {entries.map((e) => (
          <li key={e.id} className={`lvl-${e.level}${active === e.id ? " active" : ""}`}>
            <a href={`#${e.id}`}>{e.text}</a>
          </li>
        ))}
      </ul>
    </div>
  );
}
