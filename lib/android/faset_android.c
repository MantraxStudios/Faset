/* =============================================================================
 *  Faset - capa nativa de Android (NativeActivity + android_native_app_glue).
 *
 *  'faset build --target android' compila este archivo junto al programa y al
 *  pegamento del NDK (android_native_app_glue.c) en lib<App>.so, que se empaqueta
 *  en un APK sin Java ni Gradle.
 *
 *  Hilos:
 *    - el hilo del pegamento (android_main) atiende los comandos de la actividad
 *      (ventana creada/destruida, foco, rotación...) y la entrada táctil/teclado;
 *    - el programa ('main' generado por Faset) corre en su propio hilo, así un
 *      programa de consola que tarda (o espera en ReadLine) nunca bloquea la
 *      actividad (no hay ANR).
 *  Ambos se comunican con una cola de eventos protegida por un mutex. std.ui usa
 *  las funciones faset_android_* y faset_ttf_* de abajo (declaradas 'extern').
 *
 *  stdout y stderr se redirigen a logcat (etiqueta = nombre de la app), así
 *  Console.WriteLine se ve con 'faset run --target android' o 'adb logcat'.
 *
 *  Texto: el NDK no expone FreeType, así que las fuentes del sistema
 *  (/system/fonts/Roboto-Regular.ttf) se rasterizan con stb_truetype (dominio público).
 * ============================================================================= */
#define _GNU_SOURCE 1
#include <android_native_app_glue.h>
#include <android/configuration.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <android/log.h>
#include <android/looper.h>
#include <android/native_window.h>
#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"

/* Lo genera el compilador de Faset (nombre de la app = etiqueta de logcat). */
extern const char faset_android_tag[];
/* Punto de entrada generado por Faset. */
extern int main(int argc, char** argv);

/* Tipos de evento que entiende std.ui (NativeWindow de Android). */
enum {
    FA_RESIZE = 1, FA_EXPOSE = 2, FA_CLOSE = 3, FA_MOVE = 4, FA_DOWN = 5, FA_UP = 6,
    FA_LEAVE = 7, FA_KEY = 8, FA_CHAR = 9, FA_FOCUS_LOST = 10
};

typedef struct { int32_t kind, x, y, key, ch, meta, w, h; } fa_event;

#define FA_QUEUE 512

static struct android_app* g_app;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static fa_event g_queue[FA_QUEUE];
static int g_head, g_count;
static ANativeWindow* g_window;    /* protegido por g_lock */
static int g_win_w, g_win_h;       /* último tamaño comunicado */
static int g_closing;
static volatile int g_program_done;
static int g_exit_code;
static float g_density = 1.0f;
static __thread JNIEnv* t_env;

/* ------------------------------------------------------------------ cola */

/* Requiere g_lock. Los movimientos seguidos se fusionan. */
static void push_locked(fa_event e) {
    if (e.kind == FA_MOVE && g_count > 0) {
        fa_event* last = &g_queue[(g_head + g_count - 1) % FA_QUEUE];
        if (last->kind == FA_MOVE) {
            *last = e;
            return;
        }
    }
    if (g_count == FA_QUEUE) { /* llena: se descarta la más antigua */
        g_head = (g_head + 1) % FA_QUEUE;
        g_count--;
    }
    g_queue[(g_head + g_count) % FA_QUEUE] = e;
    g_count++;
    pthread_cond_broadcast(&g_cond);
}

static void push(int kind, int x, int y) {
    fa_event e;
    memset(&e, 0, sizeof e);
    e.kind = kind;
    e.x = x;
    e.y = y;
    pthread_mutex_lock(&g_lock);
    push_locked(e);
    pthread_mutex_unlock(&g_lock);
}

/* Requiere g_lock: si la ventana cambió de tamaño (rotación...), lo comunica. */
static void check_size_locked(void) {
    if (!g_window) return;
    int w = ANativeWindow_getWidth(g_window), h = ANativeWindow_getHeight(g_window);
    if (w <= 0 || h <= 0 || (w == g_win_w && h == g_win_h)) return;
    g_win_w = w;
    g_win_h = h;
    fa_event e;
    memset(&e, 0, sizeof e);
    e.kind = FA_RESIZE;
    e.w = w;
    e.h = h;
    push_locked(e);
}

static void update_density(void) {
    int dpi = g_app && g_app->config ? AConfiguration_getDensity(g_app->config) : 0;
    if (dpi <= 0 || dpi == ACONFIGURATION_DENSITY_ANY || dpi == ACONFIGURATION_DENSITY_NONE) dpi = 160;
    g_density = dpi / 160.0f;
}

/* ------------------------------------------------------------------ JNI */

static JNIEnv* jni(void) {
    if (!t_env && g_app) (*g_app->activity->vm)->AttachCurrentThread(g_app->activity->vm, &t_env, NULL);
    return t_env;
}

static void jni_clear(JNIEnv* env) {
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
}

static jobject system_service(JNIEnv* env, const char* name) {
    jobject act = g_app->activity->clazz;
    jclass cls = (*env)->GetObjectClass(env, act);
    jmethodID m = (*env)->GetMethodID(env, cls, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    jstring s = (*env)->NewStringUTF(env, name);
    jobject r = m ? (*env)->CallObjectMethod(env, act, m, s) : NULL;
    jni_clear(env);
    (*env)->DeleteLocalRef(env, s);
    (*env)->DeleteLocalRef(env, cls);
    return r;
}

/* Carácter Unicode de una tecla (KeyEvent.getUnicodeChar). */
static int unicode_char(int32_t keycode, int32_t meta) {
    JNIEnv* env = jni();
    if (!env) return 0;
    jclass cls = (*env)->FindClass(env, "android/view/KeyEvent");
    if (!cls) {
        jni_clear(env);
        return 0;
    }
    jmethodID ctor = (*env)->GetMethodID(env, cls, "<init>", "(II)V");
    jmethodID get = (*env)->GetMethodID(env, cls, "getUnicodeChar", "(I)I");
    int r = 0;
    if (ctor && get) {
        jobject ev = (*env)->NewObject(env, cls, ctor, AKEY_EVENT_ACTION_DOWN, keycode);
        if (ev) {
            r = (*env)->CallIntMethod(env, ev, get, meta);
            (*env)->DeleteLocalRef(env, ev);
        }
    }
    jni_clear(env);
    (*env)->DeleteLocalRef(env, cls);
    return r;
}

/* Muestra u oculta el teclado en pantalla (InputMethodManager). */
void faset_android_text_input(int32_t on) {
    JNIEnv* env = jni();
    if (!env) {
        if (on) ANativeActivity_showSoftInput(g_app->activity, ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT);
        else ANativeActivity_hideSoftInput(g_app->activity, 0);
        return;
    }
    jobject act = g_app->activity->clazz;
    jobject imm = system_service(env, "input_method");
    jclass actCls = (*env)->GetObjectClass(env, act);
    jmethodID getWindow = (*env)->GetMethodID(env, actCls, "getWindow", "()Landroid/view/Window;");
    jobject window = getWindow ? (*env)->CallObjectMethod(env, act, getWindow) : NULL;
    jni_clear(env);
    jobject decor = NULL;
    if (window) {
        jclass wCls = (*env)->GetObjectClass(env, window);
        jmethodID getDecor = (*env)->GetMethodID(env, wCls, "getDecorView", "()Landroid/view/View;");
        decor = getDecor ? (*env)->CallObjectMethod(env, window, getDecor) : NULL;
        jni_clear(env);
        (*env)->DeleteLocalRef(env, wCls);
    }
    int done = 0;
    if (imm && decor) {
        jclass immCls = (*env)->GetObjectClass(env, imm);
        if (on) {
            jmethodID show = (*env)->GetMethodID(env, immCls, "showSoftInput", "(Landroid/view/View;I)Z");
            if (show) done = (*env)->CallBooleanMethod(env, imm, show, decor, 0);
        } else {
            jclass vCls = (*env)->GetObjectClass(env, decor);
            jmethodID token = (*env)->GetMethodID(env, vCls, "getWindowToken", "()Landroid/os/IBinder;");
            jobject binder = token ? (*env)->CallObjectMethod(env, decor, token) : NULL;
            jmethodID hide = (*env)->GetMethodID(env, immCls, "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z");
            if (binder && hide) done = (*env)->CallBooleanMethod(env, imm, hide, binder, 0);
            (*env)->DeleteLocalRef(env, vCls);
        }
        jni_clear(env);
        (*env)->DeleteLocalRef(env, immCls);
    }
    if (!done) {
        if (on) ANativeActivity_showSoftInput(g_app->activity, ANATIVEACTIVITY_SHOW_SOFT_INPUT_IMPLICIT);
        else ANativeActivity_hideSoftInput(g_app->activity, 0);
    }
    if (decor) (*env)->DeleteLocalRef(env, decor);
    if (window) (*env)->DeleteLocalRef(env, window);
    if (imm) (*env)->DeleteLocalRef(env, imm);
    (*env)->DeleteLocalRef(env, actCls);
}

/* Portapapeles del sistema (ClipboardManager). Devuelve false si no está disponible. */
int32_t faset_android_clipboard_set(const uint8_t* text, int32_t len) {
    JNIEnv* env = jni();
    if (!env) return 0;
    jobject cm = system_service(env, "clipboard");
    if (!cm) return 0;
    char* z = (char*)malloc((size_t)len + 1);
    memcpy(z, text, (size_t)len);
    z[len] = 0;
    jstring js = (*env)->NewStringUTF(env, z);
    free(z);
    jclass clipCls = (*env)->FindClass(env, "android/content/ClipData");
    int ok = 0;
    if (clipCls && js) {
        jmethodID plain = (*env)->GetStaticMethodID(env, clipCls, "newPlainText",
                                                    "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;");
        jstring label = (*env)->NewStringUTF(env, "faset");
        jobject clip = plain ? (*env)->CallStaticObjectMethod(env, clipCls, plain, label, js) : NULL;
        jni_clear(env);
        if (clip) {
            jclass cmCls = (*env)->GetObjectClass(env, cm);
            jmethodID set = (*env)->GetMethodID(env, cmCls, "setPrimaryClip", "(Landroid/content/ClipData;)V");
            if (set) {
                (*env)->CallVoidMethod(env, cm, set, clip);
                ok = !(*env)->ExceptionCheck(env);
            }
            jni_clear(env);
            (*env)->DeleteLocalRef(env, cmCls);
            (*env)->DeleteLocalRef(env, clip);
        }
        (*env)->DeleteLocalRef(env, label);
    }
    jni_clear(env);
    if (clipCls) (*env)->DeleteLocalRef(env, clipCls);
    if (js) (*env)->DeleteLocalRef(env, js);
    (*env)->DeleteLocalRef(env, cm);
    return ok;
}

/* Texto del portapapeles en UTF-8 (reservado con malloc; se libera con Memory.Free). -1 si no hay. */
int32_t faset_android_clipboard_get(uint8_t** out) {
    *out = NULL;
    JNIEnv* env = jni();
    if (!env) return -1;
    jobject cm = system_service(env, "clipboard");
    if (!cm) return -1;
    int32_t n = -1;
    jclass cmCls = (*env)->GetObjectClass(env, cm);
    jmethodID get = (*env)->GetMethodID(env, cmCls, "getPrimaryClip", "()Landroid/content/ClipData;");
    jobject clip = get ? (*env)->CallObjectMethod(env, cm, get) : NULL;
    jni_clear(env);
    if (clip) {
        jclass clipCls = (*env)->GetObjectClass(env, clip);
        jmethodID count = (*env)->GetMethodID(env, clipCls, "getItemCount", "()I");
        jmethodID at = (*env)->GetMethodID(env, clipCls, "getItemAt", "(I)Landroid/content/ClipData$Item;");
        if (count && at && (*env)->CallIntMethod(env, clip, count) > 0) {
            jobject item = (*env)->CallObjectMethod(env, clip, at, 0);
            if (item) {
                jclass itemCls = (*env)->GetObjectClass(env, item);
                jmethodID coerce = (*env)->GetMethodID(env, itemCls, "coerceToText",
                                                       "(Landroid/content/Context;)Ljava/lang/CharSequence;");
                jobject cs = coerce ? (*env)->CallObjectMethod(env, item, coerce, g_app->activity->clazz) : NULL;
                jni_clear(env);
                if (cs) {
                    jclass csCls = (*env)->GetObjectClass(env, cs);
                    jmethodID toString = (*env)->GetMethodID(env, csCls, "toString", "()Ljava/lang/String;");
                    jstring s = toString ? (jstring)(*env)->CallObjectMethod(env, cs, toString) : NULL;
                    jni_clear(env);
                    if (s) {
                        const char* utf = (*env)->GetStringUTFChars(env, s, NULL);
                        if (utf) {
                            n = (int32_t)strlen(utf);
                            *out = (uint8_t*)malloc((size_t)n + 1);
                            memcpy(*out, utf, (size_t)n + 1);
                            (*env)->ReleaseStringUTFChars(env, s, utf);
                        }
                        (*env)->DeleteLocalRef(env, s);
                    }
                    (*env)->DeleteLocalRef(env, csCls);
                    (*env)->DeleteLocalRef(env, cs);
                }
                (*env)->DeleteLocalRef(env, itemCls);
                (*env)->DeleteLocalRef(env, item);
            }
        }
        jni_clear(env);
        (*env)->DeleteLocalRef(env, clipCls);
        (*env)->DeleteLocalRef(env, clip);
    }
    (*env)->DeleteLocalRef(env, cmCls);
    (*env)->DeleteLocalRef(env, cm);
    return n;
}

/* Para otras capas nativas (lib/android/faset_webview.c): JNIEnv del hilo actual y la actividad. */
JNIEnv* faset_android_jni(void) { return jni(); }
jobject faset_android_activity(void) { return g_app ? g_app->activity->clazz : NULL; }

/* ------------------------------------------------------------------ actividad (hilo del pegamento) */

static void on_cmd(struct android_app* app, int32_t cmd) {
    pthread_mutex_lock(&g_lock);
    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            g_window = app->window;
            if (g_window) ANativeWindow_setBuffersGeometry(g_window, 0, 0, WINDOW_FORMAT_RGBX_8888);
            g_win_w = g_win_h = 0;
            check_size_locked();
            push_locked((fa_event){FA_EXPOSE, 0, 0, 0, 0, 0, 0, 0});
            break;
        case APP_CMD_TERM_WINDOW:
            g_window = NULL;  /* el programa deja de dibujar antes de que la ventana se destruya */
            break;
        case APP_CMD_CONFIG_CHANGED:
            update_density();
            /* fallthrough */
        case APP_CMD_WINDOW_RESIZED:
        case APP_CMD_CONTENT_RECT_CHANGED:
        case APP_CMD_WINDOW_REDRAW_NEEDED:
            check_size_locked();
            push_locked((fa_event){FA_EXPOSE, 0, 0, 0, 0, 0, 0, 0});
            break;
        case APP_CMD_LOST_FOCUS:
            push_locked((fa_event){FA_FOCUS_LOST, 0, 0, 0, 0, 0, 0, 0});
            break;
        case APP_CMD_DESTROY:
            g_closing = 1;
            push_locked((fa_event){FA_CLOSE, 0, 0, 0, 0, 0, 0, 0});
            break;
        default:
            break;
    }
    pthread_cond_broadcast(&g_cond);
    pthread_mutex_unlock(&g_lock);
}

static int32_t on_input(struct android_app* app, AInputEvent* ev) {
    (void)app;
    int32_t type = AInputEvent_getType(ev);
    if (type == AINPUT_EVENT_TYPE_MOTION) {
        int32_t action = AMotionEvent_getAction(ev) & AMOTION_EVENT_ACTION_MASK;
        int x = (int)AMotionEvent_getX(ev, 0), y = (int)AMotionEvent_getY(ev, 0);
        switch (action) {
            case AMOTION_EVENT_ACTION_DOWN:
                push(FA_MOVE, x, y);
                push(FA_DOWN, x, y);
                break;
            case AMOTION_EVENT_ACTION_MOVE:
                push(FA_MOVE, x, y);
                break;
            case AMOTION_EVENT_ACTION_UP:
                push(FA_MOVE, x, y);
                push(FA_UP, x, y);
                push(FA_LEAVE, x, y);
                break;
            case AMOTION_EVENT_ACTION_CANCEL:
                push(FA_UP, -100000, -100000);
                push(FA_LEAVE, 0, 0);
                break;
            default:
                break;
        }
        return 1;
    }
    if (type == AINPUT_EVENT_TYPE_KEY) {
        int32_t code = AKeyEvent_getKeyCode(ev);
        if (code == AKEYCODE_BACK || code == AKEYCODE_VOLUME_UP || code == AKEYCODE_VOLUME_DOWN ||
            code == AKEYCODE_VOLUME_MUTE || code == AKEYCODE_HOME || code == AKEYCODE_POWER)
            return 0;  /* el sistema: atrás cierra la actividad, volumen... */
        if (AKeyEvent_getAction(ev) != AKEY_EVENT_ACTION_DOWN) return 1;
        int32_t meta = AKeyEvent_getMetaState(ev);
        int ch = unicode_char(code, meta);
        fa_event e;
        memset(&e, 0, sizeof e);
        e.kind = FA_KEY;
        e.key = code;
        e.meta = meta;
        e.ch = ch;
        pthread_mutex_lock(&g_lock);
        push_locked(e);
        if (ch > 0 && code != AKEYCODE_ENTER && code != AKEYCODE_TAB) {
            e.kind = FA_CHAR;
            push_locked(e);
        }
        pthread_mutex_unlock(&g_lock);
        return 1;
    }
    return 0;
}

/* ------------------------------------------------------------------ API para std.ui (hilo del programa) */

/* Espera a que exista la ventana. Devuelve 0 si la actividad se cierra antes. */
int32_t faset_android_wait_window(void) {
    pthread_mutex_lock(&g_lock);
    while (!g_window && !g_closing) pthread_cond_wait(&g_cond, &g_lock);
    int ok = g_window != NULL;
    pthread_mutex_unlock(&g_lock);
    return ok;
}

float faset_android_density(void) { return g_density; }
int32_t faset_android_width(void) { return g_win_w; }
int32_t faset_android_height(void) { return g_win_h; }

/* Saca un evento de la cola en ev[0..7] = {tipo, x, y, tecla, carácter, meta, ancho, alto}. */
int32_t faset_android_next(int32_t* ev) {
    pthread_mutex_lock(&g_lock);
    int got = 0;
    if (g_count > 0) {
        fa_event e = g_queue[g_head];
        g_head = (g_head + 1) % FA_QUEUE;
        g_count--;
        memcpy(ev, &e, sizeof e);
        got = 1;
    }
    pthread_mutex_unlock(&g_lock);
    return got;
}

/* Espera hasta 'ms' milisegundos a que llegue un evento. */
void faset_android_wait(int32_t ms) {
    pthread_mutex_lock(&g_lock);
    if (g_count == 0 && !g_closing && ms > 0) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += ms / 1000;
        ts.tv_nsec += (long)(ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec++;
            ts.tv_nsec -= 1000000000L;
        }
        pthread_cond_timedwait(&g_cond, &g_lock, &ts);
    }
    pthread_mutex_unlock(&g_lock);
}

/* Copia el lienzo (0x00RRGGBB, w x h) a la ventana. */
void faset_android_present(const uint32_t* px, int32_t w, int32_t h) {
    pthread_mutex_lock(&g_lock);
    if (!g_window) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    check_size_locked();
    ANativeWindow_Buffer b;
    if (ANativeWindow_lock(g_window, &b, NULL) == 0) {
        int cw = w < b.width ? w : b.width, ch = h < b.height ? h : b.height;
        if (b.format == WINDOW_FORMAT_RGB_565) {
            for (int y = 0; y < b.height; y++) {
                uint16_t* dst = (uint16_t*)b.bits + (size_t)y * b.stride;
                if (y >= ch) {
                    memset(dst, 0, (size_t)b.width * 2);
                    continue;
                }
                const uint32_t* src = px + (size_t)y * w;
                for (int x = 0; x < cw; x++) {
                    uint32_t c = src[x];
                    dst[x] = (uint16_t)(((c >> 8) & 0xf800) | ((c >> 5) & 0x07e0) | ((c >> 3) & 0x001f));
                }
                for (int x = cw; x < b.width; x++) dst[x] = 0;
            }
        } else {
            /* RGBA_8888 / RGBX_8888: bytes R, G, B, A en memoria. */
            for (int y = 0; y < b.height; y++) {
                uint32_t* dst = (uint32_t*)b.bits + (size_t)y * b.stride;
                if (y >= ch) {
                    for (int x = 0; x < b.width; x++) dst[x] = 0xff000000u;
                    continue;
                }
                const uint32_t* src = px + (size_t)y * w;
                for (int x = 0; x < cw; x++) {
                    uint32_t c = src[x];
                    dst[x] = 0xff000000u | ((c >> 16) & 0xffu) | (c & 0xff00u) | ((c & 0xffu) << 16);
                }
                for (int x = cw; x < b.width; x++) dst[x] = 0xff000000u;
            }
        }
        ANativeWindow_unlockAndPost(g_window);
    }
    pthread_mutex_unlock(&g_lock);
}

/* ------------------------------------------------------------------ fuentes (stb_truetype) */

typedef struct {
    stbtt_fontinfo info;
    unsigned char* data;
    float scale;
    int fakeBold;
} faset_ttf;

static unsigned char* read_all(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* d = n > 0 ? (unsigned char*)malloc((size_t)n) : NULL;
    if (d && fread(d, 1, (size_t)n, f) != (size_t)n) {
        free(d);
        d = NULL;
    }
    fclose(f);
    return d;
}

/* Abre una fuente TrueType/OpenType a 'px' píxeles por em. 'fakeBold' engrosa los glifos. */
void* faset_ttf_open(const uint8_t* path, float px, int32_t fakeBold, float* ascent, float* descent) {
    unsigned char* data = read_all((const char*)path);
    if (!data) return NULL;
    faset_ttf* f = (faset_ttf*)calloc(1, sizeof(faset_ttf));
    int off = stbtt_GetFontOffsetForIndex(data, 0);
    if (off < 0 || !stbtt_InitFont(&f->info, data, off)) {
        free(data);
        free(f);
        return NULL;
    }
    f->data = data;
    f->scale = stbtt_ScaleForMappingEmToPixels(&f->info, px);
    f->fakeBold = fakeBold;
    int asc, desc, gap;
    stbtt_GetFontVMetrics(&f->info, &asc, &desc, &gap);
    *ascent = ceilf(asc * f->scale);
    *descent = ceilf(-desc * f->scale);
    return f;
}

/* Rasteriza un carácter. 'coverage' (w x h, 0..255) se reserva con malloc. */
int32_t faset_ttf_glyph(void* handle, uint32_t cp, uint8_t** coverage, int32_t* w, int32_t* h, int32_t* left,
                        int32_t* top, float* advance) {
    faset_ttf* f = (faset_ttf*)handle;
    *coverage = NULL;
    *w = *h = *left = *top = 0;
    *advance = 0;
    if (!f) return 0;
    int glyph = stbtt_FindGlyphIndex(&f->info, (int)cp);
    int adv, lsb;
    stbtt_GetGlyphHMetrics(&f->info, glyph, &adv, &lsb);
    *advance = adv * f->scale + (f->fakeBold ? 1.0f : 0.0f);
    int bw = 0, bh = 0, xoff = 0, yoff = 0;
    unsigned char* bmp = stbtt_GetGlyphBitmap(&f->info, f->scale, f->scale, glyph, &bw, &bh, &xoff, &yoff);
    if (!bmp || bw <= 0 || bh <= 0) {
        if (bmp) stbtt_FreeBitmap(bmp, NULL);
        return 1;
    }
    int ow = bw + (f->fakeBold ? 1 : 0);
    uint8_t* out = (uint8_t*)malloc((size_t)ow * bh);
    for (int y = 0; y < bh; y++)
        for (int x = 0; x < ow; x++) {
            int a = x < bw ? bmp[y * bw + x] : 0;
            if (f->fakeBold && x > 0) {
                int b = bmp[y * bw + x - 1];
                if (b > a) a = b;
            }
            out[y * ow + x] = (uint8_t)a;
        }
    stbtt_FreeBitmap(bmp, NULL);
    *coverage = out;
    *w = ow;
    *h = bh;
    *left = xoff;
    *top = -yoff;
    return 1;
}

/* ------------------------------------------------------------------ stdout/stderr -> logcat */

static int g_out_pipe[2] = {-1, -1}, g_err_pipe[2] = {-1, -1};
static pthread_t g_out_thread, g_err_thread;
static int g_log_threads;

static void* log_pump(void* arg) {
    int fd = (int)(intptr_t)arg;
    int prio = fd == g_err_pipe[0] ? ANDROID_LOG_WARN : ANDROID_LOG_INFO;
    char buf[4096];
    size_t used = 0;
    for (;;) {
        ssize_t n = read(fd, buf + used, sizeof buf - 1 - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        used += (size_t)n;
        size_t start = 0;
        for (size_t i = 0; i < used; i++)
            if (buf[i] == '\n') {
                buf[i] = 0;
                __android_log_write(prio, faset_android_tag, buf + start);
                start = i + 1;
            }
        if (start == 0 && used == sizeof buf - 1) { /* línea muy larga */
            buf[used] = 0;
            __android_log_write(prio, faset_android_tag, buf);
            used = 0;
        } else if (start > 0) {
            memmove(buf, buf + start, used - start);
            used -= start;
        }
    }
    if (used > 0) {
        buf[used] = 0;
        __android_log_write(prio, faset_android_tag, buf);
    }
    close(fd);
    return NULL;
}

static void redirect_stdio(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    if (pipe(g_out_pipe) != 0 || pipe(g_err_pipe) != 0) return;
    dup2(g_out_pipe[1], 1);
    dup2(g_err_pipe[1], 2);
    close(g_out_pipe[1]);
    close(g_err_pipe[1]);
    pthread_create(&g_out_thread, NULL, log_pump, (void*)(intptr_t)g_out_pipe[0]);
    pthread_create(&g_err_thread, NULL, log_pump, (void*)(intptr_t)g_err_pipe[0]);
    g_log_threads = 1;
}

/* Vacía y cierra stdout/stderr para que logcat reciba las últimas líneas. */
static void flush_stdio(void) {
    fflush(stdout);
    fflush(stderr);
    if (!g_log_threads) return;
    int devnull = open("/dev/null", O_WRONLY);
    dup2(devnull, 1);
    dup2(devnull, 2);
    close(devnull);
    pthread_join(g_out_thread, NULL);
    pthread_join(g_err_thread, NULL);
    g_log_threads = 0;
}

/* ------------------------------------------------------------------ entrada */

static void* program_thread(void* arg) {
    (void)arg;
    char* argv[2] = {(char*)faset_android_tag, NULL};
    jni();
    int r = main(1, argv);
    fflush(stdout);
    fflush(stderr);
    if (t_env) (*g_app->activity->vm)->DetachCurrentThread(g_app->activity->vm);
    t_env = NULL;
    g_exit_code = r;
    g_program_done = 1;
    ALooper_wake(g_app->looper);
    return NULL;
}

static void pump(int timeoutMs) {
    for (;;) {
        int events = 0;
        struct android_poll_source* src = NULL;
        int id = ALooper_pollOnce(timeoutMs, NULL, &events, (void**)&src);
        timeoutMs = 0;
        if (id >= 0) {
            if (src) src->process(g_app, src);
            continue;
        }
        if (id == ALOOPER_POLL_CALLBACK) continue;
        break;
    }
}

void android_main(struct android_app* app) {
    g_app = app;
    app->onAppCmd = on_cmd;
    app->onInputEvent = on_input;
    jni();
    update_density();
    redirect_stdio();

    /* Carpeta de trabajo = almacenamiento interno de la app (rutas relativas, HOME, TMPDIR). */
    const char* data = app->activity->internalDataPath;
    if (data) {
        mkdir(data, 0700);
        if (chdir(data) == 0) {
            setenv("HOME", data, 1);
            setenv("TMPDIR", data, 1);
        }
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    pthread_t prog;
    pthread_create(&prog, &attr, program_thread, NULL);
    pthread_attr_destroy(&attr);

    int finishing = 0;
    while (!app->destroyRequested) {
        pump(-1);
        if (g_program_done && !finishing) {
            finishing = 1;
            ANativeActivity_finish(app->activity);
        }
    }
    /* La actividad se cierra: el programa recibió FA_CLOSE; se le da un momento para terminar. */
    for (int i = 0; i < 200 && !g_program_done; i++) usleep(10000);
    __android_log_print(ANDROID_LOG_INFO, faset_android_tag, "[faset] fin del programa (código %d)", g_exit_code);
    flush_stdio();
    if (t_env) (*app->activity->vm)->DetachCurrentThread(app->activity->vm);
    /* Un proceso por ejecución: así 'faset run' sabe cuándo terminó y cada arranque empieza limpio. */
    _exit(g_exit_code);
}

/* ------------------------------------------------------------------ recursos del APK (assets/)
   Los <Asset Include="..."/> del .fstproj se empaquetan sin comprimir en assets/ con su ruta
   relativa. Cualquier módulo puede leerlos con AAssetManager (std.audio lo hace así). */
#include <android/asset_manager.h>

AAssetManager* faset_android_asset_manager(void) { return g_app ? g_app->activity->assetManager : NULL; }

/* Lee un recurso entero en memoria nueva (malloc, terminada en 0; se libera con Memory.Free).
   Devuelve 1 si existe. */
int32_t faset_android_asset_read(const uint8_t* name, uint8_t** data, int64_t* len) {
    *data = NULL;
    *len = 0;
    AAssetManager* m = faset_android_asset_manager();
    if (!m || !name) return 0;
    while (name[0] == '.' && name[1] == '/') name += 2;
    AAsset* a = AAssetManager_open(m, (const char*)name, AASSET_MODE_BUFFER);
    if (!a) return 0;
    off_t n = AAsset_getLength(a);
    uint8_t* buf = (uint8_t*)malloc((size_t)n + 1);
    int ok = buf && AAsset_read(a, buf, (size_t)n) == n;
    AAsset_close(a);
    if (!ok) {
        free(buf);
        return 0;
    }
    buf[n] = 0;
    *data = buf;
    *len = (int64_t)n;
    return 1;
}
