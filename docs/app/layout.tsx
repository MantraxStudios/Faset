import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { asset } from "@/lib/util";
import "./globals.css";

export const metadata: Metadata = {
  title: { default: "Faset — código nativo con sintaxis de C#", template: "%s · Faset" },
  description:
    "Faset es un lenguaje nativo con la sintaxis de C# y el control de C++: compila a C11 y produce ejecutables para Linux, Windows y Android. Incluye FasetStudio, un IDE escrito en Faset.",
  icons: { icon: asset("/favicon-64.png") },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: dark)", color: "#0a0a0b" },
    { media: "(prefers-color-scheme: light)", color: "#ffffff" },
  ],
};

// Se aplica el tema guardado antes del primer pintado (oscuro por defecto).
const themeScript = `try{var t=localStorage.getItem("faset-theme");document.documentElement.dataset.theme=t==="light"?"light":"dark"}catch(e){document.documentElement.dataset.theme="dark"}`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="es" data-theme="dark" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
