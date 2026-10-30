// Parámetros 'comptime': una versión del método por cada valor de esos argumentos.
using std;
using std.collections;

enum Modo { Rapido, Saturado }

class Caja<T>
{
    public T Valor;
    public Caja(T v) { Valor = v; }
    public string Mostrar(comptime string sep) => sep + Valor + sep;
}

class Programa
{
    // Se desenrolla al compilar: Potencia(x, 3) queda en x * x * x * 1.
    static long Potencia(long x, comptime int n)
    {
        static_assert(n >= 0, "el exponente no puede ser negativo");
        comptime if (n == 0) return 1;
        else return x * Potencia(x, n - 1);
    }

    static string Repetir(string s, comptime int veces)
    {
        string r = "";
        comptime foreach (var i in Rango(veces)) r += s;
        return r;
    }

    comptime static List<int> Rango(int n)
    {
        List<int> l = new List<int>();
        for (int i = 0; i < n; i++) l.Add(i);
        return l;
    }

    static int Sumar(int a, int b, comptime Modo modo = Modo.Rapido)
    {
        comptime if (modo == Modo.Saturado)
        {
            long r = (long)a + b;
            return r > 2147483647 ? 2147483647 : (int)r;
        }
        else return a + b;
    }

    static T Extremo<T>(List<T> l, comptime bool minimo) where T : IComparable<T>
    {
        T m = l[0];
        foreach (T x in l)
        {
            comptime if (minimo) { if (x.CompareTo(m) < 0) m = x; }
            else { if (x.CompareTo(m) > 0) m = x; }
        }
        return m;
    }

    static string Etiqueta(comptime string prefijo, int v)
    {
        const int L = comptime prefijo.Length;
        return prefijo + ":" + v + " (" + L + ")";
    }

    static int SumaTabla(comptime List<int> t)
    {
        int s = 0;
        comptime foreach (var x in t) s += x;
        return s;
    }

    static double Escala(double v, comptime double f) => v * f;

    // Dentro de una función comptime, el argumento puede ser uno de sus parámetros.
    comptime static long PotenciaN(long x, int n) => Potencia(x, n);

    static void Main()
    {
        long b = 2;
        println(Potencia(b, 10));      // 1024
        println(Potencia(3, 0));       // 1
        const int K = 4;
        println(Potencia(b, K));       // 16
        println(Potencia(b, K + 1));   // 32
        println(Repetir("ab", 3));     // ababab
        println(Sumar(2, 3));          // 5
        println(Sumar(2147483647, 3, modo: Modo.Saturado));  // 2147483647
        List<int> l = [3, 9, 1];
        println(Extremo(l, false));    // 9
        println(Extremo(l, true));     // 1
        println(Etiqueta("id", 7));    // id:7 (2)
        println(SumaTabla([1, 2, 3, 4]));  // 10
        println(Escala(2, 1.5));       // 3
        println(PotenciaN(2, 5));      // 32
        println(comptime Potencia(2, 20));  // 1048576
        Caja<int> c = new Caja<int>(4);
        println(c.Mostrar("*") + c.Mostrar("|"));  // *4*|4|
        Func<long, long> cuadrado = x => Potencia(x, 2);
        println(cuadrado(9));          // 81
    }
}
