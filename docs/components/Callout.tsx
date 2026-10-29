import type { ReactNode } from "react";

type Kind = "nota" | "aviso" | "dev" | "consejo";

const TITLES: Record<Kind, string> = {
  nota: "Nota",
  aviso: "Atención",
  dev: "En desarrollo",
  consejo: "Consejo",
};

export function Callout({ type = "nota", title, children }: { type?: Kind; title?: string; children: ReactNode }) {
  return (
    <aside className={`callout callout-${type}`}>
      <div className="callout-title">{title ?? TITLES[type]}</div>
      <div className="callout-body">{children}</div>
    </aside>
  );
}

export function DevBadge({ children = "En desarrollo" }: { children?: ReactNode }) {
  return <span className="badge-dev">{children}</span>;
}

export function Kbd({ children }: { children: ReactNode }) {
  return <kbd className="kbd">{children}</kbd>;
}
