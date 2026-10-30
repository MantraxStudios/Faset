// Dirección pública de la web (sitemap, enlaces canónicos y vista previa al compartir).
// Otra: NEXT_PUBLIC_SITE_URL=https://ejemplo.com npm run build
export const siteUrl = (process.env.NEXT_PUBLIC_SITE_URL || "https://faset.lat").replace(/\/$/, "");

// Palabras clave para buscadores: términos reales con los que alguien buscaría un lenguaje así
// (español e inglés). No repetir ni rellenar: Google penaliza el "keyword stuffing".
export const siteKeywords = [
  "Faset", "lenguaje Faset", "Faset lang", "FasetStudio", "faset.lat",
  "lenguaje de programación", "nuevo lenguaje de programación", "lenguaje de programación en español",
  "lenguaje de programación nativo", "lenguaje compilado", "lenguaje compilado a C", "compilador a C11",
  "lenguaje como C#", "sintaxis de C#", "C# nativo", "C# compilado a código máquina", "alternativa a C#",
  "alternativa a C++", "alternativa a C", "C# sin .NET", "C# sin máquina virtual",
  "lenguaje con recolector de basura", "seguridad de memoria", "memory safe", "lenguaje seguro en memoria",
  "programación de sistemas", "programación de videojuegos", "ejecutables nativos",
  "compilación cruzada", "Linux", "Windows", "Android", "APK sin Gradle", "apps Android en C#",
  "IDE", "IDE para Linux", "diseñador visual de interfaces", "interfaz gráfica", "GUI nativa",
  "depurador", "gestor de paquetes", "async await", "lambdas", "LINQ", "herencia e interfaces",
  "excepciones", "genéricos", "plantillas", "WebView", "audio", "video", "HTTPS",
  "aprender a programar", "lenguaje open source", "lenguaje de código abierto", "Vulkan",
  "programming language", "new programming language", "native programming language",
  "compiled language", "C# like language", "C# to C compiler", "C# to native", "C++ alternative",
  "memory safe language", "garbage collected native language", "transpiler to C", "cross platform compiler",
  "Android NDK", "game development language", "systems programming", "visual UI designer",
];
