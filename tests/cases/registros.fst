// Registros: record / record class / record struct, igualdad por valor, ToString, GetHashCode,
// expresiones 'with', registros genéricos y con miembros propios.
using std.collections;

record Punto(int X, int Y);

record class Persona(string Nombre, int Edad)
{
    public bool EsAdulta => Edad >= 18;
    public string Saludo() => "Hola, soy " + Nombre;
}

record struct Color(byte R, byte G, byte B);

record Par<T>(T A, T B);

enum Palo { Oros, Copas }

record Carta(int Numero, Palo Palo, bool Figura, double Peso, Punto Pos);

record Contador
{
    public int N { get; set; }
}

record Vacio;

void Main()
{
    Punto p = new Punto(1, 2);
    Punto q = new Punto(1, 2);
    Punto r = p with { Y = 5 };
    Console.WriteLine(p);
    Console.WriteLine(r.ToString());
    Console.WriteLine(p == q);
    Console.WriteLine(p != r);
    Console.WriteLine(p.Equals(q));
    object o = q;
    Console.WriteLine(p.Equals(o));
    Console.WriteLine(p.GetHashCode() == q.GetHashCode());
    Console.WriteLine(p.X + p.Y);
    Console.WriteLine(r.Y + " " + p.Y);  // 'with' crea una copia
    Punto nulo = null;
    Console.WriteLine(nulo == null);
    Console.WriteLine(p == nulo);

    Persona ana = new Persona("Ana", 30);
    Persona joven = ana with { Edad = 12 };
    Console.WriteLine(ana + " / " + joven);
    Console.WriteLine(ana.EsAdulta + " " + joven.EsAdulta + " " + joven.Saludo());
    Console.WriteLine(ana == new Persona("Ana", 30));

    Color rojo = new Color(255, 0, 0);
    Color otro = rojo with { B = 10 };
    Console.WriteLine(rojo.ToString());  // struct: sin boxing, ToString() explícito
    Console.WriteLine(otro.ToString());
    Console.WriteLine(rojo == new Color(255, 0, 0));
    Console.WriteLine(rojo == otro);
    Console.WriteLine(rojo.GetHashCode() == new Color(255, 0, 0).GetHashCode());

    Par<string> par = new Par<string>("x", "y");
    Console.WriteLine(par);
    Console.WriteLine(par == new Par<string>("x", "y"));
    Par<int> pi = new Par<int>(3, 4) with { A = 9 };
    Console.WriteLine(pi);

    Carta c1 = new Carta(7, Palo.Copas, false, 1.5, new Punto(0, 1));
    Carta c2 = new Carta(7, Palo.Copas, false, 1.5, new Punto(0, 1));
    Console.WriteLine(c1);
    Console.WriteLine(c1 == c2);  // Pos se compara con Equals (valor)
    Console.WriteLine(c1 == (c2 with { Pos = new Punto(9, 9) }));

    Contador k = new Contador();
    k.N = 4;
    Contador k2 = k with { N = 8 };
    Console.WriteLine(k + " " + k2 + " " + (k == k2));
    Console.WriteLine(new Vacio() == new Vacio());
    Console.WriteLine(new Vacio());
    Console.WriteLine(typeof(Punto).IsRecord);

    List<Punto> puntos = new List<Punto>();
    puntos.Add(new Punto(3, 3));
    Console.WriteLine(puntos.Contains(new Punto(3, 3)));
}
