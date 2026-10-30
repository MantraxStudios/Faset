// Faset - 'faset fmt': formateador de código .fst con el estilo de C# (llaves en su propia línea,
// sangría de 4 espacios, espacios alrededor de los operadores y tras las comas).
//
// Solo cambia espacios en blanco y saltos de línea: los comentarios, las cadenas (también las
// interpoladas y las @"..." de varias líneas) y el orden de los tokens se conservan tal cual. Antes
// de devolver el resultado se comprueba que la secuencia de tokens es idéntica a la original.
// Volver a formatear un resultado no lo cambia (idempotente).
#pragma once
#include <string>
#include <vector>

#include "Json.h"

// Formatea 'src'. Devuelve false (con 'error' = "línea N: motivo") si el archivo no se puede
// formatear con seguridad (literal sin cerrar, llaves desparejadas...); 'out' queda sin tocar.
bool formatSource(const std::string& src, std::string& out, std::string& error);

// textDocument/formatting: los cambios (TextEdit[]) que dejan 'text' formateado ([] si ya lo está
// o no se puede formatear).
Json formattingEdits(const std::string& text);

// faset fmt [archivos|carpetas] [--check] [--stdin]
int cmdFormat(const std::vector<std::string>& args);
