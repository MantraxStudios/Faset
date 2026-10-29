// Orden de evaluación, como en C#: los operandos y los argumentos se evalúan de izquierda a
// derecha, el receptor antes que los argumentos y, en una asignación, las subexpresiones del
// lado izquierdo antes que el lado derecho. Cada función con efectos anota su nombre en la traza.
// (La salida esperada es la de C#; tests/projects/orden_release compila este archivo con -O2.)
using std.collections;

static class T
{
    public static string Traza = "";
    public static int Contador = 0;

    public static int N(string nombre, int valor)
    {
        Traza = Traza + nombre + ";";
        return valor;
    }

    public static string S(string nombre)
    {
        Traza = Traza + nombre + ";";
        return nombre;
    }

    public static int Incr()
    {
        Contador++;
        return Contador;
    }

    public static void Ver(string titulo)
    {
        println(titulo + " -> " + Traza);
        Traza = "";
    }
}

class Caja
{
    public int Valor;
    public string Texto = "a";
    int prop = 100;
    public event Action<int> Cambio;

    public int Siguiente()
    {
        Valor += 10;
        return Valor;
    }

    public string Etiqueta()
    {
        Valor++;
        return "t" + Valor;
    }

    public string Leer()
    {
        Texto = "X";
        return "b";
    }

    public int Prop
    {
        get { T.S("get"); return prop; }
        set { T.S("set"); prop = value; }
    }

    public void Avisar(int v) { Cambio(v); }
}

class Eco
{
    public string Nombre;
    public Eco(string n) { Nombre = n; }
    public string Di(string a, string b) => Nombre + ":" + a + b;
}

class Nombrado
{
    string n;
    public Nombrado(string nombre) { n = nombre; }
    public override string ToString()
    {
        T.S("ts-" + n);
        return n;
    }
}

struct Punto
{
    public int X;
    public Punto(int x) { X = x; }
    public int Suma(int a) => X * 10 + a;
}

class Soporte
{
    public Punto P = new Punto(1);
    public int Mover()
    {
        P.X = 5;
        return 2;
    }
}

class Par
{
    public int A, B;
    public Par(int a, int b) { A = a; B = b; }
}

record Registro(int X, int Y);

int Tres(int a, int b, int c) => a * 100 + b * 10 + c;

Eco Obtener(string n)
{
    T.S("recv-" + n);
    return new Eco(n);
}

Caja cajaGlobal = new Caja();

Caja LaCaja(string n)
{
    T.S(n);
    return cajaGlobal;
}

List<int> Lista(string n, List<int> l)
{
    T.S(n);
    return l;
}

Func<int, int, int> Delegado()
{
    T.S("delegado");
    return (a, b) => a * 10 + b;
}

Action<int> Manejador()
{
    T.S("manejador");
    return v => println("evento " + v);
}

int Doblar(ref int v)
{
    v *= 2;
    return v;
}

Registro Original()
{
    T.S("orig");
    return new Registro(1, 2);
}

int main()
{
    // Operadores binarios
    int r1 = T.N("a", 1) + T.N("b", 2) * T.N("c", 3);
    println("binario " + r1);
    T.Ver("binario");
    int r2 = T.N("m", 7) - T.N("n", 2) - T.N("o", 1);
    println("resta " + r2 + " " + (T.N("p", 8) / T.N("q", 2)) + " " + (T.N("r", 9) % T.N("s", 4)));
    T.Ver("resta");
    bool cmp = T.N("l1", 1) < T.N("l2", 2) == (T.N("l3", 3) != T.N("l4", 3));
    println("comparaciones " + cmp);
    T.Ver("comparaciones");

    // Un campo leído antes (o después) de una llamada que lo cambia
    Caja c = new Caja();
    c.Valor = 1;
    int x = c.Valor + c.Siguiente();
    int y = c.Siguiente() + c.Valor;
    println("campo " + x + " " + y);
    T.Contador = 1;
    int z1 = T.Contador + T.Incr();
    int z2 = T.Incr() + T.Contador;
    println("estatico " + z1 + " " + z2);

    // Concatenación de cadenas (con efectos a los dos lados)
    string s1 = c.Etiqueta() + " " + c.Etiqueta();
    string s2 = c.Valor + " " + c.Siguiente();
    println("concatenacion " + s1 + " | " + s2);
    Nombrado uno = new Nombrado("uno"), dos = new Nombrado("dos");
    string s3 = uno + " y " + dos;
    println("tostring " + s3);
    T.Ver("tostring");

    // Argumentos de funciones, métodos, constructores y delegados (y el receptor primero)
    int a1 = Tres(T.N("x", 1), T.N("y", 2), T.N("z", 3));
    int a2 = Tres(T.N("a", 1), Tres(T.N("b", 2), T.N("c", 3), T.N("d", 4)), T.N("e", 5));
    println("argumentos " + a1 + " " + a2);
    T.Ver("argumentos");
    string d1 = Obtener("e").Di(T.S("1"), T.S("2"));
    println("receptor " + d1);
    T.Ver("receptor");
    Soporte so = new Soporte();
    println("receptor struct " + so.P.Suma(so.Mover()));
    Par par = new Par(T.N("p1", 1), T.N("p2", 2));
    Punto pu = new Punto(T.N("k", 3));
    println("constructor " + par.A + par.B + " " + pu.X);
    T.Ver("constructor");
    Func<int, int, int> f = (p, q) => p * 10 + q;
    int dl1 = f(T.N("d1", 1), T.N("d2", 2));
    int dl2 = Delegado()(T.N("d3", 3), T.N("d4", 4));
    println("delegado " + dl1 + " " + dl2);
    T.Ver("delegado");

    // Cadenas interpoladas
    c.Valor = 0;
    string i1 = $"{T.S("i1")}-{T.N("i2", 2)}-{c.Valor}-{c.Siguiente()}-{c.Valor}";
    println("interpolada " + i1);
    T.Ver("interpolada");

    // Índices y asignaciones
    List<int> lista = new List<int>();
    lista.Add(0);
    lista.Add(0);
    lista.Add(0);
    int i = 0;
    lista[i++] = i;
    lista[T.N("idx", 1)] += T.N("val", 5);
    lista[i] = i++;
    println("indices " + lista[0] + " " + lista[1] + " " + lista[2] + " i=" + i);
    T.Ver("indices");
    lista[2] = 3;
    int le = Lista("L", lista)[T.N("pos", 2)];
    lista[T.N("sh", 2)] <<= 3;
    println("lectura " + le + " " + lista[2]);
    T.Ver("lectura");
    List<string> nombres = new List<string>();
    nombres.Add("n");
    nombres[T.N("k", 0)] += "!";
    nombres[T.N("k2", 0)] += T.S("?");
    println("cadena += " + nombres[0]);
    T.Ver("cadena +=");

    // Asignación compuesta: el valor anterior se lee antes que el lado derecho
    Caja c2 = new Caja();
    c2.Texto += c2.Leer();
    c2.Valor = 1;
    c2.Valor += c2.Siguiente();
    println("compuesta " + c2.Texto + " " + c2.Valor);
    LaCaja("caja").Prop += T.N("rhs", 5);
    println("propiedad " + cajaGlobal.Prop);
    T.Ver("propiedad");
    LaCaja("fuente").Cambio += Manejador();
    T.Ver("evento");
    cajaGlobal.Avisar(7);

    // Variables que cambian dentro de la misma expresión
    int v = 5;
    v = v++;
    int j = 1;
    j = j++ + ++j;
    int k = 1;
    Func<int> inc = () => { k += 1; return k; };
    int w = k + inc();
    int m = 3;
    int w2 = m + Doblar(ref m);
    println("variables " + v + " " + j + " " + w + " " + w2);

    // Tuplas, deconstrucción y 'with'
    var t = (T.N("t1", 1), T.N("t2", 2), T.S("t3"));
    var (p1, p2) = (T.N("u1", 10), T.N("u2", 20));
    (p1, p2) = (p2, p1);
    println("tuplas " + t + " " + p1 + " " + p2);
    T.Ver("tuplas");
    Registro reg = Original() with { Y = T.N("w1", 7), X = T.N("w2", 8) };
    println("with " + reg.X + " " + reg.Y);
    T.Ver("with");
    return 0;
}
