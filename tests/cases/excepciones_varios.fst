// Excepciones en métodos genéricos, métodos de structs, cases de switch, "=> throw" y try anidados en finally.
using std.collections;

class Forma
{
    public double Area() => throw new NotImplementedException("Forma.Area");
    public int Lados => throw new NotSupportedException();
}

T Primero<T>(List<T> l)
{
    try { return l[0]; }
    catch (ArgumentOutOfRangeException) { return default(T); }
    finally { println("finally genérico"); }
}

struct Contador
{
    public int N;
    public int Sumar(int k)
    {
        try { N += k; if (N > 10) throw new OverflowException("demasiado"); return N; }
        catch (OverflowException) { N = 0; return -1; }
    }
}

string Switch(int x)
{
    switch (x)
    {
        case 1:
            try { return "uno"; }
            finally { println("f1"); }
        default:
            try { throw new FormatException("x"); }
            catch { return "otro"; }
    }
}

void main()
{
    Forma f = new Forma();
    try { f.Area(); } catch (NotImplementedException e) { println(e.Message); }
    try { println(f.Lados); } catch (Exception e) { println(e.TypeName); }
    var l = new List<int>();
    println(Primero<int>(l));
    l.Add(5);
    println(Primero<int>(l));
    var s = new List<string>();
    println("[" + Primero<string>(s) + "]");
    Contador c = new Contador();
    println(c.Sumar(4));
    println(c.Sumar(8));
    println(c.N);
    println(Switch(1));
    println(Switch(2));
    // try dentro de un catch dentro de un finally
    try
    {
        try { throw new IOException("a"); }
        finally
        {
            try { throw new FormatException("b"); }
            catch (FormatException e) { println("interior " + e.Message); }
        }
    }
    catch (IOException e) { println("exterior " + e.Message); }
}
