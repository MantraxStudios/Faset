using std;
using std.task;

static class Programa
{
    static async Task<int> Calcular(int x)
    {
        await Task.Delay(1);
        return x * 2;
    }

    static async Task Main()
    {
        Task<int> tarea = Calcular(3);
        int valor = await tarea;
        Console.WriteLine(valor);
    }
}
