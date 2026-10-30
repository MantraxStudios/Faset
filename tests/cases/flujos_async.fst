// Flujos asíncronos: async IAsyncEnumerable<T> con 'await' y 'yield return', 'await foreach' con
// esperas, salida anticipada (DisposeAsync ejecuta los 'finally'), excepciones, flujos encadenados,
// varios flujos a la vez y lambdas/funciones locales async con 'yield'.
using std.collections;
using std.task;

public static class Program
{
    static List<string> log = new List<string>();

    static async IAsyncEnumerable<int> Lecturas(int n, int ms)
    {
        try
        {
            log.Add("abre");
            for (int i = 1; i <= n; i++)
            {
                await Task.Delay(ms);
                log.Add("lee" + i);
                yield return i * 10;
            }
        }
        finally
        {
            log.Add("cierra");
        }
    }

    // Sin registro (se recorren varios a la vez, desde hilos distintos).
    static async IAsyncEnumerable<int> Numeros(int n, int ms)
    {
        for (int i = 1; i <= n; i++)
        {
            await Task.Delay(ms);
            yield return i * 10;
        }
    }

    // Un flujo que consume otro (await foreach dentro de un iterador async).
    static async IAsyncEnumerable<string> Etiquetas(IAsyncEnumerable<int> fuente)
    {
        await foreach (int x in fuente)
        {
            await Task.Yield();
            yield return "#" + x;
        }
    }

    static async IAsyncEnumerable<int> Falla()
    {
        yield return 1;
        await Task.Delay(5);
        throw new InvalidOperationException("falló la lectura");
    }

    static async Task<int> Suma(IAsyncEnumerable<int> xs)
    {
        int s = 0;
        await foreach (int x in xs) s += x;
        return s;
    }

    static string Unir(List<string> xs)
    {
        string r = "";
        foreach (string s in xs) r += (r.Length > 0 ? " " : "") + s;
        return r;
    }

    static async Task Main()
    {
        // Recorrido completo, con esperas.
        await foreach (int x in Lecturas(3, 10)) log.Add("usa" + x);
        Console.WriteLine(Unir(log));
        log.Clear();

        // Salida anticipada: 'break' llama a DisposeAsync y el iterador ejecuta su 'finally'.
        await foreach (int x in Lecturas(10, 5))
        {
            log.Add("usa" + x);
            if (x == 20) break;
        }
        Console.WriteLine(Unir(log));
        log.Clear();

        // Encadenados y recogidos en una lista.
        List<string> etiquetas = await Etiquetas(Lecturas(3, 1)).ToListAsync();
        Console.WriteLine(Unir(etiquetas) + " | " + Unir(log));
        log.Clear();

        // Varios flujos a la vez.
        Task<int> a = Suma(Numeros(4, 7));
        Task<int> b = Suma(Numeros(2, 3));
        Console.WriteLine("sumas: " + await a + " " + await b);

        // Excepción dentro del flujo: sale del 'await foreach'.
        try
        {
            await foreach (int x in Falla()) Console.WriteLine("recibe " + x);
        }
        catch (InvalidOperationException e)
        {
            Console.WriteLine("atrapada: " + e.Message);
        }

        // Recorrido manual con MoveNextAsync / Current / DisposeAsync.
        IAsyncEnumerator<int> en = Lecturas(5, 1).GetAsyncEnumerator();
        while (await en.MoveNextAsync())
            if (en.Current >= 30) break;
        await en.DisposeAsync();
        Console.WriteLine("manual: " + en.Current + " | " + Unir(log));
        log.Clear();

        // Función local async con 'yield' y un IEnumerable<T> convertido en flujo.
        async IAsyncEnumerable<string> Saludos(string quien)
        {
            foreach (string s in Enumerable.Repeat("hola", 2))
            {
                await Task.Delay(1);
                yield return s + " " + quien;
            }
        }
        await foreach (string s in Saludos("mundo")) Console.WriteLine(s);
        int total = 0;
        await foreach (int x in Enumerable.Range(1, 4).ToAsyncEnumerable()) total += x;
        Console.WriteLine("total " + total);
    }
}
