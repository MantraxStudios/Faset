using std.collections;

class Contador
{
    public event Action<int> Cambio;
    int n;
    public void Sumar() { n++; Cambio(n); }
}

int main()
{
    // try dentro de una lambda
    Func<string, int> parsear = s => {
        try { return int.Parse(s); }
        catch (FormatException e) { return -1; }
        finally { println("finally lambda " + s); }
    };
    println(parsear("42"));
    println(parsear("xx"));

    // la lambda lanza; se captura fuera
    Action falla = () => { throw new InvalidOperationException("desde lambda"); };
    try { falla(); }
    catch (InvalidOperationException e) { println("capturada: " + e.Message); }

    // variable capturada y modificada dentro de un try
    int total = 0;
    Action<int> sumar = x => { total += x; };
    try
    {
        sumar(5);
        sumar(7);
        throw new Exception("corte");
    }
    catch (Exception e) { println("total tras excepción: " + total); }

    // excepción en LINQ
    var lista = new List<int>();
    lista.Add(3); lista.Add(0); lista.Add(5);
    try
    {
        var r = lista.Select(x => 10 / x);
        println(r.Count);
    }
    catch (DivideByZeroException e) { println("división en Select"); }

    // eventos + excepciones
    var c = new Contador();
    c.Cambio += v => { if (v == 2) throw new ArgumentException("dos"); println("cambio " + v); };
    try { c.Sumar(); c.Sumar(); c.Sumar(); }
    catch (ArgumentException e) { println("evento lanzó: " + e.Message); }
    return 0;
}
