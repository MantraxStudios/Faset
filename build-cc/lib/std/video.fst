// =============================================================================
//  std.video  —  reproducción de vídeo para el control VideoPlayer de std.ui.
//
//  En un .fstui:
//
//      <VideoPlayer Name="Video" X="20" Y="20" Width="640" Height="360"
//                   Source="intro.mp4" AutoPlay="true" Loop="false" ShowControls="true"
//                   Stretch="Uniform" Volume="0.8" Ended="OnVideoEnded" />
//
//  y en el código de la ventana:  Video.Pause();  Video.Seek(10);  Video.Position ...
//
//  Desde código (sin diseñador):
//
//      auto video = VideoPlayer.Create("video", 20, 20, 640, 360);
//      window.Add(video.View);
//      video.Source = "/ruta/a/clip.mp4";
//      video.Play();
//
//  Los fotogramas se decodifican a BGRx (el formato del lienzo) y se copian escalados al
//  rectángulo del control. Sistemas:
//      Linux    GStreamer 1.0 (se carga con dlopen; solo hacen falta las bibliotecas y los
//               plugins: gstreamer1.0-plugins-base/good y gstreamer1.0-libav para H.264/AAC).
//               Source admite rutas y URI (file://, http://, https://...).
//      Android  libmediandk (AMediaExtractor + AMediaCodec) y AAudio para el sonido. Source es
//               una ruta del dispositivo (p. ej. /sdcard/Movies/clip.mp4 o el almacenamiento
//               de la app) o una URL http(s).
//      Windows  todavía no disponible: el control muestra el aviso y lanza Failed.
//  Sin pantalla (FASET_UI_SCREENSHOT) el sonido se descarta y se espera al primer fotograma.
// =============================================================================
using std.collections;
using std.io;
using std.os;
using std.ui;
using std.video;

namespace std.video
{
    // Capa nativa: runtime de C (src/RuntimeVideo.cpp).
    public memory_unsafe static class VideoNative
    {
        public static extern void* faset_video_open(string source, int flags);
        public static extern int faset_video_poll(void* video);
        public static extern int faset_video_update(void* video);
        public static extern int faset_video_frame_size(void* video, int* width, int* height);
        public static extern int faset_video_error(void* video, byte* buffer, int capacity);
        public static extern void faset_video_blit(void* video, uint* pixels, int canvasWidth, int canvasHeight,
                                                   int x, int y, int w, int h, int clipX0, int clipY0, int clipX1, int clipY1);
        public static extern void faset_video_play(void* video);
        public static extern void faset_video_pause(void* video);
        public static extern void faset_video_seek(void* video, double seconds);
        public static extern double faset_video_position(void* video);
        public static extern double faset_video_duration(void* video);
        public static extern void faset_video_set_volume(void* video, double volume);
        public static extern int faset_video_preroll(void* video, int milliseconds);
        public static extern void faset_video_close(void* video);
    }

    public static class VideoTime
    {
        // "1:05", "12:00" o "1:02:03" para una duración en segundos.
        public static func Format(seconds: double) -> string
        {
            int total = seconds > 0 ? (int)seconds : 0;
            int h = total / 3600, m = (total / 60) % 60, s = total % 60;
            string ss = (s < 10 ? "0" : "") + String.FromInt(s);
            if (h > 0) return String.FromInt(h) + ":" + (m < 10 ? "0" : "") + String.FromInt(m) + ":" + ss;
            return String.FromInt(m) + ":" + ss;
        }
    }
}

namespace std.ui
{
    // Cómo se ajusta la imagen al control.
    public enum VideoStretch
    {
        Uniform,  // cabe entera sin deformarse (bandas negras si hace falta)
        Fill,     // ocupa todo el control (puede deformarse)
        None      // tamaño original, centrada
    }

    // Reproductor de vídeo. 'View' es el control (Widget de tipo VideoPlayer) que se añade a la
    // ventana; el diseñador genera un campo VideoPlayer por cada <VideoPlayer>.
    public memory_unsafe class VideoPlayer
    {
        // Reproductores con un vídeo cargado: los actualiza el bucle de la ventana.
        static var active: List<VideoPlayer> = new List<VideoPlayer>();
        static var headless: int = -1;

        public var View: Widget;
        public var Loop: bool;
        public var ShowControls: bool = true;
        public var Stretch: VideoStretch = VideoStretch.Uniform;

        void* handle;
        var source: string = String.Copy("");
        var error: string = String.Copy("");
        var autoPlay: bool;
        var playing: bool;
        var ended: bool;
        var opened: bool;
        var failed: bool;
        var hasFrame: bool;
        var volume: float = 1;
        var duration: double = -1;
        var lastClock: long;
        var lastAction: long;    // última orden (Play, Seek...): se sigue sondeando un rato tras ella

        // Barra de controles: arrastre del deslizador de posición.
        var dragging: bool;
        var dragFraction: float;
        var lastDragSeek: long;

        // Eventos (como Widget.SetEvents): fn(target, View, número).
        delegate*<void*, Widget, int, void> eventFn;
        void* eventTarget;
        var openedEvent: int;
        var endedEvent: int;
        var failedEvent: int;

        public init(view: Widget)
        {
            View = view;
            view.Player = this;
        }

        // Crea el control y su reproductor (para añadir con window.Add(player.View)).
        public static func Create(name: string, x: int, y: int, w: int, h: int) -> VideoPlayer
        {
            return new VideoPlayer(Widget.Create(WidgetKind.VideoPlayer, name, x, y, w, h));
        }

        // Conecta los eventos Opened, Ended y Failed (0 = sin manejador).
        public void SetEvents(delegate*<void*, Widget, int, void> fn, void* target, int opened, int ended, int failed)
        {
            eventFn = fn;
            eventTarget = target;
            openedEvent = opened;
            endedEvent = ended;
            failedEvent = failed;
        }

        func Raise(ev: int)
        {
            if (ev != 0 && eventFn != null) eventFn(eventTarget, View, ev);
        }

        // ------------------------------------------------------------- propiedades

        // Archivo o URI del vídeo. Al cambiarlo se carga (en pausa, o en marcha con AutoPlay).
        public prop Source: string
        {
            get => source;
            set
            {
                Close();
                source = String.Copy(value);
                Open();
            }
        }

        // Empieza a reproducir en cuanto se asigna Source.
        public prop AutoPlay: bool
        {
            get => autoPlay;
            set
            {
                autoPlay = value;
                if (value && handle != null && !playing && !ended && !failed) Play();
            }
        }

        // Volumen de 0 a 1.
        public prop Volume: float
        {
            get => volume;
            set
            {
                float v = value < 0 ? 0 : (value > 1 ? 1 : value);
                volume = v;
                if (handle != null) VideoNative.faset_video_set_volume(handle, v);
            }
        }

        // Posición en segundos (asignarla equivale a Seek).
        public prop Position: double
        {
            get
            {
                if (dragging) return dragFraction * Duration;
                if (handle == null) return 0;
                if (ended && duration > 0) return duration;
                return VideoNative.faset_video_position(handle);
            }
            set { Seek(value); }
        }

        // Duración en segundos (0 si aún no se conoce o es un directo).
        public prop Duration: double
        {
            get
            {
                if (handle != null && duration <= 0) duration = VideoNative.faset_video_duration(handle);
                return duration > 0 ? duration : 0;
            }
        }

        public prop IsPlaying: bool => playing;
        public prop IsOpened: bool => opened;
        public prop HasEnded: bool => ended;
        public prop HasFailed: bool => failed;

        // Mensaje del último error ("" si no hubo).
        public prop Error: string => error;

        // Tamaño original del vídeo en píxeles (0 hasta el primer fotograma).
        public prop NaturalWidth: int
        {
            get
            {
                int w = 0, h = 0;
                if (handle != null) VideoNative.faset_video_frame_size(handle, &w, &h);
                return w;
            }
        }

        public prop NaturalHeight: int
        {
            get
            {
                int w = 0, h = 0;
                if (handle != null) VideoNative.faset_video_frame_size(handle, &w, &h);
                return h;
            }
        }

        // ------------------------------------------------------------- control

        public func Play()
        {
            if (handle == null || failed) return;
            VideoNative.faset_video_play(handle);
            playing = true;
            ended = false;
            Wake();
        }

        public func Pause()
        {
            if (handle == null) return;
            VideoNative.faset_video_pause(handle);
            playing = false;
            Wake();
        }

        public func TogglePlay()
        {
            if (playing) Pause();
            else Play();
        }

        // Detiene y vuelve al principio (se ve el primer fotograma).
        public func Stop()
        {
            if (handle == null) return;
            VideoNative.faset_video_pause(handle);
            VideoNative.faset_video_seek(handle, 0);
            playing = false;
            ended = false;
            Wake();
        }

        public func Seek(seconds: double)
        {
            if (handle == null) return;
            if (seconds < 0) seconds = 0;
            double d = Duration;
            if (d > 0 && seconds > d) seconds = d;
            VideoNative.faset_video_seek(handle, seconds);
            ended = false;
            Wake();
        }

        // Libera el vídeo (el control queda vacío). Se llama solo al cerrar la ventana.
        public func Close()
        {
            if (handle != null)
            {
                VideoNative.faset_video_close(handle);
                handle = null;
            }
            active.Remove(this);
            playing = false;
            ended = false;
            opened = false;
            failed = false;
            hasFrame = false;
            duration = -1;
            String.Free(error);
            error = String.Copy("");
            Wake();
        }

        func Open()
        {
            if (source.Length == 0) return;
            if (headless < 0)
            {
                string shot = Environment.GetVariable("FASET_UI_SCREENSHOT");
                headless = shot.Length > 0 ? 1 : 0;
                String.Free(shot);
            }
            string path = ResolvePath(source);
            handle = VideoNative.faset_video_open(path, headless == 1 ? 1 : 0);
            String.Free(path);
            if (handle == null) return;
            active.Add(this);
            if (volume != 1) VideoNative.faset_video_set_volume(handle, volume);
            // Los eventos (Opened, Failed...) se entregan en el siguiente Tick: así llegan aunque
            // Source se asigne en InitializeComponent antes de conectar los manejadores.
            if (autoPlay && !failed) Play();
        }

        // Las rutas relativas se buscan en la carpeta actual y, si no están ahí, el runtime de C
        // prueba junto al ejecutable.
        static func ResolvePath(s: string) -> string => String.Copy(s);

        func Wake()
        {
            lastAction = Environment.TickCount64();
            if (View != null) View.Invalidate();
        }

        // ------------------------------------------------------------- bucle

        // Atiende eventos y recoge el fotograma más reciente (hilo de la interfaz).
        internal func Update()
        {
            if (handle == null) return;
            int ev = VideoNative.faset_video_poll(handle);
            while (ev != 0)
            {
                if (ev == 1)
                {
                    opened = true;
                    duration = VideoNative.faset_video_duration(handle);
                    Wake();
                    Raise(openedEvent);
                }
                else if (ev == 2)
                {
                    if (Loop && playing)
                    {
                        VideoNative.faset_video_seek(handle, 0);
                        VideoNative.faset_video_play(handle);
                    }
                    else
                    {
                        playing = false;
                        ended = true;
                        Wake();
                        Raise(endedEvent);
                    }
                }
                else if (ev == 3)
                {
                    failed = true;
                    playing = false;
                    byte* buf = (byte*)Memory.AllocZeroed(512);
                    int n = VideoNative.faset_video_error(handle, buf, 512);
                    String.Free(error);
                    error = String.Copy(String.FromBytes(buf, n));
                    Memory.Free(buf);
                    Wake();
                    Raise(failedEvent);
                }
                if (handle == null) return;  // un manejador cerró o cambió el vídeo
                ev = VideoNative.faset_video_poll(handle);
            }
            if (VideoNative.faset_video_update(handle) != 0)
            {
                hasFrame = true;
                Wake();
            }
            // El tiempo de la barra se refresca aunque no lleguen fotogramas (vídeo sin imagen).
            if (playing && ShowControls)
            {
                long now = Environment.TickCount64();
                if (now - lastClock >= 250)
                {
                    lastClock = now;
                    Wake();
                }
            }
        }

        // Actualiza todos los reproductores; devuelve cuántos ms puede dormir el bucle (-1 = sin límite).
        public static func Tick() -> int
        {
            int wait = -1;
            for (int i = active.Count - 1; i >= 0; i--)
            {
                if (i >= active.Count) continue;
                VideoPlayer p = active[i];
                p.Update();
                // En pausa, el fotograma de una búsqueda o de la precarga llega después: se
                // sondea durante 2 s tras la última orden.
                if (p.playing) wait = 5;
                else if (wait < 0 && Environment.TickCount64() - p.lastAction < 2000) wait = 15;
            }
            return wait;
        }

        // Sin pantalla: espera a que cada vídeo tenga su primer fotograma.
        public static func PrerollAll(milliseconds: int)
        {
            for (int i = 0; i < active.Count; i++)
            {
                VideoPlayer p = active[i];
                if (p.handle != null && !p.failed && !p.hasFrame && VideoNative.faset_video_preroll(p.handle, milliseconds) != 0)
                    p.hasFrame = true;
                p.Update();
            }
        }

        // Deja pasar el tiempo atendiendo a los vídeos (FASET_UI_SCRIPT: "wait 1500").
        public static func WaitTicking(milliseconds: int)
        {
            long end = Environment.TickCount64() + milliseconds;
            while (Environment.TickCount64() < end)
            {
                Tick();
                EventWait.WaitFd(-1, 5);
            }
            Tick();
        }

        // Cierra los vídeos de una ventana que se cierra (para el sonido).
        public static func CloseAll(w: Window)
        {
            for (int i = active.Count - 1; i >= 0; i--)
            {
                if (i >= active.Count) continue;
                VideoPlayer p = active[i];
                if (p.View == null || p.View.Owner == w || p.View.Owner == null) p.Close();
            }
        }

        // ------------------------------------------------------------- dibujo

        const int BarHeight = 44;

        func BarVisible(w: Window) -> bool => ShowControls && (w.Hot == View || !playing || dragging || w.Pressed == View);

        internal func Draw(c: Canvas, p: Palette, w: Window)
        {
            Widget v = View;
            float fx = v.ScreenX, fy = v.ScreenY, fw = v.ActualWidth, fh = v.ActualHeight;
            if (fw <= 0 || fh <= 0) return;
            uint bg = v.Background != 0 ? v.Background : Rgb.Of(0x000000);
            c.FillRect(v.ScreenX, v.ScreenY, v.ActualWidth, v.ActualHeight, bg);
            if (hasFrame && handle != null) DrawFrame(c);
            else DrawPlaceholder(c, p, v, source, error, fx, fy, fw, fh);
            if (ShowControls && !playing && !failed && handle != null && fh >= 100) DrawBigPlay(c, fx + fw / 2, fy + fh / 2 - (BarVisible(w) ? 10 : 0));
            if (BarVisible(w) && handle != null && !failed) DrawBar(c, p, fx, fy, fw, fh);
            if (v.BorderColor != 0) c.StrokeRoundRect(fx, fy, fw, fh, 0, 1, v.BorderColor);
        }

        func DrawFrame(c: Canvas)
        {
            int vw = 0, vh = 0;
            VideoNative.faset_video_frame_size(handle, &vw, &vh);
            if (vw <= 0 || vh <= 0) return;
            float s = c.Scale;
            int x0 = (int)Math.Floor(View.ScreenX * s + 0.5f), y0 = (int)Math.Floor(View.ScreenY * s + 0.5f);
            int x1 = (int)Math.Floor((View.ScreenX + View.ActualWidth) * s + 0.5f);
            int y1 = (int)Math.Floor((View.ScreenY + View.ActualHeight) * s + 0.5f);
            int pw = x1 - x0, ph = y1 - y0;
            int dw = pw, dh = ph;
            if (Stretch == VideoStretch.Uniform)
            {
                if ((long)pw * vh > (long)ph * vw)
                {
                    dh = ph;
                    dw = (int)((long)vw * ph / vh);
                }
                else
                {
                    dw = pw;
                    dh = (int)((long)vh * pw / vw);
                }
            }
            else if (Stretch == VideoStretch.None)
            {
                dw = (int)(vw * s + 0.5f);
                dh = (int)(vh * s + 0.5f);
            }
            int dx = x0 + (pw - dw) / 2, dy = y0 + (ph - dh) / 2;
            VideoNative.faset_video_blit(handle, c.Pixels, c.Width, c.Height, dx, dy, dw, dh, x0, y0, x1, y1);
        }

        // Icono de película con el nombre del archivo (o el error). También lo usa el diseñador.
        public static func DrawPlaceholder(c: Canvas, p: Palette, v: Widget, source: string, error: string, fx: float, fy: float, fw: float, fh: float)
        {
            uint fg = Rgb.Alpha(0xffffff, 0.55f);
            float cx = fx + fw / 2, cy = fy + fh / 2 - 10;
            float iw = 44, ih = 32;
            if (fh < 90)
            {
                iw = 30;
                ih = 22;
                cy = fy + fh / 2;
            }
            // Fotograma de película con perforaciones.
            c.StrokeRoundRect(cx - iw / 2, cy - ih / 2, iw, ih, 4, 1.6f, fg);
            for (int k = 0; k < 4; k++)
            {
                float hx = cx - iw / 2 + 5 + k * (iw - 12) / 3;
                c.FillRoundRect(hx, cy - ih / 2 + 3, 3, 3, 1, fg);
                c.FillRoundRect(hx, cy + ih / 2 - 6, 3, 3, 1, fg);
            }
            FillPlayTriangle(c, cx + 1, cy, ih * 0.22f, fg);
            if (fh < 90) return;
            string label = error.Length > 0 ? error : (source.Length > 0 ? Path.GetFileName(source) : "VideoPlayer");
            UiFont font = UiFont.Get(12, false);
            c.Clip(v.ScreenX + 4, v.ScreenY, v.ActualWidth - 8, v.ActualHeight);
            float tw = font.Measure(label);
            uint tc = error.Length > 0 ? Rgb.Of(0xff8a8a) : Rgb.Alpha(0xffffff, 0.7f);
            c.Text(font, label, tw < fw - 8 ? cx - tw / 2 : fx + 4, cy + ih / 2 + 22, tc);
            c.ResetClip();
        }

        // Triángulo de "reproducir" relleno (abanico de segmentos) centrado en cx, cy.
        static func FillPlayTriangle(c: Canvas, cx: float, cy: float, r: float, color: uint)
        {
            float left = cx - r * 0.75f, right = cx + r;
            for (float k = -r; k <= r; k += 0.75f) c.Line(left, cy + k, right, cy, 1.2f, color);
            c.Line(left, cy - r, left, cy + r, 1.2f, color);
        }

        static func DrawBigPlay(c: Canvas, cx: float, cy: float)
        {
            c.FillCircle(cx, cy, 28, Rgb.Alpha(0x000000, 0.55f));
            c.StrokeRoundRect(cx - 28, cy - 28, 56, 56, 28, 1.5f, Rgb.Alpha(0xffffff, 0.5f));
            FillPlayTriangle(c, cx + 3, cy, 11, Rgb.Of(0xffffff));
        }

        // Zona del deslizador dentro de la barra (coordenadas lógicas de la ventana).
        func SliderRange(font: UiFont, out left: float, out right: float)
        {
            float fx = View.ScreenX, fw = View.ActualWidth;
            string sample = VideoTime.Format(Duration);
            float tw = font.Measure(sample) * 2 + font.Measure(" / ");
            left = fx + 48;
            right = fx + fw - tw - 22;
            if (right < left + 20) right = left + 20;
        }

        func DrawBar(c: Canvas, p: Palette, fx: float, fy: float, fw: float, fh: float)
        {
            float top = fy + fh - BarHeight;
            c.FillRoundRectGradient(fx, top - 16, fw, BarHeight + 16, 0, Rgb.Alpha(0x000000, 0), Rgb.Alpha(0x000000, 0.72f), false);
            uint white = Rgb.Of(0xffffff);
            float cy = top + BarHeight / 2;
            // Reproducir / pausa.
            float bx = fx + 24;
            if (playing)
            {
                c.FillRoundRect(bx - 6, cy - 7, 4, 14, 1.5f, white);
                c.FillRoundRect(bx + 2, cy - 7, 4, 14, 1.5f, white);
            }
            else FillPlayTriangle(c, bx + 1, cy, 7, white);
            // Tiempo.
            UiFont font = UiFont.Get(12, false);
            string time = VideoTime.Format(Position) + " / " + VideoTime.Format(Duration);
            float tw = font.Measure(time);
            c.Text(font, time, fx + fw - tw - 12, cy - font.LineHeight / 2 + font.Ascent, white);
            // Posición.
            float left = 0, right = 0;
            SliderRange(font, out left, out right);
            double d = Duration;
            float frac = dragging ? dragFraction : (d > 0 ? (float)(Position / d) : 0);
            if (frac < 0) frac = 0;
            if (frac > 1) frac = 1;
            uint accent = View.Accent != 0 ? View.Accent : white;
            c.FillRoundRect(left, cy - 2, right - left, 4, 2, Rgb.Alpha(0xffffff, 0.28f));
            float pos = left + (right - left) * frac;
            if (pos > left) c.FillRoundRect(left, cy - 2, pos - left, 4, 2, accent);
            c.FillCircle(pos, cy, dragging ? 7 : 6, accent);
        }

        // ------------------------------------------------------------- ratón (lo llama Window)

        internal func MouseDown(mx: int, my: int)
        {
            if (!ShowControls || handle == null || failed) return;
            float fy = View.ScreenY, fh = View.ActualHeight;
            if (my >= fy + fh - BarHeight)
            {
                float left = 0, right = 0;
                SliderRange(UiFont.Get(12, false), out left, out right);
                if (mx < View.ScreenX + 42) TogglePlay();
                else if (mx >= left - 8 && mx <= right + 8 && Duration > 0)
                {
                    dragging = true;
                    DragTo(mx, true);
                }
                return;
            }
            TogglePlay();
        }

        internal func MouseDrag(mx: int)
        {
            if (dragging) DragTo(mx, false);
        }

        internal func MouseUp(mx: int)
        {
            if (!dragging) return;
            DragTo(mx, true);
            dragging = false;
            Wake();
        }

        func DragTo(mx: int, force: bool)
        {
            float left = 0, right = 0;
            SliderRange(UiFont.Get(12, false), out left, out right);
            float t = right > left ? (mx - left) / (right - left) : 0;
            if (t < 0) t = 0;
            if (t > 1) t = 1;
            dragFraction = t;
            long now = Environment.TickCount64();
            if (force || now - lastDragSeek >= 80)
            {
                lastDragSeek = now;
                if (handle != null) VideoNative.faset_video_seek(handle, t * Duration);
                ended = false;
            }
            Wake();
        }
    }
}
