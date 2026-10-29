// Hilos desde código seguro (sin 'memory_unsafe' en todo el archivo): Thread.Run<T>,
// Thread.Run sin argumentos, ThreadPool.Submit<T>, Parallel.For<T>, AtomicLong y Mutex.
using std.collections;
using std.thread;

class Totales
{
    public Mutex M = new Mutex();
    public long Suma;                          // protegida por M
    public AtomicLong Atomico = new AtomicLong();
    public List<long> Cuadrados = new List<long>();
    ~Totales() { delete M; delete Atomico; delete Cuadrados; }
}

AtomicLong sinArgumentos = new AtomicLong();

void Sumar(Totales t)
{
    for (int i = 1; i <= 10000; i++)
    {
        t.M.Lock();
        t.Suma += i;
        t.M.Unlock();
        t.Atomico.Add(2);
    }
}

void Marcar() { sinArgumentos.Increment(); }

void Trabajo(Totales t) { t.Atomico.Increment(); }

// Cada índice escribe en su propia posición: no hace falta exclusión.
void Cuadrado(int i, Totales t) { t.Cuadrados[i] = (long)i * i; }

void main()
{
    Totales t = new Totales();

    List<Thread> hilos = new List<Thread>();
    for (int i = 0; i < 4; i++) hilos.Add(Thread.Run(&Sumar, t));
    hilos.Add(Thread.Run(&Marcar));
    for (int i = 0; i < hilos.Count; i++)
    {
        hilos[i].Join();
        delete hilos[i];
    }
    delete hilos;
    println(t.Suma);                // 4 * 50005000
    println(t.Atomico.Value);       // 4 * 20000
    println(sinArgumentos.Value);

    ThreadPool pool = new ThreadPool(3);
    for (int i = 0; i < 100; i++) pool.Submit(&Trabajo, t);
    pool.WaitIdle();
    println(t.Atomico.Value);       // + 100
    delete pool;

    for (int i = 0; i < 1000; i++) t.Cuadrados.Add(0);
    Parallel.For(0, 1000, &Cuadrado, t);
    long s = 0;
    for (int i = 0; i < t.Cuadrados.Count; i++) s += t.Cuadrados[i];
    println(s);                     // suma de i^2, i < 1000
    Parallel.For(0, 10, &Cuadrado, t, 2);
    println(t.Cuadrados[9]);

    delete t;
}
