# FasetStudio

Entorno de desarrollo para Faset, **escrito en Faset**. Dibuja con **Vulkan**, usa la ventana nativa
de X11, rasteriza el texto con FreeType y obtiene el IntelliSense del propio compilador.

```bash
make studio                       # desde la raíz del repositorio
./studio/bin/Release/linux-x86_64/FasetStudio                     # ventana de inicio
./studio/bin/Release/linux-x86_64/FasetStudio  ruta/a/MiProyecto  # abrir directamente
```

Se le puede pasar una carpeta, un `.fstproj` o un archivo `.fst`.

## Funciones

- **Ventana de inicio (Hub)** al abrir sin argumentos: proyectos recientes (abrir, quitar de la lista,
  eliminar del disco), **crear proyecto** con plantillas (aplicación de consola, biblioteca, aplicación
  de ventana) y **abrir proyecto o carpeta** con un explorador de carpetas integrado
- **Barra de menús** (Archivo, Editar, Ver, Compilar, Proyecto, Ayuda) y **menú contextual** con clic
  derecho en el explorador y en el editor
- **Gestión de archivos**: nuevo archivo o carpeta, renombrar (`F2`), duplicar, copiar ruta, eliminar con
  confirmación y **arrastrar y soltar** para mover archivos y carpetas; las pestañas abiertas siguen al archivo
- **Propiedades del proyecto**: editor visual del `.fstproj` (nombre, tipo de salida, plataforma,
  arquitectura, configuración, enlazado estático, referencias de proyecto y bibliotecas nativas)
- **Interfaz en inglés y traducible**: cada idioma es un archivo `lang/<código>.txt` con líneas
  `English = Traducción` (incluye español). El idioma se cambia desde la barra de estado o el menú Ver y
  se recuerda en `~/.config/fasetstudio/settings.ini`; también `FASET_STUDIO_LANG=es`
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
- **Compilar y ejecutar** con la salida en vivo (`Ctrl+B`, `F5`, `Shift+F5` para detener) y Debug/Release
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

## Diseñador de interfaces (`.fstui`)

Al abrir un `.fstui` se muestra el diseñador visual (botón **Diseño | Código** para ver el XML).

- **Herramientas:** Label, Button, TextBox, CheckBox, RadioButton, ComboBox, ListBox, Slider,
  ProgressBar y Panel. Se arrastran a la ventana o se añaden con un clic.
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

## Paneles acoplables

Explorador, Salida y Problemas se pueden colocar a la izquierda, a la derecha o abajo.
- **Arrastra su pestaña** hacia un borde. Aparecen guías y una vista previa del hueco donde quedará.
- **Botón derecho en la pestaña:** acoplar a un lado, ocultar o restablecer la disposición.
- Los paneles que están en el mismo lado se muestran como pestañas.
- **Ver → Explorador / Salida / Problemas** los muestra u oculta.
- La disposición y los tamaños se guardan en `~/.config/fasetstudio/settings.ini`.

Los RadioButton con el mismo `Group` dentro del mismo contenedor se excluyen entre sí. ComboBox y
ListBox exponen `Items`/`SetItems`, `AddItem`, `RemoveItemAt`, `ClearItems`, `SelectedIndex` y
`SelectedItem`, y lanzan `Changed` al elegir.

## Arquitectura

| Archivo                | Contenido                                                          |
|------------------------|--------------------------------------------------------------------|
| `src/Gfx/Vk.fst`       | bindings de Vulkan escritos en Faset (structs con la disposición de C) |
| `src/Gfx/Renderer.fst` | renderizador 2D: swapchain, pipeline, atlas, lotes con recorte, capturas |
| `src/Gfx/Font.fst`     | FreeType → atlas de glifos bajo demanda                            |
| `src/Gfx/Shaders.fst`  | SPIR-V generado desde `shaders/ui.vert` y `shaders/ui.frag`        |
| `src/Platform/X11.fst` | ventana, teclado, ratón y portapapeles con Xlib                    |
| `src/Ide/*.fst`        | búfer de texto, resaltado, editor, explorador, IntelliSense y la aplicación |

La GPU se elige automáticamente (prefiere la dedicada). `FASET_STUDIO_GPU=cpu` fuerza lavapipe (Vulkan por software).

**Modo de prueba sin ventana**, que se usa en `make test`:

```bash
FasetStudio carpeta --screenshot captura.ppm --size 1400x860 --script "open Program.fst | goto 10 5 | type heroe. | hover 12 8"
```

Para regenerar los shaders hace falta `npm install @webgpu/glslang@0.0.15` y luego
`node shaders/compile.mjs shaders/ui.vert shaders/ui.frag src/Gfx/Shaders.fst`.

## Limitaciones

- Solo Linux (X11/XWayland) por ahora. La versión de Windows necesita un backend Win32 para la ventana.
- Los programas que se ejecutan con F5 no reciben entrada por teclado: la salida va al panel *Salida*.
- No hay depurador ni refactorizaciones (renombrar, buscar referencias).
