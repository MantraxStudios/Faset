// Faset - 'faset fmt' (ver Formatter.h).
//
// Funciona sobre tokens que conservan los comentarios y el texto exacto de los literales:
//   1. Se separa el código en tokens (los comentarios, las cadenas y las directivas #if son tokens
//      opacos) y se emparejan las llaves (cada rama de #if / #else por separado).
//   2. Se respetan los saltos de línea del autor, salvo las llaves de bloques de varias líneas, que
//      van solas en su línea (estilo Allman): "if (x) {" pasa a "if (x)" + "{", y "} else {" a tres
//      líneas. Un bloque escrito en una sola línea ({ get; set; }, "{ return x; }") se queda así.
//   3. La sangría sale de la profundidad de llaves (4 espacios; dentro de un switch, las etiquetas
//      case van un nivel dentro y sus sentencias otro más). Una línea que continúa una sentencia
//      conserva su sangría relativa a la primera línea de la sentencia (como mínimo +4).
//   4. Espacios dentro de la línea: alrededor de los operadores binarios, tras comas y ';', tras
//      if/for/while..., sin espacios junto a '(' ')' '[' ']' '.'. Donde un símbolo es ambiguo
//      (< > de genéricos, * y & de punteros, ?, :, ++) se respeta lo que había.
//   5. Como mucho una línea en blanco seguida, ninguna tras '{' ni antes de '}', sin espacios al
//      final de línea y un salto de línea al final del archivo.
// Al terminar se vuelve a separar el resultado en tokens: si no coincide token a token con el
// original, no se toca el archivo (red de seguridad).
#include "Formatter.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <set>
#include <sstream>

#include "Lexer.h"

namespace fs = std::filesystem;

namespace {

enum class K { Ident, Keyword, Number, Str, Punct, LineComment, BlockComment, Preproc };

struct Tok {
    K k;
    std::string text;
    int nl = 0;       // saltos de línea antes del token
    std::string ws;   // espacios antes del token en su línea (la sangría si nl > 0)
    int line = 0;     // línea original (desde 0)
    int col = 0;      // columna original (tabuladores = 4)
};

// Los símbolos se separan con la tabla del analizador léxico: un operador nuevo del lenguaje (|>,
// ..) es un solo token también aquí y nunca se parte con un espacio.
size_t punctAt(const std::string& s, size_t i) { return punctLength(s, i); }

int visualWidth(const std::string& ws) {
    int w = 0;
    for (char c : ws) w += c == '\t' ? 4 : 1;
    return w;
}

bool isIdentStart(unsigned char c) { return std::isalpha(c) || c == '_' || c >= 0x80; }
bool isIdentChar(unsigned char c) { return std::isalnum(c) || c == '_' || c >= 0x80; }

// Separa 'src' en tokens. false si hay un literal o comentario sin cerrar.
bool scan(const std::string& s, std::vector<Tok>& out, std::string& error) {
    size_t i = 0, n = s.size();
    int line = 0, nl = 0;
    std::string ws;
    bool lineStart = true;
    auto fail = [&](const std::string& why) {
        error = "line " + std::to_string(line + 1) + ": " + why;
        return false;
    };
    auto push = [&](K k, size_t from, size_t to) {
        Tok t;
        t.k = k;
        t.text = s.substr(from, to - from);
        if (k == K::LineComment || k == K::Preproc) {
            while (!t.text.empty() && std::isspace((unsigned char)t.text.back())) t.text.pop_back();
        }
        t.nl = nl;
        t.ws = ws;
        t.line = line;
        t.col = nl > 0 || out.empty() ? visualWidth(ws) : 0;
        if (nl == 0 && !out.empty()) {
            // columna original: se cuenta desde el último salto de línea
            size_t b = from;
            while (b > 0 && s[b - 1] != '\n') b--;
            t.col = visualWidth(s.substr(b, from - b));
        }
        for (size_t k2 = from; k2 < to; k2++)
            if (s[k2] == '\n') line++;
        out.push_back(t);
        nl = 0;
        ws.clear();
        lineStart = false;
    };
    while (i < n) {
        char c = s[i];
        if (c == '\n') {
            nl++;
            line++;
            ws.clear();
            lineStart = true;
            i++;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '\v') {
            if (c != '\r') ws += c;
            i++;
            continue;
        }
        if (c == '#' && lineStart) {
            size_t e = s.find('\n', i);
            if (e == std::string::npos) e = n;
            push(K::Preproc, i, e);
            i = e;
            continue;
        }
        if (c == '/' && i + 1 < n && s[i + 1] == '/') {
            size_t e = s.find('\n', i);
            if (e == std::string::npos) e = n;
            push(K::LineComment, i, e);
            i = e;
            continue;
        }
        if (c == '/' && i + 1 < n && s[i + 1] == '*') {
            size_t e = s.find("*/", i + 2);
            if (e == std::string::npos) return fail("unterminated block comment");
            push(K::BlockComment, i, e + 2);
            i = e + 2;
            continue;
        }
        // Literales: "..." @"..." $"..." $@"..." @$"..." '...'
        {
            size_t j = i;
            bool verbatim = false, interp = false;
            while (j < n && j - i < 2 && (s[j] == '$' || s[j] == '@')) {
                if (s[j] == '@') verbatim = true;
                else interp = true;
                j++;
            }
            if (j < n && s[j] == '"') {
                size_t start = i;
                j++;
                int depth = 0;
                bool closed = false;
                while (j < n) {
                    char d = s[j];
                    if (interp && depth > 0) {
                        if (d == '"' || d == '\'') {  // literal dentro de un hueco
                            char q = d;
                            j++;
                            while (j < n && s[j] != q && s[j] != '\n') j += s[j] == '\\' ? 2 : 1;
                            j++;
                            continue;
                        }
                        if (d == '{') depth++;
                        else if (d == '}') depth--;
                        j++;
                        continue;
                    }
                    if (interp && d == '{') {
                        if (j + 1 < n && s[j + 1] == '{') j += 2;
                        else depth++, j++;
                        continue;
                    }
                    if (d == '"') {
                        if (verbatim && j + 1 < n && s[j + 1] == '"') {
                            j += 2;
                            continue;
                        }
                        closed = true;
                        j++;
                        break;
                    }
                    if (!verbatim && d == '\\') {
                        j += 2;
                        continue;
                    }
                    if (!verbatim && d == '\n') break;
                    j++;
                }
                if (!closed) return fail("unterminated string");
                push(K::Str, start, j);
                i = j;
                continue;
            }
        }
        if (c == '\'') {
            size_t j = i + 1;
            while (j < n && s[j] != '\'' && s[j] != '\n') j += s[j] == '\\' ? 2 : 1;
            if (j >= n || s[j] != '\'') return fail("unterminated character");
            push(K::Str, i, j + 1);
            i = j + 1;
            continue;
        }
        if (std::isdigit((unsigned char)c) || (c == '.' && i + 1 < n && std::isdigit((unsigned char)s[i + 1]))) {
            size_t j = i;
            bool hex = c == '0' && i + 1 < n && (s[i + 1] == 'x' || s[i + 1] == 'X');
            while (j < n) {
                char d = s[j];
                if (isIdentChar((unsigned char)d)) j++;
                else if (d == '.' && j + 1 < n && std::isdigit((unsigned char)s[j + 1])) j++;
                else if ((d == '+' || d == '-') && !hex && (s[j - 1] == 'e' || s[j - 1] == 'E')) j++;
                else break;
            }
            push(K::Number, i, j);
            i = j;
            continue;
        }
        if (isIdentStart((unsigned char)c) || (c == '@' && i + 1 < n && isIdentStart((unsigned char)s[i + 1]))) {
            size_t j = i + 1;
            while (j < n && isIdentChar((unsigned char)s[j])) j++;
            std::string word = s.substr(i, j - i);
            push(c != '@' && isKeyword(word) ? K::Keyword : K::Ident, i, j);
            i = j;
            continue;
        }
        size_t p = punctAt(s, i);
        if (p == 0) return fail(std::string("unexpected character '") + c + "'");
        push(K::Punct, i, i + p);
        i += p;
    }
    return true;
}

bool isP(const Tok& t, const char* s) { return t.k == K::Punct && t.text == s; }
bool isComment(const Tok& t) { return t.k == K::LineComment || t.k == K::BlockComment; }
bool isWord(const Tok& t) { return t.k == K::Ident || t.k == K::Keyword || t.k == K::Number || t.k == K::Str; }

bool isBinaryOp(const Tok& t) {
    static const std::set<std::string> ops = {"=",  "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "?\?=",
                                              "==", "!=", "<=", ">=", "&&", "||", "??", "=>", "/",  "%",   "|",   "^", "|>"};
    return t.k == K::Punct && ops.count(t.text);
}

bool isControlKeyword(const Tok& t) {
    static const std::set<std::string> kws = {"if",   "for",   "foreach", "while", "switch", "catch", "using", "lock", "fixed",
                                              "return", "throw", "in",     "case",  "else",   "await", "when",  "yield", "is", "as",
                                              "comptime"};
    return (t.k == K::Keyword || t.k == K::Ident) && kws.count(t.text);
}

// Fin de un operando: lo que sigue a '+' o '-' es binario.
bool endsOperand(const Tok& t) {
    if (t.k == K::Number || t.k == K::Str) return true;
    if (t.k == K::Ident) return !isControlKeyword(t);
    if (t.k == K::Keyword) return t.text == "this" || t.text == "base" || t.text == "null" || t.text == "true" || t.text == "false";
    return isP(t, "]");
}

// Palabras que abren un bloque: la '{' de la línea siguiente va a su altura.
bool isHeaderKeyword(const Tok& t) {
    static const std::set<std::string> kws = {"if",   "else",  "for",   "foreach", "while", "do",     "switch",
                                              "using", "lock", "fixed", "try",     "catch", "finally", "memory_unsafe", "unsafe"};
    return t.k == K::Keyword && kws.count(t.text);
}

// Lo que va pegado a un '(' que lo sigue: el nombre de una llamada y unas pocas palabras clave.
bool callLike(const Tok& t) {
    static const std::set<std::string> ctx = {"var", "async", "or", "and", "not", "await", "yield", "when", "where", "from",
                                              "select", "let", "into", "on", "equals", "by", "with", "comptime"};
    static const std::set<std::string> kws = {"this", "base", "typeof", "sizeof", "default", "checked", "unchecked", "new",
                                              "delegate", "stackalloc", "operator"};
    if (t.k == K::Ident) return !ctx.count(t.text);
    if (t.k == K::Keyword) return kws.count(t.text) != 0;
    return false;
}

enum class Sign { None, Binary, Unary, Keep, Tight };

// Para los símbolos ambiguos de una línea: '<' y '>' de genéricos (List<int>, Dictionary<string, List<int>>)
// y ')' que cierra una conversión ((int)-x, (Foo*)p).
struct LineShape {
    std::vector<bool> genericOpen, genericClose, castClose;
    std::vector<bool> headerClose;  // ')' que cierra la cabecera de if/for/while...: "if (p) *p = 1;"
};

LineShape shapeOf(const std::vector<Tok>& toks, const std::vector<size_t>& ix) {
    size_t n = ix.size();
    LineShape sh;
    sh.genericOpen.assign(n, false);
    sh.genericClose.assign(n, false);
    sh.castClose.assign(n, false);
    sh.headerClose.assign(n, false);
    auto T = [&](size_t j) -> const Tok& { return toks[ix[j]]; };
    for (size_t j = 1; j < n; j++) {
        // List<int>, F<T>(...) y delegate*<int, void>
        bool fnPointer = j >= 2 && isP(T(j - 1), "*") && T(j - 2).k == K::Keyword && T(j - 2).text == "delegate";
        if (!isP(T(j), "<") || (T(j - 1).k != K::Ident && !fnPointer)) continue;
        int depth = 1, parens = 0;
        std::vector<size_t> closes;
        bool ok = false;
        for (size_t k = j + 1; k < n; k++) {
            const Tok& t = T(k);
            if (t.k == K::Ident || t.k == K::Keyword || isP(t, ",") || isP(t, ".") || isP(t, "::") || isP(t, "?") ||
                isP(t, "[") || isP(t, "]") || isP(t, "*")) {
                continue;
            }
            if (isP(t, "(")) {
                parens++;
                continue;
            }
            if (isP(t, ")")) {
                if (--parens < 0) break;
                continue;
            }
            if (isP(t, "<")) {
                depth++;
                continue;
            }
            if (isP(t, ">") || isP(t, ">>")) {
                depth -= t.text.size() == 2 ? 2 : 1;
                closes.push_back(k);
                if (depth <= 0) {
                    ok = depth == 0 && parens == 0;
                    break;
                }
                continue;
            }
            break;
        }
        if (!ok) continue;
        sh.genericOpen[j] = true;
        for (size_t k = j + 1; k <= closes.back(); k++)
            if (isP(T(k), "<")) sh.genericOpen[k] = true;
        for (size_t k : closes) sh.genericClose[k] = true;
    }
    // (tipo) o (Tipo*): conversión si dentro solo hay un nombre de tipo predefinido o un puntero.
    std::vector<size_t> open;
    for (size_t j = 0; j < n; j++) {
        if (isP(T(j), "(")) open.push_back(j);
        else if (isP(T(j), ")") && !open.empty()) {
            size_t o = open.back();
            open.pop_back();
            sh.headerClose[j] = o > 0 && isHeaderKeyword(T(o - 1));
            if (j - o < 2) continue;
            bool keywordType = j - o == 2 && T(o + 1).k == K::Keyword && T(o + 1).text != "this" && T(o + 1).text != "null" &&
                               T(o + 1).text != "true" && T(o + 1).text != "false" && T(o + 1).text != "base";
            bool pointer = isP(T(j - 1), "*");
            bool names = true;
            for (size_t k = o + 1; k < j; k++) {
                const Tok& t = T(k);
                names &= t.k == K::Ident || t.k == K::Keyword || isP(t, ".") || isP(t, "*") || sh.genericOpen[k] || sh.genericClose[k] ||
                         isP(t, ",");
            }
            sh.castClose[j] = keywordType || (pointer && names);
        }
    }
    return sh;
}

struct Segment {
    std::vector<size_t> toks;  // índices en el vector de tokens
    int origIndent = 0;
    int blankBefore = 0;
};

struct Block {
    int braceIndent = 0;   // sangría de la línea del '{'
    int indent = 0;        // sangría de las sentencias del bloque
    bool isSwitch = false;
    int parens = 0;        // paréntesis y corchetes abiertos dentro del bloque
    int stmtIndent = 0;    // sangría nueva de la primera línea de la sentencia actual
    int stmtOrig = 0;      // sangría original de esa línea
    std::string stmtFirst; // primer token de la sentencia actual (para detectar 'switch')
    int headerIndent = -1; // última línea de la sentencia que empieza con if/for/while... (-1 = ninguna)
    bool afterLabel = false;  // la línea anterior era una etiqueta 'case X:'
};

struct State {
    std::vector<Block> blocks;
    bool atStart = true;
};

}  // namespace

bool formatSource(const std::string& src, std::string& out, std::string& error) {
    std::vector<Tok> toks;
    if (!scan(src, toks, error)) return false;
    bool crlf = src.find("\r\n") != std::string::npos && src.find("\r\n") == src.find('\n') - 1;

    // ---- emparejar llaves (cada rama de #if por separado)
    std::vector<int> match(toks.size(), -1);
    {
        std::vector<size_t> stack;
        std::vector<std::vector<size_t>> saved;
        for (size_t i = 0; i < toks.size(); i++) {
            const Tok& t = toks[i];
            if (t.k == K::Preproc) {
                std::string d = t.text.substr(1);
                d.erase(0, d.find_first_not_of(" \t"));
                if (d.rfind("if", 0) == 0 && (d.size() == 2 || !isIdentChar((unsigned char)d[2]))) saved.push_back(stack);
                else if ((d.rfind("else", 0) == 0 || d.rfind("elif", 0) == 0) && !saved.empty()) stack = saved.back();
                else if (d.rfind("endif", 0) == 0 && !saved.empty()) saved.pop_back();
                continue;
            }
            if (isP(t, "{")) stack.push_back(i);
            else if (isP(t, "}")) {
                if (stack.empty()) {
                    error = "line " + std::to_string(t.line + 1) + ": '}' without '{'";
                    return false;
                }
                match[i] = (int)stack.back();
                match[stack.back()] = (int)i;
                stack.pop_back();
            }
        }
        if (!stack.empty()) {
            error = "line " + std::to_string(toks[stack.back()].line + 1) + ": unterminated '{'";
            return false;
        }
    }
    auto local = [&](size_t i) {  // llave cuya pareja está en la misma línea original
        return match[i] >= 0 && toks[(size_t)match[i]].line == toks[i].line;
    };

    // ---- líneas originales -> segmentos (las llaves de bloques de varias líneas van solas)
    std::vector<Segment> segs;
    for (size_t i = 0; i < toks.size();) {
        size_t e = i + 1;
        while (e < toks.size() && toks[e].nl == 0) e++;
        Segment cur;
        cur.origIndent = visualWidth(toks[i].ws);
        cur.blankBefore = std::max(0, toks[i].nl - 1);
        if (i == 0) cur.blankBefore = 0;
        auto flush = [&](size_t next) {
            if (!cur.toks.empty()) segs.push_back(cur);
            cur = Segment();
            if (next < e) cur.origIndent = toks[next].col;
        };
        for (size_t k = i; k < e; k++) {
            const Tok& t = toks[k];
            bool open = isP(t, "{") && !local(k), close = isP(t, "}") && !local(k);
            if ((open || close) && !cur.toks.empty()) flush(k);
            cur.toks.push_back(k);
            if (open || close) {
                bool restComments = true;
                for (size_t r = k + 1; r < e; r++) restComments &= isComment(toks[r]);
                if (k + 1 < e && !restComments) {
                    const Tok& nx = toks[k + 1];
                    bool attach = close && (isP(nx, ")") || isP(nx, ";") || isP(nx, ",") || isP(nx, "]") || isP(nx, ".") || isP(nx, "?"));
                    // do { ... } while (x);  se queda en la línea de la llave
                    if (close && nx.k == K::Keyword && nx.text == "while") {
                        size_t lastCode = e - 1;
                        while (lastCode > k && isComment(toks[lastCode])) lastCode--;
                        attach = isP(toks[lastCode], ";");
                    }
                    if (!attach) flush(k + 1);
                }
            }
        }
        if (!cur.toks.empty()) segs.push_back(cur);
        i = e;
    }

    // ---- sangría y espacios
    State st;
    Block root;
    st.blocks.push_back(root);
    std::vector<State> ppStack;
    std::vector<std::string> lines;
    std::vector<int> blanks;  // líneas en blanco antes de cada línea de salida
    const Tok* prevLast = nullptr;  // último token de la línea anterior
    for (const Segment& sg : segs) {
        const Tok& f = toks[sg.toks[0]];
        int blank = std::min(1, sg.blankBefore);
        if (prevLast && isP(*prevLast, "{") ) blank = 0;
        if (isP(f, "}")) blank = 0;
        if (lines.empty()) blank = 0;

        if (f.k == K::Preproc) {
            std::string d = f.text.substr(1);
            d.erase(0, d.find_first_not_of(" \t"));
            if (d.rfind("if", 0) == 0 && (d.size() == 2 || !isIdentChar((unsigned char)d[2]))) ppStack.push_back(st);
            else if ((d.rfind("else", 0) == 0 || d.rfind("elif", 0) == 0) && !ppStack.empty()) st = ppStack.back();
            else if (d.rfind("endif", 0) == 0 && !ppStack.empty()) ppStack.pop_back();
            int ind = 0;
            if (d.rfind("region", 0) == 0 || d.rfind("endregion", 0) == 0) ind = st.blocks.back().indent;
            lines.push_back(std::string(ind, ' ') + f.text);
            blanks.push_back(blank);
            prevLast = &f;
            continue;
        }

        bool allComments = true;
        for (size_t k : sg.toks) allComments &= isComment(toks[k]);
        Block& top = st.blocks.back();
        bool isLabel = f.text == "case" || (f.text == "default" && sg.toks.size() > 1 && isP(toks[sg.toks[1]], ":")) ||
                       (sg.toks.size() == 2 && (f.k == K::Ident || f.k == K::Keyword) && isP(toks[sg.toks[1]], ":"));
        int indent;
        bool opensBlock = isP(f, "{") && !local(sg.toks[0]);
        bool accessLabel = sg.toks.size() == 2 && isP(toks[sg.toks[1]], ":") && f.k == K::Keyword &&
                           (f.text == "public" || f.text == "private" || f.text == "protected" || f.text == "internal");
        if ((isP(f, "}") && !local(sg.toks[0])) || accessLabel) {
            indent = top.braceIndent;
        } else if (opensBlock && top.afterLabel) {
            indent = top.indent;  // case X: + { en la línea siguiente: la llave a la altura de 'case'
        } else if (opensBlock && !st.atStart) {
            indent = top.headerIndent >= 0 ? top.headerIndent : top.stmtIndent;
        } else if (st.atStart) {
            indent = top.indent + (top.isSwitch && !isLabel ? 4 : 0);
            if (!allComments) {
                top.stmtIndent = indent;
                top.stmtOrig = sg.origIndent;
                top.stmtFirst = f.text;
                top.headerIndent = isHeaderKeyword(f) ? indent : -1;
            }
        } else {
            indent = std::max(top.stmtIndent + 4, sg.origIndent + (top.stmtIndent - top.stmtOrig));
            if (isHeaderKeyword(f)) top.headerIndent = indent;
        }
        if (!allComments) top.afterLabel = isLabel && top.isSwitch;

        // Texto de la línea con los espacios normalizados.
        std::string text;
        std::vector<Sign> sign(sg.toks.size(), Sign::None);
        LineShape shape = shapeOf(toks, sg.toks);
        for (size_t j = 0; j < sg.toks.size(); j++) {
            const Tok& b = toks[sg.toks[j]];
            if (j == 0) {
                text = b.text;
            } else {
                const Tok& a = toks[sg.toks[j - 1]];
                bool orig = !b.ws.empty();
                std::string sep;
                bool decided = true;
                if (b.k == K::LineComment) sep = orig ? std::string((size_t)visualWidth(b.ws), ' ') : " ";
                else if (a.k == K::BlockComment || b.k == K::BlockComment) sep = orig ? " " : "";
                else if (isP(a, ";") && isP(b, ";")) sep = orig ? " " : "";  // for (int i = 0; ; i++)
                else if (isP(b, ",") || isP(b, ";")) sep = "";
                else if (isP(a, ",")) sep = isP(b, ")") || isP(b, "]") || isP(b, ">") || isP(b, ",") ? (orig ? " " : "") : " ";
                else if (isP(a, ";")) sep = isP(b, ")") ? "" : " ";
                else if (isP(b, ")") || isP(b, "]")) sep = "";
                else if (isP(a, "(") || isP(a, "[")) sep = "";
                else if (isP(b, ".") && a.k == K::Number) sep = orig ? " " : "";
                else if (isP(a, ".") || isP(b, ".") || isP(a, "::") || isP(b, "::") || isP(a, "->") || isP(b, "->")) sep = "";
                else if (isP(a, "{") || isP(b, "}")) sep = " ";
                else if (isP(a, "}")) sep = isP(b, ")") || isP(b, ";") || isP(b, ",") || isP(b, "]") || isP(b, ".") || isP(b, "?") ? "" : " ";
                else if (isP(b, "{")) sep = " ";
                else if (j >= 2 && toks[sg.toks[j - 2]].k == K::Keyword && toks[sg.toks[j - 2]].text == "operator") sep = orig ? " " : "";
                else if (isBinaryOp(a) || isBinaryOp(b)) sep = " ";
                else if (isP(b, "(")) {
                    if (isControlKeyword(a)) sep = " ";
                    else if (callLike(a)) sep = "";  // Llamada: F(x), this(x), typeof(T)
                    else decided = false;            // var (a, b), async (), public (int, int) X...
                } else if (isP(b, "[") && (a.k == K::Ident || isP(a, ")") || isP(a, "]") || a.k == K::Str)) sep = "";
                else decided = false;
                if (!decided) {
                    bool closesExpr = isP(a, ")") && !shape.castClose[j - 1] && !shape.headerClose[j - 1];  // (a + b) - c, f(x) * 2
                    if (isP(b, "<") || isP(b, ">") || isP(b, "<<") || isP(b, ">>")) {
                        sign[j] = shape.genericOpen[j] || shape.genericClose[j] ? Sign::Tight : Sign::Binary;
                        sep = sign[j] == Sign::Tight ? "" : " ";
                    } else if (isP(b, "*") || isP(b, "&")) {
                        // a * b tras un operador binario o 'return' ("x = a*b", "=> a*b") no puede ser un puntero
                        const Tok* before = j >= 2 ? &toks[sg.toks[j - 2]] : nullptr;
                        bool afterOp = before && (a.k == K::Ident || a.k == K::Number) &&
                                       (isBinaryOp(*before) || sign[j - 2] == Sign::Binary || (before->k == K::Keyword && before->text == "return"));
                        bool binary = a.k == K::Number || isP(a, "]") || closesExpr || afterOp ||
                                      (j + 1 < sg.toks.size() && toks[sg.toks[j + 1]].k == K::Number);
                        sign[j] = binary ? Sign::Binary : Sign::Keep;
                        sep = binary ? " " : (orig ? " " : "");
                    } else if (isP(b, "+") || isP(b, "-")) {
                        // r? + 1: el '?' pegado a su operando (propagación de errores) termina un operando
                        bool postfixQ = isP(a, "?") && a.nl == 0 && a.ws.empty() && orig;
                        sign[j] = endsOperand(a) || closesExpr || postfixQ ? Sign::Binary
                                  : isP(a, ")") || isP(a, ">") || isP(a, "++") || isP(a, "--") ? Sign::Keep : Sign::Unary;
                        if (isP(a, ">") && sign[j - 1] == Sign::Binary) sign[j] = Sign::Unary;
                        sep = sign[j] == Sign::Binary ? " " : sign[j] == Sign::Unary && (isWord(a) || sign[j - 1] == Sign::Binary) ? " " : (orig ? " " : "");
                    } else if (sign[j - 1] != Sign::None) {
                        Sign sa = sign[j - 1];
                        sep = sa == Sign::Binary ? " " : sa == Sign::Unary || (sa == Sign::Tight && shape.genericOpen[j - 1]) ? "" : (orig ? " " : "");
                    } else if (isP(a, "!") || isP(a, "~")) {
                        sep = "";
                    } else if (isWord(a) && isWord(b)) {
                        sep = " ";
                    } else {
                        sep = orig ? " " : "";
                    }
                }
                // Que dos símbolos juntos no formen otro ("- -x" no es "--x"; "/ /" no es un comentario).
                if (sep.empty() && a.k == K::Punct && b.k == K::Punct) {
                    std::string joined = a.text + b.text;
                    if (punctAt(joined, 0) != a.text.size() || (a.text.back() == '/' && (b.text[0] == '/' || b.text[0] == '*')))
                        sep = " ";
                }
                if (sep.empty() && isWord(a) && isWord(b)) sep = " ";
                text += sep + b.text;
            }
        }
        lines.push_back(std::string((size_t)std::max(0, indent), ' ') + text);
        blanks.push_back(blank);

        // Estado para la línea siguiente.
        const Tok* last = nullptr;
        for (size_t j = 0; j < sg.toks.size(); j++) {
            size_t k = sg.toks[j];
            const Tok& t = toks[k];
            if (isComment(t)) continue;
            last = &t;
            Block& b = st.blocks.back();
            if (isP(t, "(") || isP(t, "[")) b.parens++;
            else if (isP(t, ")") || isP(t, "]")) b.parens = std::max(0, b.parens - 1);
            else if (isP(t, "{")) {
                Block nb;
                nb.braceIndent = j == 0 ? indent : b.headerIndent >= 0 ? b.headerIndent : b.stmtIndent;
                nb.indent = nb.braceIndent + 4;
                nb.isSwitch = !local(k) && b.stmtFirst == "switch";
                nb.stmtIndent = nb.indent;
                nb.stmtOrig = nb.indent;
                st.blocks.push_back(nb);
            } else if (isP(t, "}")) {
                if (st.blocks.size() > 1) st.blocks.pop_back();
            }
        }
        if (last) {
            Block& b = st.blocks.back();
            bool attrLine = st.atStart && isP(f, "[");
            if (b.parens > 0) st.atStart = false;
            else if (isP(*last, ";") || isP(*last, "{") || isP(*last, "}") || isP(*last, ",")) st.atStart = true;
            else if (isP(*last, ":") && isLabel) st.atStart = true;
            else if (isP(*last, "]") && attrLine) st.atStart = true;
            else st.atStart = false;
            prevLast = last;
        } else if (!sg.toks.empty()) {
            prevLast = &toks[sg.toks.back()];
        }
    }

    std::string nlText = crlf ? "\r\n" : "\n";
    std::string result;
    for (size_t i = 0; i < lines.size(); i++) {
        if (blanks[i]) result += nlText;
        std::string l = lines[i];
        while (!l.empty() && (l.back() == ' ' || l.back() == '\t')) l.pop_back();
        result += l + nlText;
    }

    // ---- red de seguridad: los mismos tokens, en el mismo orden
    std::vector<Tok> again;
    std::string err2;
    if (!scan(result, again, err2) || again.size() != toks.size()) {
        error = "internal formatter error (tokens do not match); the file is left unchanged";
        return false;
    }
    for (size_t i = 0; i < toks.size(); i++)
        if (again[i].k != toks[i].k || again[i].text != toks[i].text) {
            error = "internal formatter error at line " + std::to_string(toks[i].line + 1) + "; the file is left unchanged";
            return false;
        }
    out = result;
    return true;
}

// ------------------------------------------------------------------ faset fmt

namespace {

bool readFile(const fs::path& p, std::string& out) {
    std::ifstream f(p, std::ios::binary);
    if (!f) return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

void collect(const fs::path& p, std::vector<fs::path>& out) {
    std::error_code ec;
    if (!fs::is_directory(p, ec)) {
        out.push_back(p);
        return;
    }
    auto it = fs::recursive_directory_iterator(p, fs::directory_options::skip_permission_denied, ec);
    for (; it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (ec) break;
        std::string name = it->path().filename().string();
        if (it->is_directory(ec)) {
            if (name == "bin" || name == "obj" || name == "node_modules" || (!name.empty() && name[0] == '.')) it.disable_recursion_pending();
            continue;
        }
        if (it->path().extension() == ".fst") out.push_back(it->path());
    }
}

}  // namespace

int cmdFormat(const std::vector<std::string>& args) {
    bool check = false, useStdin = false, quiet = false;
    std::vector<std::string> inputs;
    for (const std::string& a : args) {
        if (a == "--check") check = true;
        else if (a == "--stdin" || a == "-") useStdin = true;
        else if (a == "-q" || a == "--quiet") quiet = true;
        else if (a == "-h" || a == "--help") {
            std::printf(
                "Usage: faset fmt [files|folders] [--check] [--stdin]\n\n"
                "Format .fst files in Faset style (like C#): braces on their own line, 4-space\n"
                "indentation, spaces around operators and after commas. With no files, formats\n"
                "the current folder (excluding bin/, obj/ and hidden folders). Comments and strings are left untouched.\n\n"
                "  --check   writes nothing; exits with code 1 if any file needs formatting (for CI)\n"
                "  --stdin   read code from standard input and write the result to standard output\n");
            return 0;
        } else if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr, "faset: error: unknown option '%s' (use 'faset fmt --help')\n", a.c_str());
            return 2;
        } else inputs.push_back(a);
    }
    if (useStdin) {
        std::string src((std::istreambuf_iterator<char>(std::cin)), std::istreambuf_iterator<char>()), out, err;
        if (!formatSource(src, out, err)) {
            std::fprintf(stderr, "<stdin>: %s\n", err.c_str());
            return 2;
        }
        if (check) return out == src ? 0 : 1;
        std::fwrite(out.data(), 1, out.size(), stdout);
        return 0;
    }
    std::vector<fs::path> files;
    if (inputs.empty()) collect(fs::current_path(), files);
    for (const std::string& in : inputs) {
        std::error_code ec;
        if (!fs::exists(in, ec)) {
            std::fprintf(stderr, "faset: error: '%s' does not exist\n", in.c_str());
            return 2;
        }
        collect(in, files);
    }
    std::sort(files.begin(), files.end());
    int changed = 0, failed = 0;
    for (const fs::path& f : files) {
        std::string src, out, err;
        if (!readFile(f, src)) {
            std::fprintf(stderr, "faset: error: cannot read '%s'\n", f.string().c_str());
            failed++;
            continue;
        }
        if (!formatSource(src, out, err)) {
            std::fprintf(stderr, "%s: %s\n", f.string().c_str(), err.c_str());
            failed++;
            continue;
        }
        if (out == src) continue;
        changed++;
        if (check) {
            if (!quiet) std::printf("Needs formatting: %s\n", f.string().c_str());
            continue;
        }
        std::ofstream o(f, std::ios::binary);
        if (!(o << out)) {
            std::fprintf(stderr, "faset: error: cannot write '%s'\n", f.string().c_str());
            failed++;
            continue;
        }
        if (!quiet) std::printf("Formatted: %s\n", f.string().c_str());
    }
    if (!quiet) {
        if (check)
            std::printf("%zu file(s) checked, %d need(s) formatting.\n", files.size(), changed);
        else
            std::printf("%zu file(s), %d formatted.\n", files.size(), changed);
    }
    if (failed) return 2;
    return check && changed ? 1 : 0;
}

// ------------------------------------------------------------------ servidor de lenguaje

namespace {

int utf16Length(const std::string& s) {
    int n = 0;
    for (size_t i = 0; i < s.size(); i++) {
        unsigned char c = (unsigned char)s[i];
        if ((c & 0xC0) == 0x80) continue;
        n += c >= 0xF0 ? 2 : 1;
    }
    return n;
}

std::vector<std::string> splitLines(const std::string& s) {
    std::vector<std::string> out;
    size_t start = 0;
    for (size_t k = s.find('\n'); k != std::string::npos; k = s.find('\n', start)) {
        out.push_back(s.substr(start, k - start));
        start = k + 1;
    }
    out.push_back(s.substr(start));
    return out;
}

Json position(int line, int character) {
    Json p = Json::object();
    p["line"] = line;
    p["character"] = character;
    return p;
}

}  // namespace

Json formattingEdits(const std::string& text) {
    Json edits = Json::array();
    std::string out, err;
    if (!formatSource(text, out, err) || out == text) return edits;
    // Un solo cambio que cubre de la primera a la última línea distinta (el cursor no salta).
    std::vector<std::string> a = splitLines(text), b = splitLines(out);
    size_t p = 0;
    while (p + 1 < a.size() && p + 1 < b.size() && a[p] == b[p]) p++;
    size_t s = 0;
    while (s + 1 < a.size() - p && s + 1 < b.size() - p && a[a.size() - 1 - s] == b[b.size() - 1 - s]) s++;
    Json range = Json::object();
    range["start"] = position((int)p, 0);
    std::string newText;
    if (s > 0) {
        range["end"] = position((int)(a.size() - s), 0);
        for (size_t i = p; i < b.size() - s; i++) newText += b[i] + "\n";
    } else {
        range["end"] = position((int)a.size() - 1, utf16Length(a.back()));
        for (size_t i = p; i < b.size(); i++) newText += (i > p ? "\n" : "") + b[i];
    }
    Json e = Json::object();
    e["range"] = std::move(range);
    e["newText"] = newText;
    edits.push(std::move(e));
    return edits;
}
