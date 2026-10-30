// Indizadores (varios parámetros, claves string, sobrecargas, genéricos, en interfaces, op=) y
// conversiones del usuario implicit/explicit en asignaciones, argumentos, casts y sobrecargas.
using std.collections;

class Matriz
{
    List<double> datos = new List<double>();
    public int Filas;
    public int Columnas;
    public Matriz(int f, int c) { Filas = f; Columnas = c; for (int i = 0; i < f * c; i++) datos.Add(0); }
    public double this[int f, int c]
    {
        get => datos[f * Columnas + c];
        set { datos[f * Columnas + c] = value; }
    }
    public double this[int i] => datos[i];
}

class Agenda
{
    Dictionary<string, string> tel = new Dictionary<string, string>();
    public string this[string nombre]
    {
        get { return tel.ContainsKey(nombre) ? tel[nombre] : "?"; }
        set { tel[nombre] = value; }
    }
    public int this[char c] { get { return (int)c; } }
}

class Vector<T>
{
    List<T> xs = new List<T>();
    public void Add(T x) => xs.Add(x);
    public T this[int i] { get { return xs[i]; } set { xs[i] = value; } }
    public int Count => xs.Count;
}

interface ILista
{
    int this[int i] { get; }
}
class Rango : ILista
{
    public int this[int i] => i * 10;
}

struct Celsius
{
    public double Grados;
    public Celsius(double g) { Grados = g; }
    public static implicit operator Celsius(double d) => new Celsius(d);
    public static explicit operator double(Celsius c) => c.Grados;
    public static implicit operator Fahrenheit(Celsius c) => new Fahrenheit(c.Grados * 9 / 5 + 32);
}
struct Fahrenheit
{
    public double Grados;
    public Fahrenheit(double g) { Grados = g; }
}
class Metros
{
    public double V;
    public Metros(double v) { V = v; }
    public static explicit operator Metros(int x) => new Metros(x);
    public static implicit operator string(Metros m) => $"{m.V} m";
}

void Mostrar(Fahrenheit f) => println($"F: {f.Grados}");
void Tipo(int x) => println("int");
void Tipo(Celsius c) => println("Celsius");

void main()
{
    var m = new Matriz(2, 3);
    m[1, 2] = 5.5;
    m[0, 0] += 2;
    m[0, 0] += 1;
    println(m[1, 2]);
    println(m[0, 0]);
    println(m[5]);
    var a = new Agenda();
    a["ana"] = "123";
    println(a["ana"] + " " + a["luis"]);
    println(a['A']);
    var v = new Vector<string> { "x", "y" };
    v[1] = "z";
    println(v[0] + v[1] + v.Count);
    ILista r = new Rango();
    println(r[3]);
    Celsius c = 25.0;
    Celsius c2 = 10;
    double d = (double)c;
    println(d + c2.Grados);
    Fahrenheit f = c;
    println(f.Grados);
    Mostrar(c);
    Tipo(3);
    Tipo(3.5);
    Metros mt = (Metros)7;
    string s = mt;
    println(s);
    println((string)mt);
    var g = new Matriz(1, 1);
    g[0, 0] = 1;
    for (int k = 0; k < 3; k++) g[0, 0] *= 2;
    println(g[0, 0]);
    List<Celsius> temps = new List<Celsius> { 1.5, 2 };   // conversión implícita en Add
    println(temps[0].Grados + temps[1].Grados);
    Celsius Devuelve() => 8.0;                              // y en un return
    println(Devuelve().Grados);
}
