// =============================================================================
//  std.math  —  vectores y utilidades para gráficos y juegos.
//  (Las funciones básicas están en std::Math.)
// =============================================================================
namespace std.math
{
    public struct Vec2
    {
        public double X;
        public double Y;

        public Vec2(double x, double y) { X = x; Y = y; }

        public static Vec2 Zero => new Vec2(0, 0);
        public static Vec2 One => new Vec2(1, 1);

        public static Vec2 operator +(Vec2 a, Vec2 b) => new Vec2(a.X + b.X, a.Y + b.Y);
        public static Vec2 operator -(Vec2 a, Vec2 b) => new Vec2(a.X - b.X, a.Y - b.Y);
        public static Vec2 operator -(Vec2 a) => new Vec2(-a.X, -a.Y);
        public static Vec2 operator *(Vec2 a, double k) => new Vec2(a.X * k, a.Y * k);
        public static Vec2 operator *(double k, Vec2 a) => new Vec2(a.X * k, a.Y * k);
        public static Vec2 operator /(Vec2 a, double k) => new Vec2(a.X / k, a.Y / k);
        public static bool operator ==(Vec2 a, Vec2 b) => a.X == b.X && a.Y == b.Y;

        public double Length => Math.Sqrt(X * X + Y * Y);
        public double LengthSquared => X * X + Y * Y;

        public Vec2 Normalized()
        {
            double len = Length;
            return len == 0 ? new Vec2(0, 0) : new Vec2(X / len, Y / len);
        }

        public static double Dot(Vec2 a, Vec2 b) => a.X * b.X + a.Y * b.Y;
        public static double Cross(Vec2 a, Vec2 b) => a.X * b.Y - a.Y * b.X;
        public static double Distance(Vec2 a, Vec2 b) => (a - b).Length;
        public static Vec2 Lerp(Vec2 a, Vec2 b, double t) => a + (b - a) * t;

        public Vec2 Rotated(double radians)
        {
            double c = Math.Cos(radians), s = Math.Sin(radians);
            return new Vec2(X * c - Y * s, X * s + Y * c);
        }
    }

    public struct Vec3
    {
        public double X;
        public double Y;
        public double Z;

        public Vec3(double x, double y, double z) { X = x; Y = y; Z = z; }

        public static Vec3 Zero => new Vec3(0, 0, 0);
        public static Vec3 Up => new Vec3(0, 1, 0);

        public static Vec3 operator +(Vec3 a, Vec3 b) => new Vec3(a.X + b.X, a.Y + b.Y, a.Z + b.Z);
        public static Vec3 operator -(Vec3 a, Vec3 b) => new Vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
        public static Vec3 operator -(Vec3 a) => new Vec3(-a.X, -a.Y, -a.Z);
        public static Vec3 operator *(Vec3 a, double k) => new Vec3(a.X * k, a.Y * k, a.Z * k);
        public static Vec3 operator *(double k, Vec3 a) => new Vec3(a.X * k, a.Y * k, a.Z * k);
        public static Vec3 operator /(Vec3 a, double k) => new Vec3(a.X / k, a.Y / k, a.Z / k);
        public static bool operator ==(Vec3 a, Vec3 b) => a.X == b.X && a.Y == b.Y && a.Z == b.Z;

        public double Length => Math.Sqrt(X * X + Y * Y + Z * Z);
        public double LengthSquared => X * X + Y * Y + Z * Z;

        public Vec3 Normalized()
        {
            double len = Length;
            return len == 0 ? new Vec3(0, 0, 0) : new Vec3(X / len, Y / len, Z / len);
        }

        public static double Dot(Vec3 a, Vec3 b) => a.X * b.X + a.Y * b.Y + a.Z * b.Z;
        public static Vec3 Cross(Vec3 a, Vec3 b) => new Vec3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X);
        public static double Distance(Vec3 a, Vec3 b) => (a - b).Length;
        public static Vec3 Lerp(Vec3 a, Vec3 b, double t) => a + (b - a) * t;
    }

    public struct Rect
    {
        public double X;
        public double Y;
        public double Width;
        public double Height;

        public Rect(double x, double y, double width, double height)
        {
            X = x;
            Y = y;
            Width = width;
            Height = height;
        }

        public double Left => X;
        public double Top => Y;
        public double Right => X + Width;
        public double Bottom => Y + Height;
        public double Area => Width * Height;
        public Vec2 Center => new Vec2(X + Width / 2, Y + Height / 2);

        public bool Contains(Vec2 p) => p.X >= X && p.X < X + Width && p.Y >= Y && p.Y < Y + Height;

        public bool Intersects(Rect o) => X < o.X + o.Width && o.X < X + Width && Y < o.Y + o.Height && o.Y < Y + Height;
    }

    public static class Interp
    {
        public static double Lerp(double a, double b, double t) => a + (b - a) * t;
        public static double InverseLerp(double a, double b, double v) => a == b ? 0 : (v - a) / (b - a);
        public static double Remap(double v, double inMin, double inMax, double outMin, double outMax) =>
            Lerp(outMin, outMax, InverseLerp(inMin, inMax, v));
        public static double Clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
        public static double SmoothStep(double t)
        {
            double x = Clamp01(t);
            return x * x * (3 - 2 * x);
        }
    }
}
