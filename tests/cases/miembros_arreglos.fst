// Parámetros opcionales, argumentos con nombre, indizadores, inicializadores y 'out var' junto a
// los arreglos T[], los rangos y las expresiones de colección.
using std.collections;
int Suma(int inicio = 0, params int[] xs) { int s = inicio; foreach (int x in xs) s += x; return s; }
class M { public int this[int f, int c] => f * 10 + c; }
void Toma(int[] a, string sep = ",") => println($"{a[0]}{sep}{a.Length}");
void main()
{
    println(Suma());
    println(Suma(1, 2, 3));
    println(Suma(inicio: 5));
    int[] arr = [1, 2, 3];
    Toma(arr);
    Toma([4, 5], sep: "-");
    var l = new List<int> { 1, 2 };
    List<int> l2 = [3, 4];
    println(l.Count + l2.Count);
    println(new M()[2, 3]);
    println(arr[^1]);
    var d = new Dictionary<string, int[]> { ["a"] = [1, 2] };
    println(d["a"].Length);
    if (int.TryParse("5", out var n)) println(arr[..(n - 3)].Length);
}
