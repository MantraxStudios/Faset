# Faset para VS Code

Soporte para el lenguaje **Faset** (`.fst`), sus proyectos (`.fstproj`) y sus interfaces (`.fstui`).

## Funciones

- **Resaltado de sintaxis** de la mezcla C# / C++: `::`, `->`, plantillas `<T>`, `delegate*<...>`,
  `operator`, referencias `T&`, `nullptr`, destructores `~T()`, etc.
- **IntelliSense** del propio compilador (`faset lsp`):
  - errores y avisos en vivo mientras escribes
  - autocompletado de miembros (`.`, `::`, `->`), variables, tipos, funciones, namespaces y
    módulos de la biblioteca (`using std.`)
  - información al pasar el ratón: tipos y firmas
  - ir a la definición (F12), también dentro de la biblioteca estándar
  - esquema del documento (Ctrl+Shift+O)
  - formatear documento (Shift+Alt+F) con `faset fmt`
- **Proyectos `.fstproj`**: resaltado XML, snippets (`fstproj`, `ProjectReference`, `NativeLibrary`…),
  autocompletado de elementos, propiedades y valores (`OutputType`, `TargetPlatform`, `Configuration`…),
  errores en vivo (propiedad desconocida, valor no válido) y documentación al pasar el ratón.
- **Interfaces `.fstui`**: autocompletado de controles tras `<`, de los atributos válidos de cada control y
  de sus valores (`Anchor`, `Style`, `TextAlign`, `Theme`…), nombres de manejadores para `Click`/`Changed`
  sacados del código de la ventana, errores del generador en la línea y el atributo correctos e ir a la
  definición del manejador (y, desde el `.fst`, del control en el `.fstui`).
- **Comandos**: *Faset: Compilar* (Ctrl+Shift+B), *Faset: Ejecutar* (Ctrl+F5),
  *Faset: Compilar (Release)*, *Faset: Ejecutar pruebas* y *Faset: Reiniciar el servidor de lenguaje*.
- **Snippets**: `main`, `program`, `class`, `struct`, `classT`, `prop`, `operator`, `indexer`,
  `ext`, `for`, `forlist`, `switch`, `list`, `dict`, `using`…

## Requisitos

El compilador `faset` debe estar en el `PATH` o configurado en **`faset.path`**. Si la extensión
se instala desde el repositorio de Faset (`make vscode-install`), usa directamente el `faset`
compilado en la raíz del repositorio.

## Configuración

| Opción        | Descripción                                                  |
|---------------|--------------------------------------------------------------|
| `faset.path`  | Ruta del ejecutable `faset` (vacío = buscar en el `PATH`)     |
| `faset.trace` | Muestra el tráfico LSP en el canal de salida *Faset*          |
