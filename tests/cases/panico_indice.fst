// Índice fuera de rango en List<T>: panic con la línea de quien indexa ([TrackCaller]).
using std.collections;

void main()
{
    List<int> l = new List<int>();
    l.Add(1);
    l.Add(2);
    println(l[1]);
    println(l[5]);
    println("no se llega aquí");
    delete l;
}
