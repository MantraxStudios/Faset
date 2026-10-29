// Navegación de la documentación: el orden de esta lista define la barra lateral
// y los enlaces "anterior / siguiente". La sección de la biblioteca estándar se
// genera a partir de generated/api.json (un módulo por archivo de lib/std).
import api from "@/generated/api.json";

export type NavItem = { title: string; href: string; status?: "dev" };
export type NavSection = { title: string; items: NavItem[] };

type ApiModule = { id: string; namespace: string | null };

export const stdModules = (api.modules as ApiModule[]).map((m) => ({
  id: m.id,
  title: m.id === "core" ? "std (núcleo)" : `std.${m.id}`,
}));

export const nav: NavSection[] = [
  {
    title: "Empezar",
    items: [
      { title: "¿Qué es Faset?", href: "/empezar/introduccion/" },
      { title: "Instalación", href: "/empezar/instalacion/" },
      { title: "Tu primer proyecto", href: "/empezar/primer-proyecto/" },
      { title: "Proyectos .fstproj", href: "/empezar/proyectos/" },
      { title: "Plataformas y compilación cruzada", href: "/empezar/plataformas/" },
      { title: "Editores y LSP", href: "/empezar/editores/" },
    ],
  },
  {
    title: "Guía del lenguaje",
    items: [
      { title: "Tipos y variables", href: "/lenguaje/tipos/" },
      { title: "Control de flujo", href: "/lenguaje/control/" },
      { title: "Clases y structs", href: "/lenguaje/clases-y-structs/" },
      { title: "Propiedades", href: "/lenguaje/propiedades/" },
      { title: "Clases parciales", href: "/lenguaje/clases-parciales/" },
      { title: "Genéricos (plantillas)", href: "/lenguaje/genericos/" },
      { title: "Sobrecarga de operadores", href: "/lenguaje/operadores/" },
      { title: "Métodos de extensión", href: "/lenguaje/extensiones/" },
      { title: "Punteros a función", href: "/lenguaje/delegados/" },
      { title: "Referencias, ref y out", href: "/lenguaje/referencias/" },
      { title: "Namespaces, using e import", href: "/lenguaje/namespaces/" },
      { title: "Compilación condicional", href: "/lenguaje/compilacion-condicional/" },
      { title: "Modelo de memoria", href: "/lenguaje/memoria/" },
      { title: "Punteros e interoperabilidad con C", href: "/lenguaje/interop/" },
      { title: "Seguridad de memoria", href: "/lenguaje/seguridad-de-memoria/" },
      { title: "Limitaciones actuales", href: "/lenguaje/limitaciones/" },
    ],
  },
  {
    title: "Biblioteca estándar",
    items: [
      { title: "Visión general", href: "/std/" },
      ...stdModules.map((m) => ({ title: m.title, href: `/std/${m.id}/` })),
    ],
  },
  {
    title: "std.ui y el diseñador",
    items: [
      { title: "Aplicaciones AppUI", href: "/ui/introduccion/" },
      { title: "Formato .fstui", href: "/ui/fstui/" },
      { title: "Colores y degradados", href: "/ui/colores/" },
      { title: "Código de la ventana", href: "/ui/codigo/" },
      { title: "Imágenes (PictureBox)", href: "/ui/imagenes/" },
      { title: "Pestañas y árboles", href: "/ui/pestanas-y-arboles/" },
      { title: "Menús", href: "/ui/menus/" },
      { title: "Lienzo y temporizador", href: "/ui/lienzo/" },
      { title: "WebView", href: "/ui/webview/" },
      { title: "Vídeo y audio", href: "/ui/multimedia/" },
      { title: "Limitaciones de std.ui", href: "/ui/limitaciones/" },
    ],
  },
  {
    title: "FasetStudio",
    items: [
      { title: "El IDE", href: "/studio/introduccion/" },
      { title: "Diseñador visual", href: "/studio/disenador/" },
      { title: "Paneles acoplables", href: "/studio/paneles/" },
      { title: "IntelliSense", href: "/studio/intellisense/" },
      { title: "Depurador", href: "/studio/depurador/" },
      { title: "Atajos de teclado", href: "/studio/atajos/" },
    ],
  },
  {
    title: "Referencia",
    items: [
      { title: "Línea de órdenes (CLI)", href: "/cli/" },
      { title: "Android", href: "/android/" },
      { title: "Rendimiento", href: "/rendimiento/" },
    ],
  },
];

export const flatNav: NavItem[] = nav.flatMap((s) => s.items);

export function normalize(path: string) {
  return path.endsWith("/") ? path : path + "/";
}
