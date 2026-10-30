// Arreglos T[]: creación, índices con comprobación de límites, foreach, Array.*, LINQ, params,
// multidimensionales, escalonados, rangos, Span<T>, expresiones de colección y patrones de lista.
using std;
using std.collections;

struct Punto { public int X; public int Y; public Punto(int x, int y) { X = x; Y = y; } }
class Animal { public string Nombre; public Animal(string n) { Nombre = n; } }

static class P
{
    static int Suma(params int[] xs) { int s = 0; foreach (int x in xs) s += x; return s; }
    static string Unir<T>(T[] a) { string r = ""; foreach (T x in a) r += (r == "" ? "" : ",") + x; return r; }
    static T Primero<T>(T[] a) => a[0];

    public static void Main()
    {
        int[] a = new int[5];
        Console.WriteLine(a.Length);
        a[2] = 7;
        Console.WriteLine(a[2] + a[0]);
        int[] b = new int[] { 1, 2, 3 };
        int[] c = { 4, 5, 6 };
        var d = new[] { 1.5, 2.5 };
        int[] e = [7, 8, 9];
        Console.WriteLine(b[0] + c[1] + e[2]);
        Console.WriteLine(d[1]);
        foreach (int x in c) Console.Write(x + " ");
        Console.WriteLine();
        string[] s = { "uno", "dos", "tres" };
        Console.WriteLine(Unir(s));
        Punto[] ps = new Punto[2];
        ps[1].X = 3;
        Console.WriteLine(ps[1].X);
        Animal[] an = [new Animal("gato"), new Animal("perro")];
        Console.WriteLine(an[1].Nombre);
        (int, string)[] tu = [(1, "a"), (2, "b")];
        Console.WriteLine(tu[1].Item2);
        int[] z = { 5, 3, 9, 1 };
        Array.Sort(z);
        Console.WriteLine(Unir(z));
        Array.Reverse(z);
        Console.WriteLine(z[0]);
        Console.WriteLine(Array.IndexOf(z, 3));
        Array.Sort(z);
        Console.WriteLine(Array.BinarySearch(z, 5));
        Array.Resize(ref z, 6);
        Console.WriteLine(z.Length + " " + z[5]);
        Array.Fill(z, 2);
        Console.WriteLine(z[3]);
        Array.Clear(z);
        Console.WriteLine(z[3]);
        int[] w = new int[3];
        Array.Copy(b, w, 3);
        Console.WriteLine(w[2]);
        List<int> l = b.Where(x => x > 1).ToList();
        Console.WriteLine(l.Count);
        int[] sq = b.Select(x => x * x).ToArray();
        Console.WriteLine(sq[2]);
        Console.WriteLine(Suma(1, 2, 3) + Suma());
        Console.WriteLine(Suma(b));
        Console.WriteLine(Primero(s));
        Func<int[], int> largo = v => v.Length;
        Console.WriteLine(largo(e));
        try { int q = a[10]; Console.WriteLine(q); }
        catch (IndexOutOfRangeException ex) { Console.WriteLine("fuera: " + ex.Message); }
        int[,] m = new int[2, 3];
        m[1, 2] = 5;
        Console.WriteLine(m.GetLength(0) + " " + m.GetLength(1) + " " + m.Rank + " " + m[1, 2]);
        int[,] m2 = { { 1, 2 }, { 3, 4 } };
        Console.WriteLine(m2[1, 0]);
        int[][] j = new int[2][];
        j[0] = [1]; j[1] = [1, 2, 3];
        Console.WriteLine(j[1].Length + j[0][0]);
        Console.WriteLine(e[^1]);
        int[] sl = e[1..];
        Console.WriteLine(sl.Length + " " + sl[0]);
        Console.WriteLine("hola mundo"[..4]);
        List<int> li = [1, 2, ..b, 4];
        Console.WriteLine(li.Count + " " + li[^1]);
        Console.WriteLine(li[1..3].Count);
        Span<int> sp = e.AsSpan(1, 2);
        sp[0] = 100;
        Console.WriteLine(e[1]);
        HashSet<int> hs = [1, 1, 2];
        Console.WriteLine(hs.Count);
        Dictionary<string, int> dic = [["a"] = 1, ["b"] = 2];
        Console.WriteLine(dic["b"]);
        int[] vacio = [];
        Console.WriteLine(vacio.Length);
        if (e is [7, .., var ult]) Console.WriteLine("ult " + ult);
        string r = b switch { [] => "vacío", [var p] => "uno " + p, [var p, .., var u] => "varios " + p + "-" + u };
        Console.WriteLine(r);
        Index ix = ^2;
        Range rg = 1..^1;
        Console.WriteLine(ix.ToString() + " " + rg.ToString());
    }
}
