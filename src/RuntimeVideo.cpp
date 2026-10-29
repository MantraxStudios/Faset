#include "Runtime.h"

// Reproducción de vídeo del control VideoPlayer (lib/std/video.fst). Se añade a kRuntimeSource
// solo cuando el programa usa std.ui (que importa std.video).
//
//   Linux    GStreamer 1.0 cargado con dlopen (playbin + appsink BGRx); sin cabeceras -dev.
//            Todo se hace en el hilo de la interfaz: las muestras y los mensajes del bus se
//            recogen sin bloquear desde faset_video_update / faset_video_poll.
//   Android  AMediaExtractor + AMediaCodec (libmediandk) y AAudio, cargados con dlopen.
//            Dos hilos de C (vídeo y audio) decodifican; el vídeo se convierte de YUV a BGRx
//            en un búfer de C protegido por un mutex. Ningún hilo de C llama a código Faset.
//   Windows  todavía no disponible: el reproductor informa del error con el evento Failed.
//
// Los píxeles de los fotogramas son 0x00RRGGBB (como el lienzo de std.ui) y los reserva C con
// malloc: el recolector de Faset no los recorre.
const char* const kRuntimeVideoSource = R"FASET(
/* ---- std.ui: VideoPlayer */
#if defined(_WIN32)
#  include <windows.h>
#else
#  include <dlfcn.h>
#  include <pthread.h>
#endif

enum { FV_EV_NONE = 0, FV_EV_OPENED = 1, FV_EV_ENDED = 2, FV_EV_FAILED = 3 };

typedef struct faset_video {
    /* fotograma actual (BGRx) */
    uint32_t* pix;
    int fw, fh;
    int serial, seen;           /* serial cambia con cada fotograma nuevo */
    /* eventos pendientes para el hilo de la interfaz */
    int events[16];
    int evHead, evCount;
    char error[512];
    int opened, ended, failed, playing, muted;
    double volume;
    double pendingSeek;         /* < 0 = ninguno */
    uint64_t lastPts;           /* GStreamer: pts del último búfer mostrado */
#if !defined(_WIN32)
    pthread_mutex_t lock;
#endif
    /* datos de cada sistema */
    void* a; void* b; void* c; void* d;
#if defined(__ANDROID__)
    struct fv_android* nd;
#endif
} faset_video;

#if defined(_WIN32)
#  define FV_LOCK(v) ((void)0)
#  define FV_UNLOCK(v) ((void)0)
#else
#  define FV_LOCK(v) pthread_mutex_lock(&(v)->lock)
#  define FV_UNLOCK(v) pthread_mutex_unlock(&(v)->lock)
#endif

static void fv_push(faset_video* v, int ev) {
    FV_LOCK(v);
    if (v->evCount < 16) {
        v->events[(v->evHead + v->evCount) % 16] = ev;
        v->evCount++;
    }
    FV_UNLOCK(v);
}

static int fv_pop(faset_video* v) {
    int ev = 0;
    FV_LOCK(v);
    if (v->evCount > 0) {
        ev = v->events[v->evHead];
        v->evHead = (v->evHead + 1) % 16;
        v->evCount--;
    }
    FV_UNLOCK(v);
    return ev;
}

static void fv_fail(faset_video* v, const char* msg) {
    if (v->failed) return;
    FV_LOCK(v);
    snprintf(v->error, sizeof v->error, "%s", msg);
    FV_UNLOCK(v);
    v->failed = 1;
    fv_push(v, FV_EV_FAILED);
}

/* Copia un fotograma BGRx (filas de 'stride' bytes) al búfer del reproductor. */
static void fv_store_bgrx(faset_video* v, const uint8_t* src, int w, int h, int stride) {
    FV_LOCK(v);
    if (w != v->fw || h != v->fh || !v->pix) {
        free(v->pix);
        v->pix = (uint32_t*)malloc((size_t)w * h * 4);
        v->fw = v->pix ? w : 0;
        v->fh = v->pix ? h : 0;
    }
    if (v->pix) {
        for (int y = 0; y < h; y++) memcpy(v->pix + (size_t)y * w, src + (size_t)y * stride, (size_t)w * 4);
        v->serial++;
    }
    FV_UNLOCK(v);
}

/* Escala el fotograma (bilineal) al rectángulo x,y,w,h del lienzo, recortado a cx0..cx1 / cy0..cy1. */
void faset_video_blit(void* hv, uint32_t* dst, int32_t dw, int32_t dh, int32_t x, int32_t y, int32_t w, int32_t h,
                      int32_t cx0, int32_t cy0, int32_t cx1, int32_t cy1) {
    faset_video* v = (faset_video*)hv;
    if (!v || !dst || w <= 0 || h <= 0) return;
    if (cx0 < 0) cx0 = 0;
    if (cy0 < 0) cy0 = 0;
    if (cx1 > dw) cx1 = dw;
    if (cy1 > dh) cy1 = dh;
    if (x > cx0) cx0 = x;
    if (y > cy0) cy0 = y;
    if (x + w < cx1) cx1 = x + w;
    if (y + h < cy1) cy1 = y + h;
    if (cx0 >= cx1 || cy0 >= cy1) return;
    FV_LOCK(v);
    const uint32_t* s = v->pix;
    int sw = v->fw, sh = v->fh;
    if (!s || sw <= 0 || sh <= 0) {
        FV_UNLOCK(v);
        return;
    }
    /* coordenadas de origen en 16.16 (centro de píxel) */
    int64_t stepX = ((int64_t)sw << 16) / w, stepY = ((int64_t)sh << 16) / h;
    for (int py = cy0; py < cy1; py++) {
        int64_t fy = (int64_t)(py - y) * stepY + stepY / 2 - 32768;
        if (fy < 0) fy = 0;
        int y0 = (int)(fy >> 16), y1 = y0 + 1 < sh ? y0 + 1 : sh - 1;
        uint32_t wy = (uint32_t)((fy >> 8) & 0xff);
        const uint32_t* r0 = s + (size_t)y0 * sw;
        const uint32_t* r1 = s + (size_t)y1 * sw;
        uint32_t* out = dst + (size_t)py * dw;
        for (int px = cx0; px < cx1; px++) {
            int64_t fx = (int64_t)(px - x) * stepX + stepX / 2 - 32768;
            if (fx < 0) fx = 0;
            int x0 = (int)(fx >> 16), x1 = x0 + 1 < sw ? x0 + 1 : sw - 1;
            uint32_t wx = (uint32_t)((fx >> 8) & 0xff);
            uint32_t a = r0[x0], b = r0[x1], c = r1[x0], d = r1[x1];
            /* mezcla de los canales R y B a la vez, y G aparte */
            uint32_t top_rb = ((a & 0xff00ff) * (256 - wx) + (b & 0xff00ff) * wx) >> 8;
            uint32_t top_g = ((a & 0xff00) * (256 - wx) + (b & 0xff00) * wx) >> 8;
            uint32_t bot_rb = ((c & 0xff00ff) * (256 - wx) + (d & 0xff00ff) * wx) >> 8;
            uint32_t bot_g = ((c & 0xff00) * (256 - wx) + (d & 0xff00) * wx) >> 8;
            uint32_t rb = (((top_rb & 0xff00ff) * (256 - wy) + (bot_rb & 0xff00ff) * wy) >> 8) & 0xff00ff;
            uint32_t g = (((top_g & 0xff00) * (256 - wy) + (bot_g & 0xff00) * wy) >> 8) & 0xff00;
            out[px] = rb | g;
        }
    }
    FV_UNLOCK(v);
}

int32_t faset_video_frame_size(void* hv, int32_t* w, int32_t* h) {
    faset_video* v = (faset_video*)hv;
    if (!v) return 0;
    FV_LOCK(v);
    *w = v->fw;
    *h = v->fh;
    FV_UNLOCK(v);
    return *w > 0;
}

int32_t faset_video_error(void* hv, uint8_t* buf, int32_t cap) {
    faset_video* v = (faset_video*)hv;
    if (!v || cap <= 0) return 0;
    FV_LOCK(v);
    int n = (int)strlen(v->error);
    if (n > cap) n = cap;
    memcpy(buf, v->error, (size_t)n);
    FV_UNLOCK(v);
    return n;
}

static faset_video* fv_new(int flags) {
    faset_video* v = (faset_video*)calloc(1, sizeof(faset_video));
    if (!v) return 0;
#if !defined(_WIN32)
    pthread_mutex_init(&v->lock, 0);
#endif
    v->muted = flags & 1;
    v->volume = 1;
    v->pendingSeek = -1;
    return v;
}

static void fv_free(faset_video* v) {
    free(v->pix);
#if !defined(_WIN32)
    pthread_mutex_destroy(&v->lock);
#endif
    free(v);
}

static char* fv_cstr(faset_string s) {
    char* c = (char*)malloc((size_t)s.len + 1);
    if (!c) return 0;
    memcpy(c, s.ptr, (size_t)s.len);
    c[s.len] = 0;
    return c;
}

static int64_t fv_now_ms(void) {
#if defined(_WIN32)
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

static void fv_sleep_ms(int ms) {
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, 0);
#endif
}

#if defined(__linux__) && !defined(__ANDROID__)
/* =========================================================================== GStreamer */

typedef struct { void* memory; int flags; uint8_t* data; size_t size; size_t maxsize; void* user[4]; void* res[4]; } fv_gst_map;
/* GstMiniObject: el tipo del mensaje (GstMessageType) va justo después. */
typedef struct { size_t type; int refcount; int lockstate; unsigned flags; void* copy; void* dispose; void* free; unsigned nq; void* qdata; } fv_gst_mini;
typedef struct { uint32_t domain; int code; char* message; } fv_gerror;

static struct {
    int tried, ok;
    char why[256];
    int (*init_check)(int*, char***, void**);
    void* (*factory_make)(const char*, const char*);
    void* (*caps_from_string)(const char*);
    void (*mini_unref)(void*);
    void (*object_unref)(void*);
    void (*g_object_set)(void*, const char*, ...);
    void (*g_object_get)(void*, const char*, ...);
    void (*g_free)(void*);
    void (*g_error_free)(void*);
    char* (*filename_to_uri)(const char*, void**);
    int (*set_state)(void*, int);
    int (*get_state)(void*, int*, int*, uint64_t);
    void* (*get_bus)(void*);
    void* (*bus_pop)(void*);
    void (*parse_error)(void*, void**, char**);
    int (*query_position)(void*, int, int64_t*);
    int (*query_duration)(void*, int, int64_t*);
    int (*seek_simple)(void*, int, int, int64_t);
    void* (*try_pull_sample)(void*, uint64_t);
    void* (*sample_get_buffer)(void*);
    void* (*sample_get_caps)(void*);
    void* (*caps_get_structure)(void*, unsigned);
    int (*structure_get_int)(void*, const char*, int*);
    int (*buffer_map)(void*, fv_gst_map*, int);
    void (*buffer_unmap)(void*, fv_gst_map*);
} fgst;

#define FV_GST_FORMAT_TIME 3
#define FV_GST_STATE_NULL 1
#define FV_GST_STATE_PAUSED 3
#define FV_GST_STATE_PLAYING 4
#define FV_GST_MSG_EOS (1 << 0)
#define FV_GST_MSG_ERROR (1 << 1)
#define FV_GST_MSG_ASYNC_DONE (1 << 21)

static int fv_gst_load(void) {
    if (fgst.tried) return fgst.ok;
    fgst.tried = 1;
    void* core = dlopen("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    void* app = dlopen("libgstapp-1.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    void* gobj = dlopen("libgobject-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    void* glib = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!core || !app || !gobj || !glib) {
        snprintf(fgst.why, sizeof fgst.why, "VideoPlayer: no se encontró GStreamer 1.0 (%s); instala gstreamer1.0 y gst-plugins-base",
                 !core ? "libgstreamer-1.0.so.0" : !app ? "libgstapp-1.0.so.0" : !gobj ? "libgobject-2.0.so.0" : "libglib-2.0.so.0");
        return 0;
    }
    int missing = 0;
#define FV_SYM(lib, field, name) do { *(void**)&fgst.field = dlsym(lib, name); if (!fgst.field) missing = 1; } while (0)
    FV_SYM(core, init_check, "gst_init_check");
    FV_SYM(core, factory_make, "gst_element_factory_make");
    FV_SYM(core, caps_from_string, "gst_caps_from_string");
    FV_SYM(core, mini_unref, "gst_mini_object_unref");
    FV_SYM(core, object_unref, "gst_object_unref");
    FV_SYM(gobj, g_object_set, "g_object_set");
    FV_SYM(gobj, g_object_get, "g_object_get");
    FV_SYM(glib, g_free, "g_free");
    FV_SYM(glib, g_error_free, "g_error_free");
    FV_SYM(core, filename_to_uri, "gst_filename_to_uri");
    FV_SYM(core, set_state, "gst_element_set_state");
    FV_SYM(core, get_state, "gst_element_get_state");
    FV_SYM(core, get_bus, "gst_element_get_bus");
    FV_SYM(core, bus_pop, "gst_bus_pop");
    FV_SYM(core, parse_error, "gst_message_parse_error");
    FV_SYM(core, query_position, "gst_element_query_position");
    FV_SYM(core, query_duration, "gst_element_query_duration");
    FV_SYM(core, seek_simple, "gst_element_seek_simple");
    FV_SYM(app, try_pull_sample, "gst_app_sink_try_pull_sample");
    FV_SYM(core, sample_get_buffer, "gst_sample_get_buffer");
    FV_SYM(core, sample_get_caps, "gst_sample_get_caps");
    FV_SYM(core, caps_get_structure, "gst_caps_get_structure");
    FV_SYM(core, structure_get_int, "gst_structure_get_int");
    FV_SYM(core, buffer_map, "gst_buffer_map");
    FV_SYM(core, buffer_unmap, "gst_buffer_unmap");
#undef FV_SYM
    if (missing) {
        snprintf(fgst.why, sizeof fgst.why, "VideoPlayer: la versión de GStreamer instalada es demasiado antigua (se necesita 1.10 o superior)");
        return 0;
    }
    void* err = 0;
    if (!fgst.init_check(0, 0, &err)) {
        snprintf(fgst.why, sizeof fgst.why, "VideoPlayer: GStreamer no se pudo iniciar: %s", err ? ((fv_gerror*)err)->message : "?");
        if (err) fgst.g_error_free(err);
        return 0;
    }
    fgst.ok = 1;
    return 1;
}

/* a = playbin, b = appsink, c = bus, d = último búfer mostrado (solo para comparar) */
void* faset_video_open(faset_string src, int32_t flags) {
    faset_video* v = fv_new(flags);
    if (!v) return 0;
    if (!fv_gst_load()) {
        fv_fail(v, fgst.why);
        return v;
    }
    void* pipe = fgst.factory_make("playbin", 0);
    void* sink = fgst.factory_make("appsink", 0);
    if (!pipe || !sink) {
        if (pipe) fgst.object_unref(pipe);
        if (sink) fgst.object_unref(sink);
        fv_fail(v, "VideoPlayer: faltan los elementos 'playbin' o 'appsink' (instala gstreamer1.0-plugins-base)");
        return v;
    }
    void* caps = fgst.caps_from_string("video/x-raw,format=BGRx");
    fgst.g_object_set(sink, "caps", caps, "max-buffers", 2, "drop", 1, "sync", 1, (char*)0);
    fgst.mini_unref(caps);
    fgst.g_object_set(pipe, "video-sink", sink, (char*)0);
    if (v->muted) {
        void* fake = fgst.factory_make("fakesink", 0);
        if (fake) {
            fgst.g_object_set(fake, "sync", 1, (char*)0);
            fgst.g_object_set(pipe, "audio-sink", fake, (char*)0);
        }
    }
    /* Una ruta se convierte en URI file:// (absoluta); "http://..." y demás URI se usan tal cual. */
    char* path = fv_cstr(src);
    if (path) {
        if (strstr(path, "://")) fgst.g_object_set(pipe, "uri", path, (char*)0);
        else {
            /* relativa y no está en la carpeta actual: se prueba junto al ejecutable */
            if (path[0] != '/' && access(path, R_OK) != 0) {
                char exe[4096];
                ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
                if (n > 0) {
                    exe[n] = 0;
                    char* slash = strrchr(exe, '/');
                    if (slash) {
                        slash[1] = 0;
                        size_t need = strlen(exe) + strlen(path) + 1;
                        char* alt = (char*)malloc(need);
                        if (alt) {
                            snprintf(alt, need, "%s%s", exe, path);
                            if (access(alt, R_OK) == 0) {
                                free(path);
                                path = alt;
                            } else free(alt);
                        }
                    }
                }
            }
            void* err = 0;
            char* uri = fgst.filename_to_uri(path, &err);
            if (err) fgst.g_error_free(err);
            if (uri) {
                fgst.g_object_set(pipe, "uri", uri, (char*)0);
                fgst.g_free(uri);
            }
        }
        free(path);
    }
    v->a = pipe;
    v->b = sink;
    v->c = fgst.get_bus(pipe);
    fgst.set_state(pipe, FV_GST_STATE_PAUSED);  /* precarga: el primer fotograma y la duración */
    return v;
}

static void fv_gst_bus(faset_video* v) {
    if (!v->c) return;
    void* m;
    while ((m = fgst.bus_pop(v->c)) != 0) {
        int type = *(int*)((char*)m + sizeof(fv_gst_mini));
        if (type == FV_GST_MSG_EOS) {
            v->ended = 1;
            v->playing = 0;
            fv_push(v, FV_EV_ENDED);
        } else if (type == FV_GST_MSG_ERROR) {
            void* err = 0;
            char* dbg = 0;
            fgst.parse_error(m, &err, &dbg);
            char msg[400];
            snprintf(msg, sizeof msg, "VideoPlayer: %s", err ? ((fv_gerror*)err)->message : "error de GStreamer");
            if (err) fgst.g_error_free(err);
            if (dbg) fgst.g_free(dbg);
            v->playing = 0;
            fv_fail(v, msg);
        } else if (type == FV_GST_MSG_ASYNC_DONE && !v->opened && !v->failed) {
            v->opened = 1;
            fv_push(v, FV_EV_OPENED);
            if (v->pendingSeek >= 0) {
                fgst.seek_simple(v->a, FV_GST_FORMAT_TIME, 1 | 2, (int64_t)(v->pendingSeek * 1e9));
                v->pendingSeek = -1;
            }
        }
        fgst.mini_unref(m);
    }
}

int32_t faset_video_poll(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v) return 0;
    if (fgst.ok) fv_gst_bus(v);
    return fv_pop(v);
}

static int fv_gst_take(faset_video* v, void* sample) {
    int ok = 0;
    void* caps = fgst.sample_get_caps(sample);
    void* buf = fgst.sample_get_buffer(sample);
    int w = 0, h = 0;
    if (caps && buf) {
        void* st = fgst.caps_get_structure(caps, 0);
        if (st && fgst.structure_get_int(st, "width", &w) && fgst.structure_get_int(st, "height", &h) && w > 0 && h > 0) {
            fv_gst_map map;
            memset(&map, 0, sizeof map);
            if (fgst.buffer_map(buf, &map, 1)) {
                int stride = (int)(map.size / (size_t)h);
                if (stride >= w * 4) {
                    fv_store_bgrx(v, map.data, w, h, stride);
                    ok = 1;
                }
                fgst.buffer_unmap(buf, &map);
            }
        }
    }
    fgst.mini_unref(sample);
    return ok;
}

/* Marca de tiempo de un GstBuffer: GstMiniObject, GstBufferPool* y luego pts. El búfer de un
   pool puede reutilizar la misma dirección, así que se compara (dirección, pts). */
static uint64_t fv_gst_pts(void* buf) {
    return buf ? *(uint64_t*)((char*)buf + sizeof(fv_gst_mini) + sizeof(void*)) : 0;
}

/* Recoge el último fotograma disponible sin bloquear; 1 si hay uno nuevo. */
int32_t faset_video_update(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->b) return 0;
    void* last = 0;
    void* s;
    while ((s = fgst.try_pull_sample(v->b, 0)) != 0) {
        if (last) fgst.mini_unref(last);
        last = s;
    }
    if (!last && !v->playing) {
        /* En pausa (precarga o tras buscar) el fotograma no pasa por la cola del appsink:
           se toma la última muestra del sink si es un búfer distinto del que ya se mostró. */
        void* s2 = 0;
        fgst.g_object_get(v->b, "last-sample", &s2, (char*)0);
        if (s2 && (fgst.sample_get_buffer(s2) != v->d || fv_gst_pts(fgst.sample_get_buffer(s2)) != v->lastPts)) last = s2;
        else if (s2) fgst.mini_unref(s2);
    }
    if (!last) return 0;
    v->d = fgst.sample_get_buffer(last);  /* solo para comparar (no se desreferencia) */
    v->lastPts = fv_gst_pts(v->d);
    return fv_gst_take(v, last);
}

void faset_video_play(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->a) return;
    if (v->ended) {
        fgst.seek_simple(v->a, FV_GST_FORMAT_TIME, 1 | 2, 0);
        v->ended = 0;
    }
    fgst.set_state(v->a, FV_GST_STATE_PLAYING);
    v->playing = 1;
}

void faset_video_pause(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->a) return;
    fgst.set_state(v->a, FV_GST_STATE_PAUSED);
    v->playing = 0;
}

void faset_video_seek(void* hv, double seconds) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->a) return;
    if (seconds < 0) seconds = 0;
    if (!v->opened) {
        v->pendingSeek = seconds;
        return;
    }
    if (fgst.seek_simple(v->a, FV_GST_FORMAT_TIME, 1 | 2, (int64_t)(seconds * 1e9))) v->ended = 0;
}

double faset_video_position(void* hv) {
    faset_video* v = (faset_video*)hv;
    int64_t pos = 0;
    if (!v || !v->a || !fgst.query_position(v->a, FV_GST_FORMAT_TIME, &pos) || pos < 0) return 0;
    return pos / 1e9;
}

double faset_video_duration(void* hv) {
    faset_video* v = (faset_video*)hv;
    int64_t d = 0;
    if (!v || !v->a || !fgst.query_duration(v->a, FV_GST_FORMAT_TIME, &d) || d < 0) return -1;
    return d / 1e9;
}

void faset_video_set_volume(void* hv, double volume) {
    faset_video* v = (faset_video*)hv;
    if (!v) return;
    v->volume = volume;
    if (v->a) fgst.g_object_set(v->a, "volume", volume, (char*)0);
}

/* Espera (sin pantalla) a que haya un fotograma; 1 si llegó. */
int32_t faset_video_preroll(void* hv, int32_t ms) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->a) return 0;
    int64_t end = fv_now_ms() + ms;
    while (fv_now_ms() < end) {
        fv_gst_bus(v);
        if (v->failed) return 0;
        if (faset_video_update(v)) return 1;
        fv_sleep_ms(5);
    }
    return 0;
}

void faset_video_close(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v) return;
    if (v->a) {
        fgst.set_state(v->a, FV_GST_STATE_NULL);
        if (v->c) fgst.object_unref(v->c);
        fgst.object_unref(v->a);  /* también libera el appsink */
    }
    fv_free(v);
}

#elif defined(__ANDROID__)
/* =========================================================================== Android (NDK) */
#include <android/log.h>

/* Tipos opacos de <media/NdkMediaExtractor.h>, <media/NdkMediaCodec.h> y <aaudio/AAudio.h>. */
/* AMediaCodecBufferInfo */
typedef struct { int32_t offset; int32_t size; int64_t presentationTimeUs; uint32_t flags; } fv_codec_info;

static struct {
    int tried, ok, audio;
    char why[256];
    void* (*ex_new)(void);
    int (*ex_delete)(void*);
    int (*ex_set_fd)(void*, int, int64_t, int64_t);
    int (*ex_set_url)(void*, const char*);
    size_t (*ex_track_count)(void*);
    void* (*ex_track_format)(void*, size_t);
    int (*ex_select)(void*, size_t);
    ssize_t (*ex_read)(void*, uint8_t*, size_t);
    int64_t (*ex_time)(void*);
    _Bool (*ex_advance)(void*);
    int (*ex_seek)(void*, int64_t, int);
    _Bool (*fmt_get_string)(void*, const char*, const char**);
    _Bool (*fmt_get_int32)(void*, const char*, int32_t*);
    _Bool (*fmt_get_int64)(void*, const char*, int64_t*);
    int (*fmt_delete)(void*);
    void* (*codec_by_mime)(const char*);
    int (*codec_configure)(void*, void*, void*, void*, uint32_t);
    int (*codec_start)(void*);
    int (*codec_stop)(void*);
    int (*codec_delete)(void*);
    int (*codec_flush)(void*);
    ssize_t (*codec_in_index)(void*, int64_t);
    uint8_t* (*codec_in_buffer)(void*, size_t, size_t*);
    int (*codec_queue_in)(void*, size_t, long, size_t, uint64_t, uint32_t);
    ssize_t (*codec_out_index)(void*, fv_codec_info*, int64_t);
    uint8_t* (*codec_out_buffer)(void*, size_t, size_t*);
    void* (*codec_out_format)(void*);
    int (*codec_release_out)(void*, size_t, int);
    /* AAudio */
    int (*aa_builder)(void**);
    void (*aa_set_rate)(void*, int32_t);
    void (*aa_set_channels)(void*, int32_t);
    void (*aa_set_format)(void*, int32_t);
    int (*aa_open)(void*, void**);
    int (*aa_builder_delete)(void*);
    int (*aa_start)(void*);
    int (*aa_pause)(void*);
    int (*aa_flush)(void*);
    int (*aa_close)(void*);
    int (*aa_write)(void*, const void*, int32_t, int64_t);
} fnd;

static int fv_nd_load(void) {
    if (fnd.tried) return fnd.ok;
    fnd.tried = 1;
    void* m = dlopen("libmediandk.so", RTLD_NOW);
    if (!m) {
        snprintf(fnd.why, sizeof fnd.why, "VideoPlayer: no se pudo cargar libmediandk.so");
        return 0;
    }
    int missing = 0;
#define FV_SYM(lib, field, name) do { *(void**)&fnd.field = dlsym(lib, name); if (!fnd.field) missing = 1; } while (0)
    FV_SYM(m, ex_new, "AMediaExtractor_new");
    FV_SYM(m, ex_delete, "AMediaExtractor_delete");
    FV_SYM(m, ex_set_fd, "AMediaExtractor_setDataSourceFd");
    FV_SYM(m, ex_set_url, "AMediaExtractor_setDataSource");
    FV_SYM(m, ex_track_count, "AMediaExtractor_getTrackCount");
    FV_SYM(m, ex_track_format, "AMediaExtractor_getTrackFormat");
    FV_SYM(m, ex_select, "AMediaExtractor_selectTrack");
    FV_SYM(m, ex_read, "AMediaExtractor_readSampleData");
    FV_SYM(m, ex_time, "AMediaExtractor_getSampleTime");
    FV_SYM(m, ex_advance, "AMediaExtractor_advance");
    FV_SYM(m, ex_seek, "AMediaExtractor_seekTo");
    FV_SYM(m, fmt_get_string, "AMediaFormat_getString");
    FV_SYM(m, fmt_get_int32, "AMediaFormat_getInt32");
    FV_SYM(m, fmt_get_int64, "AMediaFormat_getInt64");
    FV_SYM(m, fmt_delete, "AMediaFormat_delete");
    FV_SYM(m, codec_by_mime, "AMediaCodec_createDecoderByType");
    FV_SYM(m, codec_configure, "AMediaCodec_configure");
    FV_SYM(m, codec_start, "AMediaCodec_start");
    FV_SYM(m, codec_stop, "AMediaCodec_stop");
    FV_SYM(m, codec_delete, "AMediaCodec_delete");
    FV_SYM(m, codec_flush, "AMediaCodec_flush");
    FV_SYM(m, codec_in_index, "AMediaCodec_dequeueInputBuffer");
    FV_SYM(m, codec_in_buffer, "AMediaCodec_getInputBuffer");
    FV_SYM(m, codec_queue_in, "AMediaCodec_queueInputBuffer");
    FV_SYM(m, codec_out_index, "AMediaCodec_dequeueOutputBuffer");
    FV_SYM(m, codec_out_buffer, "AMediaCodec_getOutputBuffer");
    FV_SYM(m, codec_out_format, "AMediaCodec_getOutputFormat");
    FV_SYM(m, codec_release_out, "AMediaCodec_releaseOutputBuffer");
#undef FV_SYM
    if (missing) {
        snprintf(fnd.why, sizeof fnd.why, "VideoPlayer: libmediandk.so incompleta en este dispositivo");
        return 0;
    }
    /* AAudio (Android 8+); sin él el vídeo se reproduce sin sonido. */
    void* aa = dlopen("libaaudio.so", RTLD_NOW);
    if (aa) {
        int amiss = 0;
#define FV_ASYM(field, name) do { *(void**)&fnd.field = dlsym(aa, name); if (!fnd.field) amiss = 1; } while (0)
        FV_ASYM(aa_builder, "AAudio_createStreamBuilder");
        FV_ASYM(aa_set_rate, "AAudioStreamBuilder_setSampleRate");
        FV_ASYM(aa_set_channels, "AAudioStreamBuilder_setChannelCount");
        FV_ASYM(aa_set_format, "AAudioStreamBuilder_setFormat");
        FV_ASYM(aa_open, "AAudioStreamBuilder_openStream");
        FV_ASYM(aa_builder_delete, "AAudioStreamBuilder_delete");
        FV_ASYM(aa_start, "AAudioStream_requestStart");
        FV_ASYM(aa_pause, "AAudioStream_requestPause");
        FV_ASYM(aa_flush, "AAudioStream_requestFlush");
        FV_ASYM(aa_close, "AAudioStream_close");
        FV_ASYM(aa_write, "AAudioStream_write");
#undef FV_ASYM
        fnd.audio = !amiss;
    }
    fnd.ok = 1;
    return 1;
}

#define FV_TRY_AGAIN (-1)
#define FV_OUT_FORMAT_CHANGED (-2)
#define FV_EOS_FLAG 4

/* Un hilo por pista (vídeo o audio), cada uno con su extractor y su decodificador. */
typedef struct fv_track {
    faset_video* v;
    void* ex;
    void* codec;
    int index;            /* pista en el extractor */
    int isVideo;
    pthread_t thread;
    int started;
    /* vídeo: formato de salida */
    int width, height, stride, slice, colorFormat;
    int cropL, cropT, cropR, cropB;
    /* audio */
    void* stream;
    int rate, channels;
    int inputDone, outputDone;
} fv_track;

typedef struct fv_android {
    pthread_cond_t cond;
    int quit;
    int playing;
    int64_t seekUs;        /* >= 0: búsqueda pendiente (generación 'seekGen') */
    int seekGen;
    int64_t clockBaseUs;   /* posición de medios cuando se puso en marcha el reloj */
    int64_t clockStartMs;  /* instante (monotónico) en que se puso en marcha; < 0 = parado */
    int64_t positionUs;
    int64_t durationUs;
    int endedTracks, trackCount;
    fv_track video, audio;
    uint8_t* yuvTmp;
} fv_android;

static int64_t fv_media_now_us(fv_android* a) {
    if (a->clockStartMs < 0) return a->clockBaseUs;
    return a->clockBaseUs + (fv_now_ms() - a->clockStartMs) * 1000;
}

static inline uint8_t fv_clamp8(int x) { return (uint8_t)(x < 0 ? 0 : x > 255 ? 255 : x); }

/* YUV 4:2:0 (plano I420 o semiplano NV12/NV21) -> BGRx (BT.601, rango limitado). */
static void fv_yuv_to_bgrx(fv_track* t, const uint8_t* src, size_t size, uint32_t* out) {
    int w = t->width, h = t->height;
    int stride = t->stride > 0 ? t->stride : w;
    int slice = t->slice > 0 ? t->slice : h;
    int x0 = t->cropL, y0 = t->cropT;
    int cw = t->cropR > t->cropL ? t->cropR - t->cropL + 1 : w;
    int ch = t->cropB > t->cropT ? t->cropB - t->cropT + 1 : h;
    const uint8_t* Y = src;
    /* NV12 (semiplano) en 21, 39 y los formatos de Qualcomm; I420 (plano) en 19 y en el "flexible"
       0x7f420888, que es lo que entregan los decodificadores por software de Google. */
    int cf = t->colorFormat;
    int semi = cf == 21 || cf == 39 || (cf >= 0x7FA30C00 && cf <= 0x7FA30CFF);
    const uint8_t* U = src + (size_t)stride * slice;
    const uint8_t* V = semi ? U + 1 : U + (size_t)(stride / 2) * (slice / 2);
    int cstep = semi ? 2 : 1;
    int cstride = semi ? stride : stride / 2;
    size_t need = (size_t)stride * slice * 3 / 2;
    if (size < need) {
        /* algunos decodificadores no rellenan la última franja: se usa la altura real */
        slice = h;
        U = src + (size_t)stride * slice;
        V = semi ? U + 1 : U + (size_t)(stride / 2) * (slice / 2);
        if (size < (size_t)stride * h * 3 / 2) return;
    }
    for (int y = 0; y < ch; y++) {
        const uint8_t* yr = Y + (size_t)(y + y0) * stride + x0;
        const uint8_t* ur = U + (size_t)((y + y0) / 2) * cstride;
        const uint8_t* vr = V + (size_t)((y + y0) / 2) * cstride;
        uint32_t* o = out + (size_t)y * cw;
        for (int x = 0; x < cw; x++) {
            int cx = ((x + x0) / 2) * cstep;
            int yy = (yr[x] - 16) * 298;
            int u = ur[cx] - 128, vv = vr[cx] - 128;
            uint8_t r = fv_clamp8((yy + 409 * vv + 128) >> 8);
            uint8_t g = fv_clamp8((yy - 100 * u - 208 * vv + 128) >> 8);
            uint8_t b = fv_clamp8((yy + 516 * u + 128) >> 8);
            o[x] = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
        }
    }
}

static void fv_read_out_format(fv_track* t) {
    void* f = fnd.codec_out_format(t->codec);
    if (!f) return;
    int32_t v = 0;
    if (t->isVideo) {
        if (fnd.fmt_get_int32(f, "width", &v)) t->width = v;
        if (fnd.fmt_get_int32(f, "height", &v)) t->height = v;
        t->stride = fnd.fmt_get_int32(f, "stride", &v) ? v : t->width;
        t->slice = fnd.fmt_get_int32(f, "slice-height", &v) ? v : t->height;
        if (fnd.fmt_get_int32(f, "color-format", &v)) t->colorFormat = v;
        t->cropL = fnd.fmt_get_int32(f, "crop-left", &v) ? v : 0;
        t->cropT = fnd.fmt_get_int32(f, "crop-top", &v) ? v : 0;
        t->cropR = fnd.fmt_get_int32(f, "crop-right", &v) ? v : 0;
        t->cropB = fnd.fmt_get_int32(f, "crop-bottom", &v) ? v : 0;
        if (t->stride < t->width) t->stride = t->width;
        if (t->slice < t->height) t->slice = t->height;
    } else {
        if (fnd.fmt_get_int32(f, "sample-rate", &v)) t->rate = v;
        if (fnd.fmt_get_int32(f, "channel-count", &v)) t->channels = v;
    }
    fnd.fmt_delete(f);
}

static void fv_audio_open(fv_track* t) {
    if (!fnd.audio || t->stream || t->rate <= 0 || t->channels <= 0) return;
    void* b = 0;
    if (fnd.aa_builder(&b) != 0 || !b) return;
    fnd.aa_set_rate(b, t->rate);
    fnd.aa_set_channels(b, t->channels);
    fnd.aa_set_format(b, 1);  /* AAUDIO_FORMAT_PCM_I16 */
    void* s = 0;
    if (fnd.aa_open(b, &s) == 0) t->stream = s;
    fnd.aa_builder_delete(b);
    if (t->stream) fnd.aa_start(t->stream);
}

static void* fv_track_main(void* arg) {
    fv_track* t = (fv_track*)arg;
    faset_video* v = t->v;
    fv_android* a = v->nd;
    int seekGen = -1;
    int16_t* pcm = 0;
    size_t pcmCap = 0;
    for (;;) {
        pthread_mutex_lock(&v->lock);
        while (!a->quit && !a->playing && a->seekGen == seekGen) pthread_cond_wait(&a->cond, &v->lock);
        if (a->quit) {
            pthread_mutex_unlock(&v->lock);
            break;
        }
        int doSeek = a->seekGen != seekGen;
        int64_t seekUs = a->seekUs;
        int playing = a->playing;
        seekGen = a->seekGen;
        pthread_mutex_unlock(&v->lock);
        if (doSeek) {
            fnd.ex_seek(t->ex, seekUs, 0);  /* AMEDIAEXTRACTOR_SEEK_PREVIOUS_SYNC */
            fnd.codec_flush(t->codec);
            if (t->stream && fnd.aa_flush) {
                fnd.aa_pause(t->stream);
                fnd.aa_flush(t->stream);
            }
            t->inputDone = t->outputDone = 0;
        }
        if (t->stream) {
            if (playing) fnd.aa_start(t->stream);
            else fnd.aa_pause(t->stream);
        }
        /* Decodifica mientras se reproduce; en pausa solo hasta el primer fotograma tras buscar. */
        int wantFrame = doSeek && t->isVideo;
        int64_t targetUs = seekUs;
        while (!t->outputDone) {
            pthread_mutex_lock(&v->lock);
            int stop = a->quit || a->seekGen != seekGen || (!a->playing && !wantFrame);
            pthread_mutex_unlock(&v->lock);
            if (stop) break;
            if (!t->inputDone) {
                ssize_t in = fnd.codec_in_index(t->codec, 2000);
                if (in >= 0) {
                    size_t cap = 0;
                    uint8_t* buf = fnd.codec_in_buffer(t->codec, (size_t)in, &cap);
                    ssize_t n = buf ? fnd.ex_read(t->ex, buf, cap) : -1;
                    if (n < 0) {
                        fnd.codec_queue_in(t->codec, (size_t)in, 0, 0, 0, FV_EOS_FLAG);
                        t->inputDone = 1;
                    } else {
                        int64_t pts = fnd.ex_time(t->ex);
                        fnd.codec_queue_in(t->codec, (size_t)in, 0, (size_t)n, (uint64_t)(pts < 0 ? 0 : pts), 0);
                        fnd.ex_advance(t->ex);
                    }
                }
            }
            fv_codec_info info;
            ssize_t out = fnd.codec_out_index(t->codec, &info, 5000);
            if (out == FV_OUT_FORMAT_CHANGED) {
                fv_read_out_format(t);
                if (!t->isVideo) fv_audio_open(t);
                continue;
            }
            if (out < 0) continue;
            if (info.flags & FV_EOS_FLAG) t->outputDone = 1;
            size_t cap = 0;
            uint8_t* data = fnd.codec_out_buffer(t->codec, (size_t)out, &cap);
            int64_t pts = info.presentationTimeUs;
            if (data && info.size > 0 && info.offset >= 0 && (size_t)info.offset + (size_t)info.size <= cap) {
                if (t->isVideo) {
                    if (wantFrame && pts < targetUs && !t->outputDone) {
                        /* fotogramas anteriores al punto buscado: se descartan */
                    } else {
                        if (!wantFrame) {
                            /* espera a su momento según el reloj de reproducción */
                            for (;;) {
                                pthread_mutex_lock(&v->lock);
                                int64_t now = fv_media_now_us(a);
                                int abort = a->quit || a->seekGen != seekGen || !a->playing;
                                pthread_mutex_unlock(&v->lock);
                                if (abort || pts - now <= 2000) break;
                                int64_t wait = (pts - now) / 1000;
                                fv_sleep_ms(wait > 10 ? 10 : (int)(wait < 1 ? 1 : wait));
                            }
                        }
                        int cw = t->cropR > t->cropL ? t->cropR - t->cropL + 1 : t->width;
                        int ch = t->cropB > t->cropT ? t->cropB - t->cropT + 1 : t->height;
                        if (cw > 0 && ch > 0) {
                            uint32_t* rgb = (uint32_t*)malloc((size_t)cw * ch * 4);
                            if (rgb) {
                                memset(rgb, 0, (size_t)cw * ch * 4);
                                fv_yuv_to_bgrx(t, data + info.offset, info.size, rgb);
                                fv_store_bgrx(v, (const uint8_t*)rgb, cw, ch, cw * 4);
                                free(rgb);
                            }
                        }
                        pthread_mutex_lock(&v->lock);
                        a->positionUs = pts;
                        if (wantFrame) {
                            a->clockBaseUs = pts;
                            if (a->clockStartMs >= 0) a->clockStartMs = fv_now_ms();
                        }
                        pthread_mutex_unlock(&v->lock);
                        wantFrame = 0;
                    }
                } else if (t->stream) {
                    int frames = (int)(info.size / (2 * (size_t)(t->channels > 0 ? t->channels : 1)));
                    if (pcmCap < info.size) {
                        free(pcm);
                        pcm = (int16_t*)malloc(info.size);
                        pcmCap = pcm ? info.size : 0;
                    }
                    if (pcm) {
                        memcpy(pcm, data + info.offset, info.size);
                        double vol = v->volume;
                        if (vol < 0.999) {
                            int n = (int)(info.size / 2);
                            for (int i = 0; i < n; i++) pcm[i] = (int16_t)(pcm[i] * vol);
                        }
                        fnd.aa_write(t->stream, pcm, frames, 200000000LL);  /* bloquea: marca el ritmo */
                    }
                }
            }
            fnd.codec_release_out(t->codec, (size_t)out, 0);
        }
        if (t->outputDone) {
            pthread_mutex_lock(&v->lock);
            int report = a->seekGen == seekGen && a->playing;
            if (report) {
                a->endedTracks++;
                if (a->endedTracks >= a->trackCount) {
                    a->playing = 0;
                    a->positionUs = a->durationUs > 0 ? a->durationUs : a->positionUs;
                    a->clockBaseUs = a->positionUs;
                    a->clockStartMs = -1;
                    v->ended = 1;
                    v->playing = 0;
                }
            }
            /* espera a la siguiente orden */
            while (!a->quit && a->seekGen == seekGen) pthread_cond_wait(&a->cond, &v->lock);
            pthread_mutex_unlock(&v->lock);
            if (report && v->ended) { /* el evento lo emite faset_video_poll */ }
        }
    }
    free(pcm);
    return 0;
}

static int fv_track_setup(faset_video* v, fv_track* t, faset_string src, const char* path, size_t index, void* fmt, const char* mime) {
    t->v = v;
    t->index = (int)index;
    t->isVideo = strncmp(mime, "video/", 6) == 0;
    t->ex = fnd.ex_new();
    if (!t->ex) return 0;
    int r;
    if (strstr(path, "://")) r = fnd.ex_set_url(t->ex, path);
    else {
        int fd = open(path, O_RDONLY);
        if (fd < 0) return 0;
        struct stat st;
        fstat(fd, &st);
        r = fnd.ex_set_fd(t->ex, fd, 0, (int64_t)st.st_size);
        close(fd);
    }
    if (r != 0) return 0;
    fnd.ex_select(t->ex, index);
    t->codec = fnd.codec_by_mime(mime);
    if (!t->codec) return 0;
    if (fnd.codec_configure(t->codec, fmt, 0, 0, 0) != 0) return 0;
    if (t->isVideo) {
        int32_t w = 0, h = 0;
        fnd.fmt_get_int32(fmt, "width", &w);
        fnd.fmt_get_int32(fmt, "height", &h);
        t->width = w;
        t->height = h;
        t->stride = w;
        t->slice = h;
        t->colorFormat = 19;
    } else {
        int32_t x = 0;
        if (fnd.fmt_get_int32(fmt, "sample-rate", &x)) t->rate = x;
        if (fnd.fmt_get_int32(fmt, "channel-count", &x)) t->channels = x;
    }
    if (fnd.codec_start(t->codec) != 0) return 0;
    if (!t->isVideo) fv_audio_open(t);
    return 1;
}

static void fv_track_free(fv_track* t) {
    if (t->stream) {
        fnd.aa_pause(t->stream);
        fnd.aa_close(t->stream);
    }
    if (t->codec) {
        fnd.codec_stop(t->codec);
        fnd.codec_delete(t->codec);
    }
    if (t->ex) fnd.ex_delete(t->ex);
}

void* faset_video_open(faset_string src, int32_t flags) {
    faset_video* v = fv_new(flags);
    if (!v) return 0;
    if (!fv_nd_load()) {
        fv_fail(v, fnd.why);
        return v;
    }
    char* path = fv_cstr(src);
    if (!path) return v;
    fv_android* a = (fv_android*)calloc(1, sizeof(fv_android));
    v->nd = a;
    pthread_cond_init(&a->cond, 0);
    a->clockStartMs = -1;
    a->seekUs = 0;
    a->seekGen = 1;  /* los hilos empiezan "buscando" 0: decodifican el primer fotograma */
    /* Extractor de prueba para listar las pistas. */
    void* probe = fnd.ex_new();
    int r = -1;
    if (strstr(path, "://")) r = fnd.ex_set_url(probe, path);
    else {
        int fd = open(path, O_RDONLY);
        if (fd >= 0) {
            struct stat st;
            fstat(fd, &st);
            r = fnd.ex_set_fd(probe, fd, 0, (int64_t)st.st_size);
            close(fd);
        }
    }
    if (r != 0) {
        char msg[400];
        snprintf(msg, sizeof msg, "VideoPlayer: no se pudo abrir '%s'", path);
        fv_fail(v, msg);
        fnd.ex_delete(probe);
        free(path);
        return v;
    }
    size_t n = fnd.ex_track_count(probe);
    int haveVideo = 0, haveAudio = 0;
    for (size_t i = 0; i < n; i++) {
        void* fmt = fnd.ex_track_format(probe, i);
        if (!fmt) continue;
        const char* mime = 0;
        if (fnd.fmt_get_string(fmt, "mime", &mime) && mime) {
            int64_t d = 0;
            if (fnd.fmt_get_int64(fmt, "durationUs", &d) && d > a->durationUs) a->durationUs = d;
            if (!haveVideo && strncmp(mime, "video/", 6) == 0) {
                haveVideo = fv_track_setup(v, &a->video, src, path, i, fmt, mime);
                if (!haveVideo) fv_track_free(&a->video), memset(&a->video, 0, sizeof a->video);
            } else if (!haveAudio && strncmp(mime, "audio/", 6) == 0 && !v->muted) {
                haveAudio = fv_track_setup(v, &a->audio, src, path, i, fmt, mime);
                if (!haveAudio) fv_track_free(&a->audio), memset(&a->audio, 0, sizeof a->audio);
            }
        }
        fnd.fmt_delete(fmt);
    }
    fnd.ex_delete(probe);
    if (!haveVideo && !haveAudio) {
        char msg[400];
        snprintf(msg, sizeof msg, "VideoPlayer: '%s' no tiene pistas que este dispositivo pueda decodificar", path);
        fv_fail(v, msg);
        free(path);
        return v;
    }
    free(path);
    a->trackCount = haveVideo + haveAudio;
    if (haveVideo && pthread_create(&a->video.thread, 0, fv_track_main, &a->video) == 0) a->video.started = 1;
    if (haveAudio && pthread_create(&a->audio.thread, 0, fv_track_main, &a->audio) == 0) a->audio.started = 1;
    v->opened = 1;
    fv_push(v, FV_EV_OPENED);
    return v;
}

int32_t faset_video_poll(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v) return 0;
    fv_android* a = v->nd;
    if (a) {
        pthread_mutex_lock(&v->lock);
        int ended = v->ended == 1;
        if (ended) v->ended = 2;  /* notificado */
        pthread_mutex_unlock(&v->lock);
        if (ended) fv_push(v, FV_EV_ENDED);
    }
    return fv_pop(v);
}

int32_t faset_video_update(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v) return 0;
    pthread_mutex_lock(&v->lock);
    int fresh = v->serial != v->seen;
    v->seen = v->serial;
    pthread_mutex_unlock(&v->lock);
    return fresh;
}

static void fv_nd_seek(faset_video* v, int64_t us) {
    fv_android* a = v->nd;
    a->seekUs = us;
    a->seekGen++;
    a->endedTracks = 0;
    a->positionUs = us;
    a->clockBaseUs = us;
    if (a->clockStartMs >= 0) a->clockStartMs = fv_now_ms();
    v->ended = 0;
    pthread_cond_broadcast(&a->cond);
}

void faset_video_play(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->nd) return;
    fv_android* a = v->nd;
    pthread_mutex_lock(&v->lock);
    if (v->ended) fv_nd_seek(v, 0);
    a->playing = 1;
    v->playing = 1;
    if (a->clockStartMs < 0) a->clockStartMs = fv_now_ms();
    pthread_cond_broadcast(&a->cond);
    pthread_mutex_unlock(&v->lock);
}

void faset_video_pause(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->nd) return;
    fv_android* a = v->nd;
    pthread_mutex_lock(&v->lock);
    a->clockBaseUs = fv_media_now_us(a);
    a->clockStartMs = -1;
    a->playing = 0;
    v->playing = 0;
    pthread_cond_broadcast(&a->cond);
    pthread_mutex_unlock(&v->lock);
}

void faset_video_seek(void* hv, double seconds) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->nd) return;
    pthread_mutex_lock(&v->lock);
    fv_nd_seek(v, (int64_t)((seconds < 0 ? 0 : seconds) * 1e6));
    pthread_mutex_unlock(&v->lock);
}

double faset_video_position(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->nd) return 0;
    fv_android* a = v->nd;
    pthread_mutex_lock(&v->lock);
    int64_t p = a->playing ? fv_media_now_us(a) : a->clockBaseUs;
    if (a->durationUs > 0 && p > a->durationUs) p = a->durationUs;
    pthread_mutex_unlock(&v->lock);
    return p / 1e6;
}

double faset_video_duration(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->nd || v->nd->durationUs <= 0) return -1;
    return v->nd->durationUs / 1e6;
}

void faset_video_set_volume(void* hv, double volume) {
    faset_video* v = (faset_video*)hv;
    if (v) v->volume = volume < 0 ? 0 : volume > 1 ? 1 : volume;
}

int32_t faset_video_preroll(void* hv, int32_t ms) {
    faset_video* v = (faset_video*)hv;
    if (!v || !v->nd) return 0;
    int64_t end = fv_now_ms() + ms;
    while (fv_now_ms() < end) {
        pthread_mutex_lock(&v->lock);
        int have = v->serial != 0;
        pthread_mutex_unlock(&v->lock);
        if (have) return 1;
        fv_sleep_ms(5);
    }
    return 0;
}

void faset_video_close(void* hv) {
    faset_video* v = (faset_video*)hv;
    if (!v) return;
    fv_android* a = v->nd;
    if (a) {
        pthread_mutex_lock(&v->lock);
        a->quit = 1;
        pthread_cond_broadcast(&a->cond);
        pthread_mutex_unlock(&v->lock);
        if (a->video.started) pthread_join(a->video.thread, 0);
        if (a->audio.started) pthread_join(a->audio.thread, 0);
        fv_track_free(&a->video);
        fv_track_free(&a->audio);
        pthread_cond_destroy(&a->cond);
        free(a);
    }
    fv_free(v);
}

#else
/* =========================================================================== sin implementación */

void* faset_video_open(faset_string src, int32_t flags) {
    (void)src;
    faset_video* v = fv_new(flags);
    if (v) fv_fail(v, "VideoPlayer: la reproducción de vídeo aún no está disponible en este sistema");
    return v;
}
int32_t faset_video_poll(void* hv) { return hv ? fv_pop((faset_video*)hv) : 0; }
int32_t faset_video_update(void* hv) { (void)hv; return 0; }
void faset_video_play(void* hv) { (void)hv; }
void faset_video_pause(void* hv) { (void)hv; }
void faset_video_seek(void* hv, double s) { (void)hv; (void)s; }
double faset_video_position(void* hv) { (void)hv; return 0; }
double faset_video_duration(void* hv) { (void)hv; return -1; }
void faset_video_set_volume(void* hv, double v) { (void)hv; (void)v; }
int32_t faset_video_preroll(void* hv, int32_t ms) { (void)hv; (void)ms; return 0; }
void faset_video_close(void* hv) { if (hv) fv_free((faset_video*)hv); }
#endif
)FASET";
