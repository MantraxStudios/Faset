// =============================================================================
//  Soul - the world.
//
//  A procedural heightmap world. Surface height comes from a sum of sine octaves.
//  Blocks: grass on top (sand near/under water), a band of dirt, stone below;
//  water fills everything up to sea level. Trees are generated as a feature pass
//  into the sparse override map, so they sit on top of the base terrain.
// =============================================================================
using std;
using std.collections;

namespace Soul.Game
{
    public static class World
    {
        public const int SX  = 16;      // chunk size in X
        public const int SZ  = 16;      // chunk size in Z
        public const int SEA = 19;      // sea level

        static var overrides: Dictionary<long, byte> = new Dictionary<long, byte>();
        static var featured:  Dictionary<long, byte> = new Dictionary<long, byte>();

        static func Key(x: int, y: int, z: int) -> long
            => ((long)(x + 1048576) << 42) | ((long)(y + 1024) << 21) | (long)(z + 1048576);

        public static func HeightAt(wx: int, wz: int) -> int
        {
            double x = (double)wx;
            double z = (double)wz;
            double h = 22.0
                     + 6.0 * Math.Sin(x * 0.15)
                     + 5.0 * Math.Cos(z * 0.13)
                     + 3.0 * Math.Sin((x + z) * 0.08)
                     + 2.0 * Math.Sin(x * 0.37) * Math.Cos(z * 0.29);
            int hi = (int)Math.Floor(h);
            if (hi < 1) hi = 1;
            return hi;
        }

        static func BaseBlock(wx: int, wy: int, wz: int) -> byte
        {
            if (wy < 0) return Block.AIR;
            int h = HeightAt(wx, wz);
            if (wy < h)
            {
                if (wy == h - 1)
                    return (h - 1 <= SEA) ? Block.SAND : Block.GRASS;
                if (wy >= h - 4) return Block.DIRT;
                return Block.STONE;
            }
            if (wy <= SEA) return Block.WATER;
            return Block.AIR;
        }

        public static func BlockAt(wx: int, wy: int, wz: int) -> byte
        {
            byte ov;
            if (overrides.TryGetValue(Key(wx, wy, wz), out ov)) return ov;
            return BaseBlock(wx, wy, wz);
        }

        public static func SetBlock(wx: int, wy: int, wz: int, type: byte)
        {
            overrides[Key(wx, wy, wz)] = type;
        }

        public static func IsSolid(wx: int, wy: int, wz: int) -> bool
            => Block.IsSolid(BlockAt(wx, wy, wz));

        public static func IsOpaque(wx: int, wy: int, wz: int) -> bool
            => Block.IsOpaque(BlockAt(wx, wy, wz));

        // ---- feature generation (trees) ----

        public static func Hash(x: int, z: int) -> uint
        {
            uint h = (uint)(x * 73856093) ^ (uint)(z * 19349663);
            h = h ^ (h >> 13);
            h = h * 1274126177u;
            return h ^ (h >> 16);
        }

        // Generate the trees owned by one chunk, once. Idempotent per chunk.
        public static func GenerateChunkFeatures(cx: int, cz: int)
        {
            long k = ((long)cx << 32) | ((long)cz & 0xFFFFFFFF);
            byte dummy;
            if (featured.TryGetValue(k, out dummy)) return;
            featured[k] = (byte)1;

            int ox = cx * SX;
            int oz = cz * SZ;
            for (int lx = 0; lx < SX; lx++)
                for (int lz = 0; lz < SZ; lz++)
                {
                    int wx = ox + lx;
                    int wz = oz + lz;
                    int h = HeightAt(wx, wz);
                    if (h - 1 <= SEA) continue;                 // no trees on sand/water
                    if (Hash(wx, wz) % 140u != 0u) continue;    // ~0.7% of columns
                    PlaceTree(wx, h, wz);
                }
        }

        static func PlaceTree(x: int, baseY: int, z: int)
        {
            int trunkH = 4 + (int)(Hash(x + 7, z - 3) % 3u);
            int topY = baseY + trunkH;

            // canopy
            for (int dy = -2; dy <= 1; dy++)
            {
                int ly = topY + dy;
                int rad = (dy >= 0) ? 1 : 2;
                for (int lx = -rad; lx <= rad; lx++)
                    for (int lz = -rad; lz <= rad; lz++)
                    {
                        if (lx == 0 && lz == 0 && dy < 0) continue;              // leave room for trunk
                        if ((lx == rad || lx == -rad) && (lz == rad || lz == -rad)) continue; // round corners
                        if (!Block.IsSolid(BlockAt(x + lx, ly, z + lz)))
                            SetBlock(x + lx, ly, z + lz, Block.LEAVES);
                    }
            }

            // trunk
            for (int i = 0; i < trunkH; i++)
                SetBlock(x, baseY + i, z, Block.WOOD);
        }
    }
}
