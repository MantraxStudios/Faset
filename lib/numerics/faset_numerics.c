/* =============================================================================
 *  Faset - std.numerics: aritmética de BigInteger y Decimal.
 *
 *  El compilador añade este archivo a todo programa que use 'using std.numerics;'.
 *
 *  Magnitudes: arreglos de palabras de 32 bits, de la menos significativa a la más
 *  significativa (con productos intermedios de 64 bits: no hace falta __int128, así que
 *  sirve igual para 32 y 64 bits, Windows y Android). Faset reserva la memoria (del
 *  recolector) con el tamaño que indica cada función y aquí solo se escribe en ella.
 *
 *    suma / resta         lineales
 *    multiplicación       clásica y Karatsuba a partir de KARATSUBA_MIN palabras
 *    división             algoritmo D de Knuth (TAOCP vol. 2, 4.3.1)
 *    texto <-> número     por bloques de 9 dígitos decimales
 *
 *  Decimal (como System.Decimal de .NET): mantisa entera de 96 bits, escala 0..28 (número de
 *  cifras decimales) y signo. Cada operación se calcula exacta con hasta 256 bits y después
 *  se redondea al más cercano, con empates al par (banker's rounding), a lo que quepa en 96
 *  bits con escala <= 28. Si no cabe ni con escala 0, la operación desborda.
 * ============================================================================= */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

typedef struct { const uint8_t* ptr; int64_t len; } nm_str;

/* ---------------------------------------------------------------- magnitudes */

/* Longitud sin palabras altas a cero. */
static int nm_norm(const uint32_t* a, int n) {
    while (n > 0 && a[n - 1] == 0) n--;
    return n;
}

int32_t faset_big_cmp(const uint32_t* a, int32_t an, const uint32_t* b, int32_t bn) {
    an = nm_norm(a, an);
    bn = nm_norm(b, bn);
    if (an != bn) return an < bn ? -1 : 1;
    for (int i = an - 1; i >= 0; i--)
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return 0;
}

/* out = a + b (out: max(an, bn) + 1 palabras). Devuelve la longitud. */
int32_t faset_big_add(const uint32_t* a, int32_t an, const uint32_t* b, int32_t bn, uint32_t* out) {
    if (an < bn) {
        const uint32_t* t = a; a = b; b = t;
        int32_t tn = an; an = bn; bn = tn;
    }
    uint64_t carry = 0;
    for (int i = 0; i < an; i++) {
        carry += (uint64_t)a[i] + (i < bn ? b[i] : 0);
        out[i] = (uint32_t)carry;
        carry >>= 32;
    }
    out[an] = (uint32_t)carry;
    return nm_norm(out, an + 1);
}

/* out = a - b, con a >= b (out: an palabras). Devuelve la longitud. */
int32_t faset_big_sub(const uint32_t* a, int32_t an, const uint32_t* b, int32_t bn, uint32_t* out) {
    int64_t borrow = 0;
    for (int i = 0; i < an; i++) {
        int64_t d = (int64_t)a[i] - (i < bn ? b[i] : 0) - borrow;
        borrow = d < 0;
        out[i] = (uint32_t)(d + (borrow << 32));
    }
    return nm_norm(out, an);
}

/* x += y desde la palabra 0 (x tiene sitio para el acarreo). */
static void nm_add_into(uint32_t* x, int xn, const uint32_t* y, int yn) {
    uint64_t carry = 0;
    int i = 0;
    for (; i < yn; i++) {
        carry += (uint64_t)x[i] + y[i];
        x[i] = (uint32_t)carry;
        carry >>= 32;
    }
    for (; carry && i < xn; i++) {
        carry += x[i];
        x[i] = (uint32_t)carry;
        carry >>= 32;
    }
}

/* x -= y (x >= y). */
static void nm_sub_from(uint32_t* x, int xn, const uint32_t* y, int yn) {
    int64_t borrow = 0;
    int i = 0;
    for (; i < yn; i++) {
        int64_t d = (int64_t)x[i] - y[i] - borrow;
        borrow = d < 0;
        x[i] = (uint32_t)(d + (borrow << 32));
    }
    for (; borrow && i < xn; i++) {
        int64_t d = (int64_t)x[i] - borrow;
        borrow = d < 0;
        x[i] = (uint32_t)(d + (borrow << 32));
    }
}

static void nm_mul_school(const uint32_t* a, int an, const uint32_t* b, int bn, uint32_t* out) {
    memset(out, 0, sizeof(uint32_t) * (size_t)(an + bn));
    for (int i = 0; i < an; i++) {
        uint64_t carry = 0, ai = a[i];
        if (ai == 0) continue;
        for (int j = 0; j < bn; j++) {
            carry += ai * b[j] + out[i + j];
            out[i + j] = (uint32_t)carry;
            carry >>= 32;
        }
        out[i + bn] = (uint32_t)carry;
    }
}

#define KARATSUBA_MIN 40

/* out[0 .. an + bn) = a * b. Karatsuba: a = a1·B^m + a0, b = b1·B^m + b0 y
 * a·b = z2·B^2m + (z1 - z2 - z0)·B^m + z0, con z1 = (a0 + a1)(b0 + b1): 3 productos en vez de 4. */
static void nm_mul(const uint32_t* a, int an, const uint32_t* b, int bn, uint32_t* out) {
    if (an < bn) {
        const uint32_t* t = a; a = b; b = t;
        int tn = an; an = bn; bn = tn;
    }
    if (bn < KARATSUBA_MIN) {
        nm_mul_school(a, an, b, bn, out);
        return;
    }
    int m = (an + 1) / 2;
    if (bn <= m) {
        /* Muy desiguales: a0·b + (a1·b)·B^m. */
        uint32_t* t = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)(an - m + bn));
        nm_mul(a, m, b, bn, out);
        memset(out + m + bn, 0, sizeof(uint32_t) * (size_t)(an - m));
        nm_mul(a + m, an - m, b, bn, t);
        nm_add_into(out + m, an + bn - m, t, nm_norm(t, an - m + bn));
        free(t);
        return;
    }
    /* z0 en out[0, 2m) y z2 en out[2m, an + bn). */
    nm_mul(a, m, b, m, out);
    nm_mul(a + m, an - m, b + m, bn - m, out + 2 * m);
    uint32_t* sa = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)(4 * m + 4));
    uint32_t* sb = sa + (m + 1);
    uint32_t* z1 = sb + (m + 1);
    memcpy(sa, a, sizeof(uint32_t) * (size_t)m);
    sa[m] = 0;
    nm_add_into(sa, m + 1, a + m, an - m);
    memcpy(sb, b, sizeof(uint32_t) * (size_t)m);
    sb[m] = 0;
    nm_add_into(sb, m + 1, b + m, bn - m);
    nm_mul(sa, m + 1, sb, m + 1, z1);
    nm_sub_from(z1, 2 * m + 2, out, nm_norm(out, 2 * m));
    nm_sub_from(z1, 2 * m + 2, out + 2 * m, nm_norm(out + 2 * m, an + bn - 2 * m));
    nm_add_into(out + m, an + bn - m, z1, nm_norm(z1, 2 * m + 2));
    free(sa);
}

/* out = a * b (out: an + bn palabras). Devuelve la longitud. */
int32_t faset_big_mul(const uint32_t* a, int32_t an, const uint32_t* b, int32_t bn, uint32_t* out) {
    an = nm_norm(a, an);
    bn = nm_norm(b, bn);
    if (an == 0 || bn == 0) return 0;
    nm_mul(a, an, b, bn, out);
    return nm_norm(out, an + bn);
}

/* a = a * m + add, en su sitio (a tiene n palabras y sitio para una más). Devuelve la longitud. */
static int nm_mul_small_add(uint32_t* a, int n, uint32_t m, uint32_t add) {
    uint64_t carry = add;
    for (int i = 0; i < n; i++) {
        carry += (uint64_t)a[i] * m;
        a[i] = (uint32_t)carry;
        carry >>= 32;
    }
    if (carry) a[n++] = (uint32_t)carry;
    return n;
}

/* a /= d en su sitio; devuelve el resto. */
static uint32_t nm_div_small(uint32_t* a, int n, uint32_t d) {
    uint64_t r = 0;
    for (int i = n - 1; i >= 0; i--) {
        uint64_t cur = (r << 32) | a[i];
        a[i] = (uint32_t)(cur / d);
        r = cur % d;
    }
    return (uint32_t)r;
}

static int nm_clz(uint32_t x) {
    int n = 0;
    if (x == 0) return 32;
    while (!(x & 0x80000000u)) {
        x <<= 1;
        n++;
    }
    return n;
}

/* Cociente y resto: q = a / b (an - bn + 1 palabras), r = a % b (bn palabras). b != 0.
 * Devuelve la longitud del cociente y deja la del resto en *rn. */
int32_t faset_big_divmod(const uint32_t* a, int32_t an, const uint32_t* b, int32_t bn, uint32_t* q, uint32_t* r, int32_t* rn) {
    an = nm_norm(a, an);
    bn = nm_norm(b, bn);
    if (faset_big_cmp(a, an, b, bn) < 0) {
        memcpy(r, a, sizeof(uint32_t) * (size_t)an);
        *rn = an;
        return 0;
    }
    if (bn == 1) {
        memcpy(q, a, sizeof(uint32_t) * (size_t)an);
        uint32_t rem = nm_div_small(q, an, b[0]);
        r[0] = rem;
        *rn = rem ? 1 : 0;
        return nm_norm(q, an);
    }
    /* Normaliza: desplaza para que la palabra alta del divisor tenga el bit alto a 1. */
    int s = nm_clz(b[bn - 1]);
    uint32_t* un = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)(an + 1 + bn));
    uint32_t* vn = un + an + 1;
    for (int i = bn - 1; i > 0; i--) vn[i] = s ? (b[i] << s) | (b[i - 1] >> (32 - s)) : b[i];
    vn[0] = b[0] << s;
    un[an] = s ? a[an - 1] >> (32 - s) : 0;
    for (int i = an - 1; i > 0; i--) un[i] = s ? (a[i] << s) | (a[i - 1] >> (32 - s)) : a[i];
    un[0] = a[0] << s;
    for (int j = an - bn; j >= 0; j--) {
        uint64_t num = ((uint64_t)un[j + bn] << 32) | un[j + bn - 1];
        uint64_t qhat = num / vn[bn - 1];
        uint64_t rhat = num % vn[bn - 1];
        while (qhat >= 0x100000000ull || qhat * vn[bn - 2] > ((rhat << 32) | un[j + bn - 2])) {
            qhat--;
            rhat += vn[bn - 1];
            if (rhat >= 0x100000000ull) break;
        }
        /* un[j .. j + bn] -= qhat * vn */
        int64_t borrow = 0;
        uint64_t carry = 0;
        for (int i = 0; i < bn; i++) {
            uint64_t p = qhat * vn[i] + carry;
            carry = p >> 32;
            int64_t t = (int64_t)un[i + j] - (int64_t)(uint32_t)p - borrow;
            borrow = t < 0;
            un[i + j] = (uint32_t)(t + (borrow << 32));
        }
        int64_t t = (int64_t)un[j + bn] - (int64_t)carry - borrow;
        borrow = t < 0;
        un[j + bn] = (uint32_t)(t + (borrow << 32));
        if (borrow) {
            /* qhat era uno de más: se suma el divisor de vuelta. */
            qhat--;
            uint64_t c = 0;
            for (int i = 0; i < bn; i++) {
                c += (uint64_t)un[i + j] + vn[i];
                un[i + j] = (uint32_t)c;
                c >>= 32;
            }
            un[j + bn] += (uint32_t)c;
        }
        q[j] = (uint32_t)qhat;
    }
    for (int i = 0; i < bn; i++) r[i] = s ? (un[i] >> s) | (un[i + 1] << (32 - s)) : un[i];
    *rn = nm_norm(r, bn);
    free(un);
    return nm_norm(q, an - bn + 1);
}

/* Desplazamientos de bits: out = a << bits (an + bits/32 + 1 palabras) y a >> bits. */
int32_t faset_big_shl(const uint32_t* a, int32_t an, int32_t bits, uint32_t* out) {
    int w = bits / 32, s = bits % 32;
    memset(out, 0, sizeof(uint32_t) * (size_t)w);
    out[an + w] = 0;
    for (int i = an - 1; i >= 0; i--) {
        out[i + w + 1] |= s ? a[i] >> (32 - s) : 0;
        out[i + w] = a[i] << s;
    }
    return nm_norm(out, an + w + 1);
}

int32_t faset_big_shr(const uint32_t* a, int32_t an, int32_t bits, uint32_t* out) {
    int w = bits / 32, s = bits % 32;
    if (w >= an) return 0;
    int n = an - w;
    for (int i = 0; i < n; i++) {
        uint32_t lo = a[i + w] >> s;
        uint32_t hi = (s && i + w + 1 < an) ? a[i + w + 1] << (32 - s) : 0;
        out[i] = lo | hi;
    }
    return nm_norm(out, n);
}

/* Texto decimal de la magnitud (out: 10 * an + 1 bytes). Devuelve la longitud. */
int32_t faset_big_to_string(const uint32_t* a, int32_t an, uint8_t* out) {
    an = nm_norm(a, an);
    if (an == 0) {
        out[0] = '0';
        return 1;
    }
    uint32_t* t = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)an);
    memcpy(t, a, sizeof(uint32_t) * (size_t)an);
    /* Bloques de 9 cifras, del menos significativo al más significativo. */
    uint32_t* chunks = (uint32_t*)malloc(sizeof(uint32_t) * (size_t)(an * 10 / 9 + 2));
    int nc = 0, n = an;
    while (n > 0) {
        chunks[nc++] = nm_div_small(t, n, 1000000000u);
        n = nm_norm(t, n);
    }
    int len = sprintf((char*)out, "%u", chunks[nc - 1]);
    for (int i = nc - 2; i >= 0; i--) {
        uint32_t c = chunks[i];
        for (int k = 8; k >= 0; k--) {
            out[len + k] = (uint8_t)('0' + c % 10);
            c /= 10;
        }
        len += 9;
    }
    free(t);
    free(chunks);
    return len;
}

/* Magnitud de una cadena de cifras '0'..'9' (out: n / 9 + 2 palabras). Devuelve la longitud. */
int32_t faset_big_from_digits(const uint8_t* s, int64_t n, uint32_t* out) {
    int len = 0;
    int64_t i = 0;
    int first = (int)(n % 9);
    if (first == 0) first = 9;
    while (i < n) {
        int k = i == 0 ? first : 9;
        uint32_t chunk = 0, mul = 1;
        for (int j = 0; j < k; j++) {
            chunk = chunk * 10 + (uint32_t)(s[i + j] - '0');
            mul *= 10;
        }
        len = nm_mul_small_add(out, len, mul, chunk);
        len = nm_norm(out, len);
        i += k;
    }
    return len;
}

/* ---------------------------------------------------------------- Decimal */

#define DEC_W 8          /* palabras de trabajo: 256 bits */
#define DEC_MAXSCALE 28

/* Las banderas son las de .NET: escala en los bits 16..23 y signo en el bit 31. */
#define DEC_SCALE(f) (((f) >> 16) & 0xFF)
#define DEC_NEG(f) (((uint32_t)(f) >> 31) & 1)

typedef struct { uint32_t w[DEC_W]; int scale; int neg; } dec_t;

static void dec_load(dec_t* d, uint32_t lo, uint32_t mid, uint32_t hi, int32_t flags) {
    memset(d, 0, sizeof *d);
    d->w[0] = lo;
    d->w[1] = mid;
    d->w[2] = hi;
    d->scale = DEC_SCALE(flags);
    d->neg = DEC_NEG(flags);
}

static int dec_is_zero(const uint32_t* w) { return nm_norm(w, DEC_W) == 0; }

/* w *= 10^k (debe caber en 256 bits). */
static void dec_mul_pow10(uint32_t* w, int k) {
    while (k > 0) {
        int s = k > 9 ? 9 : k;
        uint32_t m = 1;
        for (int i = 0; i < s; i++) m *= 10;
        nm_mul_small_add(w, DEC_W - 1, m, 0);
        k -= s;
    }
}

/* p = 10^k en DEC_W palabras (k <= 77). */
static void dec_pow10(uint32_t* p, int k) {
    memset(p, 0, sizeof(uint32_t) * DEC_W);
    p[0] = 1;
    dec_mul_pow10(p, k);
}

/* Redondea al más cercano (empates al par) a 96 bits y escala <= 28, descartando al menos
 * 'minK' cifras. 'sticky': hay cifras distintas de cero, ya descartadas, por debajo de w
 * (deshace los empates hacia arriba). Si se redondeó, quita los ceros finales mientras la
 * escala sea mayor que 'stripTo'. Devuelve 0, o 1 si desborda. */
static int dec_finish_ex(dec_t* d, int sticky, int minK, int stripTo, uint32_t* lo, uint32_t* mid, uint32_t* hi, int32_t* flags) {
    int k = d->scale > DEC_MAXSCALE ? d->scale - DEC_MAXSCALE : 0;
    if (k < minK) k = minK;
    for (;; k++) {
        if (k == 0) {
            if (nm_norm(d->w, DEC_W) <= 3) break;
            continue;
        }
        if (k > d->scale) return 1;    /* ni con escala 0 cabe en 96 bits */
        uint32_t q[DEC_W + 1], r[DEC_W], p[DEC_W];
        int rn = 0;
        if (k > 77) {
            /* 10^k es mayor que cualquier valor de 256 bits: queda 0 */
            memset(d->w, 0, sizeof d->w);
            d->scale -= k;
            break;
        }
        dec_pow10(p, k);
        memset(q, 0, sizeof q);
        memset(r, 0, sizeof r);
        int qn = faset_big_divmod(d->w, DEC_W, p, DEC_W, q, r, &rn);
        /* resto * 2 frente a 10^k */
        uint32_t r2[DEC_W + 1];
        memset(r2, 0, sizeof r2);
        memcpy(r2, r, sizeof(uint32_t) * (size_t)rn);
        nm_mul_small_add(r2, DEC_W, 2, 0);
        int c = faset_big_cmp(r2, DEC_W + 1, p, DEC_W);
        if (c > 0 || (c == 0 && (sticky || (q[0] & 1)))) {
            uint32_t one = 1;
            nm_add_into(q, DEC_W + 1, &one, 1);
            qn = nm_norm(q, DEC_W + 1);
        }
        if (qn > 3) continue;   /* aún no cabe (o el redondeo pasó a 2^96): una cifra menos */
        memcpy(d->w, q, sizeof d->w);
        d->scale -= k;
        while (d->scale > stripTo && !dec_is_zero(d->w)) {
            uint32_t t[DEC_W];
            memcpy(t, d->w, sizeof t);
            if (nm_div_small(t, DEC_W, 10) != 0) break;
            memcpy(d->w, t, sizeof t);
            d->scale--;
        }
        break;
    }
    if (d->scale < 0) return 1;
    *lo = d->w[0];
    *mid = d->w[1];
    *hi = d->w[2];
    int neg = d->neg && !dec_is_zero(d->w);
    *flags = (int32_t)(((uint32_t)d->scale << 16) | ((uint32_t)neg << 31));
    return 0;
}

static int dec_finish(dec_t* d, int sticky, uint32_t* lo, uint32_t* mid, uint32_t* hi, int32_t* flags) {
    return dec_finish_ex(d, sticky, 0, 99, lo, mid, hi, flags);
}

/* Iguala las escalas multiplicando el de menor escala por 10^diferencia (cabe: 96 + 94 bits). */
static void dec_align(dec_t* a, dec_t* b) {
    if (a->scale < b->scale) {
        dec_mul_pow10(a->w, b->scale - a->scale);
        a->scale = b->scale;
    } else if (b->scale < a->scale) {
        dec_mul_pow10(b->w, a->scale - b->scale);
        b->scale = a->scale;
    }
}

/* Operaciones: 0 suma, 1 resta, 2 producto, 3 cociente, 4 resto (con el signo del dividendo).
 * Devuelve 0 si va bien, 1 si desborda y 2 si es una división por cero. */
int32_t faset_dec_op(int32_t op, uint32_t alo, uint32_t amid, uint32_t ahi, int32_t af, uint32_t blo, uint32_t bmid,
                     uint32_t bhi, int32_t bf, uint32_t* lo, uint32_t* mid, uint32_t* hi, int32_t* flags) {
    dec_t a, b, r;
    dec_load(&a, alo, amid, ahi, af);
    dec_load(&b, blo, bmid, bhi, bf);
    memset(&r, 0, sizeof r);
    if (op == 1) {
        b.neg = !b.neg;
        op = 0;
    }
    if (op == 0) {
        dec_align(&a, &b);
        r.scale = a.scale;
        if (a.neg == b.neg) {
            faset_big_add(a.w, DEC_W - 1, b.w, DEC_W - 1, r.w);
            r.neg = a.neg;
        } else if (faset_big_cmp(a.w, DEC_W, b.w, DEC_W) >= 0) {
            faset_big_sub(a.w, DEC_W, b.w, DEC_W, r.w);
            r.neg = a.neg;
        } else {
            faset_big_sub(b.w, DEC_W, a.w, DEC_W, r.w);
            r.neg = b.neg;
        }
        return dec_finish(&r, 0, lo, mid, hi, flags);
    }
    if (op == 2) {
        nm_mul(a.w, 3, b.w, 3, r.w);
        r.scale = a.scale + b.scale;
        r.neg = a.neg != b.neg;
        return dec_finish(&r, 0, lo, mid, hi, flags);
    }
    if (dec_is_zero(b.w)) return 2;
    uint32_t q[DEC_W + 1], rem[DEC_W];
    int rn = 0;
    if (op == 4) {
        dec_align(&a, &b);
        memset(rem, 0, sizeof rem);
        faset_big_divmod(a.w, DEC_W, b.w, DEC_W, q, rem, &rn);
        memcpy(r.w, rem, sizeof rem);
        r.scale = a.scale;
        r.neg = a.neg;
        return dec_finish(&r, 0, lo, mid, hi, flags);
    }
    /* Cociente: con escala a.scale - b.scale, y si no es exacto se añaden cifras mientras
     * quepan (como mucho escala 28); la última se redondea con el resto. */
    int scale = a.scale - b.scale;
    if (scale < 0) {
        dec_mul_pow10(a.w, -scale);
        scale = 0;
    }
    memset(q, 0, sizeof q);
    memset(rem, 0, sizeof rem);
    faset_big_divmod(a.w, DEC_W, b.w, DEC_W, q, rem, &rn);
    memcpy(r.w, q, sizeof r.w);
    r.neg = a.neg != b.neg;
    int sticky = 0;
    while (rn > 0 && scale < DEC_MAXSCALE) {
        /* ¿Cabe una cifra más? (q * 10 + 9 < 2^96) */
        uint32_t t[DEC_W];
        memcpy(t, r.w, sizeof t);
        nm_mul_small_add(t, DEC_W - 1, 10, 9);
        if (nm_norm(t, DEC_W) > 3) break;
        uint32_t r10[DEC_W + 1], dq[DEC_W + 1], dr[DEC_W];
        int drn = 0;
        memset(r10, 0, sizeof r10);
        memcpy(r10, rem, sizeof(uint32_t) * (size_t)rn);
        nm_mul_small_add(r10, DEC_W, 10, 0);
        memset(dq, 0, sizeof dq);
        memset(dr, 0, sizeof dr);
        faset_big_divmod(r10, DEC_W + 1, b.w, DEC_W, dq, dr, &drn);
        nm_mul_small_add(r.w, DEC_W - 1, 10, dq[0]);
        memset(rem, 0, sizeof rem);
        memcpy(rem, dr, sizeof(uint32_t) * (size_t)drn);
        rn = drn;
        scale++;
    }
    if (rn > 0) {
        /* Redondeo con el resto: una "cifra" de más (escala + 1) que dec_finish descarta. */
        uint32_t r10[DEC_W + 1], dq[DEC_W + 1], dr[DEC_W];
        int drn = 0;
        memset(r10, 0, sizeof r10);
        memcpy(r10, rem, sizeof(uint32_t) * (size_t)rn);
        nm_mul_small_add(r10, DEC_W, 10, 0);
        memset(dq, 0, sizeof dq);
        memset(dr, 0, sizeof dr);
        faset_big_divmod(r10, DEC_W + 1, b.w, DEC_W, dq, dr, &drn);
        nm_mul_small_add(r.w, DEC_W - 1, 10, dq[0]);
        scale++;
        sticky = drn > 0;
        r.scale = scale;
        /* Esa última cifra se descarta redondeando; si el redondeo deja ceros finales
         * (0,99..9 -> 1,00..0) se quitan hasta la escala inicial del cociente. */
        int base = a.scale - b.scale > 0 ? a.scale - b.scale : 0;
        return dec_finish_ex(&r, sticky, 1, base, lo, mid, hi, flags);
    }
    r.scale = scale;
    return dec_finish(&r, 0, lo, mid, hi, flags);
}

/* Comparación (-1, 0, 1); 1,0 y 1,00 son iguales. */
int32_t faset_dec_cmp(uint32_t alo, uint32_t amid, uint32_t ahi, int32_t af, uint32_t blo, uint32_t bmid, uint32_t bhi, int32_t bf) {
    dec_t a, b;
    dec_load(&a, alo, amid, ahi, af);
    dec_load(&b, blo, bmid, bhi, bf);
    int az = dec_is_zero(a.w), bz = dec_is_zero(b.w);
    if (az && bz) return 0;
    int as = az ? 0 : (a.neg ? -1 : 1), bs = bz ? 0 : (b.neg ? -1 : 1);
    if (as != bs) return as < bs ? -1 : 1;
    dec_align(&a, &b);
    int c = faset_big_cmp(a.w, DEC_W, b.w, DEC_W);
    return as < 0 ? -c : c;
}

/* Redondeo a 'decimals' cifras (0..28). mode: 0 al par, 1 alejándose de cero, 2 hacia cero,
 * 3 hacia -infinito, 4 hacia +infinito (los valores de MidpointRounding de .NET). */
int32_t faset_dec_round(uint32_t alo, uint32_t amid, uint32_t ahi, int32_t af, int32_t decimals, int32_t mode, uint32_t* lo,
                        uint32_t* mid, uint32_t* hi, int32_t* flags) {
    dec_t a;
    dec_load(&a, alo, amid, ahi, af);
    if (a.scale <= decimals) {
        *lo = alo;
        *mid = amid;
        *hi = ahi;
        *flags = af;
        return 0;
    }
    int k = a.scale - decimals;
    uint32_t p[DEC_W], q[DEC_W + 1], r[DEC_W], r2[DEC_W + 1];
    int rn = 0;
    dec_pow10(p, k);
    memset(q, 0, sizeof q);
    memset(r, 0, sizeof r);
    faset_big_divmod(a.w, DEC_W, p, DEC_W, q, r, &rn);
    int up = 0;
    if (rn > 0) {
        memset(r2, 0, sizeof r2);
        memcpy(r2, r, sizeof(uint32_t) * (size_t)rn);
        nm_mul_small_add(r2, DEC_W, 2, 0);
        int c = faset_big_cmp(r2, DEC_W + 1, p, DEC_W);
        switch (mode) {
            case 0: up = c > 0 || (c == 0 && (q[0] & 1)); break;
            case 1: up = c >= 0; break;
            case 2: up = 0; break;
            case 3: up = a.neg; break;
            case 4: up = !a.neg; break;
        }
    }
    if (up) {
        uint32_t one = 1;
        nm_add_into(q, DEC_W + 1, &one, 1);
    }
    memcpy(a.w, q, sizeof a.w);
    a.scale = decimals;
    return dec_finish(&a, 0, lo, mid, hi, flags);
}

/* Texto: "-123.4500" (out: al menos 40 bytes). Devuelve la longitud. */
int32_t faset_dec_to_string(uint32_t lo, uint32_t mid, uint32_t hi, int32_t f, uint8_t* out) {
    uint32_t w[3] = {lo, mid, hi};
    uint8_t digits[40];
    int n = faset_big_to_string(w, 3, digits);
    int scale = DEC_SCALE(f);
    int len = 0;
    if (DEC_NEG(f) && nm_norm(w, 3) > 0) out[len++] = '-';
    if (n <= scale) {
        out[len++] = '0';
        out[len++] = '.';
        for (int i = 0; i < scale - n; i++) out[len++] = '0';
        memcpy(out + len, digits, (size_t)n);
        len += n;
    } else {
        memcpy(out + len, digits, (size_t)(n - scale));
        len += n - scale;
        if (scale > 0) {
            out[len++] = '.';
            memcpy(out + len, digits + n - scale, (size_t)scale);
            len += scale;
        }
    }
    return len;
}

/* Lee un número: espacios, signo, cifras con '.' opcional y exponente opcional (e+3). Las
 * cifras que no caben se redondean (al par). Devuelve 0, 1 si desborda o 3 si no es un número. */
int32_t faset_dec_parse(nm_str s, uint32_t* lo, uint32_t* mid, uint32_t* hi, int32_t* flags) {
    const uint8_t* p = s.ptr;
    int64_t n = s.len, i = 0;
    while (i < n && (p[i] == ' ' || p[i] == '\t' || p[i] == '\n' || p[i] == '\r')) i++;
    while (n > i && (p[n - 1] == ' ' || p[n - 1] == '\t' || p[n - 1] == '\n' || p[n - 1] == '\r')) n--;
    dec_t d;
    memset(&d, 0, sizeof d);
    if (i < n && (p[i] == '+' || p[i] == '-')) d.neg = p[i++] == '-';
    /* Hasta 60 cifras significativas (caben en 200 bits); las demás solo cuentan para redondear. */
    int ndig = 0, any = 0, sticky = 0, point = 0;
    int64_t exp10 = 0;   /* valor = cifras * 10^exp10 */
    uint8_t extra = 0;   /* primera cifra descartada */
    int dropped = 0;
    for (; i < n; i++) {
        uint8_t c = p[i];
        if (c == '.' && !point) {
            point = 1;
            continue;
        }
        if (c < '0' || c > '9') break;
        any = 1;
        if (point) exp10--;
        if (ndig == 0 && c == '0') continue;
        if (ndig < 60) {
            nm_mul_small_add(d.w, DEC_W - 1, 10, (uint32_t)(c - '0'));
            ndig++;
        } else {
            if (!dropped) extra = c;
            else if (c != '0') sticky = 1;
            dropped++;
            exp10++;
        }
    }
    if (!any) return 3;
    if (i < n && (p[i] == 'e' || p[i] == 'E')) {
        i++;
        int eneg = 0;
        if (i < n && (p[i] == '+' || p[i] == '-')) eneg = p[i++] == '-';
        if (i >= n) return 3;
        int64_t e = 0;
        for (; i < n && p[i] >= '0' && p[i] <= '9'; i++)
            if (e < 100000) e = e * 10 + (p[i] - '0');
        exp10 += eneg ? -e : e;
    }
    if (i != n) return 3;
    if (dropped) {
        /* Se vuelve a poner la primera cifra descartada para que dec_finish redondee con ella. */
        nm_mul_small_add(d.w, DEC_W - 1, 10, (uint32_t)(extra - '0'));
        exp10--;
    }
    if (dec_is_zero(d.w)) {
        d.scale = exp10 < 0 ? (int)(-exp10 > DEC_MAXSCALE ? DEC_MAXSCALE : -exp10) : 0;
        d.neg = 0;
        return dec_finish(&d, 0, lo, mid, hi, flags);
    }
    if (exp10 > 0) {
        if (ndig + 1 + exp10 > 31) return 1;   /* >= 10^30: no cabe ni en 256 bits ni en un Decimal */
        dec_mul_pow10(d.w, (int)exp10);
        exp10 = 0;
    }
    if (-exp10 > 200) {
        /* Muy pequeño: es 0 con la escala máxima. */
        memset(d.w, 0, sizeof d.w);
        d.scale = DEC_MAXSCALE;
        d.neg = 0;
        return dec_finish(&d, 0, lo, mid, hi, flags);
    }
    d.scale = (int)-exp10;
    return dec_finish(&d, sticky, lo, mid, hi, flags);
}

/* double -> Decimal con 15 cifras significativas (como .NET). 1 si desborda o no es un número. */
int32_t faset_dec_from_double(double v, uint32_t* lo, uint32_t* mid, uint32_t* hi, int32_t* flags) {
    if (v != v || v > 7.9228162514264337593543950335e28 || v < -7.9228162514264337593543950335e28) return 1;
    char buf[64];
    snprintf(buf, sizeof buf, "%.14e", v);
    /* El separador decimal de printf depende de la configuración regional: se normaliza. */
    for (char* c = buf; *c; c++)
        if (*c == ',') *c = '.';
    /* Sin ceros finales en la mantisa: 0.1 -> "1.00000000000000e-01" -> 0.1, no 0.100000000000000. */
    char* e = strchr(buf, 'e');
    if (e) {
        char* z = e - 1;
        while (*z == '0') z--;
        if (*z == '.') z--;
        memmove(z + 1, e, strlen(e) + 1);
    }
    nm_str s = {(const uint8_t*)buf, (int64_t)strlen(buf)};
    int32_t rc = faset_dec_parse(s, lo, mid, hi, flags);
    if (rc == 0 && (*lo | *mid | *hi) == 0) *flags = 0;   /* 1e-30 -> 0 (sin escala) */
    return rc;
}

double faset_dec_to_double(uint32_t lo, uint32_t mid, uint32_t hi, int32_t f) {
    double m = (double)hi * 18446744073709551616.0 + (double)mid * 4294967296.0 + (double)lo;
    int scale = DEC_SCALE(f);
    double v = m / pow(10.0, scale);
    return DEC_NEG(f) ? -v : v;
}
