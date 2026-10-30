import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import { asset } from "@/lib/util";
import { siteKeywords, siteUrl } from "@/lib/site";
import "./globals.css";

export const metadata: Metadata = {
  title: { default: "Faset — código nativo con sintaxis de C#", template: "%s · Faset" },
  description:
    "Faset es un lenguaje nativo con la sintaxis de C# y el control de C++: compila a C11 y produce ejecutables para Linux, Windows y Android. Incluye FasetStudio, un IDE escrito en Faset.",
  icons: { icon: asset("/favicon-64.png"), apple: asset("/logo-512.png") },
  keywords: siteKeywords,
  applicationName: "Faset",
  authors: [{ name: "MantraxStudios", url: "https://github.com/MantraxStudios" }],
  creator: "MantraxStudios",
  publisher: "MantraxStudios",
  category: "technology",
  robots: { index: true, follow: true, googleBot: { index: true, follow: true, "max-image-preview": "large", "max-snippet": -1 } },
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

// Datos estructurados (schema.org): Google muestra Faset como software y lenguaje de programación.
const jsonLd = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "SoftwareApplication",
      name: "Faset",
      alternateName: ["Faset lang", "lenguaje Faset", "FasetStudio"],
      description:
        "Lenguaje de programación nativo con la sintaxis de C#: compila a C11 y genera ejecutables para Linux, Windows y Android, con recolector de basura, seguridad de memoria y el IDE FasetStudio.",
      url: siteUrl,
      image: siteUrl + "/og.png",
      applicationCategory: "DeveloperApplication",
      applicationSubCategory: "Programming Language",
      operatingSystem: "Linux, Windows, Android",
      softwareVersion: "0.4.1",
      downloadUrl: "https://github.com/MantraxStudios/Faset/releases/latest",
      installUrl: siteUrl + "/empezar/instalacion/",
      license: "https://github.com/MantraxStudios/Faset/blob/main/LICENSE",
      offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
      author: { "@type": "Organization", name: "MantraxStudios", url: "https://github.com/MantraxStudios" },
      keywords: siteKeywords.join(", "),
      inLanguage: "es",
    },
    {
      "@type": "SoftwareSourceCode",
      name: "Faset",
      codeRepository: "https://github.com/MantraxStudios/Faset",
      programmingLanguage: ["C++", "C", "Faset"],
      runtimePlatform: "Linux, Windows, Android",
    },
    {
      "@type": "WebSite",
      name: "Faset",
      url: siteUrl,
      inLanguage: "es",
    },
  ],
};

// Se aplica el tema guardado antes del primer pintado (oscuro por defecto).
const themeScript = `try{var t=localStorage.getItem("faset-theme");document.documentElement.dataset.theme=t==="light"?"light":"dark"}catch(e){document.documentElement.dataset.theme="dark"}`;

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="es" data-theme="dark" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
        <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
