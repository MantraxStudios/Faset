using static NoExiste;
using static std.collections.List;

class Externa
{
    class Secreta { }
    public class Publica { }
    static Externa() { }
}
// Errores de tipos anidados, 'using static', indizadores y conversiones del usuario.
interface IConStatic { }
class Fuera { public class Dentro { public int A; } int instancia; class Usa { int Lee() => instancia; } }
class Solo
{
    public int this[int i] { get { return i; } }
    public int this[string s] { set { } }
    public static int this[long l] => 0;
}

struct Celsius
{
    public double G;
    public static implicit operator Celsius(double d) => new Celsius();
    public implicit operator double(Celsius c) => c.G;
    public static implicit operator int(string s) => 0;
    public static explicit operator Celsius(double d) => new Celsius();
}

class C2
{
    static C2() { }
}

void main()
{
    var s = new Externa.Secreta();
    var o = new Solo();
    o[1] = 3;
    int v = o["a"];
    int w = o[1, 2];
    Celsius c = "x";
    int n = 5;
    int q = n[1, 2];
    var d = new Fuera.Dentro();
    var e = new Fuera.Nada();
    Celsius k = (Celsius)"y";
}
