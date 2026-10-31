// =============================================================================
//  Soul - voxels: block types and block meshing (with ambient occlusion).
//
//  BlockMesh.AddBlock emits exposed faces with per-vertex ambient occlusion: a
//  corner is darkened when neighbouring blocks occlude it, which gives voxels the
//  soft "smooth lighting" look. Each face also carries a surface normal (for sun
//  lighting) and a texture tile.
// =============================================================================
using std;
using Soul.Vulkan;

namespace Soul.Game
{
    public static class Block
    {
        public const byte AIR    = 0;
        public const byte GRASS  = 1;
        public const byte DIRT   = 2;
        public const byte STONE  = 3;
        public const byte SAND   = 4;
        public const byte WATER  = 5;
        public const byte WOOD   = 6;
        public const byte LEAVES = 7;

        public static func IsSolid(t: byte) -> bool => t != AIR;
        public static func IsOpaque(t: byte) -> bool => t != AIR && t != WATER && t != LEAVES;
    }

    public memory_unsafe static class BlockMesh
    {
        static func UV(tile: int, rect: float*)
        {
            float t  = (float)Tiles.TILE;
            float sz = (float)Tiles.SIZE;
            int tx = tile % Tiles.PER_ROW;
            int ty = tile / Tiles.PER_ROW;
            rect[0] = ((float)tx * t + 0.5f) / sz;
            rect[1] = ((float)ty * t + 0.5f) / sz;
            rect[2] = ((float)(tx + 1) * t - 0.5f) / sz;
            rect[3] = ((float)(ty + 1) * t - 0.5f) / sz;
        }

        static func TopTile(type: byte) -> int
        {
            if (type == Block.GRASS)  return Tiles.GRASS_TOP;
            if (type == Block.WOOD)   return Tiles.WOOD_TOP;
            return SideTile(type);
        }
        static func SideTile(type: byte) -> int
        {
            if (type == Block.GRASS)  return Tiles.GRASS_SIDE;
            if (type == Block.DIRT)   return Tiles.DIRT;
            if (type == Block.STONE)  return Tiles.STONE;
            if (type == Block.SAND)   return Tiles.SAND;
            if (type == Block.WATER)  return Tiles.WATER;
            if (type == Block.WOOD)   return Tiles.WOOD_SIDE;
            if (type == Block.LEAVES) return Tiles.LEAVES;
            return Tiles.STONE;
        }
        static func BottomTile(type: byte) -> int
        {
            if (type == Block.GRASS)  return Tiles.DIRT;
            if (type == Block.WOOD)   return Tiles.WOOD_TOP;
            return SideTile(type);
        }

        // Ambient occlusion for one vertex from its three occluding neighbour cells.
        static func Cor(ax: int, ay: int, az: int, bx: int, by: int, bz: int, cx: int, cy: int, cz: int) -> float
        {
            int s1 = World.IsOpaque(ax, ay, az) ? 1 : 0;
            int s2 = World.IsOpaque(bx, by, bz) ? 1 : 0;
            int cc = World.IsOpaque(cx, cy, cz) ? 1 : 0;
            if (s1 == 1 && s2 == 1) return 0.45f;
            int n = s1 + s2 + cc;
            return n == 0 ? 1.0f : (n == 1 ? 0.78f : 0.60f);
        }

        public static func AddBlock(mb: MeshBuilder, x: int, y: int, z: int, type: byte,
                                    top: bool, bottom: bool, px: bool, nx: bool, pz: bool, nz: bool)
        {
            float fx = (float)x;      float fy = (float)y;      float fz = (float)z;
            float x1 = fx + 1.0f;     float y1 = fy + 1.0f;     float z1 = fz + 1.0f;
            float* r = (float*)Memory.Alloc(16);

            if (top)
            {
                int oy = y + 1;
                float a = Cor(x-1,oy,z, x,oy,z-1, x-1,oy,z-1);
                float b = Cor(x-1,oy,z, x,oy,z+1, x-1,oy,z+1);
                float c = Cor(x+1,oy,z, x,oy,z+1, x+1,oy,z+1);
                float d = Cor(x+1,oy,z, x,oy,z-1, x+1,oy,z-1);
                UV(TopTile(type), r);
                mb.AddQuad(fx,y1,fz, fx,y1,z1, x1,y1,z1, x1,y1,fz, 0.0f,1.0f,0.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, a,b,c,d);
            }
            if (bottom)
            {
                int oy = y - 1;
                float a = Cor(x-1,oy,z, x,oy,z-1, x-1,oy,z-1);
                float b = Cor(x+1,oy,z, x,oy,z-1, x+1,oy,z-1);
                float c = Cor(x+1,oy,z, x,oy,z+1, x+1,oy,z+1);
                float d = Cor(x-1,oy,z, x,oy,z+1, x-1,oy,z+1);
                UV(BottomTile(type), r);
                mb.AddQuad(fx,fy,fz, x1,fy,fz, x1,fy,z1, fx,fy,z1, 0.0f,-1.0f,0.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, a,b,c,d);
            }
            if (px)
            {
                int ox = x + 1;
                float a = Cor(ox,y-1,z, ox,y,z-1, ox,y-1,z-1);
                float b = Cor(ox,y+1,z, ox,y,z-1, ox,y+1,z-1);
                float c = Cor(ox,y+1,z, ox,y,z+1, ox,y+1,z+1);
                float d = Cor(ox,y-1,z, ox,y,z+1, ox,y-1,z+1);
                UV(SideTile(type), r);
                mb.AddQuad(x1,fy,fz, x1,y1,fz, x1,y1,z1, x1,fy,z1, 1.0f,0.0f,0.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, a,b,c,d);
            }
            if (nx)
            {
                int ox = x - 1;
                float a = Cor(ox,y-1,z, ox,y,z-1, ox,y-1,z-1);
                float b = Cor(ox,y-1,z, ox,y,z+1, ox,y-1,z+1);
                float c = Cor(ox,y+1,z, ox,y,z+1, ox,y+1,z+1);
                float d = Cor(ox,y+1,z, ox,y,z-1, ox,y+1,z-1);
                UV(SideTile(type), r);
                mb.AddQuad(fx,fy,fz, fx,fy,z1, fx,y1,z1, fx,y1,fz, -1.0f,0.0f,0.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, a,b,c,d);
            }
            if (pz)
            {
                int oz = z + 1;
                float a = Cor(x-1,y,oz, x,y-1,oz, x-1,y-1,oz);
                float b = Cor(x+1,y,oz, x,y-1,oz, x+1,y-1,oz);
                float c = Cor(x+1,y,oz, x,y+1,oz, x+1,y+1,oz);
                float d = Cor(x-1,y,oz, x,y+1,oz, x-1,y+1,oz);
                UV(SideTile(type), r);
                mb.AddQuad(fx,fy,z1, x1,fy,z1, x1,y1,z1, fx,y1,z1, 0.0f,0.0f,1.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, a,b,c,d);
            }
            if (nz)
            {
                int oz = z - 1;
                float a = Cor(x-1,y,oz, x,y-1,oz, x-1,y-1,oz);
                float b = Cor(x-1,y,oz, x,y+1,oz, x-1,y+1,oz);
                float c = Cor(x+1,y,oz, x,y+1,oz, x+1,y+1,oz);
                float d = Cor(x+1,y,oz, x,y-1,oz, x+1,y-1,oz);
                UV(SideTile(type), r);
                mb.AddQuad(fx,fy,fz, fx,y1,fz, x1,y1,fz, x1,fy,fz, 0.0f,0.0f,-1.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, a,b,c,d);
            }

            Memory.Free((void*)r);
        }

        // Two crossed vertical quads for foliage (no AO).
        public static func AddCross(mb: MeshBuilder, x: int, y: int, z: int, tile: int)
        {
            float* r = (float*)Memory.Alloc(16);
            UV(tile, r);
            float fx = (float)x;  float fy = (float)y;  float fz = (float)z;
            float x1 = fx + 1.0f; float y1 = fy + 1.0f; float z1 = fz + 1.0f;

            mb.AddQuad(fx,y1,fz, fx,fy,fz, x1,fy,z1, x1,y1,z1, 0.0f,1.0f,0.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);
            mb.AddQuad(x1,y1,fz, x1,fy,fz, fx,fy,z1, fx,y1,z1, 0.0f,1.0f,0.0f, r[0],r[1],r[2],r[3], 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);

            Memory.Free((void*)r);
        }

        // A small textured cube (half-size s) centred at (px,py,pz), for particles.
        public static func AddParticleCube(mb: MeshBuilder, px: float, py: float, pz: float, s: float, type: byte)
        {
            float* r = (float*)Memory.Alloc(16);
            UV(SideTile(type), r);
            float x0 = px - s; float x1 = px + s;
            float y0 = py - s; float y1 = py + s;
            float z0 = pz - s; float z1 = pz + s;
            float u0 = r[0]; float v0 = r[1]; float u1 = r[2]; float v1 = r[3];

            mb.AddQuad(x0,y1,z0, x0,y1,z1, x1,y1,z1, x1,y1,z0, 0.0f,1.0f,0.0f,  u0,v0,u1,v1, 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);
            mb.AddQuad(x0,y0,z0, x1,y0,z0, x1,y0,z1, x0,y0,z1, 0.0f,-1.0f,0.0f, u0,v0,u1,v1, 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);
            mb.AddQuad(x1,y0,z0, x1,y1,z0, x1,y1,z1, x1,y0,z1, 1.0f,0.0f,0.0f,  u0,v0,u1,v1, 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);
            mb.AddQuad(x0,y0,z0, x0,y0,z1, x0,y1,z1, x0,y1,z0, -1.0f,0.0f,0.0f, u0,v0,u1,v1, 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);
            mb.AddQuad(x0,y0,z1, x1,y0,z1, x1,y1,z1, x0,y1,z1, 0.0f,0.0f,1.0f,  u0,v0,u1,v1, 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);
            mb.AddQuad(x0,y0,z0, x0,y1,z0, x1,y1,z0, x1,y0,z0, 0.0f,0.0f,-1.0f, u0,v0,u1,v1, 1.0f,1.0f,1.0f, 1.0f,1.0f,1.0f,1.0f);

            Memory.Free((void*)r);
        }
    }
}
