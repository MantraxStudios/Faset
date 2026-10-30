// Expresiones de colección (List, Dictionary, clases con Add, Span, '..'), patrones de lista en
// 'switch', T[,,], rangos sobre cadenas y arreglos, y Array.Sort con comparación.
using std;
using std.collections;

class Bolsa
{
    public List<string> Cosas = new List<string>();
    public void Add(string s) { Cosas.Add(s.ToUpper()); }
}

static class P
{
    static int[] Hacer() => [1, 2, 3];
    static int Contar(List<int> l) => l.Count;
    static int Contar(int[] a) => a.Length * 100;
    static string Describe(int[] a) => a switch
    {
        [] => "vacío",
        [var x] => "uno: " + x,
        [1, 2, ..] => "empieza 1 2",
        [.., var y] when y > 50 => "termina grande",
        [_, .. var medio, _] => "medio de " + medio.Length,
    };

    public static void Main()
    {
        Console.WriteLine(Hacer()[1]);
        Console.WriteLine(Contar([1, 2]));
        Bolsa b = ["a", "b"];
        Console.WriteLine(b.Cosas[1]);
        List<int[]> filas = [[1, 2], [3]];
        Console.WriteLine(filas[0][1] + filas.Count);
        Dictionary<string, int> d = ["x": 1, "y": 2];
        Console.WriteLine(d["x"] + d["y"]);
        int[,,] cubo = new int[2, 3, 4];
        cubo[1, 2, 3] = 7;
        Console.WriteLine(cubo.Length + " " + cubo.GetLength(2) + " " + cubo[1, 2, 3]);
        int[,] m = { { 1, 2 }, { 3, 4 } };
        int s = 0;
        foreach (int v in m) s += v;
        Console.WriteLine(s);
        (string, int)[] pares = [("a", 1), ("b", 2)];
        foreach (var (n, k) in pares) Console.Write(n + k);
        Console.WriteLine();
        Console.WriteLine(Describe([]));
        Console.WriteLine(Describe([9]));
        Console.WriteLine(Describe([1, 2, 3]));
        Console.WriteLine(Describe([5, 99]));
        Console.WriteLine(Describe([5, 6, 7, 8]));
        Func<int[]> f = () => [4, 5];
        Console.WriteLine(f().Length);
        int[] mezcla = [..Hacer(), ..Hacer().ToList(), 0];
        Console.WriteLine(mezcla.Length + " " + mezcla[3]);
        Span<int> sp = [1, 2, 3];
        Console.WriteLine(sp.Length);
        string texto = "abcdef";
        Console.WriteLine(texto[^1] + " " + texto[1..^1] + " " + texto[..2] + texto[4..]);
        int n = 2;
        int[] base = [10, 20, 30, 40];
        Console.WriteLine(base[n..].Length + base[..n][1]);
        Range r = ..;
        Console.WriteLine(base[r].Length);
        Index ix = ^n;
        Console.WriteLine(base[ix]);
        Console.WriteLine(Array.Empty<int>().Length);
        Console.WriteLine(base.Contains(30) + " " + base.Sum() + " " + base.Max());
        string[] palabras = ["pera", "uva", "kiwi"];
        Array.Sort(palabras);
        Console.WriteLine(palabras[0]);
        Array.Sort(palabras, (x, y) => x.Length - y.Length);
        Console.WriteLine(palabras[0]);
        var ordenadas = palabras.OrderBy(p => p).ToArray();
        Console.WriteLine(ordenadas[2]);
    }
}
