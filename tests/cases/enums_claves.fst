// Enums como texto ($"{e}", "x" + e: el nombre, como en C#), enums y enteros pequeños como claves
// de Dictionary/HashSet, y el formato más corto de double/float.
using std;
using std.collections;

enum Color { Rojo, Verde, Azul }

memory_unsafe class Program
{
    static void Main()
    {
        Color c = Color.Verde;
        Color? n = Color.Azul;
        Color? vacio = null;
        Console.WriteLine($"{c} {c,7}|{c,-7}|{c:D} {n} [{vacio}]");
        Console.WriteLine("color: " + c + ", nullable: " + n);
        Console.WriteLine(c.ToString() + " " + (Color)7);

        var cuenta = new Dictionary<Color, int>();
        foreach (Color x in new List<Color> { Color.Rojo, Color.Azul, Color.Rojo, Color.Rojo })
            cuenta[x] = cuenta.ContainsKey(x) ? cuenta[x] + 1 : 1;
        Console.WriteLine($"rojo {cuenta[Color.Rojo]}, azul {cuenta[Color.Azul]}, verde {cuenta.ContainsKey(Color.Verde)}");
        var vistos = new HashSet<Color>();
        vistos.Add(Color.Verde);
        vistos.Add(Color.Verde);
        Console.WriteLine($"conjunto {vistos.Count} {vistos.Contains(Color.Verde)} {vistos.Contains(Color.Rojo)}");

        var cortos = new Dictionary<short, string>();
        cortos[(short)-3] = "menos tres";
        var bytes = new HashSet<byte>();
        bytes.Add((byte)200);
        var flotantes = new Dictionary<float, int>();
        flotantes[0.5f] = 9;
        int v = 1;
        var punteros = new HashSet<int*>();
        punteros.Add(&v);
        Console.WriteLine($"{cortos[(short)-3]} {bytes.Contains((byte)200)} {flotantes[0.5f]} {punteros.Contains(&v)}");

        double[] ds = [0.1, 1.0 / 3.0, 123.0, -0.0, 1e15, 1e-5, 123456789012345.0, 2.5e-300, 0.30000000000000004, -42.5, 1e14];
        foreach (double d in ds) Console.Write(d + " ");
        Console.WriteLine();
        Console.WriteLine($"{0.1f} {1.0f / 3.0f} {16777216.0f} {3.5f}");
    }
}
