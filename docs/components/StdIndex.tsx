import Link from "next/link";
import { moduleBlurb, moduleTitle, modules } from "@/lib/api";

export default function StdIndex() {
  return (
    <div className="card-grid">
      {modules.map((m) => (
        <Link className="card" href={`/std/${m.id}/`} key={m.id}>
          <span className="card-title">{moduleTitle(m)}</span>
          <span className="card-text">{moduleBlurb(m)}</span>
        </Link>
      ))}
    </div>
  );
}
