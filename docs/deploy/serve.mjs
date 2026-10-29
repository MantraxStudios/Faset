// Servidor estático de la web (docs/out) sin dependencias: lo arranca start.sh y nginx le pasa
// las peticiones de faset.lat. Uso: node deploy/serve.mjs [--port 8871] [--host 127.0.0.1] [--root out]
import { createReadStream, promises as fs } from "node:fs";
import { createServer } from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : def;
};
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..", opt("root", process.env.ROOT || "out"));
const port = Number(opt("port", process.env.PORT || 8871));
const host = opt("host", process.env.HOST || "127.0.0.1");

const types = {
  ".html": "text/html; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".sh": "text/plain; charset=utf-8",
  ".ps1": "text/plain; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".map": "application/json; charset=utf-8",
};

async function stat(p) {
  try {
    return await fs.stat(p);
  } catch {
    return null;
  }
}

function send(res, status, file, st, req) {
  const ext = path.extname(file).toLowerCase();
  const rel = path.relative(root, file).split(path.sep).join("/");
  // Los archivos de _next/static llevan hash en el nombre: se pueden guardar para siempre.
  const cache = rel.startsWith("_next/static/")
    ? "public, max-age=31536000, immutable"
    : ext === ".html" || ext === ".txt"
      ? "no-cache"
      : "public, max-age=3600";
  res.writeHead(status, {
    "Content-Type": types[ext] || "application/octet-stream",
    "Content-Length": st.size,
    "Cache-Control": cache,
    "X-Content-Type-Options": "nosniff",
    "Last-Modified": st.mtime.toUTCString(),
  });
  if (req.method === "HEAD") return res.end();
  createReadStream(file).pipe(res);
}

const server = createServer(async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { Allow: "GET, HEAD" });
    return res.end();
  }
  let url;
  try {
    url = new URL(req.url, "http://localhost");
  } catch {
    res.writeHead(400);
    return res.end();
  }
  let pathname;
  try {
    pathname = decodeURIComponent(url.pathname);
  } catch {
    res.writeHead(400);
    return res.end();
  }
  const file = path.join(root, pathname);
  if (file !== root && !file.startsWith(root + path.sep)) {
    res.writeHead(403);
    return res.end();
  }
  let st = await stat(file);
  if (st?.isDirectory()) {
    // La web usa barra final (trailingSlash): /empezar/instalacion -> /empezar/instalacion/
    if (!pathname.endsWith("/")) {
      res.writeHead(308, { Location: pathname + "/" + url.search });
      return res.end();
    }
    const index = path.join(file, "index.html");
    const ist = await stat(index);
    if (ist) return send(res, 200, index, ist, req);
    st = null;
  }
  if (st?.isFile()) return send(res, 200, file, st, req);
  const html = await stat(file + ".html");
  if (html?.isFile()) return send(res, 200, file + ".html", html, req);
  const notFound = path.join(root, "404.html");
  const nst = await stat(notFound);
  if (nst) return send(res, 404, notFound, nst, req);
  res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
  res.end("No encontrado");
});

server.listen(port, host, () => {
  console.log(`Web de Faset: http://${host}:${port}  (sirviendo ${root})`);
});
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => server.close(() => process.exit(0)));
