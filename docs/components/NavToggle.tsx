"use client";

export default function NavToggle() {
  return (
    <button
      type="button"
      className="icon-btn nav-toggle"
      aria-label="Abrir el menú de navegación"
      onClick={() => window.dispatchEvent(new Event("faset:toggle-nav"))}
    >
      <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true">
        <path d="M3 5.5h14M3 10h14M3 14.5h14" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
      </svg>
    </button>
  );
}
