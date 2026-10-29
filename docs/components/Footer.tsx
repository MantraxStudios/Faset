import Link from "next/link";

export default function Footer({ compact = false }: { compact?: boolean }) {
  return (
    <footer className={compact ? "site-footer compact" : "site-footer"}>
      <div className="footer-inner">
        <span>
          Faset · MIT © 2026 MantraxStudios. Documentación generada desde el repositorio: la API de{" "}
          <Link href="/std/">lib/std</Link> se extrae del código fuente en cada compilación.
        </span>
      </div>
    </footer>
  );
}
