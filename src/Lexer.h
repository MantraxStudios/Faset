// Faset - analizador léxico.
#pragma once
#include <set>

#include "Common.h"

// InterpBegin ... InterpEnd: cadena interpolada $"...". Dentro: String (texto literal) y huecos
// InterpHole (text = formato, intVal = alineación si isLong) + tokens de la expresión + InterpHoleEnd.
enum class TokKind { End, Ident, Keyword, Punct, Int, Float, Char, String, InterpBegin, InterpHole, InterpHoleEnd, InterpEnd };

struct Token {
    TokKind kind = TokKind::End;
    std::string text;  // lexema; para cadenas, el valor ya decodificado (UTF-8)
    SourceLoc loc;
    uint64_t intVal = 0;
    double floatVal = 0;
    bool isUnsigned = false, isLong = false, isFloat32 = false;
    uint32_t charVal = 0;
};

std::vector<Token> tokenize(const std::string& src, int fileId);

// Símbolos de compilación condicional (#if WINDOWS ... #endif): LINUX, WINDOWS, ANDROID,
// MACOS, DEBUG, RELEASE, FASET.
void setDefines(const std::set<std::string>& defines);
bool isKeyword(const std::string& s);
// Longitud del símbolo (operador o puntuación) que empieza en s[i]; 0 si no hay ninguno. El
// formateador (Formatter.cpp) separa los símbolos con la misma tabla que el compilador.
size_t punctLength(const std::string& s, size_t i);
