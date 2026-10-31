// =============================================================================
//  Soul - fly camera.
//
//  A yaw/pitch free camera. Yaw rotates around +Y, pitch tilts up/down. The
//  forward vector is derived from the two angles; Right is forward x worldUp.
// =============================================================================
using std;

namespace Soul.Math3
{
    public class Camera
    {
        public var Position: Vec3
        public var Yaw: float      // radians
        public var Pitch: float    // radians

        public init(pos: Vec3)
        {
            Position = pos;
            Yaw = -2.35f;           // look toward -X/-Z (into the world)
            Pitch = -0.35f;         // tilted slightly down
        }

        public func Forward() -> Vec3
        {
            float cp = (float)Math.Cos((double)Pitch);
            return new Vec3((float)Math.Cos((double)Yaw) * cp,
                            (float)Math.Sin((double)Pitch),
                            (float)Math.Sin((double)Yaw) * cp).Normalized();
        }

        public func Right() -> Vec3 => Forward().Cross(new Vec3(0.0f, 1.0f, 0.0f)).Normalized();

        public func Target() -> Vec3 => Position + Forward();
    }
}
