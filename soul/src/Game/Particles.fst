// =============================================================================
//  Soul - particle VFX.
//
//  A small CPU particle system for block-break bursts: textured cubelets that
//  fly out, fall under gravity and expire. Stored as parallel arrays (fixed
//  capacity) to keep the hot update/compact loop simple and allocation-free.
//  Each frame the live particles are rebuilt into a mesh the renderer uploads.
// =============================================================================
using std;
using Soul.Vulkan;

namespace Soul.Game
{
    public memory_unsafe class ParticleSystem
    {
        const int MAX = 1024;

        var px: float*
        var py: float*
        var pz: float*
        var vx: float*
        var vy: float*
        var vz: float*
        var life: float*
        var ptype: byte*
        var count: int
        var seed: uint

        public init()
        {
            px = (float*)Memory.Alloc(MAX * 4);
            py = (float*)Memory.Alloc(MAX * 4);
            pz = (float*)Memory.Alloc(MAX * 4);
            vx = (float*)Memory.Alloc(MAX * 4);
            vy = (float*)Memory.Alloc(MAX * 4);
            vz = (float*)Memory.Alloc(MAX * 4);
            life = (float*)Memory.Alloc(MAX * 4);
            ptype = (byte*)Memory.Alloc(MAX);
            count = 0;
            seed = 0x1234567u;
        }

        func Rnd() -> float
        {
            seed = seed * 1664525u + 1013904223u;
            return (float)((seed >> 8) & 0xFFFFu) / 65535.0f;
        }

        public func Spawn(cx: float, cy: float, cz: float, t: byte, n: int)
        {
            for (int i = 0; i < n; i++)
            {
                if (count >= MAX) return;
                int k = count;
                px[k] = cx; py[k] = cy; pz[k] = cz;
                vx[k] = (Rnd() - 0.5f) * 5.0f;
                vy[k] = Rnd() * 5.0f + 1.5f;
                vz[k] = (Rnd() - 0.5f) * 5.0f;
                life[k] = 0.5f + Rnd() * 0.4f;
                ptype[k] = t;
                count++;
            }
        }

        public func Update(dt: float)
        {
            int w = 0;
            for (int r = 0; r < count; r++)
            {
                vy[r] -= 14.0f * dt;
                px[r] += vx[r] * dt;
                py[r] += vy[r] * dt;
                pz[r] += vz[r] * dt;
                life[r] -= dt;
                if (life[r] > 0.0f)
                {
                    if (w != r)
                    {
                        px[w] = px[r]; py[w] = py[r]; pz[w] = pz[r];
                        vx[w] = vx[r]; vy[w] = vy[r]; vz[w] = vz[r];
                        life[w] = life[r]; ptype[w] = ptype[r];
                    }
                    w++;
                }
            }
            count = w;
        }

        public func Count() -> int => count;

        public func BuildMesh(mb: MeshBuilder)
        {
            for (int i = 0; i < count; i++)
            {
                float s = 0.09f + 0.05f * life[i];
                BlockMesh.AddParticleCube(mb, px[i], py[i], pz[i], s, ptype[i]);
            }
        }
    }
}
