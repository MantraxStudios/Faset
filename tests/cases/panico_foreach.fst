// Modificar una List mientras se recorre con foreach termina con panic (en la línea del foreach).
using std.collections;

void main()
{
    List<int> l = new List<int>();
    l.Add(1);
    l.Add(2);
    foreach (int x in l)
    {
        println(x);
        if (x == 1) l.Add(99);
    }
    println("no se llega aquí");
}
