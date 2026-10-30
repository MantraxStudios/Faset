// Errores de arreglos, rangos, expresiones de colección y patrones de lista.
using std;
using std.collections;

class Animal { }
class Gato : Animal { }

void main()
{
    object[] o = new string[2];
    Animal[] an = new Gato[1];
    string[] s = new int[2];
    var x = [1, 2];
    int[] a = [1, "x"];
    int[,] m = { { 1, 2 }, { 3 } };
    int[] b = new int[3] { 1, 2 };
    int n = 5;
    int[] c = [..n];
    ReadOnlySpan<int> ro = a;
    ro[0] = 1;
    if (n is [1, ..]) { }
    if (a is [.., 1, ..]) { }
    var y = new[] { };
    List<int> l = { 1 };
    int[] d = new int[2.5];
    int e = a["x"];
    int[] f = new int[] { 1, .. a };
    int g = n[1..2];
}
