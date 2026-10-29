// foreach: List, Dictionary (KeyValuePair y deconstrucción), HashSet, Stack, Span, string
// (caracteres Unicode), tipos del usuario con GetEnumerator(), break/continue y genéricos.
using std.collections;
using std.mem;

// Enumerador propio: cualquier tipo con GetEnumerator() -> { bool MoveNext(); T Current; }
struct Rango
{
    int desde, hasta;
    public Rango(int a, int b) { desde = a; hasta = b; }
    public RangoEnumerador GetEnumerator() => new RangoEnumerador(desde, hasta);
}

struct RangoEnumerador
{
    int actual, fin;
    public RangoEnumerador(int a, int b) { actual = a - 1; fin = b; }
    public int Current => actual;
    public bool MoveNext()
    {
        actual++;
        return actual <= fin;
    }
}

class Inventario
{
    List<string> cosas = new List<string>();
    public void Agregar(string c) { cosas.Add(c); }
    public ListEnumerator<string> GetEnumerator() => cosas.GetEnumerator();
}

T Suma<T>(List<T> xs)
{
    T s = default(T);
    foreach (T x in xs) s += x;
    return s;
}

void main()
{
    List<int> nums = new List<int>();
    for (int i = 1; i <= 6; i++) nums.Add(i * i);
    foreach (var n in nums) print(n + " ");
    println();

    // break / continue
    foreach (int n in nums)
    {
        if (n % 2 == 0) continue;
        if (n > 20) break;
        print(n + " ");
    }
    println();

    // anidado y con tipo explícito convertible (int -> long)
    long total = 0;
    foreach (long n in nums)
        foreach (char c in "ab") total += n;
    println("total " + total);

    // string: caracteres (puntos de código), no bytes
    int cuenta = 0;
    foreach (char c in "año€😀") { print(c + "|"); cuenta++; }
    println(" " + cuenta + " caracteres");
    foreach (var c in "") println("nunca");

    // Dictionary: KeyValuePair y deconstrucción
    Dictionary<string, int> edades = new Dictionary<string, int>();
    edades["Ana"] = 30;
    edades["Luis"] = 25;
    edades["Eva"] = 41;
    int suma = 0;
    foreach (var kv in edades) suma += kv.Value;
    println("suma de edades " + suma);
    List<string> claves = new List<string>();
    foreach (var (nombre, edad) in edades)
        if (edad > 26) claves.Add(nombre);
    claves.Sort();
    foreach (var k in claves) print(k + " ");
    println();
    foreach ((string nombre, int edad) in edades)
        if (nombre == "Luis") println("Luis tiene " + edad);

    // HashSet y Stack
    HashSet<int> conjunto = new HashSet<int>();
    conjunto.Add(5); conjunto.Add(7); conjunto.Add(5);
    int sc = 0;
    foreach (int x in conjunto) sc += x;
    println("conjunto " + sc);
    Stack<string> pila = new Stack<string>();
    pila.Push("a"); pila.Push("b");
    foreach (var s in pila) print(s);
    println();

    // Span<T>
    memory_unsafe
    {
        int* datos = new int[4];
        for (int i = 0; i < 4; i++) datos[i] = 10 * i;
        Span<int> vista = new Span<int>(datos, 4);
        foreach (int v in vista.Slice(1)) print(v + " ");
        println();
    }

    // Tipos del usuario
    foreach (int i in new Rango(3, 6)) print(i);
    println();
    Inventario inv = new Inventario();
    inv.Agregar("espada");
    inv.Agregar("escudo");
    foreach (string cosa in inv) println("- " + cosa);

    // Genérico
    println("suma genérica " + Suma<int>(nums) + " " + Suma<double>(new List<double>()));

    // Cada vuelta tiene su propia variable: se puede volver a declarar fuera
    foreach (var n in nums) { int doble = n * 2; }
    int doble = 1;
    println("fin " + doble);
}
