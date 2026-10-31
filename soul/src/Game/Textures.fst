// =============================================================================
//  Soul - procedural texture atlas.
//
//  Generates a 64x64 RGBA atlas of 4x4 tiles (16x16 px each) entirely in code:
//  grass, dirt, stone, sand, wood and leaves, each with per-pixel noise so the
//  blocks read as textured rather than flat. Tiles are addressed by index and
//  the mesher maps block faces to tile UV rects.
// =============================================================================
using std;

namespace Soul.Game
{
    public static class Tiles
    {
        public const int SIZE     = 64;   // atlas size in px
        public const int TILE     = 16;   // tile size in px
        public const int PER_ROW  = 4;

        // tile indices (ty*PER_ROW + tx)
        public const int GRASS_TOP  = 0;
        public const int GRASS_SIDE = 1;
        public const int DIRT       = 2;
        public const int STONE      = 3;
        public const int SAND       = 4;
        public const int WOOD_SIDE  = 5;
        public const int WOOD_TOP   = 6;
        public const int LEAVES     = 7;
        public const int WATER      = 8;
        public const int TALL_GRASS = 9;
    }

    public memory_unsafe static class TextureAtlas
    {
        static func Rnd(x: int, y: int) -> float
        {
            uint h = (uint)(x * 374761393 + y * 668265263);
            h = (h ^ (h >> 13)) * 1274126177u;
            h = h ^ (h >> 16);
            return (float)(h & 0xFFFFu) / 65535.0f;
        }

        static func Clamp01(v: float) -> float => v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);

        static func SetPx(px: byte*, x: int, y: int, r: float, g: float, b: float, a: float)
        {
            int o = (y * Tiles.SIZE + x) * 4;
            px[o]     = (byte)(Clamp01(r) * 255.0f);
            px[o + 1] = (byte)(Clamp01(g) * 255.0f);
            px[o + 2] = (byte)(Clamp01(b) * 255.0f);
            px[o + 3] = (byte)(Clamp01(a) * 255.0f);
        }

        // style: 0 speckle, 1 grass_side, 2 wood_side, 3 wood_top, 4 leaves
        static func FillTile(px: byte*, tile: int, br: float, bg: float, bb: float, amp: float, style: int)
        {
            int tx0 = (tile % Tiles.PER_ROW) * Tiles.TILE;
            int ty0 = (tile / Tiles.PER_ROW) * Tiles.TILE;

            for (int y = 0; y < Tiles.TILE; y++)
                for (int x = 0; x < Tiles.TILE; x++)
                {
                    int ax = tx0 + x;
                    int ay = ty0 + y;
                    float n = Rnd(ax, ay) - 0.5f;
                    float r = br + amp * n;
                    float g = bg + amp * n;
                    float b = bb + amp * n;
                    float a = 1.0f;

                    if (style == 1)  // grass side: green band on top, dirt below
                    {
                        if (y < 4 + (int)(Rnd(ax, 0) * 2.0f)) { r = 0.40f + amp * n; g = 0.72f + amp * n; b = 0.32f + amp * n; }
                        else { r = 0.55f + amp * n; g = 0.41f + amp * n; b = 0.26f + amp * n; }
                    }
                    else if (style == 2)  // wood side: vertical bark lines
                    {
                        float line = ((x % 4) == 0) ? -0.10f : 0.0f;
                        r = br + line + amp * n; g = bg + line + amp * n; b = bb + line + amp * n;
                    }
                    else if (style == 3)  // wood top: concentric rings
                    {
                        float dx = (float)(x - 8); float dy = (float)(y - 8);
                        float d = (float)Math.Sqrt((double)(dx * dx + dy * dy));
                        float ring = (float)Math.Sin((double)(d * 1.6)) * 0.08f;
                        r = br + ring + amp * n; g = bg + ring + amp * n; b = bb + ring + amp * n;
                    }
                    else if (style == 4)  // leaves: darker holes
                    {
                        if (Rnd(ax + 31, ay + 17) < 0.18f) { r *= 0.55f; g *= 0.55f; b *= 0.55f; }
                    }
                    else if (style == 5)  // tall grass: green blades on transparent bg
                    {
                        a = 0.0f;
                        bool isBlade = (x % 3) == (int)(Rnd(x * 7, 1) * 2.49f);
                        int th = 5 + (int)(Rnd(x, 3) * 8.0f);
                        if (isBlade && y >= (Tiles.TILE - th))
                        {
                            a = 1.0f;
                            r = 0.26f + 0.12f * n; g = 0.55f + 0.12f * n; b = 0.19f + 0.12f * n;
                        }
                    }

                    SetPx(px, ax, ay, r, g, b, a);
                }
        }

        // Allocate and fill the atlas. Returns RGBA pixels (SIZE*SIZE*4 bytes).
        public static func Generate() -> byte*
        {
            byte* px = (byte*)Memory.Alloc(Tiles.SIZE * Tiles.SIZE * 4);

            FillTile(px, Tiles.GRASS_TOP,  0.42f, 0.72f, 0.34f, 0.07f, 0);
            FillTile(px, Tiles.GRASS_SIDE, 0.55f, 0.41f, 0.26f, 0.06f, 1);
            FillTile(px, Tiles.DIRT,       0.55f, 0.41f, 0.26f, 0.07f, 0);
            FillTile(px, Tiles.STONE,      0.58f, 0.58f, 0.61f, 0.06f, 0);
            FillTile(px, Tiles.SAND,       0.88f, 0.82f, 0.58f, 0.05f, 0);
            FillTile(px, Tiles.WOOD_SIDE,  0.52f, 0.37f, 0.21f, 0.05f, 2);
            FillTile(px, Tiles.WOOD_TOP,   0.62f, 0.47f, 0.29f, 0.05f, 3);
            FillTile(px, Tiles.LEAVES,     0.26f, 0.58f, 0.24f, 0.10f, 4);
            FillTile(px, Tiles.WATER,      0.24f, 0.52f, 0.92f, 0.05f, 0);
            FillTile(px, Tiles.TALL_GRASS, 0.32f, 0.64f, 0.26f, 0.08f, 5);

            return px;
        }
    }
}
