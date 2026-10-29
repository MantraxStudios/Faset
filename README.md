<p align="center">
  <img src="studio/assets/logo.png" alt="Faset" width="140">
</p>

<h1 align="center">Faset</h1>

<p align="center">
  Código nativo con la elegancia de C# y la potencia de C++.<br>
  Compilador · Biblioteca estándar · Servidor de lenguaje · Extensión de VS Code · <b>FasetStudio</b>
</p>

---

Lenguaje de programación **nativo**, con **tipado estático estricto** y **memoria manual**.
Su sintaxis **mezcla C# y C++**: clases, propiedades y extensiones de C#, junto con
punteros, referencias, plantillas, `::`, `delete` y funciones globales de C++.

```csharp
using std::collections;          // estilo C++ ...
using std.text;                  // ... o estilo C#: ambos valen

namespace Juego::Modelo
{
    struct Punto
    {
        int X, Y;                                     // en un struct, público por defecto (C++)
        Punto(int x, int y) { X = x; Y = y; }
        static Punto operator +(Punto a, Punto b) => new Punto(a.X + b.X, a.Y + b.Y);
        int Manhattan => Math::Abs(X) + Math::Abs(Y);  // propiedad (C#)
    }
}

T Mayor<T>(T a, T b) => a < b ? b : a;               // plantilla (se instancia por tipo)
void Incrementar(int& x) { x++; }                     // referencia (C++)

int main()                                            // punto de entrada al estilo C++
{
    auto lista = new List<int>();                     // sin recolector de basura
    for (int i = 0; i < 10; i++) lista.Add(i * i);
    lista[0] = 100;                                   // operator[] devuelve T&
    lista.Sort();
    println(lista.Sum());

    int n = 1;
    Incrementar(n);
    println(Mayor(n, 0));

    auto p = new Juego::Modelo::Punto(1, 2) + new Juego.Modelo.Punto(3, 4);
    println(p.Manhattan);

    delete lista;                                     // tú decides cuándo liberar
    return 0;
}
```

## Cómo funciona

```
 .fst ─► lexer ─► parser ─► análisis semántico ─► C11 ─► gcc / clang / NDK ─► binario nativo
        (todo dentro de 'faset', escrito en C++17)                             .exe / ELF / Android
```

`faset` comprueba el programa completo (tipos, sobrecargas, plantillas, accesibilidad, rutas de
retorno…), genera C portable y lo compila con el compilador de C de la plataforma, que produce
**código máquina nativo**. No hay máquina virtual ni recolector de basura: el ejecutable es
equivalente a uno de C/C++, para x86-64, x86, ARM64 o ARMv7.

## Instalación

```bash
make                    # genera ./faset (usa ./lib como biblioteca estándar)
make test               # ejecuta los tests
sudo make install       # /usr/local/bin/faset + /usr/local/lib/faset

# Windows (o cualquier sistema) con CMake
cmake -B build && cmake --build build
```

`faset doctor` muestra la biblioteca y los compiladores detectados:

| Objetivo            | Necesitas                                                     |
|---------------------|---------------------------------------------------------------|
| Linux               | `gcc` o `clang`                                               |
| Windows             | MinGW-w64 o `clang` (MSYS2 / llvm-mingw)                      |
| Windows desde Linux | `sudo apt install mingw-w64`                                  |
| Android             | Android NDK (`ANDROID_NDK_HOME` o `~/Android/Sdk/ndk/<versión>`) |

## FasetStudio — el IDE de Faset, escrito en Faset

```bash
make studio
./studio/bin/Release/linux-x86_64/FasetStudio examples/proyecto/MiJuego
```

FasetStudio es un entorno de desarrollo al estilo de Visual Studio, escrito en Faset y dibujado con
**Vulkan**: explorador de soluciones, pestañas, vista dividida, resaltado de sintaxis, IntelliSense
(errores en vivo, autocompletado, información al pasar el ratón, ir a la definición), compilar y
ejecutar con la salida en vivo, y lista de errores. Detalles en [studio/README.md](studio/README.md).

## VS Code

```bash
make vscode-install      # enlaza editors/vscode en ~/.vscode/extensions
```

Después, en VS Code, ejecuta *Developer: Reload Window*. Obtienes resaltado de sintaxis, errores
en vivo, autocompletado, hover con tipos y firmas, ir a la definición (F12), esquema del
documento, snippets y los comandos *Faset: Compilar* (Ctrl+Shift+B) y *Faset: Ejecutar* (Ctrl+F5).

La inteligencia la da el propio compilador: `faset lsp` es un servidor LSP estándar, así que
también sirve para Neovim, Helix, Zed, Sublime y otros editores. Cada análisis se ejecuta en un
subproceso (`faset __analyze`) que tarda unos 10 ms y libera toda su memoria al terminar.

## Proyectos `.fstproj`

Funcionan igual que los `.csproj` de .NET SDK: **todos los `.fst` de la carpeta del proyecto
(y subcarpetas) se compilan automáticamente**.

```bash
faset new MiApp              # MiApp/MiApp.fstproj + Program.fst
faset new Utilidades --lib   # biblioteca
faset new MiVentana --winexe # aplicación de ventana de Windows
cd MiApp
faset run                    # compila y ejecuta
faset build -c Release       # bin/Release/linux-x86_64/MiApp
faset build --target windows # bin/Debug/windows-x86_64/MiApp.exe
faset clean
```

```xml
<Project>
  <PropertyGroup>
    <OutputType>Exe</OutputType>             <!-- Exe | WinExe | Library -->
    <AssemblyName>MiApp</AssemblyName>
    <TargetPlatform>native</TargetPlatform>  <!-- native | linux | windows | android -->
    <TargetArch>x86_64</TargetArch>          <!-- x86_64 | x86 | arm64 | armv7 -->
    <Configuration>Debug</Configuration>     <!-- Debug | Release -->
    <StaticLink>false</StaticLink>
  </PropertyGroup>
  <ItemGroup>
    <Compile Remove="experimentos/**" />                         <!-- excluir archivos -->
    <Compile Include="../compartido/*.fst" />                    <!-- añadir archivos -->
    <ProjectReference Include="../Utilidades/Utilidades.fstproj" />
    <NativeLibrary Include="user32" />                           <!-- -luser32 -->
    <LibraryPath Include="libs" />                               <!-- -Llibs -->
  </ItemGroup>
</Project>
```

Se ignoran `bin/`, `obj/`, las carpetas ocultas y las subcarpetas que tienen su propio
`.fstproj`. Las propiedades desconocidas dan error, así una errata no pasa desapercibida.

### Otros comandos

```bash
faset run archivo.fst          # archivos sueltos, sin proyecto
faset check                    # solo errores
faset emit-c -o salida.c       # ver el C intermedio
faset build --sanitize         # detecta errores de memoria y fugas (ASan + UBSan)
faset build --target android   # binario ARM64; --shared para una .so
```

Opciones: `-o`, `-c Debug|Release`, `--target`, `--arch`, `--api`, `--shared`, `--gui`,
`--static`, `--sanitize`, `--cc`, `-l`, `-L`, `--keep-c`, `-v`.

## Namespaces, `using` e `import`

```csharp
namespace Juego.Motor { ... }       // o  namespace Juego::Motor { ... }
namespace Juego;                    // namespace para todo el archivo

using std.collections;              // importa un namespace (C#)
using namespace std::io;            // lo mismo (C++)
import std.text;                    // lo mismo
using Lista = std.collections.List<int>;   // alias de tipo
import "utilidades/cadenas.fst";    // incluye otro archivo (ruta relativa)

std::io::File::Exists("a.txt");     // nombre totalmente cualificado
```

Los módulos de la biblioteca (`std.collections`, `std.io`…) se cargan automáticamente al
importarlos o al usarlos con su nombre completo. `std` se importa siempre.

## El lenguaje

### Tipos

| Faset                   | Notas                                              |
|-------------------------|----------------------------------------------------|
| `bool`, `char`          | `char` es un punto de código Unicode (32 bits)     |
| `sbyte` `byte` `short` `ushort` `int` `uint` `long` `ulong` | enteros de 8 a 64 bits |
| `float` `double`        |                                                    |
| `string`                | vista UTF-8 inmutable `{ptr, len}` (como `string_view`) |
| `T*`                    | puntero, con aritmética como en C                  |
| `T&`                    | referencia (parámetros, retornos y variables locales) |
| `delegate*<A, B, R>`    | puntero a función                                  |
| `struct`                | tipo valor                                         |
| `class`                 | referencia: `new` reserva en el heap, `delete` libera |
| `enum`                  | enteros con nombre                                 |
| `List<T>`, `Dictionary<K,V>`… | plantillas tuyas o de la biblioteca          |

El tipado es estricto, como en C#: solo hay conversiones implícitas sin pérdida
(`int` → `long`, `float` → `double`…); para el resto hace falta `(T)x`. `var` y `auto`
infieren el tipo en tiempo de compilación.

### Qué se toma de cada lenguaje

| De C#                                            | De C++                                         |
|--------------------------------------------------|------------------------------------------------|
| `class`, `struct`, `enum`, `namespace`, `using`  | `::`, `using namespace`, `#include`-like `import` |
| propiedades `int Total => n;` y `{ get { } }`    | funciones y variables globales, `int main()`   |
| métodos de extensión `static int F(this int x)`  | referencias `T&`, `ref`/`out` como alias       |
| sobrecarga `static T operator+(T a, T b)`        | `T& operator[](int i)`                         |
| genéricos `<T>`, `default(T)`, `where` (ignorado) | se instancian por tipo y con *duck typing*    |
| `delegate*<...>`, `&Funcion`                     | `new`/`delete`/`delete[]`, destructores `~T()` |
| `var`, `null`, `int.MaxValue`                    | `auto`, `nullptr`, `sizeof`, `*p`, `&x`, `p->x` |
| `public`/`private` por miembro                   | secciones `public:` / `private:`               |

Por defecto, los miembros de una `class` son privados y los de un `struct`, públicos (como en C++).

### Plantillas

Las plantillas usan la sintaxis de C#, pero se compilan como en C++: cada combinación de tipos
genera su propio código, sin coste en ejecución, y un método solo se comprueba si se usa.
Si un tipo no cumple lo que la plantilla necesita, el error indica dónde se instanció:

```
<std/collections>.fst:448:40: error: el operador '<' no está definido para 'P' ...
<std/collections>.fst:113:48: nota: requerido por 'Algorithms.Sort<P>', usado aquí
programa.fst:26:12: nota: requerido por 'List<P>.Sort', usado aquí
```

### Memoria

```csharp
Punto p = new Punto(1, 2);       // struct: valor en la pila
Punto* pp = &p;  pp->X = 10;     // punteros
Jugador j = new Jugador();       // class: heap
delete j;                        // llama a ~Jugador() y libera
double* v = new double[n];       // arreglo en el heap (a cero)
delete[] v;
```

Usa `faset build --sanitize` para detectar accesos inválidos y fugas.

### Interoperabilidad nativa

Cualquier función de C, de una DLL de Windows o del NDK de Android se declara como `extern`
y se llama directamente:

```csharp
static class LibC { public static extern int printf(byte* format, ...); }
LibC.printf("%d\n".Ptr, 42);
```

`[Export("nombre")]` exporta una función con un nombre de símbolo C concreto, por ejemplo
`JNI_OnLoad` o `android_main` en una biblioteca `--shared`.

## Biblioteca estándar (`lib/std`)

| Módulo            | Contenido |
|-------------------|-----------|
| `std` (siempre)   | `print`, `println`, `panic`, `assert`, `Console`, `Math` (trig., log, `Gcd`, `IsPrime`, `IPow`…), `Memory` (`Alloc`, `New<T>`, `Resize<T>`…), `String`, `Char`, `Convert` (`ToInt32`, `TryToDouble`…), `Environment`, extensiones de `string` (`Trim`, `Substring`, `IndexOf`, `StartsWith`, `Contains`, `ToUpper`, `ToInt`…), comparación de cadenas con `< > ==` |
| `std.collections` | `List<T>` (`Add`, `Insert`, `Remove`, `Sort`, `Where`, `Select`, `Any`, `Sum`, `Min`, `Max`…), `Stack<T>`, `Queue<T>`, `Dictionary<K,V>` (con `dict[k]` al estilo de C++), `HashSet<T>`, `Algorithms` (`Sort`, `BinarySearch`, `Swap`, `Reverse`, `Fill`) |
| `std.text`        | `StringBuilder`, `Text.Split`, `Join`, `Replace`, `Repeat`, `PadLeft`, `PadRight` |
| `std.io`          | `File` (`ReadAllText`, `WriteAllText`, `AppendAllText`, `Exists`, `Delete`), `Directory` (`GetEntries`…), `Path` (`GetFullPath`, `Combine`…) |
| `std.time`        | `Time` (`TickMs`, `TickNs`, `NowUnixMs`, `Sleep`), `DateTime`, `TimeSpan`, `TimeZone`, `Stopwatch` (alta resolución) |
| `std.thread`      | `Thread`, `Mutex`, `RecursiveMutex`, `ConditionVariable`, `Semaphore`, `Atomic`, `AtomicInt`/`AtomicLong`, `ThreadPool`, `Parallel.For`, `Channel<T>` |
| `std.random`      | `Random` (xorshift64*: `Next`, `NextDouble`, `Shuffle<T>`) |
| `std.math`        | `Vec2`, `Vec3`, `Rect` con operadores; `Interp` (`Lerp`, `Remap`, `SmoothStep`) |
| `std.mem`         | `Span<T>` con comprobación de límites, `Arena`, `Box<T>` |
| `std.hash`        | `Hash.Of` (FNV-1a, splitmix64), `Hash.Combine` |
| `std.os`          | `Process.Run`, `Process.Capture`, `ChildProcess` (salida en vivo), `OS.Name`… |
| `std.json`        | `Json.Parse`, `JsonValue` (`Get`, `At`, `AsString`…), `Json.WriteString` |
| `std.net`         | `IPAddress`, `IPEndPoint`, `Dns`, `Socket`, `TcpClient`, `TcpListener`, `UdpClient`, `Uri`, `HttpClient` (ver abajo) |

Toda la biblioteca está escrita en Faset: puedes leerla y ampliarla en `lib/std/`.
Para añadir tu propio módulo, crea `lib/<raiz>/<modulo>.fst`; `using raiz.modulo;` lo cargará.

### Redes (`std.net`)

Sockets BSD de libc en Linux/Android y Winsock2 en Windows (el compilador enlaza `ws2_32`
automáticamente cuando se usa `std.net`).

```csharp
using std.net;

auto http = new HttpClient();
HttpResponse r = http.Get("http://example.com/");
if (r != null) println(r.Body);
else println(http.ErrorMessage);
delete r;

auto server = new TcpListener(IPAddress.Loopback, 0);   // puerto 0 = cualquiera libre
server.Start();
auto client = new TcpClient();
client.Connect("127.0.0.1", server.LocalEndPoint.Port, 2000);
TcpClient peer = server.AcceptTcpClient(2000);
client.WriteLine("hola");
string line;
if (peer.ReadLine(out line)) println(line);
String.Free(line);
```

| Tipo | API |
|------|-----|
| `IPAddress` (struct) | `TryParse`/`Parse` (IPv4, IPv6 con `::`, `%scope` y `[...]`), `ToString` (RFC 5952), `V4`, `V6`, `FromBytes`, `GetByte`, `Any`, `Loopback`, `IPv6Any`, `IPv6Loopback`, `IsLoopback`, `MapToIPv4`/`MapToIPv6`, `==` |
| `IPEndPoint` (struct) | `Address`, `Port`, `TryParse("[::1]:80")`, `ToString` |
| `Dns` | `GetHostAddresses(host, lista)`, `TryResolve(host, out ip)`, `GetHostName()`, `LastError` |
| `Socket` | `Connect(ep, timeoutMs)`, `FinishConnect`, `Bind`, `Listen`, `Accept`, `Send`/`SendAll`, `Receive`, `SendTo`/`ReceiveFrom`, `Poll(ms, SelectMode)`, `Blocking`, `ReceiveTimeout`/`SendTimeout`, `Available`, `SetNoDelay`/`SetReuseAddress`/`SetBroadcast`/`SetKeepAlive`/`SetDualMode`, `LocalEndPoint`/`RemoteEndPoint`, `Shutdown`, `Close` |
| `TcpClient` | `Connect(host, port, timeoutMs)` (prueba todas las direcciones), `Write`, `WriteLine`, `Send`, `Receive`, `Read(StringBuilder)`, `ReadLine(out s)`, `ReadToEnd`, `Available`, `Shutdown`, `Close` |
| `TcpListener` | `Start(backlog)`, `LocalEndPoint`, `Pending(ms)`, `AcceptTcpClient(ms)`, `AcceptSocket(ms)`, `Stop` |
| `UdpClient` | `Bind`, `Connect`, `Send(datos, ep)`, `Receive(buf, n, out ep)`, `Receive(out texto, out ep)`, `SetBroadcast`, `ReceiveTimeout` |
| `Uri` | `Parse`/`TryCreate`, `Scheme`, `UserInfo`, `Host`, `Port`, `Path`, `Query`, `Fragment`, `PathAndQuery()`, `Authority()`, `Resolve(ref)`, `Escape`, `Unescape`, `UnescapeForm`, `GetQueryParameter` |
| `HttpClient` | `Get`, `Post`, `Send(HttpRequest)`, `DefaultHeaders`, `UserAgent`, `Timeout`, `FollowRedirects`, `MaxRedirects`, `BuildRequest` |
| `HttpResponse` | `StatusCode`, `ReasonPhrase`, `Version`, `Headers` (`Get`, `Contains`, sin distinguir mayúsculas), `Body`, `IsSuccess`, `Parse(texto)`, `DecodeChunked`; `HttpResponseReader` para analizar por trozos |

**Errores:** no hay excepciones. Las operaciones devuelven `bool`, un número de bytes (`-1` = error)
o un objeto (`null` = error), y el motivo queda en `Error` (`SocketError`: `TimedOut`,
`ConnectionRefused`, `WouldBlock`, `HostNotFound`…), `ErrorMessage` (texto en español) y
`NativeError` (errno / `WSAGetLastError`) del objeto que falló; `Dns` usa `Dns.LastError`.
Los tiempos de espera van en milisegundos y `-1` significa sin límite.

**Limitaciones:** sin HTTPS/TLS (una URL `https://` falla con `SocketError.Unsupported`), sin
proxies, compresión ni keep-alive (cada petición usa `Connection: close`); el cuerpo de la
respuesta se guarda entero en memoria. En Windows solo x86-64 (las funciones de Winsock son
`__stdcall`, que en x86 de 32 bits no coincide con las declaraciones `extern`).

**Propiedad de la memoria:** las funciones que crean cadenas o colecciones nuevas
(`String.Concat`, `ToUpper`, `Text.Join`, `Dictionary.Keys`…) devuelven memoria que debes
liberar con `String.Free` o `delete`. Las vistas (`Substring`, `Trim`, `Split`) no reservan
memoria.

### Hilos (`std.thread`)

Hilos del sistema (pthreads en Linux/Android, Win32 en Windows). En Linux, `faset` enlaza
`-lpthread` automáticamente cuando el programa usa `std.thread`. La función de un hilo es un
`delegate*<void*, void>` que recibe el puntero que le pases:

```csharp
using std.thread;

class Datos { public Mutex M = new Mutex(); public long Suma; public int Hits; }

static void Trabajo(void* p)
{
    Datos d = (Datos)p;
    for (int i = 1; i <= 1000; i++)
    {
        d.M.Lock(); d.Suma += i; d.M.Unlock();
        Atomic.Increment(&d.Hits);                    // atómico, sin mutex
    }
}

int main()
{
    Datos d = new Datos();
    Thread* hilos = new Thread[4];
    for (int i = 0; i < 4; i++) hilos[i] = Thread.Run(&Trabajo, (void*)d);
    for (int i = 0; i < 4; i++) { hilos[i].Join(); delete hilos[i]; }
    delete[] hilos;
    println(d.Suma);                                  // 2002000
    return 0;
}
```

| Tipo | Contenido |
|------|-----------|
| `Thread` | `new Thread(fn, arg)` + `Start()`, o `Thread.Run(fn, arg)`; `Join`, `Detach` (borrar un `Thread` sin `Join` lo desacopla), `IsStarted`; estáticos `Sleep`, `Yield`, `CurrentId`, `HardwareConcurrency` |
| `Mutex`, `RecursiveMutex` | `Lock`, `TryLock`, `Unlock` (SRWLOCK / CRITICAL_SECTION en Windows) |
| `ConditionVariable` | `Wait(m)`, `Wait(m, ms)` (false si vence el plazo), `NotifyOne`, `NotifyAll`; comprueba la condición en un bucle |
| `Semaphore` | `new Semaphore(n)`, `Wait`, `Wait(ms)`, `TryWait`, `Release`, `Release(n)`, `Count` |
| `Atomic` | `Increment`, `Decrement`, `Add`, `Load`, `Store`, `Exchange`, `CompareExchange(p, valor, comparando)` (devuelve el anterior), `Fence`; para `int*`, `long*` y `void**` (los punteros a `void*` solo en `Load`/`Store`/`Exchange`/`CompareExchange`) |
| `AtomicInt`, `AtomicLong` | contador atómico: `Value`, `Set`, `Increment`, `Add`, `Exchange`, `CompareExchange` |
| `ThreadPool` | `new ThreadPool(n)` (o uno por procesador), `Submit(fn, arg)`, `WaitIdle`, `Pending`, `Shutdown`; `delete` termina lo pendiente y une los hilos |
| `Parallel` | `Parallel.For(desde, hasta, &Cuerpo, arg)` con `static void Cuerpo(int i, void* arg)` |
| `Channel<T>` | cola productor/consumidor: `new Channel<T>(capacidad)` (0 = sin límite), `Send`, `TrySend`, `Receive(out v)`, `Receive(out v, ms)`, `TryReceive`, `Close`, `Count` |

Todas las operaciones atómicas son secuencialmente consistentes. Nada se libera solo: el puntero
`arg` debe seguir vivo mientras el hilo lo use.

### Fechas y horas (`std.time`)

```csharp
using std.time;

DateTime d = new DateTime(2024, 2, 29, 13, 45, 30);   // sin zona (Unspecified)
DateTime ahora = DateTime.Now;                          // local; DateTime.UtcNow en UTC
TimeSpan dif = d.AddMonths(1) - d;                      // 29.00:00:00
println(dif.TotalHours);                                // 696
println((int)d.DayOfWeek);                              // 4 (jueves)
string s = d.ToString("dddd dd/MM/yyyy HH:mm");         // "Thursday 29/02/2024 13:45"
string iso = DateTime.UtcNow.ToIsoString();             // "2026-10-29T14:57:00.3807657Z"
DateTime p;
if (DateTime.TryParseIso("2024-02-29T15:45:30+02:00", out p)) println(p.Hour);   // 13 (UTC)
DateTime.TryParseExact("29/02/2024 13:45", "dd/MM/yyyy HH:mm", out p);
long unix = d.ToUnixSeconds();                          // y DateTime.FromUnixSeconds / FromUnixMs
TimeSpan zona = TimeZone.LocalOffset;                   // p. ej. 01:00:00 para UTC+1
Stopwatch sw = Stopwatch.StartNew();                    // reloj monótono en ns
println(sw.ElapsedMs);                                  // también ElapsedNs, Elapsed (TimeSpan)
```

- `DateTime` guarda ticks de 100 ns desde 0001-01-01 (como C#) y un `Kind` (`Utc`, `Local`,
  `Unspecified`). Componentes: `Year`, `Month`, `Day`, `Hour`, `Minute`, `Second`,
  `Millisecond`, `DayOfWeek`, `DayOfYear`, `Date`, `TimeOfDay`. Aritmética: `Add*`
  (`AddDays`, `AddMonths` recorta al último día del mes…), `+`/`-` con `TimeSpan`, `a - b`.
  Comparaciones `== < >…` por ticks, sin convertir zonas. `ToUniversalTime`/`ToLocalTime`
  usan la zona del sistema (con horario de verano).
- Formatos propios: `yyyy yy MMMM MMM MM M dddd ddd dd d HH H hh h mm m ss s f…fffffff tt zzz K`,
  `'literal'` y `\x`. Los nombres de meses y días están en inglés (invariante).
- ISO-8601: `ToIsoString` escribe `Z` (UTC), `±hh:mm` (local) o nada (sin zona); `TryParseIso`
  acepta fecha, fecha y hora con `T` o espacio, fracción y `Z`/`±hh:mm`/`±hhmm` (con zona el
  resultado se convierte a UTC).
- `TimeSpan`: `FromDays/Hours/Minutes/Seconds/Milliseconds`, `Days`…`Milliseconds`,
  `TotalDays`…`TotalMilliseconds`, operadores y `ToString()` (`[-][d.]hh:mm:ss[.fffffff]`).

## Limitaciones actuales

- Sin herencia, interfaces ni `virtual` (están en la hoja de ruta).
- Sin `foreach`, propiedades con `set`, interpolación `$"..."` ni lambdas (usa `&Funcion`).
- C no fija el orden de evaluación de los operandos: evita expresiones como
  `a[f()] = g()` cuando `f` y `g` tienen efectos que dependen entre sí.
- Los APK de Android y los bindings de Win32 y Android aún no vienen incluidos: se usan con `extern`.
- `std.thread` en Windows supone x86-64/ARM64 (los `extern` no declaran `__stdcall`, como en `std.ui`).
  Varios hilos que escriben con `println` a la vez pueden intercalar líneas: protégelo con un `Mutex`.

## Estructura

```
src/            compilador (C++17): Lexer, Parser, Sema, CodeGen, Project, Runtime, Frontend, Lsp, Json, main
editors/vscode/ extensión de VS Code (gramática, snippets y cliente LSP sin dependencias)
studio/         FasetStudio: IDE escrito en Faset (Vulkan, X11, FreeType)
lib/std/        biblioteca estándar escrita en Faset
examples/       ejemplos; examples/proyecto/ es un proyecto con referencia a una biblioteca
tests/          cases/ (salida), errors/ (diagnósticos), projects/ (.fstproj), lsp/ (servidor de lenguaje)
```

## Licencia

[MIT](LICENSE) © 2026 MantraxStudios
