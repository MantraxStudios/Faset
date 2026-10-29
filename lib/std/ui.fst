// =============================================================================
//  std.ui  —  interfaces de escritorio nativas para Windows y Linux.
//
//  Las ventanas se diseñan en archivos .fstui (con el diseñador de FasetStudio) y el
//  compilador genera una clase 'partial' con un campo por control:
//
//      public partial class MainWindow
//      {
//          public MainWindow() { InitializeComponent(); }
//          void OnSaveClick(Widget sender) { lblStatus.Text = "Saved"; }
//      }
//      ...
//      Application.Run(new MainWindow().Window);
//
//  Todo se dibuja por software (formas con antialiasing y texto con la fuente del
//  sistema) y se copia a la ventana: X11 + FreeType en Linux, Win32 + GDI en Windows,
//  ANativeWindow + stb_truetype en Android (pantalla completa, toques = ratón).
//  Bibliotecas: el compilador enlaza X11 y freetype (Linux), user32 y gdi32 (Windows)
//  o android y log (Android).
//
//  Densidad: las coordenadas de los controles son lógicas; el lienzo multiplica por
//  'Scale' (1 en escritorio, dpi/160 en Android) y las fuentes se rasterizan al tamaño
//  real, así el texto se ve nítido en pantallas de alta densidad.
// =============================================================================
using std.collections;
using std.text;
using std.io;
using std.os;

namespace std.ui
{
    public enum WidgetKind { Panel, Label, Button, TextBox, CheckBox, Slider, ProgressBar, RadioButton, ComboBox, ListBox }
    public enum WidgetStyle { Default, Primary, Subtle, Danger }
    public enum TextAlign { Left, Center, Right }
    public enum UiTheme { Dark, Light }
    public enum Anchor { None = 0, Left = 1, Top = 2, Right = 4, Bottom = 8 }
    public enum CursorShape { Arrow, Text, Hand }

    // ======================================================================= colores

    // Colores 0xAARRGGBB.
    public static class Rgb
    {
        public static uint Of(uint rgb) => 0xff000000 | rgb;
        public static uint Alpha(uint rgb, float a) => ((uint)(Math.Clamp((double)a, 0.0, 1.0) * 255) << 24) | (rgb & 0xffffff);

        // Mezcla lineal de dos colores ARGB (t = 0..1).
        public static uint Mix(uint a, uint b, float t)
        {
            if (t <= 0) return a;
            if (t >= 1) return b;
            uint r = 0;
            for (int shift = 0; shift < 32; shift += 8)
            {
                float ca = (float)((a >> shift) & 0xff), cb = (float)((b >> shift) & 0xff);
                r |= ((uint)(ca + (cb - ca) * t + 0.5f) & 0xff) << shift;
            }
            return r;
        }

        // "#RGB", "#RRGGBB" o "#RRGGBBAA" -> 0xAARRGGBB; 0 si no es válido.
        public static uint Parse(string s)
        {
            if (s.Length == 0 || s[0] != '#') return 0;
            uint v = 0;
            int digits = s.Length - 1;
            if (digits != 3 && digits != 6 && digits != 8) return 0;
            for (int i = 1; i < s.Length; i++)
            {
                byte c = s[i];
                uint d = c >= '0' && c <= '9' ? (uint)(c - '0') : (c >= 'a' && c <= 'f' ? (uint)(c - 'a' + 10) : (c >= 'A' && c <= 'F' ? (uint)(c - 'A' + 10) : 99));
                if (d == 99) return 0;
                v = (v << 4) | d;
            }
            if (digits == 3) return 0xff000000 | ((v >> 8) * 0x110000) | (((v >> 4) & 15) * 0x1100) | ((v & 15) * 0x11);
            if (digits == 6) return 0xff000000 | v;
            return (v >> 8) | ((v & 0xff) << 24);
        }
    }

    public class Palette
    {
        public uint Background;
        public uint Surface;
        public uint SurfaceHover;
        public uint SurfacePressed;
        public uint Border;
        public uint BorderStrong;
        public uint Input;
        public uint Text;
        public uint TextMuted;
        public uint Primary;
        public uint PrimaryHover;
        public uint PrimaryText;
        public uint Danger;
        public uint Track;
        public uint Selection;
        public uint Focus;

        public static Palette For(UiTheme theme)
        {
            auto p = new Palette();
            if (theme == UiTheme.Light)
            {
                p.Background = Rgb.Of(0xf5f5f6);
                p.Surface = Rgb.Of(0xffffff);
                p.SurfaceHover = Rgb.Of(0xf0f0f2);
                p.SurfacePressed = Rgb.Of(0xe6e6e9);
                p.Border = Rgb.Of(0xdedee2);
                p.BorderStrong = Rgb.Of(0xc4c4ca);
                p.Input = Rgb.Of(0xffffff);
                p.Text = Rgb.Of(0x18181b);
                p.TextMuted = Rgb.Of(0x71717a);
                p.Primary = Rgb.Of(0x18181b);
                p.PrimaryHover = Rgb.Of(0x2e2e33);
                p.PrimaryText = Rgb.Of(0xffffff);
                p.Danger = Rgb.Of(0xdc3c3c);
                p.Track = Rgb.Of(0xe4e4e7);
                p.Selection = Rgb.Alpha(0x18181b, 0.16f);
                p.Focus = Rgb.Alpha(0x18181b, 0.35f);
            }
            else
            {
                p.Background = Rgb.Of(0x0f0f11);
                p.Surface = Rgb.Of(0x18181b);
                p.SurfaceHover = Rgb.Of(0x222226);
                p.SurfacePressed = Rgb.Of(0x2b2b30);
                p.Border = Rgb.Of(0x2a2a2f);
                p.BorderStrong = Rgb.Of(0x3a3a41);
                p.Input = Rgb.Of(0x0b0b0d);
                p.Text = Rgb.Of(0xececee);
                p.TextMuted = Rgb.Of(0x8e8e96);
                p.Primary = Rgb.Of(0xf4f4f5);
                p.PrimaryHover = Rgb.Of(0xffffff);
                p.PrimaryText = Rgb.Of(0x0b0b0c);
                p.Danger = Rgb.Of(0xe5484d);
                p.Track = Rgb.Of(0x2c2c31);
                p.Selection = Rgb.Alpha(0xffffff, 0.18f);
                p.Focus = Rgb.Alpha(0xffffff, 0.45f);
            }
            return p;
        }
    }

    // ======================================================================= lienzo

    // Mapa de píxeles 0x00RRGGBB con primitivas antialias (por distancia con signo).
    public memory_unsafe class Canvas
    {
        public uint* Pixels;
        public int Width;         // en píxeles físicos
        public int Height;
        public float Scale = 1;   // píxeles físicos por unidad lógica (las primitivas usan unidades lógicas)
        int clipX0;
        int clipY0;
        int clipX1;
        int clipY1;

        ~Canvas() { Memory.Free(Pixels); }

        public void Resize(int w, int h)
        {
            if (w < 1) w = 1;
            if (h < 1) h = 1;
            if (w == Width && h == Height && Pixels != null) return;
            Memory.Free(Pixels);
            Pixels = (uint*)Memory.AllocZeroed((long)w * h * 4);
            Width = w;
            Height = h;
            ResetClip();
        }

        public void ResetClip()
        {
            clipX0 = 0;
            clipY0 = 0;
            clipX1 = Width;
            clipY1 = Height;
        }

        // Limita el dibujo a la intersección del recorte actual con el rectángulo.
        public void Clip(int x, int y, int w, int h)
        {
            if (Scale != 1)
            {
                int x0 = (int)Math.Floor(x * Scale + 0.5f), y0 = (int)Math.Floor(y * Scale + 0.5f);
                w = (int)Math.Floor((x + w) * Scale + 0.5f) - x0;
                h = (int)Math.Floor((y + h) * Scale + 0.5f) - y0;
                x = x0;
                y = y0;
            }
            clipX0 = Math.Max(clipX0, x);
            clipY0 = Math.Max(clipY0, y);
            clipX1 = Math.Min(clipX1, x + w);
            clipY1 = Math.Min(clipY1, y + h);
        }

        public void Clear(uint color)
        {
            uint c = color & 0xffffff;
            long n = (long)Width * Height;
            for (long i = 0; i < n; i++) Pixels[i] = c;
        }

        // Mezcla 'color' (con su alfa) sobre el píxel, con cobertura 0..255.
        void Blend(int x, int y, uint color, int coverage)
        {
            int a = (int)((color >> 24) * (uint)coverage / 255);
            if (a <= 0) return;
            uint* p = Pixels + (long)y * Width + x;
            if (a >= 255)
            {
                *p = color & 0xffffff;
                return;
            }
            uint d = *p;
            uint ia = (uint)(255 - a);
            uint ua = (uint)a;
            uint rb = (((color & 0xff00ff) * ua + (d & 0xff00ff) * ia) >> 8) & 0xff00ff;
            uint g = (((color & 0xff00) * ua + (d & 0xff00) * ia) >> 8) & 0xff00;
            *p = rb | g;
        }

        static float Cov(float d) => d >= 0.5f ? 0.0f : (d <= -0.5f ? 1.0f : 0.5f - d);

        // Distancia con signo a un rectángulo redondeado (centro, semiancho, semialto, radio).
        static float RoundRectDistance(float px, float py, float cx, float cy, float hw, float hh, float r)
        {
            float qx = (float)Math.Abs(px - cx) - hw + r;
            float qy = (float)Math.Abs(py - cy) - hh + r;
            if (qx <= 0 && qy <= 0) return (qx > qy ? qx : qy) - r;
            float ox = qx > 0 ? qx : 0;
            float oy = qy > 0 ? qy : 0;
            float inside = qx > qy ? qx : qy;
            return (float)Math.Sqrt(ox * ox + oy * oy) + (inside < 0 ? inside : 0) - r;
        }

        public void FillRect(int x, int y, int w, int h, uint color)
        {
            if (Scale != 1)
            {
                int sx = (int)Math.Floor(x * Scale + 0.5f), sy = (int)Math.Floor(y * Scale + 0.5f);
                w = (int)Math.Floor((x + w) * Scale + 0.5f) - sx;
                h = (int)Math.Floor((y + h) * Scale + 0.5f) - sy;
                x = sx;
                y = sy;
            }
            int x0 = Math.Max(x, clipX0), y0 = Math.Max(y, clipY0);
            int x1 = Math.Min(x + w, clipX1), y1 = Math.Min(y + h, clipY1);
            for (int py = y0; py < y1; py++)
                for (int px = x0; px < x1; px++) Blend(px, py, color, 255);
        }

        public void FillRoundRect(float x, float y, float w, float h, float r, uint color)
        {
            StrokeOrFill(x, y, w, h, r, -1, color, color, false);
        }

        // Degradado lineal de 'from' a 'to' (de arriba abajo, o de izquierda a derecha).
        public void FillRoundRectGradient(float x, float y, float w, float h, float r, uint from, uint to, bool horizontal)
        {
            StrokeOrFill(x, y, w, h, r, -1, from, to, horizontal);
        }

        public void StrokeRoundRect(float x, float y, float w, float h, float r, float thickness, uint color)
        {
            StrokeOrFill(x, y, w, h, r, thickness, color, color, false);
        }

        void StrokeOrFill(float x, float y, float w, float h, float r, float thickness, uint color, uint color2, bool horizontal)
        {
            bool gradient = color2 != color;
            if (w <= 0 || h <= 0) return;
            if (Scale != 1)
            {
                x *= Scale;
                y *= Scale;
                w *= Scale;
                h *= Scale;
                r *= Scale;
                if (thickness > 0) thickness *= Scale;
            }
            float maxR = (w < h ? w : h) / 2;
            if (r > maxR) r = maxR;
            if (r < 0) r = 0;
            float cx = x + w / 2, cy = y + h / 2, hw = w / 2, hh = h / 2;
            int x0 = Math.Max((int)Math.Floor(x), clipX0), y0 = Math.Max((int)Math.Floor(y), clipY0);
            int x1 = Math.Min((int)Math.Ceiling(x + w), clipX1), y1 = Math.Min((int)Math.Ceiling(y + h), clipY1);
            for (int py = y0; py < y1; py++)
            {
                float fy = py + 0.5f;
                for (int px = x0; px < x1; px++)
                {
                    float d = RoundRectDistance(px + 0.5f, fy, cx, cy, hw, hh, r);
                    float c = Cov(d);
                    if (thickness > 0) c = c - Cov(d + thickness);
                    if (c <= 0) continue;
                    uint col = gradient ? Rgb.Mix(color, color2, horizontal ? (px + 0.5f - x) / w : (fy - y) / h) : color;
                    Blend(px, py, col, (int)(c * 255 + 0.5f));
                }
            }
        }

        public void FillCircle(float cx, float cy, float r, uint color)
        {
            FillRoundRect(cx - r, cy - r, r * 2, r * 2, r, color);
        }

        // Segmento con extremos redondeados.
        public void Line(float ax, float ay, float bx, float by, float thickness, uint color)
        {
            if (Scale != 1)
            {
                ax *= Scale;
                ay *= Scale;
                bx *= Scale;
                by *= Scale;
                thickness *= Scale;
            }
            float half = thickness / 2;
            int x0 = Math.Max((int)Math.Floor((ax < bx ? ax : bx) - half - 1), clipX0);
            int y0 = Math.Max((int)Math.Floor((ay < by ? ay : by) - half - 1), clipY0);
            int x1 = Math.Min((int)Math.Ceiling((ax > bx ? ax : bx) + half + 1), clipX1);
            int y1 = Math.Min((int)Math.Ceiling((ay > by ? ay : by) + half + 1), clipY1);
            float dx = bx - ax, dy = by - ay;
            float len2 = dx * dx + dy * dy;
            for (int py = y0; py < y1; py++)
                for (int px = x0; px < x1; px++)
                {
                    float qx = px + 0.5f - ax, qy = py + 0.5f - ay;
                    float t = len2 > 0 ? (qx * dx + qy * dy) / len2 : 0;
                    if (t < 0) t = 0;
                    if (t > 1) t = 1;
                    float ex = qx - dx * t, ey = qy - dy * t;
                    float c = Cov((float)Math.Sqrt(ex * ex + ey * ey) - half);
                    if (c > 0) Blend(px, py, color, (int)(c * 255 + 0.5f));
                }
        }

        // Dibuja texto con la línea base en 'baseline'; devuelve la x final.
        public float Text(UiFont font, string s, float x, float baseline, uint color)
        {
            int i = 0;
            int by = (int)Math.Floor(baseline * Scale + 0.5f);  // los glifos ya están a tamaño físico
            while (i < s.Length)
            {
                char ch = UiFont.NextChar(s, ref i);
                GlyphImage g = font.Get(ch);
                int gx = (int)Math.Floor(x * Scale + 0.5f) + g.Left;
                int gy = by - g.Top;
                for (int row = 0; row < g.Height; row++)
                {
                    int py = gy + row;
                    if (py < clipY0 || py >= clipY1) continue;
                    byte* src = g.Coverage + (long)row * g.Width;
                    for (int col = 0; col < g.Width; col++)
                    {
                        int px = gx + col;
                        if (px < clipX0 || px >= clipX1 || src[col] == 0) continue;
                        Blend(px, py, color, src[col]);
                    }
                }
                x += g.Advance;
            }
            return x;
        }

        // Guarda el lienzo como BMP de 32 bits (capturas de pantalla y pruebas).
        public bool SaveBmp(string path)
        {
            long dataSize = (long)Width * Height * 4;
            byte* buf = (byte*)Memory.AllocZeroed(54 + dataSize);
            buf[0] = (byte)'B';
            buf[1] = (byte)'M';
            *(uint*)(buf + 2) = (uint)(54 + dataSize);
            *(uint*)(buf + 10) = 54;
            *(uint*)(buf + 14) = 40;
            *(int*)(buf + 18) = Width;
            *(int*)(buf + 22) = -Height;  // de arriba abajo
            *(ushort*)(buf + 26) = 1;
            *(ushort*)(buf + 28) = 32;
            Memory.Copy(buf + 54, Pixels, dataSize);
            bool ok = File.WriteAllText(path, String.FromBytes(buf, 54 + dataSize));
            Memory.Free(buf);
            return ok;
        }
    }

    // ======================================================================= fuentes

    public memory_unsafe struct GlyphImage
    {
        public byte* Coverage;  // Width x Height, 0..255
        public int Width;
        public int Height;
        public int Left;        // desde el origen hasta el primer píxel
        public int Top;         // desde la línea base hasta la fila superior (hacia arriba)
        public float Advance;
    }

    // Fuente del sistema a un tamaño concreto; los glifos se rasterizan bajo demanda.
    public memory_unsafe class UiFont
    {
        static List<UiFont> cache = new List<UiFont>();

        Dictionary<char, GlyphImage> glyphs = new Dictionary<char, GlyphImage>();
        void* handle;  // FT_Face (Linux), HDC con la fuente seleccionada (Windows) o fuente de stb_truetype (Android)
        float scale = 1;
        public int Size;
        public bool Bold;
        public float Ascent;
        public float Descent;
        public float LineHeight => Ascent + Descent;

        // Densidad de la pantalla: los glifos se rasterizan a Size * Scale píxeles y las
        // medidas (Advance, Ascent...) se dan en unidades lógicas. La fija la ventana.
        public static float Scale = 1;

        public static UiFont Get(int size, bool bold)
        {
            if (size < 6) size = 6;
            for (int i = 0; i < cache.Count; i++)
                if (cache[i].Size == size && cache[i].Bold == bold && cache[i].scale == Scale) return cache[i];
            auto f = new UiFont();
            f.Size = size;
            f.Bold = bold;
            f.scale = Scale;
            f.Open();
            cache.Add(f);
            return f;
        }

        public GlyphImage Get(char c)
        {
            GlyphImage g;
            if (glyphs.TryGetValue(c, out g)) return g;
            g = new GlyphImage();
            if (handle != null) g = Rasterize(c);
            if (g.Advance == 0 && handle == null) g.Advance = Size * 0.55f;
            glyphs.Set(c, g);
            return g;
        }

        public float Measure(string s) => MeasureBytes(s, s.Length);

        // Ancho de los primeros 'bytes' bytes de 's'.
        public float MeasureBytes(string s, int bytes)
        {
            float w = 0;
            int i = 0;
            while (i < bytes && i < s.Length) w += Get(NextChar(s, ref i)).Advance;
            return w;
        }

        // Decodifica el carácter UTF-8 que empieza en s[i]; avanza i.
        public static char NextChar(string s, ref int i)
        {
            byte b = s[i];
            if (b < 0x80)
            {
                i++;
                return (char)b;
            }
            int extra = b >= 0xF8 ? 0 : (b >= 0xF0 ? 3 : (b >= 0xE0 ? 2 : (b >= 0xC2 ? 1 : 0)));
            // Secuencia incompleta o inválida (p. ej. texto Latin-1): el byte vale por sí mismo,
            // sin tragarse los siguientes (si no, "é" + dos letras se vería como un ideograma).
            bool valid = extra > 0 && i + extra < s.Length;
            for (int k = 1; valid && k <= extra; k++)
                if ((s[i + k] & 0xC0) != 0x80) valid = false;
            if (!valid)
            {
                i++;
                return (char)b;
            }
            uint cp = (uint)(b & (0x3F >> extra));
            i++;
            for (int k = 0; k < extra; k++)
            {
                cp = (cp << 6) | (uint)(s[i] & 0x3F);
                i++;
            }
            return (char)cp;
        }

#if WINDOWS
        void Open()
        {
            void* dc = Win32.CreateCompatibleDC(null);
            ushort* face = Win32.Wide("Segoe UI");
            void* font = Win32.CreateFontW(-Size, 0, 0, 0, Bold ? 600 : 400, 0, 0, 0, 1, 0, 0, 4, 0, face);
            Memory.Free(face);
            Win32.SelectObject(dc, font);
            byte* tm = (byte*)Memory.AllocZeroed(64);  // TEXTMETRICW
            Win32.GetTextMetricsW(dc, tm);
            Ascent = *(int*)(tm + 4);
            Descent = *(int*)(tm + 8);
            Memory.Free(tm);
            handle = dc;
        }

        GlyphImage Rasterize(char c)
        {
            GlyphImage g = new GlyphImage();
            byte* gm = (byte*)Memory.AllocZeroed(24);    // GLYPHMETRICS
            byte* mat = (byte*)Memory.AllocZeroed(16);   // MAT2 identidad
            *(short*)(mat + 2) = 1;
            *(short*)(mat + 14) = 1;
            uint ch = (uint)c;
            uint size = Win32.GetGlyphOutlineW(handle, ch, 6, gm, 0, null, mat);  // GGO_GRAY8_BITMAP
            if (size == 0xffffffff)
            {
                Memory.Free(gm);
                Memory.Free(mat);
                return g;
            }
            g.Advance = *(short*)(gm + 16);
            int bw = (int)*(uint*)gm, bh = (int)*(uint*)(gm + 4);
            g.Left = *(int*)(gm + 8);
            g.Top = *(int*)(gm + 12);
            if (size > 0 && bw > 0 && bh > 0)
            {
                byte* raw = (byte*)Memory.AllocZeroed(size);
                Win32.GetGlyphOutlineW(handle, ch, 6, gm, size, raw, mat);
                int pitch = (bw + 3) & ~3;
                g.Width = bw;
                g.Height = bh;
                g.Coverage = (byte*)Memory.AllocZeroed((long)bw * bh);
                for (int y = 0; y < bh; y++)
                    for (int x = 0; x < bw; x++)
                    {
                        int v = raw[y * pitch + x];
                        g.Coverage[y * bw + x] = (byte)(v >= 64 ? 255 : v * 4);
                    }
                Memory.Free(raw);
            }
            Memory.Free(gm);
            Memory.Free(mat);
            return g;
        }
#elif ANDROID
        static string FindFile(string candidates)
        {
            auto parts = Text.Split(candidates, ";");
            string found = "";
            for (int i = 0; i < parts.Count; i++)
                if (File.Exists(parts[i]))
                {
                    found = parts[i];
                    break;
                }
            delete parts;
            return found;
        }

        void Open()
        {
            // Roboto es variable desde Android 12: si no hay una negrita estática se engrosa la regular.
            string bold = Bold ? FindFile("/system/fonts/Roboto-Bold.ttf;/system/fonts/RobotoStatic-Bold.ttf;/system/fonts/NotoSans-Bold.ttf;/system/fonts/DroidSans-Bold.ttf") : "";
            string path = bold.Length > 0 ? bold
                : FindFile("/system/fonts/Roboto-Regular.ttf;/system/fonts/RobotoStatic-Regular.ttf;/system/fonts/NotoSans-Regular.ttf;/system/fonts/DroidSans.ttf");
            Ascent = Size * 0.8f;
            Descent = Size * 0.25f;
            if (path.Length == 0) return;
            string p = path.ToCString();
            float asc = 0, desc = 0;
            handle = AndroidNative.faset_ttf_open(p.Ptr, Size * scale, Bold && bold.Length == 0 ? 1 : 0, &asc, &desc);
            String.Free(p);
            if (handle == null) return;
            Ascent = asc / scale;
            Descent = desc / scale;
        }

        GlyphImage Rasterize(char c)
        {
            GlyphImage g = new GlyphImage();
            byte* cov = null;
            int w = 0, h = 0, left = 0, top = 0;
            float adv = 0;
            AndroidNative.faset_ttf_glyph(handle, (uint)c, &cov, &w, &h, &left, &top, &adv);
            g.Coverage = cov;
            g.Width = w;
            g.Height = h;
            g.Left = left;
            g.Top = top;
            g.Advance = adv / scale;
            return g;
        }
#else
        static void* library;

        static string FindFile(string candidates)
        {
            auto parts = Text.Split(candidates, ";");
            string found = "";
            for (int i = 0; i < parts.Count; i++)
                if (File.Exists(parts[i]))
                {
                    found = parts[i];
                    break;
                }
            delete parts;
            return found;
        }

        void Open()
        {
            if (library == null && FreeType.FT_Init_FreeType(&library) != 0) return;
            string path = Bold
                ? FindFile("/usr/share/fonts/truetype/inter/Inter-SemiBold.ttf;/usr/share/fonts/truetype/noto/NotoSans-SemiBold.ttf;/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf;/usr/share/fonts/noto/NotoSans-Bold.ttf;/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf;/usr/share/fonts/TTF/DejaVuSans-Bold.ttf;/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf;/usr/share/fonts/truetype/ubuntu/Ubuntu-B.ttf")
                : FindFile("/usr/share/fonts/truetype/inter/Inter-Regular.ttf;/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf;/usr/share/fonts/noto/NotoSans-Regular.ttf;/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf;/usr/share/fonts/TTF/DejaVuSans.ttf;/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf;/usr/share/fonts/truetype/ubuntu/Ubuntu-R.ttf");
            if (path.Length == 0)
            {
                Ascent = Size * 0.8f;
                Descent = Size * 0.25f;
                return;
            }
            string p = path.ToCString();
            void* face = null;
            int err = FreeType.FT_New_Face(library, p.Ptr, 0, &face);
            String.Free(p);
            if (err != 0) return;
            FreeType.FT_Set_Pixel_Sizes(face, 0, (uint)Size);
            byte* size = *(byte**)((byte*)face + FreeType.FaceSize);
            Ascent = (float)Math.Ceiling(*(long*)(size + FreeType.SizeAscender) / 64.0);
            Descent = (float)Math.Ceiling(-(*(long*)(size + FreeType.SizeDescender) / 64.0));
            handle = face;
        }

        GlyphImage Rasterize(char c)
        {
            GlyphImage g = new GlyphImage();
            if (FreeType.FT_Load_Char(handle, c, FreeType.LoadRender | FreeType.LoadTargetLight) != 0) return g;
            byte* slot = *(byte**)((byte*)handle + FreeType.FaceGlyph);
            g.Advance = (float)(*(long*)(slot + FreeType.GlyphAdvanceX) / 64.0);
            int rows = *(int*)(slot + FreeType.BitmapRows);
            int width = *(int*)(slot + FreeType.BitmapWidth);
            int pitch = *(int*)(slot + FreeType.BitmapPitch);
            byte* buffer = *(byte**)(slot + FreeType.BitmapBuffer);
            g.Left = *(int*)(slot + FreeType.BitmapLeft);
            g.Top = *(int*)(slot + FreeType.BitmapTop);
            if (width == 0 || rows == 0) return g;
            g.Width = width;
            g.Height = rows;
            g.Coverage = (byte*)Memory.Alloc((long)width * rows);
            for (int y = 0; y < rows; y++)
                Memory.Copy(g.Coverage + (long)y * width, buffer + (long)y * pitch, width);
            return g;
        }
#endif
    }

    // ======================================================================= controles

    // Un control de la interfaz. Todos los tipos comparten esta clase y se distinguen por 'Kind'.
    public memory_unsafe class Widget
    {
        public WidgetKind Kind;
        public string Name = String.Copy("");
        public Widget Parent;
        public Window Owner;
        public List<Widget> Children = new List<Widget>();
        public Anchor Anchor = Anchor.Left | Anchor.Top;
        public WidgetStyle Style = WidgetStyle.Default;
        public TextAlign TextAlign = TextAlign.Left;
        public int FontSize = 14;
        public bool Bold;
        public bool Enabled = true;
        public bool Visible = true;
        public int CornerRadius = -1;  // -1 = según el tipo
        public void* Tag;

        // Colores 0xAARRGGBB; 0 = el del tema. Con Background2 el fondo es un degradado.
        public uint Background;
        public uint Background2;
        public bool GradientHorizontal;
        public uint Foreground;
        public uint BorderColor;
        public uint Accent;          // casilla marcada, deslizador y barra de progreso

        int x;
        int y;
        int width;
        int height;
        string text = String.Copy("");
        string placeholder = String.Copy("");
        bool isChecked;
        float value;
        float min;
        float max = 100;

        // Posición final en la ventana (después de aplicar los anclajes).
        public int ScreenX;
        public int ScreenY;
        public int ActualWidth;
        public int ActualHeight;

        // Edición de texto (TextBox): posiciones en bytes UTF-8.
        int caret;
        int selAnchor;
        float scroll;

        // Eventos: un único punto de entrada con el número de evento de cada tipo.
        delegate*<void*, Widget, int, void> eventFn;
        void* eventTarget;
        int clickEvent;
        int changedEvent;

        // Listas (ComboBox, ListBox) y grupo de los RadioButton.
        List<string> items = new List<string>();
        int selectedIndex = -1;
        int firstVisible;   // ListBox: primer elemento visible
        string group = String.Copy("");

        public static Widget Create(WidgetKind kind, string name, int x, int y, int w, int h)
        {
            auto wd = new Widget();
            wd.Kind = kind;
            String.Free(wd.Name);
            wd.Name = String.Copy(name);
            wd.x = x;
            wd.y = y;
            wd.width = w;
            wd.height = h;
            if (kind == WidgetKind.Slider) wd.value = 50;
            if (kind == WidgetKind.Label) wd.FontSize = 14;
            return wd;
        }

        ~Widget()
        {
            for (int i = 0; i < Children.Count; i++) delete Children[i];
            delete Children;
            String.Free(Name);
            String.Free(text);
            String.Free(placeholder);
            for (int i = 0; i < items.Count; i++) String.Free(items[i]);
            delete items;
            String.Free(group);
        }

        public int X { get => x; set { x = value; Invalidate(); } }
        public int Y { get => y; set { y = value; Invalidate(); } }
        public int Width { get => width; set { width = value; Invalidate(); } }
        public int Height { get => height; set { height = value; Invalidate(); } }

        // El texto se copia al asignarlo.
        public string Text
        {
            get => text;
            set
            {
                string old = text;
                text = String.Copy(value);
                String.Free(old);
                if (caret > text.Length) caret = text.Length;
                selAnchor = caret;
                Invalidate();
            }
        }

        public string Placeholder
        {
            get => placeholder;
            set
            {
                string old = placeholder;
                placeholder = String.Copy(value);
                String.Free(old);
                Invalidate();
            }
        }

        public bool Checked { get => isChecked; set { isChecked = value; Invalidate(); } }
        public float Min { get => min; set { min = value; Invalidate(); } }
        public float Max { get => max; set { max = value; Invalidate(); } }

        public float Value
        {
            get => value;
            set
            {
                float v = value;
                if (v < min) v = min;
                if (v > max) v = max;
                this.value = v;
                Invalidate();
            }
        }

        // Fracción 0..1 del valor entre Min y Max.
        public float Fraction => max > min ? (value - min) / (max - min) : 0;

        // RadioButton: al marcar uno se desmarcan los del mismo contenedor con el mismo grupo.
        public string Group
        {
            get => group;
            set
            {
                string old = group;
                group = String.Copy(value);
                String.Free(old);
            }
        }

        // ------------------------------------------------------------- listas (ComboBox, ListBox)

        public int ItemCount => items.Count;

        // Elemento i (vista) o "" si no existe.
        public string Item(int i) => i >= 0 && i < items.Count ? items[i] : "";

        // Elemento seleccionado (vista) o "".
        public string SelectedItem => Item(selectedIndex);

        public void AddItem(string s)
        {
            items.Add(String.Copy(s));
            Invalidate();
        }

        public void RemoveItemAt(int i)
        {
            if (i < 0 || i >= items.Count) return;
            String.Free(items[i]);
            items.RemoveAt(i);
            if (i == selectedIndex) selectedIndex = -1;
            else if (i < selectedIndex) selectedIndex--;
            ClampScroll();
            Invalidate();
        }

        public void ClearItems()
        {
            for (int i = 0; i < items.Count; i++) String.Free(items[i]);
            items.Clear();
            selectedIndex = -1;
            firstVisible = 0;
            Invalidate();
        }

        // Reemplaza los elementos por los de una lista separada por ';' ("Rojo;Verde;Azul").
        public void SetItems(string list)
        {
            ClearItems();
            if (list.Length == 0) return;
            auto parts = std.text.Text.Split(list, ";");
            for (int i = 0; i < parts.Count; i++) items.Add(String.Copy(parts[i].Trim()));
            delete parts;
        }

        // Índice del elemento seleccionado (-1 = ninguno). Asignarlo no lanza 'Changed'.
        public int SelectedIndex
        {
            get => selectedIndex;
            set
            {
                int v = value < -1 ? -1 : value;
                if (v >= items.Count) v = items.Count - 1;
                selectedIndex = v;
                EnsureVisible();
                Invalidate();
            }
        }

        // Selecciona por interacción del usuario (lanza 'Changed' si cambia).
        internal void Choose(int i)
        {
            if (i < 0 || i >= items.Count || i == selectedIndex) return;
            selectedIndex = i;
            EnsureVisible();
            Invalidate();
            RaiseChanged();
        }

        internal int RowHeight => (int)UiFont.Get(FontSize, Bold).LineHeight + 14;

        internal int VisibleRows
        {
            get
            {
                int h = ActualHeight > 0 ? ActualHeight : height;
                int n = (h - 8) / RowHeight;
                return n < 1 ? 1 : n;
            }
        }

        internal void ClampScroll()
        {
            int most = items.Count - VisibleRows;
            if (firstVisible > most) firstVisible = most;
            if (firstVisible < 0) firstVisible = 0;
        }

        internal void ScrollList(int rows)
        {
            firstVisible += rows;
            ClampScroll();
            Invalidate();
        }

        void EnsureVisible()
        {
            if (Kind != WidgetKind.ListBox || selectedIndex < 0) return;
            if (selectedIndex < firstVisible) firstVisible = selectedIndex;
            int rows = VisibleRows;
            if (selectedIndex >= firstVisible + rows) firstVisible = selectedIndex - rows + 1;
            ClampScroll();
        }

        // ListBox: fila bajo la coordenada y de la ventana, o -1.
        internal int RowAt(int py)
        {
            int local = py - ScreenY - 4;
            if (local < 0) return -1;
            int i = firstVisible + local / RowHeight;
            return i < items.Count ? i : -1;
        }

        public Widget Add(Widget child)
        {
            child.Parent = this;
            child.SetOwner(Owner);
            Children.Add(child);
            Invalidate();
            return child;
        }

        public void SetOwner(Window w)
        {
            Owner = w;
            for (int i = 0; i < Children.Count; i++) Children[i].SetOwner(w);
        }

        // Conecta los eventos: fn(target, control, número) se llama con 'click' o 'changed'.
        public void SetEvents(delegate*<void*, Widget, int, void> fn, void* target, int click, int changed)
        {
            eventFn = fn;
            eventTarget = target;
            clickEvent = click;
            changedEvent = changed;
        }

        public void Invalidate()
        {
            if (Owner != null) Owner.Invalidate();
        }

        public bool Focusable => Visible && Enabled && (Kind == WidgetKind.TextBox || Kind == WidgetKind.Button ||
                                                       Kind == WidgetKind.CheckBox || Kind == WidgetKind.Slider ||
                                                       Kind == WidgetKind.RadioButton || Kind == WidgetKind.ComboBox ||
                                                       Kind == WidgetKind.ListBox);

        internal void RaiseClick()
        {
            if (clickEvent != 0 && eventFn != null) eventFn(eventTarget, this, clickEvent);
        }

        internal void RaiseChanged()
        {
            if (changedEvent != 0 && eventFn != null) eventFn(eventTarget, this, changedEvent);
        }

        // ------------------------------------------------------------- disposición

        // Calcula la posición final según el tamaño real del padre y su tamaño de diseño.
        internal void Layout(int parentX, int parentY, int dw, int dh)
        {
            int ax = (int)Anchor;
            bool left = (ax & 1) != 0, top = (ax & 2) != 0, right = (ax & 4) != 0, bottom = (ax & 8) != 0;
            int nx = x, nw = width;
            if (right && left) nw = width + dw;
            else if (right) nx = x + dw;
            else if (!left) nx = x + dw / 2;
            int ny = y, nh = height;
            if (bottom && top) nh = height + dh;
            else if (bottom) ny = y + dh;
            else if (!top) ny = y + dh / 2;
            ScreenX = parentX + nx;
            ScreenY = parentY + ny;
            ActualWidth = nw < 0 ? 0 : nw;
            ActualHeight = nh < 0 ? 0 : nh;
            for (int i = 0; i < Children.Count; i++)
                Children[i].Layout(ScreenX, ScreenY, ActualWidth - width, ActualHeight - height);
        }

        public bool Contains(int px, int py) =>
            px >= ScreenX && py >= ScreenY && px < ScreenX + ActualWidth && py < ScreenY + ActualHeight;

        // Control visible más interno bajo el punto (o null).
        internal Widget HitTest(int px, int py)
        {
            if (!Visible || !Contains(px, py)) return null;
            for (int i = Children.Count - 1; i >= 0; i--)
            {
                Widget hit = Children[i].HitTest(px, py);
                if (hit != null) return hit;
            }
            return Kind == WidgetKind.Panel || Kind == WidgetKind.Label ? null : this;
        }

        // ------------------------------------------------------------- dibujo

        internal void Draw(Canvas c, Palette p, Window w)
        {
            if (!Visible) return;
            float fx = ScreenX, fy = ScreenY, fw = ActualWidth, fh = ActualHeight;
            bool hot = w.Hot == this && Enabled;
            bool pressed = w.Pressed == this && hot;
            bool focused = w.Focused == this;
            UiFont font = UiFont.Get(FontSize, Bold || (Kind == WidgetKind.Button && Style == WidgetStyle.Primary));
            uint textColor = Foreground != 0 ? Foreground : (Enabled ? p.Text : p.TextMuted);
            uint accent = Accent != 0 ? Accent : p.Primary;
            switch (Kind)
            {
                case WidgetKind.Panel:
                {
                    float r = CornerRadius >= 0 ? CornerRadius : 10;
                    if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, 0);
                    else if (Style != WidgetStyle.Subtle) c.FillRoundRect(fx, fy, fw, fh, r, p.Surface);
                    if (BorderColor != 0 || (Style != WidgetStyle.Subtle && Background == 0))
                        c.StrokeRoundRect(fx, fy, fw, fh, r, 1, BorderColor != 0 ? BorderColor : p.Border);
                    break;
                }
                case WidgetKind.Label:
                {
                    if (Background != 0) FillBackground(c, fx, fy, fw, fh, CornerRadius >= 0 ? CornerRadius : 0, 0);
                    if (BorderColor != 0) c.StrokeRoundRect(fx, fy, fw, fh, CornerRadius >= 0 ? CornerRadius : 0, 1, BorderColor);
                    uint color = Foreground != 0 ? Foreground : Style == WidgetStyle.Subtle ? p.TextMuted : (Style == WidgetStyle.Danger ? p.Danger : textColor);
                    DrawLabelText(c, font, text, fx, fy, fw, fh, color);
                    break;
                }
                case WidgetKind.Button:
                {
                    float r = CornerRadius >= 0 ? CornerRadius : 8;
                    uint bg = p.Surface, fg = textColor, border = p.Border;
                    if (Style == WidgetStyle.Primary)
                    {
                        bg = hot ? p.PrimaryHover : p.Primary;
                        fg = p.PrimaryText;
                        border = 0;
                    }
                    else if (Style == WidgetStyle.Danger)
                    {
                        bg = p.Danger;
                        fg = Rgb.Of(0xffffff);
                        border = 0;
                    }
                    else if (Style == WidgetStyle.Subtle)
                    {
                        bg = hot ? p.SurfaceHover : 0;
                        border = 0;
                    }
                    else if (hot)
                    {
                        bg = p.SurfaceHover;
                        border = p.BorderStrong;
                    }
                    if (pressed) bg = Style == WidgetStyle.Default || Style == WidgetStyle.Subtle ? p.SurfacePressed : Darken(bg);
                    if (!Enabled && Style != WidgetStyle.Default) bg = Rgb.Alpha(bg, 0.45f);
                    if (Foreground != 0) fg = Foreground;
                    if (Background != 0 && Style == WidgetStyle.Default) border = 0;
                    if (BorderColor != 0) border = BorderColor;
                    if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, pressed ? -1 : (hot ? 1 : 0));
                    else if (bg != 0) c.FillRoundRect(fx, fy, fw, fh, r, bg);
                    if (border != 0) c.StrokeRoundRect(fx, fy, fw, fh, r, 1, border);
                    if (focused && w.FocusVisible) c.StrokeRoundRect(fx - 3, fy - 3, fw + 6, fh + 6, r + 3, 2, p.Focus);
                    float tw = font.Measure(text);
                    float baseline = fy + (fh - font.LineHeight) / 2 + font.Ascent;
                    c.Text(font, text, fx + (fw - tw) / 2, baseline + (pressed ? 1 : 0), fg);
                    break;
                }
                case WidgetKind.TextBox:
                    DrawTextBox(c, p, w, font, fx, fy, fw, fh, focused, hot);
                    break;
                case WidgetKind.CheckBox:
                {
                    float box = 18;
                    float by = fy + (fh - box) / 2;
                    if (isChecked)
                    {
                        c.FillRoundRect(fx, by, box, box, 5, Enabled ? accent : p.TextMuted);
                        c.Line(fx + 4.5f, by + 9.5f, fx + 7.8f, by + 12.8f, 2, p.PrimaryText);
                        c.Line(fx + 7.8f, by + 12.8f, fx + 13.5f, by + 5.8f, 2, p.PrimaryText);
                    }
                    else
                    {
                        c.FillRoundRect(fx, by, box, box, 5, p.Input);
                        c.StrokeRoundRect(fx, by, box, box, 5, 1.2f, hot ? p.TextMuted : p.BorderStrong);
                    }
                    if (focused && w.FocusVisible) c.StrokeRoundRect(fx - 3, by - 3, box + 6, box + 6, 7, 2, p.Focus);
                    DrawLabelText(c, font, text, fx + box + 10, fy, fw - box - 10, fh, textColor);
                    break;
                }
                case WidgetKind.Slider:
                {
                    float cy = fy + fh / 2;
                    float thumb = 8;
                    float left = fx + thumb, right = fx + fw - thumb;
                    float pos = left + (right - left) * Fraction;
                    c.FillRoundRect(fx, cy - 2, fw, 4, 2, Background != 0 ? Background : p.Track);
                    c.FillRoundRect(fx, cy - 2, pos - fx, 4, 2, Enabled ? accent : p.TextMuted);
                    if (focused && w.FocusVisible) c.FillCircle(pos, cy, thumb + 4, p.Focus);
                    c.FillCircle(pos, cy, thumb + (hot || pressed ? 1 : 0), Enabled ? accent : p.TextMuted);
                    c.FillCircle(pos, cy, 3, p.Background);
                    break;
                }
                case WidgetKind.RadioButton:
                {
                    float box = 18;
                    float cx = fx + box / 2, cy = fy + fh / 2;
                    if (isChecked)
                    {
                        c.FillCircle(cx, cy, box / 2, Enabled ? accent : p.TextMuted);
                        c.FillCircle(cx, cy, 3.5f, p.PrimaryText);
                    }
                    else
                    {
                        c.FillCircle(cx, cy, box / 2, hot ? p.TextMuted : p.BorderStrong);
                        c.FillCircle(cx, cy, box / 2 - 1.2f, p.Input);
                    }
                    if (focused && w.FocusVisible) c.StrokeRoundRect(fx - 3, cy - box / 2 - 3, box + 6, box + 6, box / 2 + 3, 2, p.Focus);
                    DrawLabelText(c, font, text, fx + box + 10, fy, fw - box - 10, fh, textColor);
                    break;
                }
                case WidgetKind.ComboBox:
                {
                    float r = CornerRadius >= 0 ? CornerRadius : 8;
                    bool open = w.DropDown == this;
                    if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, hot || open ? 1 : 0);
                    else c.FillRoundRect(fx, fy, fw, fh, r, hot || open ? p.SurfaceHover : p.Surface);
                    c.StrokeRoundRect(fx, fy, fw, fh, r, open ? 1.5f : 1, open ? p.Focus : (BorderColor != 0 ? BorderColor : (hot ? p.BorderStrong : p.Border)));
                    if (focused && w.FocusVisible && !open) c.StrokeRoundRect(fx - 3, fy - 3, fw + 6, fh + 6, r + 3, 2, p.Focus);
                    float baseline = fy + (fh - font.LineHeight) / 2 + font.Ascent;
                    c.Clip(ScreenX + 1, ScreenY + 1, ActualWidth - 34, ActualHeight - 2);
                    if (selectedIndex >= 0) c.Text(font, items[selectedIndex], fx + 12, baseline, textColor);
                    else c.Text(font, placeholder, fx + 12, baseline, p.TextMuted);
                    c.ResetClip();
                    float ax = fx + fw - 18, ay = fy + fh / 2;
                    c.Line(ax - 4.5f, ay - 2, ax, ay + 2.5f, 1.6f, p.TextMuted);
                    c.Line(ax, ay + 2.5f, ax + 4.5f, ay - 2, 1.6f, p.TextMuted);
                    break;
                }
                case WidgetKind.ListBox:
                    DrawListBox(c, p, w, font, fx, fy, fw, fh, focused, textColor);
                    break;
                case WidgetKind.ProgressBar:
                {
                    float r = CornerRadius >= 0 ? CornerRadius : fh / 2;
                    c.FillRoundRect(fx, fy, fw, fh, r, Background != 0 ? Background : p.Track);
                    float filled = fw * Fraction;
                    if (filled > 0) c.FillRoundRect(fx, fy, filled < fh ? fh : filled, fh, r, accent);
                    break;
                }
            }
            for (int i = 0; i < Children.Count; i++) Children[i].Draw(c, p, w);
        }

        // Fondo propio (sólido o degradado); shade: 1 más claro (encima), -1 más oscuro (pulsado).
        void FillBackground(Canvas c, float x, float y, float w, float h, float r, int shade)
        {
            uint a = Background, b = Background2 != 0 ? Background2 : Background;
            if (shade > 0)
            {
                a = Rgb.Mix(a, 0xffffffff, 0.08f) & 0xffffff | (a & 0xff000000);
                b = Rgb.Mix(b, 0xffffffff, 0.08f) & 0xffffff | (b & 0xff000000);
            }
            else if (shade < 0)
            {
                a = Darken(a);
                b = Darken(b);
            }
            if (a == b) c.FillRoundRect(x, y, w, h, r, a);
            else c.FillRoundRectGradient(x, y, w, h, r, a, b, GradientHorizontal);
        }

        static uint Darken(uint c)
        {
            uint r = ((c >> 16) & 0xff) * 85 / 100, g = ((c >> 8) & 0xff) * 85 / 100, b = (c & 0xff) * 85 / 100;
            return (c & 0xff000000) | (r << 16) | (g << 8) | b;
        }

        void DrawLabelText(Canvas c, UiFont font, string s, float fx, float fy, float fw, float fh, uint color)
        {
            // Varias líneas separadas por '\n', centradas verticalmente en el control.
            int lines = 1;
            for (int i = 0; i < s.Length; i++)
                if (s[i] == '\n') lines++;
            float lh = (float)Math.Ceiling(font.LineHeight * 1.25);
            float top = fy + (fh - (lh * (lines - 1) + font.LineHeight)) / 2;
            int start = 0;
            for (int line = 0; line < lines; line++)
            {
                int end = start;
                while (end < s.Length && s[end] != '\n') end++;
                string part = s.Substring(start, end - start);
                float tw = font.Measure(part);
                float tx = TextAlign == TextAlign.Center ? fx + (fw - tw) / 2 : (TextAlign == TextAlign.Right ? fx + fw - tw : fx);
                c.Text(font, part, tx, top + line * lh + font.Ascent, color);
                start = end + 1;
            }
        }

        void DrawListBox(Canvas c, Palette p, Window w, UiFont font, float fx, float fy, float fw, float fh, bool focused, uint textColor)
        {
            float r = CornerRadius >= 0 ? CornerRadius : 8;
            if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, 0);
            else c.FillRoundRect(fx, fy, fw, fh, r, p.Input);
            c.StrokeRoundRect(fx, fy, fw, fh, r, focused ? 1.5f : 1, focused ? p.Focus : (BorderColor != 0 ? BorderColor : p.Border));
            ClampScroll();
            int rh = RowHeight, rows = VisibleRows;
            bool bar = items.Count > rows;
            float inner = fw - 8 - (bar ? 8 : 0);
            int hotRow = w.Hot == this ? RowAt(w.MouseY) : -1;
            c.Clip(ScreenX + 1, ScreenY + 1, ActualWidth - 2, ActualHeight - 2);
            for (int i = firstVisible; i < items.Count && i <= firstVisible + rows; i++)
            {
                float ry = fy + 4 + (i - firstVisible) * rh;
                if (i == selectedIndex) c.FillRoundRect(fx + 4, ry, inner, rh, 6, focused ? p.Selection : p.SurfacePressed);
                else if (i == hotRow) c.FillRoundRect(fx + 4, ry, inner, rh, 6, p.SurfaceHover);
                c.Text(font, items[i], fx + 14, ry + (rh - font.LineHeight) / 2 + font.Ascent, textColor);
            }
            if (bar)
            {
                float track = fh - 8;
                float th = track * rows / items.Count;
                if (th < 24) th = 24;
                float ty = fy + 4 + (track - th) * firstVisible / (items.Count - rows);
                c.FillRoundRect(fx + fw - 9, ty, 4, th, 2, p.BorderStrong);
            }
            c.ResetClip();
        }

        void DrawTextBox(Canvas c, Palette p, Window w, UiFont font, float fx, float fy, float fw, float fh, bool focused, bool hot)
        {
            float r = CornerRadius >= 0 ? CornerRadius : 8;
            if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, 0);
            else c.FillRoundRect(fx, fy, fw, fh, r, p.Input);
            c.StrokeRoundRect(fx, fy, fw, fh, r, focused ? 1.5f : 1, focused ? p.Focus : (BorderColor != 0 ? BorderColor : (hot ? p.BorderStrong : p.Border)));
            float pad = 10;
            float inner = fw - pad * 2;
            float caretX = font.MeasureBytes(text, caret);
            if (caretX - scroll > inner) scroll = caretX - inner;
            if (caretX - scroll < 0) scroll = caretX;
            if (scroll > 0 && font.Measure(text) - scroll < inner) scroll = (float)Math.Max(0.0, (double)(font.Measure(text) - inner));
            float baseline = fy + (fh - font.LineHeight) / 2 + font.Ascent;
            c.Clip(ScreenX + 1, ScreenY + 1, ActualWidth - 2, ActualHeight - 2);
            if (text.Length == 0 && !focused || text.Length == 0 && placeholder.Length > 0)
                c.Text(font, placeholder, fx + pad, baseline, p.TextMuted);
            if (focused && selAnchor != caret)
            {
                int a = selAnchor < caret ? selAnchor : caret, b = selAnchor < caret ? caret : selAnchor;
                float sx = fx + pad - scroll + font.MeasureBytes(text, a);
                float ex = fx + pad - scroll + font.MeasureBytes(text, b);
                c.FillRoundRect(sx, baseline - font.Ascent - 2, ex - sx, font.LineHeight + 4, 3, p.Selection);
            }
            c.Text(font, text, fx + pad - scroll, baseline, Foreground != 0 ? Foreground : (Enabled ? p.Text : p.TextMuted));
            if (focused && w.CaretOn)
                c.FillRect((int)(fx + pad - scroll + caretX), (int)(baseline - font.Ascent - 1), 2 - 1 + 1, (int)(font.LineHeight + 2), p.Text);
            c.ResetClip();
        }

        // ------------------------------------------------------------- texto (TextBox)

        bool HasSelection => selAnchor != caret;

        void DeleteSelection()
        {
            if (!HasSelection) return;
            int a = selAnchor < caret ? selAnchor : caret, b = selAnchor < caret ? caret : selAnchor;
            Replace(a, b, "");
        }

        void Replace(int a, int b, string with)
        {
            string head = text.Substring(0, a);
            string tail = text.Substring(b, text.Length - b);
            string joined = String.Concat(head, with, tail);
            String.Free(text);
            text = joined;
            caret = a + with.Length;
            selAnchor = caret;
        }

        int PrevChar(int i)
        {
            if (i <= 0) return 0;
            i--;
            while (i > 0 && (text[i] & 0xC0) == 0x80) i--;
            return i;
        }

        int NextCharPos(int i)
        {
            if (i >= text.Length) return text.Length;
            i++;
            while (i < text.Length && (text[i] & 0xC0) == 0x80) i++;
            return i;
        }

        int CaretFromX(int px)
        {
            UiFont font = UiFont.Get(FontSize, Bold);
            float local = px - (ScreenX + 10) + scroll;
            int i = 0;
            float xx = 0;
            while (i < text.Length)
            {
                int start = i;
                float adv = font.Get(UiFont.NextChar(text, ref i)).Advance;
                if (local < xx + adv / 2) return start;
                xx += adv;
            }
            return text.Length;
        }

        internal void TextMouseDown(int px, bool shift)
        {
            caret = CaretFromX(px);
            if (!shift) selAnchor = caret;
        }

        internal void TextMouseDrag(int px) { caret = CaretFromX(px); }

        internal void SelectAll()
        {
            selAnchor = 0;
            caret = text.Length;
        }

        internal string SelectedText()
        {
            int a = selAnchor < caret ? selAnchor : caret, b = selAnchor < caret ? caret : selAnchor;
            return String.Copy(text.Substring(a, b - a));
        }

        internal void InsertText(string s)
        {
            DeleteSelection();
            Replace(caret, caret, s);
            RaiseChanged();
        }

        // Devuelve true si la tecla se usó.
        internal bool TextKey(UiEvent e)
        {
            int before = caret;
            switch (e.Key)
            {
                case KeyCode.Left:
                    if (HasSelection && !e.Shift) caret = selAnchor < caret ? selAnchor : caret;
                    else caret = PrevChar(caret);
                    break;
                case KeyCode.Right:
                    if (HasSelection && !e.Shift) caret = selAnchor > caret ? selAnchor : caret;
                    else caret = NextCharPos(caret);
                    break;
                case KeyCode.Home:
                    caret = 0;
                    break;
                case KeyCode.End:
                    caret = text.Length;
                    break;
                case KeyCode.Backspace:
                    if (!HasSelection) selAnchor = PrevChar(caret);
                    if (HasSelection)
                    {
                        DeleteSelection();
                        RaiseChanged();
                    }
                    return true;
                case KeyCode.Delete:
                    if (!HasSelection) selAnchor = NextCharPos(caret);
                    if (HasSelection)
                    {
                        DeleteSelection();
                        RaiseChanged();
                    }
                    return true;
                default:
                    return false;
            }
            if (!e.Shift) selAnchor = caret;
            return true;
        }
    }

    // ======================================================================= ventana

    public enum KeyCode { None, Backspace, Delete, Left, Right, Up, Down, Home, End, Enter, Tab, Escape, Space, A, C, V, X, Other }
    public enum UiEventKind { None, KeyDown, Char, MouseDown, MouseUp, MouseMove, MouseLeave, Scroll, Resize, Close, Expose, FocusLost }

    public struct UiEvent
    {
        public UiEventKind Kind;
        public int X;
        public int Y;
        public int Button;    // 1 izquierdo, 2 central, 3 derecho
        public KeyCode Key;
        public char Char;
        public bool Ctrl;
        public bool Shift;
        public int Width;
        public int Height;
        public int Delta;     // rueda: positivo hacia abajo
    }

    public class Window
    {
        public List<Widget> Children = new List<Widget>();
        public UiTheme Theme = UiTheme.Dark;
        public bool Resizable = true;
        public int MinWidth = 200;
        public int MinHeight = 120;
        public uint Background;          // 0 = el del tema
        public uint Background2;         // con valor: degradado de Background a Background2
        public bool GradientHorizontal;

        string title;
        int designWidth;
        int designHeight;
        int width;
        int height;
        bool dirty = true;
        bool open;
        Palette palette;
        Canvas canvas = new Canvas();
        NativeWindow native;
        long caretTime;

        // Estado de la interacción (lo usan los controles al dibujarse).
        public Widget Hot;
        public Widget Pressed;
        public Widget Focused;
        public bool FocusVisible;
        public bool CaretOn = true;
        public int MouseX = -1;
        public int MouseY = -1;

        // ComboBox con la lista abierta (se dibuja encima de todo).
        public Widget DropDown;
        int dropHot = -1;
        int dropScroll;
        const int DropMaxRows = 8;

        public Window(string title, int width, int height)
        {
            this.title = String.Copy(title);
            designWidth = width;
            designHeight = height;
            this.width = width;
            this.height = height;
        }

        ~Window()
        {
            for (int i = 0; i < Children.Count; i++) delete Children[i];
            delete Children;
            delete canvas;
            delete palette;
            if (native != null) delete native;
            String.Free(title);
        }

        public string Title
        {
            get => title;
            set
            {
                string old = title;
                title = String.Copy(value);
                String.Free(old);
                if (native != null) native.SetTitle(title);
            }
        }

        public int Width => width;
        public int Height => height;
        public bool IsOpen => open;

        public Widget Add(Widget w)
        {
            w.Parent = null;
            w.SetOwner(this);
            Children.Add(w);
            dirty = true;
            return w;
        }

        // Busca un control por su nombre (también dentro de paneles).
        public Widget Find(string name)
        {
            for (int i = 0; i < Children.Count; i++)
            {
                Widget r = FindIn(Children[i], name);
                if (r != null) return r;
            }
            return null;
        }

        static Widget FindIn(Widget w, string name)
        {
            if (w.Name == name) return w;
            for (int i = 0; i < w.Children.Count; i++)
            {
                Widget r = FindIn(w.Children[i], name);
                if (r != null) return r;
            }
            return null;
        }

        public void Invalidate() { dirty = true; }

        public void Close() { open = false; }

        public void Focus(Widget w)
        {
            if (Focused == w) return;
            Focused = w;
            CaretOn = true;
            caretTime = Environment.TickCount64();
            dirty = true;
        }

        // ------------------------------------------------------------- dibujo

        public void Render()
        {
            if (palette == null) palette = Palette.For(Theme);
            float scale = native != null ? native.Scale : 1;
            canvas.Scale = scale;
            UiFont.Scale = scale;
            canvas.Resize((int)Math.Ceiling(width * scale), (int)Math.Ceiling(height * scale));
            canvas.ResetClip();
            canvas.Clear(Background != 0 ? Background : palette.Background);
            if (Background != 0 && Background2 != 0)
                canvas.FillRoundRectGradient(0, 0, width, height, 0, Background, Background2, GradientHorizontal);
            for (int i = 0; i < Children.Count; i++)
            {
                Children[i].Layout(0, 0, width - designWidth, height - designHeight);
                Children[i].Draw(canvas, palette, this);
            }
            if (DropDown != null) DrawDropDown();
            dirty = false;
        }

        // ------------------------------------------------------------- lista desplegable

        void OpenDropDown(Widget combo)
        {
            DropDown = combo;
            dropHot = combo.SelectedIndex;
            dropScroll = 0;
            if (combo.SelectedIndex >= DropMaxRows) dropScroll = combo.SelectedIndex - DropMaxRows + 1;
            dirty = true;
        }

        void CloseDropDown()
        {
            DropDown = null;
            dropHot = -1;
            dirty = true;
        }

        int DropRows => DropDown.ItemCount < DropMaxRows ? DropDown.ItemCount : DropMaxRows;

        // Rectángulo de la lista: debajo del ComboBox, o encima si no cabe.
        void DropRect(out int x, out int y, out int w, out int h)
        {
            Widget d = DropDown;
            int rows = DropRows < 1 ? 1 : DropRows;
            h = rows * d.RowHeight + 8;
            w = d.ActualWidth;
            x = d.ScreenX;
            y = d.ScreenY + d.ActualHeight + 4;
            if (y + h > height && d.ScreenY - h - 4 >= 0) y = d.ScreenY - h - 4;
        }

        bool InDropDown(int px, int py)
        {
            int x = 0, y = 0, w = 0, h = 0;
            DropRect(out x, out y, out w, out h);
            return px >= x && py >= y && px < x + w && py < y + h;
        }

        int DropIndexAt(int px, int py)
        {
            if (!InDropDown(px, py)) return -1;
            int x = 0, y = 0, w = 0, h = 0;
            DropRect(out x, out y, out w, out h);
            int local = py - y - 4;
            if (local < 0) return -1;
            int i = dropScroll + local / DropDown.RowHeight;
            return i < DropDown.ItemCount ? i : -1;
        }

        void ScrollDropDown(int rows)
        {
            int most = DropDown.ItemCount - DropRows;
            dropScroll += rows;
            if (dropScroll > most) dropScroll = most;
            if (dropScroll < 0) dropScroll = 0;
            dirty = true;
        }

        void DrawDropDown()
        {
            Widget d = DropDown;
            int x = 0, y = 0, w = 0, h = 0;
            DropRect(out x, out y, out w, out h);
            UiFont font = UiFont.Get(d.FontSize, d.Bold);
            int rh = d.RowHeight;
            canvas.FillRoundRect(x - 2, y, w + 4, h + 6, 11, Rgb.Alpha(0x000000, 0.18f));
            canvas.FillRoundRect(x, y, w, h, 8, palette.Surface);
            canvas.StrokeRoundRect(x, y, w, h, 8, 1, palette.BorderStrong);
            canvas.Clip(x + 1, y + 1, w - 2, h - 2);
            for (int i = dropScroll; i < d.ItemCount && i < dropScroll + DropMaxRows; i++)
            {
                float ry = y + 4 + (i - dropScroll) * rh;
                if (i == dropHot) canvas.FillRoundRect(x + 4, ry, w - 8, rh, 6, palette.SurfaceHover);
                canvas.Text(font, d.Item(i), x + 14, ry + (rh - font.LineHeight) / 2 + font.Ascent, palette.Text);
                if (i == d.SelectedIndex)
                {
                    float cx = x + w - 22, cy = ry + rh / 2.0f;
                    canvas.Line(cx - 4, cy, cx - 1, cy + 3, 1.6f, palette.Text);
                    canvas.Line(cx - 1, cy + 3, cx + 5, cy - 3.5f, 1.6f, palette.Text);
                }
            }
            if (d.ItemCount > DropMaxRows)
            {
                float track = h - 8;
                float th = track * DropMaxRows / d.ItemCount;
                float ty = y + 4 + (track - th) * dropScroll / (d.ItemCount - DropMaxRows);
                canvas.FillRoundRect(x + w - 9, ty, 4, th, 2, palette.BorderStrong);
            }
            canvas.ResetClip();
        }

        public Canvas Canvas => canvas;

        // ------------------------------------------------------------- eventos

        Widget HitTest(int x, int y)
        {
            for (int i = Children.Count - 1; i >= 0; i--)
            {
                Widget w = Children[i].HitTest(x, y);
                if (w != null) return w;
            }
            return null;
        }

        void CollectFocusable(Widget w, List<Widget> found)
        {
            if (!w.Visible) return;
            if (w.Focusable) found.Add(w);
            for (int i = 0; i < w.Children.Count; i++) CollectFocusable(w.Children[i], found);
        }

        void MoveFocus(bool back)
        {
            auto list = new List<Widget>();
            for (int i = 0; i < Children.Count; i++) CollectFocusable(Children[i], list);
            if (list.Count > 0)
            {
                int idx = list.IndexOf(Focused);
                if (idx < 0) idx = back ? 0 : list.Count - 1;
                idx = back ? (idx + list.Count - 1) % list.Count : (idx + 1) % list.Count;
                Focus(list[idx]);
                if (list[idx].Kind == WidgetKind.TextBox) list[idx].SelectAll();
                FocusVisible = true;
            }
            delete list;
        }

        void SetSlider(Widget w, int mx)
        {
            float left = w.ScreenX + 8, right = w.ScreenX + w.ActualWidth - 8;
            float t = right > left ? (mx - left) / (right - left) : 0;
            if (t < 0) t = 0;
            if (t > 1) t = 1;
            float old = w.Value;
            w.Value = w.Min + (w.Max - w.Min) * t;
            if (w.Value != old) w.RaiseChanged();
        }

        void Activate(Widget w)
        {
            if (w.Kind == WidgetKind.CheckBox)
            {
                w.Checked = !w.Checked;
                w.RaiseChanged();
            }
            else if (w.Kind == WidgetKind.RadioButton && !w.Checked)
            {
                List<Widget> siblings = w.Parent != null ? w.Parent.Children : Children;
                for (int i = 0; i < siblings.Count; i++)
                {
                    Widget s = siblings[i];
                    if (s != w && s.Kind == WidgetKind.RadioButton && s.Checked && s.Group == w.Group)
                    {
                        s.Checked = false;
                        s.RaiseChanged();
                    }
                }
                w.Checked = true;
                w.RaiseChanged();
            }
            w.RaiseClick();
        }

        public void HandleEvent(UiEvent e)
        {
            switch (e.Kind)
            {
                case UiEventKind.Resize:
                    width = e.Width;
                    height = e.Height;
                    dirty = true;
                    break;
                case UiEventKind.Expose:
                    dirty = true;
                    break;
                case UiEventKind.Close:
                    open = false;
                    break;
                case UiEventKind.MouseMove:
                {
                    MouseX = e.X;
                    MouseY = e.Y;
                    if (DropDown != null)
                    {
                        int over = DropIndexAt(e.X, e.Y);
                        if (over >= 0 && over != dropHot)
                        {
                            dropHot = over;
                            dirty = true;
                        }
                    }
                    if (Pressed != null)
                    {
                        if (Pressed.Kind == WidgetKind.Slider) SetSlider(Pressed, e.X);
                        else if (Pressed.Kind == WidgetKind.TextBox)
                        {
                            Pressed.TextMouseDrag(e.X);
                            dirty = true;
                        }
                    }
                    Widget hit = HitTest(e.X, e.Y);
                    if (hit != null && !hit.Enabled) hit = null;
                    if (hit != Hot || (hit != null && hit.Kind == WidgetKind.ListBox))
                    {
                        Hot = hit;
                        dirty = true;
                    }
                    if (native != null)
                        native.SetCursor(DropDown != null && InDropDown(e.X, e.Y) ? CursorShape.Hand
                                         : hit == null || hit.Kind == WidgetKind.ListBox ? CursorShape.Arrow
                                         : (hit.Kind == WidgetKind.TextBox ? CursorShape.Text : CursorShape.Hand));
                    break;
                }
                case UiEventKind.MouseLeave:
                    if (Hot != null)
                    {
                        Hot = null;
                        dirty = true;
                    }
                    break;
                case UiEventKind.MouseDown:
                {
                    if (e.Button != 1) break;
                    MouseX = e.X;
                    MouseY = e.Y;
                    Widget hit = HitTest(e.X, e.Y);
                    if (hit != null && !hit.Enabled) hit = null;
                    if (DropDown != null)
                    {
                        // Con la lista abierta, el clic elige un elemento o la cierra.
                        Widget combo = DropDown;
                        bool inside = InDropDown(e.X, e.Y);
                        int idx = DropIndexAt(e.X, e.Y);
                        CloseDropDown();
                        if (inside)
                        {
                            if (idx >= 0) combo.Choose(idx);
                            break;
                        }
                        if (hit == combo) break;
                    }
                    Pressed = hit;
                    FocusVisible = false;
                    if (hit == null || hit.Focusable) Focus(hit);
                    if (hit != null && hit.Kind == WidgetKind.TextBox) hit.TextMouseDown(e.X, e.Shift);
                    if (hit != null && hit.Kind == WidgetKind.Slider) SetSlider(hit, e.X);
                    if (hit != null && hit.Kind == WidgetKind.ComboBox) OpenDropDown(hit);
                    if (hit != null && hit.Kind == WidgetKind.ListBox) hit.Choose(hit.RowAt(e.Y));
                    dirty = true;
                    break;
                }
                case UiEventKind.MouseUp:
                {
                    if (e.Button != 1) break;
                    Widget p = Pressed;
                    Pressed = null;
                    dirty = true;
                    if (p != null && p.Contains(e.X, e.Y) &&
                        (p.Kind == WidgetKind.Button || p.Kind == WidgetKind.CheckBox || p.Kind == WidgetKind.RadioButton)) Activate(p);
                    break;
                }
                case UiEventKind.Scroll:
                {
                    if (DropDown != null)
                    {
                        if (InDropDown(MouseX, MouseY)) ScrollDropDown(e.Delta);
                        else CloseDropDown();
                        break;
                    }
                    Widget over = HitTest(MouseX, MouseY);
                    if (over != null && over.Kind == WidgetKind.ListBox)
                    {
                        over.ScrollList(e.Delta);
                        dirty = true;
                    }
                    break;
                }
                case UiEventKind.KeyDown:
                    HandleKey(e);
                    break;
                case UiEventKind.Char:
                    if (Focused != null && Focused.Kind == WidgetKind.TextBox && !e.Ctrl && e.Char >= 0x20 && e.Char != 0x7f)
                    {
                        string s = Utf8.Encode(e.Char);
                        Focused.InsertText(s);
                        String.Free(s);
                        CaretOn = true;
                        caretTime = Environment.TickCount64();
                        dirty = true;
                    }
                    break;
                case UiEventKind.FocusLost:
                    Pressed = null;
                    if (DropDown != null) CloseDropDown();
                    dirty = true;
                    break;
            }
        }

        void HandleKey(UiEvent e)
        {
            Widget f = Focused;
            if (DropDown != null)
            {
                Widget d = DropDown;
                dirty = true;
                if (e.Key == KeyCode.Down || e.Key == KeyCode.Up)
                {
                    int next = dropHot + (e.Key == KeyCode.Down ? 1 : -1);
                    if (next >= 0 && next < d.ItemCount) dropHot = next;
                    if (dropHot < dropScroll) dropScroll = dropHot;
                    if (dropHot >= dropScroll + DropMaxRows) dropScroll = dropHot - DropMaxRows + 1;
                    return;
                }
                if (e.Key == KeyCode.Enter || e.Key == KeyCode.Space)
                {
                    int chosen = dropHot;
                    CloseDropDown();
                    d.Choose(chosen);
                    return;
                }
                CloseDropDown();
                if (e.Key == KeyCode.Escape) return;
            }
            if (e.Key == KeyCode.Tab)
            {
                MoveFocus(e.Shift);
                return;
            }
            if (f == null) return;
            dirty = true;
            CaretOn = true;
            caretTime = Environment.TickCount64();
            if (f.Kind == WidgetKind.TextBox)
            {
                if (e.Ctrl && e.Key == KeyCode.A) f.SelectAll();
                else if (e.Ctrl && (e.Key == KeyCode.C || e.Key == KeyCode.X))
                {
                    string s = f.SelectedText();
                    if (s.Length > 0 && native != null) native.SetClipboard(s);
                    String.Free(s);
                    if (e.Key == KeyCode.X) f.InsertText("");
                }
                else if (e.Ctrl && e.Key == KeyCode.V && native != null)
                {
                    string s = native.GetClipboard();
                    f.InsertText(s);
                    String.Free(s);
                }
                else if (e.Key == KeyCode.Enter) f.RaiseClick();
                else f.TextKey(e);
                return;
            }
            if ((e.Key == KeyCode.Enter || e.Key == KeyCode.Space) &&
                (f.Kind == WidgetKind.Button || f.Kind == WidgetKind.CheckBox || f.Kind == WidgetKind.RadioButton))
            {
                FocusVisible = true;
                Activate(f);
            }
            else if (f.Kind == WidgetKind.ComboBox && (e.Key == KeyCode.Enter || e.Key == KeyCode.Space))
            {
                FocusVisible = true;
                OpenDropDown(f);
            }
            else if ((f.Kind == WidgetKind.ComboBox || f.Kind == WidgetKind.ListBox) && (e.Key == KeyCode.Up || e.Key == KeyCode.Down))
            {
                FocusVisible = true;
                int next = f.SelectedIndex + (e.Key == KeyCode.Down ? 1 : -1);
                f.Choose(next < 0 ? 0 : next);
            }
            else if (f.Kind == WidgetKind.ListBox && (e.Key == KeyCode.Home || e.Key == KeyCode.End))
            {
                FocusVisible = true;
                f.Choose(e.Key == KeyCode.Home ? 0 : f.ItemCount - 1);
            }
            else if (f.Kind == WidgetKind.Slider && (e.Key == KeyCode.Left || e.Key == KeyCode.Right || e.Key == KeyCode.Down || e.Key == KeyCode.Up))
            {
                float step = (f.Max - f.Min) / 20;
                float old = f.Value;
                f.Value = f.Value + (e.Key == KeyCode.Left || e.Key == KeyCode.Down ? -step : step);
                if (f.Value != old) f.RaiseChanged();
                FocusVisible = true;
            }
        }

        // ------------------------------------------------------------- pruebas

        // Simula entrada sin pantalla (FASET_UI_SCRIPT): "click X Y | move X Y | scroll N | type texto | key tab | resize W H".
        void RunScript(string script)
        {
            auto cmds = Text.Split(script, "|");
            for (int i = 0; i < cmds.Count; i++)
            {
                string cmd = cmds[i].Trim();
                auto parts = Text.Split(cmd, " ");
                if (parts.Count == 0 || cmd.Length == 0)
                {
                    delete parts;
                    continue;
                }
                string op = parts[0];
                UiEvent e = new UiEvent();
                if (op == "click" && parts.Count >= 3)
                {
                    e.X = Convert.ToInt32(parts[1]);
                    e.Y = Convert.ToInt32(parts[2]);
                    e.Button = 1;
                    e.Kind = UiEventKind.MouseMove;
                    HandleEvent(e);
                    e.Kind = UiEventKind.MouseDown;
                    HandleEvent(e);
                    e.Kind = UiEventKind.MouseUp;
                    HandleEvent(e);
                }
                else if (op == "type")
                {
                    string t = cmd.Substring(5, cmd.Length - 5);
                    int k = 0;
                    while (k < t.Length)
                    {
                        e.Kind = UiEventKind.Char;
                        e.Char = UiFont.NextChar(t, ref k);
                        HandleEvent(e);
                    }
                }
                else if (op == "key" && parts.Count >= 2)
                {
                    string k = parts[1];
                    e.Kind = UiEventKind.KeyDown;
                    e.Key = k == "tab" ? KeyCode.Tab : k == "enter" ? KeyCode.Enter : k == "backspace" ? KeyCode.Backspace
                          : k == "left" ? KeyCode.Left : k == "right" ? KeyCode.Right : k == "home" ? KeyCode.Home
                          : k == "end" ? KeyCode.End : k == "space" ? KeyCode.Space : k == "delete" ? KeyCode.Delete
                          : k == "up" ? KeyCode.Up : k == "down" ? KeyCode.Down : k == "escape" ? KeyCode.Escape : KeyCode.Other;
                    HandleEvent(e);
                }
                else if (op == "move" && parts.Count >= 3)
                {
                    e.Kind = UiEventKind.MouseMove;
                    e.X = Convert.ToInt32(parts[1]);
                    e.Y = Convert.ToInt32(parts[2]);
                    HandleEvent(e);
                }
                else if (op == "scroll" && parts.Count >= 2)
                {
                    e.Kind = UiEventKind.Scroll;
                    e.Delta = Convert.ToInt32(parts[1]);
                    HandleEvent(e);
                }
                else if (op == "resize" && parts.Count >= 3)
                {
                    e.Kind = UiEventKind.Resize;
                    e.Width = Convert.ToInt32(parts[1]);
                    e.Height = Convert.ToInt32(parts[2]);
                    HandleEvent(e);
                }
                delete parts;
                Render();
            }
            delete cmds;
        }

        // ------------------------------------------------------------- bucle

        // Muestra la ventana y procesa eventos hasta que se cierra. Devuelve 0 si todo fue bien.
        public int Run()
        {
            // FASET_UI_SCREENSHOT=archivo.bmp: dibuja una vez, guarda la imagen y termina (sin pantalla).
            string shot = Environment.GetVariable("FASET_UI_SCREENSHOT");
            if (shot.Length > 0)
            {
                Render();
                string script = Environment.GetVariable("FASET_UI_SCRIPT");
                RunScript(script);
                String.Free(script);
                Render();
                bool saved = canvas.SaveBmp(shot);
                String.Free(shot);
                return saved ? 0 : 1;
            }
            String.Free(shot);

            native = new NativeWindow();
            if (!native.Create(title, width, height, Resizable, MinWidth, MinHeight, Background != 0 ? Background : Palette.For(Theme).Background))
            {
                Console.ErrorLine("std.ui: no se pudo abrir la ventana (¿hay un entorno gráfico?)");
                return 1;
            }
            open = true;
            caretTime = Environment.TickCount64();
            while (open)
            {
                UiEvent e;
                while (open && native.Poll(out e)) HandleEvent(e);
                if (!open) break;
                bool editing = Focused != null && Focused.Kind == WidgetKind.TextBox;
                native.SetTextInput(editing);  // teclado en pantalla (Android)
                if (editing)
                {
                    long now = Environment.TickCount64();
                    if (now - caretTime >= 530)
                    {
                        CaretOn = !CaretOn;
                        caretTime = now;
                        dirty = true;
                    }
                }
                if (dirty)
                {
                    Render();
                    native.Present(canvas);
                }
                native.Wait(editing ? 530 - (int)(Environment.TickCount64() - caretTime) : 1000);
            }
            native.Destroy();
            return 0;
        }
    }

    public static class Application
    {
        // Ejecuta la ventana principal hasta que se cierra.
        public static int Run(Window window) => window.Run();
    }

    // UTF-8
    public memory_unsafe static class Utf8
    {
        public static string Encode(char c)
        {
            uint cp = (uint)c;
            byte* b = (byte*)Memory.AllocZeroed(4);
            int n = 1;
            if (cp < 0x80) b[0] = (byte)cp;
            else if (cp < 0x800)
            {
                b[0] = (byte)(0xC0 | (cp >> 6));
                b[1] = (byte)(0x80 | (cp & 0x3F));
                n = 2;
            }
            else if (cp < 0x10000)
            {
                b[0] = (byte)(0xE0 | (cp >> 12));
                b[1] = (byte)(0x80 | ((cp >> 6) & 0x3F));
                b[2] = (byte)(0x80 | (cp & 0x3F));
                n = 3;
            }
            else
            {
                b[0] = (byte)(0xF0 | (cp >> 18));
                b[1] = (byte)(0x80 | ((cp >> 12) & 0x3F));
                b[2] = (byte)(0x80 | ((cp >> 6) & 0x3F));
                b[3] = (byte)(0x80 | (cp & 0x3F));
                n = 4;
            }
            string s = String.Copy(String.FromBytes(b, n));
            Memory.Free(b);
            return s;
        }
    }

#if WINDOWS
    // ======================================================================= Win32

    memory_unsafe static class Win32
    {
        public static extern void* GetModuleHandleW(ushort* name);
        public static extern ushort RegisterClassExW(byte* wc);
        public static extern void* CreateWindowExW(uint exStyle, ushort* cls, ushort* title, uint style, int x, int y, int w, int h,
                                                   void* parent, void* menu, void* instance, void* param);
        public static extern long DefWindowProcW(void* hwnd, uint msg, ulong wp, long lp);
        public static extern int ShowWindow(void* hwnd, int cmd);
        public static extern int UpdateWindow(void* hwnd);
        public static extern int DestroyWindow(void* hwnd);
        public static extern int PeekMessageW(byte* msg, void* hwnd, uint min, uint max, uint remove);
        public static extern int TranslateMessage(byte* msg);
        public static extern long DispatchMessageW(byte* msg);
        public static extern uint MsgWaitForMultipleObjects(uint count, void* handles, int waitAll, uint ms, uint mask);
        public static extern void* LoadCursorW(void* instance, void* name);
        public static extern void* SetCursor(void* cursor);
        public static extern int SetWindowTextW(void* hwnd, ushort* text);
        public static extern int AdjustWindowRectEx(int* rect, uint style, int menu, uint exStyle);
        public static extern int InvalidateRect(void* hwnd, void* rect, int erase);
        public static extern void* BeginPaint(void* hwnd, byte* ps);
        public static extern int EndPaint(void* hwnd, byte* ps);
        public static extern void* GetDC(void* hwnd);
        public static extern int ReleaseDC(void* hwnd, void* dc);
        public static extern int SetDIBitsToDevice(void* dc, int x, int y, uint w, uint h, int sx, int sy, uint start, uint lines,
                                                   void* bits, byte* info, uint usage);
        public static extern void* SetCapture(void* hwnd);
        public static extern int ReleaseCapture();
        public static extern int TrackMouseEvent(byte* tme);
        public static extern short GetKeyState(int key);
        public static extern void* CreateCompatibleDC(void* dc);
        public static extern void* CreateFontW(int h, int w, int esc, int orient, int weight, uint italic, uint underline, uint strike,
                                               uint charset, uint outPrec, uint clipPrec, uint quality, uint pitch, ushort* face);
        public static extern void* SelectObject(void* dc, void* obj);
        public static extern int GetTextMetricsW(void* dc, byte* tm);
        public static extern uint GetGlyphOutlineW(void* dc, uint ch, uint format, byte* gm, uint size, void* buffer, byte* mat);
        public static extern int MultiByteToWideChar(uint cp, uint flags, byte* src, int n, ushort* dst, int cap);
        public static extern int WideCharToMultiByte(uint cp, uint flags, ushort* src, int n, byte* dst, int cap, void* d, void* u);
        public static extern int OpenClipboard(void* hwnd);
        public static extern int CloseClipboard();
        public static extern int EmptyClipboard();
        public static extern void* GetClipboardData(uint format);
        public static extern void* SetClipboardData(uint format, void* mem);
        public static extern void* GlobalAlloc(uint flags, ulong bytes);
        public static extern void* GlobalLock(void* mem);
        public static extern int GlobalUnlock(void* mem);

        // Copia UTF-16 terminada en cero (libérala con Memory.Free).
        public static ushort* Wide(string s)
        {
            int n = MultiByteToWideChar(65001, 0, s.Ptr, s.Length, null, 0);
            ushort* w = (ushort*)Memory.AllocZeroed((long)(n + 1) * 2);
            MultiByteToWideChar(65001, 0, s.Ptr, s.Length, w, n);
            return w;
        }
    }

    memory_unsafe class NativeWindow
    {
        static NativeWindow current;

        public float Scale = 1;  // densidad (unidades lógicas -> píxeles)
        void* hwnd;
        byte* msg;
        byte* bmi;
        List<UiEvent> queue = new List<UiEvent>();
        void* cursorArrow;
        void* cursorText;
        void* cursorHand;
        CursorShape cursor = CursorShape.Arrow;
        bool tracking;
        int minW;
        int minH;
        uint style;

        ~NativeWindow()
        {
            delete queue;
            Memory.Free(msg);
            Memory.Free(bmi);
        }

        public bool Create(string title, int w, int h, bool resizable, int minWidth, int minHeight, uint background)
        {
            current = this;
            minW = minWidth;
            minH = minHeight;
            void* instance = Win32.GetModuleHandleW(null);
            ushort* cls = Win32.Wide("FasetUiWindow");
            byte* wc = (byte*)Memory.AllocZeroed(80);   // WNDCLASSEXW
            *(uint*)wc = 80;
            *(uint*)(wc + 4) = 3;  // CS_HREDRAW | CS_VREDRAW
            *(delegate*<void*, uint, ulong, long, long>*)(wc + 8) = &WndProc;
            *(void**)(wc + 24) = instance;
            cursorArrow = Win32.LoadCursorW(null, (void*)32512);
            cursorText = Win32.LoadCursorW(null, (void*)32513);
            cursorHand = Win32.LoadCursorW(null, (void*)32649);
            *(void**)(wc + 40) = cursorArrow;
            *(ushort**)(wc + 64) = cls;
            Win32.RegisterClassExW(wc);
            Memory.Free(wc);
            style = resizable ? (uint)0x00CF0000 : (uint)0x00CA0000;  // WS_OVERLAPPEDWINDOW o sin borde redimensionable ni maximizar
            int* rect = (int*)Memory.AllocZeroed(16);
            rect[2] = w;
            rect[3] = h;
            Win32.AdjustWindowRectEx(rect, style, 0, 0);
            ushort* t = Win32.Wide(title);
            hwnd = Win32.CreateWindowExW(0, cls, t, style, (int)0x80000000, (int)0x80000000, rect[2] - rect[0], rect[3] - rect[1],
                                         null, null, instance, null);
            Memory.Free(t);
            Memory.Free(cls);
            Memory.Free(rect);
            if (hwnd == null) return false;
            msg = (byte*)Memory.AllocZeroed(48);
            bmi = (byte*)Memory.AllocZeroed(44);
            Win32.ShowWindow(hwnd, 5);
            Win32.UpdateWindow(hwnd);
            return true;
        }

        public void Destroy()
        {
            if (hwnd != null) Win32.DestroyWindow(hwnd);
            hwnd = null;
        }

        public void SetTitle(string title)
        {
            ushort* t = Win32.Wide(title);
            Win32.SetWindowTextW(hwnd, t);
            Memory.Free(t);
        }

        public void SetTextInput(bool on) { }  // solo Android muestra un teclado en pantalla

        public void SetCursor(CursorShape shape)
        {
            cursor = shape;
            Win32.SetCursor(CursorHandle());
        }

        void* CursorHandle() => cursor == CursorShape.Text ? cursorText : (cursor == CursorShape.Hand ? cursorHand : cursorArrow);

        public void Present(Canvas c)
        {
            void* dc = Win32.GetDC(hwnd);
            Blit(dc, c);
            Win32.ReleaseDC(hwnd, dc);
        }

        Canvas last;

        void Blit(void* dc, Canvas c)
        {
            last = c;
            *(uint*)bmi = 40;
            *(int*)(bmi + 4) = c.Width;
            *(int*)(bmi + 8) = -c.Height;
            *(ushort*)(bmi + 12) = 1;
            *(ushort*)(bmi + 14) = 32;
            Win32.SetDIBitsToDevice(dc, 0, 0, (uint)c.Width, (uint)c.Height, 0, 0, 0, (uint)c.Height, c.Pixels, bmi, 0);
        }

        public void Wait(int ms)
        {
            if (queue.Count > 0) return;
            if (ms < 0) ms = 0;
            Win32.MsgWaitForMultipleObjects(0, null, 0, (uint)ms, 0x04FF);
        }

        public bool Poll(out UiEvent e)
        {
            while (queue.Count == 0 && Win32.PeekMessageW(msg, null, 0, 0, 1) != 0)
            {
                Win32.TranslateMessage(msg);
                Win32.DispatchMessageW(msg);
            }
            if (queue.Count == 0)
            {
                e = new UiEvent();
                return false;
            }
            e = queue[0];
            queue.RemoveAt(0);
            return true;
        }

        void Push(UiEvent e) { queue.Add(e); }

        static int LoX(long lp) => (int)(short)(lp & 0xffff);
        static int HiY(long lp) => (int)(short)((lp >> 16) & 0xffff);

        static KeyCode MapKey(ulong vk)
        {
            switch ((int)vk)
            {
                case 0x08: return KeyCode.Backspace;
                case 0x09: return KeyCode.Tab;
                case 0x0D: return KeyCode.Enter;
                case 0x1B: return KeyCode.Escape;
                case 0x20: return KeyCode.Space;
                case 0x23: return KeyCode.End;
                case 0x24: return KeyCode.Home;
                case 0x25: return KeyCode.Left;
                case 0x26: return KeyCode.Up;
                case 0x27: return KeyCode.Right;
                case 0x28: return KeyCode.Down;
                case 0x2E: return KeyCode.Delete;
                case 0x41: return KeyCode.A;
                case 0x43: return KeyCode.C;
                case 0x56: return KeyCode.V;
                case 0x58: return KeyCode.X;
                default: return KeyCode.Other;
            }
        }

        static long WndProc(void* hwnd, uint m, ulong wp, long lp)
        {
            NativeWindow w = current;
            if (w == null || w.hwnd != hwnd && w.hwnd != null) return Win32.DefWindowProcW(hwnd, m, wp, lp);
            UiEvent e = new UiEvent();
            switch (m)
            {
                case 0x0010:  // WM_CLOSE
                    e.Kind = UiEventKind.Close;
                    w.Push(e);
                    return 0;
                case 0x0005:  // WM_SIZE
                    e.Kind = UiEventKind.Resize;
                    e.Width = LoX(lp) & 0xffff;
                    e.Height = HiY(lp) & 0xffff;
                    if (e.Width > 0 && e.Height > 0) w.Push(e);
                    return 0;
                case 0x0024:  // WM_GETMINMAXINFO
                {
                    int* rect = (int*)Memory.AllocZeroed(16);
                    rect[2] = w.minW;
                    rect[3] = w.minH;
                    Win32.AdjustWindowRectEx(rect, w.style, 0, 0);
                    byte* info = (byte*)lp;
                    *(int*)(info + 24) = rect[2] - rect[0];
                    *(int*)(info + 28) = rect[3] - rect[1];
                    Memory.Free(rect);
                    return 0;
                }
                case 0x0014:  // WM_ERASEBKGND
                    return 1;
                case 0x000F:  // WM_PAINT
                {
                    byte* ps = (byte*)Memory.AllocZeroed(72);
                    void* dc = Win32.BeginPaint(hwnd, ps);
                    if (w.last != null) w.Blit(dc, w.last);
                    Win32.EndPaint(hwnd, ps);
                    Memory.Free(ps);
                    e.Kind = UiEventKind.Expose;
                    w.Push(e);
                    return 0;
                }
                case 0x0020:  // WM_SETCURSOR
                    if ((lp & 0xffff) == 1)
                    {
                        Win32.SetCursor(w.CursorHandle());
                        return 1;
                    }
                    break;
                case 0x0200:  // WM_MOUSEMOVE
                    if (!w.tracking)
                    {
                        byte* tme = (byte*)Memory.AllocZeroed(24);
                        *(uint*)tme = 24;
                        *(uint*)(tme + 4) = 2;  // TME_LEAVE
                        *(void**)(tme + 8) = hwnd;
                        Win32.TrackMouseEvent(tme);
                        Memory.Free(tme);
                        w.tracking = true;
                    }
                    e.Kind = UiEventKind.MouseMove;
                    e.X = LoX(lp);
                    e.Y = HiY(lp);
                    w.Push(e);
                    return 0;
                case 0x02A3:  // WM_MOUSELEAVE
                    w.tracking = false;
                    e.Kind = UiEventKind.MouseLeave;
                    w.Push(e);
                    return 0;
                case 0x0201:  // WM_LBUTTONDOWN
                case 0x0202:  // WM_LBUTTONUP
                    e.Kind = m == 0x0201 ? UiEventKind.MouseDown : UiEventKind.MouseUp;
                    e.Button = 1;
                    e.X = LoX(lp);
                    e.Y = HiY(lp);
                    e.Shift = (wp & 4) != 0;
                    e.Ctrl = (wp & 8) != 0;
                    if (m == 0x0201) Win32.SetCapture(hwnd);
                    else Win32.ReleaseCapture();
                    w.Push(e);
                    return 0;
                case 0x020A:  // WM_MOUSEWHEEL
                    e.Kind = UiEventKind.Scroll;
                    e.Delta = -(int)(short)((wp >> 16) & 0xffff) / 40;
                    w.Push(e);
                    return 0;
                case 0x0100:  // WM_KEYDOWN
                    e.Kind = UiEventKind.KeyDown;
                    e.Key = MapKey(wp);
                    e.Shift = Win32.GetKeyState(0x10) < 0;
                    e.Ctrl = Win32.GetKeyState(0x11) < 0;
                    w.Push(e);
                    return 0;
                case 0x0102:  // WM_CHAR
                    if (wp >= 0x20 && wp != 0x7f && (wp < 0xD800 || wp > 0xDFFF))
                    {
                        e.Kind = UiEventKind.Char;
                        e.Char = (char)wp;
                        e.Ctrl = Win32.GetKeyState(0x11) < 0 && Win32.GetKeyState(0x12) >= 0;
                        w.Push(e);
                    }
                    return 0;
                case 0x0008:  // WM_KILLFOCUS
                    e.Kind = UiEventKind.FocusLost;
                    w.Push(e);
                    break;
            }
            return Win32.DefWindowProcW(hwnd, m, wp, lp);
        }

        public void SetClipboard(string s)
        {
            if (Win32.OpenClipboard(hwnd) == 0) return;
            Win32.EmptyClipboard();
            int n = Win32.MultiByteToWideChar(65001, 0, s.Ptr, s.Length, null, 0);
            void* mem = Win32.GlobalAlloc(2, (ulong)(n + 1) * 2);  // GMEM_MOVEABLE
            ushort* dst = (ushort*)Win32.GlobalLock(mem);
            Win32.MultiByteToWideChar(65001, 0, s.Ptr, s.Length, dst, n);
            dst[n] = 0;
            Win32.GlobalUnlock(mem);
            Win32.SetClipboardData(13, mem);  // CF_UNICODETEXT
            Win32.CloseClipboard();
        }

        public string GetClipboard()
        {
            string r = String.Copy("");
            if (Win32.OpenClipboard(hwnd) == 0) return r;
            void* mem = Win32.GetClipboardData(13);
            if (mem != null)
            {
                ushort* src = (ushort*)Win32.GlobalLock(mem);
                int n = Win32.WideCharToMultiByte(65001, 0, src, -1, null, 0, null, null);
                if (n > 1)
                {
                    byte* buf = (byte*)Memory.AllocZeroed(n);
                    Win32.WideCharToMultiByte(65001, 0, src, -1, buf, n, null, null);
                    String.Free(r);
                    r = String.Copy(String.FromBytes(buf, n - 1));
                    Memory.Free(buf);
                }
                Win32.GlobalUnlock(mem);
            }
            Win32.CloseClipboard();
            return r;
        }
    }
#elif ANDROID
    // ======================================================================= Android (NativeActivity)

    // Capa nativa en lib/android/faset_android.c (se compila dentro del APK).
    static class AndroidNative
    {
        public static extern int faset_android_wait_window();
        public static extern float faset_android_density();
        public static extern int faset_android_next(int* ev);
        public static extern void faset_android_wait(int ms);
        public static extern void faset_android_present(uint* pixels, int w, int h);
        public static extern void faset_android_text_input(int on);
        public static extern int faset_android_clipboard_set(byte* text, int len);
        public static extern int faset_android_clipboard_get(byte** text);
        public static extern void* faset_ttf_open(byte* path, float px, int fakeBold, float* ascent, float* descent);
        public static extern int faset_ttf_glyph(void* font, uint cp, byte** coverage, int* w, int* h, int* left, int* top, float* advance);
    }

    // La "ventana" es la actividad a pantalla completa: los toques llegan como ratón
    // (botón 1) y el tamaño lógico es el de la pantalla dividido por la densidad.
    memory_unsafe class NativeWindow
    {
        public float Scale = 1;
        int* ev;
        bool textInput;
        string clipboard = String.Copy("");

        ~NativeWindow()
        {
            Memory.Free(ev);
            String.Free(clipboard);
        }

        public bool Create(string title, int w, int h, bool resizable, int minW, int minH, uint background)
        {
            if (AndroidNative.faset_android_wait_window() == 0) return false;
            Scale = AndroidNative.faset_android_density();
            if (Scale <= 0) Scale = 1;
            ev = (int*)Memory.AllocZeroed(32);
            return true;
        }

        public void Destroy() { SetTextInput(false); }

        public void SetTitle(string title) { }

        public void SetCursor(CursorShape shape) { }

        public void SetTextInput(bool on)
        {
            if (on == textInput) return;
            textInput = on;
            AndroidNative.faset_android_text_input(on ? 1 : 0);
        }

        public void Present(Canvas c) { AndroidNative.faset_android_present(c.Pixels, c.Width, c.Height); }

        public void Wait(int ms)
        {
            if (ms < 0) ms = 0;
            AndroidNative.faset_android_wait(ms);
        }

        int Logical(int px) => (int)(px / Scale);

        // Códigos AKEYCODE_* de android/keycodes.h.
        static KeyCode MapKey(int code)
        {
            switch (code)
            {
                case 67: return KeyCode.Backspace;   // DEL
                case 112: return KeyCode.Delete;     // FORWARD_DEL
                case 21: return KeyCode.Left;
                case 22: return KeyCode.Right;
                case 19: return KeyCode.Up;
                case 20: return KeyCode.Down;
                case 122: return KeyCode.Home;       // MOVE_HOME
                case 123: return KeyCode.End;        // MOVE_END
                case 66: return KeyCode.Enter;
                case 160: return KeyCode.Enter;      // NUMPAD_ENTER
                case 61: return KeyCode.Tab;
                case 111: return KeyCode.Escape;
                case 62: return KeyCode.Space;
                case 29: return KeyCode.A;
                case 31: return KeyCode.C;
                case 50: return KeyCode.V;
                case 52: return KeyCode.X;
                default: return KeyCode.Other;
            }
        }

        public bool Poll(out UiEvent e)
        {
            e = new UiEvent();
            while (AndroidNative.faset_android_next(ev) != 0)
            {
                int kind = ev[0];
                e.X = Logical(ev[1]);
                e.Y = Logical(ev[2]);
                int meta = ev[5];
                e.Shift = (meta & 1) != 0;          // AMETA_SHIFT_ON
                e.Ctrl = (meta & 0x1000) != 0;      // AMETA_CTRL_ON
                switch (kind)
                {
                    case 1:
                        e.Kind = UiEventKind.Resize;
                        e.Width = Logical(ev[6]);
                        e.Height = Logical(ev[7]);
                        return true;
                    case 2: e.Kind = UiEventKind.Expose; return true;
                    case 3: e.Kind = UiEventKind.Close; return true;
                    case 4: e.Kind = UiEventKind.MouseMove; return true;
                    case 5: e.Kind = UiEventKind.MouseDown; e.Button = 1; return true;
                    case 6: e.Kind = UiEventKind.MouseUp; e.Button = 1; return true;
                    case 7: e.Kind = UiEventKind.MouseLeave; return true;
                    case 8: e.Kind = UiEventKind.KeyDown; e.Key = MapKey(ev[3]); return true;
                    case 9: e.Kind = UiEventKind.Char; e.Char = (char)ev[4]; return true;
                    case 10: e.Kind = UiEventKind.FocusLost; return true;
                }
            }
            return false;
        }

        public void SetClipboard(string text)
        {
            String.Free(clipboard);
            clipboard = String.Copy(text);
            AndroidNative.faset_android_clipboard_set(text.Ptr, text.Length);
        }

        public string GetClipboard()
        {
            byte* data = null;
            int n = AndroidNative.faset_android_clipboard_get(&data);
            if (n < 0) return String.Copy(clipboard);
            string r = String.Copy(String.FromBytes(data, n));
            Memory.Free(data);
            return r;
        }
    }
#else
    // ======================================================================= X11 + FreeType

    memory_unsafe static class FreeType
    {
        public static extern int FT_Init_FreeType(void** library);
        public static extern int FT_New_Face(void* library, byte* path, long faceIndex, void** face);
        public static extern int FT_Set_Pixel_Sizes(void* face, uint width, uint height);
        public static extern int FT_Load_Char(void* face, ulong charcode, int flags);

        // Desplazamientos en FT_FaceRec / FT_SizeRec / FT_GlyphSlotRec (64 bits).
        public const int FaceGlyph = 152;
        public const int FaceSize = 160;
        public const int SizeAscender = 48;
        public const int SizeDescender = 56;
        public const int GlyphAdvanceX = 128;
        public const int BitmapRows = 152;
        public const int BitmapWidth = 156;
        public const int BitmapPitch = 160;
        public const int BitmapBuffer = 168;
        public const int BitmapLeft = 192;
        public const int BitmapTop = 196;
        public const int LoadRender = 4;
        public const int LoadTargetLight = 65536;
    }

    memory_unsafe static class X11
    {
        public static extern void* XOpenDisplay(byte* name);
        public static extern int XCloseDisplay(void* dpy);
        public static extern int XDefaultScreen(void* dpy);
        public static extern ulong XRootWindow(void* dpy, int screen);
        public static extern void* XDefaultVisual(void* dpy, int screen);
        public static extern int XDefaultDepth(void* dpy, int screen);
        public static extern void* XDefaultGC(void* dpy, int screen);
        public static extern ulong XCreateSimpleWindow(void* dpy, ulong parent, int x, int y, uint w, uint h, uint border, ulong borderColor, ulong background);
        public static extern int XSelectInput(void* dpy, ulong w, long mask);
        public static extern int XMapWindow(void* dpy, ulong w);
        public static extern int XStoreName(void* dpy, ulong w, byte* name);
        public static extern ulong XInternAtom(void* dpy, byte* name, int onlyIfExists);
        public static extern int XSetWMProtocols(void* dpy, ulong w, ulong* atoms, int count);
        public static extern int XSetWMNormalHints(void* dpy, ulong w, byte* hints);
        public static extern int XPending(void* dpy);
        public static extern int XNextEvent(void* dpy, void* ev);
        public static extern int XConnectionNumber(void* dpy);
        public static extern int XLookupString(void* keyEvent, byte* buf, int len, ulong* keysym, void* status);
        public static extern int XFlush(void* dpy);
        public static extern int XDestroyWindow(void* dpy, ulong w);
        public static extern ulong XCreateFontCursor(void* dpy, uint shape);
        public static extern int XDefineCursor(void* dpy, ulong w, ulong cursor);
        public static extern void* XCreateImage(void* dpy, void* visual, uint depth, int format, int offset, void* data,
                                                uint w, uint h, int pad, int bytesPerLine);
        public static extern int XPutImage(void* dpy, ulong d, void* gc, void* image, int sx, int sy, int dx, int dy, uint w, uint h);
        public static extern int XFree(void* data);
        public static extern int XChangeProperty(void* dpy, ulong w, ulong property, ulong type, int format, int mode, byte* data, int count);
        public static extern int XSetSelectionOwner(void* dpy, ulong selection, ulong owner, ulong time);
        public static extern ulong XGetSelectionOwner(void* dpy, ulong selection);
        public static extern int XConvertSelection(void* dpy, ulong selection, ulong target, ulong property, ulong requestor, ulong time);
        public static extern int XGetWindowProperty(void* dpy, ulong w, ulong property, long offset, long length, int del, ulong reqType,
                                                    ulong* actualType, int* actualFormat, ulong* nitems, ulong* bytesAfter, byte** data);
        public static extern int XSendEvent(void* dpy, ulong w, int propagate, long mask, void* ev);
    }

    memory_unsafe class NativeWindow
    {
        public float Scale = 1;  // densidad (unidades lógicas -> píxeles)
        void* display;
        ulong window;
        int screen;
        ulong wmDelete;
        ulong atomClipboard;
        ulong atomUtf8;
        ulong atomTargets;
        ulong atomPaste;
        byte* ev;
        ulong* cursors;
        CursorShape cursor = CursorShape.Text;
        int width;
        int height;
        string clipboard = String.Copy("");

        ~NativeWindow()
        {
            Memory.Free(ev);
            Memory.Free(cursors);
            String.Free(clipboard);
        }

        public bool Create(string title, int w, int h, bool resizable, int minW, int minH, uint background)
        {
            display = X11.XOpenDisplay(null);
            if (display == null) return false;
            screen = X11.XDefaultScreen(display);
            window = X11.XCreateSimpleWindow(display, X11.XRootWindow(display, screen), 0, 0, (uint)w, (uint)h, 0, 0, background & 0xffffff);
            // Teclado, botones, movimiento, salida del puntero, exposición, tamaño y foco.
            X11.XSelectInput(display, window, 1 | 4 | 8 | 32 | 64 | 32768 | 131072 | 2097152);
            byte* hints = (byte*)Memory.AllocZeroed(80);  // XSizeHints
            *(long*)hints = resizable ? 16 : 16 | 32;     // PMinSize | PMaxSize
            *(int*)(hints + 24) = resizable ? minW : w;
            *(int*)(hints + 28) = resizable ? minH : h;
            *(int*)(hints + 32) = w;
            *(int*)(hints + 36) = h;
            X11.XSetWMNormalHints(display, window, hints);
            Memory.Free(hints);
            wmDelete = X11.XInternAtom(display, "WM_DELETE_WINDOW".Ptr, 0);
            X11.XSetWMProtocols(display, window, &wmDelete, 1);
            atomClipboard = X11.XInternAtom(display, "CLIPBOARD".Ptr, 0);
            atomUtf8 = X11.XInternAtom(display, "UTF8_STRING".Ptr, 0);
            atomTargets = X11.XInternAtom(display, "TARGETS".Ptr, 0);
            atomPaste = X11.XInternAtom(display, "FASET_PASTE".Ptr, 0);
            SetTitle(title);
            cursors = (ulong*)Memory.AllocZeroed(24);
            cursors[0] = X11.XCreateFontCursor(display, 68);   // left_ptr
            cursors[1] = X11.XCreateFontCursor(display, 152);  // xterm
            cursors[2] = X11.XCreateFontCursor(display, 60);   // hand2
            SetCursor(CursorShape.Arrow);
            X11.XMapWindow(display, window);
            X11.XFlush(display);
            ev = (byte*)Memory.AllocZeroed(192);
            width = w;
            height = h;
            return true;
        }

        public void Destroy()
        {
            if (display == null) return;
            X11.XDestroyWindow(display, window);
            X11.XCloseDisplay(display);
            display = null;
        }

        public void SetTitle(string title)
        {
            // WM_NAME / WM_ICON_NAME (39 / 37) también en UTF-8: XStoreName los marca como Latin-1
            // y algunas barras de tareas mostraban los acentos rotos.
            ulong netName = X11.XInternAtom(display, "_NET_WM_NAME".Ptr, 0);
            ulong netIcon = X11.XInternAtom(display, "_NET_WM_ICON_NAME".Ptr, 0);
            X11.XChangeProperty(display, window, netName, atomUtf8, 8, 0, title.Ptr, title.Length);
            X11.XChangeProperty(display, window, netIcon, atomUtf8, 8, 0, title.Ptr, title.Length);
            X11.XChangeProperty(display, window, 39, atomUtf8, 8, 0, title.Ptr, title.Length);
            X11.XChangeProperty(display, window, 37, atomUtf8, 8, 0, title.Ptr, title.Length);
            X11.XFlush(display);
        }

        public void SetTextInput(bool on) { }  // solo Android muestra un teclado en pantalla

        public void SetCursor(CursorShape shape)
        {
            if (shape == cursor) return;
            cursor = shape;
            X11.XDefineCursor(display, window, cursors[(int)shape]);
            X11.XFlush(display);
        }

        public void Present(Canvas c)
        {
            void* img = X11.XCreateImage(display, X11.XDefaultVisual(display, screen), (uint)X11.XDefaultDepth(display, screen), 2, 0,
                                         c.Pixels, (uint)c.Width, (uint)c.Height, 32, c.Width * 4);
            if (img == null) return;
            X11.XPutImage(display, window, X11.XDefaultGC(display, screen), img, 0, 0, 0, 0, (uint)c.Width, (uint)c.Height);
            X11.XFree(img);  // solo la estructura: los píxeles son del lienzo
            X11.XFlush(display);
        }

        public void Wait(int ms)
        {
            if (X11.XPending(display) > 0) return;
            if (ms < 0) ms = 0;
            EventWait.WaitFd(X11.XConnectionNumber(display), ms);
        }

        static int I32(byte* p, int off) => *(int*)(p + off);
        static uint U32(byte* p, int off) => *(uint*)(p + off);
        static ulong U64(byte* p, int off) => *(ulong*)(p + off);

        static KeyCode MapKey(ulong sym)
        {
            switch (sym)
            {
                case 0xff08: return KeyCode.Backspace;
                case 0xff09: return KeyCode.Tab;
                case 0xfe20: return KeyCode.Tab;
                case 0xff0d: return KeyCode.Enter;
                case 0xff8d: return KeyCode.Enter;
                case 0xff1b: return KeyCode.Escape;
                case 0xffff: return KeyCode.Delete;
                case 0xff50: return KeyCode.Home;
                case 0xff51: return KeyCode.Left;
                case 0xff52: return KeyCode.Up;
                case 0xff53: return KeyCode.Right;
                case 0xff54: return KeyCode.Down;
                case 0xff57: return KeyCode.End;
                case 0x20: return KeyCode.Space;
                case 'a': return KeyCode.A;
                case 'A': return KeyCode.A;
                case 'c': return KeyCode.C;
                case 'C': return KeyCode.C;
                case 'v': return KeyCode.V;
                case 'V': return KeyCode.V;
                case 'x': return KeyCode.X;
                case 'X': return KeyCode.X;
                default: return KeyCode.Other;
            }
        }

        // Un evento de tecla puede producir dos eventos de la interfaz (tecla y carácter).
        char pendingChar;
        bool pendingCtrl;

        public bool Poll(out UiEvent e)
        {
            e = new UiEvent();
            if (pendingChar != 0)
            {
                e.Kind = UiEventKind.Char;
                e.Char = pendingChar;
                e.Ctrl = pendingCtrl;
                pendingChar = (char)0;
                return true;
            }
            while (X11.XPending(display) > 0)
            {
                X11.XNextEvent(display, ev);
                int type = I32(ev, 0);
                if (type == 2)  // KeyPress
                {
                    uint state = U32(ev, 80);
                    ulong keysym = 0;
                    byte* buf = (byte*)Memory.AllocZeroed(16);
                    int n = X11.XLookupString(ev, buf, 15, &keysym, null);
                    e.Kind = UiEventKind.KeyDown;
                    e.Key = MapKey(keysym);
                    e.Shift = (state & 1) != 0;
                    e.Ctrl = (state & 4) != 0;
                    char ch = (char)0;
                    if (n == 1 && buf[0] >= 0x20 && buf[0] != 0x7f) ch = (char)buf[0];   // Latin-1 = Unicode
                    else if (keysym >= 0x1000100 && keysym < 0x1110000) ch = (char)(keysym - 0x1000000);
                    Memory.Free(buf);
                    if (ch != 0)
                    {
                        pendingChar = ch;
                        pendingCtrl = e.Ctrl;
                    }
                    return true;
                }
                if (type == 4 || type == 5)  // ButtonPress / ButtonRelease
                {
                    int button = I32(ev, 84);
                    uint state = U32(ev, 80);
                    e.X = I32(ev, 64);
                    e.Y = I32(ev, 68);
                    e.Shift = (state & 1) != 0;
                    e.Ctrl = (state & 4) != 0;
                    if (button == 4 || button == 5)
                    {
                        if (type == 5) continue;
                        e.Kind = UiEventKind.Scroll;
                        e.Delta = button == 4 ? -3 : 3;
                        return true;
                    }
                    e.Kind = type == 4 ? UiEventKind.MouseDown : UiEventKind.MouseUp;
                    e.Button = button == 3 ? 3 : (button == 2 ? 2 : 1);
                    return true;
                }
                if (type == 6)  // MotionNotify
                {
                    e.Kind = UiEventKind.MouseMove;
                    e.X = I32(ev, 64);
                    e.Y = I32(ev, 68);
                    return true;
                }
                if (type == 8)  // LeaveNotify
                {
                    e.Kind = UiEventKind.MouseLeave;
                    return true;
                }
                if (type == 22)  // ConfigureNotify
                {
                    int w = I32(ev, 56), h = I32(ev, 60);
                    if (w == width && h == height) continue;
                    width = w;
                    height = h;
                    e.Kind = UiEventKind.Resize;
                    e.Width = w;
                    e.Height = h;
                    return true;
                }
                if (type == 12)  // Expose
                {
                    e.Kind = UiEventKind.Expose;
                    return true;
                }
                if (type == 10)  // FocusOut
                {
                    e.Kind = UiEventKind.FocusLost;
                    return true;
                }
                if (type == 33 && U64(ev, 56) == wmDelete)  // ClientMessage: cerrar
                {
                    e.Kind = UiEventKind.Close;
                    return true;
                }
                if (type == 30) AnswerSelectionRequest();
            }
            return false;
        }

        // ------------------------------------------------------------- portapapeles

        public void SetClipboard(string text)
        {
            String.Free(clipboard);
            clipboard = String.Copy(text);
            X11.XSetSelectionOwner(display, atomClipboard, window, 0);
            X11.XFlush(display);
        }

        public string GetClipboard()
        {
            if (X11.XGetSelectionOwner(display, atomClipboard) == window) return String.Copy(clipboard);
            X11.XConvertSelection(display, atomClipboard, atomUtf8, atomPaste, window, 0);
            X11.XFlush(display);
            long deadline = Environment.TickCount64() + 300;
            while (Environment.TickCount64() < deadline)
            {
                if (X11.XPending(display) == 0)
                {
                    EventWait.WaitFd(X11.XConnectionNumber(display), 10);
                    continue;
                }
                X11.XNextEvent(display, ev);
                int type = I32(ev, 0);
                if (type == 30)
                {
                    AnswerSelectionRequest();
                    continue;
                }
                if (type != 31) continue;  // SelectionNotify
                if (U64(ev, 56) == 0) break;
                ulong actualType = 0, nitems = 0, after = 0;
                int format = 0;
                byte* data = null;
                X11.XGetWindowProperty(display, window, atomPaste, 0, 1 << 24, 1, 0, &actualType, &format, &nitems, &after, &data);
                string r = String.Copy(String.FromBytes(data, (long)nitems));
                if (data != null) X11.XFree(data);
                return r;
            }
            return String.Copy("");
        }

        void AnswerSelectionRequest()
        {
            ulong requestor = U64(ev, 40);
            ulong selection = U64(ev, 48);
            ulong target = U64(ev, 56);
            ulong property = U64(ev, 64);
            ulong time = U64(ev, 72);
            if (property == 0) property = target;
            ulong result = property;
            if (target == atomTargets)
            {
                ulong* atoms = (ulong*)Memory.Alloc(16);
                atoms[0] = atomUtf8;
                atoms[1] = 31;  // XA_STRING
                X11.XChangeProperty(display, requestor, property, 4, 32, 0, (byte*)atoms, 2);
                Memory.Free(atoms);
            }
            else if (target == atomUtf8 || target == 31)
            {
                X11.XChangeProperty(display, requestor, property, target, 8, 0, clipboard.Ptr, clipboard.Length);
            }
            else
            {
                result = 0;
            }
            byte* reply = (byte*)Memory.AllocZeroed(192);
            *(int*)reply = 31;  // SelectionNotify
            *(int*)(reply + 16) = 1;
            *(void**)(reply + 24) = display;
            *(ulong*)(reply + 32) = requestor;
            *(ulong*)(reply + 40) = selection;
            *(ulong*)(reply + 48) = target;
            *(ulong*)(reply + 56) = result;
            *(ulong*)(reply + 64) = time;
            X11.XSendEvent(display, requestor, 0, 0, reply);
            X11.XFlush(display);
            Memory.Free(reply);
        }
    }
#endif
}
