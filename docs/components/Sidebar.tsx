"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { nav, normalize } from "@/lib/nav";

export default function Sidebar() {
  const pathname = normalize(usePathname() || "/");
  const [open, setOpen] = useState(false);

  useEffect(() => setOpen(false), [pathname]);
  useEffect(() => {
    const toggle = () => setOpen((o) => !o);
    window.addEventListener("faset:toggle-nav", toggle);
    return () => window.removeEventListener("faset:toggle-nav", toggle);
  }, []);

  return (
    <>
      <div className={`sidebar-backdrop${open ? " open" : ""}`} onClick={() => setOpen(false)} />
      <nav className={`sidebar${open ? " open" : ""}`} aria-label="Documentación">
        {nav.map((section) => (
          <div className="nav-section" key={section.title}>
            <div className="nav-title">{section.title}</div>
            <ul>
              {section.items.map((item) => {
                const active = pathname === item.href;
                return (
                  <li key={item.href}>
                    <Link href={item.href} className={active ? "active" : undefined} aria-current={active ? "page" : undefined}>
                      <span>{item.title}</span>
                      {item.status === "dev" ? <span className="nav-dev" title="En desarrollo" /> : null}
                    </Link>
                  </li>
                );
              })}
            </ul>
          </div>
        ))}
      </nav>
    </>
  );
}
