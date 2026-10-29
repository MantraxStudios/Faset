using std.collections;
using std.task;

static int paso = 0;
static int Marca(string s) { paso++; println($"{paso}:{s}"); return paso; }

static async Task<int> Doble(int x)
{
    await Task.Delay(5);
    return x * 2;
}

static async Task<int> Suma(List<int> xs)
{
    int total = 0;
    foreach (var x in xs)
    {
        try
        {
            if (x == 3) throw new InvalidOperationException("tres");
            total += await Doble(x);
        }
        catch (InvalidOperationException e) { println($"saltado {e.Message}"); }
        finally { await Task.Delay(1); }
    }
    return total;
}

static async Task<int> Main()
{
    // orden de evaluación con await en medio: Marca(a) antes de esperar, Marca(b) después
    int r = Marca("a") + await Doble(10) + Marca("b");
    println($"r = {r}");

    var xs = new List<int>();
    for (int i = 1; i <= 4; i++) xs.Add(i);
    println($"suma = {await Suma(xs)}");

    // lambdas async + WhenAll
    var tareas = xs.Select(x => Doble(x));
    var res = await Task.WhenAll(tareas);
    println($"todas = {res.Count} {res[0]} {res[3]}");
    return 0;
}
