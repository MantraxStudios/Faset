// =============================================================================
//  Fuentes: FreeType (Linux) o stb_truetype (Windows, native/windows/stb_font.c)
//  rasterizan los glifos bajo demanda y se empaquetan en un atlas (textura de un
//  canal) que el renderizador sube a la GPU cuando cambia.
// =============================================================================
using std.collections;
using std.io;

namespace FasetStudio.Gfx
{
#if WINDOWS
    static extern void* faset_stb_open(byte* path, int px, float* ascent, float* descent);
    static extern int faset_stb_has(void* font, uint cp);
    static extern int faset_stb_glyph(void* font, uint cp, byte** coverage, int* w, int* h, int* left, int* top, float* advance);
    static extern void faset_stb_free(void* p);
#else
    static extern int FT_Init_FreeType(void** library);
    static extern int FT_New_Face(void* library, byte* path, long faceIndex, void** face);
    static extern int FT_Set_Pixel_Sizes(void* face, uint width, uint height);
    static extern int FT_Load_Char(void* face, ulong charcode, int flags);
#endif

    // Desplazamientos en FT_FaceRec / FT_SizeRec / FT_GlyphSlotRec (Linux 64 bits).
    static class FT
    {
        public const int FaceGlyph = 152;
        public const int FaceSize = 160;
        public const int SizeAscender = 48;
        public const int SizeDescender = 56;
        public const int SizeHeight = 64;
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

    public struct Glyph
    {
        public float U0;
        public float V0;
        public float U1;
        public float V1;
        public int Width;
        public int Height;
        public int Left;
        public int Top;
        public float Advance;
    }

    // Textura de cobertura (un byte por píxel) con empaquetado por filas.
    public memory_unsafe class Atlas
    {
        public byte* Pixels;
        public int Size;
        public bool Dirty = true;
        int penX;
        int penY;
        int rowHeight;

        public Atlas(int size)
        {
            Size = size;
            Pixels = (byte*)Memory.AllocZeroed((long)size * size);
            // Bloque blanco en la esquina: los rectángulos lo muestrean para tener cobertura 1.
            for (int y = 0; y < 4; y++)
                for (int x = 0; x < 4; x++) Pixels[y * size + x] = 255;
            penX = 6;
            penY = 1;
            rowHeight = 4;
        }

        ~Atlas() { Memory.Free(Pixels); }

        public float WhiteU => 1.5f / Size;
        public float WhiteV => 1.5f / Size;

        // Reserva un hueco de w x h píxeles; false si el atlas está lleno.
        public bool Allocate(int w, int h, out int x, out int y)
        {
            if (penX + w + 1 >= Size)
            {
                penX = 1;
                penY += rowHeight + 1;
                rowHeight = 0;
            }
            if (penY + h + 1 >= Size)
            {
                x = 0;
                y = 0;
                return false;
            }
            x = penX;
            y = penY;
            penX += w + 1;
            if (h > rowHeight) rowHeight = h;
            return true;
        }
    }

    public memory_unsafe class Font
    {
        static void* library;

        void* face;
        Atlas atlas;
        Dictionary<char, Glyph> glyphs = new Dictionary<char, Glyph>();

        public int PixelSize;
        public float Ascent;
        public float Descent;
        public float LineHeight;
        public float CharWidth;  // avance de 'M' (exacto en fuentes monoespaciadas)

        ~Font() { delete glyphs; }

#if WINDOWS
        void* fallback;   // fuente de símbolos para los caracteres que no tiene 'face'

        // Fuente de símbolos de respaldo (Windows: Segoe UI Symbol), "" si no hay.
        public static string FallbackPath = "";

        public bool Load(string path, int pixelSize, Atlas target)
        {
            string p = path.ToCString();
            float asc = 0, desc = 0;
            face = faset_stb_open(p.Ptr, pixelSize, &asc, &desc);
            String.Free(p);
            if (face == null) return false;
            if (FallbackPath.Length > 0 && FallbackPath != path)
            {
                string fp = FallbackPath.ToCString();
                float a2 = 0, d2 = 0;
                fallback = faset_stb_open(fp.Ptr, pixelSize, &a2, &d2);
                String.Free(fp);
            }
            atlas = target;
            PixelSize = pixelSize;
            Ascent = asc;
            Descent = desc;
            LineHeight = (float)Math.Ceiling(Ascent + Descent) + 3;
            CharWidth = Get('M').Advance;
            return true;
        }
#else
        public bool Load(string path, int pixelSize, Atlas target)
        {
            if (library == null && FT_Init_FreeType(&library) != 0) return false;
            string p = path.ToCString();
            int err = FT_New_Face(library, p.Ptr, 0, &face);
            String.Free(p);
            if (err != 0) return false;
            FT_Set_Pixel_Sizes(face, 0, (uint)pixelSize);
            atlas = target;
            PixelSize = pixelSize;
            byte* size = *(byte**)((byte*)face + FT.FaceSize);
            Ascent = *(long*)(size + FT.SizeAscender) / 64.0f;
            Descent = -(*(long*)(size + FT.SizeDescender) / 64.0f);
            LineHeight = (float)Math.Ceiling(Ascent + Descent) + 3;
            CharWidth = Get('M').Advance;
            return true;
        }
#endif

        // Primera fuente existente de la lista (separada por ';').
        public static string FindFile(string candidates)
        {
            auto parts = std.text.Text.Split(candidates, ";");
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

        public Glyph Get(char c)
        {
            Glyph g;
            if (glyphs.TryGetValue(c, out g)) return g;
            g = Render(c);
            glyphs.Set(c, g);
            return g;
        }

        Glyph Render(char c)
        {
            Glyph g = new Glyph();
#if WINDOWS
            void* font = face;
            if (fallback != null && faset_stb_has(face, (uint)c) == 0 && faset_stb_has(fallback, (uint)c) != 0) font = fallback;
            byte* buffer = null;
            int width = 0, rows = 0, left = 0, top = 0;
            float advance = 0;
            if (faset_stb_glyph(font, (uint)c, &buffer, &width, &rows, &left, &top, &advance) == 0) return g;
            int pitch = width;
            g.Advance = advance;
            g.Left = left;
            g.Top = top;
            g.Width = width;
            g.Height = rows;
            g = Place(g, buffer, pitch);
            faset_stb_free(buffer);
            return g;
#else
            if (FT_Load_Char(face, c, FT.LoadRender | FT.LoadTargetLight) != 0) return g;
            byte* slot = *(byte**)((byte*)face + FT.FaceGlyph);
            g.Advance = *(long*)(slot + FT.GlyphAdvanceX) / 64.0f;
            int rows = *(int*)(slot + FT.BitmapRows);
            int width = *(int*)(slot + FT.BitmapWidth);
            int pitch = *(int*)(slot + FT.BitmapPitch);
            byte* buffer = *(byte**)(slot + FT.BitmapBuffer);
            g.Left = *(int*)(slot + FT.BitmapLeft);
            g.Top = *(int*)(slot + FT.BitmapTop);
            g.Width = width;
            g.Height = rows;
            return Place(g, buffer, pitch);
#endif
        }

        // Copia la cobertura del glifo al atlas y calcula sus coordenadas de textura.
        Glyph Place(Glyph g, byte* buffer, int pitch)
        {
            int width = g.Width, rows = g.Height;
            if (width == 0 || rows == 0) return g;
            int ax = 0, ay = 0;
            if (!atlas.Allocate(width, rows, out ax, out ay))
            {
                g.Width = 0;
                return g;
            }
            for (int y = 0; y < rows; y++)
            {
                byte* src = buffer + (long)y * pitch;
                byte* dst = atlas.Pixels + (long)(ay + y) * atlas.Size + ax;
                for (int x = 0; x < width; x++) dst[x] = src[x];
            }
            float s = atlas.Size;
            g.U0 = ax / s;
            g.V0 = ay / s;
            g.U1 = (ax + width) / s;
            g.V1 = (ay + rows) / s;
            atlas.Dirty = true;
            return g;
        }
    }
}
