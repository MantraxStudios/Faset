#include "Lexer.h"

#include <cctype>
#include <cstdlib>
#include <unordered_set>

static const std::unordered_set<std::string> kKeywords = {
    "namespace", "using",    "class",   "struct",   "enum",     "public",    "private",
    "protected", "internal", "static",  "extern",   "unsafe",   "readonly",  "const",
    "new",       "delete",   "sizeof",  "this",     "null",     "true",      "false",
    "if",        "else",     "while",   "do",       "for",      "foreach",   "in",
    "break",     "continue", "return",  "switch",   "case",     "default",   "void",
    "bool",      "char",     "sbyte",   "byte",     "short",    "ushort",    "int",
    "uint",      "long",     "ulong",   "float",    "double",   "string",    "object",
    "ref",       "out",      "params",  "is",       "as",       "virtual",   "override",
    "abstract",  "sealed",   "interface", "operator", "goto",   "throw",     "try",
    "catch",     "finally",  "typeof",  "stackalloc", "fixed",  "import",    "delegate",
    "nullptr",
};

bool isKeyword(const std::string& s) { return kKeywords.count(s) != 0; }

namespace {

// Ordenados de mayor a menor longitud para que gane la coincidencia más larga.
const char* const kPuncts[] = {
    "<<=", ">>=", "...", "::", "->", "++", "--", "&&", "||", "==", "!=", "<=", ">=", "+=", "-=", "*=",
    "/=",  "%=",  "&=",  "|=", "^=", "<<", ">>", "??", "=>", "{",  "}",  "(",  ")",  "[",  "]",
    ";",   ",",   ".",   ":",  "?",  "+",  "-",  "*",  "/",  "%",  "&",  "|",  "^",  "!",  "~",
    "=",   "<",   ">",
};

struct Lex {
    const std::string& s;
    int file;
    size_t i = 0;
    int line = 1, col = 1;
    std::vector<Token> out;

    Lex(const std::string& src, int f) : s(src), file(f) {}

    char peek(size_t o = 0) const { return i + o < s.size() ? s[i + o] : '\0'; }
    char get() {
        char c = s[i++];
        if (c == '\n') {
            line++;
            col = 1;
        } else {
            col++;
        }
        return c;
    }
    SourceLoc here() const { return {file, line, col}; }

    static void appendUtf8(std::string& o, uint32_t cp) {
        if (cp < 0x80) {
            o += (char)cp;
        } else if (cp < 0x800) {
            o += (char)(0xC0 | (cp >> 6));
            o += (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            o += (char)(0xE0 | (cp >> 12));
            o += (char)(0x80 | ((cp >> 6) & 0x3F));
            o += (char)(0x80 | (cp & 0x3F));
        } else {
            o += (char)(0xF0 | (cp >> 18));
            o += (char)(0x80 | ((cp >> 12) & 0x3F));
            o += (char)(0x80 | ((cp >> 6) & 0x3F));
            o += (char)(0x80 | (cp & 0x3F));
        }
    }

    static int hexVal(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    // Lee un punto de código UTF-8 crudo desde el código fuente.
    uint32_t readUtf8() {
        unsigned char c = (unsigned char)get();
        if (c < 0x80) return c;
        int extra = (c >= 0xF0) ? 3 : (c >= 0xE0) ? 2 : 1;
        uint32_t cp = c & (0x3F >> extra);
        for (int k = 0; k < extra && i < s.size(); k++) cp = (cp << 6) | ((unsigned char)get() & 0x3F);
        return cp;
    }

    // Se llama justo después de la barra invertida.
    uint32_t readEscape(SourceLoc loc) {
        char c = get();
        switch (c) {
            case '\'': return '\'';
            case '"': return '"';
            case '\\': return '\\';
            case '0': return 0;
            case 'a': return 7;
            case 'b': return 8;
            case 'f': return 12;
            case 'n': return 10;
            case 'r': return 13;
            case 't': return 9;
            case 'v': return 11;
            case 'x':
            case 'u':
            case 'U': {
                int maxDigits = c == 'x' ? 4 : c == 'u' ? 4 : 8;
                int minDigits = c == 'x' ? 1 : maxDigits;
                uint32_t v = 0;
                int n = 0;
                while (n < maxDigits && hexVal(peek()) >= 0) {
                    v = v * 16 + (uint32_t)hexVal(get());
                    n++;
                }
                if (n < minDigits) diag.error(loc, "secuencia de escape hexadecimal incompleta");
                if (v > 0x10FFFF) diag.error(loc, "punto de código Unicode fuera de rango");
                return v;
            }
            default:
                diag.error(loc, std::string("secuencia de escape no reconocida: \\") + c);
                return '?';
        }
    }

    void push(Token t) { out.push_back(std::move(t)); }

    void lexNumber() {
        Token t;
        t.loc = here();
        std::string digits;
        bool isFloat = false;
        int base = 10;
        if (peek() == '0' && (peek(1) == 'x' || peek(1) == 'X')) {
            get(), get();
            base = 16;
            while (hexVal(peek()) >= 0 || peek() == '_') {
                char c = get();
                if (c != '_') digits += c;
            }
        } else if (peek() == '0' && (peek(1) == 'b' || peek(1) == 'B')) {
            get(), get();
            base = 2;
            while (peek() == '0' || peek() == '1' || peek() == '_') {
                char c = get();
                if (c != '_') digits += c;
            }
        } else {
            while (isdigit((unsigned char)peek()) || peek() == '_') {
                char c = get();
                if (c != '_') digits += c;
            }
            if (peek() == '.' && isdigit((unsigned char)peek(1))) {
                isFloat = true;
                digits += get();
                while (isdigit((unsigned char)peek()) || peek() == '_') {
                    char c = get();
                    if (c != '_') digits += c;
                }
            }
            if (peek() == 'e' || peek() == 'E') {
                size_t save = i;
                int sl = line, sc = col;
                std::string exp(1, get());
                if (peek() == '+' || peek() == '-') exp += get();
                if (isdigit((unsigned char)peek())) {
                    while (isdigit((unsigned char)peek())) exp += get();
                    digits += exp;
                    isFloat = true;
                } else {
                    i = save, line = sl, col = sc;
                }
            }
        }
        if (digits.empty()) {
            diag.error(t.loc, "literal numérico mal formado");
            digits = "0";
        }
        char sfx = peek();
        if (base == 10 && (sfx == 'f' || sfx == 'F' || sfx == 'd' || sfx == 'D')) {
            get();
            isFloat = true;
            t.isFloat32 = (sfx == 'f' || sfx == 'F');
        } else if (sfx == 'm' || sfx == 'M') {
            get();
            diag.error(t.loc, "el tipo 'decimal' no está soportado");
        }
        if (isFloat) {
            t.kind = TokKind::Float;
            t.floatVal = std::strtod(digits.c_str(), nullptr);
        } else {
            t.kind = TokKind::Int;
            uint64_t v = 0;
            bool overflow = false;
            for (char c : digits) {
                uint64_t d = (uint64_t)hexVal(c);
                if (v > (UINT64_MAX - d) / (uint64_t)base) overflow = true;
                v = v * (uint64_t)base + d;
            }
            if (overflow) diag.error(t.loc, "la constante integral es demasiado grande");
            t.intVal = v;
            for (int k = 0; k < 2; k++) {
                char c = peek();
                if ((c == 'u' || c == 'U') && !t.isUnsigned) {
                    get();
                    t.isUnsigned = true;
                } else if ((c == 'l' || c == 'L') && !t.isLong) {
                    get();
                    t.isLong = true;
                }
            }
        }
        if (isalnum((unsigned char)peek()) || peek() == '_') diag.error(here(), "sufijo de literal numérico no válido");
        t.text = digits;
        push(t);
    }

    void run() {
        while (i < s.size()) {
            char c = peek();
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
                get();
                continue;
            }
            if (c == '/' && peek(1) == '/') {
                while (i < s.size() && peek() != '\n') get();
                continue;
            }
            if (c == '/' && peek(1) == '*') {
                SourceLoc loc = here();
                get(), get();
                while (i < s.size() && !(peek() == '*' && peek(1) == '/')) get();
                if (i >= s.size()) diag.error(loc, "comentario de bloque sin cerrar");
                else get(), get();
                continue;
            }
            if (c == '#') {  // #region, #pragma, etc.: se ignoran
                while (i < s.size() && peek() != '\n') get();
                continue;
            }
            if (isdigit((unsigned char)c) || (c == '.' && isdigit((unsigned char)peek(1)))) {
                lexNumber();
                continue;
            }
            if (isalpha((unsigned char)c) || c == '_' || (c == '@' && (isalpha((unsigned char)peek(1)) || peek(1) == '_')) ||
                (unsigned char)c >= 0x80) {
                Token t;
                t.loc = here();
                bool verbatim = false;
                if (c == '@') {
                    get();
                    verbatim = true;
                }
                while (i < s.size() && (isalnum((unsigned char)peek()) || peek() == '_' || (unsigned char)peek() >= 0x80))
                    t.text += get();
                t.kind = (!verbatim && isKeyword(t.text)) ? TokKind::Keyword : TokKind::Ident;
                push(t);
                continue;
            }
            if (c == '$' && (peek(1) == '"' || peek(1) == '@')) {
                diag.error(here(), "las cadenas interpoladas ($\"...\") aún no están soportadas");
                get();
                continue;
            }
            if (c == '"' || (c == '@' && peek(1) == '"')) {
                Token t;
                t.loc = here();
                t.kind = TokKind::String;
                bool verbatim = c == '@';
                if (verbatim) get();
                get();
                bool closed = false;
                while (i < s.size()) {
                    char d = peek();
                    if (verbatim) {
                        if (d == '"') {
                            get();
                            if (peek() == '"') {
                                get();
                                t.text += '"';
                                continue;
                            }
                            closed = true;
                            break;
                        }
                        t.text += get();
                    } else {
                        if (d == '\n') break;
                        if (d == '"') {
                            get();
                            closed = true;
                            break;
                        }
                        if (d == '\\') {
                            SourceLoc el = here();
                            get();
                            appendUtf8(t.text, readEscape(el));
                        } else {
                            t.text += get();
                        }
                    }
                }
                if (!closed) diag.error(t.loc, "literal de cadena sin cerrar");
                push(t);
                continue;
            }
            if (c == '\'') {
                Token t;
                t.loc = here();
                t.kind = TokKind::Char;
                get();
                if (peek() == '\\') {
                    get();
                    t.charVal = readEscape(t.loc);
                } else if (peek() == '\'' || peek() == '\n' || i >= s.size()) {
                    diag.error(t.loc, "literal de carácter vacío");
                } else {
                    t.charVal = readUtf8();
                }
                if (peek() == '\'') get();
                else diag.error(t.loc, "literal de carácter demasiado largo o sin cerrar");
                push(t);
                continue;
            }
            bool matched = false;
            for (const char* p : kPuncts) {
                size_t n = std::char_traits<char>::length(p);
                if (s.compare(i, n, p) == 0) {
                    Token t;
                    t.loc = here();
                    t.kind = TokKind::Punct;
                    t.text = p;
                    for (size_t k = 0; k < n; k++) get();
                    push(t);
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                diag.error(here(), std::string("carácter inesperado '") + c + "'");
                get();
            }
        }
        Token end;
        end.kind = TokKind::End;
        end.loc = here();
        end.text = "<fin de archivo>";
        push(end);
    }
};

}  // namespace

std::vector<Token> tokenize(const std::string& src, int fileId) {
    Lex l(src, fileId);
    l.run();
    return std::move(l.out);
}
