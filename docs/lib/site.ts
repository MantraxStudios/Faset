// Dirección pública de la web (sitemap, enlaces canónicos y vista previa al compartir).
// Otra: NEXT_PUBLIC_SITE_URL=https://ejemplo.com npm run build
export const siteUrl = (process.env.NEXT_PUBLIC_SITE_URL || "https://faset.lat").replace(/\/$/, "");
