import { highlight, resolveLang } from "@/lib/highlight";
import CopyButton from "./CopyButton";

const LABELS: Record<string, string> = {
  faset: "Faset",
  fst: "Faset",
  fstui: ".fstui",
  fstproj: ".fstproj",
  xml: "XML",
  bash: "Terminal",
  sh: "Terminal",
  c: "C",
  cpp: "C++",
  json: "JSON",
  python: "Python",
  py: "Python",
  javascript: "JavaScript",
  js: "JavaScript",
  ini: "INI",
  text: "Texto",
};

export default async function CodeBlock({ code, lang, title }: { code: string; lang?: string; title?: string }) {
  const clean = code.replace(/\n$/, "");
  const html = await highlight(clean, lang);
  const key = (lang || "text").toLowerCase();
  const label = title ?? LABELS[key] ?? LABELS[resolveLang(lang)] ?? key;
  return (
    <div className="code-block">
      <div className="code-head">
        <span className="code-lang">{label}</span>
        <CopyButton text={clean} />
      </div>
      <div className="code-body" dangerouslySetInnerHTML={{ __html: html }} />
    </div>
  );
}
