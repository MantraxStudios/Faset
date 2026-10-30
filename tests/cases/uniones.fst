// Tipos algebraicos (union): construcción, patrones con deconstrucción, exhaustividad,
// ToString / == / GetHashCode generados, métodos, uniones genéricas y recursivas.
using std;
using std.collections;

union Forma
{
    Circulo(double Radio),
    Rect(double Ancho, double Alto),
    Punto;

    public double Area() => this switch
    {
        Circulo(var r) => 3.0 * r * r,
        Rect(var a, var h) => a * h,
        Punto => 0,
    };

    public string Nombre => this match { Circulo => "círculo", Rect => "rectángulo", _ => "punto" };
}

union Arbol<T>
{
    Hoja(T Valor),
    Nodo(Arbol<T> Izq, Arbol<T> Der)
}

union Expr
{
    Num(int V),
    Suma(Expr A, Expr B),
    Mul(Expr A, Expr B),
    Neg(Expr E)
}

record Pedido(string Cliente, Forma Pieza);

enum Color { Rojo, Verde }

class Programa
{
    static string Describir(Forma f) => f switch
    {
        Forma.Circulo(var r) when r > 10 => "círculo grande",
        Forma.Circulo(var r) => $"círculo de radio {r}",
        Rect { Ancho: > 10 } => "rectángulo ancho",
        Rect(var a, var h) => $"rectángulo {a}x{h}",
        Forma.Punto => "punto",
    };

    static int Suma<T>(Arbol<T> a, Func<T, int> f) => a switch
    {
        Arbol<T>.Hoja(var v) => f(v),
        Arbol<T>.Nodo(var i, var d) => Suma(i, f) + Suma(d, f),
    };

    static int Eval(Expr e) => e match
    {
        Num(var v) => v,
        Suma(var a, var b) => Eval(a) + Eval(b),
        Mul(var a, var b) => Eval(a) * Eval(b),
        Neg(var x) => -Eval(x),
    };

    static string Ver(Expr e) => e switch
    {
        Num(var v) => $"{v}",
        Suma(var a, var b) => $"({Ver(a)} + {Ver(b)})",
        Mul(var a, var b) => $"{Ver(a)} * {Ver(b)}",
        Neg(Num(var v)) => $"-{v}",
        Neg(var x) => $"-({Ver(x)})",
    };

    static void Main()
    {
        Forma c = Forma.Circulo(2);
        Forma r = Forma.Rect(3, 4);
        Forma p = Forma.Punto;
        println(c.ToString());
        println(r.ToString());
        println(p.ToString());
        println(c.Area() + r.Area() + p.Area());
        println(c.Nombre + " " + r.Nombre + " " + p.Nombre);
        println(Describir(Forma.Circulo(20)));
        println(Describir(c));
        println(Describir(Forma.Rect(11, 1)));
        println(Describir(r));
        println(Describir(p));

        // Igualdad estructural y hash.
        println(c == Forma.Circulo(2));
        println(c == Forma.Circulo(3));
        println(c != r);
        println(p == Forma.Punto);
        println(c.Equals(Forma.Circulo(2)));
        println(c.GetHashCode() == Forma.Circulo(2).GetHashCode());
        println(c.GetHashCode() == r.GetHashCode());

        // 'is' con deconstrucción.
        if (r is Forma.Rect(var ancho, _)) println($"ancho {ancho}");
        if (c is not Forma.Rect) println("c no es un rectángulo");
        if (c is Circulo(> 1)) println("radio mayor que 1");
        println(p is Forma.Punto);

        // 'switch' de sentencia exhaustivo.
        var tres = new List<Forma>();
        tres.Add(c);
        tres.Add(r);
        tres.Add(p);
        foreach (var f in tres)
        {
            switch (f)
            {
                case Forma.Circulo(var radio):
                    println($"caso círculo {radio}");
                    break;
                case Forma.Rect rr:
                    println("caso rect " + rr.ToString());
                    break;
                case Forma.Punto:
                    println("caso punto");
                    break;
            }
        }

        // Genéricas y recursivas.
        var arbol = Arbol<string>.Nodo(Arbol<string>.Hoja("ab"), Arbol<string>.Nodo(Arbol<string>.Hoja("cde"), Arbol<string>.Hoja("f")));
        println(Suma(arbol, s => s.Length));
        println(Arbol<int>.Hoja(7).ToString());

        Expr e = Expr.Suma(Expr.Num(2), Expr.Mul(Expr.Num(3), Expr.Neg(Expr.Num(4))));
        println(Eval(e));
        println(Ver(e));
        println(e.ToString());
        println(Expr.Neg(Expr.Num(1)) == Expr.Neg(Expr.Num(1)));

        // Uniones dentro de registros.
        var pedido = new Pedido("Ana", Forma.Rect(2, 5));
        println(pedido.ToString());
        string desc = pedido switch
        {
            { Pieza: Forma.Rect(var a, _) } when a > 1 => "pedido de rectángulo ancho",
            { Pieza: Forma.Rect } => "pedido de rectángulo",
            _ => "otro pedido",
        };
        println(desc);
        var p2 = pedido with { Pieza = Forma.Punto };
        println(p2.Pieza.ToString());

        // Copias por valor.
        Forma copia = c;
        copia = Forma.Punto;
        println(c.ToString());

        // Listas de uniones.
        var formas = new List<Forma>();
        formas.Add(Forma.Circulo(1));
        formas.Add(Forma.Rect(2, 2));
        formas.Add(Forma.Punto);
        formas.Add(Forma.Rect(1, 3));
        double total = 0;
        foreach (var f in formas) total += f.Area();
        println(total);
        println(formas.Count(f => f is Forma.Rect));
    }
}
