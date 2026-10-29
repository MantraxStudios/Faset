using std.collections;

interface IForma
{
    double Area();
    string Nombre { get; }
}

abstract class Forma : IForma
{
    public abstract double Area();
    public virtual string Nombre => "forma";
    public override string ToString() => $"{Nombre} ({Area():F1})";
}

class Circulo : Forma
{
    double r;
    public Circulo(double r) { this.r = r; }
    public override double Area() => 3.14159 * r * r;
    public override string Nombre => "círculo";
}

class Rect : Forma
{
    protected double w, h;
    public Rect(double w, double h) { this.w = w; this.h = h; }
    public override double Area() => w * h;
    public override string Nombre => "rectángulo";
}

class Cuadrado : Rect
{
    public Cuadrado(double l) : base(l, l) { }
    public override string Nombre => "cuadrado";
}

record Punto(int X, int Y);

class FormaInvalida : Exception
{
    public FormaInvalida(string m) : base(m) { }
}

static string Describir(Forma f) => f switch
{
    Cuadrado c => $"un cuadrado de área {c.Area()}",
    Circulo { Nombre: "círculo" } => "un círculo",
    Rect r when r.Area() > 10 => "un rectángulo grande",
    _ => "otra forma",
};

int main()
{
    var formas = new List<Forma>();
    formas.Add(new Circulo(1));
    formas.Add(new Rect(2, 3));
    formas.Add(new Cuadrado(2));
    formas.Add(new Rect(5, 5));
    foreach (var f in formas) println($"{f} -> {Describir(f)}");

    // lambdas sobre interfaces + LINQ
    List<IForma> ifs = new List<IForma>();
    foreach (var f in formas) ifs.Add(f);
    var grandes = ifs.Where(f => f.Area() > 4).Select(f => f.Nombre);
    foreach (var n in grandes) Console.Write(n + " ");
    println("");

    // is / as
    Forma x = formas[2];
    if (x is Rect rr) println($"es Rect: {rr.Area()}");
    Circulo? noes = x as Circulo;
    println(noes == null ? "no es círculo" : "círculo");

    // excepción propia que hereda de Exception
    try { throw new FormaInvalida("lado negativo"); }
    catch (FormaInvalida e) { println($"capturada {e.GetType().Name}: {e.Message}"); }
    catch (Exception e) { println("genérica"); }

    // record + with + typeof
    var p = new Punto(1, 2);
    var q = p with { Y = 5 };
    println($"{p} {q} iguales={p == new Punto(1, 2)}");
    println(typeof(Cuadrado).BaseType.Name);
    return 0;
}
