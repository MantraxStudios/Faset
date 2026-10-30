// Errores de los iteradores (yield) y de los flujos asíncronos.
using std.collections;
using std.task;

static IEnumerable<int> ConReturn()
{
    yield return 1;
    return;
}

static int NoIterador()
{
    yield return 1;
}

static IEnumerable<int> EnFinally()
{
    try { yield return 1; }
    finally { yield return 2; }
}

static IEnumerable<int> ConAwait()
{
    await Task.Delay(1);
    yield return 1;
}

static async IEnumerable<int> AsyncMal()
{
    yield return 1;
}

static IAsyncEnumerable<int> SinAsync()
{
    yield return 1;
}

static IEnumerable<string> TipoMal()
{
    yield return 5;
}

static IEnumerable<int> ConRef(ref int x)
{
    yield return x;
}

static void Main()
{
    yield break;
    await foreach (int x in SinAsync()) { }
}
