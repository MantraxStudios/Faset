// Mide el coste de las comprobaciones en ejecución (RuntimeChecks). Compara:
//   faset run -c Release --no-checks examples/benchmark_checks.fst
//   faset run -c Release --checks    examples/benchmark_checks.fst
//   faset run -c Debug               examples/benchmark_checks.fst   (checks activas por defecto)
using std.collections;
using std.time;

class Particula
{
    public var X: double, Y: double, VX: double, VY: double;
    public var Siguiente: Particula;
    public func Mover(dt: double) { X += VX * dt; Y += VY * dt; }
}

static class Bench
{
    // Acceso a campos y llamadas a métodos a través de referencias (comprobación de nulo/delete).
    public static func Objetos() -> double
    {
        Particula primera = null;
        for (int i = 0; i < 1000; i++)
        {
            Particula p = new Particula();
            p.VX = i * 0.5;
            p.VY = 1.0 / (i + 1);
            p.Siguiente = primera;
            primera = p;
        }
        for (int paso = 0; paso < 20000; paso++)
            for (Particula p = primera; p != null; p = p.Siguiente) p.Mover(0.001);
        double s = 0;
        while (primera != null)
        {
            Particula sig = primera.Siguiente;
            s += primera.X + primera.Y;
            delete primera;
            primera = sig;
        }
        return s;
    }

    // Indexación de List<T> (límites) y aritmética entera con división.
    public static func Listas() -> long
    {
        List<int> l = new List<int>();
        for (int i = 0; i < 100000; i++) l.Add(i * 7 + 3);
        long total = 0;
        for (int r = 0; r < 300; r++)
            for (int i = 0; i < l.Count; i++) total += l[i] % (r + 1) + l[i] / (i + 1);
        delete l;
        return total;
    }

    // Indexación de cadenas (límites).
    public static func Cadenas() -> long
    {
        string s = "Faset: nativo, con la elegancia de C# y la potencia de C++. ";
        long h = 0;
        for (int r = 0; r < 400000; r++)
            for (int i = 0; i < s.Length; i++) h = h * 31 + s[i];
        return h;
    }
}

func Medir(nombre: string, ms: long)
{
    Console.Write(nombre);
    Console.Write(": ");
    Console.Write(ms);
    Console.WriteLine(" ms");
}

func main()
{
    long t0 = Time.TickMs();
    double a = Bench.Objetos();
    long t1 = Time.TickMs();
    long b = Bench.Listas();
    long t2 = Time.TickMs();
    long c = Bench.Cadenas();
    long t3 = Time.TickMs();
    Medir("objetos", t1 - t0);
    Medir("listas ", t2 - t1);
    Medir("cadenas", t3 - t2);
    Medir("total  ", t3 - t0);
    println(a > 0 && b != 0 && c != 0);
}
