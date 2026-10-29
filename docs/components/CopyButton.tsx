"use client";

import { useState } from "react";

export default function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      document.execCommand("copy");
      ta.remove();
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 1600);
  }
  return (
    <button type="button" className="copy-btn" onClick={copy} aria-label="Copiar código">
      {copied ? (
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
          <path d="M3 8.5 6.5 12 13 4.5" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      ) : (
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
          <rect x="5" y="5" width="8.5" height="8.5" rx="1.6" fill="none" stroke="currentColor" strokeWidth="1.3" />
          <path d="M3.5 10.5h-.2A1.3 1.3 0 0 1 2 9.2V3.3A1.3 1.3 0 0 1 3.3 2h5.9a1.3 1.3 0 0 1 1.3 1.3v.2" fill="none" stroke="currentColor" strokeWidth="1.3" />
        </svg>
      )}
      <span>{copied ? "Copiado" : "Copiar"}</span>
    </button>
  );
}
