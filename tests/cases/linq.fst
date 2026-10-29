// LINQ sobre List<T> y Dictionary<K, V> con lambdas (evaluación inmediata).
using std.collections;

class Producto
{
    public string Nombre;
    public string Tipo;
    public double Precio;
    public int Stock;
    public Producto(string n, string t, double p, int s) { Nombre = n; Tipo = t; Precio = p; Stock = s; }
}

void Mostrar(List<int> l)
{
    string s = "";
    for (int i = 0; i < l.Count; i++) s += (i > 0 ? " " : "") + l[i];
    println(s);
}

int main()
{
    var l = new List<int>();
    for (int i = 1; i <= 10; i++) l.Add(i);
    Mostrar(l.Where(x => x % 2 == 0));
    Mostrar(l.Select(x => x * x).Where(x => x > 20));
    var textos = l.Select(x => "n" + x);
    println(textos[2]);
    println(l.Count(x => x > 3));
    println(l.Count);
    println(l.Any(x => x > 9));
    println(l.All(x => x > 0));
    println(l.Sum(x => x * 2));
    println(l.Average());
    println(l.First(x => x > 4));
    println(l.FirstOrDefault(x => x > 40));
    println(l.Aggregate((a, b) => a * b));
    println(l.Aggregate("", (s, x) => s + x));
    Mostrar(l.Take(3));
    Mostrar(l.Skip(8));
    Mostrar(l.OrderByDescending(x => x % 3).ThenBy(x => -x));

    var ps = new List<Producto>();
    ps.Add(new Producto("pera", "fruta", 1.5, 10));
    ps.Add(new Producto("leche", "lacteo", 0.9, 0));
    ps.Add(new Producto("manzana", "fruta", 2.25, 3));
    ps.Add(new Producto("queso", "lacteo", 7.0, 2));
    ps.Add(new Producto("uva", "fruta", 3.0, 0));
    var grupos = ps.GroupBy(p => p.Tipo);
    for (int i = 0; i < grupos.Count; i++)
        println(grupos[i].Key + ": " + grupos[i].Count + " " + grupos[i].Items.Sum(p => p.Precio));
    var orden = ps.OrderBy(p => p.Tipo).ThenByDescending(p => p.Precio).Select(p => p.Nombre);
    for (int i = 0; i < orden.Count; i++) println(orden[i]);
    println(ps.Max(p => p.Precio));
    println(ps.MinBy(p => p.Precio).Nombre);
    var agotados = ps.FindAll(p => p.Stock == 0).Select(p => p.Nombre);
    println(agotados.Count);
    var dic = ps.ToDictionary(p => p.Nombre, p => p.Stock);
    println(dic.Get("pera"));
    println(dic.Count((k, v) => v > 0));
    var pares = l.Zip(textos, (a, b) => b + "=" + a);
    println(pares[9]);
    var rep = new List<int>();
    rep.Add(3); rep.Add(1); rep.Add(3); rep.Add(2); rep.Add(1);
    Mostrar(rep.Distinct());
    rep.Sort((a, b) => b - a);
    Mostrar(rep);
    println(rep.RemoveAll(x => x == 3));
    Mostrar(rep);
    var anidada = new List<List<int>>();
    anidada.Add(l.Take(2));
    anidada.Add(l.Skip(8));
    Mostrar(anidada.SelectMany(x => x));
    int suma = 0;
    l.ForEach(x => suma += x);
    println(suma);
    println(l.Exists(x => x == 7));
    println(l.Find(x => x * x == 49));
    println(l.FindIndex(x => x == 7));
    println(l.Where((x, i) => i < 2).Count);
    return 0;
}
