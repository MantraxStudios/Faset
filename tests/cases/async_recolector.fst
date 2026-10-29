// async / await y el recolector de basura: miles de tareas suspendidas a la vez (sus marcos solo
// los alcanzan las continuaciones registradas en otras tareas y en la cola de temporizadores),
// con recolecciones forzadas mientras esperan y basura creada entre los 'await'.
using std;
using std.collections;
using std.task;

class Nodo
{
    public string Texto;
    public Nodo Siguiente;
}

public static class Program
{
    static async Task<string> Pieza(int i, Task puerta)
    {
        Nodo lista = null;
        for (int k = 0; k < 4; k++)
        {
            Nodo n = new Nodo();
            n.Texto = "n" + i + "." + k;
            n.Siguiente = lista;
            lista = n;
        }
        string antes = "p" + i;
        await puerta;                      // todas suspendidas aquí a la vez
        string basura = "";
        for (int k = 0; k < 20; k++) basura = basura + k;
        await Task.Delay(1 + i % 5);
        int largo = 0;
        for (Nodo n = lista; n != null; n = n.Siguiente) largo += n.Texto.Length;
        return antes + ":" + largo + ":" + basura.Length;
    }

    static async Task Main()
    {
        var puerta = new TaskCompletionSource<int>();
        var tareas = new List<Task<string>>();
        for (int i = 0; i < 4000; i++) tareas.Add(Pieza(i, puerta.Task));
        long antes = GC.Collections;
        for (int i = 0; i < 3; i++)
        {
            var relleno = new List<string>();
            for (int k = 0; k < 20000; k++) relleno.Add("relleno " + k);
            GC.Collect();
        }
        int pendientes = 0;
        foreach (var t in tareas)
            if (!t.IsCompleted) pendientes++;
        Console.WriteLine("pendientes: " + pendientes);
        puerta.SetResult(1);
        GC.Collect();
        List<string> res = await Task.WhenAll(tareas);
        GC.Collect();
        long total = 0;
        foreach (var s in res) total += s.Length;
        Console.WriteLine("resultados: " + res.Count + " " + res[0] + " " + res[3999] + " total " + total);
        Console.WriteLine("hubo recolecciones: " + (GC.Collections - antes >= 5));
    }
}
