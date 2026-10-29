"use client";

import { useEffect, useState } from "react";

export default function ThemeToggle() {
  const [theme, setTheme] = useState<string>("dark");
  useEffect(() => {
    setTheme(document.documentElement.dataset.theme || "dark");
  }, []);
  function toggle() {
    const next = theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem("faset-theme", next);
    } catch {
      /* almacenamiento no disponible */
    }
    setTheme(next);
  }
  return (
    <button type="button" className="icon-btn" onClick={toggle} aria-label={theme === "dark" ? "Cambiar a tema claro" : "Cambiar a tema oscuro"}>
      {theme === "dark" ? (
        <svg viewBox="0 0 20 20" width="17" height="17" aria-hidden="true">
          <circle cx="10" cy="10" r="3.6" fill="none" stroke="currentColor" strokeWidth="1.5" />
          <path
            d="M10 1.8v2M10 16.2v2M1.8 10h2M16.2 10h2M4.2 4.2l1.4 1.4M14.4 14.4l1.4 1.4M4.2 15.8l1.4-1.4M14.4 5.6l1.4-1.4"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
          />
        </svg>
      ) : (
        <svg viewBox="0 0 20 20" width="17" height="17" aria-hidden="true">
          <path d="M16.5 12.3A7 7 0 0 1 7.7 3.5a7 7 0 1 0 8.8 8.8Z" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" />
        </svg>
      )}
    </button>
  );
}
