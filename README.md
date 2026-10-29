<p align="center">
  <img src="studio/assets/logo.png" alt="Faset" width="140">
</p>

<h1 align="center">Faset</h1>

<p align="center">
  Código nativo con la elegancia de C# y la potencia de C++.<br>
  Compilador · Biblioteca estándar · Servidor de lenguaje · Extensión de VS Code · <b>FasetStudio</b>
</p>

---

Lenguaje de programación **nativo**, con **tipado estático estricto**, **memoria manual** y
**seguro por defecto**: los punteros y el código nativo viven en bloques `memory_unsafe` bien
visibles. Su sintaxis **mezcla C# y C++**: clases, propiedades y extensiones de C#, junto con
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
    <RuntimeChecks>true</RuntimeChecks>      <!-- comprobaciones en ejecución (por defecto: solo Debug) -->
    <AllowUnsafe>false</AllowUnsafe>         <!-- true: todo el proyecto es memory_unsafe -->
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
faset build -c Release --checks  # Release con las comprobaciones de seguridad activas
faset build --target android   # binario ARM64; --shared para una .so
```

Opciones: `-o`, `-c Debug|Release`, `--target`, `--arch`, `--api`, `--shared`, `--gui`,
`--static`, `--sanitize`, `--checks`, `--no-checks`, `--allow-unsafe`, `--cc`, `-l`, `-L`, `--keep-c`, `-v`.

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
| `T*`                    | puntero, con aritmética como en C (solo en `memory_unsafe`) |
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
| `var`, `null`, `int.MaxValue`                    | `auto`, `nullptr`, `sizeof`, `*p`, `&x`, `p->x` (en `memory_unsafe`) |
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
Jugador j = new Jugador();       // class: heap
delete j;                        // llama a ~Jugador() y libera
memory_unsafe
{
    Punto* pp = &p;  pp->X = 10; // punteros: solo dentro de memory_unsafe
    double* v = new double[n];   // arreglo crudo en el heap (a cero)
    delete[] v;
}
```

### Seguridad de memoria: `memory_unsafe`

Faset es **seguro por defecto**. El código normal al estilo C# (clases, `new`/`delete`, `List<T>`,
`Dictionary<K,V>`, `string`, genéricos, propiedades, `ref`/`out`, `T&`, punteros a función con
`&Funcion`) se escribe sin anotaciones. Lo que puede corromper la memoria solo se permite dentro
de un **contexto `memory_unsafe`**, de modo que siempre se ve dónde vive el código peligroso:

| Fuera de `memory_unsafe` es un error de compilación |
|-----------------------------------------------------|
| declarar o usar tipos puntero (`int*`, `void*`, `List<int*>`…) en variables, campos, parámetros, retornos, conversiones o argumentos genéricos |
| cualquier expresión cuyo valor sea un puntero: `&x`, `s.Ptr`, `lista.Data`, `new T[n]`, `Memory.Alloc(...)` |
| desreferenciar (`*p`), `p->x`, indexar un puntero (`p[i]`) y la aritmética de punteros (`p + 1`, `p++`, `p += n`) |
| reinterpretar referencias (`(Otra)objeto`, `(void*)obj`, conversiones entre punteros a función) |
| llamar a funciones `extern` (C, Win32, NDK…) y tomar su dirección |
| llamar a métodos marcados `memory_unsafe` (p. ej. todo `Memory.*`) |

El mensaje indica la línea y cómo arreglarlo:

```
programa.fst:12:13: error: desreferenciar un puntero ('*') requiere un contexto memory_unsafe
(usa 'memory_unsafe { ... }' o marca el método o la clase con 'memory_unsafe')
```

Formas de abrir un contexto `memory_unsafe` (de la más precisa a la más amplia):

```csharp
memory_unsafe { Memory.Copy(dst, src, n); }   // bloque

memory_unsafe static void Rellenar(int* p, int n) { ... }
// método: su cuerpo es memory_unsafe *y* solo se puede llamar desde un contexto memory_unsafe
// (como 'unsafe fn' en Rust). Úsalo para API peligrosas.

public memory_unsafe class Lista { int* datos; ... }
// clase o struct: implementación confiable. Sus miembros se siguen pudiendo usar desde código
// seguro, salvo los que tienen punteros en la firma (y los marcados memory_unsafe).

memory_unsafe namespace Bindings { ... }      // todo lo declarado dentro del namespace
memory_unsafe;                                // directiva: todo el archivo (al principio)
<AllowUnsafe>true</AllowUnsafe>               // en el .fstproj: todo el proyecto (o --allow-unsafe)
```

La palabra `unsafe` de C# no existe: da un error que propone `memory_unsafe`. Declarar una función
`extern` no requiere contexto (su firma puede usar punteros), pero llamarla sí. Una API con
implementación insegura y firma sin punteros es un **envoltorio seguro**: quien la llama no
necesita `memory_unsafe`. Así está escrita la biblioteca estándar (`List<T>`, `StringBuilder`,
`File`…: clases `memory_unsafe` con API pública segura).

#### Comprobaciones en ejecución

Lo que no se puede demostrar al compilar se comprueba al ejecutar. Están **activas en Debug** y
desactivadas en Release; se controlan con `<RuntimeChecks>true|false</RuntimeChecks>` o con
`--checks` / `--no-checks` (además definen el símbolo `RUNTIME_CHECKS` para `#if`):

| Comprobación | Qué detecta |
|--------------|-------------|
| referencias nulas | `obj.Campo`, `obj.Metodo()`, propiedades e indexadores sobre una referencia `null` |
| uso después de `delete` | cada objeto lleva una cabecera que `delete` marca como liberada; usarlo después (o hacer `delete` dos veces) termina con un error en vez de corromper memoria. Los objetos liberados pasan por una cuarentena (4096 objetos / 64 MB) antes de volver a `malloc` |
| índices de cadenas | `s[i]` fuera de `0..s.Length-1` |
| división entera | `/`, `%`, `/=` y `%=` por cero, y `int.MinValue / -1` |
| punteros a función | llamada a través de un `delegate*` nulo |

Los límites de `List<T>`, `Span<T>`, `Queue<T>`, `Dictionary.Get`, `Substring`… se comprueban
**siempre**, también en Release. Un fallo escribe en stderr y termina con **código 101**:

```
Faset panic: List: índice fuera de rango at programa.fst:10
```

La línea es la de *tu* código, no la de la biblioteca: los métodos con `[TrackCaller]` (como
`panic`, `assert` o `List.operator[]`) reciben la ubicación de quien los llama. Con
`FASET_PANIC_ABORT=1` el programa llama a `abort()` en lugar de salir, para depurar con gdb.
Una biblioteca `--shared` y el programa que la usa deben compilarse con el mismo valor de
`RuntimeChecks` si se pasan objetos entre ellos (la cabecera de los objetos solo existe con checks).

**Rendimiento** (`examples/benchmark_checks.fst`, gcc, x86-64): en Release las comprobaciones
cuestan un 3 % en total (≈15 % en código dominado por accesos a campos de objetos; ≈0 % en
cadenas y listas); en Debug (`-O0`) el programa tarda ≈1,75× más con ellas. Sin comprobaciones
no se emite ningún código de comprobación ni cabecera en los objetos.

**Lo que no cubre** (usa `faset build --sanitize` para encontrarlo): la propiedad de las cadenas
sigue siendo manual (`String.Free` de una vista o de un literal); una referencia `T&` o un
parámetro `ref` a un elemento de una `List<T>` deja de ser válido si la lista crece mientras se
usa; y un uso después de `delete` ya no se detecta cuando el objeto ha salido de la cuarentena.

### Interoperabilidad nativa

Cualquier función de C, de una DLL de Windows o del NDK de Android se declara como `extern`
y se llama directamente desde un contexto `memory_unsafe`:

```csharp
static class LibC { public static extern int printf(byte* format, ...); }
memory_unsafe { LibC.printf("%d\n".Ptr, 42); }
```

`[Export("nombre")]` exporta una función con un nombre de símbolo C concreto, por ejemplo
`JNI_OnLoad` o `android_main` en una biblioteca `--shared`.

## Biblioteca estándar (`lib/std`)

| Módulo            | Contenido |
|-------------------|-----------|
| `std` (siempre)   | `print`, `println`, `panic`, `assert`, `Console`, `Math` (trig., log, `Gcd`, `IsPrime`, `IPow`…), `Memory` (`Alloc`, `New<T>`, `Resize<T>`…; `memory_unsafe`), `String`, `Char`, `Convert` (`ToInt32`, `TryToDouble`…), `Environment`, extensiones de `string` (`Trim`, `Substring`, `IndexOf`, `StartsWith`, `Contains`, `ToUpper`, `ToInt`…), comparación de cadenas con `< > ==` |
| `std.collections` | `List<T>` (`Add`, `Insert`, `Remove`, `Sort`, `Where`, `Select`, `Any`, `Sum`, `Min`, `Max`…), `Stack<T>`, `Queue<T>`, `Dictionary<K,V>` (con `dict[k]` al estilo de C++), `HashSet<T>`, `Algorithms` (`Sort`, `BinarySearch`, `Swap`, `Reverse`, `Fill`) |
| `std.text`        | `StringBuilder`, `Text.Split`, `Join`, `Replace`, `Repeat`, `PadLeft`, `PadRight` |
| `std.io`          | `File` (`ReadAllText`, `WriteAllText`, `AppendAllText`, `Exists`, `Delete`), `Directory` (`GetEntries`…), `Path` (`GetFullPath`, `Combine`…) |
| `std.time`        | `Time` (`TickMs`, `NowUnixMs`, `Sleep`), `Stopwatch` |
| `std.random`      | `Random` (xorshift64*: `Next`, `NextDouble`, `Shuffle<T>`) |
| `std.math`        | `Vec2`, `Vec3`, `Rect` con operadores; `Interp` (`Lerp`, `Remap`, `SmoothStep`) |
| `std.mem`         | `Span<T>` con comprobación de límites, `Arena`, `Box<T>` |
| `std.hash`        | `Hash.Of` (FNV-1a, splitmix64), `Hash.Combine` |
| `std.os`          | `Process.Run`, `Process.Capture`, `ChildProcess` (salida en vivo), `OS.Name`… |
| `std.json`        | `Json.Parse`, `JsonValue` (`Get`, `At`, `AsString`…), `Json.WriteString` |

Toda la biblioteca está escrita en Faset: puedes leerla y ampliarla en `lib/std/`.
Para añadir tu propio módulo, crea `lib/<raiz>/<modulo>.fst`; `using raiz.modulo;` lo cargará.
La biblioteca no tiene privilegios especiales: cada clase que usa punteros o llama al runtime en C
está marcada `memory_unsafe` (implementación confiable) y su API pública sigue siendo segura.

**Propiedad de la memoria:** las funciones que crean cadenas o colecciones nuevas
(`String.Concat`, `ToUpper`, `Text.Join`, `Dictionary.Keys`…) devuelven memoria que debes
liberar con `String.Free` o `delete`. Las vistas (`Substring`, `Trim`, `Split`) no reservan
memoria.

## Limitaciones actuales

- Sin herencia, interfaces ni `virtual` (están en la hoja de ruta).
- Sin `foreach`, propiedades con `set`, interpolación `$"..."` ni lambdas (usa `&Funcion`).
- C no fija el orden de evaluación de los operandos: evita expresiones como
  `a[f()] = g()` cuando `f` y `g` tienen efectos que dependen entre sí.
- Los APK de Android y los bindings de Win32 y Android aún no vienen incluidos: se usan con `extern`.

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
