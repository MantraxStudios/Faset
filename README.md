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
| Android             | SDK + NDK + build-tools + Java (ver [Android](#android))       |

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
faset new MiUi --ui           # AppUI: ventana de std.ui con diseñador (.fstui)
faset new MiMovil --android   # app de Android (ver la sección Android)
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

**Referencias entre proyectos.** Un `<ProjectReference>` debe apuntar a un proyecto con
`OutputType=Library`, que a su vez puede referenciar otras bibliotecas (se detectan los ciclos y
cada biblioteca se incluye una sola vez aunque llegue por varios caminos). Como las plantillas
de Faset se instancian por tipo (igual que en C++), las bibliotecas referenciadas se compilan
**dentro** del programa que las usa: sus namespaces y tipos quedan visibles, y sus
`NativeLibrary`, `LibraryPath` y `AndroidPermission` se heredan. El resultado es un único
binario (o una única `lib<App>.so` en el APK) para cualquier objetivo, sin `.so` intermedias que
desplegar. `faset build` dentro de una biblioteca produce su `lib<Nombre>.so` / `.dll`.
Ejemplo: `tests/projects/cadena` (App → Motor → Base, y App → Base).

### Otros comandos

```bash
faset run archivo.fst          # archivos sueltos, sin proyecto
faset check                    # solo errores
faset emit-c -o salida.c       # ver el C intermedio
faset build --sanitize         # detecta errores de memoria y fugas (ASan + UBSan)
faset build --target android   # APK firmado (ver Android); --shared para una .so
```

Opciones: `-o`, `-c Debug|Release`, `--target`, `--arch`, `--api`, `--device`, `--no-apk`,
`--shared`, `--gui`, `--static`, `--sanitize`, `--cc`, `-l`, `-L`, `--keep-c`, `-v`.

## Android

`faset` genera **APK firmados** sin Java, Gradle ni Android Studio abierto: el programa se compila
con el NDK como `lib<App>.so`, se carga desde una `NativeActivity` y se empaqueta con las
herramientas del SDK (`aapt2`, `zipalign`, `apksigner`).

### Preparación

1. Instala el SDK de Android (Android Studio o las *cmdline-tools*). `faset` lo busca en
   `ANDROID_HOME`, `ANDROID_SDK_ROOT`, `~/Android/Sdk`, `%LOCALAPPDATA%\Android\Sdk` o `~/Library/Android/sdk`.
2. Instala el NDK, las build-tools y una plataforma:

   ```bash
   sdkmanager --install "ndk;30.0.16248370" "build-tools;36.0.0" "platforms;android-36" platform-tools emulator
   ```

   El NDK más reciente de `<SDK>/ndk/<versión>` se detecta solo (o usa `ANDROID_NDK_HOME`).
3. Java (para `apksigner` y `keytool`): `JAVA_HOME`, `java` en el `PATH` o el JBR de Android
   Studio (`~/android-studio/jbr`…), que se usa automáticamente.
4. `faset doctor` muestra el SDK, el NDK, las build-tools, la plataforma, `adb`, el emulador,
   Java y los AVD encontrados.

La primera vez se crea la clave de depuración `~/.android/debug.keystore` (la misma que usa
Android Studio) si no existe.

### Crear, compilar y ejecutar

```bash
faset new MiApp --android            # interfaz táctil (std.ui) con las propiedades de Android
faset new Hola --android --console   # programa de consola: Console.WriteLine va a logcat
cd MiApp
faset android avds                   # emuladores disponibles
faset android emulator Medium_Phone_API_37.0 --headless   # arranca y espera; imprime la serie
faset run                            # compila el APK, lo instala, lo abre y muestra su logcat
faset build                          # bin/Debug/android/MiApp.apk
faset build -c Release               # APK sin depuración (firma con AndroidKeystore si existe)
faset run --target native            # el mismo programa en el escritorio
```

Cualquier proyecto se compila para Android con `--target android`; `--arch arm64` limita el APK
a una ABI y `--no-apk` produce el ejecutable ELF suelto de antes (para `adb push`).
Una biblioteca (`OutputType=Library` o `--shared`) produce `lib<Nombre>.so`.

`faset run --target android [--device <serie>]` sigue el log del proceso de la app hasta que
termina (o Ctrl+C) y devuelve su código de salida. Muestra la salida del programa
(`I/MiApp: ...`) y los errores del proceso; con `-v`, todo su logcat. Al final se imprime
`[faset] fin del programa (código N)` y, si hubo un fallo nativo, el búfer `crash` de logcat.

### Comandos `faset android`

| Comando | Salida |
|---------|--------|
| `faset android devices` | una línea por dispositivo: `serie<TAB>estado<TAB>modelo` (p. ej. `emulator-5554	device	sdk_gphone64_x86_64`) |
| `faset android avds` | un AVD por línea |
| `faset android emulator <avd> [--headless] [--no-wait] [-- opciones]` | arranca el emulador en segundo plano, espera a `sys.boot_completed` e imprime su serie en stdout (el progreso va a stderr) |
| `faset android logcat [--device s] [--app] [--clear] [-- args]` | `adb logcat -v tag`; `--app` filtra por el proceso de la app del proyecto |
| `faset android stop` / `uninstall` | detiene / desinstala la app del proyecto |

### Propiedades del `.fstproj`

```xml
<PropertyGroup>
  <TargetPlatform>android</TargetPlatform>        <!-- 'faset run' apunta a Android -->
  <AndroidPackage>com.miempresa.miapp</AndroidPackage>  <!-- por defecto com.faset.<nombre> -->
  <AppName>Mi App</AppName>                       <!-- nombre visible (por defecto AssemblyName) -->
  <VersionCode>1</VersionCode>
  <VersionName>1.0</VersionName>                  <!-- por defecto <Version> o 1.0 -->
  <AndroidApi>24</AndroidApi>                     <!-- minSdk (también --api) -->
  <AndroidTargetSdk>36</AndroidTargetSdk>         <!-- por defecto la plataforma instalada más reciente -->
  <AndroidAbis>arm64-v8a;x86_64</AndroidAbis>     <!-- arm64-v8a, armeabi-v7a, x86, x86_64 -->
  <AndroidOrientation>portrait</AndroidOrientation>
  <AndroidIcon>icono.png</AndroidIcon>
  <AndroidKeystore>release.jks</AndroidKeystore>  <!-- firma propia; si no, la de depuración -->
  <AndroidKeyAlias>miclave</AndroidKeyAlias>
  <!-- contraseñas: FASET_ANDROID_KEYSTORE_PASSWORD / FASET_ANDROID_KEY_PASSWORD
       (o AndroidKeystorePassword / AndroidKeyPassword) -->
</PropertyGroup>
<ItemGroup>
  <AndroidPermission Include="INTERNET;CAMERA" />  <!-- android.permission.* (también de las bibliotecas referenciadas) -->
  <NativeLibrary Include="miotra" />               <!-- libmiotra.so se mete en el APK si está en LibraryPath -->
  <LibraryPath Include="libs/$(AndroidAbi)" />
</ItemGroup>
```

### Cómo funciona

- `lib/android/faset_android.c` implementa `android_main` (con `android_native_app_glue` del NDK):
  el programa corre en su propio hilo, así un `Main()` largo nunca bloquea la actividad; al
  terminar `Main()` se cierra la actividad y el proceso.
- `stdout`/`stderr` se redirigen a logcat con la etiqueta de la app. La carpeta de trabajo (y
  `HOME`) es el almacenamiento interno de la app, así `File.WriteAllText("datos.txt", ...)` funciona.
- **std.ui** en Android (`#if ANDROID`): la ventana ocupa toda la pantalla; el lienzo se copia a
  `ANativeWindow`; los toques llegan como ratón (botón 1); la rotación y los cambios de tamaño
  se notifican como `Resize`; un `TextBox` con foco abre el teclado en pantalla y sus teclas
  llegan como caracteres; el portapapeles es el del sistema. Las coordenadas son lógicas
  (dp): todo se escala por la densidad (`dpi / 160`) y el texto se rasteriza al tamaño real con
  `/system/fonts/Roboto-Regular.ttf` mediante **stb_truetype** (el NDK no ofrece FreeType), así
  se ve nítido. Se enlazan `android` y `log`.
- Las `.so` van sin comprimir y alineadas a 16 KB (`zipalign -P 16`, Android 15+).


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
| `std.time`        | `Time` (`TickMs`, `NowUnixMs`, `Sleep`), `Stopwatch` |
| `std.random`      | `Random` (xorshift64*: `Next`, `NextDouble`, `Shuffle<T>`) |
| `std.math`        | `Vec2`, `Vec3`, `Rect` con operadores; `Interp` (`Lerp`, `Remap`, `SmoothStep`) |
| `std.mem`         | `Span<T>` con comprobación de límites, `Arena`, `Box<T>` |
| `std.hash`        | `Hash.Of` (FNV-1a, splitmix64), `Hash.Combine` |
| `std.os`          | `Process.Run`, `Process.Capture`, `ChildProcess` (salida en vivo), `OS.Name`… |
| `std.json`        | `Json.Parse`, `JsonValue` (`Get`, `At`, `AsString`…), `Json.WriteString` |

Toda la biblioteca está escrita en Faset: puedes leerla y ampliarla en `lib/std/`.
Para añadir tu propio módulo, crea `lib/<raiz>/<modulo>.fst`; `using raiz.modulo;` lo cargará.

**Propiedad de la memoria:** las funciones que crean cadenas o colecciones nuevas
(`String.Concat`, `ToUpper`, `Text.Join`, `Dictionary.Keys`…) devuelven memoria que debes
liberar con `String.Free` o `delete`. Las vistas (`Substring`, `Trim`, `Split`) no reservan
memoria.

## Limitaciones actuales

- Sin herencia, interfaces ni `virtual` (están en la hoja de ruta).
- Sin `foreach`, propiedades con `set`, interpolación `$"..."` ni lambdas (usa `&Funcion`).
- C no fija el orden de evaluación de los operandos: evita expresiones como
  `a[f()] = g()` cuando `f` y `g` tienen efectos que dependen entre sí.
- Los bindings de Win32 y de Android más allá de `std.ui` no vienen incluidos: se usan con `extern`.
- Android: `std.ui` no conoce los recortes de la pantalla (la barra de navegación se dibuja
  encima) ni redimensiona la ventana cuando aparece el teclado; la entrada de texto usa
  eventos de tecla (sin autocorrección ni IME complejos).

## Estructura

```
src/            compilador (C++17): Lexer, Parser, Sema, CodeGen, Project, Runtime, Frontend, Lsp, Json, Android, main
editors/vscode/ extensión de VS Code (gramática, snippets y cliente LSP sin dependencias)
studio/         FasetStudio: IDE escrito en Faset (Vulkan, X11, FreeType)
lib/std/        biblioteca estándar escrita en Faset
lib/android/    capa nativa de Android (NativeActivity, logcat, stb_truetype) que se compila en cada APK
examples/       ejemplos; examples/proyecto/ es un proyecto con referencia a una biblioteca
tests/          cases/ (salida), errors/ (diagnósticos), projects/ (.fstproj), lsp/ (servidor de lenguaje)
```

## Licencia

[MIT](LICENSE) © 2026 MantraxStudios
