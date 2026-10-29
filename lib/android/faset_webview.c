/* =============================================================================
 *  Faset - WebView de std.ui en Android (android.webkit.WebView por JNI).
 *
 *  El APK no lleva código Java (hasCode=false), así que el puente
 *  (webview/WebViewBridge.java) va ya compilado a dex dentro de este archivo
 *  (faset_webview_dex.h) y se carga en ejecución con InMemoryDexClassLoader
 *  (API 26+) o DexClassLoader desde la caché de código (API 24-25).
 *
 *  Cada WebView es un panel (WindowManager) sobre la actividad, colocado en los
 *  límites del control en píxeles físicos. El puente avisa de la navegación, el
 *  título y los mensajes de window.faset.postMessage llamando a onEvent (nativo,
 *  registrado aquí): solo se encolan (con un mutex) y std.ui los recoge en su
 *  bucle con faset_wv_next_event. Nunca se llama a código Faset desde Java.
 * ============================================================================= */
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>

#include "faset_webview_dex.h"

/* De faset_android.c. */
extern JNIEnv* faset_android_jni(void);
extern jobject faset_android_activity(void);

#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, "faset", __VA_ARGS__)

/* ------------------------------------------------------------------ texto UTF-8 <-> UTF-16 */

static jstring utf8_to_jstring(JNIEnv* env, const uint8_t* s, int32_t n) {
    jchar* buf = (jchar*)malloc(((size_t)(n > 0 ? n : 0) + 1) * 2 * sizeof(jchar));
    if (!buf) return NULL;
    int32_t i = 0, k = 0;
    while (i < n) {
        uint32_t c = s[i], cp = 0xFFFD;
        int extra = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : c >= 0xC0 ? 1 : 0;
        if (c < 0x80) cp = c;
        else if (extra) {
            cp = c & (0x3F >> extra);
            int ok = 1;
            for (int j = 1; j <= extra; j++) {
                if (i + j >= n || (s[i + j] & 0xC0) != 0x80) {
                    ok = 0;
                    break;
                }
                cp = (cp << 6) | (s[i + j] & 0x3F);
            }
            if (ok) i += extra;
            else cp = 0xFFFD;
        }
        i++;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            buf[k++] = (jchar)(0xD800 + (cp >> 10));
            buf[k++] = (jchar)(0xDC00 + (cp & 0x3FF));
        } else {
            buf[k++] = (jchar)cp;
        }
    }
    jstring r = (*env)->NewString(env, buf, k);
    free(buf);
    return r;
}

/* Copia UTF-8 (malloc) de un String de Java; *len = bytes. */
static char* jstring_to_utf8(JNIEnv* env, jstring js, int32_t* len) {
    *len = 0;
    if (!js) {
        char* e = (char*)malloc(1);
        if (e) e[0] = 0;
        return e;
    }
    jsize n = (*env)->GetStringLength(env, js);
    const jchar* u = (*env)->GetStringChars(env, js, NULL);
    char* out = (char*)malloc((size_t)n * 3 + 1);
    int32_t k = 0;
    for (jsize i = 0; out && u && i < n; i++) {
        uint32_t c = u[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < n && u[i + 1] >= 0xDC00 && u[i + 1] < 0xE000) {
            c = 0x10000 + ((c - 0xD800) << 10) + (u[i + 1] - 0xDC00);
            i++;
        }
        if (c < 0x80) out[k++] = (char)c;
        else if (c < 0x800) {
            out[k++] = (char)(0xC0 | (c >> 6));
            out[k++] = (char)(0x80 | (c & 0x3F));
        } else if (c < 0x10000) {
            out[k++] = (char)(0xE0 | (c >> 12));
            out[k++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[k++] = (char)(0x80 | (c & 0x3F));
        } else {
            out[k++] = (char)(0xF0 | (c >> 18));
            out[k++] = (char)(0x80 | ((c >> 12) & 0x3F));
            out[k++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[k++] = (char)(0x80 | (c & 0x3F));
        }
    }
    if (u) (*env)->ReleaseStringChars(env, js, u);
    if (out) out[k] = 0;
    *len = k;
    return out;
}

/* ------------------------------------------------------------------ cola de eventos */

typedef struct wv_event {
    int32_t id, kind, len;
    char* text;
    struct wv_event* next;
} wv_event;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static wv_event* g_head;
static wv_event* g_tail;

/* WebViewBridge.onEvent (hilo de la interfaz de Android o del puente de JavaScript). */
static void JNICALL on_event(JNIEnv* env, jclass cls, jlong id, jint kind, jstring text) {
    (void)cls;
    wv_event* e = (wv_event*)calloc(1, sizeof *e);
    if (!e) return;
    e->id = (int32_t)id;
    e->kind = kind;
    e->text = jstring_to_utf8(env, text, &e->len);
    pthread_mutex_lock(&g_lock);
    if (g_tail) g_tail->next = e;
    else g_head = e;
    g_tail = e;
    pthread_mutex_unlock(&g_lock);
}

int32_t faset_wv_next_event(int32_t* id, int32_t* kind, uint8_t** text, int32_t* len) {
    pthread_mutex_lock(&g_lock);
    wv_event* e = g_head;
    if (e) {
        g_head = e->next;
        if (!g_head) g_tail = NULL;
    }
    pthread_mutex_unlock(&g_lock);
    if (!e) return 0;
    *id = e->id;
    *kind = e->kind;
    *text = (uint8_t*)e->text;
    *len = e->len;
    free(e);
    return 1;
}

/* ------------------------------------------------------------------ carga del puente */

static jclass g_bridge;      /* faset.WebViewBridge (referencia global) */
static int g_tried;
static jmethodID m_ctor, m_bounds, m_navigate, m_loadHtml, m_eval, m_command, m_history, m_release, m_destroy;

static int clear(JNIEnv* env) {
    if (!(*env)->ExceptionCheck(env)) return 0;
    (*env)->ExceptionDescribe(env);
    (*env)->ExceptionClear(env);
    return 1;
}

static jobject call_obj(JNIEnv* env, jobject o, const char* name, const char* sig) {
    jclass c = (*env)->GetObjectClass(env, o);
    jmethodID m = (*env)->GetMethodID(env, c, name, sig);
    jobject r = m ? (*env)->CallObjectMethod(env, o, m) : NULL;
    (*env)->DeleteLocalRef(env, c);
    if (clear(env)) return NULL;
    return r;
}

static int sdk_int(JNIEnv* env) {
    jclass v = (*env)->FindClass(env, "android/os/Build$VERSION");
    if (!v) {
        clear(env);
        return 0;
    }
    jfieldID f = (*env)->GetStaticFieldID(env, v, "SDK_INT", "I");
    int r = f ? (*env)->GetStaticIntField(env, v, f) : 0;
    (*env)->DeleteLocalRef(env, v);
    clear(env);
    return r;
}

/* Crea el cargador de clases con el dex incrustado y devuelve faset.WebViewBridge. */
static jclass load_bridge(JNIEnv* env, jobject activity) {
    jobject parent = call_obj(env, activity, "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject loader = NULL;
    if (sdk_int(env) >= 26) {
        jobject buf = (*env)->NewDirectByteBuffer(env, (void*)faset_webview_dex, (jlong)sizeof faset_webview_dex);
        jclass cls = (*env)->FindClass(env, "dalvik/system/InMemoryDexClassLoader");
        jmethodID ctor = cls ? (*env)->GetMethodID(env, cls, "<init>", "(Ljava/nio/ByteBuffer;Ljava/lang/ClassLoader;)V") : NULL;
        if (ctor) loader = (*env)->NewObject(env, cls, ctor, buf, parent);
        clear(env);
        if (cls) (*env)->DeleteLocalRef(env, cls);
        if (buf) (*env)->DeleteLocalRef(env, buf);
    } else {
        /* API 24-25: el dex se escribe en la caché de código y se carga con DexClassLoader. */
        jobject dir = call_obj(env, activity, "getCodeCacheDir", "()Ljava/io/File;");
        jstring dirPath = dir ? (jstring)call_obj(env, dir, "getAbsolutePath", "()Ljava/lang/String;") : NULL;
        const char* d = dirPath ? (*env)->GetStringUTFChars(env, dirPath, NULL) : NULL;
        if (d) {
            char path[1024];
            snprintf(path, sizeof path, "%s/faset_webview.dex", d);
            FILE* f = fopen(path, "wb");
            if (f) {
                fwrite(faset_webview_dex, 1, sizeof faset_webview_dex, f);
                fclose(f);
                jclass cls = (*env)->FindClass(env, "dalvik/system/DexClassLoader");
                jmethodID ctor = cls ? (*env)->GetMethodID(env, cls, "<init>",
                                                           "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V")
                                     : NULL;
                jstring jp = (*env)->NewStringUTF(env, path);
                if (ctor) loader = (*env)->NewObject(env, cls, ctor, jp, dirPath, NULL, parent);
                clear(env);
                (*env)->DeleteLocalRef(env, jp);
                if (cls) (*env)->DeleteLocalRef(env, cls);
            }
            (*env)->ReleaseStringUTFChars(env, dirPath, d);
        }
        if (dirPath) (*env)->DeleteLocalRef(env, dirPath);
        if (dir) (*env)->DeleteLocalRef(env, dir);
    }
    if (parent) (*env)->DeleteLocalRef(env, parent);
    if (!loader) return NULL;
    jclass lc = (*env)->GetObjectClass(env, loader);
    jmethodID loadClass = (*env)->GetMethodID(env, lc, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    jstring name = (*env)->NewStringUTF(env, "faset.WebViewBridge");
    jclass bridge = (jclass)(*env)->CallObjectMethod(env, loader, loadClass, name);
    clear(env);
    (*env)->DeleteLocalRef(env, name);
    (*env)->DeleteLocalRef(env, lc);
    (*env)->DeleteLocalRef(env, loader);
    return bridge;
}

static int ready(JNIEnv* env) {
    if (g_bridge) return 1;
    if (g_tried) return 0;
    g_tried = 1;
    jobject activity = faset_android_activity();
    if (!env || !activity) return 0;
    jclass local = load_bridge(env, activity);
    if (!local) {
        LOGW("std.ui: no se pudo cargar el puente del WebView");
        return 0;
    }
    JNINativeMethod natives[] = {{"onEvent", "(JILjava/lang/String;)V", (void*)on_event}};
    if ((*env)->RegisterNatives(env, local, natives, 1) != 0) {
        clear(env);
        (*env)->DeleteLocalRef(env, local);
        return 0;
    }
    m_ctor = (*env)->GetMethodID(env, local, "<init>", "(Landroid/app/Activity;J)V");
    m_bounds = (*env)->GetMethodID(env, local, "bounds", "(IIIIZ)V");
    m_navigate = (*env)->GetMethodID(env, local, "navigate", "(Ljava/lang/String;)V");
    m_loadHtml = (*env)->GetMethodID(env, local, "loadHtml", "(Ljava/lang/String;Ljava/lang/String;)V");
    m_eval = (*env)->GetMethodID(env, local, "eval", "(Ljava/lang/String;)V");
    m_command = (*env)->GetMethodID(env, local, "command", "(I)V");
    m_history = (*env)->GetMethodID(env, local, "history", "()I");
    m_release = (*env)->GetMethodID(env, local, "releaseFocus", "()V");
    m_destroy = (*env)->GetMethodID(env, local, "destroy", "()V");
    if (clear(env) || !m_ctor || !m_destroy) {
        (*env)->DeleteLocalRef(env, local);
        return 0;
    }
    g_bridge = (jclass)(*env)->NewGlobalRef(env, local);
    (*env)->DeleteLocalRef(env, local);
    return 1;
}

/* ------------------------------------------------------------------ vistas */

#define WV_MAX 64
static jobject g_views[WV_MAX];  /* WebViewBridge (referencias globales); índice = id - 1 */

static jobject view(int32_t id) { return id >= 1 && id <= WV_MAX ? g_views[id - 1] : NULL; }

int32_t faset_wv_create(uint64_t parent) {
    (void)parent;
    JNIEnv* env = faset_android_jni();
    if (!env || !ready(env)) return 0;
    for (int i = 0; i < WV_MAX; i++) {
        if (g_views[i]) continue;
        jobject o = (*env)->NewObject(env, g_bridge, m_ctor, faset_android_activity(), (jlong)(i + 1));
        if (clear(env) || !o) return 0;
        g_views[i] = (*env)->NewGlobalRef(env, o);
        (*env)->DeleteLocalRef(env, o);
        return i + 1;
    }
    return 0;
}

void faset_wv_destroy(int32_t id) {
    JNIEnv* env = faset_android_jni();
    jobject o = view(id);
    if (!env || !o) return;
    (*env)->CallVoidMethod(env, o, m_destroy);
    clear(env);
    (*env)->DeleteGlobalRef(env, o);
    g_views[id - 1] = NULL;
}

void faset_wv_bounds(int32_t id, int32_t x, int32_t y, int32_t w, int32_t h, int32_t visible) {
    JNIEnv* env = faset_android_jni();
    jobject o = view(id);
    if (!env || !o) return;
    (*env)->CallVoidMethod(env, o, m_bounds, x, y, w, h, (jboolean)(visible != 0));
    clear(env);
}

static void call_str(int32_t id, jmethodID m, const uint8_t* s, int32_t n) {
    JNIEnv* env = faset_android_jni();
    jobject o = view(id);
    if (!env || !o) return;
    jstring js = utf8_to_jstring(env, s, n);
    if (!js) return;
    (*env)->CallVoidMethod(env, o, m, js);
    clear(env);
    (*env)->DeleteLocalRef(env, js);
}

void faset_wv_navigate(int32_t id, const uint8_t* url, int32_t len) { call_str(id, m_navigate, url, len); }

void faset_wv_eval(int32_t id, const uint8_t* js, int32_t len) { call_str(id, m_eval, js, len); }

void faset_wv_load_html(int32_t id, const uint8_t* html, int32_t len, const uint8_t* base, int32_t baseLen) {
    JNIEnv* env = faset_android_jni();
    jobject o = view(id);
    if (!env || !o) return;
    jstring h = utf8_to_jstring(env, html, len);
    jstring b = utf8_to_jstring(env, base, baseLen);
    if (h && b) (*env)->CallVoidMethod(env, o, m_loadHtml, h, b);
    clear(env);
    if (h) (*env)->DeleteLocalRef(env, h);
    if (b) (*env)->DeleteLocalRef(env, b);
}

void faset_wv_command(int32_t id, int32_t cmd) {
    JNIEnv* env = faset_android_jni();
    jobject o = view(id);
    if (!env || !o) return;
    (*env)->CallVoidMethod(env, o, m_command, cmd);
    clear(env);
}

int32_t faset_wv_history(int32_t id) {
    JNIEnv* env = faset_android_jni();
    jobject o = view(id);
    if (!env || !o) return 0;
    int32_t r = (*env)->CallIntMethod(env, o, m_history);
    clear(env);
    return r;
}

void faset_wv_release_focus(void) {
    JNIEnv* env = faset_android_jni();
    if (!env) return;
    for (int i = 0; i < WV_MAX; i++)
        if (g_views[i]) {
            (*env)->CallVoidMethod(env, g_views[i], m_release);
            clear(env);
        }
}

/* Los eventos llegan solos por onEvent: aquí solo se cuenta cuántas vistas hay. */
int32_t faset_wv_pump(void) {
    int n = 0;
    for (int i = 0; i < WV_MAX; i++)
        if (g_views[i]) n++;
    return n;
}
