// Hilos: Mutex, RecursiveMutex, ConditionVariable, Semaphore, atómicos,
// ThreadPool, Parallel.For y Channel<T>. La salida es determinista.
// Los hilos reciben su argumento como void* y los atómicos trabajan sobre punteros:
// todo el archivo es un contexto memory_unsafe.
memory_unsafe;
using std.thread;

const int Hilos = 4;
const int Vueltas = 20000;

class Compartido
{
    public Mutex M = new Mutex();
    public RecursiveMutex R = new RecursiveMutex();
    public long Suma;        // protegida por M
    public long SumaR;       // protegida por R
    public int Atomico;      // con Atomic.*
    public AtomicLong Contador = new AtomicLong();
    public long Ids;         // ids distintos de cero
    ~Compartido() { delete M; delete R; delete Contador; }
}

static void Sumar(void* p)
{
    Compartido c = (Compartido)p;
    for (int i = 1; i <= Vueltas; i++)
    {
        c.M.Lock();
        c.Suma += i;
        c.M.Unlock();

        c.R.Lock();
        c.R.Lock();          // recursivo: el mismo hilo lo vuelve a tomar
        c.SumaR += 2;
        c.R.Unlock();
        c.R.Unlock();

        Atomic.Increment(&c.Atomico);
        c.Contador.Add(3);
    }
    if (Thread.CurrentId != 0) Atomic.Increment(&c.Ids);
}

// --- productor/consumidor con ConditionVariable
class Buzon
{
    public Mutex M = new Mutex();
    public ConditionVariable Cv = new ConditionVariable();
    public int Valor;
    public bool Listo;
    ~Buzon() { delete M; delete Cv; }
}

static void Avisar(void* p)
{
    Buzon b = (Buzon)p;
    Thread.Sleep(10);
    b.M.Lock();
    b.Valor = 42;
    b.Listo = true;
    b.M.Unlock();
    b.Cv.NotifyAll();
}

// --- Semaphore
class Turnos
{
    public Semaphore S = new Semaphore(0);
    public int Hechos;
    ~Turnos() { delete S; }
}

static void Trabajar(void* p)
{
    Turnos t = (Turnos)p;
    Atomic.Increment(&t.Hechos);
    t.S.Release();
}

// --- ThreadPool
static void Cuadrado(void* p)
{
    long* v = (long*)p;
    *v = *v * *v;
}

// --- Parallel.For
static void Marcar(int i, void* p)
{
    int* datos = (int*)p;
    datos[i] = i * 2;
}

// --- Channel<T>
static void Producir(void* p)
{
    Channel<int> ch = (Channel<int>)p;
    for (int i = 1; i <= 1000; i++) ch.Send(i);
}

class Consumo
{
    public Channel<int> Ch;
    public long Total;
    public int Recibidos;
}

static void Consumir(void* p)
{
    Consumo c = (Consumo)p;
    int v = 0;
    while (c.Ch.Receive(out v))
    {
        Atomic.Add(&c.Total, v);
        Atomic.Increment(&c.Recibidos);
    }
}

int main()
{
    println(Thread.HardwareConcurrency >= 1);

    // 1. Suma con varios hilos
    Compartido c = new Compartido();
    Thread* ts = new Thread[Hilos];
    for (int i = 0; i < Hilos; i++) ts[i] = Thread.Run(&Sumar, (void*)c);
    for (int i = 0; i < Hilos; i++)
    {
        ts[i].Join();
        delete ts[i];
    }
    delete[] ts;
    println(c.Suma);                  // 4 * 20000 * 20001 / 2
    println(c.SumaR);
    println(c.Atomico);
    println(c.Contador.Value);
    println(c.Ids);

    // 2. Atómicos sueltos
    int x = 5;
    println(Atomic.CompareExchange(&x, 9, 5));   // 5 (anterior), x = 9
    println(Atomic.CompareExchange(&x, 1, 5));   // 9 (no cambia)
    println(Atomic.Exchange(&x, 7));             // 9
    println(Atomic.Load(&x));                    // 7
    Atomic.Store(&x, 11);
    println(Atomic.Decrement(&x));               // 10
    long big = 1;
    Atomic.Add(&big, 4000000000);
    println(Atomic.Load(&big));
    void* ptr = null;
    void* nuevo = (void*)&x;
    println(Atomic.CompareExchange(&ptr, nuevo, null) == null);
    println(Atomic.Load(&ptr) == nuevo);
    Atomic.Fence();
    AtomicInt ai = new AtomicInt(10);
    println(ai.CompareExchange(20, 10));
    println(ai.Value);
    delete ai;

    // 3. ConditionVariable
    Buzon b = new Buzon();
    Thread t = Thread.Run(&Avisar, (void*)b);
    b.M.Lock();
    while (!b.Listo) b.Cv.Wait(b.M);
    println(b.Valor);
    bool avisado = b.Cv.Wait(b.M, 20);   // nadie avisa: vence el plazo
    b.M.Unlock();
    println(avisado);
    t.Join();
    delete t;

    // 4. Semaphore
    Turnos tu = new Turnos();
    Thread* ws = new Thread[Hilos];
    for (int i = 0; i < Hilos; i++) ws[i] = Thread.Run(&Trabajar, (void*)tu);
    for (int i = 0; i < Hilos; i++) tu.S.Wait();
    println(tu.Hechos);
    println(tu.S.TryWait());
    println(tu.S.Wait(10));
    tu.S.Release(2);
    println(tu.S.Count);
    for (int i = 0; i < Hilos; i++)
    {
        ws[i].Join();
        delete ws[i];
    }
    delete[] ws;

    // 5. ThreadPool
    ThreadPool pool = new ThreadPool(3);
    long* nums = new long[50];
    for (int i = 0; i < 50; i++)
    {
        nums[i] = i;
        pool.Submit(&Cuadrado, (void*)(nums + i));
    }
    pool.WaitIdle();
    long sq = 0;
    for (int i = 0; i < 50; i++) sq += nums[i];
    println(sq);                      // suma de i^2, i < 50
    println(pool.Pending);
    delete pool;
    delete[] nums;

    // 6. Parallel.For
    int* datos = new int[1000];
    Parallel.For(0, 1000, &Marcar, (void*)datos);
    long sd = 0;
    for (int i = 0; i < 1000; i++) sd += datos[i];
    println(sd);
    delete[] datos;

    // 7. Channel<T>: 2 productores, 3 consumidores, capacidad 8
    Channel<int> ch = new Channel<int>(8);
    Consumo co = new Consumo();
    co.Ch = ch;
    Thread p1 = Thread.Run(&Producir, (void*)ch);
    Thread p2 = Thread.Run(&Producir, (void*)ch);
    Thread* cs = new Thread[3];
    for (int i = 0; i < 3; i++) cs[i] = Thread.Run(&Consumir, (void*)co);
    p1.Join();
    p2.Join();
    ch.Close();
    for (int i = 0; i < 3; i++)
    {
        cs[i].Join();
        delete cs[i];
    }
    delete[] cs;
    println(co.Recibidos);
    println(co.Total);
    println(ch.Send(1));
    int v = 0;
    println(ch.TryReceive(out v));
    delete p1;
    delete p2;
    delete ch;
    delete co;

    // Canal sin límite, recepción con plazo
    Channel<string> cad = new Channel<string>();
    cad.Send("hola");
    cad.TrySend("mundo");
    string s = "";
    while (cad.Receive(out s, 5)) println(s);
    println(cad.Count);
    delete cad;

    // 8. Hilo desacoplado: el objeto Thread se borra mientras el hilo sigue vivo
    Turnos suelto = new Turnos();
    Thread h = new Thread(&Trabajar, (void*)suelto);
    println(h.IsStarted);
    println(h.Start());
    println(h.Start());               // ya estaba lanzado
    delete h;                         // sin Join: se desacopla
    suelto.S.Wait();
    println(suelto.Hechos);
    delete suelto;

    delete b;
    delete tu;
    delete c;
    return 0;
}
