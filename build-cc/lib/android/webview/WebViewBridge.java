// =============================================================================
//  Faset - puente del WebView de std.ui en Android.
//
//  NativeActivity no tiene jerarquía de vistas para el contenido de la app (su
//  superficie la dibuja std.ui), así que cada WebView vive en un panel propio
//  (WindowManager, TYPE_APPLICATION_PANEL) colocado encima de la actividad en los
//  límites del control.
//
//  Este archivo NO se compila al construir una app: build_dex.sh lo convierte una
//  vez en un dex que se incrusta como bytes en faset_webview_dex.h, y
//  lib/android/faset_webview.c lo carga en ejecución (InMemoryDexClassLoader).
//  Así el APK sigue sin código Java ni Gradle (hasCode=false).
//
//  Todo lo que llama Faset (desde su hilo) se pasa al hilo de la interfaz con un
//  Handler. Los eventos vuelven por onEvent (nativo, registrado desde C).
// =============================================================================
package faset;

import android.app.Activity;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.PixelFormat;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

public final class WebViewBridge {
    // Tipos de evento (los mismos que en lib/linux/faset_webview.c).
    static final int NAVIGATED = 1, TITLE = 2, MESSAGE = 3, STARTED = 4, URI = 5, FOCUS = 6;

    static native void onEvent(long id, int kind, String text);

    // window.faset sobre la interfaz de Java (__fasetNative).
    static final String SHIM =
        "(function(){if(window.faset&&window.faset.__receive)return;var ls=[];window.faset={"
        + "postMessage:function(m){__fasetNative.postMessage(String(m));},"
        + "onmessage:null,"
        + "addEventListener:function(t,f){if(t==='message')ls.push(f);},"
        + "removeEventListener:function(t,f){var i=ls.indexOf(f);if(i>=0)ls.splice(i,1);},"
        + "__receive:function(m){var e={data:m};if(typeof window.faset.onmessage==='function')window.faset.onmessage(e);"
        + "for(var i=0;i<ls.length;i++)ls[i](e);}};})();";

    final Activity activity;
    final long id;
    final Handler ui = new Handler(Looper.getMainLooper());
    WebView web;
    FrameLayout frame;
    WindowManager.LayoutParams lp;
    boolean added, focusable, destroyed;
    int x, y, w = 1, h = 1;
    boolean visible;
    volatile int history;

    public WebViewBridge(Activity activity, long id) {
        this.activity = activity;
        this.id = id;
        ui.post(new Runnable() { public void run() { create(); } });
    }

    final class Js {
        @JavascriptInterface
        public void postMessage(String m) { onEvent(id, MESSAGE, m == null ? "" : m); }
    }

    void create() {
        web = new WebView(activity);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        web.addJavascriptInterface(new Js(), "__fasetNative");
        web.setWebViewClient(new WebViewClient() {
            @Override public void onPageStarted(WebView v, String url, Bitmap icon) {
                v.evaluateJavascript(SHIM, null);
                updateHistory();
                onEvent(id, STARTED, url == null ? "" : url);
            }
            @Override public void onPageFinished(WebView v, String url) {
                v.evaluateJavascript(SHIM, null);
                updateHistory();
                onEvent(id, NAVIGATED, url == null ? "" : url);
            }
            @Override public void doUpdateVisitedHistory(WebView v, String url, boolean reload) {
                updateHistory();
                onEvent(id, URI, url == null ? "" : url);
            }
        });
        web.setWebChromeClient(new WebChromeClient() {
            @Override public void onReceivedTitle(WebView v, String title) { onEvent(id, TITLE, title == null ? "" : title); }
        });
        // Al tocar la página, su panel pasa a recibir el teclado.
        web.setOnTouchListener(new View.OnTouchListener() {
            public boolean onTouch(View v, MotionEvent e) {
                if (e.getActionMasked() == MotionEvent.ACTION_DOWN && !focusable) setFocusable(true);
                return false;
            }
        });
        frame = new FrameLayout(activity);
        frame.addView(web, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        frame.setVisibility(visible ? View.VISIBLE : View.GONE);
        lp = new WindowManager.LayoutParams(w, h, WindowManager.LayoutParams.TYPE_APPLICATION_PANEL,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.OPAQUE);
        lp.gravity = Gravity.TOP | Gravity.LEFT;
        if (Build.VERSION.SDK_INT >= 30) lp.setFitInsetsTypes(0);
        attach();
    }

    // El panel necesita el token de la ventana de la actividad (puede tardar en existir).
    void attach() {
        if (destroyed || added) return;
        IBinder token = activity.getWindow().getDecorView().getWindowToken();
        if (token == null) {
            ui.postDelayed(new Runnable() { public void run() { attach(); } }, 50);
            return;
        }
        lp.token = token;
        place();
        try {
            activity.getWindowManager().addView(frame, lp);
            added = true;
        } catch (RuntimeException e) {
            ui.postDelayed(new Runnable() { public void run() { attach(); } }, 100);
        }
    }

    void place() {
        int[] at = new int[2];
        activity.getWindow().getDecorView().getLocationOnScreen(at);
        lp.x = at[0] + x;
        lp.y = at[1] + y;
        lp.width = w;
        lp.height = h;
    }

    void updateHistory() {
        if (web != null) history = (web.canGoBack() ? 1 : 0) | (web.canGoForward() ? 2 : 0);
    }

    void setFocusable(boolean f) {
        focusable = f;
        if (f) lp.flags &= ~WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        else lp.flags |= WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        if (added) activity.getWindowManager().updateViewLayout(frame, lp);
        if (f) {
            web.requestFocus();
            onEvent(id, FOCUS, "");
        } else {
            InputMethodManager imm = (InputMethodManager)activity.getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) imm.hideSoftInputFromWindow(web.getWindowToken(), 0);
        }
    }

    // ------------------------------------------------------------------ API (hilo de Faset)

    public int history() { return history; }

    public void bounds(final int nx, final int ny, final int nw, final int nh, final boolean nv) {
        ui.post(new Runnable() { public void run() {
            x = nx;
            y = ny;
            w = nw < 1 ? 1 : nw;
            h = nh < 1 ? 1 : nh;
            visible = nv;
            if (frame == null) return;
            frame.setVisibility(nv ? View.VISIBLE : View.GONE);
            if (!nv && focusable) setFocusable(false);
            if (!added) return;
            place();
            activity.getWindowManager().updateViewLayout(frame, lp);
        } });
    }

    public void navigate(final String url) {
        ui.post(new Runnable() { public void run() { if (web != null) web.loadUrl(url); } });
    }

    public void loadHtml(final String html, final String base) {
        ui.post(new Runnable() { public void run() {
            if (web != null)
                web.loadDataWithBaseURL(base.length() > 0 ? base : null, "<script>" + SHIM + "</script>" + html, "text/html", "utf-8", null);
        } });
    }

    public void eval(final String js) {
        ui.post(new Runnable() { public void run() { if (web != null) web.evaluateJavascript(js, null); } });
    }

    public void command(final int cmd) {
        ui.post(new Runnable() { public void run() {
            if (web == null) return;
            if (cmd == 1) web.goBack();
            else if (cmd == 2) web.goForward();
            else if (cmd == 3) web.reload();
            else if (cmd == 4) web.stopLoading();
        } });
    }

    public void releaseFocus() {
        ui.post(new Runnable() { public void run() { if (focusable && web != null) setFocusable(false); } });
    }

    public void destroy() {
        ui.post(new Runnable() { public void run() {
            destroyed = true;
            if (added) activity.getWindowManager().removeViewImmediate(frame);
            added = false;
            if (web != null) web.destroy();
            web = null;
        } });
    }
}
