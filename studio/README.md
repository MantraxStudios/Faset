# FasetStudio

Entorno de desarrollo para Faset, **escrito en Faset**. Dibuja con **Vulkan**, usa la ventana nativa
de X11 (Linux) o Win32 (Windows), rasteriza el texto con FreeType (stb_truetype en Windows) y obtiene
el IntelliSense del propio compilador.

```bash
make studio                       # desde la raíz del repositorio
./studio/bin/Release/linux-x86_64/FasetStudio                     # ventana de inicio
./studio/bin/Release/linux-x86_64/FasetStudio  ruta/a/MiProyecto  # abrir directamente
```

Se le puede pasar una carpeta, un `.fstproj`, una solución `.fstp` o un archivo `.fst`.

## Windows

> **Compilado pero aún sin probar en un Windows real.** Se ha probado con Wine 10 en Linux (GPU NVIDIA
> a través de winevulkan); ver abajo qué funciona y qué no se ha probado.

```bash
faset build studio --target windows   # desde Linux, con llvm-mingw → studio/bin/Release/windows-x86_64/FasetStudio.exe
scripts/dist.sh windows               # faset-windows-x86_64.zip
```

El zip `faset-windows-x86_64.zip` trae `faset.exe`, `FasetStudio.exe` (aplicación de ventana, sin
consola), `lang\`, `faset.ico`, `lib\`, `install.ps1` y `LEEME.txt`.
`powershell -ExecutionPolicy Bypass -File install.ps1 [-Desktop]` instala en `%LOCALAPPDATA%\Faset`,
lo añade al `PATH` del usuario, crea el acceso directo «FasetStudio» en el menú Inicio
(`%APPDATA%\Microsoft\Windows\Start Menu\Programs\FasetStudio.lnk`; con `-Desktop`, también en el
escritorio) y ejecuta `faset setup windows`. `-Uninstall` lo quita todo, accesos directos incluidos;
`-Android`, `-Yes` y `-NoSetup` funcionan como antes.

- **Requisitos:** Windows 10 o posterior x64 (usa el Universal C Runtime) y un controlador de la GPU
  con Vulkan. `vulkan-1.dll` se carga al arrancar; si falta, se muestra un mensaje de error en español.
- **Ventana:** Win32 consciente del DPI de cada monitor, título en UTF-8, portapapeles y cursores.
- **Fuentes:** de `%WINDIR%\Fonts`: Consolas (código), Segoe UI (interfaz) y Segoe UI Symbol
  (símbolos), rasterizadas con stb_truetype.
- **Configuración** en `%APPDATA%\FasetStudio\settings.ini`; temporales en `%TEMP%`.
- **Compilador:** busca `faset.exe` junto a `FasetStudio.exe`, en la variable `FASET` o en el `PATH`.
  IntelliSense, compilar y ejecutar, nuevo proyecto, paquetes y soluciones llaman a `faset.exe`, que
  necesita el compilador de C de `faset setup windows` (llvm-mingw; lo ejecuta el instalador).
- **Depurador:** necesita un `gdb` de Windows en el `PATH` (MSYS2, WinLibs…); si no está, lo avisa.
- **Android:** busca `adb.exe` en `%ANDROID_HOME%`, `%ANDROID_SDK_ROOT%`, `%LOCALAPPDATA%\Android\Sdk`
  (donde lo instala `faset setup android`) o en el `PATH`.

Probado con Wine: la ventana se abre y dibuja con Vulkan, la ventana de inicio, abrir un proyecto, el
editor (escribir, también ñ, € y emoji, atajos, portapapeles, rueda, doble clic, redimensionar,
minimizar y restaurar), IntelliSense con `faset.exe`, crear un proyecto, el diálogo de abrir carpeta y
la configuración en `%APPDATA%`. **Sin probar:** compilar y ejecutar programas desde el IDE en Windows
(necesita llvm-mingw para Windows, no disponible bajo Wine en la prueba), el depurador, las
herramientas de Android, el DPI alto y las fuentes de un Windows real. **Limitación conocida:** la
interfaz aún no se escala, así que con DPI alto (150 % o más) se dibuja a 1:1 píxeles (pequeño pero
nítido).

## Funciones

- **Ventana de inicio (Hub)** al abrir sin argumentos: proyectos recientes (abrir, quitar de la lista,
  eliminar del disco), **crear proyecto** con una lista de plantillas al estilo de Visual Studio
  (consola, biblioteca, ventana, escritorio con diseñador y Android): buscador por nombre o etiqueta,
  `↑`/`↓` para elegir y el panel de configuración (nombre y ubicación) a la derecha, y **abrir proyecto o carpeta** con un explorador de carpetas integrado
- **Barra de menús** (Archivo, Editar, Ver, Compilar, Proyecto, Ayuda) y **menú contextual** con clic
  derecho en el explorador y en el editor
- **Gestión de archivos**: nuevo archivo o carpeta, renombrar (`F2`), duplicar, copiar ruta, eliminar con
  confirmación y **arrastrar y soltar** para mover archivos y carpetas; las pestañas abiertas siguen al archivo
- **Propiedades del proyecto**: editor visual del `.fstproj` (nombre, tipo de salida, plataforma,
  arquitectura, configuración, enlazado estático, referencias de proyecto y bibliotecas nativas)
- **Interfaz en inglés y traducible**: cada idioma es un archivo `lang/<código>.txt` con líneas
  `English = Traducción` (incluye español). El idioma se cambia desde la barra de estado o el menú Ver y
  se recuerda en `~/.config/fasetstudio/settings.ini` (Windows: `%APPDATA%\FasetStudio\settings.ini`); también `FASET_STUDIO_LANG=es`
- **Diseño monocromo** (negro, grises y blanco) con formas redondeadas y sombras dibujadas en el shader
  y cursores del ratón según la zona (texto, mano, redimensionar)

- **Explorador de soluciones** con el árbol del proyecto
- **Pestañas** y **vista dividida** (`Ctrl+\`), con el mismo archivo en las dos mitades si quieres
- **Resaltado de sintaxis** de Faset (C# + C++), números de línea, línea actual y selección
- **IntelliSense** del compilador real:
  - errores en vivo subrayados en rojo, marcados en la barra de desplazamiento y en la *Lista de errores*
  - autocompletado tras `.`, `::` y `->`, al empezar una palabra o con `Ctrl+Espacio`
  - información al pasar el ratón: firmas, tipos y mensajes de error
  - ir a la definición con `F12` o `Ctrl+clic`, también dentro de la biblioteca estándar
  - también en los `.fstproj` y en la vista de código de los `.fstui`: elementos tras `<`, atributos
    (con espacio), valores tras `="` (`OutputType`, `Anchor`, `Style`…), manejadores para `Click`/`Changed`,
    errores en la línea y el atributo exactos, y `F12` del manejador al código y del control al `.fstui`
- **Depurador** con gdb: puntos de interrupción (`F9` o clic en el margen, con condición), `F5`
  depurar/continuar, `F10`/`F11`/`Shift+F11` paso a paso, paneles *Variables*, *Pila de llamadas* e
  *Inspección*, valores al pasar el ratón y parada en los `panic` y en los fallos (SIGSEGV). Ver
  [Depurador](#depurador).
- **Compilar y ejecutar** con la salida en vivo (`Ctrl+B`, `Ctrl+F5`, `Shift+F5` para detener) y Debug/Release
- Paneles redimensionables (arrastra los separadores)
- Edición: deshacer y rehacer, sangría automática, cierre de `()` `[]` `""`, `Tab`/`Shift+Tab`
  sobre bloques, `Ctrl+/` comentar, `Ctrl+D` duplicar línea, `Ctrl+Shift+K` borrar línea,
  doble y triple clic, portapapeles del sistema
- Navegación y edición rápidas:
  - `Ctrl+←/→` salta por palabras y `Ctrl+↑/↓` por bloques (hasta la siguiente línea en blanco); con `Shift` se selecciona.
  - `Alt+↑/↓` mueve la línea o las líneas seleccionadas y `Alt+Shift+↑/↓` las duplica encima o debajo.
  - `Ctrl+Retroceso` / `Ctrl+Supr` borran la palabra anterior o siguiente.
  - `Ctrl+L` selecciona la línea (repetido, amplía la selección).
  - `Ctrl+Intro` / `Ctrl+Shift+Intro` crean una línea nueva debajo o encima.
- `Ctrl+P` abrir rápido, `Ctrl+N` nuevo archivo, `Ctrl+F`/`F3` buscar, `Ctrl+G` ir a la línea,
  `Ctrl+S` guardar (`Ctrl+Shift+S` todo), `Ctrl+W` cerrar pestaña, `Ctrl+Tab` cambiar de pestaña

## Soluciones (`.fstp`)

Una solución abre **varios proyectos a la vez**, como en Visual Studio (formato y comandos `faset sln`
en el [README principal](../README.md#soluciones-fstp)).

- **Abrir:** Archivo → Abrir acepta un `.fstp`, y una carpeta que contiene un `.fstp` se abre como
  solución. Las soluciones aparecen en *Abrir recientes* con la etiqueta «solución». Un `.fstproj`
  suelto se sigue abriendo como siempre.
- **Crear:** en Archivo → Nuevo proyecto, la casilla **Crear una solución** genera
  `Nombre/Nombre.fstp` con el proyecto dentro (`Nombre/Nombre/`).
- **Explorador de soluciones:** la raíz es «Solución 'MiJuego' (N proyectos)», debajo las carpetas de
  solución y cada proyecto con sus archivos. El proyecto de inicio va en **negrita** y los que no
  existen en el disco aparecen en gris como «(no disponible)».
- **Menú contextual de la solución:** compilar, ejecutar el proyecto de inicio, limpiar, agregar un
  proyecto nuevo (el diálogo de nuevo proyecto, dentro de la carpeta de la solución), agregar un
  proyecto existente, agregar una carpeta de solución, renombrar y abrir el `.fstp`.
- **Menú contextual de una carpeta de solución:** agregar proyectos o subcarpetas dentro de ella, o
  quitarla (sus proyectos pasan a la carpeta superior).
- **Menú contextual de un proyecto:** establecer como proyecto de inicio, compilar solo ese proyecto,
  agregar una referencia a otra biblioteca de la solución (escribe `<ProjectReference>` en su
  `.fstproj`), nuevo archivo o carpeta, propiedades y quitar de la solución (los archivos se conservan).
- **Compilar y ejecutar** (`Ctrl+B`, `Ctrl+F5`; `F5` depura el proyecto de inicio): toda la solución en orden de dependencias y después se
  ejecuta el proyecto de inicio; la salida muestra cada proyecto (`[1/3] Compilando Motor ...`).
- **IntelliSense:** cada archivo se analiza con su propio proyecto (el analizador elige, entre los de
  la solución, el que lo compila), así que el autocompletado y `F12` llegan también a las bibliotecas
  referenciadas. El propio `.fstp` tiene autocompletado (`Project`, `Folder`, `Path` con los
  `.fstproj` de la carpeta, `Startup`...) y marca los proyectos que no existen.

Todos los cambios se hacen con `faset sln` (el IDE lo llama), así que el `.fstp` queda igual que si
se editara desde la línea de órdenes.

## Diseñador de interfaces (`.fstui`)

Al abrir un `.fstui` se muestra el diseñador visual (botón **Diseño | Código** para ver el XML).

- **Herramientas:** Label, Button, TextBox, CheckBox, RadioButton, ComboBox, ListBox, Slider,
  ProgressBar, Panel, PictureBox, TabControl, TreeView, MenuBar y Canvas, y los componentes Timer y
  ContextMenu. Se arrastran a la ventana o se añaden con un clic.
- **Esquema:** árbol de todos los controles. Un clic selecciona y un doble clic va al evento.
- **Mover y redimensionar** con asas, ajustando a la cuadrícula y a guías inteligentes (`Ctrl` desactiva el ajuste).
- **Barra de alinear** en el contenedor (izquierda, centro, derecha, arriba, medio, abajo) y de orden (frente/fondo).
- **Propiedades** por categorías. `Items` usa `;` como separador (`Rojo;Verde;Azul`).
- **Atajos:**
  - `Ctrl+C` / `Ctrl+X` / `Ctrl+V` copiar, cortar y pegar controles.
  - `Ctrl+D` duplicar y `Supr` borrar.
  - `Ctrl+Z` / `Ctrl+Y` deshacer y rehacer.
  - `Tab` pasa al siguiente control.
  - `Ctrl+↑` / `Ctrl+↓` traer al frente o enviar al fondo.
  - Flechas para mover (`Shift`: de 8 en 8).
- **Doble clic** en un control crea su manejador (`OnGuardarClick`…) en el código de la ventana.
- **Moverse por el lienzo:** rueda (vertical), `Shift`+rueda (horizontal) o arrastrar con la rueda pulsada.
- **Colores:** sección *Colores* con muestra, código `#RRGGBB` (o `#RRGGBBAA`) y paleta.
  - `Background` + `Background2` crean un degradado; su dirección se elige con `GradientDirection`.
  - `Foreground` es el color del texto y `BorderColor` el del borde.
  - `Accent` colorea la casilla marcada, el deslizador y la barra de progreso.
  - La ventana también admite `Background`, `Background2` y `GradientDirection`.

### Imágenes, pestañas, árbol, menús, lienzo y componentes

- **PictureBox** muestra PNG, JPEG, BMP o GIF (primer fotograma) con `Source` (ruta relativa al
  proyecto) y `SizeMode`: `Normal`, `Stretch`, `Zoom` (cabe entera sin deformarse), `Center` o
  `Cover` (llena y recorta). Se escala con filtro bilineal. `Button` y `MenuItem` aceptan `Icon`.
  En el código, la clase `Image` (`Image.FromFile`, `Image.Load`, `GetPixel`/`SetPixel`) sirve
  también para el Canvas. El compilador copia junto al ejecutable (y mete en el APK de Android) la
  carpeta `Assets/` del proyecto y las imágenes que nombran los `.fstui`.
- **TabControl:** las páginas son `<TabPage Text="...">` con sus controles dentro. En el diseñador,
  un clic en una pestaña muestra esa página (los controles que se sueltan encima van a ella) y `+`
  añade otra. `SelectedIndex`, `SelectedPage`, evento `SelectedChanged`; `Ctrl+Tab` cambia de página.
- **TreeView:** nodos `<TreeNode Text="..." Expanded="true" Tag="...">` anidados (con `Name` se
  genera un campo `TreeNode`). En código: `AddNode`, `node.Add`, `Nodes`, `SelectedNode`, eventos
  `SelectedChanged` y `NodeActivated` (doble clic o Enter); teclado ↑ ↓ ← → Inicio Fin.
- **MenuBar y ContextMenu:** `<Menu Text="Archivo">` con `<MenuItem Text Shortcut Icon Checked Enabled
  Click>`, `<Separator/>` y submenús (`<Menu>` dentro de `<Menu>`). El atajo (`Ctrl+S`, `F5`...)
  funciona aunque el menú esté cerrado. Un control abre un `ContextMenu` con el botón derecho si lo
  nombra en su propiedad `ContextMenu` (`menu.SourceControl` dice sobre cuál se abrió).
  **Edición en el diseñador:** un clic en una cabecera de la barra despliega ese menú y un clic en un
  elemento lo elige (doble clic: su manejador `Click`). Los botones *Añadir elemento / separador /
  submenú / menú* del panel de propiedades crean entradas, `Ctrl+↑/↓` las cambia de orden y `Supr`
  las borra. El **esquema** muestra todo el árbol de menús (y la vista de código, el XML).
- **Canvas:** dibujo libre. `Paint` recibe un `Graphics` (`Clear`, `FillRect`, `DrawRect`,
  `FillRoundRect`, `DrawLine`, `FillCircle`, `DrawCircle`, `DrawText`, `DrawImage`, `FillGradient`,
  `SetClip`); `MouseDown`/`MouseMove`/`MouseUp` reciben un `MouseArgs` (X, Y, Button, Clicks).
  `Invalidate()` pide otro fotograma. Los manejadores se crean con la firma correcta.
- **Componentes no visuales** (`Timer`, `ContextMenu`) van directamente dentro de `<Window>` y el
  diseñador los muestra en la **bandeja de componentes** bajo la ventana: un clic los elige, doble
  clic va a su evento (`Tick`). Para añadir otro tipo de componente basta con incluirlo en
  `UiNode.IsComponentKind` (Designer.fst) y en `Widget.IsComponent` (lib/std/ui/kinds.fst).
- **Timer:** `Interval` (ms), `Enabled`, `Start()`, `Stop()` y el evento `Tick`, que llega en el hilo
  de la interfaz (la espera de eventos de la ventana se acorta para despertar a tiempo).

Pruebas sin pantalla: `FASET_UI_SCREENSHOT=captura.bmp FASET_UI_SCRIPT="click X Y | rclick X Y |
dblclick X Y | key ctrl+s | wait 500" ./App` (`wait` avanza el reloj de los Timer sin esperar).
El ejemplo `examples/controles` usa todos estos controles.

## Depurador

`F5` compila el proyecto (en una solución, el de inicio) con información de depuración
(`faset build -g -o obj/debug/<Nombre>`) y lo ejecuta bajo **gdb** (`gdb --interpreter=mi3`, por
tuberías). El compilador emite `#line N "archivo.fst"` en el C de Debug, así que gdb trabaja con las
líneas de Faset; `src/Ide/Debugger.fst` traduce los nombres del C (`l_x`, `p_x`, `self`, `f_Campo`,
`Ns_Clase__m_Metodo`) a los de Faset.

- **Puntos de interrupción:** `F9` o clic en el margen; botón derecho para ponerles una condición en
  Faset (`i == 3`, `jugador.Vida < 10`). Se guardan por proyecto y siguen a su línea al editar.
- **Controles:** `F5` continuar, `F10` saltar la llamada, `F11` entrar, `Shift+F11` salir,
  `Shift+F5` detener; mientras se depura, la barra de búsqueda se convierte en la barra de depuración
  (continuar, pausa, detener, reiniciar y los tres pasos). `Ctrl+F5` ejecuta sin depurar.
- **Paneles** (acoplables): *Variables* (locales y parámetros del marco; objetos, `List<T>`,
  `string` como texto y `enum` por nombre), *Pila de llamadas* (clic para cambiar de marco) e
  *Inspección* (expresiones de Faset: `heroe.Vida * 2`, `lista[i]`). Pasar el ratón sobre una
  variable muestra su valor.
- **Panics y fallos:** un `panic` (`faset_panic_at`) o una señal (SIGSEGV...) detienen el programa
  en la línea de Faset que los produjo, con el mensaje en *Variables* y en *Salida*.
- **Solo mi código** (menú Compilar): el paso a paso no entra en la biblioteca estándar.
- La salida del programa va al panel *Salida*; no hay entrada estándar (`< /dev/null`).
- Linux con gdb ≥ 9 (`sudo apt install gdb`); en Windows, un `gdb` de Windows en el `PATH` (sin
  probar). Android y la depuración remota no están soportados. `FASET_DEBUG_MI=archivo` guarda el diálogo con gdb para diagnosticar.

Verbos del modo sin ventana: `bp archivo línea [condición]`, `debug`, `next`, `step`, `stepout`,
`continue`, `pause`, `restart`, `waitstop`, `stopdebug`, `frame N`, `expand ruta`, `watch expr`,
`print ruta` y `debugstate` (los que avanzan esperan a que el programa se detenga):

```bash
FasetStudio Juego --screenshot dbg.ppm --script "open Program.fst | bp Program.fst 20 | debug | step | expand this | debugstate"
```

## Paneles acoplables

Explorador, Salida, Problemas y los paneles del depurador se pueden colocar a la izquierda, a la derecha o abajo.
- **Arrastra su pestaña** hacia un borde. Aparecen guías y una vista previa del hueco donde quedará.
- **Botón derecho en la pestaña:** acoplar a un lado, ocultar o restablecer la disposición.
- Los paneles que están en el mismo lado se muestran como pestañas.
- **Ver → Explorador / Salida / Problemas** los muestra u oculta.
- La disposición y los tamaños se guardan en `~/.config/fasetstudio/settings.ini` (Windows: `%APPDATA%\FasetStudio\settings.ini`).

Los RadioButton con el mismo `Group` dentro del mismo contenedor se excluyen entre sí. ComboBox y
ListBox exponen `Items`/`SetItems`, `AddItem`, `RemoveItemAt`, `ClearItems`, `SelectedIndex` y
`SelectedItem`, y lanzan `Changed` al elegir.

## Arquitectura

| Archivo                | Contenido                                                          |
|------------------------|--------------------------------------------------------------------|
| `src/Gfx/Vk.fst`       | bindings de Vulkan escritos en Faset (structs con la disposición de C) |
| `src/Gfx/Renderer.fst` | renderizador 2D: swapchain, pipeline, atlas, lotes con recorte, capturas |
| `src/Gfx/Font.fst`     | FreeType (Linux) o stb_truetype (Windows) → atlas de glifos bajo demanda |
| `src/Gfx/Shaders.fst`  | SPIR-V generado desde `shaders/ui.vert` y `shaders/ui.frag`        |
| `src/Platform/X11.fst` | ventana, teclado, ratón y portapapeles con Xlib                    |
| `src/Platform/Win32.fst` | lo mismo en Windows con Win32                                    |
| `src/Ide/Debugger.fst` | depurador: gdb por MI, puntos de interrupción, variables, pila e inspección |
| `src/Ide/*.fst`        | búfer de texto, resaltado, editor, explorador, IntelliSense y la aplicación |

La GPU se elige automáticamente (prefiere la dedicada). `FASET_STUDIO_GPU=cpu` fuerza lavapipe (Vulkan por software).

**Modo de prueba sin ventana**, que se usa en `make test`:

```bash
FasetStudio carpeta --screenshot captura.ppm --size 1400x860 --script "open Program.fst | goto 10 5 | type heroe. | hover 12 8"
```

Para regenerar los shaders hace falta `npm install @webgpu/glslang@0.0.15` y luego
`node shaders/compile.mjs shaders/ui.vert shaders/ui.frag src/Gfx/Shaders.fst`.

## Limitaciones

- Linux (X11/XWayland) y Windows (Win32). La versión de Windows está compilada pero aún sin probar en
  un Windows real (ver [Windows](#windows)).
- La interfaz aún no se escala: en pantallas de DPI alto (150 % o más) se dibuja a 1:1 píxeles.
- Los programas que se ejecutan con Ctrl+F5 (o se depuran con F5) no reciben entrada por teclado: la
  salida va al panel *Salida*.
- No hay refactorizaciones (renombrar, buscar referencias).
- En una solución, los proyectos no se pueden arrastrar entre carpetas de solución desde el explorador
  (usa `faset sln move`), y quitar una referencia de proyecto se hace en Propiedades.
