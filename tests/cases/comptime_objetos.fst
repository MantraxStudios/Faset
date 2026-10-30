// comptime que devuelve objetos de clases y structs propios: se crean sin constructor con los
// valores de sus campos (también heredados, protegidos, listas y otros objetos).
using std;
using std.collections;

public struct Punto
{
    public int X;
    public int Y;
    public Punto(int x, int y) { X = x; Y = y; }
    public override string ToString() => $"({X}, {Y})";
}

public class Base
{
    protected string nombre = "base";
    public string Nombre => nombre;
    public virtual string Que() => "Base";
}

public class Tabla : Base
{
    int[] nada;
    List<int> cuadrados = new List<int>();
    public Punto Esquina { get; private set; }
    public Tabla Siguiente;
    public double Factor = 1.5;
    public Color Color { get; set; } = Color.Verde;
    public Tabla(int n)
    {
        nombre = "tabla " + n;
        for (int i = 0; i < n; i++) cuadrados.Add(i * i);
        Esquina = new Punto(n, -n);
    }
    public int Suma() { int s = 0; foreach (int c in cuadrados) s += c; return s; }
    public int Cuenta => cuadrados.Count;
    public override string Que() => "Tabla";
}
public enum Color { Rojo, Verde }

comptime Tabla Hacer()
{
    Tabla t = new Tabla(5);
    t.Siguiente = new Tabla(2);
    t.Factor = 0.25;
    return t;
}

class Program
{
    static readonly Tabla Global = comptime Hacer();
    static void Main()
    {
        Punto p = comptime new Punto(3, 4);
        Console.WriteLine($"{p}");
        Tabla t = comptime Hacer();
        Console.WriteLine($"{t.Nombre} {t.Suma()} {t.Cuenta} {t.Esquina} {t.Factor} {t.Color} {t.Que()}");
        Console.WriteLine($"{t.Siguiente.Nombre} {t.Siguiente.Suma()} {t.Siguiente.Siguiente == null}");
        Base b = t;
        Console.WriteLine(b.Que() + " " + (b is Tabla) + " " + Global.Cuenta);
        t.Factor = 9;
        Tabla otra = comptime Hacer();
        Console.WriteLine(otra.Factor);
    }
}
