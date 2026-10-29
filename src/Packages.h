// Faset - gestor de paquetes (sin servidor central: git, rutas locales y un índice estático opcional).
//
// En el .fstproj:
//   <PackageReference Include="Json5" Git="https://github.com/usuario/json5-faset" Version="^1.2" />
//   <PackageReference Include="Json5" Git="..." Branch="main" />        punta de una rama
//   <PackageReference Include="Json5" Git="..." Commit="a1b2c3d" />     un commit concreto
//   <PackageReference Include="MiLib" Path="../milib" />                carpeta local
//   <PackageReference Include="Json5" Version="^1.2" />                 se busca en el índice
//   Folder="subcarpeta"  el .fstproj del paquete no está en la raíz del repositorio
//
// Un paquete es un proyecto Library. Version es una restricción semver que se compara con las
// etiquetas del repositorio (v1.2.0 o 1.2.0): exacta (1.2.0), ^1.2, ~1.2, 1.2.x, >=1.0 <2.0, ||.
// Se resuelven también las dependencias de los paquetes; el resultado (con el commit de cada uno)
// se guarda en paquetes.lock junto al .fstproj y los repositorios en la caché:
//   ~/.local/share/faset/paquetes/<nombre>/<versión o commit>   (%LOCALAPPDATA%\Faset\paquetes)
// Cada paquete se compila como un <ProjectReference> más (fuentes, NativeLibrary, Asset...).
//
// Índice: JSON estático (FASET_PAQUETES_INDICE, <PackageIndex> o https://faset.lat/paquetes/index.json)
//   { "formato": 1, "paquetes": { "Json5": { "git": "https://...", "carpeta": "", "descripcion": "...",
//                                            "versiones": ["1.0.0", "1.2.0"] } } }
#pragma once
#include <string>
#include <vector>

// Proyectos (.fstproj) de los paquetes que necesita 'projPath' (y los proyectos que referencia),
// listos para compilar: descarga lo que falte respetando paquetes.lock y lo actualiza si hace falta.
bool packagesForBuild(const std::string& projPath, std::vector<std::string>& projects, std::string& error);

// Lo mismo sin red ni escribir nada: lo que dice paquetes.lock y ya está en la caché (IntelliSense).
std::vector<std::string> lockedPackageProjects(const std::string& projPath);

// faset add | remove | restore | update | list paquetes | pack | publish | new X --package.
// Devuelve false si la orden no es suya.
bool packageCommand(const std::vector<std::string>& args, const std::string& self, int& code);

// Para el IntelliSense del .fstproj: qué dice paquetes.lock (y la caché) de un paquete.
struct PackageStatus {
    bool lockExists = false;  // hay paquetes.lock junto al proyecto
    bool locked = false;      // el paquete está en él
    std::string description;  // "Json5 1.2.0 · commit a1b2c3d · origen"
    std::string project;      // .fstproj del paquete en la caché ("" si no está descargado)
};
PackageStatus lockedPackageStatus(const std::string& projPath, const std::string& name);

// ¿Es válida la restricción de versión? ("^1.2", "~1.2", ">=1.0 <2.0"...)
bool packageVersionValid(const std::string& version, std::string& error);
