// Arreglos con interfaces, genéricos, IEnumerable<T> (LINQ perezoso, yield), async, tuplas,
// lambdas, 'object', excepciones, orden de evaluación y vistas Span<T> / ReadOnlySpan<T>.
using std;
using std.collections;
using std.task;

interface IForma { double Area(); }
class Cuadrado : IForma { double l; public Cuadrado(double l) { this.l = l; } public double Area() => l * l; }

class Caja<T>
{
    public T[] Items;
    public Caja(params T[] xs) { Items = xs; }
    public int Cuantos => Items.Length;
}

static class P
{
    static int Total(IEnumerable<int> xs) { int s = 0; foreach (int x in xs) s += x; return s; }
    static IEnumerable<int> Dobles(int[] a) { foreach (int x in a) yield return x * 2; }

    static async Task<int[]> Cargar()
    {
        await Task.Delay(1);
        int[] r = [1, 2, 3];
        await Task.Delay(1);
        r[0] = 10;
        return r;
    }

    static (int[], string) Par() => ([4, 5], "x");

    public static void Main()
    {
        IForma[] formas = [new Cuadrado(2), new Cuadrado(3)];
        double t = 0;
        foreach (IForma f in formas) t += f.Area();
        Console.WriteLine(t);
        var caja = new Caja<string>("a", "b", "c");
        Console.WriteLine(caja.Cuantos + caja.Items[^1]);
        int[] a = [3, 1, 2];
        Console.WriteLine(Total(a));
        Console.WriteLine(Total(Dobles(a)));
        IEnumerable<int> perezoso = a.AsEnumerable().Where(x => x > 1);
        Console.WriteLine(perezoso.Count());
        int[] de = Cargar().Result;
        Console.WriteLine(de[0] + de[2]);
        var (arr, nom) = Par();
        Console.WriteLine(arr[1] + nom);
        List<Action> acciones = new List<Action>();
        foreach (int x in a) acciones.Add(() => Console.Write(x));
        foreach (Action ac in acciones) ac();
        Console.WriteLine();
        object o = a;
        if (o is int[] ia) Console.WriteLine("es int[] " + ia.Length);
        Console.WriteLine(a.ToString().Length > 0);
        List<string> ls = ["x", "y", "z"];
        if (ls is [var p0, ..]) Console.WriteLine(p0);
        if ("hola" is ['h', ..]) Console.WriteLine("empieza con h");
        Console.WriteLine(ls[^2]);
        string[] partes = ls.ToArray();
        Console.WriteLine(partes.Length);
        int[] copia = (int[])a.Clone();
        copia[0] = 99;
        Console.WriteLine(a[0]);
        int i = 0;
        int[] orden = new int[3];
        orden[i++] = i;
        orden[i++] = i;
        Console.WriteLine(orden[0] + "," + orden[1]);
        try
        {
            int[] nada = null;
            Console.WriteLine(nada.Length);
        }
        catch (NullReferenceException) { Console.WriteLine("nulo"); }
        try { int[] neg = new int[-1]; }
        catch (OverflowException e) { Console.WriteLine("negativo"); }
        int[][] jag = [[1, 2], [3]];
        Console.WriteLine(jag[0][1] + jag[1][0]);
        int s = 0;
        for (int k = 0; k < a.Length; k++) s += a[k];
        Console.WriteLine(s);
        Span<int> sp = a;
        ReadOnlySpan<int> ro = sp[1..];
        Console.WriteLine(ro.Length + " " + ro[0]);
        foreach (int v in ro) Console.Write(v);
        Console.WriteLine();
        Span<int> sl = new Span<int>(ls.Count > 0 ? new int[] { 5, 6, 7 } : null);
        Console.WriteLine(sl[2]);
        int[] desde = Enumerable.Range(1, 4).ToArray();
        Console.WriteLine(desde.Length);
    }
}
