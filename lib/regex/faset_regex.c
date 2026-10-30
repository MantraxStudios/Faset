/* =============================================================================
 *  Faset - std.regex: motor de expresiones regulares (sintaxis de .NET, texto UTF-8).
 *
 *  El compilador añade este archivo a todo programa que use 'using std.regex;'.
 *
 *  El patrón se analiza a un árbol y se compila a un programa de instrucciones (como en
 *  RE2 / el artículo "Regular Expression Matching: the Virtual Machine Approach" de Russ
 *  Cox). Hay dos motores para el mismo programa:
 *
 *    Pike VM       tiempo lineal O(texto x patrón): simula todos los caminos a la vez con
 *                  prioridades, así que da el mismo resultado que el retroceso (la primera
 *                  alternativa, cuantificadores voraces y perezosos) sin explotar nunca.
 *                  Se usa siempre que el patrón no tenga referencias hacia atrás (\1, \k<n>),
 *                  búsquedas alrededor ((?=...) (?!...) (?<=...) (?<!...)) ni grupos atómicos.
 *    Retroceso     con pila explícita (sin recursión de C) para los patrones con esas
 *                  construcciones. Tiene un presupuesto de pasos y un tiempo límite opcional:
 *                  si se agotan, la búsqueda devuelve -1 y Faset lanza
 *                  RegexMatchTimeoutException en lugar de colgarse (retroceso catastrófico).
 *
 *  Las posiciones son índices de bytes en el texto UTF-8 (como string.Substring en Faset);
 *  la coincidencia se hace por puntos de código: '.' consume un carácter completo. Un byte
 *  que no es UTF-8 válido se trata como un carácter propio que no coincide con ninguno del
 *  patrón (solo con '.', [^...] y \W / \S / \D).
 *
 *  Memoria: el programa compilado es de malloc (faset_regex_free); los textos que se
 *  devuelven a Faset (mensajes, nombres) se copian en memoria del recolector.
 * ============================================================================= */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#if defined(_WIN32)
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <windows.h>
#else
#  include <time.h>
#endif

typedef struct { const uint8_t* ptr; int64_t len; } rx_str;

void* faset_alloc_atomic(int64_t size);

static rx_str rx_copy(const char* p, int64_t n) {
    rx_str s;
    uint8_t* d = (uint8_t*)faset_alloc_atomic(n + 1);
    if (n > 0) memcpy(d, p, (size_t)n);
    d[n] = 0;
    s.ptr = d;
    s.len = n;
    return s;
}

/* Opciones (los mismos valores que RegexOptions de .NET). */
enum {
    RX_ICASE = 1, RX_MULTILINE = 2, RX_EXPLICIT = 4, RX_SINGLELINE = 16, RX_IGNORE_WS = 32,
    RX_RIGHT_TO_LEFT = 64, RX_ECMA = 256, RX_NONBACKTRACKING = 1024
};

/* ---------------------------------------------------------------- Unicode (aproximado) */

/* Minúscula simple: ASCII, Latin-1, Latín extendido A y adicional, griego, cirílico y ancho completo. */
static uint32_t rx_lower(uint32_t c) {
    if (c < 0x80) return (c >= 'A' && c <= 'Z') ? c + 32 : c;
    if (c >= 0xC0 && c <= 0xDE && c != 0xD7) return c + 32;
    if (c >= 0x100 && c <= 0x17F) {
        if (c == 0x130) return 'i';
        if (c == 0x178) return 0xFF;
        if ((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E)) return (c & 1) ? c + 1 : c;
        if (c == 0x138 || c == 0x149 || c == 0x17F) return c;
        return (c & 1) ? c : c + 1;
    }
    if (c >= 0x391 && c <= 0x3AB && c != 0x3A2) return c + 32;
    if (c >= 0x410 && c <= 0x42F) return c + 32;
    if (c >= 0x400 && c <= 0x40F) return c + 80;
    if (c >= 0x460 && c <= 0x4FF && c != 0x482 && !(c >= 0x483 && c <= 0x489)) return (c & 1) ? c : c + 1;
    if (c >= 0x1E00 && c <= 0x1EFF) return (c & 1) ? c : c + 1;
    if (c >= 0xFF21 && c <= 0xFF3A) return c + 32;
    return c;
}

static uint32_t rx_upper(uint32_t c) {
    if (c < 0x80) return (c >= 'a' && c <= 'z') ? c - 32 : c;
    if (c >= 0xE0 && c <= 0xFE && c != 0xF7) return c - 32;
    if (c == 0xFF) return 0x178;
    if (c >= 0x100 && c <= 0x17F) {
        if (c == 0x138 || c == 0x149 || c == 0x17F) return c;
        if ((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E)) return (c & 1) ? c : c - 1;
        return (c & 1) ? c - 1 : c;
    }
    if (c >= 0x3B1 && c <= 0x3CB && c != 0x3C2) return c - 32;
    if (c == 0x3C2) return 0x3A3;
    if (c >= 0x430 && c <= 0x44F) return c - 32;
    if (c >= 0x450 && c <= 0x45F) return c - 80;
    if (c >= 0x460 && c <= 0x4FF && !(c >= 0x482 && c <= 0x489)) return (c & 1) ? c - 1 : c;
    if (c >= 0x1E00 && c <= 0x1EFF) return (c & 1) ? c - 1 : c;
    if (c >= 0xFF41 && c <= 0xFF5A) return c - 32;
    return c;
}

static uint32_t rx_fold(uint32_t c) { return c == 0x3C2 ? 0x3C3 : rx_lower(c); }

static int rx_is_digit(uint32_t c) {
    if (c < 0x80) return c >= '0' && c <= '9';
    return (c >= 0x660 && c <= 0x669) || (c >= 0x6F0 && c <= 0x6F9) || (c >= 0x966 && c <= 0x96F) || (c >= 0xFF10 && c <= 0xFF19);
}

static int rx_is_upper(uint32_t c) { return rx_lower(c) != c || (c >= 'A' && c <= 'Z'); }
static int rx_is_lower(uint32_t c) { return rx_upper(c) != c || c == 0xDF || c == 0x138 || c == 0x149; }

/* Letras (aproximación por bloques de Unicode). */
static int rx_is_letter(uint32_t c) {
    if (c < 0x80) return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if (c == 0xAA || c == 0xB5 || c == 0xBA) return 1;
    if (c >= 0xC0 && c <= 0x2AF) return c != 0xD7 && c != 0xF7;
    if (c >= 0x370 && c <= 0x3FF) return c != 0x375 && c != 0x37E && c != 0x384 && c != 0x385 && c != 0x387;
    if (c >= 0x400 && c <= 0x52F) return !(c >= 0x482 && c <= 0x489);
    if ((c >= 0x531 && c <= 0x556) || (c >= 0x561 && c <= 0x587)) return 1;
    if (c >= 0x5D0 && c <= 0x5EA) return 1;
    if ((c >= 0x620 && c <= 0x64A) || (c >= 0x671 && c <= 0x6D3)) return 1;
    if (c >= 0x904 && c <= 0x939) return 1;
    if (c >= 0xE01 && c <= 0xE30) return 1;
    if (c >= 0x10A0 && c <= 0x10FF) return 1;
    if (c >= 0x1100 && c <= 0x11FF) return 1;
    if (c >= 0x1E00 && c <= 0x1FFF) return 1;
    if ((c >= 0x3041 && c <= 0x3096) || (c >= 0x30A1 && c <= 0x30FA)) return 1;
    if ((c >= 0x3400 && c <= 0x4DBF) || (c >= 0x4E00 && c <= 0x9FFF)) return 1;
    if (c >= 0xAC00 && c <= 0xD7A3) return 1;
    if (c >= 0xF900 && c <= 0xFAFF) return 1;
    if ((c >= 0xFF21 && c <= 0xFF3A) || (c >= 0xFF41 && c <= 0xFF5A)) return 1;
    if (c >= 0x20000 && c <= 0x2FA1F) return 1;
    return 0;
}

static int rx_is_mark(uint32_t c) {
    return (c >= 0x300 && c <= 0x36F) || (c >= 0x483 && c <= 0x489) || (c >= 0x591 && c <= 0x5BD) || (c >= 0x64B && c <= 0x65F) ||
           (c >= 0x93A && c <= 0x94F) || (c >= 0x1AB0 && c <= 0x1AFF) || (c >= 0x1DC0 && c <= 0x1DFF) || (c >= 0x20D0 && c <= 0x20FF) ||
           (c >= 0xFE20 && c <= 0xFE2F);
}

/* \w de .NET: letras, marcas, dígitos y puntuación de conexión ('_'). */
static int rx_is_word(uint32_t c) {
    if (c < 0x80) return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    return rx_is_letter(c) || rx_is_digit(c) || rx_is_mark(c) || c == 0x203F || c == 0x2040 || c == 0x2054 || c == 0xFE33 ||
           c == 0xFE34 || c == 0xFE4D || c == 0xFE4E || c == 0xFE4F || c == 0xFF3F || c == 0x200C || c == 0x200D;
}

static int rx_is_space(uint32_t c) {
    if (c < 0x80) return c == ' ' || (c >= '\t' && c <= '\r');
    return c == 0x85 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F ||
           c == 0x205F || c == 0x3000;
}

static int rx_is_punct(uint32_t c) {
    if (c < 0x80) return (c >= '!' && c <= '/' && c != '$' && c != '+') || (c >= ':' && c <= '@' && c != '<' && c != '=' && c != '>') ||
                         (c >= '[' && c <= '_' && c != '^' && c != '`') || c == '{' || c == '}';
    return c == 0xA1 || c == 0xA7 || c == 0xAB || c == 0xB6 || c == 0xB7 || c == 0xBB || c == 0xBF || (c >= 0x2010 && c <= 0x2027) ||
           (c >= 0x2030 && c <= 0x205E) || (c >= 0x3001 && c <= 0x3003) || (c >= 0x3008 && c <= 0x3011);
}

/* Lee el punto de código en 'p'. Un byte no válido da 0x110000 + byte (no coincide con nada del patrón). */
static int rx_decode(const uint8_t* s, int64_t len, int64_t p, uint32_t* out) {
    uint32_t b = s[p];
    if (b < 0x80) {
        *out = b;
        return 1;
    }
    int n = (b & 0xE0) == 0xC0 ? 2 : (b & 0xF0) == 0xE0 ? 3 : (b & 0xF8) == 0xF0 ? 4 : 0;
    if (n == 0 || p + n > len) {
        *out = 0x110000 + b;
        return 1;
    }
    uint32_t c = b & (0x7F >> n);
    for (int k = 1; k < n; k++) {
        uint32_t t = s[p + k];
        if ((t & 0xC0) != 0x80) {
            *out = 0x110000 + b;
            return 1;
        }
        c = (c << 6) | (t & 0x3F);
    }
    if ((n == 2 && c < 0x80) || (n == 3 && c < 0x800) || (n == 4 && (c < 0x10000 || c > 0x10FFFF))) {
        *out = 0x110000 + b;
        return 1;
    }
    *out = c;
    return n;
}

/* Punto de código que termina justo antes de 'p' (o -1 al principio). */
static int64_t rx_prev(const uint8_t* s, int64_t len, int64_t p, uint32_t* out) {
    if (p <= 0) return -1;
    int64_t q = p - 1;
    int k = 0;
    while (q > 0 && k < 3 && (s[q] & 0xC0) == 0x80) {
        q--;
        k++;
    }
    uint32_t c;
    int n = rx_decode(s, len, q, &c);
    if (q + n != p) {
        *out = 0x110000 + s[p - 1];
        return p - 1;
    }
    *out = c;
    return q;
}

/* ---------------------------------------------------------------- clases de caracteres */

enum { CB_D = 1, CB_ND = 2, CB_W = 4, CB_NW = 8, CB_S = 16, CB_NS = 32, CB_L = 64, CB_LU = 128, CB_LL = 256, CB_N = 512,
       CB_P = 1024, CB_NL = 2048, CB_NLU = 4096, CB_NLL = 8192, CB_NN = 16384, CB_NP = 32768 };

typedef struct {
    uint32_t* r;  /* pares [lo, hi] */
    int n, cap;
    int builtin;  /* CB_* */
    int negated;
    int sub;      /* resta [a-z-[aeiou]]: índice + 1 de la clase restada (0 = ninguna) */
} rx_class;

static int rx_builtin(int b, uint32_t c) {
    if ((b & CB_D) && rx_is_digit(c)) return 1;
    if ((b & CB_ND) && !rx_is_digit(c)) return 1;
    if ((b & CB_W) && rx_is_word(c)) return 1;
    if ((b & CB_NW) && !rx_is_word(c)) return 1;
    if ((b & CB_S) && rx_is_space(c)) return 1;
    if ((b & CB_NS) && !rx_is_space(c)) return 1;
    if ((b & CB_L) && rx_is_letter(c)) return 1;
    if ((b & CB_NL) && !rx_is_letter(c)) return 1;
    if ((b & CB_LU) && rx_is_letter(c) && rx_is_upper(c)) return 1;
    if ((b & CB_NLU) && !(rx_is_letter(c) && rx_is_upper(c))) return 1;
    if ((b & CB_LL) && rx_is_letter(c) && rx_is_lower(c)) return 1;
    if ((b & CB_NLL) && !(rx_is_letter(c) && rx_is_lower(c))) return 1;
    if ((b & CB_N) && rx_is_digit(c)) return 1;
    if ((b & CB_NN) && !rx_is_digit(c)) return 1;
    if ((b & CB_P) && rx_is_punct(c)) return 1;
    if ((b & CB_NP) && !rx_is_punct(c)) return 1;
    return 0;
}

static int rx_class_raw(const rx_class* k, uint32_t c) {
    for (int i = 0; i < k->n; i++)
        if (c >= k->r[2 * i] && c <= k->r[2 * i + 1]) return 1;
    return k->builtin && c < 0x110000 && rx_builtin(k->builtin, c);
}

static int rx_class_match(const rx_class* all, int ci, uint32_t c, int icase) {
    const rx_class* k = &all[ci];
    int in = rx_class_raw(k, c);
    if (!in && icase && c < 0x110000) {
        uint32_t l = rx_lower(c), u = rx_upper(c);
        in = (l != c && rx_class_raw(k, l)) || (u != c && rx_class_raw(k, u)) || (c == 0x3C2 && rx_class_raw(k, 0x3C3));
    }
    if (in == k->negated) return 0;
    return !k->sub || !rx_class_match(all, k->sub - 1, c, icase);
}

/* ---------------------------------------------------------------- programa */

enum {
    OP_CHAR, OP_ANY, OP_ANYNL, OP_CLASS, OP_SPLIT, OP_JMP, OP_SAVE, OP_MATCH,
    OP_BOL, OP_EOL, OP_BOT, OP_EOTZ, OP_EOT, OP_WORDB, OP_NWORDB, OP_START,
    OP_BACKREF, OP_LOOK, OP_SETPOS, OP_PROGRESS
};
enum { LK_AHEAD = 0, LK_NAHEAD = 1, LK_BEHIND = 2, LK_NBEHIND = 3, LK_ATOMIC = 4 };

typedef struct {
    uint8_t op;
    uint8_t flag;   /* CHAR/CLASS/BACKREF: sin distinguir mayúsculas; LOOK: tipo */
    int32_t x, y;   /* CHAR: x = carácter; SPLIT: x preferido, y alternativo; JMP: x; SAVE: x = ranura;
                       LOOK: x = continuación, y = longitud máxima (-1 = sin límite) para lookbehind */
} rx_inst;

typedef struct {
    rx_inst* prog;
    int nprog, capprog;
    rx_class* classes;
    int nclasses, capclasses;
    int ngroups;          /* incluido el 0 */
    char** names;         /* nombre de cada grupo (NULL si no tiene) */
    int nregs;            /* registros de SETPOS/PROGRESS */
    int backtrack;        /* 1 si necesita el motor de retroceso */
    int options;
    int anchored;         /* empieza con \A (o ^ sin Multiline) */
    int first;            /* primer byte obligatorio (ASCII) o -1 */
} rx_regex;

/* ---------------------------------------------------------------- árbol */

enum { N_EMPTY, N_CHAR, N_ANY, N_CLASS, N_CAT, N_ALT, N_GROUP, N_REPEAT, N_ASSERT, N_BACKREF, N_NAMEDREF, N_LOOK };

typedef struct {
    int type;
    int a, b, c;      /* CHAR: a = carácter, b = icase; ANY: a = dotall; CLASS: a = clase, b = icase;
                         GROUP: a = índice provisional (>0 sin nombre, <0 con nombre: -(id+1)), -1000000 = no captura;
                         REPEAT: a = min, b = max (-1 = infinito), c = voraz; ASSERT: a = op;
                         BACKREF: a = número, b = icase; NAMEDREF: a = id de nombre, b = icase; LOOK: a = tipo */
    int kid;          /* primer hijo */
    int next;         /* siguiente hermano */
} rx_node;

typedef struct {
    const uint8_t* p;
    int64_t len, pos;
    rx_node* nodes;
    int nnodes, capnodes;
    rx_regex* re;
    char err[256];
    int unnamed;        /* grupos sin nombre */
    char** names;       /* nombres de grupos con nombre (distintos) */
    int* defined;       /* 1 si el nombre tiene un grupo (y no solo \k<nombre>) */
    int nnames, capnames;
    int maxBackref;
    int hasNamedRef;
} rx_parser;

static int px_node(rx_parser* P, int type) {
    if (P->nnodes == P->capnodes) {
        int c = P->capnodes ? P->capnodes * 2 : 64;
        rx_node* n = (rx_node*)realloc(P->nodes, sizeof(rx_node) * c);
        if (!n) return -1;
        P->nodes = n;
        P->capnodes = c;
    }
    rx_node* n = &P->nodes[P->nnodes];
    memset(n, 0, sizeof *n);
    n->type = type;
    n->kid = n->next = -1;
    return P->nnodes++;
}

static void px_error(rx_parser* P, const char* msg) {
    if (!P->err[0]) snprintf(P->err, sizeof P->err, "%s (posición %lld)", msg, (long long)P->pos);
}

static int px_eof(rx_parser* P) { return P->pos >= P->len; }
static uint32_t px_peek(rx_parser* P) {
    uint32_t c;
    rx_decode(P->p, P->len, P->pos, &c);
    return c;
}
static uint32_t px_get(rx_parser* P) {
    uint32_t c;
    P->pos += rx_decode(P->p, P->len, P->pos, &c);
    return c;
}

static int px_class(rx_parser* P) {
    rx_regex* re = P->re;
    if (re->nclasses == re->capclasses) {
        int c = re->capclasses ? re->capclasses * 2 : 8;
        rx_class* n = (rx_class*)realloc(re->classes, sizeof(rx_class) * c);
        if (!n) return -1;
        re->classes = n;
        re->capclasses = c;
    }
    memset(&re->classes[re->nclasses], 0, sizeof(rx_class));
    return re->nclasses++;
}

static void cls_add(rx_class* k, uint32_t lo, uint32_t hi) {
    if (k->n == k->cap) {
        int c = k->cap ? k->cap * 2 : 8;
        uint32_t* r = (uint32_t*)realloc(k->r, sizeof(uint32_t) * 2 * c);
        if (!r) return;
        k->r = r;
        k->cap = c;
    }
    k->r[2 * k->n] = lo;
    k->r[2 * k->n + 1] = hi;
    k->n++;
}

static int hexval(uint32_t c) {
    if (c >= '0' && c <= '9') return (int)(c - '0');
    if (c >= 'a' && c <= 'f') return (int)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return (int)(c - 'A' + 10);
    return -1;
}

/* \p{Nombre}: devuelve los bits CB_* (negados si 'neg'), o 0 si no se conoce. */
static int px_category(rx_parser* P, int neg) {
    if (px_eof(P) || px_get(P) != '{') {
        px_error(P, "se esperaba '{' después de \\p");
        return 0;
    }
    char name[32];
    int n = 0;
    while (!px_eof(P) && px_peek(P) != '}' && n < 31) name[n++] = (char)px_get(P);
    name[n] = 0;
    if (px_eof(P) || px_get(P) != '}') {
        px_error(P, "falta '}' en \\p{...}");
        return 0;
    }
    int b = 0;
    if (!strcmp(name, "L")) b = neg ? CB_NL : CB_L;
    else if (!strcmp(name, "Lu")) b = neg ? CB_NLU : CB_LU;
    else if (!strcmp(name, "Ll")) b = neg ? CB_NLL : CB_LL;
    else if (!strcmp(name, "N") || !strcmp(name, "Nd")) b = neg ? CB_NN : CB_N;
    else if (!strcmp(name, "P")) b = neg ? CB_NP : CB_P;
    else if (!strcmp(name, "Z") || !strcmp(name, "Zs")) b = neg ? CB_NS : CB_S;
    else px_error(P, "categoría Unicode no admitida en \\p{...} (se admiten L, Lu, Ll, N, Nd, P, Z, Zs)");
    return b;
}

/* Escape simple de un carácter (\t, \x41, ñ...). Devuelve 1 si lo reconoce. */
static int px_simple_escape(rx_parser* P, uint32_t e, uint32_t* out) {
    switch (e) {
        case 't': *out = '\t'; return 1;
        case 'n': *out = '\n'; return 1;
        case 'r': *out = '\r'; return 1;
        case 'f': *out = '\f'; return 1;
        case 'v': *out = '\v'; return 1;
        case 'a': *out = 7; return 1;
        case 'e': *out = 27; return 1;
        case 'x':
        case 'u': {
            int digits = e == 'x' ? 2 : 4;
            uint32_t v = 0;
            for (int i = 0; i < digits; i++) {
                int h = px_eof(P) ? -1 : hexval(px_peek(P));
                if (h < 0) {
                    px_error(P, e == 'x' ? "\\x necesita 2 dígitos hexadecimales" : "\\u necesita 4 dígitos hexadecimales");
                    return 1;
                }
                px_get(P);
                v = v * 16 + (uint32_t)h;
            }
            *out = v;
            return 1;
        }
        case 'c': {
            uint32_t c = px_eof(P) ? 0 : px_get(P);
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) px_error(P, "\\c necesita una letra");
            *out = c & 31;
            return 1;
        }
        case '0': {
            uint32_t v = 0;
            for (int i = 0; i < 2 && !px_eof(P) && px_peek(P) >= '0' && px_peek(P) <= '7'; i++) v = v * 8 + (px_get(P) - '0');
            *out = v;
            return 1;
        }
    }
    if (e < 0x80 && ((e >= 'a' && e <= 'z') || (e >= 'A' && e <= 'Z') || (e >= '0' && e <= '9'))) return 0;
    *out = e;  /* cualquier otro símbolo escapado es literal: \. \* \\ \/ ... */
    return 1;
}

static int px_alt(rx_parser* P, int* flags);

static int px_parse_class(rx_parser* P, int flags);

/* Resta de clases: tras '-[' (ya leídos) viene la clase que se resta y después el ']' final. */
static int px_class_sub(rx_parser* P, int ci, int flags) {
    int sub = px_parse_class(P, flags);
    if (P->err[0]) return 0;
    P->re->classes[ci].sub = P->nodes[sub].a + 1;
    if (px_eof(P) || px_get(P) != ']') {
        px_error(P, "la resta de clases debe ir al final: [a-z-[aeiou]]");
        return 0;
    }
    return 1;
}

/* [ ... ] */
static int px_parse_class(rx_parser* P, int flags) {
    int ci = px_class(P);
    if (ci < 0) return -1;
    int node = px_node(P, N_CLASS);
    P->nodes[node].a = ci;
    P->nodes[node].b = (flags & RX_ICASE) != 0;
    rx_class* k = &P->re->classes[ci];
    if (!px_eof(P) && px_peek(P) == '^') {
        px_get(P);
        k->negated = 1;
    }
    int first = 1;
    for (;;) {
        if (px_eof(P)) {
            px_error(P, "falta ']' al final de la clase de caracteres");
            return node;
        }
        uint32_t c = px_get(P);
        if (c == ']' && !first) break;
        if (c == '-' && !first && !px_eof(P) && px_peek(P) == '[') {
            px_get(P);
            px_class_sub(P, ci, flags);
            return node;
        }
        first = 0;
        uint32_t lo;
        int isChar = 1;
        if (c == '\\') {
            if (px_eof(P)) {
                px_error(P, "'\\' al final del patrón");
                return node;
            }
            uint32_t e = px_get(P);
            k = &P->re->classes[ci];
            switch (e) {
                case 'd': k->builtin |= CB_D; isChar = 0; break;
                case 'D': k->builtin |= CB_ND; isChar = 0; break;
                case 'w': k->builtin |= CB_W; isChar = 0; break;
                case 'W': k->builtin |= CB_NW; isChar = 0; break;
                case 's': k->builtin |= CB_S; isChar = 0; break;
                case 'S': k->builtin |= CB_NS; isChar = 0; break;
                case 'p': k->builtin |= px_category(P, 0); isChar = 0; break;
                case 'P': k->builtin |= px_category(P, 1); isChar = 0; break;
                case 'b': lo = 8; break;
                default:
                    if (!px_simple_escape(P, e, &lo)) {
                        px_error(P, "secuencia de escape desconocida en la clase");
                        return node;
                    }
            }
            if (!isChar) continue;
        } else if (c == '[' && !px_eof(P) && px_peek(P) == ':') {
            /* [:alpha:] de POSIX: .NET lo toma como literal; aquí también. */
            lo = c;
        } else lo = c;
        uint32_t hi = lo;
        if (!px_eof(P) && px_peek(P) == '-' && P->pos + 1 < P->len && P->p[P->pos + 1] != ']') {
            int64_t save = P->pos;
            px_get(P);
            uint32_t d = px_get(P);
            if (d == '[') {
                /* [a-[b]]: 'a' menos la clase [b] */
                cls_add(&P->re->classes[ci], lo, lo);
                px_class_sub(P, ci, flags);
                return node;
            }
            if (d == '\\') {
                if (px_eof(P)) {
                    px_error(P, "'\\' al final del patrón");
                    return node;
                }
                uint32_t e = px_get(P);
                if (e == 'b') d = 8;
                else if (!px_simple_escape(P, e, &d) || e == 'd' || e == 'w' || e == 's') {
                    P->pos = save;  /* [a-\d]: el '-' es literal */
                    cls_add(&P->re->classes[ci], lo, lo);
                    continue;
                }
            }
            hi = d;
            if (hi < lo) {
                px_error(P, "rango [x-y] en orden inverso");
                return node;
            }
        }
        cls_add(&P->re->classes[ci], lo, hi);
    }
    return node;
}

static int px_name(rx_parser* P, char close, char* out, int cap) {
    int n = 0;
    while (!px_eof(P) && (char)P->p[P->pos] != close) {
        uint8_t c = P->p[P->pos];
        if (!(c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80) || n >= cap - 1) {
            px_error(P, "nombre de grupo no válido");
            return 0;
        }
        out[n++] = (char)c;
        P->pos++;
    }
    out[n] = 0;
    if (px_eof(P) || n == 0) {
        px_error(P, "nombre de grupo vacío o sin cerrar");
        return 0;
    }
    P->pos++;
    return 1;
}

static int px_name_id(rx_parser* P, const char* name) {
    for (int i = 0; i < P->nnames; i++)
        if (!strcmp(P->names[i], name)) return i;
    if (P->nnames == P->capnames) {
        int c = P->capnames ? P->capnames * 2 : 8;
        char** n = (char**)realloc(P->names, sizeof(char*) * c);
        int* d = (int*)realloc(P->defined, sizeof(int) * c);
        if (!n || !d) return -1;
        P->names = n;
        P->defined = d;
        P->capnames = c;
    }
    P->defined[P->nnames] = 0;
    size_t l = strlen(name);
    char* d = (char*)malloc(l + 1);
    memcpy(d, name, l + 1);
    P->names[P->nnames] = d;
    return P->nnames++;
}

static int px_parse_flags(rx_parser* P, int* flags, int* scoped) {
    /* (?imnsx-imnsx) o (?imnsx-imnsx: ...) */
    int on = 1;
    int f = *flags;
    for (;;) {
        if (px_eof(P)) {
            px_error(P, "grupo sin cerrar");
            return 0;
        }
        uint32_t c = px_get(P);
        int bit = c == 'i' ? RX_ICASE : c == 'm' ? RX_MULTILINE : c == 's' ? RX_SINGLELINE : c == 'n' ? RX_EXPLICIT : c == 'x' ? RX_IGNORE_WS : 0;
        if (bit) f = on ? (f | bit) : (f & ~bit);
        else if (c == '-') on = 0;
        else if (c == ')') {
            *scoped = 0;
            *flags = f;
            return 1;
        } else if (c == ':') {
            *scoped = 1;
            *flags = f;
            return 1;
        } else {
            px_error(P, "construcción (?...) desconocida");
            return 0;
        }
    }
}

static void px_skip_ws(rx_parser* P, int flags) {
    if (!(flags & RX_IGNORE_WS)) return;
    while (!px_eof(P)) {
        uint8_t c = P->p[P->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v') P->pos++;
        else if (c == '#') {
            while (!px_eof(P) && P->p[P->pos] != '\n') P->pos++;
        } else break;
    }
}

/* Átomo; devuelve -1 si no hay (fin de alternativa) y -2 en error. */
static int px_atom(rx_parser* P, int* flags) {
    px_skip_ws(P, *flags);
    if (px_eof(P)) return -1;
    uint32_t c = px_peek(P);
    if (c == '|' || c == ')') return -1;
    px_get(P);
    int n;
    switch (c) {
        case '(': {
            int f = *flags;
            int kind = 0;   /* 0 captura, 1 no captura, 2 look, 3 solo opciones */
            int groupA = 0, look = 0;
            if (!px_eof(P) && px_peek(P) == '?') {
                px_get(P);
                uint32_t d = px_eof(P) ? 0 : px_get(P);
                char name[128];
                if (d == ':') kind = 1;
                else if (d == '=') kind = 2, look = LK_AHEAD;
                else if (d == '!') kind = 2, look = LK_NAHEAD;
                else if (d == '>') kind = 2, look = LK_ATOMIC;
                else if (d == '#') {
                    while (!px_eof(P) && px_peek(P) != ')') px_get(P);
                    if (px_eof(P)) {
                        px_error(P, "comentario (?#...) sin cerrar");
                        return -2;
                    }
                    px_get(P);
                    return px_node(P, N_EMPTY);
                } else if (d == '<' && !px_eof(P) && (px_peek(P) == '=' || px_peek(P) == '!')) {
                    kind = 2;
                    look = px_get(P) == '=' ? LK_BEHIND : LK_NBEHIND;
                } else if (d == '<' || d == '\'' || (d == 'P' && !px_eof(P) && px_peek(P) == '<')) {
                    if (d == 'P') px_get(P);
                    if (!px_name(P, d == '\'' ? '\'' : '>', name, sizeof name)) return -2;
                    if (name[0] >= '0' && name[0] <= '9') {
                        px_error(P, "los grupos con número explícito (?<3>...) no están admitidos");
                        return -2;
                    }
                    int id = px_name_id(P, name);
                    if (id < 0) return -2;
                    P->defined[id] = 1;
                    groupA = -(id + 1);
                    kind = 0;
                } else if (d == '(') {
                    px_error(P, "los grupos condicionales (?(...)) no están admitidos");
                    return -2;
                } else {
                    P->pos -= 1;
                    int scoped = 0;
                    if (!px_parse_flags(P, &f, &scoped)) return -2;
                    if (!scoped) {
                        *flags = f;   /* (?i): hasta el final del grupo actual */
                        return px_node(P, N_EMPTY);
                    }
                    kind = 1;
                }
            } else {
                if (f & RX_EXPLICIT) kind = 1;
                else groupA = ++P->unnamed;
            }
            int inner = f;
            int body = px_alt(P, &inner);
            if (body == -2) return -2;
            if (px_eof(P) || px_get(P) != ')') {
                px_error(P, "falta ')'");
                return -2;
            }
            if (kind == 1) {
                n = px_node(P, N_GROUP);
                P->nodes[n].a = -1000000;
            } else if (kind == 2) {
                n = px_node(P, N_LOOK);
                P->nodes[n].a = look;
                P->re->backtrack = 1;
            } else {
                n = px_node(P, N_GROUP);
                P->nodes[n].a = groupA;
            }
            P->nodes[n].kid = body;
            return n;
        }
        case '[': return px_parse_class(P, *flags);
        case '.':
            n = px_node(P, N_ANY);
            P->nodes[n].a = (*flags & RX_SINGLELINE) != 0;
            return n;
        case '^':
            n = px_node(P, N_ASSERT);
            P->nodes[n].a = (*flags & RX_MULTILINE) ? OP_BOL : OP_BOT;
            return n;
        case '$':
            n = px_node(P, N_ASSERT);
            P->nodes[n].a = (*flags & RX_MULTILINE) ? OP_EOL : OP_EOTZ;
            return n;
        case '*': case '+': case '?':
            px_error(P, "cuantificador sin nada que repetir");
            return -2;
        case '\\': {
            if (px_eof(P)) {
                px_error(P, "'\\' al final del patrón");
                return -2;
            }
            uint32_t e = px_get(P);
            int op = -1, b = 0;
            switch (e) {
                case 'b': op = OP_WORDB; break;
                case 'B': op = OP_NWORDB; break;
                case 'A': op = OP_BOT; break;
                case 'z': op = OP_EOT; break;
                case 'Z': op = OP_EOTZ; break;
                case 'G': op = OP_START; break;
                case 'd': b = CB_D; break;
                case 'D': b = CB_ND; break;
                case 'w': b = CB_W; break;
                case 'W': b = CB_NW; break;
                case 's': b = CB_S; break;
                case 'S': b = CB_NS; break;
                case 'p': b = px_category(P, 0); if (!b) return -2; break;
                case 'P': b = px_category(P, 1); if (!b) return -2; break;
                case 'k': {
                    char name[128];
                    uint32_t open = px_eof(P) ? 0 : px_get(P);
                    if (open != '<' && open != '\'') {
                        px_error(P, "\\k necesita un nombre: \\k<nombre>");
                        return -2;
                    }
                    if (!px_name(P, open == '<' ? '>' : '\'', name, sizeof name)) return -2;
                    n = px_node(P, N_NAMEDREF);
                    if (name[0] >= '0' && name[0] <= '9') {
                        P->nodes[n].type = N_BACKREF;
                        P->nodes[n].a = atoi(name);
                        if (P->nodes[n].a > P->maxBackref) P->maxBackref = P->nodes[n].a;
                    } else P->nodes[n].a = px_name_id(P, name);
                    P->nodes[n].b = (*flags & RX_ICASE) != 0;
                    P->re->backtrack = 1;
                    P->hasNamedRef = 1;
                    return n;
                }
            }
            if (op >= 0) {
                n = px_node(P, N_ASSERT);
                P->nodes[n].a = op;
                return n;
            }
            if (b) {
                int ci = px_class(P);
                if (ci < 0) return -2;
                P->re->classes[ci].builtin = b;
                n = px_node(P, N_CLASS);
                P->nodes[n].a = ci;
                P->nodes[n].b = 0;
                return n;
            }
            if (e >= '1' && e <= '9') {
                int v = (int)(e - '0');
                while (!px_eof(P) && px_peek(P) >= '0' && px_peek(P) <= '9' && v * 10 + (int)(px_peek(P) - '0') <= 99) v = v * 10 + (int)(px_get(P) - '0');
                n = px_node(P, N_BACKREF);
                P->nodes[n].a = v;
                P->nodes[n].b = (*flags & RX_ICASE) != 0;
                if (v > P->maxBackref) P->maxBackref = v;
                P->re->backtrack = 1;
                return n;
            }
            uint32_t lit;
            if (!px_simple_escape(P, e, &lit)) {
                px_error(P, "secuencia de escape desconocida");
                return -2;
            }
            n = px_node(P, N_CHAR);
            P->nodes[n].a = (int)((*flags & RX_ICASE) ? rx_fold(lit) : lit);
            P->nodes[n].b = (*flags & RX_ICASE) != 0;
            return n;
        }
        default:
            n = px_node(P, N_CHAR);
            P->nodes[n].a = (int)((*flags & RX_ICASE) ? rx_fold(c) : c);
            P->nodes[n].b = (*flags & RX_ICASE) != 0;
            return n;
    }
}

/* {n}, {n,}, {n,m}: 1 si lo es (y avanza); si no, el '{' es literal. */
static int px_brace(rx_parser* P, int* mn, int* mx) {
    int64_t p = P->pos;
    if (p >= P->len || P->p[p] != '{') return 0;
    p++;
    int64_t a = 0, digits = 0;
    while (p < P->len && P->p[p] >= '0' && P->p[p] <= '9') {
        a = a * 10 + (P->p[p++] - '0');
        digits++;
        if (a > 100000) a = 100000;
    }
    if (!digits) return 0;
    int64_t b = a;
    if (p < P->len && P->p[p] == ',') {
        p++;
        b = -1;
        int64_t d2 = 0, v = 0;
        while (p < P->len && P->p[p] >= '0' && P->p[p] <= '9') {
            v = v * 10 + (P->p[p++] - '0');
            d2++;
            if (v > 100000) v = 100000;
        }
        if (d2) b = v;
    }
    if (p >= P->len || P->p[p] != '}') return 0;
    P->pos = p + 1;
    *mn = (int)a;
    *mx = (int)b;
    return 1;
}

static int px_seq(rx_parser* P, int* flags) {
    int first = -1, last = -1;
    for (;;) {
        int a = px_atom(P, flags);
        if (a == -2) return -2;
        if (a == -1) break;
        for (;;) {
            px_skip_ws(P, *flags);
            if (px_eof(P)) break;
            uint32_t q = px_peek(P);
            int mn, mx;
            if (q == '*') px_get(P), mn = 0, mx = -1;
            else if (q == '+') px_get(P), mn = 1, mx = -1;
            else if (q == '?') px_get(P), mn = 0, mx = 1;
            else if (q == '{' && px_brace(P, &mn, &mx)) {
                if (mx >= 0 && mx < mn) {
                    px_error(P, "cuantificador {n,m} con m < n");
                    return -2;
                }
            } else break;
            int greedy = 1;
            if (!px_eof(P) && px_peek(P) == '?') {
                px_get(P);
                greedy = 0;
            }
            int t = P->nodes[a].type;
            if (t == N_ASSERT || (t == N_EMPTY)) {
                /* \b* o (?i)*: .NET lo rechaza */
                px_error(P, "cuantificador sin nada que repetir");
                return -2;
            }
            int r = px_node(P, N_REPEAT);
            P->nodes[r].a = mn;
            P->nodes[r].b = mx;
            P->nodes[r].c = greedy;
            P->nodes[r].kid = a;
            a = r;
            px_skip_ws(P, *flags);
            if (!px_eof(P) && (px_peek(P) == '*' || px_peek(P) == '+' || px_peek(P) == '?')) {
                px_error(P, "cuantificador anidado (p. ej. a**): agrupa con (...) si es lo que quieres");
                return -2;
            }
        }
        if (first < 0) first = a;
        else P->nodes[last].next = a;
        last = a;
    }
    int n = px_node(P, N_CAT);
    P->nodes[n].kid = first;
    return n;
}

static int px_alt(rx_parser* P, int* flags) {
    int first = px_seq(P, flags);
    if (first == -2) return -2;
    if (px_eof(P) || px_peek(P) != '|') return first;
    int alt = px_node(P, N_ALT);
    P->nodes[alt].kid = first;
    int last = first;
    while (!px_eof(P) && px_peek(P) == '|') {
        px_get(P);
        int s = px_seq(P, flags);
        if (s == -2) return -2;
        P->nodes[last].next = s;
        last = s;
    }
    return alt;
}

/* ---------------------------------------------------------------- compilación */

typedef struct {
    rx_parser* P;
    rx_regex* re;
    int failed;
} rx_comp;

static int cp_emit(rx_comp* C, int op, int flag, int x, int y) {
    rx_regex* re = C->re;
    if (re->nprog >= 300000) {
        C->failed = 1;
        return 0;
    }
    if (re->nprog == re->capprog) {
        int c = re->capprog ? re->capprog * 2 : 64;
        rx_inst* n = (rx_inst*)realloc(re->prog, sizeof(rx_inst) * c);
        if (!n) {
            C->failed = 1;
            return 0;
        }
        re->prog = n;
        re->capprog = c;
    }
    rx_inst* i = &re->prog[re->nprog];
    i->op = (uint8_t)op;
    i->flag = (uint8_t)flag;
    i->x = x;
    i->y = y;
    return re->nprog++;
}

static int nd_nullable(rx_parser* P, int n) {
    rx_node* d = &P->nodes[n];
    switch (d->type) {
        case N_CHAR: case N_ANY: case N_CLASS: return 0;
        case N_CAT:
            for (int k = d->kid; k >= 0; k = P->nodes[k].next)
                if (!nd_nullable(P, k)) return 0;
            return 1;
        case N_ALT:
            for (int k = d->kid; k >= 0; k = P->nodes[k].next)
                if (nd_nullable(P, k)) return 1;
            return 0;
        case N_GROUP: return nd_nullable(P, d->kid);
        case N_REPEAT: return d->a == 0 || nd_nullable(P, d->kid);
        case N_LOOK: return d->a == LK_ATOMIC ? nd_nullable(P, d->kid) : 1;
        default: return 1;  /* aserciones, referencias (pueden ser vacías) */
    }
}

/* Longitud máxima en bytes (-1 si no está acotada). */
static int64_t nd_maxlen(rx_parser* P, int n) {
    rx_node* d = &P->nodes[n];
    switch (d->type) {
        case N_CHAR: case N_ANY: case N_CLASS: return 4;
        case N_CAT: {
            int64_t t = 0;
            for (int k = d->kid; k >= 0; k = P->nodes[k].next) {
                int64_t m = nd_maxlen(P, k);
                if (m < 0) return -1;
                t += m;
            }
            return t;
        }
        case N_ALT: {
            int64_t t = 0;
            for (int k = d->kid; k >= 0; k = P->nodes[k].next) {
                int64_t m = nd_maxlen(P, k);
                if (m < 0) return -1;
                if (m > t) t = m;
            }
            return t;
        }
        case N_GROUP: return nd_maxlen(P, d->kid);
        case N_REPEAT: {
            if (d->b < 0) return -1;
            int64_t m = nd_maxlen(P, d->kid);
            return m < 0 ? -1 : m * d->b;
        }
        case N_LOOK: return d->a == LK_ATOMIC ? nd_maxlen(P, d->kid) : 0;
        case N_BACKREF: case N_NAMEDREF: return -1;
        default: return 0;
    }
}

static int group_number(rx_parser* P, int a) {
    if (a > 0) return a;
    return P->unnamed + (-a - 1) + 1;
}

static void cp_node(rx_comp* C, int n) {
    if (C->failed) return;
    rx_parser* P = C->P;
    rx_node d = P->nodes[n];
    switch (d.type) {
        case N_EMPTY: break;
        case N_CHAR: cp_emit(C, OP_CHAR, d.b, d.a, 0); break;
        case N_ANY: cp_emit(C, d.a ? OP_ANYNL : OP_ANY, 0, 0, 0); break;
        case N_CLASS: cp_emit(C, OP_CLASS, d.b, d.a, 0); break;
        case N_CAT:
            for (int k = d.kid; k >= 0; k = P->nodes[k].next) cp_node(C, k);
            break;
        case N_ALT: {
            int jumps[4096];
            int nj = 0;
            int ovf = 0;
            for (int k = d.kid; k >= 0; k = P->nodes[k].next) {
                if (P->nodes[k].next >= 0) {
                    int s = cp_emit(C, OP_SPLIT, 0, 0, 0);
                    C->re->prog[s].x = s + 1;
                    cp_node(C, k);
                    int j = cp_emit(C, OP_JMP, 0, 0, 0);
                    if (nj < 4096) jumps[nj++] = j;
                    else ovf = 1;
                    if (C->failed) return;
                    C->re->prog[s].y = C->re->nprog;
                } else cp_node(C, k);
            }
            if (ovf) {
                C->failed = 1;
                return;
            }
            for (int i = 0; i < nj; i++) C->re->prog[jumps[i]].x = C->re->nprog;
            break;
        }
        case N_GROUP:
            if (d.a == -1000000) cp_node(C, d.kid);
            else {
                int g = group_number(P, d.a);
                cp_emit(C, OP_SAVE, 0, 2 * g, 0);
                cp_node(C, d.kid);
                cp_emit(C, OP_SAVE, 0, 2 * g + 1, 0);
            }
            break;
        case N_REPEAT: {
            int mn = d.a, mx = d.b, greedy = d.c;
            for (int i = 0; i < mn; i++) cp_node(C, d.kid);
            if (mx < 0) {
                int nullable = nd_nullable(P, d.kid);
                int L1 = cp_emit(C, OP_SPLIT, 0, 0, 0);
                int reg = -1;
                if (nullable) {
                    reg = C->re->nregs++;
                    cp_emit(C, OP_SETPOS, 0, reg, 0);
                }
                cp_node(C, d.kid);
                if (nullable) cp_emit(C, OP_PROGRESS, 0, reg, 0);
                cp_emit(C, OP_JMP, 0, L1, 0);
                if (C->failed) return;
                int L3 = C->re->nprog;
                C->re->prog[L1].x = greedy ? L1 + 1 : L3;
                C->re->prog[L1].y = greedy ? L3 : L1 + 1;
            } else if (mx > mn) {
                int splits[1024];
                int ns = 0, ovf = 0;
                for (int i = mn; i < mx; i++) {
                    int s = cp_emit(C, OP_SPLIT, 0, 0, 0);
                    if (ns < 1024) splits[ns++] = s;
                    else ovf = 1;
                    cp_node(C, d.kid);
                    if (C->failed) return;
                }
                if (ovf) {
                    /* {n,m} con m - n > 1024: se compila como x{n}(x?){m-n} sin anidar (mismo lenguaje). */
                    C->failed = 1;
                    return;
                }
                int end = C->re->nprog;
                for (int i = 0; i < ns; i++) {
                    C->re->prog[splits[i]].x = greedy ? splits[i] + 1 : end;
                    C->re->prog[splits[i]].y = greedy ? end : splits[i] + 1;
                }
            }
            break;
        }
        case N_ASSERT: cp_emit(C, d.a, 0, 0, 0); break;
        case N_BACKREF: cp_emit(C, OP_BACKREF, d.b, d.a, 0); break;
        case N_NAMEDREF: cp_emit(C, OP_BACKREF, d.b, P->unnamed + d.a + 1, 0); break;
        case N_LOOK: {
            int64_t ml = (d.a == LK_BEHIND || d.a == LK_NBEHIND) ? nd_maxlen(P, d.kid) : -1;
            int l = cp_emit(C, OP_LOOK, d.a, 0, ml > 0x7fffffff ? -1 : (int)ml);
            cp_node(C, d.kid);
            cp_emit(C, OP_MATCH, 0, 0, 0);
            if (C->failed) return;
            C->re->prog[l].x = C->re->nprog;
            break;
        }
    }
}

void faset_regex_free(void* p) {
    rx_regex* re = (rx_regex*)p;
    if (!re) return;
    free(re->prog);
    for (int i = 0; i < re->nclasses; i++) free(re->classes[i].r);
    free(re->classes);
    if (re->names) {
        for (int i = 0; i < re->ngroups; i++) free(re->names[i]);
        free(re->names);
    }
    free(re);
}

/* Compila 'pattern'. Devuelve NULL y el mensaje en '*error' si no es válido. */
void* faset_regex_compile(rx_str pattern, int32_t options, rx_str* error) {
    rx_regex* re = (rx_regex*)calloc(1, sizeof(rx_regex));
    rx_parser P;
    memset(&P, 0, sizeof P);
    P.p = pattern.ptr;
    P.len = pattern.len;
    P.re = re;
    re->options = options;
    if (options & RX_RIGHT_TO_LEFT) snprintf(P.err, sizeof P.err, "RegexOptions.RightToLeft no está admitido");
    int flags = options;
    int root = P.err[0] ? -2 : px_alt(&P, &flags);
    if (root != -2 && !P.err[0] && !px_eof(&P)) px_error(&P, "')' sin '(' que la abra");
    for (int i = 0; i < P.nnames && !P.err[0]; i++)
        if (!P.defined[i]) snprintf(P.err, sizeof P.err, "referencia a un grupo con nombre que no existe: '%s'", P.names[i]);
    if (!P.err[0]) {
        re->ngroups = 1 + P.unnamed + P.nnames;
        if (P.maxBackref >= re->ngroups) px_error(&P, "referencia a un grupo que no existe");
    }
    if (!P.err[0] && (options & RX_NONBACKTRACKING) && re->backtrack)
        px_error(&P, "RegexOptions.NonBacktracking no admite referencias hacia atrás, búsquedas alrededor ni grupos atómicos");
    if (!P.err[0]) {
        rx_comp C = {&P, re, 0};
        cp_emit(&C, OP_SAVE, 0, 0, 0);
        cp_node(&C, root);
        cp_emit(&C, OP_SAVE, 0, 1, 0);
        cp_emit(&C, OP_MATCH, 0, 0, 0);
        if (C.failed) snprintf(P.err, sizeof P.err, "el patrón es demasiado grande (repeticiones {n,m} muy altas)");
    }
    if (P.err[0]) {
        *error = rx_copy(P.err, (int64_t)strlen(P.err));
        for (int i = 0; i < P.nnames; i++) free(P.names[i]);
        free(P.names);
        free(P.defined);
        free(P.nodes);
        faset_regex_free(re);
        return NULL;
    }
    /* Nombres: los grupos sin nombre se numeran primero y después los que tienen nombre (como .NET). */
    re->names = (char**)calloc((size_t)re->ngroups, sizeof(char*));
    for (int i = 0; i < P.nnames; i++) re->names[1 + P.unnamed + i] = P.names[i];
    free(P.names);
    free(P.defined);
    free(P.nodes);
    /* Anclado al principio y primer byte obligatorio (para saltar posiciones sin coincidencia). */
    re->first = -1;
    int pc = 1;
    while (pc < re->nprog && re->prog[pc].op == OP_SAVE) pc++;
    if (pc < re->nprog) {
        rx_inst* in = &re->prog[pc];
        if (in->op == OP_BOT) re->anchored = 1;
        else if (in->op == OP_CHAR && !in->flag && in->x < 0x80) re->first = in->x;
    }
    *error = rx_copy("", 0);
    return re;
}

int32_t faset_regex_group_count(void* p) { return ((rx_regex*)p)->ngroups; }

/* Nombre del grupo 'i' ("" si no tiene). */
rx_str faset_regex_group_name(void* p, int32_t i) {
    rx_regex* re = (rx_regex*)p;
    if (i < 0 || i >= re->ngroups || !re->names[i]) return rx_copy("", 0);
    return rx_copy(re->names[i], (int64_t)strlen(re->names[i]));
}

/* ---------------------------------------------------------------- ejecución: común */

typedef struct {
    rx_regex* re;
    const uint8_t* s;
    int64_t len;
    int64_t start;      /* posición de \G */
    int64_t steps, budget;
    int64_t deadline;   /* ms (0 = sin límite) */
    int aborted;
} rx_exec;

static int64_t rx_now_ms(void) {
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static int rx_tick(rx_exec* X) {
    if (++X->steps > X->budget) {
        X->aborted = 1;
        return 0;
    }
    if (X->deadline && (X->steps & 0xFFFF) == 0 && rx_now_ms() > X->deadline) {
        X->aborted = 1;
        return 0;
    }
    return 1;
}

static int rx_is_word_at(rx_exec* X, int64_t p, int before) {
    uint32_t c;
    if (before) {
        if (rx_prev(X->s, X->len, p, &c) < 0) return 0;
    } else {
        if (p >= X->len) return 0;
        rx_decode(X->s, X->len, p, &c);
    }
    return c < 0x110000 && rx_is_word(c);
}

/* Aserciones de anchura cero. */
static int rx_assert(rx_exec* X, int op, int64_t sp) {
    const uint8_t* s = X->s;
    int64_t len = X->len;
    switch (op) {
        case OP_BOL: return sp == 0 || s[sp - 1] == '\n';
        case OP_EOL: return sp == len || s[sp] == '\n';
        case OP_BOT: return sp == 0;
        case OP_EOTZ: return sp == len || (sp == len - 1 && s[sp] == '\n');
        case OP_EOT: return sp == len;
        case OP_WORDB: return rx_is_word_at(X, sp, 1) != rx_is_word_at(X, sp, 0);
        case OP_NWORDB: return rx_is_word_at(X, sp, 1) == rx_is_word_at(X, sp, 0);
        case OP_START: return sp == X->start;
    }
    return 0;
}

/* ¿Consume la instrucción 'in' el carácter c? */
static int rx_consumes(rx_regex* re, rx_inst* in, uint32_t c) {
    switch (in->op) {
        case OP_CHAR: return in->flag ? (c < 0x110000 && rx_fold(c) == (uint32_t)in->x) : c == (uint32_t)in->x;
        case OP_ANY: return c != '\n';
        case OP_ANYNL: return 1;
        case OP_CLASS: return rx_class_match(re->classes, in->x, c, in->flag);
    }
    return 0;
}

/* ---------------------------------------------------------------- retroceso */

enum { BT_BRANCH, BT_CAP, BT_REG };
typedef struct { int32_t kind, a; int64_t b; } bt_frame;

typedef struct {
    bt_frame* f;
    int64_t n, cap;
} bt_stack;

static int bt_push(rx_exec* X, bt_stack* st, int kind, int a, int64_t b) {
    if (st->n == st->cap) {
        int64_t c = st->cap ? st->cap * 2 : 256;
        if (c > 64 * 1024 * 1024) {
            X->aborted = 1;
            return 0;
        }
        bt_frame* nf = (bt_frame*)realloc(st->f, sizeof(bt_frame) * (size_t)c);
        if (!nf) {
            X->aborted = 1;
            return 0;
        }
        st->f = nf;
        st->cap = c;
    }
    st->f[st->n].kind = kind;
    st->f[st->n].a = a;
    st->f[st->n].b = b;
    st->n++;
    return 1;
}

/* Ejecuta desde 'pc' en 'sp'. Devuelve la posición final o -1. Si 'mustEnd' >= 0, solo vale
 * terminar (OP_MATCH) exactamente ahí (lookbehind). Las capturas quedan en 'caps'. */
static int64_t bt_run(rx_exec* X, bt_stack* st, int pc, int64_t sp, int64_t* caps, int64_t* regs, int64_t mustEnd) {
    rx_regex* re = X->re;
    int64_t base = st->n;
    for (;;) {
        if (!rx_tick(X)) return -1;
        rx_inst* in = &re->prog[pc];
        int ok = 1;
        switch (in->op) {
            case OP_CHAR: case OP_ANY: case OP_ANYNL: case OP_CLASS: {
                if (sp >= X->len) {
                    ok = 0;
                    break;
                }
                uint32_t c;
                int n = rx_decode(X->s, X->len, sp, &c);
                if (rx_consumes(re, in, c)) {
                    sp += n;
                    pc++;
                } else ok = 0;
                break;
            }
            case OP_SPLIT:
                if (!bt_push(X, st, BT_BRANCH, in->y, sp)) return -1;
                pc = in->x;
                break;
            case OP_JMP: pc = in->x; break;
            case OP_SAVE:
                if (!bt_push(X, st, BT_CAP, in->x, caps[in->x])) return -1;
                caps[in->x] = sp;
                pc++;
                break;
            case OP_SETPOS:
                if (!bt_push(X, st, BT_REG, in->x, regs[in->x])) return -1;
                regs[in->x] = sp;
                pc++;
                break;
            case OP_PROGRESS:
                if (regs[in->x] == sp) ok = 0;
                else pc++;
                break;
            case OP_MATCH:
                if (mustEnd >= 0 && sp != mustEnd) {
                    ok = 0;
                    break;
                }
                st->n = base;   /* éxito: se descartan las alternativas pendientes (sin deshacer capturas) */
                return sp;
            case OP_BACKREF: {
                int g = in->x;
                int64_t a = caps[2 * g], b = caps[2 * g + 1];
                if (a < 0 || b < 0) {   /* grupo sin participar: no coincide (como .NET) */
                    ok = 0;
                    break;
                }
                int64_t n = b - a;
                if (!in->flag) {
                    if (sp + n <= X->len && memcmp(X->s + a, X->s + sp, (size_t)n) == 0) {
                        sp += n;
                        pc++;
                    } else ok = 0;
                } else {
                    int64_t p = a, q = sp;
                    while (p < b) {
                        if (q >= X->len) {
                            ok = 0;
                            break;
                        }
                        uint32_t c1, c2;
                        p += rx_decode(X->s, X->len, p, &c1);
                        q += rx_decode(X->s, X->len, q, &c2);
                        if (rx_fold(c1) != rx_fold(c2)) {
                            ok = 0;
                            break;
                        }
                    }
                    if (ok) {
                        sp = q;
                        pc++;
                    }
                }
                break;
            }
            case OP_LOOK: {
                int kind = in->flag;
                int ng2 = re->ngroups * 2;
                int64_t snap[64];
                int64_t* old = ng2 <= 64 ? snap : (int64_t*)malloc(sizeof(int64_t) * (size_t)ng2);
                if (!old) return -1;
                memcpy(old, caps, sizeof(int64_t) * (size_t)ng2);
                int64_t end = -1;
                if (kind == LK_AHEAD || kind == LK_NAHEAD || kind == LK_ATOMIC) end = bt_run(X, st, pc + 1, sp, caps, regs, -1);
                else {
                    int64_t lo = in->y >= 0 ? sp - in->y : 0;
                    if (lo < 0) lo = 0;
                    for (int64_t s0 = sp; s0 >= lo && end < 0 && !X->aborted; s0--) {
                        if (s0 < X->len && s0 > 0 && (X->s[s0] & 0xC0) == 0x80) continue;
                        end = bt_run(X, st, pc + 1, s0, caps, regs, sp);
                    }
                }
                if (X->aborted) {
                    if (old != snap) free(old);
                    return -1;
                }
                int positive = kind == LK_AHEAD || kind == LK_BEHIND || kind == LK_ATOMIC;
                if ((end >= 0) == positive) {
                    if (end >= 0) {
                        /* Capturas de dentro: se deshacen si luego se retrocede más atrás. */
                        for (int i = 0; i < ng2; i++)
                            if (caps[i] != old[i] && !bt_push(X, st, BT_CAP, i, old[i])) {
                                if (old != snap) free(old);
                                return -1;
                            }
                        if (kind == LK_ATOMIC) sp = end;
                    } else memcpy(caps, old, sizeof(int64_t) * (size_t)ng2);
                    pc = in->x;
                } else {
                    memcpy(caps, old, sizeof(int64_t) * (size_t)ng2);
                    ok = 0;
                }
                if (old != snap) free(old);
                break;
            }
            default:
                if (rx_assert(X, in->op, sp)) pc++;
                else ok = 0;
        }
        if (ok) continue;
        /* Retroceder. */
        for (;;) {
            if (st->n <= base) return -1;
            bt_frame* f = &st->f[--st->n];
            if (f->kind == BT_CAP) caps[f->a] = f->b;
            else if (f->kind == BT_REG) regs[f->a] = f->b;
            else {
                pc = f->a;
                sp = f->b;
                break;
            }
        }
    }
}

/* ---------------------------------------------------------------- Pike VM */

typedef struct {
    int* pcs;       /* pc de cada hilo */
    int64_t* caps;  /* capturas de cada hilo (ngroups * 2) */
    int n;
} pk_list;

typedef struct { int kind; int pc; int slot; int64_t old; } pk_item;

typedef struct {
    rx_exec* X;
    int ncap;
    int* mark;        /* generación en que se visitó cada pc */
    int gen;
    pk_item* stack;
    int nstack, capstack;
} pk_vm;

static int pk_push(pk_vm* V, int kind, int pc, int slot, int64_t old) {
    if (V->nstack == V->capstack) {
        int c = V->capstack ? V->capstack * 2 : 256;
        pk_item* n = (pk_item*)realloc(V->stack, sizeof(pk_item) * (size_t)c);
        if (!n) return 0;
        V->stack = n;
        V->capstack = c;
    }
    pk_item* it = &V->stack[V->nstack++];
    it->kind = kind;
    it->pc = pc;
    it->slot = slot;
    it->old = old;
    return 1;
}

/* Añade a 'L' los hilos que salen de 'pc0' siguiendo las instrucciones sin consumo, en orden de prioridad. */
static int pk_add(pk_vm* V, pk_list* L, int pc0, int64_t sp, int64_t* caps) {
    rx_regex* re = V->X->re;
    V->nstack = 0;
    if (!pk_push(V, 0, pc0, 0, 0)) return 0;
    while (V->nstack > 0) {
        pk_item it = V->stack[--V->nstack];
        if (it.kind == 1) {
            caps[it.slot] = it.old;
            continue;
        }
        int pc = it.pc;
        if (V->mark[pc] == V->gen) continue;
        V->mark[pc] = V->gen;
        /* Tiempo lineal: sin presupuesto de pasos, solo el tiempo límite (si lo hay). */
        if (V->X->deadline && (++V->X->steps & 0xFFFF) == 0 && rx_now_ms() > V->X->deadline) {
            V->X->aborted = 1;
            return 0;
        }
        rx_inst* in = &re->prog[pc];
        switch (in->op) {
            case OP_JMP: if (!pk_push(V, 0, in->x, 0, 0)) return 0; break;
            case OP_SPLIT:
                if (!pk_push(V, 0, in->y, 0, 0) || !pk_push(V, 0, in->x, 0, 0)) return 0;
                break;
            case OP_SAVE:
                if (!pk_push(V, 1, 0, in->x, caps[in->x])) return 0;
                caps[in->x] = sp;
                if (!pk_push(V, 0, pc + 1, 0, 0)) return 0;
                break;
            case OP_SETPOS: case OP_PROGRESS:
                if (!pk_push(V, 0, pc + 1, 0, 0)) return 0;
                break;
            case OP_CHAR: case OP_ANY: case OP_ANYNL: case OP_CLASS: case OP_MATCH:
                L->pcs[L->n] = pc;
                memcpy(L->caps + (size_t)L->n * V->ncap, caps, sizeof(int64_t) * (size_t)V->ncap);
                L->n++;
                break;
            default:
                if (rx_assert(V->X, in->op, sp) && !pk_push(V, 0, pc + 1, 0, 0)) return 0;
        }
    }
    return 1;
}

static int pk_search(rx_exec* X, int64_t from, int64_t* out) {
    rx_regex* re = X->re;
    int ncap = re->ngroups * 2;
    int np = re->nprog;
    pk_vm V;
    memset(&V, 0, sizeof V);
    V.X = X;
    V.ncap = ncap;
    V.mark = (int*)calloc((size_t)np, sizeof(int));
    V.gen = 1;
    pk_list A, B;
    A.pcs = (int*)malloc(sizeof(int) * (size_t)np);
    B.pcs = (int*)malloc(sizeof(int) * (size_t)np);
    A.caps = (int64_t*)malloc(sizeof(int64_t) * (size_t)np * (size_t)ncap);
    B.caps = (int64_t*)malloc(sizeof(int64_t) * (size_t)np * (size_t)ncap);
    int64_t* tmp = (int64_t*)malloc(sizeof(int64_t) * (size_t)ncap);
    int matched = 0;
    if (!V.mark || !A.pcs || !B.pcs || !A.caps || !B.caps || !tmp) {
        X->aborted = 1;
        goto done;
    }
    A.n = B.n = 0;
    pk_list* cl = &A;
    pk_list* nl = &B;
    int64_t sp = from;
    for (;;) {
        if (!matched) {
            if (cl->n == 0) {
                /* Ningún hilo vivo: salta directamente a la siguiente posición posible. */
                if (re->anchored && sp != 0) break;
                if (re->first >= 0) {
                    if (sp >= X->len) break;
                    const void* q = memchr(X->s + sp, re->first, (size_t)(X->len - sp));
                    if (!q) break;
                    sp = (const uint8_t*)q - X->s;
                }
            }
            /* Hilo nuevo que empieza en 'sp', con la prioridad más baja (misma generación que
             * los hilos que ya hay en 'cl', para no repetir instrucciones). */
            if (!(re->anchored && sp != 0)) {
                for (int i = 0; i < ncap; i++) tmp[i] = -1;
                if (!pk_add(&V, cl, 0, sp, tmp)) goto done;
            }
        }
        if (cl->n == 0) {
            /* Ningún hilo, ni siquiera el nuevo (p. ej. un '^' que falla aquí): se prueba en el
             * carácter siguiente con una generación nueva. */
            if (matched || sp >= X->len) break;
            uint32_t c0;
            sp += rx_decode(X->s, X->len, sp, &c0);
            V.gen++;
            continue;
        }
        uint32_t c = 0;
        int clen = sp < X->len ? rx_decode(X->s, X->len, sp, &c) : 0;
        V.gen++;
        nl->n = 0;
        for (int i = 0; i < cl->n; i++) {
            int pc = cl->pcs[i];
            int64_t* tc = cl->caps + (size_t)i * ncap;
            rx_inst* in = &re->prog[pc];
            if (in->op == OP_MATCH) {
                memcpy(out, tc, sizeof(int64_t) * (size_t)ncap);
                matched = 1;
                break;   /* los hilos siguientes tienen menos prioridad */
            }
            if (clen && rx_consumes(re, in, c)) {
                memcpy(tmp, tc, sizeof(int64_t) * (size_t)ncap);
                if (!pk_add(&V, nl, pc + 1, sp + clen, tmp)) goto done;
            }
        }
        pk_list* t = cl;
        cl = nl;
        nl = t;
        if (!clen) break;
        sp += clen;
    }
done:
    free(V.mark);
    free(V.stack);
    free(A.pcs);
    free(B.pcs);
    free(A.caps);
    free(B.caps);
    free(tmp);
    return X->aborted ? -1 : matched;
}

/* ---------------------------------------------------------------- búsqueda */

/* Busca la primera coincidencia desde 'start'. 'caps' tiene ngroups * 2 posiciones (inicio,
 * fin; -1 si el grupo no participó). Devuelve 1 si hay coincidencia, 0 si no y -1 si se agotó
 * el presupuesto de pasos o el tiempo límite. maxSteps <= 0: presupuesto automático. */
int32_t faset_regex_match(void* p, rx_str text, int64_t start, int64_t* caps, int64_t maxSteps, int64_t timeoutMs) {
    rx_regex* re = (rx_regex*)p;
    rx_exec X;
    memset(&X, 0, sizeof X);
    X.re = re;
    X.s = text.ptr;
    X.len = text.len;
    X.start = start;
    X.budget = maxSteps > 0 ? maxSteps : 50000000 + 200 * text.len;
    X.deadline = timeoutMs > 0 ? rx_now_ms() + timeoutMs : 0;
    int ncap = re->ngroups * 2;
    if (start < 0 || start > text.len) return 0;
    if (!re->backtrack) {
        int64_t* out = (int64_t*)malloc(sizeof(int64_t) * (size_t)ncap);
        if (!out) return -1;
        int r = pk_search(&X, start, out);
        if (r == 1) memcpy(caps, out, sizeof(int64_t) * (size_t)ncap);
        free(out);
        return r;
    }
    bt_stack st = {0};
    int64_t* regs = (int64_t*)calloc((size_t)(re->nregs + 1), sizeof(int64_t));
    if (!regs) return -1;
    int32_t result = 0;
    for (int64_t sp = start; sp <= text.len; ) {
        if (re->anchored && sp != 0) break;
        if (re->first >= 0) {
            if (sp >= text.len) break;
            const void* q = memchr(text.ptr + sp, re->first, (size_t)(text.len - sp));
            if (!q) break;
            sp = (const uint8_t*)q - text.ptr;
        }
        for (int i = 0; i < ncap; i++) caps[i] = -1;
        for (int i = 0; i < re->nregs; i++) regs[i] = -1;
        st.n = 0;
        int64_t end = bt_run(&X, &st, 0, sp, caps, regs, -1);
        if (X.aborted) {
            result = -1;
            break;
        }
        if (end >= 0) {
            result = 1;
            break;
        }
        if (sp >= text.len) break;
        uint32_t c;
        sp += rx_decode(text.ptr, text.len, sp, &c);
    }
    free(st.f);
    free(regs);
    return result;
}
