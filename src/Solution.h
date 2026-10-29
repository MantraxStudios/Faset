// Faset - soluciones .fstp: varios proyectos .fstproj que se abren y compilan juntos
// (como las .sln de Visual Studio). Las rutas son relativas a la carpeta del .fstp.
//
// <Solution Name="MiJuego" Configuration="Debug" TargetPlatform="native">
//   <Project Path="Motor/Motor.fstproj" />
//   <Project Path="Juego/Juego.fstproj" Startup="true" />
//   <Folder Name="Herramientas">                 carpeta de solución (solo organiza el árbol)
//     <Project Path="Tools/Editor/Editor.fstproj" />
//   </Folder>
// </Solution>
//
// Configuration y TargetPlatform son opcionales: valores por defecto para todos los proyectos
// cuando no se indican -c / --target en la línea de órdenes.
#pragma once
#include <string>
#include <vector>

struct SolutionProject {
    std::string path;    // ruta absoluta del .fstproj
    std::string rel;     // ruta tal como está en el .fstp (relativa, con '/')
    std::string folder;  // carpeta de solución ("" = raíz; anidadas con '/': "Herramientas/Editores")
    bool startup = false;
};

struct Solution {
    std::string path;  // ruta absoluta del .fstp
    std::string dir;   // carpeta de la solución
    std::string name;
    std::string configuration, targetPlatform;  // por defecto ("" = los de cada proyecto)
    std::vector<SolutionProject> projects;
    std::vector<std::string> folders;  // todas las carpetas de solución, en orden ("A", "A/B")

    int startup() const;                                 // proyecto marcado con Startup="true" (-1 si no hay)
    int find(const std::string& projectPath) const;      // por ruta (absoluta o relativa a la solución) o nombre
};

bool loadSolution(const std::string& path, Solution& out, std::string& error);
std::string solutionXml(const Solution& s);
bool saveSolution(const Solution& s, std::string& error);

// Orden de compilación: cada proyecto después de los proyectos de la solución que referencia
// (<ProjectReference>). Falla si hay una referencia circular. 'deps' (opcional) recibe los proyectos
// de la solución de los que depende cada uno.
bool solutionBuildOrder(const Solution& s, std::vector<int>& order, std::string& error,
                        std::vector<std::vector<int>>* deps = nullptr);

// Proyecto de inicio efectivo: el marcado o, si no hay, el primer ejecutable (Exe/WinExe).
int solutionStartupProject(const Solution& s);

// El único .fstp de una carpeta ("" si no hay ninguno o hay varios).
std::string findSolutionIn(const std::string& dir);

// La solución más cercana subiendo desde la carpeta de 'file' ("" si no hay).
std::string findSolutionFor(const std::string& file);

// El .fstproj que compila 'file': el más cercano si lo incluye y no hay dudas; si no, el proyecto
// de la solución ('solutionHint' o la más cercana) cuyos archivos lo contienen.
std::string projectForFile(const std::string& file, const std::string& solutionHint = "");

// Ruta relativa con '/'de 'path' respecto a 'base'.
std::string relativeSlash(const std::string& path, const std::string& base);

// Órdenes de soluciones de la línea de órdenes: 'faset sln ...', 'faset new sln', 'faset new X --solution'
// y build/run/check/clean con un .fstp (o en una carpeta con un .fstp y sin .fstproj).
// Devuelve true si la orden era de soluciones y deja el código de salida en 'code'.
bool solutionCommand(const std::vector<std::string>& args, const std::string& argv0, int& code);
