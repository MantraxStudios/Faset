struct Vec2
{
    public var X: double, Y: double;
    public init(x: double, y: double) { X = x; Y = y; }
    public operator +(a: Vec2, b: Vec2) -> Vec2 => new Vec2(a.X + b.X, a.Y + b.Y);
    public prop Length: double => Math.Sqrt(X * X + Y * Y);
}

func main() -> int
{
    Vec2 v = new Vec2(1, 2) + new Vec2(2, 2);
    println(v.Length);   // 5
    return 0;
}
