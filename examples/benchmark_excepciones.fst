// Coste de las excepciones: entrar en un 'try' (sin lanzar), lanzar y atrapar, y el
// mismo trabajo sin 'try'. Compílalo en Release:
//   faset run --release examples/benchmark_excepciones.fst
using std.time;

func Trabajo(i: int) -> int
{
    // Algo que el compilador de C no puede eliminar.
    return (i * 7 + 3) % 1000;
}

func TrabajoQueFalla(i: int) -> int
{
    if (i >= 0) throw new InvalidOperationException("fallo");
    return i;
}

func Profundo(nivel: int) -> int
{
    if (nivel == 0) throw new FormatException("abajo");
    return Profundo(nivel - 1) + 1;
}

func Medir(nombre: string, ns: long, n: long)
{
    double porOp = (double)ns / n;
    println(nombre + ": " + (ns / 1000000) + " ms, " + ((long)(porOp * 10)) / 10.0 + " ns por operación");
}

func main()
{
    const int N = 50000000;
    long suma = 0;

    long t0 = Time.TickNs();
    for (int i = 0; i < N; i++) suma += Trabajo(i);
    long sinTry = Time.TickNs() - t0;
    Medir("sin try", sinTry, N);

    t0 = Time.TickNs();
    for (int i = 0; i < N; i++)
    {
        try { suma += Trabajo(i); }
        catch (Exception) { suma--; }
    }
    long conTry = Time.TickNs() - t0;
    Medir("try/catch sin lanzar", conTry, N);
    println("  coste de entrar en un try: " + ((conTry - sinTry) * 10 / N) / 10.0 + " ns");

    t0 = Time.TickNs();
    for (int i = 0; i < N; i++)
    {
        try { suma += Trabajo(i); }
        finally { suma++; }
    }
    long conFinally = Time.TickNs() - t0;
    Medir("try/finally sin lanzar", conFinally, N);

    const int M = 2000000;
    t0 = Time.TickNs();
    for (int i = 0; i < M; i++)
    {
        try { suma += TrabajoQueFalla(i); }
        catch (InvalidOperationException e) { suma += e.Message.Length; }
    }
    Medir("throw + catch (1 nivel)", Time.TickNs() - t0, M);

    t0 = Time.TickNs();
    for (int i = 0; i < M; i++)
    {
        try { suma += Profundo(10); }
        catch (FormatException e) { suma += 1; }
    }
    Medir("throw + catch (10 niveles)", Time.TickNs() - t0, M);

    t0 = Time.TickNs();
    for (int i = 0; i < M; i++)
    {
        try
        {
            try { suma += TrabajoQueFalla(i); }
            finally { suma++; }
        }
        catch (Exception) { suma--; }
    }
    Medir("throw + finally + catch", Time.TickNs() - t0, M);

    int cero = 0;
    t0 = Time.TickNs();
    for (int i = 0; i < M; i++)
    {
        try { suma += i / cero; }
        catch (DivideByZeroException) { suma++; }
    }
    Medir("error del runtime (división por cero)", Time.TickNs() - t0, M);

    println(suma != 42);
}
