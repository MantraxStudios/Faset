/* =============================================================================
 *  Faset - std.audio: decodificación, mezclador y salida de sonido.
 *
 *  El compilador añade este archivo al programa cuando se usa 'using std.audio;'
 *  (ver src/main.cpp). Es C puro: el hilo de audio nunca llama a código de Faset ni
 *  guarda referencias a objetos de Faset (el recolector no lo ve); Faset solo guarda
 *  punteros opacos a memoria de C (malloc) e identificadores de voz.
 *
 *  Formatos:
 *    WAV  PCM de 8, 16, 24 y 32 bits, float de 32 y 64 bits (también WAVE_FORMAT_EXTENSIBLE)
 *    OGG  Vorbis con stb_vorbis (dominio público / MIT, Sean Barrett)
 *    MP3  con minimp3 (CC0, lieff)
 *
 *  Mezclador: un hilo propio mezcla en float todas las voces (volumen, panorama,
 *  bucle y velocidad con remuestreo lineal a la frecuencia del dispositivo), aplica el
 *  volumen general, convierte a 16 bits estéreo y escribe en el dispositivo. Los
 *  cambios de volumen, pausa y parada se suavizan durante un bloque (~10 ms) para que
 *  no se oigan chasquidos.
 *
 *  Salidas (se eligen solas, o con FASET_AUDIO_DRIVER / Audio.Open):
 *    Linux    pulse (libpulse-simple.so.0, también PipeWire) o alsa (libasound.so.2),
 *             las dos cargadas con dlopen: el programa arranca aunque no estén
 *    Windows  winmm (waveOut)
 *    Android  aaudio (libaaudio.so, API 26+, cargada con dlopen) u opensl (OpenSL ES)
 *    todos    null (sin sonido, el tiempo avanza) y offline (sin hilo: Audio.Render)
 *
 *  Música (Music): el archivo codificado se guarda en memoria y se decodifica poco a
 *  poco en el hilo de audio; cada reproducción tiene su propio decodificador.
 * ============================================================================= */
#if !defined(_WIN32)
#  define _GNU_SOURCE 1
#endif
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#  include <windows.h>
#  include <mmsystem.h>
#else
#  include <pthread.h>
#  include <time.h>
#  include <unistd.h>
#  include <dlfcn.h>
#endif
#if defined(__ANDROID__)
#  include <android/asset_manager.h>
#  include <android/log.h>
#  include <SLES/OpenSLES.h>
#  include <SLES/OpenSLES_Android.h>
#endif

#define STB_VORBIS_NO_STDIO 1
#define STB_VORBIS_NO_PUSHDATA_API 1
#include "stb_vorbis.c"
#undef L
#undef R
#undef C

/* minimp3 y stb_vorbis comparten algunos nombres de funciones estáticas. */
#define get_bits fa_mp3_get_bits
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"
#undef get_bits

/* Cadena de Faset (misma disposición que faset_string de faset_rt.h). */
typedef struct { const uint8_t* ptr; int64_t len; } fa_str;

#define FA_CHUNK 480          /* fotogramas por bloque del mezclador (10 ms a 48 kHz) */
#define FA_MAX_VOICES 256
#define FA_STREAM_WINDOW 4096 /* fotogramas decodificados por adelantado en la música */

/* ================================================================== hilos y errores */

#if defined(_WIN32)
typedef CRITICAL_SECTION fa_mutex;
static void fa_mutex_init(fa_mutex* m) { InitializeCriticalSection(m); }
static void fa_lock_m(fa_mutex* m) { EnterCriticalSection(m); }
static void fa_unlock_m(fa_mutex* m) { LeaveCriticalSection(m); }
static void fa_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
typedef pthread_mutex_t fa_mutex;
static void fa_mutex_init(fa_mutex* m) { pthread_mutex_init(m, NULL); }
static void fa_lock_m(fa_mutex* m) { pthread_mutex_lock(m); }
static void fa_unlock_m(fa_mutex* m) { pthread_mutex_unlock(m); }
static void fa_sleep_ms(int ms) {
    struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
}
#endif

static fa_mutex g_mx;

#if defined(_WIN32)
/* Sin InitOnce (exige _WIN32_WINNT >= 0x0600, que MinGW antiguo no define): 0 no, 1 en curso, 2 hecho. */
static volatile LONG g_once_state;
static void fa_global_init(void) {
    if (g_once_state == 2) return;
    if (InterlockedCompareExchange(&g_once_state, 1, 0) == 0) {
        fa_mutex_init(&g_mx);
        InterlockedExchange(&g_once_state, 2);
    } else {
        while (g_once_state != 2) Sleep(0);
    }
}
#else
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static void fa_once_fn(void) { fa_mutex_init(&g_mx); }
static void fa_global_init(void) { pthread_once(&g_once, fa_once_fn); }
#endif

static void fa_lock(void) { fa_global_init(); fa_lock_m(&g_mx); }
static void fa_unlock(void) { fa_unlock_m(&g_mx); }

static _Thread_local char t_error[512];

static void fa_set_error(const char* a, const char* b) {
    snprintf(t_error, sizeof t_error, "%s%s", a, b ? b : "");
}

const char* faset_audio_error(void) { return t_error; }

static void fa_log(const char* msg) {
#if defined(__ANDROID__)
    __android_log_print(ANDROID_LOG_WARN, "faset-audio", "%s", msg);
#else
    if (getenv("FASET_AUDIO_DEBUG")) fprintf(stderr, "faset-audio: %s\n", msg);
#endif
}

static char* fa_cstr(fa_str s) {
    char* p = (char*)malloc((size_t)s.len + 1);
    if (!p) return NULL;
    if (s.len) memcpy(p, s.ptr, (size_t)s.len);
    p[s.len] = 0;
    return p;
}

/* ================================================================== lectura de archivos */

#if defined(__ANDROID__)
static AAssetManager* g_assets;
/* La define lib/android/faset_android.c (débil: un programa sin esa capa sigue enlazando). */
extern AAssetManager* faset_android_asset_manager(void) __attribute__((weak));
#endif

static uint8_t* fa_read_file(const char* path, int64_t* outLen) {
    FILE* f = NULL;
#if defined(_WIN32)
    wchar_t wpath[1024];
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, 1024) > 0) f = _wfopen(wpath, L"rb");
#else
    f = fopen(path, "rb");
#endif
    if (!f) return NULL;
    size_t cap = 1 << 16, len = 0;
    uint8_t* buf = (uint8_t*)malloc(cap);
    for (;;) {
        if (!buf) break;
        if (len == cap) {
            uint8_t* nb = (uint8_t*)realloc(buf, cap * 2);
            if (!nb) {
                free(buf);
                buf = NULL;
                break;
            }
            buf = nb;
            cap *= 2;
        }
        size_t n = fread(buf + len, 1, cap - len, f);
        if (n == 0) break;
        len += n;
    }
    fclose(f);
    *outLen = (int64_t)len;
    return buf;
}

static int fa_is_absolute(const char* p) {
    if (p[0] == '/' || p[0] == '\\') return 1;
    return p[0] && p[1] == ':';
}

/* Carpeta del ejecutable con separador final ("" si no se sabe). */
static void fa_exe_dir(char* out, size_t cap) {
    out[0] = 0;
#if defined(_WIN32)
    wchar_t w[1024];
    DWORD n = GetModuleFileNameW(NULL, w, 1024);
    if (n == 0 || n >= 1024) return;
    if (WideCharToMultiByte(CP_UTF8, 0, w, -1, out, (int)cap, NULL, NULL) <= 0) {
        out[0] = 0;
        return;
    }
#elif defined(__linux__) && !defined(__ANDROID__)
    ssize_t n = readlink("/proc/self/exe", out, cap - 1);
    if (n <= 0) {
        out[0] = 0;
        return;
    }
    out[n] = 0;
#else
    return;
#endif
    char* slash = NULL;
    for (char* c = out; *c; c++)
        if (*c == '/' || *c == '\\') slash = c;
    if (slash) slash[1] = 0;
    else out[0] = 0;
}

/* Lee un recurso: la ruta tal cual (relativa a la carpeta actual), junto al
   ejecutable o, en Android, dentro del APK (assets/). */
static uint8_t* fa_read_source(const char* path, int64_t* outLen) {
    uint8_t* d = fa_read_file(path, outLen);
    if (d) return d;
    if (!fa_is_absolute(path)) {
        char dir[1024], full[2048];
        fa_exe_dir(dir, sizeof dir);
        if (dir[0]) {
            snprintf(full, sizeof full, "%s%s", dir, path);
            d = fa_read_file(full, outLen);
            if (d) return d;
        }
    }
#if defined(__ANDROID__)
    if (!g_assets && faset_android_asset_manager) g_assets = faset_android_asset_manager();
    if (g_assets && !fa_is_absolute(path)) {
        const char* name = path;
        while (name[0] == '.' && (name[1] == '/' || name[1] == '\\')) name += 2;
        AAsset* a = AAssetManager_open(g_assets, name, AASSET_MODE_BUFFER);
        if (a) {
            off_t n = AAsset_getLength(a);
            uint8_t* buf = (uint8_t*)malloc(n > 0 ? (size_t)n : 1);
            const void* src = buf ? AAsset_getBuffer(a) : NULL;
            if (src) memcpy(buf, src, (size_t)n);
            else if (buf && AAsset_read(a, buf, (size_t)n) != n) {
                free(buf);
                buf = NULL;
            }
            AAsset_close(a);
            if (buf) {
                *outLen = (int64_t)n;
                return buf;
            }
        }
    }
#endif
    return NULL;
}

/* ================================================================== decodificadores */

enum { FA_FMT_NONE = 0, FA_FMT_WAV = 1, FA_FMT_OGG = 2, FA_FMT_MP3 = 3 };

static uint32_t rd16(const uint8_t* p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8); }
static uint32_t rd32(const uint8_t* p) { return rd16(p) | (rd16(p + 2) << 16); }

/* Salta una etiqueta ID3v2 al principio de un MP3. */
static int64_t fa_id3_skip(const uint8_t* d, int64_t len) {
    if (len >= 10 && d[0] == 'I' && d[1] == 'D' && d[2] == '3') {
        int64_t size = ((int64_t)(d[6] & 0x7f) << 21) | ((d[7] & 0x7f) << 14) | ((d[8] & 0x7f) << 7) | (d[9] & 0x7f);
        size += 10 + ((d[5] & 0x10) ? 10 : 0);
        return size < len ? size : len;
    }
    return 0;
}

static int fa_detect(const uint8_t* d, int64_t len) {
    if (len >= 12 && !memcmp(d, "RIFF", 4) && !memcmp(d + 8, "WAVE", 4)) return FA_FMT_WAV;
    if (len >= 4 && !memcmp(d, "OggS", 4)) return FA_FMT_OGG;
    int64_t s = fa_id3_skip(d, len);
    if (s > 0) return FA_FMT_MP3;
    /* Sincronía de trama MPEG: 11 bits a 1, capa III (o II/I, que minimp3 también lee). */
    if (len >= 4 && d[0] == 0xff && (d[1] & 0xe0) == 0xe0 && (d[1] & 0x06) != 0) return FA_FMT_MP3;
    return FA_FMT_NONE;
}

typedef struct fa_dec {
    int fmt;
    int channels;     /* de salida: 1 o 2 */
    int rate;
    int64_t frames;   /* total (-1 si no se sabe) */
    int64_t pos;      /* siguiente fotograma que se va a decodificar */
    const uint8_t* data;
    int64_t len;
    /* WAV */
    const uint8_t* wdata;
    int64_t wframes;
    int wtag, wbits, wch, walign;
    /* OGG */
    stb_vorbis* vorbis;
    /* MP3 */
    mp3dec_t* mp3;
    int64_t moff, mstart;
    int16_t* mpcm;
    int mpcmFrames, mpcmIdx;
} fa_dec;

static int fa_wav_parse(fa_dec* d) {
    const uint8_t* p = d->data;
    int64_t len = d->len, off = 12;
    int haveFmt = 0;
    while (off + 8 <= len) {
        const uint8_t* ck = p + off;
        int64_t size = rd32(ck + 4);
        int64_t body = off + 8;
        if (!memcmp(ck, "fmt ", 4)) {
            if (size < 16 || body + 16 > len) break;
            d->wtag = (int)rd16(p + body);
            d->wch = (int)rd16(p + body + 2);
            d->rate = (int)rd32(p + body + 4);
            d->walign = (int)rd16(p + body + 12);
            d->wbits = (int)rd16(p + body + 14);
            if (d->wtag == 0xfffe && size >= 40 && body + 26 <= len) d->wtag = (int)rd16(p + body + 24);
            haveFmt = 1;
        } else if (!memcmp(ck, "data", 4)) {
            if (!haveFmt) {
                fa_set_error("WAV no válido: el bloque 'data' va antes de 'fmt '", NULL);
                return 0;
            }
            if (size > len - body) size = len - body; /* archivo truncado */
            d->wdata = p + body;
            if (d->walign <= 0) d->walign = d->wch * (d->wbits / 8);
            d->wframes = d->walign > 0 ? size / d->walign : 0;
            break;
        }
        off = body + size + (size & 1);
    }
    if (!haveFmt || !d->wdata) {
        fa_set_error("WAV no válido: faltan los bloques 'fmt ' o 'data'", NULL);
        return 0;
    }
    int okBits = (d->wtag == 1 && (d->wbits == 8 || d->wbits == 16 || d->wbits == 24 || d->wbits == 32)) ||
                 (d->wtag == 3 && (d->wbits == 32 || d->wbits == 64));
    if (!okBits) {
        char msg[96];
        snprintf(msg, sizeof msg, "formato %d con %d bits", d->wtag, d->wbits);
        fa_set_error("WAV no admitido (solo PCM de 8/16/24/32 bits o float de 32/64): ", msg);
        return 0;
    }
    if (d->wch < 1 || d->rate < 1000 || d->rate > 768000 || d->walign < d->wch * (d->wbits / 8)) {
        fa_set_error("WAV no válido: canales, frecuencia o alineación incorrectos", NULL);
        return 0;
    }
    d->channels = d->wch >= 2 ? 2 : 1;
    d->frames = d->wframes;
    return 1;
}

static int16_t fa_wav_sample(const fa_dec* d, const uint8_t* s) {
    switch (d->wbits) {
        case 8: return (int16_t)(((int)s[0] - 128) << 8);
        case 16: return (int16_t)rd16(s);
        case 24: return (int16_t)rd16(s + 1);
        case 32:
            if (d->wtag == 1) return (int16_t)rd16(s + 2);
            else {
                float f;
                uint32_t u = rd32(s);
                memcpy(&f, &u, 4);
                f = f * 32767.0f;
                if (!(f > -32768.0f)) f = -32768.0f; /* también NaN */
                if (f > 32767.0f) f = 32767.0f;
                return (int16_t)f;
            }
        default: {
            double f;
            uint64_t u = (uint64_t)rd32(s) | ((uint64_t)rd32(s + 4) << 32);
            memcpy(&f, &u, 8);
            f = f * 32767.0;
            if (!(f > -32768.0)) f = -32768.0;
            if (f > 32767.0) f = 32767.0;
            return (int16_t)f;
        }
    }
}

static int fa_mp3_frame(fa_dec* d) {
    mp3dec_frame_info_t info;
    for (;;) {
        if (d->moff >= d->len) return 0;
        int64_t rest = d->len - d->moff;
        int n = mp3dec_decode_frame(d->mp3, d->data + d->moff, rest > 0x7fffffff ? 0x7fffffff : (int)rest, d->mpcm, &info);
        if (info.frame_bytes <= 0) return 0;
        d->moff += info.frame_bytes;
        if (n <= 0) continue;
        /* Adapta los canales de la trama a los del flujo. */
        if (info.channels == 2 && d->channels == 1) {
            for (int i = 0; i < n; i++) d->mpcm[i] = (int16_t)(((int)d->mpcm[2 * i] + d->mpcm[2 * i + 1]) / 2);
        } else if (info.channels == 1 && d->channels == 2) {
            for (int i = n - 1; i >= 0; i--) d->mpcm[2 * i] = d->mpcm[2 * i + 1] = d->mpcm[i];
        }
        d->mpcmFrames = n;
        d->mpcmIdx = 0;
        return n;
    }
}

static void fa_dec_free(fa_dec* d) {
    if (!d) return;
    if (d->vorbis) stb_vorbis_close(d->vorbis);
    free(d->mp3);
    free(d->mpcm);
    free(d);
}

/* Abre un decodificador sobre datos en memoria (que deben vivir más que él). */
static fa_dec* fa_dec_open(const uint8_t* data, int64_t len) {
    fa_dec* d = (fa_dec*)calloc(1, sizeof(fa_dec));
    if (!d) {
        fa_set_error("sin memoria", NULL);
        return NULL;
    }
    d->data = data;
    d->len = len;
    d->frames = -1;
    d->fmt = fa_detect(data, len);
    switch (d->fmt) {
        case FA_FMT_WAV:
            if (fa_wav_parse(d)) return d;
            break;
        case FA_FMT_OGG: {
            int err = 0;
            if (len > 0x7fffffff) {
                fa_set_error("archivo OGG demasiado grande", NULL);
                break;
            }
            d->vorbis = stb_vorbis_open_memory(data, (int)len, &err, NULL);
            if (!d->vorbis) {
                char msg[32];
                snprintf(msg, sizeof msg, "%d", err);
                fa_set_error("OGG Vorbis no válido (error de stb_vorbis ", msg);
                strncat(t_error, ")", sizeof t_error - strlen(t_error) - 1);
                break;
            }
            stb_vorbis_info vi = stb_vorbis_get_info(d->vorbis);
            d->channels = vi.channels >= 2 ? 2 : 1;
            d->rate = (int)vi.sample_rate;
            unsigned int total = stb_vorbis_stream_length_in_samples(d->vorbis);
            d->frames = total ? (int64_t)total : -1;
            stb_vorbis_seek_start(d->vorbis);
            return d;
        }
        case FA_FMT_MP3: {
            d->mp3 = (mp3dec_t*)malloc(sizeof(mp3dec_t));
            d->mpcm = (int16_t*)malloc(sizeof(int16_t) * MINIMP3_MAX_SAMPLES_PER_FRAME);
            if (!d->mp3 || !d->mpcm) {
                fa_set_error("sin memoria", NULL);
                break;
            }
            d->mstart = fa_id3_skip(data, len);
            /* Primera trama: canales y frecuencia; luego se cuentan las muestras (sin decodificar). */
            mp3dec_init(d->mp3);
            mp3dec_frame_info_t info;
            int64_t off = d->mstart, total = 0;
            int first = 1;
            while (off < len) {
                int64_t rest = len - off;
                int n = mp3dec_decode_frame(d->mp3, data + off, rest > 0x7fffffff ? 0x7fffffff : (int)rest, NULL, &info);
                if (info.frame_bytes <= 0) break;
                if (first && n > 0) {
                    d->channels = info.channels >= 2 ? 2 : 1;
                    d->rate = info.hz;
                    first = 0;
                }
                off += info.frame_bytes;
                total += n;
            }
            if (first || d->rate <= 0) {
                fa_set_error("MP3 no válido: no se encontró ninguna trama", NULL);
                break;
            }
            d->frames = total;
            mp3dec_init(d->mp3);
            d->moff = d->mstart;
            return d;
        }
        default:
            fa_set_error("formato de audio desconocido (se admiten WAV, OGG Vorbis y MP3)", NULL);
            break;
    }
    fa_dec_free(d);
    return NULL;
}

/* Decodifica hasta 'frames' fotogramas (d->channels muestras cada uno). 0 = fin. */
static int fa_dec_read(fa_dec* d, int16_t* out, int frames) {
    int done = 0;
    switch (d->fmt) {
        case FA_FMT_WAV: {
            int64_t left = d->wframes - d->pos;
            if (left <= 0) return 0;
            if (frames > left) frames = (int)left;
            int bps = d->wbits / 8;
            for (int i = 0; i < frames; i++) {
                const uint8_t* f = d->wdata + (d->pos + i) * d->walign;
                out[i * d->channels] = fa_wav_sample(d, f);
                if (d->channels == 2) out[i * 2 + 1] = fa_wav_sample(d, f + bps);
            }
            done = frames;
            break;
        }
        case FA_FMT_OGG:
            done = stb_vorbis_get_samples_short_interleaved(d->vorbis, d->channels, out, frames * d->channels);
            break;
        case FA_FMT_MP3:
            while (done < frames) {
                if (d->mpcmIdx >= d->mpcmFrames && !fa_mp3_frame(d)) break;
                int n = d->mpcmFrames - d->mpcmIdx;
                if (n > frames - done) n = frames - done;
                memcpy(out + done * d->channels, d->mpcm + d->mpcmIdx * d->channels, sizeof(int16_t) * n * d->channels);
                d->mpcmIdx += n;
                done += n;
            }
            break;
    }
    d->pos += done;
    return done;
}

static void fa_dec_seek(fa_dec* d, int64_t frame) {
    if (frame < 0) frame = 0;
    if (d->frames >= 0 && frame > d->frames) frame = d->frames;
    switch (d->fmt) {
        case FA_FMT_WAV: d->pos = frame; break;
        case FA_FMT_OGG:
            if (frame == 0) stb_vorbis_seek_start(d->vorbis);
            else stb_vorbis_seek(d->vorbis, (unsigned int)frame);
            d->pos = frame;
            break;
        case FA_FMT_MP3: {
            /* Vuelve al principio y salta tramas sin decodificarlas. */
            mp3dec_init(d->mp3);
            d->moff = d->mstart;
            d->mpcmFrames = d->mpcmIdx = 0;
            int64_t at = 0;
            mp3dec_frame_info_t info;
            while (d->moff < d->len) {
                int64_t rest = d->len - d->moff;
                int n = mp3dec_decode_frame(d->mp3, d->data + d->moff, rest > 0x7fffffff ? 0x7fffffff : (int)rest, NULL, &info);
                if (info.frame_bytes <= 0) break;
                if (n > 0 && at + n > frame) break; /* esta trama contiene el destino */
                d->moff += info.frame_bytes;
                at += n;
            }
            d->pos = at;
            int16_t skip[256 * 2];
            while (d->pos < frame) {
                int want = (int)(frame - d->pos < 256 ? frame - d->pos : 256);
                if (fa_dec_read(d, skip, want) <= 0) break;
            }
            break;
        }
    }
}

/* ================================================================== fuentes (Sound y Music) */

typedef struct fa_source {
    int refs;          /* Faset + una por voz; protegido por g_mx */
    int stream;        /* 0 Sound (PCM en memoria), 1 Music (archivo codificado) */
    int channels, rate;
    int64_t frames;
    int16_t* pcm;      /* Sound */
    uint8_t* blob;     /* Music */
    int64_t blobLen;
    float gain;        /* volumen propio (Sound.Volume / Music.Volume) */
} fa_source;

static void fa_source_free(fa_source* s) {
    free(s->pcm);
    free(s->blob);
    free(s);
}

/* Requiere g_mx. */
static void fa_source_unref_locked(fa_source* s) {
    if (--s->refs == 0) fa_source_free(s);
}

/* Decodifica todo a PCM de 16 bits. Toma posesión de 'blob'. */
static fa_source* fa_sound_from_blob(uint8_t* blob, int64_t len) {
    fa_dec* d = fa_dec_open(blob, len);
    if (!d) {
        free(blob);
        return NULL;
    }
    int64_t cap = d->frames > 0 ? d->frames : 65536, n = 0;
    int16_t* pcm = (int16_t*)malloc(sizeof(int16_t) * (size_t)(cap * d->channels + 1));
    for (;;) {
        if (!pcm) break;
        if (n == cap) {
            cap *= 2;
            int16_t* np = (int16_t*)realloc(pcm, sizeof(int16_t) * (size_t)(cap * d->channels));
            if (!np) {
                free(pcm);
                pcm = NULL;
                break;
            }
            pcm = np;
        }
        int want = (int)(cap - n > 65536 ? 65536 : cap - n);
        int got = fa_dec_read(d, pcm + n * d->channels, want);
        if (got <= 0) break;
        n += got;
    }
    fa_source* s = pcm ? (fa_source*)calloc(1, sizeof(fa_source)) : NULL;
    if (!s) {
        fa_set_error("sin memoria para decodificar el sonido", NULL);
        free(pcm);
        fa_dec_free(d);
        free(blob);
        return NULL;
    }
    s->refs = 1;
    s->channels = d->channels;
    s->rate = d->rate;
    s->frames = n;
    s->pcm = pcm;
    s->gain = 1;
    fa_dec_free(d);
    free(blob);
    return s;
}

static fa_source* fa_music_from_blob(uint8_t* blob, int64_t len) {
    fa_dec* d = fa_dec_open(blob, len);
    if (!d) {
        free(blob);
        return NULL;
    }
    fa_source* s = (fa_source*)calloc(1, sizeof(fa_source));
    if (!s) {
        fa_dec_free(d);
        free(blob);
        return NULL;
    }
    s->refs = 1;
    s->stream = 1;
    s->channels = d->channels;
    s->rate = d->rate;
    s->frames = d->frames;
    s->blob = blob;
    s->blobLen = len;
    s->gain = 1;
    fa_dec_free(d);
    return s;
}

static uint8_t* fa_copy_bytes(const uint8_t* data, int64_t len) {
    uint8_t* b = (uint8_t*)malloc(len > 0 ? (size_t)len : 1);
    if (b && len > 0) memcpy(b, data, (size_t)len);
    if (!b) fa_set_error("sin memoria", NULL);
    return b;
}

static uint8_t* fa_load_path(fa_str path, int64_t* len) {
    char* p = fa_cstr(path);
    if (!p) return NULL;
    uint8_t* b = fa_read_source(p, len);
    if (!b) fa_set_error("no se puede leer el archivo de audio: ", p);
    free(p);
    return b;
}

void* faset_sound_load(fa_str path) {
    t_error[0] = 0;
    int64_t len = 0;
    uint8_t* b = fa_load_path(path, &len);
    return b ? fa_sound_from_blob(b, len) : NULL;
}

void* faset_sound_from_memory(const uint8_t* data, int64_t len) {
    t_error[0] = 0;
    uint8_t* b = fa_copy_bytes(data, len);
    return b ? fa_sound_from_blob(b, len) : NULL;
}

/* Muestras float (-1..1) entrelazadas. */
void* faset_sound_from_samples(const float* samples, int64_t frames, int32_t channels, int32_t rate) {
    t_error[0] = 0;
    if (channels < 1 || channels > 2 || rate < 1000 || rate > 768000 || frames < 0) {
        fa_set_error("Sound.FromSamples: se esperan 1 o 2 canales y una frecuencia entre 1000 y 768000 Hz", NULL);
        return NULL;
    }
    fa_source* s = (fa_source*)calloc(1, sizeof(fa_source));
    int16_t* pcm = (int16_t*)malloc(sizeof(int16_t) * (size_t)(frames * channels + 1));
    if (!s || !pcm) {
        free(s);
        free(pcm);
        fa_set_error("sin memoria", NULL);
        return NULL;
    }
    for (int64_t i = 0; i < frames * channels; i++) {
        float f = samples[i] * 32767.0f;
        if (!(f > -32768.0f)) f = -32768.0f;
        if (f > 32767.0f) f = 32767.0f;
        pcm[i] = (int16_t)f;
    }
    s->refs = 1;
    s->channels = channels;
    s->rate = rate;
    s->frames = frames;
    s->pcm = pcm;
    s->gain = 1;
    return s;
}

void* faset_music_load(fa_str path) {
    t_error[0] = 0;
    int64_t len = 0;
    uint8_t* b = fa_load_path(path, &len);
    return b ? fa_music_from_blob(b, len) : NULL;
}

void* faset_music_from_memory(const uint8_t* data, int64_t len) {
    t_error[0] = 0;
    uint8_t* b = fa_copy_bytes(data, len);
    return b ? fa_music_from_blob(b, len) : NULL;
}

int64_t faset_source_frames(void* s) { return ((fa_source*)s)->frames; }
int32_t faset_source_channels(void* s) { return ((fa_source*)s)->channels; }
int32_t faset_source_rate(void* s) { return ((fa_source*)s)->rate; }
void faset_source_set_gain(void* s, float g) {
    fa_lock();
    ((fa_source*)s)->gain = g < 0 ? 0 : g;
    fa_unlock();
}

/* Muestra de un Sound (para pruebas y análisis): canal 'ch' del fotograma 'i', -1..1. */
float faset_sound_sample(void* s, int64_t i, int32_t ch) {
    fa_source* src = (fa_source*)s;
    if (!src->pcm || i < 0 || i >= src->frames || ch < 0) return 0;
    if (ch >= src->channels) ch = src->channels - 1;
    return src->pcm[i * src->channels + ch] / 32768.0f;
}

/* ================================================================== voces y mezclador */

typedef struct fa_voice {
    int used;
    uint32_t gen;
    fa_source* src;
    double pos;                 /* Sound: fotograma; Music: fotograma "virtual" (crece al repetir) */
    float volume, pan, speed;
    int loop, paused, stopping, finished;
    float gl, gr;               /* ganancias aplicadas en el último bloque */
    int started;
    /* Music */
    fa_dec* dec;
    int16_t* win;               /* ventana de fotogramas decodificados */
    int64_t winStart;           /* fotograma virtual de win[0] */
    int winLen;
    int eof;
    int64_t base, prevBase;     /* fotograma virtual donde empezó la vuelta actual (y la anterior) */
} fa_voice;

static fa_voice g_voices[FA_MAX_VOICES];
static float g_master = 1.0f;
static int g_paused_all;
static int g_out_rate = 48000;

static int64_t fa_voice_id(int slot) { return ((int64_t)g_voices[slot].gen << 16) | (int64_t)(slot + 1); }

/* Requiere g_mx. */
static fa_voice* fa_find(int64_t id) {
    int slot = (int)(id & 0xffff) - 1;
    if (slot < 0 || slot >= FA_MAX_VOICES) return NULL;
    fa_voice* v = &g_voices[slot];
    if (!v->used || v->gen != (uint32_t)(id >> 16)) return NULL;
    return v;
}

/* Requiere g_mx. */
static void fa_voice_free_locked(fa_voice* v) {
    if (v->dec) fa_dec_free(v->dec);
    free(v->win);
    fa_source_unref_locked(v->src);
    uint32_t gen = v->gen;
    memset(v, 0, sizeof *v);
    v->gen = gen + 1;
}

static void fa_targets(const fa_voice* v, float* tl, float* tr) {
    float g = (v->paused || v->stopping || g_paused_all) ? 0.0f : v->volume * v->src->gain * g_master;
    float pan = v->pan < -1 ? -1 : (v->pan > 1 ? 1 : v->pan);
    /* Panorama de potencia constante (en el centro, las dos salidas a 0.707 normalizadas a 1). */
    float a = (pan + 1) * 0.25f * 3.14159265f;
    *tl = g * cosf(a) * 1.41421356f;
    *tr = g * sinf(a) * 1.41421356f;
    if (*tl > g) *tl = g;
    if (*tr > g) *tr = g;
}

/* Fotograma 'idx' de la música (rellena la ventana si hace falta). Requiere g_mx. */
static void fa_stream_frame(fa_voice* v, int64_t idx, float* l, float* r) {
    int ch = v->src->channels;
    while (idx >= v->winStart + v->winLen && !v->eof) {
        /* Descarta lo ya reproducido y decodifica más. */
        int64_t keep = (int64_t)floor(v->pos);
        if (keep > idx) keep = idx;
        int64_t drop = keep - v->winStart;
        if (drop > v->winLen) drop = v->winLen;
        if (drop > 0) {
            memmove(v->win, v->win + drop * ch, sizeof(int16_t) * (size_t)((v->winLen - drop) * ch));
            v->winLen -= (int)drop;
            v->winStart += drop;
        }
        if (v->winLen >= FA_STREAM_WINDOW) { /* no debería pasar: ventana llena sin llegar a idx */
            v->winStart += v->winLen;
            v->winLen = 0;
        }
        int got = fa_dec_read(v->dec, v->win + v->winLen * ch, FA_STREAM_WINDOW - v->winLen);
        if (got > 0) {
            v->winLen += got;
        } else if (v->loop && v->dec->pos > 0) {
            fa_dec_seek(v->dec, 0);
            v->prevBase = v->base;
            v->base = v->winStart + v->winLen;
        } else {
            v->eof = 1;
        }
    }
    int64_t k = idx - v->winStart;
    if (k < 0 || k >= v->winLen) {
        *l = *r = 0;
        return;
    }
    const int16_t* f = v->win + k * ch;
    *l = f[0] * (1.0f / 32768.0f);
    *r = ch == 2 ? f[1] * (1.0f / 32768.0f) : *l;
}

/* Mezcla una voz en 'out' (estéreo). Requiere g_mx. */
static void fa_mix_voice(fa_voice* v, float* out, int frames) {
    float tl, tr;
    fa_targets(v, &tl, &tr);
    if (!v->started) {
        v->gl = tl;
        v->gr = tr;
        v->started = 1;
    }
    if (v->gl == 0 && v->gr == 0 && tl == 0 && tr == 0) {
        if (v->stopping) v->finished = 1;
        return; /* en pausa (o silencio): no avanza */
    }
    fa_source* s = v->src;
    double step = (double)s->rate * (v->speed > 0.01f ? v->speed : 0.01f) / (double)g_out_rate;
    float dl = (tl - v->gl) / frames, dr = (tr - v->gr) / frames;
    float gl = v->gl, gr = v->gr;
    int ch = s->channels;
    for (int i = 0; i < frames; i++) {
        gl += dl;
        gr += dr;
        int64_t i0 = (int64_t)v->pos;
        float t = (float)(v->pos - (double)i0);
        float l0, r0, l1, r1;
        if (!s->stream) {
            if (i0 >= s->frames) {
                if (v->loop && s->frames > 0) {
                    v->pos -= (double)s->frames * floor(v->pos / (double)s->frames);
                    i0 = (int64_t)v->pos;
                    t = (float)(v->pos - (double)i0);
                } else {
                    v->finished = 1;
                    break;
                }
            }
            int64_t i1 = i0 + 1;
            if (i1 >= s->frames) i1 = v->loop ? 0 : i0;
            const int16_t* a = s->pcm + i0 * ch;
            const int16_t* b = s->pcm + i1 * ch;
            l0 = a[0] * (1.0f / 32768.0f);
            r0 = ch == 2 ? a[1] * (1.0f / 32768.0f) : l0;
            l1 = b[0] * (1.0f / 32768.0f);
            r1 = ch == 2 ? b[1] * (1.0f / 32768.0f) : l1;
        } else {
            if (v->eof && i0 >= v->winStart + v->winLen) {
                v->finished = 1;
                break;
            }
            fa_stream_frame(v, i0, &l0, &r0);
            fa_stream_frame(v, i0 + 1, &l1, &r1);
        }
        out[2 * i] += (l0 + (l1 - l0) * t) * gl;
        out[2 * i + 1] += (r0 + (r1 - r0) * t) * gr;
        v->pos += step;
    }
    v->gl = tl;
    v->gr = tr;
    if (v->stopping && tl == 0 && tr == 0) v->finished = 1;
}

/* Mezcla un bloque de todas las voces. */
static void fa_mix(float* out, int frames) {
    memset(out, 0, sizeof(float) * 2 * (size_t)frames);
    fa_lock();
    for (int i = 0; i < FA_MAX_VOICES; i++) {
        fa_voice* v = &g_voices[i];
        if (!v->used) continue;
        if (!v->finished) fa_mix_voice(v, out, frames);
        if (v->finished) fa_voice_free_locked(v);
    }
    fa_unlock();
}

static void fa_to_s16(const float* in, int16_t* out, int samples) {
    for (int i = 0; i < samples; i++) {
        float f = in[i] * 32767.0f;
        if (!(f > -32768.0f)) f = -32768.0f;
        if (f > 32767.0f) f = 32767.0f;
        out[i] = (int16_t)lrintf(f);
    }
}

/* ================================================================== salidas */

typedef struct fa_backend {
    const char* name;
    int (*open)(int* rate);         /* 1 = abierto; puede cambiar la frecuencia */
    int (*write)(const int16_t* pcm, int frames); /* bloquea hasta que hay sitio; 0 = error */
    void (*close)(void);
} fa_backend;

static int null_open(int* rate) { return 1; }
static int null_write(const int16_t* pcm, int frames) {
    fa_sleep_ms(frames * 1000 / g_out_rate);
    return 1;
}
static void null_close(void) {}
static const fa_backend b_null = {"null", null_open, null_write, null_close};

#if defined(__linux__) && !defined(__ANDROID__)
/* ---- PulseAudio (API simple) */
typedef struct { int format; uint32_t rate; uint8_t channels; } fa_pa_spec;
typedef struct { uint32_t maxlength, tlength, prebuf, minreq, fragsize; } fa_pa_attr;
static void* pa_lib;
static void* pa_handle;
static void* (*p_pa_simple_new)(const char*, const char*, int, const char*, const char*, const fa_pa_spec*, const void*,
                                const fa_pa_attr*, int*);
static int (*p_pa_simple_write)(void*, const void*, size_t, int*);
static void (*p_pa_simple_free)(void*);
static const char* (*p_pa_strerror)(int);

static int pulse_open(int* rate) {
    if (!pa_lib) pa_lib = dlopen("libpulse-simple.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!pa_lib) return 0;
    p_pa_simple_new = dlsym(pa_lib, "pa_simple_new");
    p_pa_simple_write = dlsym(pa_lib, "pa_simple_write");
    p_pa_simple_free = dlsym(pa_lib, "pa_simple_free");
    void* core = dlopen("libpulse.so.0", RTLD_NOW | RTLD_LOCAL);
    p_pa_strerror = core ? dlsym(core, "pa_strerror") : NULL;
    if (!p_pa_simple_new || !p_pa_simple_write || !p_pa_simple_free) return 0;
    fa_pa_spec ss = {3 /* PA_SAMPLE_S16LE */, (uint32_t)*rate, 2};
    uint32_t bytesPerMs = (uint32_t)*rate * 4 / 1000;
    fa_pa_attr attr = {(uint32_t)-1, bytesPerMs * 40, (uint32_t)-1, bytesPerMs * 10, (uint32_t)-1};
    const char* app = getenv("FASET_AUDIO_APP");
    char exe[1024] = "Faset";
#if defined(__linux__)
    if (!app) {
        ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
        if (n > 0) {
            exe[n] = 0;
            char* slash = strrchr(exe, '/');
            if (slash) memmove(exe, slash + 1, strlen(slash));
        } else strcpy(exe, "Faset");
        app = exe;
    }
#endif
    int err = 0;
    pa_handle = p_pa_simple_new(NULL, app, 1 /* PA_STREAM_PLAYBACK */, NULL, "std.audio", &ss, NULL, &attr, &err);
    if (!pa_handle) {
        fa_set_error("PulseAudio: ", p_pa_strerror ? p_pa_strerror(err) : "no se pudo conectar");
        fa_log(t_error);
        return 0;
    }
    return 1;
}
static int pulse_write(const int16_t* pcm, int frames) {
    int err = 0;
    return p_pa_simple_write(pa_handle, pcm, (size_t)frames * 4, &err) >= 0;
}
static void pulse_close(void) {
    if (pa_handle) p_pa_simple_free(pa_handle);
    pa_handle = NULL;
}
static const fa_backend b_pulse = {"pulse", pulse_open, pulse_write, pulse_close};

/* ---- ALSA */
static void* alsa_lib;
static void* alsa_pcm;
static int (*p_snd_pcm_open)(void**, const char*, int, int);
static int (*p_snd_pcm_set_params)(void*, int, int, unsigned, unsigned, int, unsigned);
static long (*p_snd_pcm_writei)(void*, const void*, unsigned long);
static int (*p_snd_pcm_recover)(void*, int, int);
static int (*p_snd_pcm_close)(void*);
static const char* (*p_snd_strerror)(int);

static int alsa_open(int* rate) {
    if (!alsa_lib) alsa_lib = dlopen("libasound.so.2", RTLD_NOW | RTLD_LOCAL);
    if (!alsa_lib) return 0;
    p_snd_pcm_open = dlsym(alsa_lib, "snd_pcm_open");
    p_snd_pcm_set_params = dlsym(alsa_lib, "snd_pcm_set_params");
    p_snd_pcm_writei = dlsym(alsa_lib, "snd_pcm_writei");
    p_snd_pcm_recover = dlsym(alsa_lib, "snd_pcm_recover");
    p_snd_pcm_close = dlsym(alsa_lib, "snd_pcm_close");
    p_snd_strerror = dlsym(alsa_lib, "snd_strerror");
    if (!p_snd_pcm_open || !p_snd_pcm_set_params || !p_snd_pcm_writei || !p_snd_pcm_recover || !p_snd_pcm_close) return 0;
    const char* dev = getenv("FASET_ALSA_DEVICE");
    int err = p_snd_pcm_open(&alsa_pcm, dev ? dev : "default", 0 /* PLAYBACK */, 0);
    if (err < 0) {
        fa_set_error("ALSA: ", p_snd_strerror ? p_snd_strerror(err) : "no se pudo abrir el dispositivo");
        alsa_pcm = NULL;
        return 0;
    }
    /* S16_LE = 2, RW_INTERLEAVED = 3, remuestreo de ALSA permitido, 50 ms de latencia. */
    err = p_snd_pcm_set_params(alsa_pcm, 2, 3, 2, (unsigned)*rate, 1, 50000);
    if (err < 0) {
        fa_set_error("ALSA: ", p_snd_strerror ? p_snd_strerror(err) : "formato no admitido");
        p_snd_pcm_close(alsa_pcm);
        alsa_pcm = NULL;
        return 0;
    }
    return 1;
}
static int alsa_write(const int16_t* pcm, int frames) {
    while (frames > 0) {
        long n = p_snd_pcm_writei(alsa_pcm, pcm, (unsigned long)frames);
        if (n < 0) {
            if (p_snd_pcm_recover(alsa_pcm, (int)n, 1) < 0) return 0;
            continue;
        }
        pcm += n * 2;
        frames -= (int)n;
    }
    return 1;
}
static void alsa_close(void) {
    if (alsa_pcm) p_snd_pcm_close(alsa_pcm);
    alsa_pcm = NULL;
}
static const fa_backend b_alsa = {"alsa", alsa_open, alsa_write, alsa_close};
#endif

#if defined(_WIN32)
/* ---- WinMM (waveOut): 4 búferes de 20 ms y un evento que avisa cuando uno termina. */
#define FA_WO_BUFS 4
#define FA_WO_FRAMES 960
static HWAVEOUT wo;
static HANDLE wo_event;
static WAVEHDR wo_hdr[FA_WO_BUFS];
static int16_t wo_data[FA_WO_BUFS][FA_WO_FRAMES * 2];
static int16_t wo_pending[FA_WO_FRAMES * 2];
static int wo_pendingLen;

static int winmm_open(int* rate) {
    WAVEFORMATEX wf;
    memset(&wf, 0, sizeof wf);
    wf.wFormatTag = WAVE_FORMAT_PCM;
    wf.nChannels = 2;
    wf.nSamplesPerSec = (DWORD)*rate;
    wf.wBitsPerSample = 16;
    wf.nBlockAlign = 4;
    wf.nAvgBytesPerSec = wf.nSamplesPerSec * 4;
    wo_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!wo_event) return 0;
    if (waveOutOpen(&wo, WAVE_MAPPER, &wf, (DWORD_PTR)wo_event, 0, CALLBACK_EVENT) != MMSYSERR_NOERROR) {
        CloseHandle(wo_event);
        wo_event = NULL;
        fa_set_error("WinMM: no se pudo abrir la salida de audio", NULL);
        return 0;
    }
    for (int i = 0; i < FA_WO_BUFS; i++) {
        memset(&wo_hdr[i], 0, sizeof(WAVEHDR));
        wo_hdr[i].lpData = (LPSTR)wo_data[i];
        wo_hdr[i].dwBufferLength = FA_WO_FRAMES * 4;
        waveOutPrepareHeader(wo, &wo_hdr[i], sizeof(WAVEHDR));
        wo_hdr[i].dwFlags |= WHDR_DONE; /* libre */
    }
    wo_pendingLen = 0;
    return 1;
}
/* Acumula bloques del mezclador hasta llenar un búfer de waveOut y lo envía. */
static int winmm_write(const int16_t* pcm, int frames) {
    while (frames > 0) {
        int n = FA_WO_FRAMES - wo_pendingLen;
        if (n > frames) n = frames;
        memcpy(wo_pending + wo_pendingLen * 2, pcm, sizeof(int16_t) * 2 * (size_t)n);
        wo_pendingLen += n;
        pcm += n * 2;
        frames -= n;
        if (wo_pendingLen < FA_WO_FRAMES) break;
        for (;;) {
            int freeIdx = -1;
            for (int i = 0; i < FA_WO_BUFS; i++)
                if (wo_hdr[i].dwFlags & WHDR_DONE) {
                    freeIdx = i;
                    break;
                }
            if (freeIdx >= 0) {
                WAVEHDR* h = &wo_hdr[freeIdx];
                memcpy(h->lpData, wo_pending, FA_WO_FRAMES * 4);
                h->dwFlags &= ~WHDR_DONE;
                if (waveOutWrite(wo, h, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) return 0;
                wo_pendingLen = 0;
                break;
            }
            WaitForSingleObject(wo_event, 100);
        }
    }
    return 1;
}
static void winmm_close(void) {
    if (!wo) return;
    waveOutReset(wo);
    for (int i = 0; i < FA_WO_BUFS; i++) waveOutUnprepareHeader(wo, &wo_hdr[i], sizeof(WAVEHDR));
    waveOutClose(wo);
    wo = NULL;
    if (wo_event) CloseHandle(wo_event);
    wo_event = NULL;
}
static const fa_backend b_winmm = {"winmm", winmm_open, winmm_write, winmm_close};
#endif

#if defined(__ANDROID__)
/* ---- AAudio (Android 8.0+, cargada con dlopen para que la app funcione desde la API 24). */
typedef struct AAudioStreamBuilderStruct AAudioStreamBuilder;
typedef struct AAudioStreamStruct AAudioStream;
static void* aa_lib;
static AAudioStream* aa_stream;
static int32_t (*p_AAudio_createStreamBuilder)(AAudioStreamBuilder**);
static void (*p_AAudioStreamBuilder_setFormat)(AAudioStreamBuilder*, int32_t);
static void (*p_AAudioStreamBuilder_setChannelCount)(AAudioStreamBuilder*, int32_t);
static void (*p_AAudioStreamBuilder_setSampleRate)(AAudioStreamBuilder*, int32_t);
static void (*p_AAudioStreamBuilder_setPerformanceMode)(AAudioStreamBuilder*, int32_t);
static int32_t (*p_AAudioStreamBuilder_openStream)(AAudioStreamBuilder*, AAudioStream**);
static int32_t (*p_AAudioStreamBuilder_delete)(AAudioStreamBuilder*);
static int32_t (*p_AAudioStream_getSampleRate)(AAudioStream*);
static int32_t (*p_AAudioStream_requestStart)(AAudioStream*);
static int32_t (*p_AAudioStream_requestStop)(AAudioStream*);
static int32_t (*p_AAudioStream_close)(AAudioStream*);
static int32_t (*p_AAudioStream_write)(AAudioStream*, const void*, int32_t, int64_t);

static int aaudio_open_stream(int* rate) {
    AAudioStreamBuilder* b = NULL;
    if (p_AAudio_createStreamBuilder(&b) != 0 || !b) return 0;
    p_AAudioStreamBuilder_setFormat(b, 1 /* AAUDIO_FORMAT_PCM_I16 */);
    p_AAudioStreamBuilder_setChannelCount(b, 2);
    p_AAudioStreamBuilder_setSampleRate(b, *rate);
    p_AAudioStreamBuilder_setPerformanceMode(b, 12 /* AAUDIO_PERFORMANCE_MODE_LOW_LATENCY */);
    int32_t r = p_AAudioStreamBuilder_openStream(b, &aa_stream);
    p_AAudioStreamBuilder_delete(b);
    if (r != 0 || !aa_stream) {
        aa_stream = NULL;
        return 0;
    }
    int32_t sr = p_AAudioStream_getSampleRate(aa_stream);
    if (sr > 0) *rate = sr;
    if (p_AAudioStream_requestStart(aa_stream) != 0) {
        p_AAudioStream_close(aa_stream);
        aa_stream = NULL;
        return 0;
    }
    return 1;
}

static int aaudio_open(int* rate) {
    if (!aa_lib) aa_lib = dlopen("libaaudio.so", RTLD_NOW | RTLD_LOCAL);
    if (!aa_lib) return 0;
#define AA_SYM(n) p_##n = dlsym(aa_lib, #n); if (!p_##n) return 0;
    AA_SYM(AAudio_createStreamBuilder) AA_SYM(AAudioStreamBuilder_setFormat) AA_SYM(AAudioStreamBuilder_setChannelCount)
    AA_SYM(AAudioStreamBuilder_setSampleRate) AA_SYM(AAudioStreamBuilder_setPerformanceMode)
    AA_SYM(AAudioStreamBuilder_openStream) AA_SYM(AAudioStreamBuilder_delete) AA_SYM(AAudioStream_getSampleRate)
    AA_SYM(AAudioStream_requestStart) AA_SYM(AAudioStream_requestStop) AA_SYM(AAudioStream_close)
    AA_SYM(AAudioStream_write)
#undef AA_SYM
    return aaudio_open_stream(rate);
}
static int aaudio_write(const int16_t* pcm, int frames) {
    while (frames > 0) {
        if (!aa_stream) {
            /* Se desconectó (auriculares, cambio de salida): se vuelve a abrir. */
            int rate = g_out_rate;
            if (!aaudio_open_stream(&rate)) {
                fa_sleep_ms(100);
                return 1;
            }
        }
        int32_t n = p_AAudioStream_write(aa_stream, pcm, frames, 200000000LL);
        if (n < 0) {
            p_AAudioStream_close(aa_stream);
            aa_stream = NULL;
            continue;
        }
        if (n == 0) return 1; /* tiempo agotado: se descarta el bloque */
        pcm += n * 2;
        frames -= n;
    }
    return 1;
}
static void aaudio_close(void) {
    if (aa_stream) {
        p_AAudioStream_requestStop(aa_stream);
        p_AAudioStream_close(aa_stream);
    }
    aa_stream = NULL;
}
static const fa_backend b_aaudio = {"aaudio", aaudio_open, aaudio_write, aaudio_close};

/* ---- OpenSL ES (Android 2.3+): cola de 3 búferes; la llamada de la cola avisa al hilo. */
#define FA_SL_BUFS 3
static SLObjectItf sl_engineObj, sl_mixObj, sl_playerObj;
static SLEngineItf sl_engine;
static SLPlayItf sl_play;
static SLAndroidSimpleBufferQueueItf sl_queue;
static int16_t sl_data[FA_SL_BUFS][FA_CHUNK * 2];
static int sl_next, sl_free;
static pthread_mutex_t sl_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t sl_cv = PTHREAD_COND_INITIALIZER;

static void sl_callback(SLAndroidSimpleBufferQueueItf q, void* ctx) {
    pthread_mutex_lock(&sl_mx);
    sl_free++;
    pthread_cond_signal(&sl_cv);
    pthread_mutex_unlock(&sl_mx);
}
static void opensl_close(void) {
    if (sl_playerObj) (*sl_playerObj)->Destroy(sl_playerObj);
    if (sl_mixObj) (*sl_mixObj)->Destroy(sl_mixObj);
    if (sl_engineObj) (*sl_engineObj)->Destroy(sl_engineObj);
    sl_playerObj = sl_mixObj = sl_engineObj = NULL;
}
static int opensl_open(int* rate) {
    if (slCreateEngine(&sl_engineObj, 0, NULL, 0, NULL, NULL) != SL_RESULT_SUCCESS) return 0;
    if ((*sl_engineObj)->Realize(sl_engineObj, SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS) goto fail;
    if ((*sl_engineObj)->GetInterface(sl_engineObj, SL_IID_ENGINE, &sl_engine) != SL_RESULT_SUCCESS) goto fail;
    if ((*sl_engine)->CreateOutputMix(sl_engine, &sl_mixObj, 0, NULL, NULL) != SL_RESULT_SUCCESS) goto fail;
    if ((*sl_mixObj)->Realize(sl_mixObj, SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS) goto fail;
    {
        SLDataLocator_AndroidSimpleBufferQueue loc = {SL_DATALOCATOR_ANDROIDSIMPLEBUFFERQUEUE, FA_SL_BUFS};
        SLDataFormat_PCM fmt = {SL_DATAFORMAT_PCM, 2, (SLuint32)*rate * 1000, SL_PCMSAMPLEFORMAT_FIXED_16,
                                SL_PCMSAMPLEFORMAT_FIXED_16, SL_SPEAKER_FRONT_LEFT | SL_SPEAKER_FRONT_RIGHT,
                                SL_BYTEORDER_LITTLEENDIAN};
        SLDataSource src = {&loc, &fmt};
        SLDataLocator_OutputMix outLoc = {SL_DATALOCATOR_OUTPUTMIX, sl_mixObj};
        SLDataSink sink = {&outLoc, NULL};
        const SLInterfaceID ids[1] = {SL_IID_ANDROIDSIMPLEBUFFERQUEUE};
        const SLboolean req[1] = {SL_BOOLEAN_TRUE};
        if ((*sl_engine)->CreateAudioPlayer(sl_engine, &sl_playerObj, &src, &sink, 1, ids, req) != SL_RESULT_SUCCESS) goto fail;
    }
    if ((*sl_playerObj)->Realize(sl_playerObj, SL_BOOLEAN_FALSE) != SL_RESULT_SUCCESS) goto fail;
    if ((*sl_playerObj)->GetInterface(sl_playerObj, SL_IID_PLAY, &sl_play) != SL_RESULT_SUCCESS) goto fail;
    if ((*sl_playerObj)->GetInterface(sl_playerObj, SL_IID_ANDROIDSIMPLEBUFFERQUEUE, &sl_queue) != SL_RESULT_SUCCESS) goto fail;
    if ((*sl_queue)->RegisterCallback(sl_queue, sl_callback, NULL) != SL_RESULT_SUCCESS) goto fail;
    if ((*sl_play)->SetPlayState(sl_play, SL_PLAYSTATE_PLAYING) != SL_RESULT_SUCCESS) goto fail;
    sl_next = 0;
    sl_free = FA_SL_BUFS;
    return 1;
fail:
    opensl_close();
    return 0;
}
static int opensl_write(const int16_t* pcm, int frames) {
    pthread_mutex_lock(&sl_mx);
    while (sl_free == 0) pthread_cond_wait(&sl_cv, &sl_mx);
    sl_free--;
    pthread_mutex_unlock(&sl_mx);
    if (frames > FA_CHUNK) frames = FA_CHUNK;
    memcpy(sl_data[sl_next], pcm, sizeof(int16_t) * 2 * (size_t)frames);
    SLresult r = (*sl_queue)->Enqueue(sl_queue, sl_data[sl_next], (SLuint32)frames * 4);
    sl_next = (sl_next + 1) % FA_SL_BUFS;
    return r == SL_RESULT_SUCCESS;
}
static const fa_backend b_opensl = {"opensl", opensl_open, opensl_write, opensl_close};
#endif

static const fa_backend* const g_backends[] = {
#if defined(__linux__) && !defined(__ANDROID__)
    &b_pulse, &b_alsa,
#endif
#if defined(_WIN32)
    &b_winmm,
#endif
#if defined(__ANDROID__)
    &b_aaudio, &b_opensl,
#endif
    &b_null,
};

/* ================================================================== hilo de audio */

static const fa_backend* g_backend;
static int g_open;            /* 0 cerrado, 1 con hilo, 2 offline (sin hilo) */
static volatile int g_quit;
static char g_driver[16] = "";
#if defined(_WIN32)
static HANDLE g_thread;
#else
static pthread_t g_thread;
#endif

static void fa_audio_loop(void) {
    float mix[FA_CHUNK * 2];
    int16_t pcm[FA_CHUNK * 2];
    while (!g_quit) {
        fa_mix(mix, FA_CHUNK);
        fa_to_s16(mix, pcm, FA_CHUNK * 2);
        if (!g_backend->write(pcm, FA_CHUNK)) {
            /* La salida falló: se sigue sin sonido para que las voces avancen y terminen. */
            fa_log("la salida de audio falló; se continúa sin sonido");
            g_backend->close();
            g_backend = &b_null;
            strcpy(g_driver, "null");
        }
    }
}

#if defined(_WIN32)
static DWORD WINAPI fa_thread_main(LPVOID p) {
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_TIME_CRITICAL);
    fa_audio_loop();
    return 0;
}
#else
static void* fa_thread_main(void* p) {
    fa_audio_loop();
    return NULL;
}
#endif

void faset_audio_close(void);

static void fa_atexit(void) { faset_audio_close(); }

/* Abre la salida: "" (automática), "pulse", "alsa", "winmm", "aaudio", "opensl", "null"
   u "offline". Devuelve 1 si se abrió la pedida (o alguna, en automático). */
int32_t faset_audio_open(fa_str driverName) {
    fa_global_init();
    if (g_open) return 1;
    t_error[0] = 0;
    char want[32] = "";
    if (driverName.len > 0 && driverName.len < (int64_t)sizeof want) memcpy(want, driverName.ptr, (size_t)driverName.len);
    if (!want[0]) {
        const char* env = getenv("FASET_AUDIO_DRIVER");
        if (env && strlen(env) < sizeof want) strcpy(want, env);
    }
    int rate = 48000;
    const char* rateEnv = getenv("FASET_AUDIO_RATE");
    if (rateEnv && atoi(rateEnv) >= 8000) rate = atoi(rateEnv);
    if (!strcmp(want, "offline")) {
        g_out_rate = rate;
        g_open = 2;
        strcpy(g_driver, "offline");
        return 1;
    }
    const fa_backend* chosen = NULL;
    for (size_t i = 0; i < sizeof g_backends / sizeof g_backends[0]; i++) {
        const fa_backend* b = g_backends[i];
        if (want[0] && strcmp(want, b->name)) continue;
        int r = rate;
        if (b->open(&r)) {
            chosen = b;
            rate = r;
            break;
        }
    }
    int ok = chosen != NULL;
    if (!chosen) {
        if (!t_error[0]) fa_set_error(want[0] ? "no se pudo abrir la salida de audio pedida: " : "no hay salida de audio", want);
        fa_log(t_error);
        chosen = &b_null; /* sin sonido, pero el tiempo avanza */
    }
    g_backend = chosen;
    g_out_rate = rate;
    strcpy(g_driver, chosen->name);
    g_quit = 0;
#if defined(_WIN32)
    g_thread = CreateThread(NULL, 0, fa_thread_main, NULL, 0, NULL);
    if (!g_thread) {
#else
    if (pthread_create(&g_thread, NULL, fa_thread_main, NULL) != 0) {
#endif
        chosen->close();
        fa_set_error("no se pudo crear el hilo de audio", NULL);
        return 0;
    }
    g_open = 1;
    static int registered;
    if (!registered) {
        registered = 1;
        atexit(fa_atexit);
    }
    return ok;
}

void faset_audio_close(void) {
    if (!g_open) return;
    if (g_open == 1) {
        g_quit = 1;
#if defined(_WIN32)
        WaitForSingleObject(g_thread, 2000);
        CloseHandle(g_thread);
#else
        pthread_join(g_thread, NULL);
#endif
        g_backend->close();
    }
    fa_lock();
    for (int i = 0; i < FA_MAX_VOICES; i++)
        if (g_voices[i].used) fa_voice_free_locked(&g_voices[i]);
    fa_unlock();
    g_open = 0;
    g_driver[0] = 0;
}

int32_t faset_audio_is_open(void) { return g_open != 0; }
const char* faset_audio_driver(void) { return g_driver; }
int32_t faset_audio_rate(void) { return g_out_rate; }

/* Solo con la salida "offline": mezcla 'frames' fotogramas estéreo en 'out'. */
int32_t faset_audio_render(float* out, int32_t frames) {
    if (g_open != 2) return 0;
    int done = 0;
    while (done < frames) {
        int n = frames - done > FA_CHUNK ? FA_CHUNK : frames - done;
        fa_mix(out + done * 2, n);
        done += n;
    }
    return frames;
}

void faset_audio_set_master(float v) {
    fa_lock();
    g_master = v < 0 ? 0 : v;
    fa_unlock();
}
float faset_audio_master(void) { return g_master; }

void faset_audio_pause_all(int32_t on) {
    fa_lock();
    g_paused_all = on != 0;
    fa_unlock();
}

/* Para todas las voces (src == NULL) o las de una fuente. */
void faset_audio_stop_source(void* src) {
    fa_lock();
    for (int i = 0; i < FA_MAX_VOICES; i++)
        if (g_voices[i].used && (!src || g_voices[i].src == (fa_source*)src)) g_voices[i].stopping = 1;
    fa_unlock();
}

int32_t faset_audio_voice_count(void) {
    int n = 0;
    fa_lock();
    for (int i = 0; i < FA_MAX_VOICES; i++) n += g_voices[i].used && !g_voices[i].finished && !g_voices[i].stopping;
    fa_unlock();
    return n;
}

void faset_source_release(void* s) {
    if (!s) return;
    fa_lock();
    fa_source_unref_locked((fa_source*)s);
    fa_unlock();
}

/* Nueva voz de una fuente; devuelve su identificador (0 si no hay voces libres). */
int64_t faset_source_play(void* s, float volume, float pan, float speed, int32_t loop, int32_t paused) {
    fa_source* src = (fa_source*)s;
    fa_dec* dec = NULL;
    int16_t* win = NULL;
    if (src->stream) {
        dec = fa_dec_open(src->blob, src->blobLen);
        win = (int16_t*)malloc(sizeof(int16_t) * FA_STREAM_WINDOW * 2);
        if (!dec || !win) {
            fa_dec_free(dec);
            free(win);
            return 0;
        }
    }
    int64_t id = 0;
    fa_lock();
    for (int i = 0; i < FA_MAX_VOICES; i++) {
        fa_voice* v = &g_voices[i];
        if (v->used) continue;
        v->used = 1;
        v->src = src;
        src->refs++;
        v->volume = volume < 0 ? 0 : volume;
        v->pan = pan;
        v->speed = speed;
        v->loop = loop != 0;
        v->paused = paused != 0;
        v->dec = dec;
        v->win = win;
        id = fa_voice_id(i);
        dec = NULL;
        win = NULL;
        break;
    }
    fa_unlock();
    fa_dec_free(dec);
    free(win);
    if (!id) fa_set_error("demasiadas voces sonando a la vez", NULL);
    return id;
}

void faset_voice_stop(int64_t id) {
    fa_lock();
    fa_voice* v = fa_find(id);
    if (v) v->stopping = 1;
    fa_unlock();
}

void faset_voice_set_paused(int64_t id, int32_t on) {
    fa_lock();
    fa_voice* v = fa_find(id);
    if (v) v->paused = on != 0;
    fa_unlock();
}

/* 0 terminada (o parada), 1 sonando, 2 en pausa. */
int32_t faset_voice_state(int64_t id) {
    int st = 0;
    fa_lock();
    fa_voice* v = fa_find(id);
    if (v && !v->finished && !v->stopping) st = v->paused ? 2 : 1;
    fa_unlock();
    return st;
}

/* what: 0 volumen, 1 panorama, 2 velocidad, 3 bucle. */
void faset_voice_set(int64_t id, int32_t what, float value) {
    fa_lock();
    fa_voice* v = fa_find(id);
    if (v) {
        if (what == 0) v->volume = value < 0 ? 0 : value;
        else if (what == 1) v->pan = value;
        else if (what == 2) v->speed = value;
        else if (what == 3) v->loop = value != 0;
    }
    fa_unlock();
}

float faset_voice_get(int64_t id, int32_t what) {
    float r = 0;
    fa_lock();
    fa_voice* v = fa_find(id);
    if (v) r = what == 0 ? v->volume : what == 1 ? v->pan : what == 2 ? v->speed : (float)v->loop;
    fa_unlock();
    return r;
}

/* Posición en segundos dentro de la fuente. */
double faset_voice_position(int64_t id) {
    double r = 0;
    fa_lock();
    fa_voice* v = fa_find(id);
    if (v) {
        double p = v->pos;
        if (v->src->stream) {
            int64_t base = (int64_t)p >= v->base ? v->base : v->prevBase;
            p -= (double)base;
        } else if (v->loop && v->src->frames > 0 && p >= (double)v->src->frames) {
            p = fmod(p, (double)v->src->frames);
        }
        r = p / (double)v->src->rate;
    }
    fa_unlock();
    return r;
}

void faset_voice_seek(int64_t id, double seconds) {
    fa_lock();
    fa_voice* v = fa_find(id);
    if (v) {
        int64_t frame = (int64_t)(seconds * v->src->rate);
        if (frame < 0) frame = 0;
        if (v->src->frames >= 0 && frame > v->src->frames) frame = v->src->frames;
        if (v->src->stream) {
            fa_dec_seek(v->dec, frame);
            v->winStart = frame;
            v->winLen = 0;
            v->eof = 0;
            v->base = v->prevBase = 0;
        }
        v->pos = (double)frame;
    }
    fa_unlock();
}
