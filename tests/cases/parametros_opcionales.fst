// Parámetros opcionales, argumentos con nombre (con el orden de evaluación del código) y
// [CallerMemberName] / [CallerLineNumber] / [CallerFilePath].
using std.collections;

enum Color { Rojo, Verde, Azul }

class Registro
{
    public static int Contador = 0;
    public static int Siguiente(string que) { Contador++; println("evalúa " + que); return Contador; }
}

const int Defecto = 40;

void F(int x = 0, string s = "a", Color c = Color.Rojo) => println($"F({x}, {s}, {c.ToString()})");
void G(int a, int b, int c = 0) => println($"G({a}, {b}, {c})");
int Sumar(int a, int b = 10) => a + b;
int Sumar(int a, int b, int c = 100) => a + b + c;
long Grande(long v = Defecto + 2, double d = -1.5, bool b = true, char ch = 'z', string? t = null) => v;
void Log(string msg, [CallerMemberName] string miembro = "", [CallerLineNumber] int linea = 0) => println($"{miembro}:{linea}: {msg}");
bool Archivo([CallerFilePath] string ruta = "") => ruta.EndsWith("parametros_opcionales.fst");

class Base
{
    public int V;
    public Base(int v = 7, string etiqueta = "base") { V = v; println($"Base({v}, {etiqueta})"); }
}

class Derivada : Base
{
    public Derivada() : base(etiqueta: "derivada") { }
    public Derivada(int x) : this() { V = x; }
    public string Saluda(string nombre = "mundo", int veces = 1)
    {
        string r = "";
        for (int i = 0; i < veces; i++) r += "hola " + nombre + ";";
        return r;
    }
    public void Traza() => Log("traza");
}

class SinParametros : Base
{
    // base() implícito: el constructor de Base solo tiene parámetros opcionales
    public SinParametros() { println("SinParametros"); }
}

static class Ext
{
    public static string Repite(this string s, int n = 2, string sep = "")
    {
        string r = "";
        for (int i = 0; i < n; i++) r += (i > 0 ? sep : "") + s;
        return r;
    }
}

delegate int Op(int a, int b);

T Ident<T>(T v, int extra = 0) => v;

int Lista(string titulo = "lista", params int[] xs) => xs.Count;

void main()
{
    F();
    F(5);
    F(5, "b");
    F(s: "b");
    F(c: Color.Azul, x: 3);
    F(1, c: Color.Verde);
    F(x: 2, "c");  // con nombre en su posición: puede seguir uno sin nombre
    // Los argumentos se evalúan en el orden del código aunque se reordenen.
    G(b: Registro.Siguiente("b"), a: Registro.Siguiente("a"));
    G(c: Registro.Siguiente("c"), b: Registro.Siguiente("b"), a: Registro.Siguiente("a"));
    println(Sumar(1));
    println(Sumar(1, 2));       // gana la sobrecarga sin valores por defecto
    println(Sumar(1, 2, 3));
    println(Sumar(b: 5, a: 1));
    println(Grande());
    println(Grande(t: "x", v: 1));
    Log("hola");
    println(Archivo());
    var d = new Derivada();
    println(d.V);
    var d2 = new Derivada(42);
    println(d2.V);
    var b = new Base(etiqueta: "x");
    var s = new SinParametros();
    println(s.V);
    println(d.Saluda());
    println(d.Saluda(veces: 2));
    println(d.Saluda(veces: 2, nombre: "Ana"));
    d.Traza();
    println("ab".Repite());
    println("ab".Repite(sep: "-", n: 3));
    Op o = (p, q) => p - q;
    println(o(10, 3));
    println(Ident("s"));
    println(Ident(v: 3));
    println(Lista());
    println(Lista("n", 1, 2, 3));
    Func<int, int> lam = x => { Log("en lambda"); return x; };
    lam(1);
}
