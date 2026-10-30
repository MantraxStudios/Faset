// LINQ perezoso sobre IEnumerable<T>: orden de los efectos, operadores, colecciones de std como
// IEnumerable<T> (List, Dictionary, HashSet, Stack, Queue, string) y convivencia con los métodos
// inmediatos de List<T>.
using std.collections;

class Persona
{
    public string Nombre;
    public int Edad;
    public string Ciudad;
    public Persona(string n, int e, string c) { Nombre = n; Edad = e; Ciudad = c; }
}

public static class Program
{
    static string traza = "";

    static string Unir<T>(IEnumerable<T> xs)
    {
        string r = "";
        foreach (T x in xs) r += (r.Length > 0 ? "," : "") + x;
        return "[" + r + "]";
    }

    static List<int> Lista(params List<int> xs) => xs;

    static void Main()
    {
        // ---- pereza: nada se evalúa hasta recorrer; los elementos pasan de uno en uno por la cadena
        IEnumerable<int> q = Enumerable.Range(1, 5)
            .Where(x => { traza += "w" + x + " "; return x % 2 == 1; })
            .Select(x => { traza += "s" + x + " "; return x * 10; });
        traza += "| ";
        foreach (int x in q) traza += "=" + x + " ";
        Console.WriteLine(traza);
        traza = "";
        Console.WriteLine("First: " + q.First() + " traza: " + traza);

        // ---- generadores y operadores
        Console.WriteLine(Unir(Enumerable.Range(3, 4)) + " " + Unir(Enumerable.Repeat("ab", 3)) + " " +
                          Unir(Enumerable.Empty<int>()));
        IEnumerable<int> n = Enumerable.Range(1, 10);
        Console.WriteLine(Unir(n.Where((x, i) => i % 3 == 0)) + " " + Unir(n.Select((x, i) => x * i).Take(4)));
        Console.WriteLine(Unir(n.Skip(7)) + " " + Unir(n.TakeWhile(x => x < 4)) + " " + Unir(n.SkipWhile(x => x < 8)));
        Console.WriteLine(Unir(n.Take(2).Concat(n.Skip(8))) + " " + Unir(n.Take(3).Append(99).Prepend(0)));
        Console.WriteLine(Unir(n.Take(3).Zip(Enumerable.Range(100, 10), (a, b) => a + b)));
        foreach (var (a, b) in n.Take(2).Zip(Enumerable.Repeat("x", 5))) Console.Write(a + b + " ");
        Console.WriteLine();
        IEnumerable<int> rep = Lista(3, 1, 3, 2, 1, 5);
        Console.WriteLine(Unir(rep.Distinct()) + " " + Unir(rep.Reverse()) + " " + Unir(rep.OrderBy(x => x)) + " " +
                          Unir(rep.OrderByDescending(x => x)));
        foreach (List<int> c in n.Chunk(4)) Console.Write(Unir(c) + " ");
        Console.WriteLine();
        Console.WriteLine(Unir(n.Take(3).SelectMany(x => Enumerable.Repeat(x, x))));

        // ---- agregados
        Console.WriteLine("sum " + n.Sum() + " min " + n.Min() + " max " + n.Max() + " avg " + n.Average() +
                          " count " + n.Count() + " pares " + n.Count(x => x % 2 == 0));
        Console.WriteLine("any " + n.Any() + " " + n.Any(x => x > 9) + " all " + n.All(x => x > 0) + " contains " +
                          n.Contains(7) + " " + n.Contains(70));
        Console.WriteLine("first " + n.First() + " " + n.First(x => x > 4) + " last " + n.Last() + " " +
                          n.Last(x => x < 4) + " at " + n.ElementAt(2) + " def " + n.FirstOrDefault(x => x > 50) +
                          " " + Enumerable.Empty<int>().LastOrDefault());
        Console.WriteLine("aggregate " + n.Aggregate((a, b) => a * b % 1000) + " " +
                          n.Take(4).Aggregate("", (s, x) => s + x));
        try
        {
            Enumerable.Empty<int>().First();
        }
        catch (InvalidOperationException e)
        {
            Console.WriteLine("vacía: " + e.Message);
        }

        // ---- objetos: OrderBy/ThenBy, GroupBy, ToDictionary, ToHashSet, ToList
        List<Persona> gente = new List<Persona>();
        gente.Add(new Persona("Ana", 31, "Lima"));
        gente.Add(new Persona("Luis", 25, "Quito"));
        gente.Add(new Persona("Eva", 31, "Quito"));
        gente.Add(new Persona("Juan", 19, "Lima"));
        IEnumerable<Persona> todos = gente;
        foreach (Persona p in todos.OrderByDescending(p => p.Edad).ThenBy(p => p.Nombre)) Console.Write(p.Nombre + " ");
        Console.WriteLine();
        foreach (Grouping<string, Persona> g in todos.GroupBy(p => p.Ciudad))
            Console.WriteLine(g.Key + ": " + Unir(g.Select(p => p.Nombre)) + " edad media " + g.Average(p => p.Edad));
        Dictionary<string, int> edades = todos.ToDictionary(p => p.Nombre, p => p.Edad);
        Console.WriteLine("Eva tiene " + edades.Get("Eva") + "; ciudades " + todos.Select(p => p.Ciudad).ToHashSet().Count);
        List<string> nombres = todos.Where(p => p.Edad > 20).Select(p => p.Nombre).ToList();
        Console.WriteLine(nombres.Count + " mayores de 20: " + Unir(nombres));
        Console.WriteLine("mayor: " + todos.Max(p => p.Edad) + ", suma " + todos.Sum(p => p.Edad));

        // ---- List<T>: los métodos propios son inmediatos; como IEnumerable<T>, perezosos
        List<int> lista = Lista(1, 2, 3, 4);
        List<int> inmediata = lista.Where(x => x > 2);           // List<T>.Where: lista nueva ya calculada
        IEnumerable<int> perezosa = lista.AsEnumerable().Where(x => x > 2);
        lista.Add(5);
        Console.WriteLine("inmediata " + Unir(inmediata) + " perezosa " + Unir(perezosa));

        // ---- colecciones de std y string como IEnumerable<T>
        HashSet<int> hs = new HashSet<int>();
        hs.Add(4);
        hs.Add(6);
        Stack<int> pila = new Stack<int>();
        pila.Push(1);
        pila.Push(2);
        Queue<string> cola = new Queue<string>();
        cola.Enqueue("x");
        cola.Enqueue("y");
        Dictionary<string, int> d = new Dictionary<string, int>();
        d.Set("uno", 1);
        d.Set("dos", 2);
        Console.WriteLine("hs " + hs.Sum() + " pila " + Unir(pila) + " cola " + Unir(cola) + " dic " +
                          d.Sum(kv => kv.Value) + " " + d.Count(kv => kv.Key.Length == 3));
        foreach (string s in cola) Console.Write(s);
        Console.WriteLine();
        Console.WriteLine("vocales " + ("murciélago".Count(c => "aeiouáéíóú".Contains(c))) + " " +
                          Unir("abc".Select(c => (int)c)) + " " + Unir("hola".Reverse()));
    }
}
