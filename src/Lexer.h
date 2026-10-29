// Faset - analizador léxico.
#pragma once
#include <set>

#include "Common.h"

enum class TokKind { End, Ident, Keyword, Punct, Int, Float, Char, String };

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
