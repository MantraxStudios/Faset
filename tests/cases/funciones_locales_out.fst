// Funciones locales llamadas antes de su declaración y con recursión mutua, 'out var' / 'out T x'
// y miembros con cuerpo de expresión (constructores, destructores, accesores, operadores).
using std.task;

int Fact(int n)
{
    return Ayuda(n);
    int Ayuda(int k) => k <= 1 ? 1 : k * Ayuda(k - 1);
}

bool Dividir(int a, int b, out int cociente, out int resto)
{
    cociente = b != 0 ? a / b : 0;
    resto = b != 0 ? a % b : 0;
    return b != 0;
}

class P
{
    int x;
    public P(int v) => x = v;
    public P(out string s) { s = "desde el constructor"; x = 0; }
    public int X { get => x; set => x = value; }
    public int Doble => x * 2;
    public static P operator +(P a, P b) => new P(a.x + b.x);
    public int this[int i] { get => x + i; set => x = value - i; }
    public override string ToString() => $"P({x})";
}

async Task<int> Leer(string s)
{
    await Task.Delay(1);
    if (int.TryParse(s, out var n)) { await Task.Delay(1); return n * 2; }
    return -1;
}

void main()
{
    int base_ = 10;
    println(Suma(5));   // antes de su declaración
    int Suma(int x) { return x + base_; }
    void Saluda(string s) => println("hola " + s);
    Saluda("mundo");
    println(Fact(5));
    bool EsPar(int n) => n == 0 ? true : EsImpar(n - 1);
    bool EsImpar(int n) => n == 0 ? false : EsPar(n - 1);
    println(EsPar(10) + " " + EsImpar(7));
    int cont = 0;
    void Inc() { cont++; }
    Inc();
    Inc();
    println(cont);

    if (int.TryParse("12", out var v)) println(v + 1);
    if (!int.TryParse("x", out int malo)) println("no es un número: " + malo);
    Dividir(17, 5, out int c, out var r);
    println($"{c} {r}");
    Dividir(resto: out var r2, cociente: out var c2, a: 9, b: 4);
    println($"{c2} {r2}");
    new P(out var s);
    println(s);
    Func<string, int> f = t => int.TryParse(t, out int k) ? k : 0;
    println(f("41") + 1);
    println(Leer("21").Result);

    var p = new P(2) + new P(3);
    p.X = p.X + 1;
    p[1] = 10;
    println($"{p.ToString()} {p.Doble} {p[5]}");
}
