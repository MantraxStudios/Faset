// =============================================================================
//  std.ui — imágenes: clase Image (PNG, JPEG, BMP y GIF), dibujo escalado con
//  filtro bilineal en el lienzo, control PictureBox e icono de los botones.
//
//      auto foto = Image.FromFile("img/paisaje.jpg");   // null si no se puede leer
//      picFoto.Image = foto;  picFoto.SizeMode = PictureSizeMode.Zoom;
//      btnGuardar.Icon = Image.FromFile("iconos/guardar.png");
//
//  La decodificación la hace lib/std/ui/faset_image.c (stb_image, dominio público),
//  que el compilador enlaza en todos los programas que usan std.ui.
//
//  Rutas relativas: se buscan en la carpeta actual, junto al ejecutable y, en
//  Android, dentro del APK (el compilador empaqueta como 'assets' las imágenes que
//  nombran los .fstui con Source/Icon y los archivos de la carpeta Assets/).
// =============================================================================
using std.collections;
using std.io;

namespace std.ui
{
    // Cómo se coloca la imagen de un PictureBox en su rectángulo.
    public enum PictureSizeMode { Normal, Stretch, Zoom, Center, Cover }

    memory_unsafe static class ImageNative
    {
        public static extern uint* faset_image_decode(byte* data, long len, int* w, int* h);
        public static extern byte* faset_image_error();
        public static extern void faset_image_free(void* p);
#if ANDROID
        public static extern int faset_android_asset(byte* name, byte** data, long* len);
#endif
    }

    // Mapa de píxeles 0xAARRGGBB (alfa sin premultiplicar), fila a fila.
    // Los píxeles viven en memoria que el recolector no recorre (Memory.AllocBytes).
    public memory_unsafe class Image
    {
        public int Width;
        public int Height;
        public uint* Pixels;
        public string Path = "";                 // archivo del que se cargó ("" si se creó en memoria)
        public static string LastError = "";     // motivo del último Load/FromFile fallido

        static Dictionary<string, Image> cache = new Dictionary<string, Image>();

        // Copias para dibujar: alfa premultiplicado y reducciones a la mitad (mipmaps).
        uint* premul;
        bool dirty = true;
        Image half;

        public Image(int width, int height)
        {
            Width = width < 1 ? 1 : width;
            Height = height < 1 ? 1 : height;
            Pixels = (uint*)Memory.AllocBytes((long)Width * Height * 4);
            Memory.Set(Pixels, 0, (long)Width * Height * 4);
        }

        // Lee y decodifica un archivo (sin caché). null si no existe o no es una imagen válida.
        public static Image Load(string path)
        {
            byte* data = null;
            long len = 0;
            string real = Resolve(path);
            bool ok = real.Length > 0 && File.TryReadAllBytes(real, out data, out len);
#if ANDROID
            if (!ok) ok = ReadAsset(path, out data, out len);
#endif
            if (!ok)
            {
                LastError = "no se encontró la imagen '" + path + "'";
                return null;
            }
            Image img = FromMemory(data, len);
            if (img == null) LastError = "'" + path + "' no es una imagen válida (" + LastError + ")";
            else img.Path = path;
            return img;
        }

        // Como Load, pero reutiliza la imagen si ya se cargó ese archivo.
        public static Image FromFile(string path)
        {
            Image img;
            if (cache.TryGetValue(path, out img)) return img;
            img = Load(path);
            if (img != null) cache.Set(String.Copy(path), img);
            return img;
        }

        // Decodifica PNG, JPEG, BMP o GIF (primer fotograma) desde memoria.
        public static Image FromMemory(byte* data, long length)
        {
            int w = 0, h = 0;
            uint* px = ImageNative.faset_image_decode(data, length, &w, &h);
            if (px == null)
            {
                LastError = String.Copy(String.FromCString(ImageNative.faset_image_error()));
                return null;
            }
            Image img = new Image(w, h);
            Memory.Copy(img.Pixels, px, (long)w * h * 4);
            ImageNative.faset_image_free(px);
            return img;
        }

        // Ruta real de un archivo de imagen ("" si no está en ninguna de las carpetas de búsqueda).
        public static string Resolve(string path)
        {
            if (path.Length == 0) return "";
            if (File.Exists(path)) return path;
            if (std.io.Path.IsPathRooted(path)) return "";
            string exe = Environment.GetArg(0);
            string dir = std.io.Path.GetDirectoryName(exe);
            if (dir.Length > 0)
            {
                string near = std.io.Path.Combine(dir, path);
                if (File.Exists(near)) return near;
            }
            return "";
        }

#if ANDROID
        static bool ReadAsset(string path, out byte* data, out long len)
        {
            string name = path;
            while (name.StartsWith("./")) name = name.Substring(2);
            string c = name.ToCString();
            byte* raw = null;
            long n = 0;
            data = null;
            len = 0;
            if (ImageNative.faset_android_asset(c.Ptr, &raw, &n) == 0) return false;
            data = Memory.AllocBytes(n + 1);
            Memory.Copy(data, raw, n);
            ImageNative.faset_image_free(raw);
            len = n;
            return true;
        }
#endif

        public uint GetPixel(int x, int y) => x >= 0 && y >= 0 && x < Width && y < Height ? Pixels[(long)y * Width + x] : 0;

        public void SetPixel(int x, int y, uint argb)
        {
            if (x < 0 || y < 0 || x >= Width || y >= Height) return;
            Pixels[(long)y * Width + x] = argb;
            dirty = true;
        }

        public void Fill(uint argb)
        {
            long n = (long)Width * Height;
            for (long i = 0; i < n; i++) Pixels[i] = argb;
            dirty = true;
        }

        // Avisa de que se cambiaron los píxeles directamente (Pixels[i] = ...).
        public void Changed() { dirty = true; }

        public Image Clone()
        {
            Image c = new Image(Width, Height);
            Memory.Copy(c.Pixels, Pixels, (long)Width * Height * 4);
            c.Path = Path;
            return c;
        }

        // ------------------------------------------------------------- para el lienzo

        internal uint* Premultiplied
        {
            get
            {
                if (dirty || premul == null)
                {
                    long n = (long)Width * Height;
                    if (premul == null) premul = (uint*)Memory.AllocBytes(n * 4);
                    for (long i = 0; i < n; i++) premul[i] = Premultiply(Pixels[i]);
                    dirty = false;
                    half = null;
                }
                return premul;
            }
        }

        static uint Premultiply(uint c)
        {
            uint a = c >> 24;
            if (a == 255) return c;
            if (a == 0) return 0;
            uint r = ((c >> 16) & 255) * a / 255, g = ((c >> 8) & 255) * a / 255, b = (c & 255) * a / 255;
            return (a << 24) | (r << 16) | (g << 8) | b;
        }

        // Nivel de detalle para reducir 'factor' veces sin parpadeo (cada nivel es la mitad del anterior).
        internal Image Level(float factor, out float scale)
        {
            Image img = this;
            scale = 1;
            uint* force = Premultiplied;  // actualiza 'half' si cambiaron los píxeles
            while (factor >= 2 && img.Width > 1 && img.Height > 1)
            {
                img = img.Half();
                factor /= 2;
                scale *= 2;
            }
            return img;
        }

        // Reducción 2x2 por promedio (sobre los valores premultiplicados).
        Image Half()
        {
            if (half != null && !dirty) return half;
            uint* src = Premultiplied;
            int w = (Width + 1) / 2, h = (Height + 1) / 2;
            Image r = new Image(w, h);
            for (int y = 0; y < h; y++)
            {
                int y0 = y * 2, y1 = Math.Min(y * 2 + 1, Height - 1);
                for (int x = 0; x < w; x++)
                {
                    int x0 = x * 2, x1 = Math.Min(x * 2 + 1, Width - 1);
                    uint p0 = src[(long)y0 * Width + x0], p1 = src[(long)y0 * Width + x1];
                    uint p2 = src[(long)y1 * Width + x0], p3 = src[(long)y1 * Width + x1];
                    uint res = 0;
                    for (int sh = 0; sh < 32; sh += 8)
                    {
                        uint sum = ((p0 >> sh) & 255) + ((p1 >> sh) & 255) + ((p2 >> sh) & 255) + ((p3 >> sh) & 255);
                        res |= ((sum + 2) / 4) << sh;
                    }
                    r.Pixels[(long)y * w + x] = res;
                }
            }
            // r.Pixels ya está premultiplicado: su copia premultiplicada es la misma.
            r.premul = r.Pixels;
            r.dirty = false;
            half = r;
            return r;
        }
    }

    public memory_unsafe partial class Canvas
    {
        // Dibuja la imagen entera en (x, y) a su tamaño natural.
        public void DrawImage(Image img, float x, float y)
        {
            if (img == null) return;
            DrawImage(img, 0, 0, img.Width, img.Height, x, y, img.Width, img.Height, 1);
        }

        // Dibuja la imagen entera escalada al rectángulo (filtro bilineal).
        public void DrawImage(Image img, float x, float y, float w, float h)
        {
            if (img == null) return;
            DrawImage(img, 0, 0, img.Width, img.Height, x, y, w, h, 1);
        }

        // Dibuja la región (sx, sy, sw, sh) de la imagen (en píxeles de la imagen) en el rectángulo
        // (x, y, w, h) del lienzo, con opacidad 0..1. Escala con filtro bilineal (y mipmaps al reducir).
        public void DrawImage(Image img, float sx, float sy, float sw, float sh, float x, float y, float w, float h, float opacity)
        {
            if (img == null || img.Pixels == null || w <= 0 || h <= 0 || sw <= 0 || sh <= 0 || opacity <= 0) return;
            float X0 = x * Scale, Y0 = y * Scale, X1 = (x + w) * Scale, Y1 = (y + h) * Scale;
            int x0 = Math.Max((int)Math.Floor(X0 + 0.5f), clipX0), y0 = Math.Max((int)Math.Floor(Y0 + 0.5f), clipY0);
            int x1 = Math.Min((int)Math.Floor(X1 + 0.5f), clipX1), y1 = Math.Min((int)Math.Floor(Y1 + 0.5f), clipY1);
            if (x0 >= x1 || y0 >= y1) return;
            float kx = sw / (X1 - X0), ky = sh / (Y1 - Y0);   // píxeles de la imagen por píxel del lienzo
            float lod = 1;
            Image src = img.Level(kx < ky ? kx : ky, out lod);
            uint* px = src.Premultiplied;
            int iw = src.Width, ih = src.Height;
            float fsx = sx / lod, fsy = sy / lod;
            kx /= lod;
            ky /= lod;
            // Límites de la región (para no mezclar con los píxeles de fuera al recortar un sprite).
            float minU = fsx, maxU = fsx + sw / lod - 1, minV = fsy, maxV = fsy + sh / lod - 1;
            if (maxU < minU) maxU = minU;
            if (maxV < minV) maxV = minV;
            if (maxU > iw - 1) maxU = iw - 1;
            if (maxV > ih - 1) maxV = ih - 1;
            uint alpha = (uint)(Math.Clamp((double)opacity, 0.0, 1.0) * 256);
            bool exact = Math.Abs(kx - 1) < 0.0001f && Math.Abs(ky - 1) < 0.0001f;
            for (int py = y0; py < y1; py++)
            {
                float v = fsy + (py + 0.5f - Y0) * ky - 0.5f;
                if (v < minV) v = minV;
                if (v > maxV) v = maxV;
                int vy = (int)Math.Floor(v);
                int vy1 = vy + 1 > (int)maxV ? vy : vy + 1;
                uint fy = (uint)((v - vy) * 256);
                if (exact) fy = 0;
                uint* row0 = px + (long)vy * iw;
                uint* row1 = px + (long)vy1 * iw;
                uint* dst = Pixels + (long)py * Width;
                for (int qx = x0; qx < x1; qx++)
                {
                    float u = fsx + (qx + 0.5f - X0) * kx - 0.5f;
                    if (u < minU) u = minU;
                    if (u > maxU) u = maxU;
                    int ux = (int)Math.Floor(u);
                    int ux1 = ux + 1 > (int)maxU ? ux : ux + 1;
                    uint fx = exact ? (uint)0 : (uint)((u - ux) * 256);
                    uint c = Bilerp(row0[ux], row0[ux1], row1[ux], row1[ux1], fx, fy);
                    if (alpha < 256) c = ScalePremul(c, alpha);
                    uint a = c >> 24;
                    if (a == 0) continue;
                    if (a == 255)
                    {
                        dst[qx] = c & 0xffffff;
                        continue;
                    }
                    // 'over' premultiplicado: dst = src + dst * (1 - a)
                    uint d = dst[qx];
                    uint ia = 255 - a;
                    uint rb = ((c & 0xff00ff) + (((d & 0xff00ff) * ia + 0x800080) >> 8 & 0xff00ff)) & 0xff00ff;
                    uint g = ((c & 0xff00) + (((d & 0xff00) * ia + 0x8000) >> 8 & 0xff00)) & 0xff00;
                    dst[qx] = rb | g;
                }
            }
        }

        static uint Lerp8(uint a, uint b, uint t) => (a * (256 - t) + b * t) >> 8;

        static uint Bilerp(uint p00, uint p10, uint p01, uint p11, uint fx, uint fy)
        {
            if (fx == 0 && fy == 0) return p00;
            uint r = 0;
            for (int sh = 0; sh < 32; sh += 8)
            {
                uint top = Lerp8((p00 >> sh) & 255, (p10 >> sh) & 255, fx);
                uint bot = Lerp8((p01 >> sh) & 255, (p11 >> sh) & 255, fx);
                r |= (Lerp8(top, bot, fy) & 255) << sh;
            }
            return r;
        }

        static uint ScalePremul(uint c, uint k)
        {
            uint r = 0;
            for (int sh = 0; sh < 32; sh += 8) r |= ((((c >> sh) & 255) * k) >> 8) << sh;
            return r;
        }
    }

    public memory_unsafe partial class Widget
    {
        Image image;
        string source = "";
        public PictureSizeMode SizeMode = PictureSizeMode.Normal;   // PictureBox
        public Image Icon;                                          // Button y MenuItem: icono a la izquierda del texto

        // PictureBox: imagen que se muestra (null = ninguna).
        public Image Image { get => image; set { image = value; Invalidate(); } }

        // PictureBox: archivo de la imagen; al asignarlo se carga (con caché). Si no se puede
        // leer, Image queda en null y Image.LastError dice por qué.
        // WebView: dirección de la página (asignarla navega).
        public string Source
        {
            get => Kind == WidgetKind.WebView ? webSource : source;
            set
            {
                if (Kind == WidgetKind.WebView)
                {
                    Navigate(value);
                    return;
                }
                source = String.Copy(value);
                image = value.Length > 0 ? std.ui.Image.FromFile(value) : null;
                Invalidate();
            }
        }

        // Button: icono (opcional) y texto centrados.
        void DrawButtonContent(Canvas c, UiFont font, float fx, float fy, float fw, float fh, uint fg, bool pressed)
        {
            float tw = font.Measure(text);
            float baseline = fy + (fh - font.LineHeight) / 2 + font.Ascent + (pressed ? 1 : 0);
            if (Icon == null)
            {
                c.Text(font, text, fx + (fw - tw) / 2, baseline, fg);
                return;
            }
            float iw = 0, ih = 0;
            IconSize(Icon, fh - 12, out iw, out ih);
            float gap = text.Length > 0 ? 8 : 0;
            float total = iw + gap + tw;
            float left = fx + (fw - total) / 2;
            c.DrawImage(Icon, left, fy + (fh - ih) / 2 + (pressed ? 1 : 0), iw, ih);
            if (text.Length > 0) c.Text(font, text, left + iw + gap, baseline, fg);
        }

        // Tamaño del icono: el natural si cabe en 'room' de alto; si no, reducido conservando la proporción.
        internal static void IconSize(Image img, float room, out float w, out float h)
        {
            w = img.Width;
            h = img.Height;
            if (room < 8) room = 8;
            if (h > room)
            {
                w = w * room / h;
                h = room;
            }
        }

        void DrawPictureBox(Canvas c, Palette p, float fx, float fy, float fw, float fh)
        {
            float r = CornerRadius >= 0 ? CornerRadius : 0;
            if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, 0);
            c.Clip(ScreenX, ScreenY, ActualWidth, ActualHeight);
            if (image != null && image.Width > 0 && image.Height > 0)
            {
                float iw = image.Width, ih = image.Height;
                switch (SizeMode)
                {
                    case PictureSizeMode.Stretch:
                        c.DrawImage(image, fx, fy, fw, fh);
                        break;
                    case PictureSizeMode.Zoom:
                    {
                        float k = (float)Math.Min(fw / iw, fh / ih);
                        c.DrawImage(image, fx + (fw - iw * k) / 2, fy + (fh - ih * k) / 2, iw * k, ih * k);
                        break;
                    }
                    case PictureSizeMode.Cover:
                    {
                        // Llena el rectángulo y recorta lo que sobra (centrado).
                        float k = (float)Math.Max(fw / iw, fh / ih);
                        float sw = fw / k, sh = fh / k;
                        c.DrawImage(image, (iw - sw) / 2, (ih - sh) / 2, sw, sh, fx, fy, fw, fh, 1);
                        break;
                    }
                    case PictureSizeMode.Center:
                        c.DrawImage(image, (float)Math.Floor(fx + (fw - iw) / 2), (float)Math.Floor(fy + (fh - ih) / 2));
                        break;
                    default:
                        c.DrawImage(image, fx, fy);
                        break;
                }
            }
            c.ResetClip();
            if (BorderColor != 0) c.StrokeRoundRect(fx, fy, fw, fh, r, 1, BorderColor);
        }
    }
}
