// =============================================================================
//  Soul - mesh + mesh builder.
//
//  A Mesh owns a GPU vertex buffer and index buffer. MeshBuilder accumulates
//  geometry on the CPU. Each vertex is [x,y,z, nx,ny,nz, r,g,b] (9 floats,
//  36-byte stride): position, normal (for lighting) and base colour. The same
//  builder is used for voxel chunk meshes, water and foliage.
// =============================================================================
using std;

namespace Soul.Vulkan
{
    public memory_unsafe class Mesh
    {
        public var VertexBuffer: void*
        public var VertexMemory: void*
        public var IndexBuffer: void*
        public var IndexMemory: void*
        public var IndexCount: int

        public func Destroy(device: void*)
        {
            if (IndexBuffer != null)  Vk.vkDestroyBuffer(device, IndexBuffer, null);
            if (IndexMemory != null)  Vk.vkFreeMemory(device, IndexMemory, null);
            if (VertexBuffer != null) Vk.vkDestroyBuffer(device, VertexBuffer, null);
            if (VertexMemory != null) Vk.vkFreeMemory(device, VertexMemory, null);
            IndexBuffer = null; IndexMemory = null; VertexBuffer = null; VertexMemory = null;
            IndexCount = 0;
        }
    }

    // CPU-side geometry accumulator. Each vertex is [pos.xyz, normal.xyz, color.rgb].
    public memory_unsafe class MeshBuilder
    {
        const int STRIDE = 11;   // floats per vertex: pos(3) normal(3) color(3) uv(2)

        var verts: float*
        var vcapFloats: int
        public var VertCount: int

        var inds: uint*
        var icap: int
        public var IndexCount: int

        public init()
        {
            vcapFloats = 256 * STRIDE;
            verts = (float*)Memory.Alloc(vcapFloats * 4);
            VertCount = 0;

            icap = 384;
            inds = (uint*)Memory.Alloc(icap * 4);
            IndexCount = 0;
        }

        public func Reset() { VertCount = 0; IndexCount = 0; }
        public func IsEmpty() -> bool => IndexCount == 0;

        func EnsureVerts(extra: int)
        {
            int need = (VertCount + extra) * STRIDE;
            if (need <= vcapFloats) return;
            while (need > vcapFloats) vcapFloats *= 2;
            verts = (float*)Memory.Resize<float>(verts, vcapFloats);
        }

        func EnsureIndices(extra: int)
        {
            if (IndexCount + extra <= icap) return;
            while (IndexCount + extra > icap) icap *= 2;
            inds = (uint*)Memory.Resize<uint>(inds, icap);
        }

        public func AddVertex(x: float, y: float, z: float,
                             nx: float, ny: float, nz: float,
                             r: float, g: float, b: float,
                             u: float, v: float)
        {
            EnsureVerts(1);
            int o = VertCount * STRIDE;
            verts[o]     = x;  verts[o + 1] = y;  verts[o + 2] = z;
            verts[o + 3] = nx; verts[o + 4] = ny; verts[o + 5] = nz;
            verts[o + 6] = r;  verts[o + 7] = g;  verts[o + 8] = b;
            verts[o + 9] = u;  verts[o + 10] = v;
            VertCount++;
        }

        // Quad from four corners (a->b->c->d), with a shared normal + colour, a
        // texture rect (u0,v0)-(u1,v1) mapped a->(u0,v0) b->(u0,v1) c->(u1,v1) d->(u1,v0),
        // and a per-corner ambient-occlusion multiplier (aoA..aoD).
        public func AddQuad(ax: float, ay: float, az: float,
                            bx: float, by: float, bz: float,
                            cx: float, cy: float, cz: float,
                            dx: float, dy: float, dz: float,
                            nx: float, ny: float, nz: float,
                            u0: float, v0: float, u1: float, v1: float,
                            r: float, g: float, b: float,
                            aoA: float, aoB: float, aoC: float, aoD: float)
        {
            int base = VertCount;
            AddVertex(ax, ay, az, nx, ny, nz, r * aoA, g * aoA, b * aoA, u0, v0);
            AddVertex(bx, by, bz, nx, ny, nz, r * aoB, g * aoB, b * aoB, u0, v1);
            AddVertex(cx, cy, cz, nx, ny, nz, r * aoC, g * aoC, b * aoC, u1, v1);
            AddVertex(dx, dy, dz, nx, ny, nz, r * aoD, g * aoD, b * aoD, u1, v0);

            EnsureIndices(6);
            inds[IndexCount++] = (uint)base;
            inds[IndexCount++] = (uint)(base + 1);
            inds[IndexCount++] = (uint)(base + 2);
            inds[IndexCount++] = (uint)base;
            inds[IndexCount++] = (uint)(base + 2);
            inds[IndexCount++] = (uint)(base + 3);
        }

        public func VertexPtr() -> float* => verts;
        public func IndexPtr() -> uint* => inds;
        public func VertexBytes() -> long => (long)VertCount * STRIDE * 4;
        public func IndexBytes() -> long => (long)IndexCount * 4;
    }
}
