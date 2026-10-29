import createMDX from "@next/mdx";

/** @type {import('next').NextConfig} */
const nextConfig = {
  // Exportación estática: `out/` se puede servir desde cualquier hosting.
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
  pageExtensions: ["ts", "tsx", "mdx"],
  // Ruta base opcional (p. ej. GitHub Pages en /Faset): NEXT_PUBLIC_BASE_PATH=/Faset npm run build
  basePath: process.env.NEXT_PUBLIC_BASE_PATH || "",
  // La carpeta docs/ vive dentro de otro repositorio: fija la raíz para Turbopack.
  turbopack: { root: import.meta.dirname },
};

// remark-gfm: tablas, tachado y listas de tareas de GitHub en los .mdx. Con Turbopack los
// plugins se indican por nombre (deben ser serializables).
const withMDX = createMDX({
  options: {
    remarkPlugins: [["remark-gfm", { singleTilde: false }]],
  },
});

export default withMDX(nextConfig);
