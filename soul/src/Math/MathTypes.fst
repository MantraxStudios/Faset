// =============================================================================
//  Soul - math types.
//
//  Vec3 and column-major 4x4 matrices (the layout GLSL/Vulkan expect). Matrices
//  are plain 16-float buffers (float*) so they can be pushed straight into a
//  push-constant block. Element (row r, col c) lives at index c*4 + r.
// =============================================================================
using std;

namespace Soul.Math3
{
    public struct Vec3
    {
        public var x: float
        public var y: float
        public var z: float

        public init(x: float, y: float, z: float) { this.x = x; this.y = y; this.z = z; }

        public static Vec3 operator +(Vec3 a, Vec3 b) => new Vec3(a.x + b.x, a.y + b.y, a.z + b.z);
        public static Vec3 operator -(Vec3 a, Vec3 b) => new Vec3(a.x - b.x, a.y - b.y, a.z - b.z);
        public static Vec3 operator *(Vec3 a, float s) => new Vec3(a.x * s, a.y * s, a.z * s);

        public func Dot(b: Vec3) -> float => x * b.x + y * b.y + z * b.z;
        public func Length() -> float => (float)Math.Sqrt((double)(x * x + y * y + z * z));

        public func Cross(b: Vec3) -> Vec3
            => new Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x);

        public func Normalized() -> Vec3
        {
            float len = Length();
            if (len < 0.000001f) return new Vec3(0.0f, 0.0f, 0.0f);
            float inv = 1.0f / len;
            return new Vec3(x * inv, y * inv, z * inv);
        }
    }

    public memory_unsafe static class Mat
    {
        public static func Identity(m: float*)
        {
            for (int i = 0; i < 16; i++) m[i] = 0.0f;
            m[0] = 1.0f; m[5] = 1.0f; m[10] = 1.0f; m[15] = 1.0f;
        }

        // out = a * b  (column-major). 'out' must not alias 'a' or 'b'.
        public static func Mul(a: float*, b: float*, dst: float*)
        {
            for (int c = 0; c < 4; c++)
                for (int r = 0; r < 4; r++)
                {
                    float sum = 0.0f;
                    for (int k = 0; k < 4; k++)
                        sum += a[k * 4 + r] * b[c * 4 + k];
                    dst[c * 4 + r] = sum;
                }
        }

        // Right-handed perspective with Vulkan clip space (depth 0..1, Y flipped
        // so +Y is up in world space).
        public static func Perspective(fovYRad: float, aspect: float, znear: float, zfar: float, m: float*)
        {
            float f = 1.0f / (float)Math.Tan((double)(fovYRad * 0.5f));
            for (int i = 0; i < 16; i++) m[i] = 0.0f;
            m[0]  = f / aspect;
            m[5]  = -f;                              // flip Y for Vulkan
            m[10] = zfar / (znear - zfar);
            m[11] = -1.0f;
            m[14] = (zfar * znear) / (znear - zfar);
        }

        // Right-handed look-at (camera looks down -Z).
        public static func LookAt(eye: Vec3, center: Vec3, up: Vec3, m: float*)
        {
            Vec3 fwd = (center - eye).Normalized();
            Vec3 s   = fwd.Cross(up).Normalized();
            Vec3 u   = s.Cross(fwd);

            Mat.Identity(m);
            m[0] = s.x;   m[4] = s.y;   m[8]  = s.z;
            m[1] = u.x;   m[5] = u.y;   m[9]  = u.z;
            m[2] = -fwd.x; m[6] = -fwd.y; m[10] = -fwd.z;
            m[12] = -s.Dot(eye);
            m[13] = -u.Dot(eye);
            m[14] = fwd.Dot(eye);
        }

        // Right-handed orthographic projection, Vulkan clip space (depth 0..1).
        public static func Ortho(l: float, r: float, b: float, t: float, znear: float, zfar: float, m: float*)
        {
            for (int i = 0; i < 16; i++) m[i] = 0.0f;
            m[0]  = 2.0f / (r - l);
            m[5]  = 2.0f / (t - b);
            m[10] = -1.0f / (zfar - znear);
            m[12] = -(r + l) / (r - l);
            m[13] = -(t + b) / (t - b);
            m[14] = -znear / (zfar - znear);
            m[15] = 1.0f;
        }

        public static func Translate(x: float, y: float, z: float, m: float*)
        {
            Mat.Identity(m);
            m[12] = x; m[13] = y; m[14] = z;
        }

        public static func RotateY(angleRad: float, m: float*)
        {
            float c = (float)Math.Cos((double)angleRad);
            float s = (float)Math.Sin((double)angleRad);
            Mat.Identity(m);
            m[0] = c; m[2] = -s; m[8] = s; m[10] = c;
        }
    }
}
