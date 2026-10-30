/* =============================================================================
 *  Faset - WebView de std.ui en Linux (WebKitGTK 4.1 + GTK 3, cargados con dlopen).
 *
 *  'faset build' compila este archivo junto a cualquier programa que use std.ui en
 *  Linux, pero las bibliotecas de WebKit y GTK solo se cargan (dlopen) cuando se
 *  crea el primer WebView: una app sin WebView arranca aunque no estén instaladas.
 *  Si faltan, faset_wv_create devuelve 0 y el control dibuja un aviso.
 *
 *  Incrustación: std.ui dibuja en una ventana X11 propia. Cada WebView es un
 *  GtkPlug (protocolo XEmbed) hijo de esa ventana, que std.ui mueve y redimensiona
 *  según los límites del control. GTK usa siempre su backend X11 (también bajo
 *  Wayland, con XWayland), porque la ventana de std.ui es X11.
 *
 *  Hilos: todo se llama desde el hilo de la interfaz de std.ui. faset_wv_pump()
 *  atiende el bucle de GLib sin bloquear; las señales de WebKit solo encolan
 *  eventos (aquí, en memoria de C) que std.ui recoge con faset_wv_next_event().
 *  Nunca se llama a código Faset desde las señales.
 *
 *  Puente JS -> Faset: la página llama a window.faset.postMessage("...") (un
 *  script de usuario lo define al empezar cada documento sobre los manejadores de
 *  mensajes de WebKit). Faset -> JS: faset_wv_eval con window.faset.__receive(...).
 * ============================================================================= */
#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ tipos mínimos de GLib/GTK */

typedef unsigned long GType;
typedef void (*GCallback)(void);
typedef struct {
    unsigned int signal_id;
    const char* signal_name;
    GType itype;
    unsigned int signal_flags;
    GType return_type;
    unsigned int n_params;
    const GType* param_types;
} GSignalQuery;

/* Tipos de evento (los mismos en Android: lib/android/faset_webview.c). */
enum { WV_NAVIGATED = 1, WV_TITLE = 2, WV_MESSAGE = 3, WV_STARTED = 4, WV_URI = 5, WV_FOCUS = 6 };

/* ------------------------------------------------------------------ funciones cargadas */

static struct {
    int tried, ok;
    /* glib / gobject */
    int (*g_main_context_iteration)(void*, int);
    unsigned long (*g_signal_connect_data)(void*, const char*, GCallback, void*, void*, int);
    unsigned int (*g_signal_lookup)(const char*, GType);
    void (*g_signal_query)(unsigned int, GSignalQuery*);
    void (*g_free)(void*);
    void (*g_object_unref)(void*);
    /* gdk / gtk */
    void (*gdk_set_allowed_backends)(const char*);
    int (*gtk_init_check)(int*, char***);
    void* (*gtk_plug_new)(unsigned long);
    unsigned long (*gtk_plug_get_id)(void*);
    void (*gtk_container_add)(void*, void*);
    void (*gtk_widget_show_all)(void*);
    void (*gtk_widget_show)(void*);
    void (*gtk_widget_hide)(void*);
    void (*gtk_widget_destroy)(void*);
    void (*gtk_widget_grab_focus)(void*);
    void (*gtk_widget_set_size_request)(void*, int, int);
    void (*gtk_window_resize)(void*, int, int);
    void* (*gtk_widget_get_window)(void*);
    void (*gdk_window_move_resize)(void*, int, int, int, int);
    int (*gdk_window_get_scale_factor)(void*);
    void* (*gdk_display_get_default)(void);
    void* (*gdk_x11_display_get_xdisplay)(void*);
    /* Xlib (std.ui ya enlaza libX11) */
    unsigned long (*XInternAtom)(void*, const char*, int);
    int (*XSendEvent)(void*, unsigned long, int, long, void*);
    int (*XSetInputFocus)(void*, unsigned long, int, unsigned long);
    int (*XMoveResizeWindow)(void*, unsigned long, int, int, unsigned int, unsigned int);
    int (*XMapWindow)(void*, unsigned long);
    int (*XUnmapWindow)(void*, unsigned long);
    int (*XFlush)(void*);
    /* webkit */
    void* (*webkit_user_content_manager_new)(void);
    GType (*webkit_user_content_manager_get_type)(void);
    int (*webkit_user_content_manager_register_script_message_handler)(void*, const char*);
    void (*webkit_user_content_manager_add_script)(void*, void*);
    void* (*webkit_user_script_new)(const char*, int, int, const char* const*, const char* const*);
    void (*webkit_user_script_unref)(void*);
    void* (*webkit_web_view_new_with_user_content_manager)(void*);
    void (*webkit_web_view_load_uri)(void*, const char*);
    void (*webkit_web_view_load_html)(void*, const char*, const char*);
    void (*webkit_web_view_go_back)(void*);
    void (*webkit_web_view_go_forward)(void*);
    void (*webkit_web_view_reload)(void*);
    void (*webkit_web_view_stop_loading)(void*);
    int (*webkit_web_view_can_go_back)(void*);
    int (*webkit_web_view_can_go_forward)(void*);
    const char* (*webkit_web_view_get_title)(void*);
    const char* (*webkit_web_view_get_uri)(void*);
    void (*webkit_web_view_evaluate_javascript)(void*, const char*, long, const char*, const char*, void*, void*, void*);
    void (*webkit_web_view_run_javascript)(void*, const char*, void*, void*, void*);
    void* (*webkit_javascript_result_get_js_value)(void*);
    /* JavaScriptCore */
    char* (*jsc_value_to_string)(void*);
    GType (*jsc_value_get_type)(void);
} F;

static void* open_first(const char* const* names) {
    for (int i = 0; names[i]; i++) {
        void* h = dlopen(names[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) return h;
    }
    return NULL;
}

#define LOAD(lib, name, required)                                   \
    do {                                                            \
        *(void**)(&F.name) = lib ? dlsym(lib, #name) : NULL;        \
        if (!F.name) *(void**)(&F.name) = dlsym(RTLD_DEFAULT, #name); \
        if (!F.name && (required)) {                                \
            missing = #name;                                        \
            goto fail;                                              \
        }                                                           \
    } while (0)

/* Carga GTK y WebKitGTK la primera vez. Devuelve 1 si están disponibles. */
static int load(void) {
    if (F.tried) return F.ok;
    F.tried = 1;
    const char* missing = NULL;
    static const char* const webkitNames[] = {"libwebkit2gtk-4.1.so.0", "libwebkit2gtk-4.0.so.37", NULL};
    static const char* const gtkNames[] = {"libgtk-3.so.0", NULL};
    static const char* const gdkNames[] = {"libgdk-3.so.0", NULL};
    static const char* const gobjNames[] = {"libgobject-2.0.so.0", NULL};
    static const char* const glibNames[] = {"libglib-2.0.so.0", NULL};
    static const char* const jscNames[] = {"libjavascriptcoregtk-4.1.so.0", "libjavascriptcoregtk-4.0.so.18", NULL};
    static const char* const x11Names[] = {"libX11.so.6", NULL};
    void* webkit = open_first(webkitNames);
    if (!webkit) {
        fprintf(stderr, "std.ui: WebView no disponible (falta libwebkit2gtk-4.1: instala el paquete libwebkit2gtk-4.1-0)\n");
        return 0;
    }
    void* gtk = open_first(gtkNames);
    void* gdk = open_first(gdkNames);
    void* gobj = open_first(gobjNames);
    void* glib = open_first(glibNames);
    void* jsc = open_first(jscNames);
    void* x11 = open_first(x11Names);
    LOAD(glib, g_main_context_iteration, 1);
    LOAD(glib, g_free, 1);
    LOAD(gobj, g_signal_connect_data, 1);
    LOAD(gobj, g_signal_lookup, 1);
    LOAD(gobj, g_signal_query, 1);
    LOAD(gobj, g_object_unref, 1);
    LOAD(gdk, gdk_set_allowed_backends, 0);
    LOAD(gdk, gdk_window_move_resize, 1);
    LOAD(gdk, gdk_window_get_scale_factor, 0);
    LOAD(gdk, gdk_display_get_default, 1);
    LOAD(gdk, gdk_x11_display_get_xdisplay, 1);
    LOAD(gtk, gtk_init_check, 1);
    LOAD(gtk, gtk_plug_new, 1);
    LOAD(gtk, gtk_plug_get_id, 1);
    LOAD(gtk, gtk_container_add, 1);
    LOAD(gtk, gtk_widget_show_all, 1);
    LOAD(gtk, gtk_widget_show, 1);
    LOAD(gtk, gtk_widget_hide, 1);
    LOAD(gtk, gtk_widget_destroy, 1);
    LOAD(gtk, gtk_widget_grab_focus, 1);
    LOAD(gtk, gtk_widget_set_size_request, 1);
    LOAD(gtk, gtk_window_resize, 1);
    LOAD(gtk, gtk_widget_get_window, 1);
    LOAD(x11, XInternAtom, 1);
    LOAD(x11, XSendEvent, 1);
    LOAD(x11, XSetInputFocus, 1);
    LOAD(x11, XMoveResizeWindow, 1);
    LOAD(x11, XFlush, 1);
    LOAD(x11, XMapWindow, 1);
    LOAD(x11, XUnmapWindow, 1);
    LOAD(webkit, webkit_user_content_manager_new, 1);
    LOAD(webkit, webkit_user_content_manager_get_type, 1);
    LOAD(webkit, webkit_user_content_manager_register_script_message_handler, 1);
    LOAD(webkit, webkit_user_content_manager_add_script, 1);
    LOAD(webkit, webkit_user_script_new, 1);
    LOAD(webkit, webkit_user_script_unref, 1);
    LOAD(webkit, webkit_web_view_new_with_user_content_manager, 1);
    LOAD(webkit, webkit_web_view_load_uri, 1);
    LOAD(webkit, webkit_web_view_load_html, 1);
    LOAD(webkit, webkit_web_view_go_back, 1);
    LOAD(webkit, webkit_web_view_go_forward, 1);
    LOAD(webkit, webkit_web_view_reload, 1);
    LOAD(webkit, webkit_web_view_stop_loading, 1);
    LOAD(webkit, webkit_web_view_can_go_back, 1);
    LOAD(webkit, webkit_web_view_can_go_forward, 1);
    LOAD(webkit, webkit_web_view_get_title, 1);
    LOAD(webkit, webkit_web_view_get_uri, 1);
    LOAD(webkit, webkit_web_view_evaluate_javascript, 0);  /* WebKitGTK 2.40+ */
    LOAD(webkit, webkit_web_view_run_javascript, 0);
    LOAD(webkit, webkit_javascript_result_get_js_value, 0);
    LOAD(jsc, jsc_value_to_string, 1);
    LOAD(jsc, jsc_value_get_type, 1);
    if (!F.webkit_web_view_evaluate_javascript && !F.webkit_web_view_run_javascript) {
        missing = "webkit_web_view_evaluate_javascript";
        goto fail;
    }
    /* La ventana de std.ui es X11: GTK debe usar X11 aunque la sesión sea Wayland. */
    if (F.gdk_set_allowed_backends) F.gdk_set_allowed_backends("x11");
    if (!F.gtk_init_check(NULL, NULL)) {
        fprintf(stderr, "std.ui: WebView no disponible (GTK no pudo abrir la pantalla X11)\n");
        return 0;
    }
    F.ok = 1;
    return 1;
fail:
    fprintf(stderr, "std.ui: WebView no disponible (falta el símbolo %s)\n", missing);
    return 0;
}

/* ------------------------------------------------------------------ cola de eventos */

typedef struct wv_event {
    int32_t id, kind;
    char* text;
    int32_t len;
    struct wv_event* next;
} wv_event;

static wv_event* g_head;
static wv_event* g_tail;

static void push_event(int32_t id, int32_t kind, const char* text) {
    wv_event* e = (wv_event*)calloc(1, sizeof *e);
    if (!e) return;
    e->id = id;
    e->kind = kind;
    if (!text) text = "";
    e->len = (int32_t)strlen(text);
    e->text = (char*)malloc((size_t)e->len + 1);
    if (e->text) memcpy(e->text, text, (size_t)e->len + 1);
    else e->len = 0;
    if (g_tail) g_tail->next = e;
    else g_head = e;
    g_tail = e;
}

/* Saca el siguiente evento. 'text' (UTF-8, con malloc) lo libera quien llama. Devuelve 0 si no hay. */
int32_t faset_wv_next_event(int32_t* id, int32_t* kind, uint8_t** text, int32_t* len) {
    wv_event* e = g_head;
    if (!e) return 0;
    g_head = e->next;
    if (!g_head) g_tail = NULL;
    *id = e->id;
    *kind = e->kind;
    *text = (uint8_t*)e->text;
    *len = e->len;
    free(e);
    return 1;
}

/* ------------------------------------------------------------------ vistas */

typedef struct {
    int32_t id;
    void* plug;
    void* web;
    void* ucm;
    unsigned long plugXid;
    unsigned long parentXid;
    int x, y, w, h, visible;
    int jsResult; /* 1: script-message-received pasa WebKitJavascriptResult; 0: JSCValue */
} wv_view;

#define WV_MAX 64
static wv_view* g_views[WV_MAX];
static int32_t g_next_id = 1;
static wv_view* g_focused;

static wv_view* find(int32_t id) {
    for (int i = 0; i < WV_MAX; i++)
        if (g_views[i] && g_views[i]->id == id) return g_views[i];
    return NULL;
}

static char* dupn(const uint8_t* s, int32_t n) {
    if (n < 0) n = 0;
    char* r = (char*)malloc((size_t)n + 1);
    if (!r) return NULL;
    if (n > 0) memcpy(r, s, (size_t)n);
    r[n] = 0;
    return r;
}

static void* xdisplay(void) { return F.gdk_x11_display_get_xdisplay(F.gdk_display_get_default()); }

/* Mensaje XEmbed al plug (como haría un GtkSocket). */
static void xembed(wv_view* v, long message, long detail) {
    void* dpy = xdisplay();
    long ev[24];  /* XClientMessageEvent (96 bytes en 64 bits) */
    memset(ev, 0, sizeof ev);
    int* p = (int*)ev;
    p[0] = 33;                                 /* ClientMessage */
    ev[3] = 0;                                 /* display (lo rellena Xlib) */
    ev[4] = (long)v->plugXid;                  /* window */
    ev[5] = (long)F.XInternAtom(dpy, "_XEMBED", 0); /* message_type */
    ((int*)&ev[6])[0] = 32;                    /* format */
    ev[7] = 0;                                 /* data.l[0] = CurrentTime */
    ev[8] = message;
    ev[9] = detail;
    F.XSendEvent(dpy, v->plugXid, 0, 0, ev);
}

static void give_focus(wv_view* v) {
    if (g_focused == v) return;
    if (g_focused) xembed(g_focused, 5, 0);   /* XEMBED_FOCUS_OUT */
    g_focused = v;
    F.XSetInputFocus(xdisplay(), v->plugXid, 1 /* RevertToParent */, 0);
    xembed(v, 1, 0);  /* XEMBED_WINDOW_ACTIVATE */
    xembed(v, 4, 0);  /* XEMBED_FOCUS_IN, XEMBED_FOCUS_CURRENT */
    F.XFlush(xdisplay());
    F.gtk_widget_grab_focus(v->web);
    push_event(v->id, WV_FOCUS, "");
}

/* std.ui recibió un clic en su propia ventana: el teclado vuelve a ella. */
void faset_wv_release_focus(void) {
    if (!F.ok || !g_focused) return;
    wv_view* v = g_focused;
    g_focused = NULL;
    xembed(v, 5, 0);  /* XEMBED_FOCUS_OUT */
    xembed(v, 2, 0);  /* XEMBED_WINDOW_DEACTIVATE */
    F.XSetInputFocus(xdisplay(), v->parentXid, 1, 0);
    F.XFlush(xdisplay());
}

/* ------------------------------------------------------------------ video de GStreamer

   WebKitGTK reproduce el video con GStreamer y, desde la 2.44, cierra el proceso de la página si le
   falta un elemento que necesita (vp9parse, h264parse... de gst-plugins-bad): la vista se quedaba
   vacía sin explicación. Se avisa al crear el primer WebView y, si el proceso se cae, se muestra una
   página que dice qué pasó y cómo arreglarlo. */

static const char* g_missingGst;  /* elemento de GStreamer que falta (o NULL) */

static void check_gstreamer(void) {
    static int done;
    if (done) return;
    done = 1;
    void* gst = dlopen("libgstreamer-1.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!gst) return;
    int (*init_check)(int*, char***, void**) = (int (*)(int*, char***, void**))dlsym(gst, "gst_init_check");
    void* (*find)(const char*) = (void* (*)(const char*))dlsym(gst, "gst_element_factory_find");
    void (*unref)(void*) = (void (*)(void*))dlsym(gst, "gst_object_unref");
    if (!init_check || !find || !init_check(NULL, NULL, NULL)) return;
    static const char* const needed[] = {"vp9parse", "h264parse"};
    for (size_t i = 0; i < sizeof needed / sizeof needed[0]; i++) {
        void* f = find(needed[i]);
        if (!f) {
            g_missingGst = needed[i];
            fprintf(stderr,
                    "std.ui: WebView: falta el elemento '%s' de GStreamer (paquete gst-plugins-bad): una página con "
                    "video cerrará el navegador. Instálalo con 'faset setup multimedia' (en Debian/Ubuntu: "
                    "sudo apt install gstreamer1.0-plugins-bad)\n",
                    needed[i]);
            return;
        }
        if (unref) unref(f);
    }
}

/* ------------------------------------------------------------------ señales */

static void on_load_changed(void* web, int event, void* data) {
    wv_view* v = (wv_view*)data;
    (void)web;
    if (event == 0) push_event(v->id, WV_STARTED, F.webkit_web_view_get_uri(v->web));
    else if (event == 3) push_event(v->id, WV_NAVIGATED, F.webkit_web_view_get_uri(v->web));
}

/* WebKitWebProcessTerminationReason: 0 fallo, 1 sin memoria, 2 cerrado desde el programa. */
static void on_terminated(void* web, int reason, void* data) {
    wv_view* v = (wv_view*)data;
    (void)web;
    if (reason == 2) return;
    const char* why = reason == 1 ? "se quedó sin memoria" : "se cerró de forma inesperada";
    fprintf(stderr, "std.ui: WebView: el proceso de la página %s%s%s%s\n", why,
            g_missingGst ? " (falta el elemento '" : "", g_missingGst ? g_missingGst : "",
            g_missingGst ? "' de GStreamer: instala gst-plugins-bad)" : "");
    char html[2048];
    snprintf(html, sizeof html,
             "<!DOCTYPE html><meta charset='utf-8'><body style='font:14px system-ui,sans-serif;margin:24px;color:#333'>"
             "<h3 style='margin:0 0 8px'>La página se cerró</h3><p>El proceso del navegador (WebKitGTK) %s.</p>%s%s%s",
             why,
             g_missingGst ? "<p>Falta el elemento <code>" : "",
             g_missingGst ? g_missingGst : "",
             g_missingGst ? "</code> de GStreamer, que WebKit necesita para reproducir video. Instálalo con:</p>"
                            "<pre style='background:#f2f2f4;padding:8px'>faset setup multimedia</pre>"
                            "<p>o con el paquete de tu distribución: <code>gstreamer1.0-plugins-bad</code> (Debian/Ubuntu), "
                            "<code>gstreamer1-plugins-bad-free</code> (Fedora), <code>gst-plugins-bad</code> (Arch).</p>"
                          : "");
    F.webkit_web_view_load_html(v->web, html, NULL);
}

static void on_title(void* obj, void* pspec, void* data) {
    wv_view* v = (wv_view*)data;
    (void)obj, (void)pspec;
    push_event(v->id, WV_TITLE, F.webkit_web_view_get_title(v->web));
}

static void on_uri(void* obj, void* pspec, void* data) {
    wv_view* v = (wv_view*)data;
    (void)obj, (void)pspec;
    push_event(v->id, WV_URI, F.webkit_web_view_get_uri(v->web));
}

static void on_script_message(void* ucm, void* arg, void* data) {
    wv_view* v = (wv_view*)data;
    (void)ucm;
    void* value = arg;
    if (v->jsResult && F.webkit_javascript_result_get_js_value) value = F.webkit_javascript_result_get_js_value(arg);
    if (!value) return;
    char* s = F.jsc_value_to_string(value);
    push_event(v->id, WV_MESSAGE, s ? s : "");
    if (s) F.g_free(s);
}

static int on_button_press(void* widget, void* event, void* data) {
    (void)widget, (void)event;
    give_focus((wv_view*)data);
    return 0;  /* que WebKit también lo procese */
}

/* window.faset en cada documento (también en los marcos). */
static const char kBridgeScript[] =
    "(function(){if(window.faset)return;var ls=[];window.faset={"
    "postMessage:function(m){window.webkit.messageHandlers.faset.postMessage(String(m));},"
    "onmessage:null,"
    "addEventListener:function(t,f){if(t==='message')ls.push(f);},"
    "removeEventListener:function(t,f){var i=ls.indexOf(f);if(i>=0)ls.splice(i,1);},"
    "__receive:function(m){var e={data:m};if(typeof window.faset.onmessage==='function')window.faset.onmessage(e);"
    "for(var i=0;i<ls.length;i++)ls[i](e);}};})();";

/* ------------------------------------------------------------------ API para std.ui */

/* Crea un WebView dentro de la ventana X11 'parent'. Devuelve su id (>0) o 0 si no hay WebKitGTK. */
int32_t faset_wv_create(uint64_t parent) {
    if (!load()) return 0;
    int slot = -1;
    for (int i = 0; i < WV_MAX; i++)
        if (!g_views[i]) {
            slot = i;
            break;
        }
    if (slot < 0) return 0;
    check_gstreamer();
    wv_view* v = (wv_view*)calloc(1, sizeof *v);
    if (!v) return 0;
    v->id = g_next_id++;
    v->parentXid = (unsigned long)parent;
    v->ucm = F.webkit_user_content_manager_new();
    /* El argumento de script-message-received cambió de tipo en WebKitGTK 2.40 (6.0): se mira cuál es. */
    GSignalQuery q;
    memset(&q, 0, sizeof q);
    unsigned int sid = F.g_signal_lookup("script-message-received", F.webkit_user_content_manager_get_type());
    if (sid) F.g_signal_query(sid, &q);
    v->jsResult = !(q.n_params > 0 && (q.param_types[0] & ~(GType)1) == F.jsc_value_get_type());
    F.g_signal_connect_data(v->ucm, "script-message-received::faset", (GCallback)on_script_message, v, NULL, 0);
    F.webkit_user_content_manager_register_script_message_handler(v->ucm, "faset");
    void* script = F.webkit_user_script_new(kBridgeScript, 0 /* todos los marcos */, 0 /* al empezar */, NULL, NULL);
    F.webkit_user_content_manager_add_script(v->ucm, script);
    F.webkit_user_script_unref(script);
    v->web = F.webkit_web_view_new_with_user_content_manager(v->ucm);
    F.g_signal_connect_data(v->web, "load-changed", (GCallback)on_load_changed, v, NULL, 0);
    F.g_signal_connect_data(v->web, "notify::title", (GCallback)on_title, v, NULL, 0);
    F.g_signal_connect_data(v->web, "web-process-terminated", (GCallback)on_terminated, v, NULL, 0);
    F.g_signal_connect_data(v->web, "notify::uri", (GCallback)on_uri, v, NULL, 0);
    F.g_signal_connect_data(v->web, "button-press-event", (GCallback)on_button_press, v, NULL, 0);
    v->plug = F.gtk_plug_new((unsigned long)parent);
    F.gtk_container_add(v->plug, v->web);
    v->w = v->h = 1;
    F.gtk_window_resize(v->plug, 1, 1);
    v->plugXid = F.gtk_plug_get_id(v->plug);
    g_views[slot] = v;
    return v->id;
}

void faset_wv_destroy(int32_t id) {
    for (int i = 0; i < WV_MAX; i++) {
        wv_view* v = g_views[i];
        if (!v || v->id != id) continue;
        if (g_focused == v) faset_wv_release_focus();
        F.gtk_widget_destroy(v->plug);  /* también destruye el WebKitWebView */
        F.g_object_unref(v->ucm);
        g_views[i] = NULL;
        free(v);
        for (int k = 0; k < 20; k++)
            if (!F.g_main_context_iteration(NULL, 0)) break;
    }
}

/* Posición y tamaño en píxeles dentro de la ventana de std.ui. */
void faset_wv_bounds(int32_t id, int32_t x, int32_t y, int32_t w, int32_t h, int32_t visible) {
    wv_view* v = find(id);
    if (!v) return;
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (visible && !v->visible) {
        F.gtk_widget_show_all(v->plug);
        v->plugXid = F.gtk_plug_get_id(v->plug);
    } else if (!visible && v->visible) {
        if (g_focused == v) faset_wv_release_focus();
        F.XUnmapWindow(xdisplay(), v->plugXid);
        F.gtk_widget_hide(v->plug);
        F.XFlush(xdisplay());
    }
    v->visible = visible;
    v->x = x;
    v->y = y;
    v->w = w;
    v->h = h;
    if (!visible) return;
    void* gw = F.gtk_widget_get_window(v->plug);
    int scale = gw && F.gdk_window_get_scale_factor ? F.gdk_window_get_scale_factor(gw) : 1;
    if (scale < 1) scale = 1;
    F.gtk_window_resize(v->plug, w / scale, h / scale);
    if (gw) F.gdk_window_move_resize(gw, x / scale, y / scale, w / scale, h / scale);
    F.XMoveResizeWindow(xdisplay(), v->plugXid, x, y, (unsigned)w, (unsigned)h);
    /* Con un socket ajeno, quien incrusta mapea el plug (XEmbed): aquí, std.ui. */
    F.XMapWindow(xdisplay(), v->plugXid);
    F.XFlush(xdisplay());
}

void faset_wv_navigate(int32_t id, const uint8_t* url, int32_t len) {
    wv_view* v = find(id);
    if (!v) return;
    char* u = dupn(url, len);
    if (u) F.webkit_web_view_load_uri(v->web, u);
    free(u);
}

void faset_wv_load_html(int32_t id, const uint8_t* html, int32_t len, const uint8_t* base, int32_t baseLen) {
    wv_view* v = find(id);
    if (!v) return;
    char* h = dupn(html, len);
    char* b = baseLen > 0 ? dupn(base, baseLen) : NULL;
    if (h) F.webkit_web_view_load_html(v->web, h, b);
    free(h);
    free(b);
}

void faset_wv_eval(int32_t id, const uint8_t* js, int32_t len) {
    wv_view* v = find(id);
    if (!v) return;
    char* s = dupn(js, len);
    if (!s) return;
    if (F.webkit_web_view_evaluate_javascript)
        F.webkit_web_view_evaluate_javascript(v->web, s, -1, NULL, NULL, NULL, NULL, NULL);
    else
        F.webkit_web_view_run_javascript(v->web, s, NULL, NULL, NULL);
    free(s);
}

/* 1 atrás, 2 adelante, 3 recargar, 4 detener. */
void faset_wv_command(int32_t id, int32_t cmd) {
    wv_view* v = find(id);
    if (!v) return;
    if (cmd == 1) F.webkit_web_view_go_back(v->web);
    else if (cmd == 2) F.webkit_web_view_go_forward(v->web);
    else if (cmd == 3) F.webkit_web_view_reload(v->web);
    else if (cmd == 4) F.webkit_web_view_stop_loading(v->web);
}

/* Bit 1: puede ir atrás; bit 2: puede ir adelante. */
int32_t faset_wv_history(int32_t id) {
    wv_view* v = find(id);
    if (!v) return 0;
    return (F.webkit_web_view_can_go_back(v->web) ? 1 : 0) | (F.webkit_web_view_can_go_forward(v->web) ? 2 : 0);
}

/* Atiende GTK/WebKit sin bloquear. Devuelve el número de WebView vivos. */
int32_t faset_wv_pump(void) {
    if (!F.ok) return 0;
    for (int k = 0; k < 200; k++)
        if (!F.g_main_context_iteration(NULL, 0)) break;
    int n = 0;
    for (int i = 0; i < WV_MAX; i++)
        if (g_views[i]) n++;
    return n;
}
