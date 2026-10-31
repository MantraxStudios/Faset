/* =============================================================================
 *  Faset - std.compression: Deflate (RFC 1951), zlib (RFC 1950) y gzip (RFC 1952).
 *
 *  El compilador añade este archivo a todo programa que use 'using std.compression;' y
 *  enlaza miniz (lib/compression/miniz, licencia MIT), compilado una sola vez por
 *  compilador y arquitectura. Las funciones trabajan con bloques completos en memoria:
 *  el resultado se reserva con el recolector de Faset (faset_alloc_atomic) y se devuelve
 *  por '*out'; los búferes intermedios son de malloc y se liberan aquí.
 *
 *  Formatos: 0 = Deflate sin cabecera, 1 = zlib, 2 = gzip.
 *  Resultados: longitud (>= 0) o -1 = datos no válidos / truncados, -2 = sin memoria,
 *  -3 = la suma de comprobación (CRC-32 / Adler-32) no coincide.
 * ============================================================================= */
#define MINIZ_NO_STDIO 1
#define MINIZ_NO_TIME 1
#define MINIZ_NO_ARCHIVE_APIS 1
#define MINIZ_NO_ZLIB_COMPATIBLE_NAMES 1
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "miniz/miniz.h"

void* faset_alloc_atomic(int64_t size);

/* Búfer de malloc que crece. */
typedef struct { uint8_t* p; size_t len, cap; } fc_buf;

static int fc_reserve(fc_buf* b, size_t need) {
    if (need <= b->cap) return 1;
    size_t c = b->cap ? b->cap : 4096;
    while (c < need) c *= 2;
    uint8_t* n = (uint8_t*)realloc(b->p, c);
    if (!n) return 0;
    b->p = n;
    b->cap = c;
    return 1;
}

static int fc_put(fc_buf* b, const void* d, size_t n) {
    if (!fc_reserve(b, b->len + n)) return 0;
    memcpy(b->p + b->len, d, n);
    b->len += n;
    return 1;
}

/* Copia el búfer a memoria del recolector y lo libera. */
static int64_t fc_finish(fc_buf* b, uint8_t** out) {
    uint8_t* r = (uint8_t*)faset_alloc_atomic((int64_t)b->len + 1);
    if (!r) {
        free(b->p);
        return -2;
    }
    if (b->len) memcpy(r, b->p, b->len);
    r[b->len] = 0;
    free(b->p);
    *out = r;
    return (int64_t)b->len;
}

uint32_t faset_crc32(uint32_t crc, const uint8_t* p, int64_t n) {
    return (uint32_t)mz_crc32((mz_ulong)crc, p, (size_t)n);
}

uint32_t faset_adler32(uint32_t adler, const uint8_t* p, int64_t n) {
    return (uint32_t)mz_adler32((mz_ulong)adler, p, (size_t)n);
}

/* Deflate (raw o zlib) de 'src' añadiendo a 'b'. */
static int fc_deflate_into(fc_buf* b, const uint8_t* src, int64_t n, int level, int zlib) {
    mz_stream s;
    memset(&s, 0, sizeof s);
    if (level < 0) level = MZ_DEFAULT_LEVEL;
    if (level > 10) level = 10;
    if (mz_deflateInit2(&s, level, MZ_DEFLATED, zlib ? MZ_DEFAULT_WINDOW_BITS : -MZ_DEFAULT_WINDOW_BITS, 9,
                        MZ_DEFAULT_STRATEGY) != MZ_OK)
        return -2;
    const uint8_t* in = src;
    int64_t unfed = n;  /* bytes que aún no se han dado a miniz (avail_in es de 32 bits) */
    for (;;) {
        if (s.avail_in == 0 && unfed > 0) {
            unsigned int chunk = unfed > 0x40000000 ? 0x40000000u : (unsigned int)unfed;
            s.next_in = in;
            s.avail_in = chunk;
            in += chunk;
            unfed -= chunk;
        }
        if (!fc_reserve(b, b->len + 65536)) {
            mz_deflateEnd(&s);
            return -2;
        }
        s.next_out = b->p + b->len;
        s.avail_out = (unsigned int)(b->cap - b->len);
        unsigned int before_out = s.avail_out;
        int status = mz_deflate(&s, unfed == 0 ? MZ_FINISH : MZ_NO_FLUSH);
        b->len += before_out - s.avail_out;
        if (status == MZ_STREAM_END) break;
        if (status != MZ_OK && status != MZ_BUF_ERROR) {
            mz_deflateEnd(&s);
            return -1;
        }
    }
    mz_deflateEnd(&s);
    return 0;
}

int64_t faset_deflate(const uint8_t* src, int64_t n, int32_t level, int32_t format, uint8_t** out) {
    fc_buf b = {0};
    *out = NULL;
    if (format == 2) {
        static const uint8_t hdr[10] = {0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255};
        uint8_t h[10];
        memcpy(h, hdr, 10);
        h[8] = level >= 9 ? 2 : (level == 1 ? 4 : 0);
        if (!fc_put(&b, h, 10)) return -2;
    }
    int r = fc_deflate_into(&b, src, n, level, format == 1);
    if (r != 0) {
        free(b.p);
        return r;
    }
    if (format == 2) {
        uint32_t crc = faset_crc32(0, src, n);
        uint32_t size = (uint32_t)n;
        uint8_t t[8] = {(uint8_t)crc, (uint8_t)(crc >> 8), (uint8_t)(crc >> 16), (uint8_t)(crc >> 24),
                        (uint8_t)size, (uint8_t)(size >> 8), (uint8_t)(size >> 16), (uint8_t)(size >> 24)};
        if (!fc_put(&b, t, 8)) {
            free(b.p);
            return -2;
        }
    }
    return fc_finish(&b, out);
}

/* Inflate (raw o zlib) desde 'src'; '*consumed' = bytes de entrada usados. */
static int fc_inflate_into(fc_buf* b, const uint8_t* src, int64_t n, int zlib, int64_t* consumed) {
    mz_stream s;
    memset(&s, 0, sizeof s);
    if (mz_inflateInit2(&s, zlib ? MZ_DEFAULT_WINDOW_BITS : -MZ_DEFAULT_WINDOW_BITS) != MZ_OK) return -2;
    const uint8_t* in = src;
    int64_t left = n;
    int status;
    for (;;) {
        if (s.avail_in == 0) {
            unsigned int chunk = left > 0x40000000 ? 0x40000000u : (unsigned int)left;
            s.next_in = in;
            s.avail_in = chunk;
        }
        if (!fc_reserve(b, b->len + 65536)) {
            mz_inflateEnd(&s);
            return -2;
        }
        s.next_out = b->p + b->len;
        s.avail_out = (unsigned int)(b->cap - b->len);
        unsigned int before_in = s.avail_in;
        unsigned int before_out = s.avail_out;
        status = mz_inflate(&s, MZ_SYNC_FLUSH);
        b->len += before_out - s.avail_out;
        unsigned int used = before_in - s.avail_in;
        in += used;
        left -= used;
        if (status == MZ_STREAM_END) break;
        if (status == MZ_BUF_ERROR && left == 0 && s.avail_in == 0 && before_out != s.avail_out) continue;
        if (status == MZ_DATA_ERROR && zlib) {
            mz_inflateEnd(&s);
            return -3;  /* (miniz también devuelve DATA_ERROR si el Adler-32 no coincide) */
        }
        if (status != MZ_OK) {
            mz_inflateEnd(&s);
            return -1;
        }
        if (used == 0 && before_out == s.avail_out && left == 0) {  /* sin progreso: truncado */
            mz_inflateEnd(&s);
            return -1;
        }
    }
    mz_inflateEnd(&s);
    if (consumed) *consumed = in - src;
    return 0;
}

int64_t faset_inflate(const uint8_t* src, int64_t n, int32_t format, uint8_t** out) {
    fc_buf b = {0};
    *out = NULL;
    if (format != 2) {
        int r = fc_inflate_into(&b, src, n, format == 1, NULL);
        if (r != 0) {
            free(b.p);
            return r == -3 ? -1 : r;
        }
        return fc_finish(&b, out);
    }
    /* gzip: uno o varios miembros seguidos (como 'cat a.gz b.gz'). */
    int64_t pos = 0;
    int members = 0;
    while (pos < n) {
        const uint8_t* p = src + pos;
        int64_t left = n - pos;
        if (members > 0 && left >= 1 && p[0] == 0) break;  /* relleno con ceros al final */
        if (left < 18 || p[0] != 0x1f || p[1] != 0x8b || p[2] != 8) {
            free(b.p);
            return -1;
        }
        int flg = p[3];
        int64_t h = 10;
        if (flg & 4) {  /* FEXTRA */
            if (left < h + 2) { free(b.p); return -1; }
            h += 2 + (p[h] | (p[h + 1] << 8));
        }
        if (flg & 8) { while (h < left && p[h]) h++; h++; }   /* FNAME */
        if (flg & 16) { while (h < left && p[h]) h++; h++; }  /* FCOMMENT */
        if (flg & 2) h += 2;                                  /* FHCRC */
        if (h + 8 > left) { free(b.p); return -1; }
        size_t start = b.len;
        int64_t used = 0;
        int r = fc_inflate_into(&b, p + h, left - h - 8, 0, &used);
        if (r != 0) {
            free(b.p);
            return r;
        }
        const uint8_t* t = p + h + used;
        if (t + 8 > src + n) { free(b.p); return -1; }
        uint32_t crc = (uint32_t)t[0] | ((uint32_t)t[1] << 8) | ((uint32_t)t[2] << 16) | ((uint32_t)t[3] << 24);
        uint32_t size = (uint32_t)t[4] | ((uint32_t)t[5] << 8) | ((uint32_t)t[6] << 16) | ((uint32_t)t[7] << 24);
        if (crc != faset_crc32(0, b.p + start, (int64_t)(b.len - start)) || size != (uint32_t)(b.len - start)) {
            free(b.p);
            return -3;
        }
        pos += h + used + 8;
        members++;
    }
    return fc_finish(&b, out);
}
