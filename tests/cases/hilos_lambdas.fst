// Hilos, ThreadPool y Parallel con lambdas que capturan variables.
using std.thread;
using std.collections;

int main()
{
    var contador = new AtomicInt();
    var hilos = new List<Thread>();
    for (int i = 0; i < 4; i++)
    {
        int id = i;
        hilos.Add(Thread.Run(() => { for (int k = 0; k <= id; k++) contador.Increment(); }));
    }
    for (int i = 0; i < hilos.Count; i++) hilos[i].Join();
    println(contador.Value);

    var cuadrados = new List<long>();
    for (int i = 0; i < 1000; i++) cuadrados.Add(0);
    Parallel.For(0, 1000, i => cuadrados[i] = (long)i * i);
    println(cuadrados.Sum());

    var pool = new ThreadPool(3);
    var total = new AtomicLong();
    for (int i = 1; i <= 100; i++)
    {
        int n = i;
        pool.Submit(() => total.Add(n));
    }
    pool.WaitIdle();
    delete pool;
    println(total.Value);

    var palabras = new List<string>();
    palabras.Add("uno"); palabras.Add("dos"); palabras.Add("tres");
    var letras = new AtomicInt();
    Parallel.ForEach(palabras, p => letras.Add(p.Length));
    println(letras.Value);
    return 0;
}
