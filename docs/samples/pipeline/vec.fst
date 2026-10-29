struct Vec2
{
    public double X, Y;
    public Vec2(double x, double y) { X = x; Y = y; }
    public static Vec2 operator +(Vec2 a, Vec2 b) => new Vec2(a.X + b.X, a.Y + b.Y);
    public double Length => Math.Sqrt(X * X + Y * Y);
}

int main()
{
    Vec2 v = new Vec2(1, 2) + new Vec2(2, 2);
    println(v.Length);   // 5
    return 0;
}
