// async / await: Main async, orden de las tareas intercaladas (determinista con
// TaskCompletionSource y con plazos holgados), Task<T>, Task.Yield y orden de evaluación.
using std;
using std.collections;
using std.task;
using std.thread;

class Registro
{
    Mutex m = new Mutex();
    List<string> items = new List<string>();

    public void Add(string s)
    {
        m.Lock();
        items.Add(s);
        m.Unlock();
    }

    public string Todo()
    {
        m.Lock();
        string r = "";
        for (int i = 0; i < items.Count; i++) r += (i > 0 ? " " : "") + items[i];
        items.Clear();
        m.Unlock();
        return r;
    }
}

public static class Program
{
    static Registro log = new Registro();

    // Dos tareas que se pasan el turno: cada una espera la señal de la otra.
    static async Task Jugador(string nombre, List<TaskCompletionSource<int>> mias, List<TaskCompletionSource<int>> suyas)
    {
        for (int i = 0; i < mias.Count; i++)
        {
            int golpe = await mias[i].Task;
            log.Add(nombre + golpe);
            suyas[i].SetResult(golpe + 1);
        }
    }

    // Cada una avanza a su ritmo (plazos muy distintos: el orden no depende de la carga).
    static async Task Reloj(string nombre, int periodo, int veces)
    {
        for (int i = 1; i <= veces; i++)
        {
            await Task.Delay(periodo);
            log.Add(nombre + i);
        }
    }

    static async Task<int> Cuadrado(int x)
    {
        await Task.Yield();
        return x * x;
    }

    static int Nota(string s, int v)
    {
        log.Add(s);
        return v;
    }

    static async Task<int> Tarde(string s, int v)
    {
        await Task.Delay(5);
        log.Add(s);
        return v;
    }

    static int Tres(int a, int b, int c) => a * 100 + b * 10 + c;

    static async Task Main()
    {
        Console.WriteLine("inicio");

        // ping-pong
        var a = new List<TaskCompletionSource<int>>();
        var b = new List<TaskCompletionSource<int>>();
        for (int i = 0; i < 3; i++)
        {
            a.Add(new TaskCompletionSource<int>());
            b.Add(new TaskCompletionSource<int>());
        }
        Task ping = Jugador("ping", a, b);
        Task pong = Jugador("pong", b, a.Count > 0 ? Siguientes(a) : a);
        a[0].SetResult(0);
        await ping;
        await pong;
        Console.WriteLine("ping-pong: " + log.Todo());

        // relojes intercalados: R1 a los 40, 80, 120 ms; L1 a los 100 ms
        Task r = Reloj("R", 40, 3);
        Task l = Reloj("L", 100, 1);
        await Task.WhenAll(r, l);
        Console.WriteLine("relojes: " + log.Todo());

        // Task<T> y suma de resultados
        int total = 0;
        for (int i = 1; i <= 4; i++) total += await Cuadrado(i);
        Console.WriteLine("suma de cuadrados: " + total);

        // los operandos a la izquierda de un await se evalúan antes que él (como en C#)
        int t = Tres(Nota("a", 1), await Tarde("b", 2), Nota("c", 3));
        Console.WriteLine("orden: " + t + " " + log.Todo());

        // una tarea ya terminada no suspende
        Task<int> hecha = Task.FromResult(9);
        Console.WriteLine("completada: " + hecha.IsCompleted + " " + await hecha);
        await Task.CompletedTask;
        Console.WriteLine("fin");
    }

    // a[1..] seguido de una señal extra para que el último pong no se quede esperando.
    static List<TaskCompletionSource<int>> Siguientes(List<TaskCompletionSource<int>> a)
    {
        var r = new List<TaskCompletionSource<int>>();
        for (int i = 1; i < a.Count; i++) r.Add(a[i]);
        r.Add(new TaskCompletionSource<int>());
        return r;
    }
}
