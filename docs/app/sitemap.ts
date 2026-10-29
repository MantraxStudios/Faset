import type { MetadataRoute } from "next";
import { nav } from "@/lib/nav";
import { siteUrl } from "@/lib/site";

// sitemap.xml estático: la portada y todas las páginas de la barra lateral.
export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  const pages = ["/", ...nav.flatMap((s) => s.items.map((i) => i.href))];
  return [...new Set(pages)].map((href) => ({
    url: siteUrl + href,
    changeFrequency: "weekly",
    priority: href === "/" ? 1 : 0.7,
  }));
}
