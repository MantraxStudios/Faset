// =============================================================================
//  Soul - voxel raycast.
//
//  Marches a ray through the world in small steps and returns the first solid
//  cell it enters, together with the empty cell just before it (where a new
//  block is placed). Good enough for a short reach; a DDA could replace it later.
// =============================================================================
using std;
using Soul.Math3;

namespace Soul.Game
{
    public struct RayHit
    {
        public var Hit: bool
        public var X: int
        public var Y: int
        public var Z: int
        public var PX: int    // empty cell before the hit (placement target)
        public var PY: int
        public var PZ: int
    }

    public static class Raycast
    {
        public static func Cast(origin: Vec3, dir: Vec3, maxDist: float) -> RayHit
        {
            var hit = new RayHit();
            hit.Hit = false;

            int lastX = (int)Math.Floor((double)origin.x);
            int lastY = (int)Math.Floor((double)origin.y);
            int lastZ = (int)Math.Floor((double)origin.z);

            float t = 0.0f;
            while (t < maxDist)
            {
                float wx = origin.x + dir.x * t;
                float wy = origin.y + dir.y * t;
                float wz = origin.z + dir.z * t;

                int cx = (int)Math.Floor((double)wx);
                int cy = (int)Math.Floor((double)wy);
                int cz = (int)Math.Floor((double)wz);

                if (World.IsSolid(cx, cy, cz))
                {
                    hit.Hit = true;
                    hit.X = cx; hit.Y = cy; hit.Z = cz;
                    hit.PX = lastX; hit.PY = lastY; hit.PZ = lastZ;
                    return hit;
                }

                lastX = cx; lastY = cy; lastZ = cz;
                t += 0.05f;
            }
            return hit;
        }
    }
}
