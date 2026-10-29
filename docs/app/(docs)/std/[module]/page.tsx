import type { Metadata } from "next";
import { notFound } from "next/navigation";
import type { ComponentType } from "react";
import Signature from "@/components/Signature";
import { type ApiMember, type ApiType, getModule, moduleBlurb, moduleTitle, modules, typeAnchor } from "@/lib/api";
import { intros } from "@/content/std";

export const dynamicParams = false;

export function generateStaticParams() {
  return modules.map((m) => ({ module: m.id }));
}

export async function generateMetadata({ params }: { params: Promise<{ module: string }> }): Promise<Metadata> {
  const { module } = await params;
  const m = getModule(module);
  if (!m) return {};
  return { title: moduleTitle(m), description: moduleBlurb(m) };
}

const GROUPS: { title: string; test: (m: ApiMember) => boolean }[] = [
  { title: "Constructores", test: (m) => m.kind === "constructor" },
  { title: "Constantes", test: (m) => m.kind === "const" },
  { title: "Campos", test: (m) => m.kind === "field" },
  { title: "Propiedades", test: (m) => m.kind === "property" },
  { title: "Operadores", test: (m) => m.kind === "operator" },
  { title: "Métodos de extensión", test: (m) => m.kind === "method" && !!m.extension },
  { title: "Métodos estáticos", test: (m) => m.kind === "method" && !m.extension && !!m.static },
  { title: "Métodos", test: (m) => m.kind === "method" && !m.extension && !m.static },
];

function Members({ members }: { members: ApiMember[] }) {
  if (!members.length) return null;
  return (
    <div className="api-members">
      {GROUPS.map((g) => {
        const list = members.filter(g.test);
        if (!list.length) return null;
        return [
          <div className="api-group-title" key={g.title}>
            {g.title}
          </div>,
          ...list.map((m, i) => (
            <div className="api-member" key={g.title + i}>
              <code className="sig">
                <Signature text={m.signature} name={m.name} />
              </code>
              {m.doc ? <div className="doc">{m.doc}</div> : null}
            </div>
          )),
        ];
      })}
    </div>
  );
}

function TypeSection({ t }: { t: ApiType }) {
  const label = t.kind === "class" ? (t.modifiers.includes("static") ? "clase estática" : "clase") : t.kind === "struct" ? "struct" : t.kind;
  return (
    <section className="api-type">
      <h2 id={typeAnchor(t)} className="anchor-heading">
        <a href={`#${typeAnchor(t)}`} className="anchor" aria-hidden="true" tabIndex={-1}>
          #
        </a>
        <code style={{ fontSize: "0.92em", background: "none", border: 0, padding: 0 }}>{t.name}</code>{" "}
        <span className="api-kind">{label}</span>
      </h2>
      <code className="api-sig sig">
        <Signature text={`${t.namespace ? `namespace ${t.namespace} › ` : ""}${t.signature}`} />
      </code>
      {t.doc ? <p className="api-doc">{t.doc}</p> : null}
      {t.kind === "enum" ? (
        <div className="api-enum">
          {t.values.map((v) => (
            <span className="chip mono" key={v.name}>
              {v.name}
              {v.value ? ` = ${v.value}` : ""}
            </span>
          ))}
        </div>
      ) : (
        <Members members={t.members} />
      )}
    </section>
  );
}

export default async function ModulePage({ params }: { params: Promise<{ module: string }> }) {
  const { module } = await params;
  const m = getModule(module);
  if (!m) notFound();
  const Intro = (intros as Record<string, ComponentType | undefined>)[m.id];
  const visible = m.types.filter((t) => !t.native);
  const native = m.types.filter((t) => t.native);
  const memberCount = m.functions.length + m.types.reduce((s, t) => s + t.members.length + t.values.length, 0);
  const importLine = m.id === "core" ? "// std se importa siempre" : `using ${m.namespace ?? "std." + m.id};`;

  return (
    <>
      <h1>
        <code style={{ background: "none", border: 0, padding: 0, fontSize: "0.9em" }}>{moduleTitle(m)}</code>
      </h1>
      <p className="lead">{moduleBlurb(m)}</p>
      <div className="api-meta">
        <span className="chip mono">{importLine}</span>
        <a className="chip" href={`https://github.com/MantraxStudios/Faset/blob/main/${m.file}`} target="_blank" rel="noreferrer">
          {m.file}
        </a>
        <span className="chip">
          {visible.length} tipos · {memberCount} miembros públicos
        </span>
      </div>

      {Intro ? <Intro /> : null}

      {visible.length > 1 ? (
        <>
          <h2 id="tipos" className="anchor-heading">
            Tipos del módulo
          </h2>
          <div className="card-grid">
            {visible.map((t) => (
              <a className="card" href={`#${typeAnchor(t)}`} key={t.name}>
                <span className="card-title">{t.name}</span>
                <span className="card-text">{t.doc ? t.doc.split("\n")[0] : `${t.kind} · ${t.members.length || t.values.length} miembros`}</span>
              </a>
            ))}
          </div>
        </>
      ) : null}

      {m.functions.length ? (
        <section className="api-type">
          <h2 id="funciones-globales" className="anchor-heading">
            Funciones globales
          </h2>
          <p className="api-doc">Funciones declaradas directamente en el namespace (estilo C++).</p>
          <Members members={m.functions} />
        </section>
      ) : null}

      {visible.map((t) => (
        <TypeSection t={t} key={t.name} />
      ))}

      {native.length ? (
        <details className="api-native">
          <summary>Bindings nativos ({native.map((t) => t.name).join(", ")})</summary>
          {native.map((t) => (
            <TypeSection t={t} key={t.name} />
          ))}
        </details>
      ) : null}
    </>
  );
}
