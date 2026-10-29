// std.task: cancelación cooperativa, Task.WhenAll / WhenAny, Task.Run, ContinueWith,
// TaskCompletionSource, ConfigureAwait, async void y Main async con código de salida.
using std;
using std.collections;
using std.task;
using std.thread;

public static class Program
{
    static async Task<int> Contar(CancellationToken token)
    {
        int n = 0;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            await Task.Delay(2);
            n++;
        }
    }

    static async Task<int> Despues(int ms, int v)
    {
        await Task.Delay(ms);
        return v;
    }

    static async void Disparar(AtomicInt hechos)
    {
        await Task.Delay(1);
        hechos.Increment();
    }

    static async Task<int> Main()
    {
        Console.WriteLine("1) cancelación");
        var cts = new CancellationTokenSource();
        Task<int> t = Contar(cts.Token);
        await Task.Delay(20);
        cts.Cancel();
        try
        {
            await t;
            Console.WriteLine("  no se ve");
        }
        catch (OperationCanceledException e)
        {
            Console.WriteLine("  cancelada: " + t.IsCanceled + ", " + t.Status.ToString() + ", faulted " + t.IsFaulted);
        }
        var cts2 = new CancellationTokenSource(10);  // se cancela sola a los 10 ms
        try
        {
            await Task.Delay(60000, cts2.Token);
        }
        catch (TaskCanceledException e)
        {
            Console.WriteLine("  Delay cancelado: " + cts2.IsCancellationRequested);
        }
        var cts3 = new CancellationTokenSource();
        int avisos = 0;
        cts3.Token.Register(() => avisos++);
        cts3.Cancel();
        cts3.Cancel();
        Console.WriteLine("  avisos " + avisos + ", None " + CancellationToken.None.CanBeCanceled);

        Console.WriteLine("2) WhenAll y WhenAny");
        List<int> todos = await Task.WhenAll(Despues(30, 1), Despues(10, 2), Despues(20, 3));
        Console.WriteLine("  WhenAll: " + todos[0] + todos[1] + todos[2]);
        Task<int> lenta = Despues(500, 7);
        Task<int> rapida = Despues(5, 8);
        Task primera = await Task.WhenAny(lenta, rapida);
        Console.WriteLine("  WhenAny: la rápida " + (primera == rapida) + ", lenta terminada " + lenta.IsCompleted);
        await Task.WhenAll(Task.Delay(1), Task.Delay(2));
        try
        {
            await Task.WhenAll(Task.Delay(1), Task.Run(() => { throw new FormatException("w"); }));
        }
        catch (FormatException e)
        {
            Console.WriteLine("  WhenAll con error: " + e.Message);
        }

        Console.WriteLine("3) Task.Run, ContinueWith, TaskCompletionSource");
        int a = await Task.Run(() => 6 * 7);
        int b = await Task.Run(async () =>
        {
            await Task.Delay(1);
            return a + 1;
        });
        await Task.Run(async () => await Task.Delay(1));
        Console.WriteLine("  Run: " + a + " " + b);
        int c = await Despues(1, 5).ContinueWith(x => x.Result * 10);
        Console.WriteLine("  ContinueWith: " + c);
        var tcs = new TaskCompletionSource<string>();
        Task.Run(() =>
        {
            Thread.Sleep(5);
            tcs.SetResult("desde otro hilo");
        });
        Console.WriteLine("  TaskCompletionSource: " + await tcs.Task);
        Console.WriteLine("  ConfigureAwait: " + await Despues(1, 3).ConfigureAwait(false));
        Console.WriteLine("  FromResult: " + await Task.FromResult("listo") + ", Result " + Despues(1, 4).Result);

        Console.WriteLine("4) async void");
        var hechos = new AtomicInt();
        for (int i = 0; i < 20; i++) Disparar(hechos);
        while (hechos.Value < 20) await Task.Delay(1);
        Console.WriteLine("  terminados " + hechos.Value);
        return 3;  // código de salida del programa
    }
}
