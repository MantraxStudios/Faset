// Faset - runtime del azúcar sintáctico: concatenación de varias partes (cadenas interpoladas),
// alineación {x,10}, formatos numéricos {x:F2} / {n:D4} / {v:#,##0.00} y el panic de un 'switch'
// de expresión sin coincidencia.
#include "Runtime.h"

const char* const kRuntimeSugarHeader = R"FASET(
faset_string faset_str_concatv(int32_t n, const faset_string* parts);
faset_string faset_str_align(faset_string s, int32_t width);
faset_string faset_fmt_i64(int64_t v, int32_t bits, const char* fmt);
faset_string faset_fmt_u64(uint64_t v, int32_t bits, const char* fmt);
faset_string faset_fmt_f64(double v, int32_t isF32, const char* fmt);
FASET_NORETURN void faset_match_fail(faset_string shown, int32_t hasValue, const char* file, int32_t line);
)FASET";

// Se añade al final de kRuntimeSource (usa faset_str_alloc y los includes de allí).
const char* const kRuntimeSugarSource = R"FASET(
/* ---- azúcar: cadenas interpoladas y formatos */
#include <ctype.h>

faset_string faset_str_concatv(int32_t n, const faset_string* parts) {
    int64_t len = 0;
    for (int32_t i = 0; i < n; i++) len += parts[i].len;
    faset_string s = faset_str_alloc(len);
    int64_t at = 0;
    for (int32_t i = 0; i < n; i++) {
        if (parts[i].len) memcpy((void*)(s.ptr + at), parts[i].ptr, (size_t)parts[i].len);
        at += parts[i].len;
    }
    return s;
}

/* {x,10}: rellena con espacios a la izquierda; {x,-10}: a la derecha (en caracteres, no bytes). */
faset_string faset_str_align(faset_string s, int32_t width) {
    int64_t chars = 0;
    for (int64_t i = 0; i < s.len; i++) chars += (s.ptr[i] & 0xC0) != 0x80;
    int64_t w = width < 0 ? -(int64_t)width : width;
    if (chars >= w) return s;
    int64_t pad = w - chars;
    faset_string r = faset_str_alloc(s.len + pad);
    uint8_t* p = (uint8_t*)r.ptr;
    if (width > 0) {
        memset(p, ' ', (size_t)pad);
        if (s.len) memcpy(p + pad, s.ptr, (size_t)s.len);
    } else {
        if (s.len) memcpy(p, s.ptr, (size_t)s.len);
        memset(p + s.len, ' ', (size_t)pad);
    }
    return r;
}

/* Inserta separadores de miles en la parte entera de 'num' (solo dígitos, sin signo). */
static void faset_fmt_group(char* out, size_t cap, const char* num) {
    const char* dot = strchr(num, '.');
    size_t intLen = dot ? (size_t)(dot - num) : strlen(num);
    size_t o = 0;
    for (size_t i = 0; i < intLen && o + 2 < cap; i++) {
        out[o++] = num[i];
        size_t left = intLen - i - 1;
        if (left > 0 && left % 3 == 0) out[o++] = ',';
    }
    if (dot) for (const char* q = dot; *q && o + 1 < cap; q++) out[o++] = *q;
    out[o] = 0;
}

/* Formato estándar: letra + precisión opcional (D4, F2, N0, E3, X8, P1, G). */
static int faset_fmt_std(const char* f, char* spec, int* prec) {
    if (!isalpha((unsigned char)f[0])) return 0;
    size_t n = strlen(f);
    if (n > 3) return 0;
    for (size_t i = 1; i < n; i++) if (!isdigit((unsigned char)f[i])) return 0;
    *spec = f[0];
    *prec = n > 1 ? atoi(f + 1) : -1;
    return 1;
}

static faset_string faset_fmt_finish(int neg, const char* body, const char* suffix) {
    char buf[512];
    snprintf(buf, sizeof buf, "%s%s%s", neg ? "-" : "", body, suffix);
    return faset_str_from_buf(buf);
}

/* Exponencial al estilo C#: 1.234560E+003 (exponente de al menos 3 cifras). */
static faset_string faset_fmt_exp(double v, int prec, int lower) {
    char tmp[128], buf[160];
    snprintf(tmp, sizeof tmp, lower ? "%.*e" : "%.*E", prec < 0 ? 6 : prec, v);
    char* e = strchr(tmp, lower ? 'e' : 'E');
    if (!e) return faset_str_from_buf(tmp);
    int exp = atoi(e + 1);
    *e = 0;
    snprintf(buf, sizeof buf, "%s%c%c%03d", tmp, lower ? 'e' : 'E', exp < 0 ? '-' : '+', exp < 0 ? -exp : exp);
    return faset_str_from_buf(buf);
}

/* Formato personalizado: "0.00", "#,##0.0", "000", "0%", "#.##". */
static faset_string faset_fmt_custom(double v, const char* f) {
    int minInt = 0, minDec = 0, maxDec = 0, group = 0, pct = 0, afterDot = 0;
    for (const char* q = f; *q; q++) {
        if (*q == '.') afterDot = 1;
        else if (*q == ',' && !afterDot) group = 1;
        else if (*q == '%') pct = 1;
        else if (*q == '0') { if (afterDot) { minDec++; maxDec++; } else minInt++; }
        else if (*q == '#') { if (afterDot) maxDec++; }
    }
    if (pct) v *= 100.0;
    int neg = v < 0;
    double a = neg ? -v : v;
    char num[400];
    snprintf(num, sizeof num, "%.*f", maxDec, a);
    char* dot = strchr(num, '.');
    if (dot) {  /* quita ceros decimales opcionales ('#') */
        char* end = num + strlen(num) - 1;
        int decs = (int)(end - dot);
        while (decs > minDec && *end == '0') { *end-- = 0; decs--; }
        if (decs == 0) *dot = 0;
    }
    char ip[400];
    dot = strchr(num, '.');
    size_t intLen = dot ? (size_t)(dot - num) : strlen(num);
    size_t pad = (size_t)minInt > intLen ? (size_t)minInt - intLen : 0;
    size_t o = 0;
    for (size_t i = 0; i < pad && o + 1 < sizeof ip; i++) ip[o++] = '0';
    for (size_t i = 0; i < intLen && o + 1 < sizeof ip; i++) ip[o++] = num[i];
    ip[o] = 0;
    if (minInt == 0 && strcmp(ip, "0") == 0) ip[0] = 0;  /* "#.##" de 0,5 -> ".5" */
    char body[460];
    if (group) faset_fmt_group(body, sizeof body, ip); else snprintf(body, sizeof body, "%s", ip);
    if (dot) strncat(body, dot, sizeof body - strlen(body) - 1);
    if (body[0] == 0) snprintf(body, sizeof body, "0");
    int allZero = 1;
    for (const char* q = body; *q; q++) if (*q >= '1' && *q <= '9') allZero = 0;
    return faset_fmt_finish(neg && !allZero, body, pct ? "%" : "");
}

static faset_string faset_fmt_fixed(double v, int prec, int grouped, const char* suffix) {
    int neg = v < 0;
    char num[400], body[460];
    snprintf(num, sizeof num, "%.*f", prec, neg ? -v : v);
    if (grouped) faset_fmt_group(body, sizeof body, num); else snprintf(body, sizeof body, "%s", num);
    int allZero = 1;
    for (const char* q = body; *q; q++) if (*q >= '1' && *q <= '9') allZero = 0;
    return faset_fmt_finish(neg && !allZero, body, suffix);
}

faset_string faset_fmt_f64(double v, int32_t isF32, const char* f) {
    char spec;
    int prec;
    if (!faset_fmt_std(f, &spec, &prec)) return faset_fmt_custom(v, f);
    switch (spec) {
        case 'F': case 'f': return faset_fmt_fixed(v, prec < 0 ? 2 : prec, 0, "");
        case 'N': case 'n': return faset_fmt_fixed(v, prec < 0 ? 2 : prec, 1, "");
        case 'P': case 'p': return faset_fmt_fixed(v * 100.0, prec < 0 ? 2 : prec, 1, " %");
        case 'E': case 'e': return faset_fmt_exp(v, prec, spec == 'e');
        default: {  /* G */
            if (prec <= 0) return isF32 ? faset_f32_to_str((float)v) : faset_f64_to_str(v);
            char buf[128];
            snprintf(buf, sizeof buf, spec == 'g' ? "%.*g" : "%.*G", prec, v);
            return faset_str_from_buf(buf);
        }
    }
}

static faset_string faset_fmt_int(uint64_t mag, int neg, uint64_t bitsVal, int32_t bits, const char* f) {
    char spec;
    int prec;
    double dv = neg ? -(double)mag : (double)mag;
    if (!faset_fmt_std(f, &spec, &prec)) return faset_fmt_custom(dv, f);
    char num[128];
    switch (spec) {
        case 'D': case 'd':
            snprintf(num, sizeof num, "%0*llu", prec < 0 ? 1 : prec, (unsigned long long)mag);
            return faset_fmt_finish(neg, num, "");
        case 'X': case 'x': {
            uint64_t u = bits >= 64 ? bitsVal : (bitsVal & ((1ULL << bits) - 1));
            snprintf(num, sizeof num, spec == 'x' ? "%0*llx" : "%0*llX", prec < 0 ? 1 : prec, (unsigned long long)u);
            return faset_str_from_buf(num);
        }
        case 'N': case 'n': {
            char body[160];
            snprintf(num, sizeof num, "%llu", (unsigned long long)mag);
            faset_fmt_group(body, sizeof body, num);
            int p = prec < 0 ? 2 : prec;
            if (p > 0) {
                size_t l = strlen(body);
                body[l++] = '.';
                for (int i = 0; i < p && l + 1 < sizeof body; i++) body[l++] = '0';
                body[l] = 0;
            }
            return faset_fmt_finish(neg && mag != 0, body, "");
        }
        case 'F': case 'f': return faset_fmt_fixed(dv, prec < 0 ? 2 : prec, 0, "");
        case 'P': case 'p': return faset_fmt_fixed(dv * 100.0, prec < 0 ? 2 : prec, 1, " %");
        case 'E': case 'e': return faset_fmt_exp(dv, prec, spec == 'e');
        default:
            snprintf(num, sizeof num, "%llu", (unsigned long long)mag);
            return faset_fmt_finish(neg && mag != 0, num, "");
    }
}

faset_string faset_fmt_i64(int64_t v, int32_t bits, const char* f) {
    uint64_t mag = v < 0 ? 0 - (uint64_t)v : (uint64_t)v;
    return faset_fmt_int(mag, v < 0, (uint64_t)v, bits, f);
}

faset_string faset_fmt_u64(uint64_t v, int32_t bits, const char* f) { return faset_fmt_int(v, 0, v, bits, f); }

void faset_match_fail(faset_string shown, int32_t hasValue, const char* file, int32_t line) {
    if (hasValue) {
        faset_string parts[2] = { faset_str_from_cstr((const uint8_t*)"ningún brazo del 'switch' coincide con el valor "), shown };
        faset_panic_at(faset_str_concatv(2, parts), file, line);
    }
    faset_panic_at(faset_str_from_cstr((const uint8_t*)"ningún brazo del 'switch' coincide con el valor"), file, line);
}
)FASET";
