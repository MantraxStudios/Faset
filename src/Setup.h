// Faset - 'faset setup': instala los módulos de cada plataforma (compilador de C de Linux,
// toolchain de Windows, SDK/NDK/Java de Android y bibliotecas multimedia).
#pragma once
#include <string>
#include <vector>

// Carpeta de datos del usuario: ~/.local/share/faset (Linux) o %LOCALAPPDATA%\Faset (Windows).
// Ahí van los toolchains y el JDK que descarga 'faset setup'.
std::string fasetDataDir();

// Compilador de C del toolchain llvm-mingw instalado por 'faset setup windows' para la arquitectura
// dada (x86_64, x86, arm64); "" si no está.
std::string managedMingwCompiler(const std::string& arch);

// JDK descargado por 'faset setup android' ("" si no está).
std::string managedJavaHome();

// faset setup [módulos...] [--list] [--yes] [--no-emulator]
int cmdSetup(const std::vector<std::string>& args);
