// Coloreado ligero de firmas de la API (sin pasar por Shiki: hay cientos por página).
const KEYWORDS = new Set([
  "static", "const", "extern", "readonly", "ref", "out", "this", "operator", "public", "partial",
  "class", "struct", "enum", "interface", "get", "set", "new", "delegate",
]);
const BUILTIN = new Set([
  "void", "bool", "char", "sbyte", "byte", "short", "ushort", "int", "uint", "long", "ulong",
  "float", "double", "string", "object", "var", "auto",
]);

export default function Signature({ text, name }: { text: string; name?: string }) {
  const parts = text.split(/(\b[A-Za-z_]\w*\b)/g);
  let named = false;
  return (
    <>
      {parts.map((p, i) => {
        if (!p) return null;
        if (KEYWORDS.has(p)) return <span key={i} className="kw">{p}</span>;
        if (BUILTIN.has(p)) return <span key={i} className="kw">{p}</span>;
        if (!named && name && p === name && /^\s*[(<{=;]|^\s*$/.test(parts[i + 1] ?? "")) {
          named = true;
          return <span key={i} className="fn">{p}</span>;
        }
        if (/^[A-Z]/.test(p) && p.length > 1) return <span key={i} className="ty">{p}</span>;
        return <span key={i}>{p}</span>;
      })}
    </>
  );
}
