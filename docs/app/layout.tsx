import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { asset } from "@/lib/util";
import { siteUrl } from "@/lib/site";
import "./globals.css";

export const metadata: Metadata = {
  title: { default: "Faset — código nativo con sintaxis de C#", template: "%s · Faset" },
  description:
    "Faset es un lenguaje nativo con la sintaxis de C# y el control de C++: compila a C11 y produce ejecutables para Linux, Windows y Android. Incluye FasetStudio, un IDE escrito en Faset.",
  icons: { icon: asset("/favicon-64.png"), apple: asset("/logo-512.png") },
  metadataBase: new URL(siteUrl),
  alternates: { canonical: "./" },
  openGraph: {
    type: "website",
    siteName: "Faset",
    locale: "es_ES",
    url: "./",
    images: [{ url: asset("/og.png"), width: 1200, height: 630, alt: "Faset: código nativo con sintaxis de C#" }],
  },
  twitter: { card: "summary_large_image", images: [asset("/og.png")] },
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
