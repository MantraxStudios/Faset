// comptime con expresiones de colección ([1, ..otra]), índices desde el final (^1) y rangos (a..b)
// sobre listas y cadenas, dentro de funciones comptime y en expresiones comptime directas.
using std;
using std.collections;

comptime List<int> Pares(int n)
{
    List<int> r = [];
    for (int i = 0; i < n; i++) r.Add(i * 2);
    return r;
}
comptime List<int> Unir(List<int> a, List<int> b) => [..a, 100, ..b];
comptime string Medio(string s) => s[1..^1];
comptime int Ultimo(List<int> l) => l[^1];
comptime List<int> Trozo(List<int> l) => l[1..3];
comptime List<string> Nombres() => ["ana", "bea"];
comptime int Cambia()
{
    List<int> l = [1, 2, 3];
    l[^1] = 30;
    var r = 0..2;
    return l[r][1] + l[^1] + l[..1][0];
}

class Program
{
    static void Main()
    {
        List<int> u = comptime Unir(Pares(3), [7, 8]);
        foreach (int x in u) Console.Write(x + " ");
        Console.WriteLine();
        Console.WriteLine(comptime Medio("[hola]"));
        Console.WriteLine(comptime Ultimo([4, 5, 6]));
        List<int> t = comptime Trozo([10, 11, 12, 13]);
        Console.WriteLine($"{t.Count} {t[0]} {t[1]}");
        foreach (string n in comptime Nombres()) Console.Write(n + " ");
        Console.WriteLine();
        Console.WriteLine(comptime Cambia());
        Console.WriteLine(comptime "abcdef"[2..]);
        List<int> a = comptime [1, 2, ..Pares(2)];
        Console.WriteLine($"{a.Count} {a[^1]} {comptime "abcdef"[^2]} {comptime "abcdef"[1..3]}");
    }
}
