"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { flatNav, normalize } from "@/lib/nav";

export default function PrevNext() {
  const pathname = normalize(usePathname() || "/");
  const i = flatNav.findIndex((n) => n.href === pathname);
  if (i < 0) return null;
  const prev = flatNav[i - 1];
  const next = flatNav[i + 1];
  return (
    <nav className="prevnext" aria-label="Paginación">
      {prev ? (
        <Link href={prev.href} className="pn prev">
          <span className="pn-label">Anterior</span>
          <span className="pn-title">{prev.title}</span>
        </Link>
      ) : (
        <span />
      )}
      {next ? (
        <Link href={next.href} className="pn next">
          <span className="pn-label">Siguiente</span>
          <span className="pn-title">{next.title}</span>
        </Link>
      ) : (
        <span />
      )}
    </nav>
  );
}
