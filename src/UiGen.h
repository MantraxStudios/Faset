// Faset - interfaces .fstui: convierte el XML del diseñador en una clase 'partial' de Faset.
#pragma once
#include <string>

// Genera el código Faset de una interfaz .fstui. Cada control se emite en la misma línea
// que su elemento en el XML, así los errores (p. ej. un manejador que no existe) señalan
// la línea correcta del archivo .fstui. Los errores del XML se informan en 'fileId'.
std::string generateUiSource(const std::string& xml, int fileId);
