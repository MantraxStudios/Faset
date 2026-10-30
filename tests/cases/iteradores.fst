// Iteradores: yield return / yield break, pereza (orden de los efectos), generadores infinitos,
// 'finally' al salir antes de tiempo (Dispose), excepciones, iteradores anidados, capturas de
// variables locales y de 'this', propiedades, funciones locales, IEnumerator<T> y la
// implementación explícita de IEnumerable<T> en una clase propia.
using std.collections;

class Registro
{
    public List<string> Lineas = new List<string>();
    public void Anota(string s) { Lineas.Add(s); }
    public string Texto()
    {
        string r = "";
        foreach (string s in Lineas) r += (r.Length > 0 ? " " : "") + s;
        return r;
    }
}

class Arbol
{
    public int Valor;
    public Arbol Izq, Der;
    public Arbol(int v, Arbol i, Arbol d) { Valor = v; Izq = i; Der = d; }

    // Iteradores anidados (recursivos) que usan 'this'.
    public IEnumerable<int> EnOrden()
    {
        if (Izq != null)
            foreach (int x in Izq.EnOrden()) yield return x;
        yield return Valor;
        if (Der != null)
            foreach (int x in Der.EnOrden()) yield return x;
    }

    // Propiedad iteradora.
    public IEnumerable<int> Hojas
    {
        get
        {
            if (Izq == null && Der == null) yield return Valor;
            if (Izq != null) foreach (int x in Izq.Hojas) yield return x;
            if (Der != null) foreach (int x in Der.Hojas) yield return x;
        }
    }
}

// Una colección propia: foreach usa la interfaz (implementación explícita).
class Rango : IEnumerable<int>
{
    int desde, hasta;
    public Rango(int a, int b) { desde = a; hasta = b; }
    IEnumerator<int> IEnumerable<int>.GetEnumerator()
    {
        for (int i = desde; i <= hasta; i++) yield return i;
    }
}

class Contador
{
    int paso = 10;
    public IEnumerator<int> Pasos(int n)  // devuelve directamente el enumerador
    {
        for (int i = 1; i <= n; i++) yield return i * paso;
    }
}

public static class Program
{
    static Registro log = new Registro();

    static IEnumerable<int> Numeros(int n)
    {
        log.Anota("inicio");
        for (int i = 1; i <= n; i++)
        {
            log.Anota("da" + i);
            yield return i;
        }
        log.Anota("fin");
    }

    static IEnumerable<long> Fibonacci()
    {
        long a = 0, b = 1;
        while (true)
        {
            yield return a;
            long t = a + b;
            a = b;
            b = t;
        }
    }

    static IEnumerable<string> ConFinally(string nombre)
    {
        try
        {
            log.Anota(nombre + ":try");
            try
            {
                yield return nombre + "1";
                yield return nombre + "2";
            }
            finally
            {
                log.Anota(nombre + ":finally-interno");
            }
            yield return nombre + "3";
        }
        finally
        {
            log.Anota(nombre + ":finally");
        }
    }

    static IEnumerable<int> Lanza(int en)
    {
        try
        {
            for (int i = 1; ; i++)
            {
                if (i == en) throw new InvalidOperationException("fallo en " + i);
                yield return i;
            }
        }
        finally
        {
            log.Anota("lanza:finally");
        }
    }

    static IEnumerable<int> Hasta(int n)
    {
        int i = 0;
        while (true)
        {
            if (i >= n) yield break;
            yield return i++;
        }
    }

    static void Main()
    {
        // 1. Pereza: llamar al método no ejecuta nada; cada MoveNext avanza hasta el siguiente yield.
        IEnumerable<int> seq = Numeros(3);
        log.Anota("creado");
        foreach (int x in seq) log.Anota("usa" + x);
        Console.WriteLine(log.Texto());
        log.Lineas.Clear();

        // 2. Cada recorrido empieza de nuevo (GetEnumerator crea otro estado con los argumentos).
        int total = 0;
        foreach (int x in seq) total += x;
        foreach (int x in seq) total += x;
        Console.WriteLine("dos recorridos: " + total + " (" + log.Lineas.Count + " anotaciones)");
        log.Lineas.Clear();

        // 3. Generador infinito con Take / TakeWhile.
        string fib = "";
        foreach (long f in Fibonacci().Take(12)) fib += f + " ";
        Console.WriteLine(fib);
        Console.WriteLine("primer fib > 1000: " + Fibonacci().First(f => f > 1000));

        // 4. finally al salir antes de tiempo (break) y al terminar.
        foreach (string s in ConFinally("A"))
        {
            log.Anota("usa" + s);
            if (s == "A1") break;
        }
        foreach (string s in ConFinally("B")) log.Anota("usa" + s);
        foreach (string s in ConFinally("C"))
        {
            log.Anota("usa" + s);
            if (s == "C3") break;
        }
        Console.WriteLine(log.Texto());
        log.Lineas.Clear();

        // 5. Una excepción dentro del iterador sale de MoveNext (y su finally se ejecuta).
        try
        {
            foreach (int x in Lanza(3)) log.Anota("usa" + x);
        }
        catch (InvalidOperationException e)
        {
            log.Anota("atrapada:" + e.Message);
        }
        Console.WriteLine(log.Texto());
        log.Lineas.Clear();

        // 6. return dentro de foreach sobre un iterador: también se ejecuta su finally.
        Console.WriteLine("busca: " + Busca("B2"));
        Console.WriteLine(log.Texto());
        log.Lineas.Clear();

        // 7. Iteradores anidados con 'this' y propiedades.
        Arbol t = new Arbol(4, new Arbol(2, new Arbol(1, null, null), new Arbol(3, null, null)),
                            new Arbol(6, null, new Arbol(7, null, null)));
        string orden = "";
        foreach (int x in t.EnOrden()) orden += x;
        string hojas = "";
        foreach (int x in t.Hojas) hojas += x;
        Console.WriteLine("en orden " + orden + ", hojas " + hojas);

        // 8. Funciones locales: iteradoras, recursivas y capturando variables locales.
        int tope = 4;
        IEnumerable<int> Cuadrados(int desde)
        {
            for (int i = desde; i <= tope; i++) yield return i * i;
        }
        tope = 5;  // se captura la variable (no su valor al declarar)
        string cs = "";
        foreach (int x in Cuadrados(2)) cs += x + ",";
        int Factorial(int n) => n <= 1 ? 1 : n * Factorial(n - 1);
        Console.WriteLine("cuadrados " + cs + " factorial " + Factorial(6));

        // 9. Variables locales capturadas por lambdas dentro del iterador.
        foreach (Func<int> f in Funciones(3)) Console.Write(f() + " ");
        Console.WriteLine();

        // 10. IEnumerator<T> directamente, colección propia e yield break.
        IEnumerator<int> e = new Contador().Pasos(3);
        while (e.MoveNext()) Console.Write(e.Current + " ");
        Console.WriteLine();
        int suma = 0;
        foreach (int x in new Rango(1, 10)) suma += x;
        Console.WriteLine("rango " + suma + ", hasta " + Hasta(5).Count() + ", vacío " + Hasta(0).Any());

        // 11. Recorrido manual con Dispose antes de terminar.
        IEnumerator<string> m = ConFinally("D").GetEnumerator();
        m.MoveNext();
        log.Anota("actual " + m.Current);
        m.Dispose();
        log.Anota("después: " + m.MoveNext());
        Console.WriteLine(log.Texto());
    }

    static string Busca(string que)
    {
        foreach (string s in ConFinally("B"))
            if (s == que) return s;
        return "no";
    }

    static IEnumerable<Func<int>> Funciones(int n)
    {
        for (int i = 0; i < n; i++)
        {
            int copia = i * 100;
            yield return () => copia + n;
        }
    }
}
