// =============================================================================
//  Soul - streaming chunk manager (infinite world).
//
//  Keeps the chunks within a radius around the camera loaded: it meshes new
//  chunks as the player approaches (a few per frame to avoid stutter) and frees
//  chunks that fall outside the radius. Each loaded chunk owns one renderer mesh
//  slot. Tree features for a chunk and its neighbours are generated before the
//  chunk is meshed, so cross-border canopies are never clipped.
// =============================================================================
using std;
using std.collections;
using Soul.Vulkan;

namespace Soul.Game
{
    public memory_unsafe class ChunkManager
    {
        var renderer: Renderer
        public var Radius: int

        var slots: Dictionary<long, int>
        var meshes: Dictionary<long, Mesh>
        var waterSlots: Dictionary<long, int>
        var waterMeshes: Dictionary<long, Mesh>
        var loadedKeys: List<long>

        public init(renderer: Renderer, radius: int)
        {
            this.renderer = renderer;
            Radius = radius;
            slots = new Dictionary<long, int>();
            meshes = new Dictionary<long, Mesh>();
            waterSlots = new Dictionary<long, int>();
            waterMeshes = new Dictionary<long, Mesh>();
            loadedKeys = new List<long>();
        }

        static func Key(cx: int, cz: int) -> long => ((long)cx << 32) | ((long)cz & 0xFFFFFFFF);

        func LoadChunk(cx: int, cz: int)
        {
            long k = Key(cx, cz);
            if (slots.ContainsKey(k)) return;

            for (int dx = -1; dx <= 1; dx++)
                for (int dz = -1; dz <= 1; dz++)
                    World.GenerateChunkFeatures(cx + dx, cz + dz);

            var mbo = new MeshBuilder();
            var mbw = new MeshBuilder();
            Chunk.BuildMesh(mbo, mbw, cx, cz);
            Mesh mo = mbo.IsEmpty() ? null : renderer.CreateMesh(mbo);
            Mesh mw = mbw.IsEmpty() ? null : renderer.CreateMesh(mbw);

            slots[k] = renderer.AddMesh(mo);
            meshes[k] = mo;
            waterSlots[k] = renderer.AddWaterMesh(mw);
            waterMeshes[k] = mw;
            loadedKeys.Add(k);
        }

        func UnloadChunk(k: long)
        {
            Mesh mo = meshes[k];
            renderer.RemoveMesh(slots[k]);
            if (mo != null) mo.Destroy(renderer.Device);
            Mesh mw = waterMeshes[k];
            renderer.RemoveWaterMesh(waterSlots[k]);
            if (mw != null) mw.Destroy(renderer.Device);
            slots.Remove(k);
            meshes.Remove(k);
            waterSlots.Remove(k);
            waterMeshes.Remove(k);
            loadedKeys.Remove(k);
        }

        public func Update(camX: float, camZ: float, budget: int)
        {
            int ccx = (int)Math.Floor((double)(camX / (float)World.SX));
            int ccz = (int)Math.Floor((double)(camZ / (float)World.SZ));

            int left = budget;
            for (int r = 0; r <= Radius; r++)
            {
                if (left <= 0) break;
                for (int dx = -r; dx <= r; dx++)
                    for (int dz = -r; dz <= r; dz++)
                    {
                        int ax = dx < 0 ? -dx : dx;
                        int az = dz < 0 ? -dz : dz;
                        int cheb = ax > az ? ax : az;
                        if (cheb != r) continue;
                        if (left <= 0) continue;
                        long k = Key(ccx + dx, ccz + dz);
                        if (!slots.ContainsKey(k)) { LoadChunk(ccx + dx, ccz + dz); left--; }
                    }
            }

            // unload chunks that drifted out of range
            var toRemove = new List<long>();
            for (int i = 0; i < loadedKeys.Count; i++)
            {
                long k = loadedKeys[i];
                int cx = (int)(k >> 32);
                int cz = (int)(k & 0xFFFFFFFF);
                int ddx = cx - ccx; if (ddx < 0) ddx = -ddx;
                int ddz = cz - ccz; if (ddz < 0) ddz = -ddz;
                int cheb = ddx > ddz ? ddx : ddz;
                if (cheb > Radius + 1) toRemove.Add(k);
            }
            for (int i = 0; i < toRemove.Count; i++) UnloadChunk(toRemove[i]);
        }

        // --- editing ---

        func RebuildChunk(cx: int, cz: int)
        {
            long k = Key(cx, cz);
            if (!slots.ContainsKey(k)) return;

            Mesh oldO = meshes[k];
            Mesh oldW = waterMeshes[k];

            var mbo = new MeshBuilder();
            var mbw = new MeshBuilder();
            Chunk.BuildMesh(mbo, mbw, cx, cz);
            Mesh mo = mbo.IsEmpty() ? null : renderer.CreateMesh(mbo);
            Mesh mw = mbw.IsEmpty() ? null : renderer.CreateMesh(mbw);

            renderer.ReplaceMesh(slots[k], mo);
            meshes[k] = mo;
            renderer.ReplaceWaterMesh(waterSlots[k], mw);
            waterMeshes[k] = mw;

            if (oldO != null) oldO.Destroy(renderer.Device);
            if (oldW != null) oldW.Destroy(renderer.Device);
        }

        public func RebuildAround(wx: int, wz: int)
        {
            int cx = (int)Math.Floor((double)wx / (double)World.SX);
            int cz = (int)Math.Floor((double)wz / (double)World.SZ);
            int lx = wx - cx * World.SX;
            int lz = wz - cz * World.SZ;

            RebuildChunk(cx, cz);
            if (lx == 0)            RebuildChunk(cx - 1, cz);
            if (lx == World.SX - 1) RebuildChunk(cx + 1, cz);
            if (lz == 0)            RebuildChunk(cx, cz - 1);
            if (lz == World.SZ - 1) RebuildChunk(cx, cz + 1);
        }
    }
}
