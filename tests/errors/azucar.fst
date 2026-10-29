// Errores del azúcar sintáctico: mensajes en español con la línea correcta.
using std.collections;

struct Punto
{
    public int X;
}

class Caja
{
    public int Valor;
}

int Sumar(params int[] xs) => xs.Count;
void Mal(params int xs, int y) { }

void main()
{
    Punto p = new Punto();
    foreach (var x in 42) { }
    int n = 5;
    int r = n ?? 3;
    Caja c = new Caja();
    int v = n?.ToString().Length;
    string s = $"{p}";
    string f = $"{"texto":F2}";
    string g = $"{n:Q9}";
    int? q = 3;
    int w = q + 1;
    var (a, b) = (1, 2, 3);
    var t = (1, null);
    (int, int) par = (1, "dos");
    int d = n switch { 1 => "uno", _ => 2 };
    string e = n switch { 1 => "uno", _ => "otro", 2 => "dos" };
    bool k = c is Punto;
    Sumar(1, "dos");
    n ??= 4;
    var z = default;
}
