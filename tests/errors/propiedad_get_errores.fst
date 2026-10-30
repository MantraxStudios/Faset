// Una propiedad automática { get; } solo se asigna en un constructor de su propia clase.
class P
{
    public int X { get; }
    public P() { X = 1; }
    public void F() { X = 2; }
}
class Q { public Q(P p) { p.X = 3; } }
class R : P { public R() { X = 4; } }

void Main() { }
