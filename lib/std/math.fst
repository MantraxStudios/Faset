// =============================================================================
//  std.math  —  vectores y utilidades para gráficos y juegos.
//  (Las funciones básicas están en std::Math.)
// =============================================================================
namespace std.math
{
    public struct Vec2
    {
        public var X: double
        public var Y: double

        public init(x: double, y: double) { X = x; Y = y; }

        public static prop Zero: Vec2 => new Vec2(0, 0);
        public static prop One: Vec2 => new Vec2(1, 1);

        public operator +(a: Vec2, b: Vec2) -> Vec2 => new Vec2(a.X + b.X, a.Y + b.Y);
        public operator -(a: Vec2, b: Vec2) -> Vec2 => new Vec2(a.X - b.X, a.Y - b.Y);
        public operator -(a: Vec2) -> Vec2 => new Vec2(-a.X, -a.Y);
        public operator *(a: Vec2, k: double) -> Vec2 => new Vec2(a.X * k, a.Y * k);
        public operator *(k: double, a: Vec2) -> Vec2 => new Vec2(a.X * k, a.Y * k);
        public operator /(a: Vec2, k: double) -> Vec2 => new Vec2(a.X / k, a.Y / k);
        public operator ==(a: Vec2, b: Vec2) -> bool => a.X == b.X && a.Y == b.Y;

        public prop Length: double => Math.Sqrt(X * X + Y * Y);
        public prop LengthSquared: double => X * X + Y * Y;

        public func Normalized() -> Vec2
        {
            let len = Length;
            return len == 0 ? new Vec2(0, 0) : new Vec2(X / len, Y / len);
        }

        public static func Dot(a: Vec2, b: Vec2) -> double => a.X * b.X + a.Y * b.Y;
        public static func Cross(a: Vec2, b: Vec2) -> double => a.X * b.Y - a.Y * b.X;
        public static func Distance(a: Vec2, b: Vec2) -> double => (a - b).Length;
        public static func Lerp(a: Vec2, b: Vec2, t: double) -> Vec2 => a + (b - a) * t;

        public func Rotated(radians: double) -> Vec2
        {
            let c = Math.Cos(radians); let s = Math.Sin(radians);
            return new Vec2(X * c - Y * s, X * s + Y * c);
        }
    }

    public struct Vec3
    {
        public var X: double
        public var Y: double
        public var Z: double

        public init(x: double, y: double, z: double) { X = x; Y = y; Z = z; }

        public static prop Zero: Vec3 => new Vec3(0, 0, 0);
        public static prop Up: Vec3 => new Vec3(0, 1, 0);

        public operator +(a: Vec3, b: Vec3) -> Vec3 => new Vec3(a.X + b.X, a.Y + b.Y, a.Z + b.Z);
        public operator -(a: Vec3, b: Vec3) -> Vec3 => new Vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
        public operator -(a: Vec3) -> Vec3 => new Vec3(-a.X, -a.Y, -a.Z);
        public operator *(a: Vec3, k: double) -> Vec3 => new Vec3(a.X * k, a.Y * k, a.Z * k);
        public operator *(k: double, a: Vec3) -> Vec3 => new Vec3(a.X * k, a.Y * k, a.Z * k);
        public operator /(a: Vec3, k: double) -> Vec3 => new Vec3(a.X / k, a.Y / k, a.Z / k);
        public operator ==(a: Vec3, b: Vec3) -> bool => a.X == b.X && a.Y == b.Y && a.Z == b.Z;

        public prop Length: double => Math.Sqrt(X * X + Y * Y + Z * Z);
        public prop LengthSquared: double => X * X + Y * Y + Z * Z;

        public func Normalized() -> Vec3
        {
            let len = Length;
            return len == 0 ? new Vec3(0, 0, 0) : new Vec3(X / len, Y / len, Z / len);
        }

        public static func Dot(a: Vec3, b: Vec3) -> double => a.X * b.X + a.Y * b.Y + a.Z * b.Z;
        public static func Cross(a: Vec3, b: Vec3) -> Vec3 => new Vec3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X);
        public static func Distance(a: Vec3, b: Vec3) -> double => (a - b).Length;
        public static func Lerp(a: Vec3, b: Vec3, t: double) -> Vec3 => a + (b - a) * t;
    }

    public struct Rect
    {
        public var X: double
        public var Y: double
        public var Width: double
        public var Height: double

        public init(x: double, y: double, width: double, height: double)
        {
            X = x;
            Y = y;
            Width = width;
            Height = height;
        }

        public prop Left: double => X;
        public prop Top: double => Y;
        public prop Right: double => X + Width;
        public prop Bottom: double => Y + Height;
        public prop Area: double => Width * Height;
        public prop Center: Vec2 => new Vec2(X + Width / 2, Y + Height / 2);

        public func Contains(p: Vec2) -> bool => p.X >= X && p.X < X + Width && p.Y >= Y && p.Y < Y + Height;

        public func Intersects(o: Rect) -> bool => X < o.X + o.Width && o.X < X + Width && Y < o.Y + o.Height && o.Y < Y + Height;
    }

    public static class Interp
    {
        public static func Lerp(a: double, b: double, t: double) -> double => a + (b - a) * t;
        public static func InverseLerp(a: double, b: double, v: double) -> double => a == b ? 0 : (v - a) / (b - a);
        public static func Remap(v: double, inMin: double, inMax: double, outMin: double, outMax: double) -> double =>
            Lerp(outMin, outMax, InverseLerp(inMin, inMax, v));
        public static func Clamp01(v: double) -> double => v < 0 ? 0 : (v > 1 ? 1 : v);
        public static func SmoothStep(t: double) -> double
        {
            let x = Clamp01(t);
            return x * x * (3 - 2 * x);
        }
    }
}
