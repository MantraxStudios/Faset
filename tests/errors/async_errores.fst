// Errores de async / await: dónde se puede usar 'await', qué puede devolver un método async y
// las posiciones que la máquina de estados no admite (nunca se bloquea en silencio).
using std;
using std.task;

struct Punto
{
    public int X;
    public async Task Mover() { await Task.Delay(1); }
}

public static class Program
{
    static void Normal()
    {
        await Task.Delay(1);
    }

    static async int MalRetorno()
    {
        return 1;
    }

    static async Task SinValor()
    {
        await Task.Delay(1);
        return 5;
    }

    static async Task<int> FaltaReturn(bool b)
    {
        await Task.Delay(1);
        if (b) return 1;
    }

    static async Task ConRef(ref int x)
    {
        await Task.Delay(1);
    }

    static async Task<bool> Si() => true;

    static async Task Posiciones(Punto p, string s)
    {
        await 5;
        for (int i = 0; await Si(); i++) { }
        try
        {
            await Task.Delay(1);
        }
        catch (Exception e) when (await Si())
        {
        }
        Action a = () => { await Task.Delay(1); };
        Func<Task<int>> f = async () => { await Task.Delay(1); };
    }

    static async Task Main()
    {
        await Posiciones(new Punto(), "x");
    }
}
