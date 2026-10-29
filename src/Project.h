// Faset - proyectos .fstproj (formato XML al estilo de los .csproj de .NET SDK).
//
// <Project>
//   <PropertyGroup>
//     <OutputType>Exe</OutputType>              Exe | WinExe | Library
//     <AssemblyName>MiApp</AssemblyName>
//     <TargetPlatform>native</TargetPlatform>   native | linux | windows | android
//     <TargetArch>x86_64</TargetArch>           x86_64 | x86 | arm64 | armv7
//     <Configuration>Debug</Configuration>      Debug | Release
//     <AndroidPackage>com.faset.miapp</AndroidPackage>   Android: ver README
//   </PropertyGroup>
//   <ItemGroup>
//     <Compile Remove="pruebas/**" />
//     <NativeLibrary Include="user32" />
//     <ProjectReference Include="../Utilidades/Utilidades.fstproj" />
//   </ItemGroup>
// </Project>
//
// Como en los proyectos SDK de .NET, todos los .fst de la carpeta del proyecto
// (y subcarpetas, salvo bin/, obj/ y otros proyectos) se compilan automáticamente.
#pragma once
#include <map>
#include <string>
#include <vector>

struct Project {
    std::string path;  // ruta del .fstproj
    std::string dir;   // carpeta del proyecto
    std::map<std::string, std::string> props;
    std::vector<std::string> compileInclude, compileRemove;
    std::vector<std::string> nativeLibs, libPaths;
    std::vector<std::pair<std::string, std::string>> platformLibs;  // <NativeLibrary Include="x" Platform="windows" />
    std::vector<std::string> references;  // rutas a otros .fstproj
    std::vector<std::string> androidPermissions;  // <AndroidPermission Include="INTERNET" />

    std::string prop(const std::string& name, const std::string& def = "") const;
    bool boolProp(const std::string& name, bool def) const;
};

// Carga y valida un .fstproj; devuelve false y rellena 'error' si falla.
bool loadProject(const std::string& path, Project& out, std::string& error);

// Archivos .fst del proyecto (aplicando Include/Remove).
std::vector<std::string> projectSources(const Project& p);

// Busca el .fstproj más cercano subiendo desde la carpeta de 'file' ("" si no hay).
std::string findProjectFor(const std::string& file);

// Archivos de un proyecto y de todos los que referencia (recursivo).
bool projectTreeSources(const std::string& projPath, std::vector<std::string>& files, std::string& error);

// Contenido de un proyecto nuevo.
std::string newProjectXml(const std::string& name, const std::string& outputType);
