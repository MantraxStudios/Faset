import Link from "next/link";
import type { ReactNode } from "react";
import { BenchBars, BuildTable, Machine, StartupTable, bench } from "@/components/Bench";
import CodeBlock from "@/components/CodeBlock";
import CopyButton from "@/components/CopyButton";
import Footer from "@/components/Footer";
import Header from "@/components/Header";
import Pipeline from "@/components/Pipeline";
import { asset, formatBytes, formatNum } from "@/lib/util";

const HERO = `using std.collections;

struct Punto
{
    public int X, Y;
    public Punto(int x, int y) { X = x; Y = y; }
    public static Punto operator +(Punto a, Punto b)
        => new Punto(a.X + b.X, a.Y + b.Y);
    public int Manhattan => Math.Abs(X) + Math.Abs(Y);
}

T Mayor<T>(T a, T b) => a < b ? b : a;      // plantilla

int main()
{
    auto lista = new List<int>();    // memoria automática
    for (int i = 0; i < 10; i++) lista.Add(i * i);
    lista[0] = 100;                   // operator[] → T&
    lista.Sort();
    println(lista.Sum());             // 385

    Punto p = new Punto(1, 2) + new Punto(3, 4);
    println(Mayor(p.Manhattan, 7));   // 10
    return 0;
}`;

const SEGURO = `class Nodo { public Nodo Otro; public int Valor; }

int main()
{
    for (int i = 0; i < 1000000; i++)
    {
        Nodo a = new Nodo();
        a.Otro = new Nodo();
        a.Otro.Otro = a;         // ciclo: el recolector lo recupera
    }
    string s = "n = " + 42;      // + como en C#, sin liberar nada
    println(s);

    Nodo n = null;
    println(n.Valor);            // panic, también en Release
    return 0;
}`;

const FSTUI = `<Window Class="MainWindow" Namespace="Galeria" Title="Galería std.ui"
        Width="720" Height="460" Theme="Dark"
        Background="#101014" Background2="#1c1c24">
  <Panel Name="hero" X="32" Y="100" Width="656" Height="96"
         Background="#2b2f77" Background2="#7a2e8c" GradientDirection="Horizontal">
    <Label X="20" Y="16" Width="400" Height="30" Text="Degradados nativos"
           FontSize="20" Bold="true" Foreground="#ffffff" />
  </Panel>
  <Slider Name="sldLevel" X="18" Y="40" Width="284" Height="24" Value="70"
          Accent="#3ecf8e" Changed="OnLevelChanged" />
  <Button Name="btnBuild" X="576" Y="402" Width="112" Height="38" Text="Compilar"
          Style="Primary" Click="OnBuild" />
</Window>`;

type Feature = { title: string; text: ReactNode; href: string; icon: ReactNode };

const I = {
  bolt: <path d="M10.5 2 4 11h5l-1 7 6.5-9h-5l1-7Z" />,
  braces: <path d="M7 3c-2 0-2.5 1-2.5 3v1.5C4.5 9 3.5 10 2.5 10c1 0 2 1 2 2.5V14c0 2 .5 3 2.5 3M13 3c2 0 2.5 1 2.5 3v1.5c0 1.5 1 2.5 2 2.5-1 0-2 1-2 2.5V14c0 2-.5 3-2.5 3" />,
  layers: <path d="m10 3 7 4-7 4-7-4 7-4Zm-7 7 7 4 7-4M3 13l7 4 7-4" />,
  plus: <path d="M10 4v12M4 10h12M4 4h3M13 16h3" />,
  key: <path d="M12.5 3.5a4 4 0 1 1-3.4 6.1L3.5 15.2V17h2.2v-1.5h1.5V14h1.5l1.1-1.1A4 4 0 0 1 12.5 3.5Zm1 2.5h.01" />,
  puzzle: <path d="M8 3h4v2.5a1.5 1.5 0 1 0 3 0V3h2v5h-2.5a1.5 1.5 0 1 0 0 3H17v6H3v-6h2.5a1.5 1.5 0 1 0 0-3H3V3h5Z" />,
  shield: <path d="M10 2.5 16 5v5c0 3.6-2.6 6.4-6 7.5C6.6 16.4 4 13.6 4 10V5l6-2.5Z" />,
  globe: <path d="M10 2.5a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15Zm-7.5 7.5h15M10 2.5c2 2 3 4.5 3 7.5s-1 5.5-3 7.5c-2-2-3-4.5-3-7.5s1-5.5 3-7.5Z" />,
  window: <path d="M3 4.5h14v11H3v-11Zm0 3h14M5.5 6h.01M7.5 6h.01" />,
  cursor: <path d="M4 3l11 6-5 1.5L8 16 4 3Zm6.5 8.5L15 16" />,
  gradient: <path d="M3.5 3.5h13v13h-13v-13Zm0 13 13-13M3.5 11 11 3.5M9 16.5l7.5-7.5" />,
  link: <path d="M8.5 11.5a3 3 0 0 0 4.2 0l2.6-2.6a3 3 0 0 0-4.2-4.2l-.9.9M11.5 8.5a3 3 0 0 0-4.2 0l-2.6 2.6a3 3 0 0 0 4.2 4.2l.9-.9" />,
};

const features: Feature[] = [
  {
    title: "Ejecutables nativos, sin VM",
    text: "Compila a C11 y luego a código máquina con gcc, clang o el NDK. Sin máquina virtual ni JIT, con un recolector de basura nativo y seguridad de memoria por defecto.",
    href: "/empezar/introduccion/",
    icon: I.bolt,
  },
  {
    title: "Sintaxis de C#, control de C++",
    text: (
      <>
        <code>class</code>, propiedades, <code>using</code> y <code>"a" + 1</code> de C#, junto a <code>T&amp;</code>,
        <code> ::</code>, plantillas, destructores y funciones globales de C++.
      </>
    ),
    href: "/lenguaje/tipos/",
    icon: I.braces,
  },
  {
    title: "Genéricos instanciados",
    text: "Sintaxis <T> de C#, compilación de plantillas de C++: código especializado por tipo, duck typing y errores con la cadena de instanciación.",
    href: "/lenguaje/genericos/",
    icon: I.layers,
  },
  {
    title: "Sobrecarga de operadores",
    text: (
      <>
        <code>operator +</code>, comparaciones y <code>T&amp; operator[]</code> con retorno por referencia para tus propios tipos.
      </>
    ),
    href: "/lenguaje/operadores/",
    icon: I.plus,
  },
  {
    title: "Propiedades y clases parciales",
    text: (
      <>
        <code>{"{ get; set; }"}</code>, propiedades calculadas y <code>partial class</code>, la base del código generado por los
        .fstui.
      </>
    ),
    href: "/lenguaje/propiedades/",
    icon: I.puzzle,
  },
  {
    title: "Seguro por defecto",
    text: "Recolector de basura, nulos, índices y divisiones comprobados también en Release, y sin comportamiento indefinido de C. Los punteros van en bloques memory_unsafe.",
    href: "/lenguaje/seguridad-de-memoria/",
    icon: I.shield,
  },
  {
    title: "Linux, Windows y Android",
    text: "Compilación cruzada con --target y --arch. En Android, APK firmados sin Gradle: faset run instala, abre y muestra el logcat.",
    href: "/android/",
    icon: I.globe,
  },
  {
    title: "Un IDE escrito en Faset",
    text: "FasetStudio: Vulkan, X11 y FreeType, IntelliSense del compilador real, paneles acoplables y vista en vivo de Android. ~13 000 líneas de Faset.",
    href: "/studio/introduccion/",
    icon: I.window,
  },
  {
    title: "Diseñador visual",
    text: "Arrastra controles, alinea, cambia colores y haz doble clic para crear el manejador del evento. Guarda un .fstui que compila tal cual.",
    href: "/studio/disenador/",
    icon: I.cursor,
  },
  {
    title: "std.ui con degradados",
    text: "Renderizador por software escrito en Faset: antialiasing, degradados, temas, pestañas, árboles, menús, imágenes y un lienzo de dibujo. X11, Win32 y Android con el mismo código.",
    href: "/ui/introduccion/",
    icon: I.gradient,
  },
  {
    title: "Interoperabilidad directa con C",
    text: (
      <>
        Cualquier función de C, Win32 o el NDK con <code>extern</code>. Exporta símbolos con <code>[Export]</code>. Sin marshalling.
      </>
    ),
    href: "/lenguaje/interop/",
    icon: I.link,
  },
  {
    title: "Proyectos al estilo .NET",
    text: ".fstproj como los .csproj: todos los archivos de la carpeta se compilan solos, referencias entre proyectos y bibliotecas nativas.",
    href: "/empezar/proyectos/",
    icon: I.key,
  },
];

export default function Home() {
  const fib = bench.cpu.find((b) => b.id === "fib")!;
  const fibF = fib.results.find((r) => r.lang === "Faset")!.seconds;
  const fibC = fib.results.find((r) => r.lang.startsWith("C"))!.seconds;
  const studio = bench.build.find((b) => b.title.startsWith("FasetStudio"))!;
  const hello = bench.startup.find((s) => s.lang === "Faset")!;
  const nbody = bench.cpu.find((b) => b.id === "nbody")!;
  const nbF = nbody.results.find((r) => r.lang === "Faset")!.seconds;
  const nbPy = nbody.results.find((r) => r.lang === "Python")?.seconds;

  return (
    <div className="landing">
      <Header />
      <main>
        <section className="hero">
          <div className="wrap hero-grid">
            <div>
              <div className="hero-eyebrow">
                <b>v0.2</b> Compilador, biblioteca estándar e IDE · MIT
              </div>
              <h1>
                Código nativo con la elegancia de C#. <span className="dim">Y la potencia de <span style={{ whiteSpace: "nowrap" }}>C++.</span></span>
              </h1>
              <p className="sub">
                Faset compila a C11 y produce ejecutables nativos para Linux, Windows y Android. Tipado estricto, plantillas,
                operadores y memoria automática y segura, con un IDE y un diseñador visual escritos en el propio lenguaje.
              </p>
              <div className="cta">
                <Link className="btn primary" href="/empezar/instalacion/">
                  Empezar
                  <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
                    <path d="M3 8h10M9 4l4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                </Link>
                <Link className="btn" href="/lenguaje/tipos/">
                  Guía del lenguaje
                </Link>
              </div>
              <div className="install-line mono">
                <span className="prompt">$</span>
                <span>make &amp;&amp; ./faset run hola.fst</span>
                <CopyButton text="make && ./faset run hola.fst" />
              </div>
            </div>
            <div className="hero-code">
              <CodeBlock code={HERO} lang="faset" title="programa.fst" />
              <div className="hero-run mono">
                <span className="ok">$</span> faset run programa.fst
                <br />
                385
                <br />
                10
              </div>
            </div>
          </div>
        </section>

        <div className="wrap" style={{ padding: 0 }}>
          <div className="stats">
            <div className="stat">
              <div className="stat-value">
                {formatNum(fibF * 1000, 0)}
                <small>ms</small>
              </div>
              <div className="stat-label">
                fib(37) recursivo · C con gcc -O2: {formatNum(fibC * 1000, 0)} ms
              </div>
            </div>
            <div className="stat">
              <div className="stat-value">
                {nbPy ? formatNum(nbPy / nbF, 0) : "—"}
                <small>×</small>
              </div>
              <div className="stat-label">más rápido que Python en n-body</div>
            </div>
            <div className="stat">
              <div className="stat-value">
                {formatNum(studio.seconds, 1)}
                <small>s</small>
              </div>
              <div className="stat-label">compila FasetStudio ({studio.lines.toLocaleString("es-ES")} líneas)</div>
            </div>
            <div className="stat">
              <div className="stat-value">
                {formatBytes(hello.bytes).replace(" KB", "")}
                <small>KB</small>
              </div>
              <div className="stat-label">«Hola, mundo» · arranca en {formatNum(hello.ms, 2)} ms</div>
            </div>
          </div>
        </div>

        <section className="section">
          <div className="wrap">
            <div className="section-head">
              <div className="section-kicker">El lenguaje</div>
              <h2>Lo mejor de dos mundos, sin pagar por ello en ejecución</h2>
              <p className="section-sub">
                Escribes como en C#; el compilador comprueba todo el programa y genera C que cualquier compilador de la plataforma
                convierte en código máquina.
              </p>
            </div>
            <div className="features">
              {features.map((f) => (
                <Link className="feature" href={f.href} key={f.title}>
                  <div className="feature-icon">
                    <svg viewBox="0 0 20 20" width="17" height="17" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                      {f.icon}
                    </svg>
                  </div>
                  <h3>{f.title}</h3>
                  <p>{f.text}</p>
                </Link>
              ))}
            </div>
          </div>
        </section>

        <section className="section" id="seguridad">
          <div className="wrap split">
            <div>
              <div className="section-kicker">Seguridad de memoria</div>
              <h2>Memoria automática, sin renunciar a la velocidad de C</h2>
              <p className="section-sub">
                Un recolector de basura nativo recupera lo que ya nadie usa, ciclos incluidos. El código seguro no puede dejar
                punteros colgando, liberar dos veces ni leer fuera de límites.
              </p>
              <ul className="check-list">
                <li>
                  <b>Sin delete obligatorio</b>: <code>delete</code> solo cierra recursos, como <code>Dispose</code>; nunca deja
                  una referencia colgando.
                </li>
                <li>
                  <b>Comprobaciones siempre activas</b>: nulos, índices de cadenas y divisiones por cero terminan con un{" "}
                  <code>Faset panic</code> y la línea de tu código, también en Release.
                </li>
                <li>
                  <b>Sin comportamiento indefinido</b>: desplazamientos y conversiones con resultado fijo, como en C#.
                </li>
                <li>
                  <b>Pausas de milisegundos</b>: de 1 a 5 ms en FasetStudio, con unos 10 MB vivos.
                </li>
                <li>
                  <b>Lo peligroso, a la vista</b>: punteros y llamadas a C solo dentro de <code>memory_unsafe</code>.
                </li>
              </ul>
              <div className="cta">
                <Link className="btn" href="/lenguaje/seguridad-de-memoria/">
                  Seguridad de memoria
                </Link>
                <Link className="btn" href="/lenguaje/memoria/">
                  El recolector
                </Link>
              </div>
            </div>
            <div className="hero-code">
              <CodeBlock code={SEGURO} lang="faset" title="seguro.fst" />
              <div className="hero-run mono">
                <span className="ok">$</span> faset run -c Release seguro.fst
                <br />
                n = 42
                <br />
                <span style={{ color: "var(--warn)" }}>Faset panic: referencia nula (null): el objeto no existe at seguro.fst:15</span>
              </div>
            </div>
          </div>
        </section>

        <section className="section">
          <div className="wrap">
            <div className="section-head">
              <div className="section-kicker">Cómo funciona</div>
              <h2>Faset → C11 → nativo</h2>
              <p className="section-sub">
                Un struct con un operador sobrecargado y una propiedad calculada. Con <code>-c Release</code>, gcc ve el C generado y
                lo reduce a una sola constante: la abstracción no cuesta nada.
              </p>
            </div>
            <Pipeline />
          </div>
        </section>

        <section className="section" id="rendimiento">
          <div className="wrap">
            <div className="section-head">
              <div className="section-kicker">Rendimiento medido</div>
              <h2>Tan rápido como C, porque es C</h2>
              <p className="section-sub">
                El mismo algoritmo en Faset, C, Node.js y Python. Cifras reales de esta máquina, sin redondeos favorables: las fuentes y
                el script están en <code>docs/benchmarks</code>.
              </p>
            </div>
            <BenchBars />
            <div className="bench-tables">
              <BuildTable />
              <StartupTable />
            </div>
            <Machine />
            <p className="bench-foot">
              <Link href="/rendimiento/">Metodología completa y cómo repetir las mediciones →</Link>
            </p>
          </div>
        </section>

        <section className="section">
          <div className="wrap split">
            <div>
              <div className="section-kicker">FasetStudio</div>
              <h2>Un IDE escrito en Faset</h2>
              <p className="section-sub">
                La prueba más exigente del lenguaje es su propio entorno de desarrollo: Vulkan, X11 y FreeType llamados directamente
                con <code>extern</code>, y el compilador como motor de IntelliSense.
              </p>
              <ul className="check-list">
                <li>
                  <b>Diseñador visual</b> de .fstui con zoom, cuadrícula, alineación, esquema, colores, menús, pestañas y bandeja de
                  componentes.
                </li>
                <li>
                  <b>IntelliSense real</b>: errores en vivo, autocompletado, hover e ir a la definición.
                </li>
                <li>
                  <b>Paneles acoplables</b>, vista dividida, compilar y ejecutar con salida en vivo.
                </li>
                <li>
                  <b>Interfaz traducible</b> (incluye español) y diseño monocromo.
                </li>
              </ul>
              <div className="cta">
                <Link className="btn" href="/studio/introduccion/">
                  Conocer FasetStudio
                </Link>
              </div>
            </div>
            <div className="studio-shot">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img
                src={asset("/screenshots/studio-designer.png")}
                width={1680}
                height={980}
                alt="Diseñador visual de FasetStudio con la ventana Galería y el panel de propiedades"
                loading="lazy"
              />
            </div>
          </div>
        </section>

        <section className="section">
          <div className="wrap split">
            <div>
              <CodeBlock code={FSTUI} lang="fstui" title="MainWindow.fstui" />
            </div>
            <div>
              <div className="section-kicker">std.ui</div>
              <h2>Interfaces nativas en XML</h2>
              <p className="section-sub" style={{ marginBottom: 24 }}>
                Describe la ventana en un .fstui y escribe los eventos en una clase parcial. El compilador genera los controles; std.ui
                los dibuja con su propio renderizador, en Linux, Windows y Android. Incluye imágenes, pestañas, árboles, menús, un
                lienzo con temporizador, un navegador web incrustado, vídeo y sonido.
              </p>
              <div className="studio-shot">
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img src={asset("/screenshots/galeria.png")} width={720} height={460} alt="Ventana de std.ui con degradados y controles" loading="lazy" />
              </div>
            </div>
          </div>
        </section>

        <section className="final-cta">
          <div className="wrap">
            <h2>Compila tu primer programa nativo</h2>
            <p>Clona el repositorio, ejecuta make y tendrás compilador, biblioteca estándar e IDE.</p>
            <div className="cta">
              <Link className="btn primary" href="/empezar/instalacion/">
                Instalar Faset
              </Link>
              <Link className="btn" href="/std/">
                Explorar la biblioteca
              </Link>
            </div>
          </div>
        </section>
      </main>
      <Footer />
    </div>
  );
}
