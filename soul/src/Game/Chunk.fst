// =============================================================================
//  Soul - chunk meshing.
//
//  Builds two meshes per chunk: an opaque mesh (terrain, trees, foliage) and a
//  translucent water mesh. Face culling is per material:
//    - opaque blocks emit faces toward anything non-opaque (air/water/leaves),
//      so underwater terrain is visible through the water,
//    - leaves emit faces toward non-solid cells only,
//    - water emits faces toward air only (the surface and shoreline edges).
// =============================================================================
using std;
using Soul.Vulkan;

namespace Soul.Game
{
    public memory_unsafe static class Chunk
    {
        static func NeighborOpen(selfType: byte, nx: int, ny: int, nz: int) -> bool
        {
            byte nb = World.BlockAt(nx, ny, nz);
            if (selfType == Block.WATER)  return nb == Block.AIR;
            if (selfType == Block.LEAVES) return !Block.IsSolid(nb);
            return !Block.IsOpaque(nb);
        }

        public static func BuildMesh(mbo: MeshBuilder, mbw: MeshBuilder, cx: int, cz: int)
        {
            int ox = cx * World.SX;
            int oz = cz * World.SZ;

            for (int lx = 0; lx < World.SX; lx++)
                for (int lz = 0; lz < World.SZ; lz++)
                {
                    int wx = ox + lx;
                    int wz = oz + lz;

                    for (int wy = 0; wy <= 52; wy++)
                    {
                        byte t = World.BlockAt(wx, wy, wz);
                        if (t == Block.AIR) continue;

                        bool top    = NeighborOpen(t, wx, wy + 1, wz);
                        bool bottom = NeighborOpen(t, wx, wy - 1, wz);
                        bool px     = NeighborOpen(t, wx + 1, wy, wz);
                        bool nx     = NeighborOpen(t, wx - 1, wy, wz);
                        bool pz     = NeighborOpen(t, wx, wy, wz + 1);
                        bool nz     = NeighborOpen(t, wx, wy, wz - 1);

                        if (!(top || bottom || px || nx || pz || nz)) continue;

                        if (t == Block.WATER)
                            BlockMesh.AddBlock(mbw, wx, wy, wz, t, top, bottom, px, nx, pz, nz);
                        else
                            BlockMesh.AddBlock(mbo, wx, wy, wz, t, top, bottom, px, nx, pz, nz);
                    }

                    // foliage: tall grass on exposed grass tops above sea level
                    int sh = World.HeightAt(wx, wz);
                    if (sh - 1 > World.SEA
                        && World.BlockAt(wx, sh - 1, wz) == Block.GRASS
                        && World.BlockAt(wx, sh, wz) == Block.AIR
                        && World.Hash(wx + 5000, wz + 5000) % 100u < 22u)
                    {
                        BlockMesh.AddCross(mbo, wx, sh, wz, Tiles.TALL_GRASS);
                    }
                }
        }
    }
}
