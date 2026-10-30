// Errores de comptime: límites (pasos, recursión, memoria), pila de llamadas, valores no
// constantes, static_assert y condiciones que no son bool.
using std.collections;

comptime int Bucle(int n)
{
    while (true) n++;
    return n;
}
comptime int Rec(int n) => Rec(n + 1);
comptime int Divide(int a, int b) => a / b;
comptime int Medio(int x) => Divide(x, 0);
comptime int Crece()
{
    List<int> l = new List<int>();
    while (true) l.Add(1);
    return 0;
}

static_assert(1 + 1 == 3, "la aritmética falla");

struct ConCadena { public string S; }
comptime int ConArreglo() { int[] a = [1, 2]; return a[0]; }
comptime int FueraDeRango(List<int> l) => l[5..6][0];

void Main()
{
    int a = Bucle(1);
    int b = Rec(1);
    int c = Medio(4);
    int x = 3;
    int d = comptime x + 1;
    static_assert(false, "dentro de Main");
    comptime if (5) { }
    int e = Crece();
    int f = comptime sizeof(ConCadena);
    comptime foreach (var v in 42) { }
    int g = comptime ConArreglo();
    int h = comptime FueraDeRango([1, 2]);
}
