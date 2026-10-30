/* =============================================================================
 *  FasetStudio en Windows: rasterizado de fuentes con stb_truetype (dominio público,
 *  el mismo que usa el runtime de Android en lib/android/). En Linux, Font.fst usa
 *  FreeType; aquí no hay FreeType, así que estas funciones dan lo mismo que Font.fst
 *  necesita: métricas, avance y la cobertura (0..255) de cada glifo.
 * ============================================================================= */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "../../../lib/android/stb_truetype.h"

typedef struct {
    stbtt_fontinfo info;
    unsigned char* data;
    float scale;
} faset_stb_font;

/* Lee un archivo entero; la ruta es UTF-8 (se abre con _wfopen: admite carpetas con acentos). */
static unsigned char* read_all(const uint8_t* path) {
    int n = MultiByteToWideChar(CP_UTF8, 0, (const char*)path, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t* wpath = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (!wpath) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, (const char*)path, -1, wpath, n);
    FILE* f = _wfopen(wpath, L"rb");
    free(wpath);
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* d = size > 0 ? (unsigned char*)malloc((size_t)size) : NULL;
    if (d && fread(d, 1, (size_t)size, f) != (size_t)size) {
        free(d);
        d = NULL;
    }
    fclose(f);
    return d;
}

/* Abre una fuente TrueType/OpenType a 'px' píxeles por em (como FT_Set_Pixel_Sizes(0, px)).
 * Ascenso y descenso redondeados hacia fuera, como las métricas de FreeType. NULL si falla. */
void* faset_stb_open(const uint8_t* path, int32_t px, float* ascent, float* descent) {
    unsigned char* data = read_all(path);
    if (!data) return NULL;
    faset_stb_font* f = (faset_stb_font*)calloc(1, sizeof(faset_stb_font));
    int off = f ? stbtt_GetFontOffsetForIndex(data, 0) : -1;
    if (off < 0 || !stbtt_InitFont(&f->info, data, off)) {
        free(data);
        free(f);
        return NULL;
    }
    f->data = data;
    f->scale = stbtt_ScaleForMappingEmToPixels(&f->info, (float)px);
    int asc, desc, gap;
    stbtt_GetFontVMetrics(&f->info, &asc, &desc, &gap);
    *ascent = ceilf(asc * f->scale);
    *descent = ceilf(-desc * f->scale);
    return f;
}

/* ¿Tiene la fuente un glifo para el carácter? */
int32_t faset_stb_has(void* handle, uint32_t cp) {
    faset_stb_font* f = (faset_stb_font*)handle;
    return f && stbtt_FindGlyphIndex(&f->info, (int)cp) != 0;
}

/* Rasteriza un carácter. 'coverage' (w x h bytes) se reserva con malloc: libéralo con
 * faset_stb_free. El avance se redondea a píxeles enteros (como el hinting de FreeType). */
int32_t faset_stb_glyph(void* handle, uint32_t cp, uint8_t** coverage, int32_t* w, int32_t* h, int32_t* left,
                        int32_t* top, float* advance) {
    faset_stb_font* f = (faset_stb_font*)handle;
    *coverage = NULL;
    *w = *h = *left = *top = 0;
    *advance = 0;
    if (!f) return 0;
    int glyph = stbtt_FindGlyphIndex(&f->info, (int)cp);
    int adv, lsb;
    stbtt_GetGlyphHMetrics(&f->info, glyph, &adv, &lsb);
    *advance = floorf(adv * f->scale + 0.5f);
    int bw = 0, bh = 0, xoff = 0, yoff = 0;
    unsigned char* bmp = stbtt_GetGlyphBitmap(&f->info, f->scale, f->scale, glyph, &bw, &bh, &xoff, &yoff);
    if (!bmp || bw <= 0 || bh <= 0) {
        if (bmp) stbtt_FreeBitmap(bmp, NULL);
        return 1;
    }
    uint8_t* out = (uint8_t*)malloc((size_t)bw * bh);
    if (!out) {
        stbtt_FreeBitmap(bmp, NULL);
        return 0;
    }
    for (int i = 0; i < bw * bh; i++) out[i] = bmp[i];
    stbtt_FreeBitmap(bmp, NULL);
    *coverage = out;
    *w = bw;
    *h = bh;
    *left = xoff;
    *top = -yoff;
    return 1;
}

void faset_stb_free(void* p) { free(p); }
