// Errores de los parámetros 'comptime'.
using std;
class Base { public virtual int V(comptime int n) => n; }
class Q
{
    public Q(comptime int n) { }
    static int A(comptime object o) => 1;
    static int B(comptime ref int n) => 1;
    static int C(comptime int n) { n = 3; return n; }
    static int F(int x, comptime int n) => x + n;
    static int G(comptime int n) => n == 0 ? 0 : G(n - 1);
    static long Potencia(long x, comptime int n)
    {
        static_assert(n >= 0, "el exponente no puede ser negativo");
        comptime if (n == 0) return 1;
        else return x * Potencia(x, n - 1);
    }
    static void Main()
    {
        int k = 3;
        println(F(1, k));
        Func<int, int, int> d = F;
        println(C(1));
        println(G(2));
        println(Potencia(2, -1));
    }
}
