// =============================================================================
//  std.ui — control WebView: un navegador web incrustado en la ventana.
//
//      <WebView Name="Web" X="0" Y="40" Width="800" Height="560" Anchor="Left,Top,Right,Bottom"
//               Source="https://faset.dev" Navigated="OnNavigated" MessageReceived="OnMessage"/>
//
//      void OnNavigated(Widget sender) { lblUrl.Text = Web.Source; }
//      void OnMessage(Widget sender, string message) { Web.PostMessage("recibido: " + message); }
//
//  Desde JavaScript:  window.faset.postMessage("hola")         -> evento MessageReceived
//                     window.faset.onmessage = e => e.data      <- Widget.PostMessage(texto)
//                     window.faset.addEventListener("message", f)
//
//  Backends (el control es una vista nativa encima del lienzo de std.ui):
//    - Linux: WebKitGTK 4.1 + GTK 3 (GtkPlug/XEmbed dentro de la ventana X11). Se cargan
//      con dlopen al crear el primer WebView (lib/linux/faset_webview.c), así una app sin
//      WebView no necesita esas bibliotecas. Paquete: libwebkit2gtk-4.1-0.
//    - Android: android.webkit.WebView en un panel sobre la actividad (lib/android/faset_webview.c
//      + un pequeño dex incrustado). El compilador añade el permiso INTERNET.
//    - Windows: aún no (WebView2 necesita su cargador COM); se dibuja un aviso.
//    - Sin pantalla (FASET_UI_SCREENSHOT): se dibuja un marco con la dirección.
//
//  Limitaciones: la vista nativa siempre queda encima del lienzo (una lista desplegable
//  abierta no puede taparla) y no se recorta con el contenedor.
// =============================================================================
using std.collections;
using std.text;
using std.ui.webview;

namespace std.ui.webview
{
    // Tipos de evento de la capa nativa (iguales en lib/linux y lib/android).
    internal static class WebEvent
    {
        public const int Navigated = 1;
        public const int TitleChanged = 2;
        public const int Message = 3;
        public const int Started = 4;
        public const int UriChanged = 5;
        public const int FocusTaken = 6;
    }
}

namespace std.ui
{
    public memory_unsafe partial class Widget
    {
        // ------------------------------------------------------------- WebView
        string webSource = "";
        string webTitle = "";
        string webMessage = "";
        string webHtml = "";       // HTML pendiente hasta que exista la vista nativa
        internal bool webHasHtml;
        string webBase = "";
        List<string> webPending;   // scripts pendientes hasta que termine la primera carga
        internal bool webReady;    // la vista nativa ya cargó su primera página
        bool webLoading;
        int webHistory;            // bit 1: atrás, bit 2: adelante
        int navigatedEvent;
        int titleEvent;
        int messageEvent;

        // Estado de la vista nativa (lo gestiona WebViewHost).
        internal int webId;
        internal bool webFailed;
        internal bool webVisible;
        internal int webX = -1;
        internal int webY = -1;
        internal int webW = -1;
        internal int webH = -1;
        internal bool webShown;

        // Dirección actual (Source, en image.fst, navega al asignarla en un WebView).
        public string Url => webSource;

        // Título del documento cargado.
        public string Title => webTitle;

        // Último mensaje recibido de la página (window.faset.postMessage).
        public string Message => webMessage;

        public bool IsLoading => webLoading;
        public bool CanGoBack => (History() & 1) != 0;
        public bool CanGoForward => (History() & 2) != 0;

        // true si hay un navegador nativo de verdad (no el marco de vista previa).
        public bool HasNativeWebView => webId != 0;

        // Conecta los eventos de WebView (números de evento para SetEvents; 0 = ninguno).
        public void SetWebEvents(int navigated, int titleChanged, int messageReceived)
        {
            navigatedEvent = navigated;
            titleEvent = titleChanged;
            messageEvent = messageReceived;
        }

        public void Navigate(string url)
        {
            webSource = String.Copy(url);
            webHasHtml = false;
            if (webId != 0) WebNative.faset_wv_navigate(webId, url.Ptr, url.Length);
            Invalidate();
        }

        // Muestra un documento HTML; las rutas relativas se resuelven contra 'baseUrl' (puede ser "").
        public void LoadHtml(string html, string baseUrl)
        {
            webHtml = String.Copy(html);
            webHasHtml = true;
            webBase = String.Copy(baseUrl);
            webSource = "";
            if (webId != 0) SendHtml();
            Invalidate();
        }

        public void LoadHtml(string html) { LoadHtml(html, ""); }

        internal void SendHtml()
        {
            string html = webHtml;
            webHtml = "";
            webHasHtml = false;
            WebNative.faset_wv_load_html(webId, html.Ptr, html.Length, webBase.Ptr, webBase.Length);
        }

        public void GoBack() { Command(1); }
        public void GoForward() { Command(2); }
        public void Reload() { Command(3); }
        // Stop (en timer.fst) detiene la carga en un WebView.
        internal void StopLoading() { Command(4); }

        void Command(int cmd)
        {
            if (webId != 0) WebNative.faset_wv_command(webId, cmd);
        }

        int History()
        {
            if (webId != 0) webHistory = WebNative.faset_wv_history(webId);
            return webHistory;
        }

        // Ejecuta JavaScript en la página (sin esperar resultado: para devolver datos usa
        // window.faset.postMessage). Antes de la primera carga se encola.
        public void ExecuteScript(string js)
        {
            if (webId != 0 && webReady)
            {
                WebNative.faset_wv_eval(webId, js.Ptr, js.Length);
                return;
            }
            if (webPending == null) webPending = new List<string>();
            webPending.Add(String.Copy(js));
        }

        // Envía un texto a la página: llega a window.faset.onmessage / addEventListener("message") como e.data.
        public void PostMessage(string message)
        {
            ExecuteScript("window.faset&&window.faset.__receive(" + WebViewHost.JsString(message) + ");");
        }

        // Un evento de la capa nativa (hilo de la interfaz).
        internal void OnWebEvent(int kind, string text)
        {
            if (kind == WebEvent.Started)
            {
                webLoading = true;
                if (text.Length > 0) webSource = text;
            }
            else if (kind == WebEvent.UriChanged)
            {
                if (text.Length > 0) webSource = text;
            }
            else if (kind == WebEvent.Navigated)
            {
                webLoading = false;
                if (text.Length > 0 && text != "about:blank") webSource = text;
                History();
                if (!webReady)
                {
                    webReady = true;
                    if (webPending != null)
                    {
                        for (int i = 0; i < webPending.Count; i++)
                            WebNative.faset_wv_eval(webId, webPending[i].Ptr, webPending[i].Length);
                        webPending = null;
                    }
                }
                RaiseWeb(navigatedEvent);
            }
            else if (kind == WebEvent.TitleChanged)
            {
                webTitle = text;
                RaiseWeb(titleEvent);
            }
            else if (kind == WebEvent.Message)
            {
                webMessage = text;
                RaiseWeb(messageEvent);
            }
            else if (kind == WebEvent.FocusTaken)
            {
                if (Owner != null) Owner.Focus(null);  // el teclado lo tiene la página
            }
            Invalidate();
        }

        void RaiseWeb(int ev)
        {
            if (ev != 0 && eventFn != null) eventFn(eventTarget, this, ev);
        }

        // Marco de vista previa (sin pantalla, en el diseñador o si no hay navegador nativo).
        internal void DrawWebView(Canvas c, Palette p, UiFont font, float fx, float fy, float fw, float fh)
        {
            if (webId != 0 && webShown)
            {
                c.FillRect(ScreenX, ScreenY, ActualWidth, ActualHeight, Rgb.Of(0xffffff));  // queda debajo de la vista nativa
                return;
            }
            float r = CornerRadius >= 0 ? CornerRadius : 8;
            c.FillRoundRect(fx, fy, fw, fh, r, Background != 0 ? Background : p.Surface);
            c.StrokeRoundRect(fx, fy, fw, fh, r, 1, BorderColor != 0 ? BorderColor : p.Border);
            float bar = 34;
            if (fh < bar + 10) bar = fh;
            c.Clip(ScreenX + 1, ScreenY + 1, ActualWidth - 2, ActualHeight - 2);
            c.FillRect(ScreenX, ScreenY + (int)bar, ActualWidth, 1, p.Border);
            // Botones de la barra (atrás, adelante, recargar) y la dirección.
            float cy = fy + bar / 2;
            c.Line(fx + 14, cy, fx + 19, cy - 5, 1.6f, p.TextMuted);
            c.Line(fx + 14, cy, fx + 19, cy + 5, 1.6f, p.TextMuted);
            c.Line(fx + 34, cy - 5, fx + 39, cy, 1.6f, p.TextMuted);
            c.Line(fx + 39, cy, fx + 34, cy + 5, 1.6f, p.TextMuted);
            c.StrokeRoundRect(fx + 50, cy - 5, 10, 10, 5, 1.5f, p.TextMuted);
            float ax = fx + 70, aw = fw - 80;
            if (aw > 20)
            {
                c.FillRoundRect(ax, fy + 6, aw, bar - 12, (bar - 12) / 2, p.Input);
                c.StrokeRoundRect(ax, fy + 6, aw, bar - 12, (bar - 12) / 2, 1, p.Border);
                UiFont small = UiFont.Get(12, false);
                string addr = webHasHtml || (webSource.Length == 0 && webReady) ? "(HTML)" : (webSource.Length > 0 ? webSource : "about:blank");
                c.Clip((int)ax + 10, ScreenY, (int)aw - 20, ActualHeight);
                c.Text(small, addr, ax + 12, fy + (bar - small.LineHeight) / 2 + small.Ascent, p.TextMuted);
                c.ResetClip();
                c.Clip(ScreenX + 1, ScreenY + 1, ActualWidth - 2, ActualHeight - 2);
            }
            // Cuerpo: globo y nombre del control.
            float bodyY = fy + bar, bodyH = fh - bar;
            if (bodyH > 40)
            {
                float gx = fx + fw / 2, gy = bodyY + bodyH / 2 - 16;
                float gr = bodyH > 120 ? 22 : 12;
                c.StrokeRoundRect(gx - gr, gy - gr, gr * 2, gr * 2, gr, 1.6f, p.TextMuted);
                c.StrokeRoundRect(gx - gr * 0.45f, gy - gr, gr * 0.9f, gr * 2, gr * 0.45f, 1.4f, p.TextMuted);
                c.Line(gx - gr, gy, gx + gr, gy, 1.4f, p.TextMuted);
                UiFont big = UiFont.Get(FontSize, true);
                string head = webTitle.Length > 0 ? webTitle : "WebView";
                float tw = big.Measure(head);
                float ty = gy + gr + 10 + big.Ascent;
                c.Text(big, head, gx - tw / 2, ty, Foreground != 0 ? Foreground : p.Text);
                string note = WebViewHost.Unavailable(this);
                if (note.Length > 0)
                {
                    UiFont small = UiFont.Get(12, false);
                    float nw = small.Measure(note);
                    c.Text(small, note, gx - nw / 2, ty + big.Descent + 8 + small.Ascent, p.TextMuted);
                }
            }
            c.ResetClip();
        }
    }

    // Vistas nativas de los WebView de la ventana: las crea, las coloca y reparte sus eventos.
    internal memory_unsafe static class WebViewHost
    {
        static List<Widget> live = new List<Widget>();

        public static bool Active => live.Count > 0;

        // Texto que explica por qué no hay navegador ("" si lo hay o aún no se intentó).
        public static string Unavailable(Widget w)
        {
            if (!w.webFailed) return "";
#if WINDOWS
            return "WebView no disponible en esta plataforma";
#elif ANDROID
            return "WebView no disponible (android.webkit.WebView no se pudo crear)";
#else
            return "WebView no disponible: instala WebKitGTK 4.1 (libwebkit2gtk-4.1-0)";
#endif
        }

        static void Collect(Widget w, bool visible, List<Widget> found)
        {
            bool v = visible && w.Visible;
            if (w.Kind == WidgetKind.WebView)
            {
                w.webVisible = v;
                found.Add(w);
            }
            for (int i = 0; i < w.Children.Count; i++) Collect(w.Children[i], v, found);
        }

        // Después de dibujar: crea las vistas que faltan, coloca las que hay y destruye las retiradas.
        public static void Sync(Window window, ulong parent, float scale)
        {
            List<Widget> found = null;
            for (int i = 0; i < window.Children.Count; i++)
            {
                if (found == null && !HasWebView(window.Children[i])) continue;
                if (found == null) found = new List<Widget>();
                Collect(window.Children[i], true, found);
            }
            for (int i = live.Count - 1; i >= 0; i--)
                if (found == null || found.IndexOf(live[i]) < 0)
                {
                    Release(live[i]);
                    live.RemoveAt(i);
                }
            if (found == null) return;
            for (int i = 0; i < found.Count; i++)
            {
                Widget w = found[i];
                if (w.webId == 0 && !w.webFailed && w.webVisible) Create(w, parent);
                if (w.webId != 0) Place(w, scale);
            }
        }

        static bool HasWebView(Widget w)
        {
            if (w.Kind == WidgetKind.WebView) return true;
            for (int i = 0; i < w.Children.Count; i++)
                if (HasWebView(w.Children[i])) return true;
            return false;
        }

        static void Create(Widget w, ulong parent)
        {
            int id = WebNative.faset_wv_create(parent);
            if (id == 0)
            {
                w.webFailed = true;
                w.Invalidate();
                return;
            }
            w.webId = id;
            w.webShown = false;
            w.webX = -1;
            live.Add(w);
            if (w.webHasHtml) w.SendHtml();
            else
            {
                string url = w.Source.Length > 0 ? w.Source : "about:blank";
                WebNative.faset_wv_navigate(id, url.Ptr, url.Length);
            }
        }

        static void Place(Widget w, float scale)
        {
            int x = (int)Math.Floor(w.ScreenX * scale + 0.5f), y = (int)Math.Floor(w.ScreenY * scale + 0.5f);
            int r = (int)Math.Floor((w.ScreenX + w.ActualWidth) * scale + 0.5f), b = (int)Math.Floor((w.ScreenY + w.ActualHeight) * scale + 0.5f);
            bool show = w.webVisible && r > x && b > y;
            if (x == w.webX && y == w.webY && r - x == w.webW && b - y == w.webH && show == w.webShown) return;
            w.webX = x;
            w.webY = y;
            w.webW = r - x;
            w.webH = b - y;
            bool was = w.webShown;
            w.webShown = show;
            WebNative.faset_wv_bounds(w.webId, x, y, r - x, b - y, show ? 1 : 0);
            if (was != show) w.Invalidate();
        }

        static void Release(Widget w)
        {
            if (w.webId != 0) WebNative.faset_wv_destroy(w.webId);
            w.webId = 0;
            w.webShown = false;
            w.webReady = false;
        }

        // Atiende el bucle del navegador y reparte sus eventos (en cada vuelta del bucle de la ventana).
        public static void Pump()
        {
            if (live.Count == 0) return;
            WebNative.faset_wv_pump();
            int id = 0, kind = 0, len = 0;
            byte* text = null;
            while (WebNative.faset_wv_next_event(&id, &kind, &text, &len) != 0)
            {
                string s = String.Copy(String.FromBytes(text, len));
                Memory.Free(text);
                for (int i = 0; i < live.Count; i++)
                    if (live[i].webId == id)
                    {
                        live[i].OnWebEvent(kind, s);
                        break;
                    }
            }
        }

        // Clic en el lienzo de std.ui: el teclado vuelve a la ventana.
        public static void WindowClicked()
        {
            if (live.Count > 0) WebNative.faset_wv_release_focus();
        }

        // Con navegadores vivos la espera es corta: su bucle se atiende desde aquí.
        public static int WaitMs(int ms) => live.Count > 0 && ms > 15 ? 15 : ms;

        public static void CloseAll()
        {
            for (int i = 0; i < live.Count; i++) Release(live[i]);
            live.Clear();
        }

        // Literal de cadena de JavaScript (JSON) con el texto.
        public static string JsString(string s)
        {
            auto sb = new StringBuilder();
            sb.Append("\"");
            int start = 0;
            for (int i = 0; i < s.Length; i++)
            {
                byte ch = s[i];
                string rep = "";
                if (ch == '"') rep = "\\\"";
                else if (ch == '\\') rep = "\\\\";
                else if (ch == '\n') rep = "\\n";
                else if (ch == '\r') rep = "\\r";
                else if (ch == '\t') rep = "\\t";
                else if (ch == '<') rep = "\\u003c";
                else if (ch < 0x20) rep = "\\u00" + (ch < 16 ? "0" : "1") + "0123456789abcdef".Substring(ch & 15, 1);
                else if (ch == 0xE2 && i + 2 < s.Length && s[i + 1] == 0x80 && (s[i + 2] == 0xA8 || s[i + 2] == 0xA9))
                    rep = s[i + 2] == 0xA8 ? "\\u2028" : "\\u2029";
                if (rep.Length == 0) continue;
                sb.Append(s.Substring(start, i - start));
                sb.Append(rep);
                if (ch == 0xE2) i += 2;
                start = i + 1;
            }
            sb.Append(s.Substring(start, s.Length - start));
            sb.Append("\"");
            string r = sb.ToString();
            delete sb;
            return r;
        }
    }

#if WINDOWS
    // Windows: sin backend (WebView2 necesita WebView2Loader y COM); el control dibuja un aviso.
    internal memory_unsafe static class WebNative
    {
        public static int faset_wv_create(ulong parent) => 0;
        public static void faset_wv_destroy(int id) { }
        public static void faset_wv_bounds(int id, int x, int y, int w, int h, int visible) { }
        public static void faset_wv_navigate(int id, byte* url, int len) { }
        public static void faset_wv_load_html(int id, byte* html, int len, byte* baseUrl, int baseLen) { }
        public static void faset_wv_eval(int id, byte* js, int len) { }
        public static void faset_wv_command(int id, int cmd) { }
        public static int faset_wv_history(int id) => 0;
        public static int faset_wv_pump() => 0;
        public static int faset_wv_wait(int fd, int ms) => 0;
        public static int faset_wv_next_event(int* id, int* kind, byte** text, int* len) => 0;
        public static void faset_wv_release_focus() { }
    }
#else
    // Capa nativa: lib/linux/faset_webview.c (WebKitGTK) o lib/android/faset_webview.c (android.webkit).
    internal memory_unsafe static class WebNative
    {
        public static extern int faset_wv_create(ulong parent);
        public static extern void faset_wv_destroy(int id);
        public static extern void faset_wv_bounds(int id, int x, int y, int w, int h, int visible);
        public static extern void faset_wv_navigate(int id, byte* url, int len);
        public static extern void faset_wv_load_html(int id, byte* html, int len, byte* baseUrl, int baseLen);
        public static extern void faset_wv_eval(int id, byte* js, int len);
        public static extern void faset_wv_command(int id, int cmd);
        public static extern int faset_wv_history(int id);
        public static extern int faset_wv_pump();
        public static extern int faset_wv_wait(int fd, int ms);
        public static extern int faset_wv_next_event(int* id, int* kind, byte** text, int* len);
        public static extern void faset_wv_release_focus();
    }
#endif
}
