// params: argumentos variables empaquetados en un arreglo T[] o en una List<T>.
using std.collections;

int Sumar(params int[] xs)
{
    int s = 0;
    foreach (int x in xs) s += x;
    return s;
}

void Log(string formato, params List<string> partes)
{
    string r = formato;
    foreach (var p in partes) r += " " + p;
    println(r + " (" + partes.Count + ")");
}

double Media(params List<double> xs)
{
    if (xs.Count == 0) return 0;
    double s = 0;
    foreach (double x in xs) s += x;
    return s / xs.Count;
}

T Mayor<T>(T primero, params List<T> resto)
{
    T m = primero;
    foreach (T x in resto)
        if (m < x) m = x;
    return m;
}

class Registro
{
    List<string> lineas = new List<string>();
    public Registro(params string[] iniciales) { lineas.AddRange(iniciales); }
    public void Anotar(params string[] ls) { lineas.AddRange(ls); }
    public int Total => lineas.Count;
}

void main()
{
    println(Sumar());
    println(Sumar(5));
    println(Sumar(1, 2, 3, 4));
    List<int> lista = new List<int>();
    lista.Add(10);
    lista.Add(20);
    println(Sumar(lista.ToArray()));  // forma normal: se pasa el arreglo tal cual

    Log("vacío");
    Log("uno", "a");
    Log("varios", "a", "b", "c");

    println(Media(1, 2, 3, 4));  // int -> double en cada argumento
    println(Media());

    println(Mayor(3, 9, 4));
    println(Mayor<string>("pera", "uva", "manzana"));
    println(Mayor(1.5));

    Registro r = new Registro("inicio");
    r.Anotar("x", "y");
    r.Anotar();
    println(r.Total);
}
