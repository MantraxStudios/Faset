/* =============================================================================
 *  Faset - decodificación de imágenes para std.ui (clase Image).
 *
 *  El compilador añade este archivo a cualquier programa que use std.ui (en todas
 *  las plataformas: Linux, Windows y Android). Usa stb_image.h (dominio público,
 *  https://github.com/nothings/stb) para PNG, JPEG, BMP y GIF (primer fotograma).
 *
 *  Devuelve píxeles 0xAARRGGBB (alfa sin premultiplicar) en memoria de malloc que el
 *  llamador copia y libera con faset_image_free.
 * ============================================================================= */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#define STBI_NO_STDIO
#define STBI_FAILURE_USERMSG
#include "stb_image.h"

#include <stdint.h>
#include <stdlib.h>

/* RGBA (bytes) -> ARGB (uint32) en el mismo búfer. */
static uint32_t* to_argb(unsigned char* rgba, int w, int h) {
    uint32_t* px = (uint32_t*)rgba;
    long n = (long)w * h;
    for (long i = 0; i < n; i++) {
        unsigned char* p = rgba + i * 4;
        px[i] = ((uint32_t)p[3] << 24) | ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
    }
    return px;
}

/* Decodifica una imagen en memoria. NULL si el formato no es válido o no está soportado. */
uint32_t* faset_image_decode(const unsigned char* data, int64_t len, int32_t* w, int32_t* h) {
    int iw = 0, ih = 0, comp = 0;
    if (!data || len <= 0 || len > 0x7fffffff) return NULL;
    unsigned char* rgba = stbi_load_from_memory(data, (int)len, &iw, &ih, &comp, 4);
    if (!rgba) return NULL;
    *w = iw;
    *h = ih;
    return to_argb(rgba, iw, ih);
}

/* Motivo del último fallo (texto en inglés de stb_image). */
const char* faset_image_error(void) {
    const char* r = stbi_failure_reason();
    return r ? r : "";
}

void faset_image_free(void* p) { stbi_image_free(p); }
