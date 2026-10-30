// Iteradores y el recolector de basura: miles de iteradores suspendidos a la vez (sus marcos solo
// los alcanza el generador), con recolecciones forzadas mientras esperan, basura creada entre dos
// 'yield', cadenas largas de LINQ perezoso y generadores que se abandonan sin terminar.
using std;
using std.collections;

class Nodo
{
    public string Texto;
    public Nodo Siguiente;
}

public static class Program
{
    static IEnumerable<string> Piezas(int i)
    {
        Nodo lista = null;
        for (int k = 0; k < 4; k++)
        {
            Nodo n = new Nodo();
            n.Texto = "n" + i + "." + k;
            n.Siguiente = lista;
            lista = n;
            yield return n.Texto;      // todas suspendidas aquí, con su lista viva en el marco
            string basura = "";
            for (int b = 0; b < 10; b++) basura = basura + b;
        }
        int largo = 0;
        for (Nodo n = lista; n != null; n = n.Siguiente) largo += n.Texto.Length;
        yield return "fin" + i + ":" + largo;
    }

    static void Main()
    {
        List<IEnumerator<string>> vivos = new List<IEnumerator<string>>();
        for (int i = 0; i < 5000; i++)
        {
            IEnumerator<string> e = Piezas(i).GetEnumerator();
            e.MoveNext();
            vivos.Add(e);
        }
        long antes = GC.Collections;
        int pasos = 0;
        for (int vuelta = 0; vuelta < 4; vuelta++)
        {
            List<string> relleno = new List<string>();
            for (int k = 0; k < 20000; k++) relleno.Add("relleno " + k);
            GC.Collect();
            foreach (IEnumerator<string> e in vivos)
                if (e.MoveNext()) pasos++;
        }
        Console.WriteLine("pasos: " + pasos + ", primero: " + vivos[0].Current + ", último: " + vivos[4999].Current);
        foreach (IEnumerator<string> e in vivos) e.Dispose();
        vivos.Clear();
        GC.Collect();

        // Una cadena larga de operadores perezosos sobre un generador infinito.
        long total = 0;
        for (int r = 0; r < 200; r++)
        {
            IEnumerable<int> q = Enumerable.Range(0, 1000000000)
                .Select(x => x * 3)
                .Where(x => x % 2 == 0)
                .Select(x => "v" + x)
                .Select(s => s.Length)
                .Skip(r)
                .Take(50);
            total += q.Sum();
            if (r % 50 == 0) GC.Collect();
        }
        Console.WriteLine("total: " + total);

        // Generadores abandonados a medias (sin Dispose): los recoge el recolector.
        int abandonados = 0;
        for (int i = 0; i < 20000; i++)
        {
            IEnumerator<string> e = Piezas(i).GetEnumerator();
            if (e.MoveNext() && e.MoveNext()) abandonados++;
        }
        GC.Collect();
        Console.WriteLine("abandonados: " + abandonados);
        Console.WriteLine("hubo recolecciones: " + (GC.Collections - antes >= 5));
    }
}
