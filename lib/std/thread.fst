// =============================================================================
//  std.thread  —  hilos, exclusión mutua, variables de condición y atómicos.
//
//    Thread              hilo del sistema (pthreads en Linux/Android, Win32 en Windows)
//    Mutex               exclusión mutua (pthread_mutex / SRWLOCK)
//    RecursiveMutex      el mismo hilo puede bloquearlo varias veces (CRITICAL_SECTION)
//    ConditionVariable   Wait / Wait con plazo / NotifyOne / NotifyAll
//    Semaphore           semáforo con contador
//    Atomic              Increment, Decrement, Add, Exchange, CompareExchange, Load, Store
//    AtomicInt/AtomicLong contadores atómicos en el heap
//    ThreadPool          hilos fijos que ejecutan trabajos (función + puntero)
//    Parallel            Parallel.For(desde, hasta, cuerpo, dato)
//    Channel<T>          cola segura entre hilos (con o sin capacidad máxima)
//
//  Desde código seguro, los hilos reciben un argumento tipado (cualquier tipo T: lo
//  normal es un objeto de clase compartido, que debe seguir vivo mientras el hilo lo use):
//
//    static void Trabajo(Contador c) { ... }
//    auto t = Thread.Run(&Trabajo, miContador);   // Thread.Run<Contador>
//    t.Join;
//    delete t;
//
//  También hay ThreadPool.Submit<T>, Parallel.For<T> y Thread.Run(&SinArgumentos).
//  Con lambdas (el cierre mantiene vivo lo que captura mientras el hilo lo use):
//
//    auto t = Thread.Run(() => println("hola desde otro hilo"));
//    pool.Submit(() => Procesar(dato));
//    Parallel.For(0, n, i => resultados[i] = Calcular(i));
//  Las versiones con 'void*' (Thread(fn, void*), Thread.Run(fn, void*), Submit(fn, void*),
//  Parallel.For(..., void*)) son 'memory_unsafe'. Para contadores compartidos usa
//  AtomicInt / AtomicLong; la clase Atomic trabaja sobre punteros (memory_unsafe).
//
//  Como el resto de la biblioteca, nada se libera solo: usa 'delete'.
//  En Linux se enlaza automáticamente con -lpthread.
// =============================================================================
using std.collections;

namespace std.thread
{
    // ---------------------------------------------------------------- runtime (atómicos y utilidades)
    static extern int faset_atomic_add_i32(int* p, int v);
    static extern long faset_atomic_add_i64(long* p, long v);
    static extern int faset_atomic_load_i32(int* p);
    static extern long faset_atomic_load_i64(long* p);
    static extern void* faset_atomic_load_ptr(void** p);
    static extern void faset_atomic_store_i32(int* p, int v);
    static extern void faset_atomic_store_i64(long* p, long v);
    static extern void faset_atomic_store_ptr(void** p, void* v);
    static extern int faset_atomic_xchg_i32(int* p, int v);
    static extern long faset_atomic_xchg_i64(long* p, long v);
    static extern void* faset_atomic_xchg_ptr(void** p, void* v);
    static extern int faset_atomic_cas_i32(int* p, int desired, int expected);
    static extern long faset_atomic_cas_i64(long* p, long desired, long expected);
    static extern void* faset_atomic_cas_ptr(void** p, void* desired, void* expected);
    static extern void faset_atomic_fence();
    // Lanza un hilo registrado en el recolector de basura (sus variables son raíces).
    static extern bool faset_thread_spawn(delegate*<void*, void> fn, void* arg, ulong* handle);
    static extern void faset_timespec_after_ms(void* outTimespec, long ms);
    static extern int faset_cpu_count();
    static extern void faset_sleep_ms(long ms);
    static extern long faset_ticks_ms();

    // ---------------------------------------------------------------- bindings del sistema
#if WINDOWS
    static class Win32Threads
    {
        public static extern void* CreateThread(void* attributes, ulong stackSize, delegate*<void*, uint> start, void* arg,
                                                uint flags, uint* threadId);
        public static extern uint WaitForSingleObject(void* handle, uint milliseconds);
        public static extern int CloseHandle(void* handle);
        public static extern uint GetCurrentThreadId();
        public static extern int SwitchToThread();

        public static extern void InitializeSRWLock(void* lock);
        public static extern void AcquireSRWLockExclusive(void* lock);
        public static extern byte TryAcquireSRWLockExclusive(void* lock);
        public static extern void ReleaseSRWLockExclusive(void* lock);

        public static extern void InitializeCriticalSection(void* cs);
        public static extern void DeleteCriticalSection(void* cs);
        public static extern void EnterCriticalSection(void* cs);
        public static extern int TryEnterCriticalSection(void* cs);
        public static extern void LeaveCriticalSection(void* cs);

        public static extern void InitializeConditionVariable(void* cv);
        public static extern int SleepConditionVariableSRW(void* cv, void* lock, uint milliseconds, uint flags);
        public static extern void WakeConditionVariable(void* cv);
        public static extern void WakeAllConditionVariable(void* cv);

        public const uint Infinite = 0xFFFFFFFF;
    }
#else
    static class Posix
    {
        public static extern int pthread_create(ulong* thread, void* attr, delegate*<void*, void*> start, void* arg);
        public static extern int pthread_join(ulong thread, void** result);
        public static extern int pthread_detach(ulong thread);
        public static extern ulong pthread_self();
        public static extern int sched_yield();

        public static extern int pthread_mutex_init(void* mutex, void* attr);
        public static extern int pthread_mutex_destroy(void* mutex);
        public static extern int pthread_mutex_lock(void* mutex);
        public static extern int pthread_mutex_trylock(void* mutex);
        public static extern int pthread_mutex_unlock(void* mutex);
        public static extern int pthread_mutexattr_init(void* attr);
        public static extern int pthread_mutexattr_settype(void* attr, int kind);
        public static extern int pthread_mutexattr_destroy(void* attr);

        public static extern int pthread_cond_init(void* cond, void* attr);
        public static extern int pthread_cond_destroy(void* cond);
        public static extern int pthread_cond_wait(void* cond, void* mutex);
        public static extern int pthread_cond_timedwait(void* cond, void* mutex, void* abstime);
        public static extern int pthread_cond_signal(void* cond);
        public static extern int pthread_cond_broadcast(void* cond);

        // Tamaños generosos para los tipos opacos de pthreads (glibc/bionic, 32 y 64 bits).
        public const int MutexSize = 64;
        public const int CondSize = 64;
        public const int AttrSize = 16;
        public const int TimespecSize = 16;
        public const int RecursiveKind = 1;  // PTHREAD_MUTEX_RECURSIVE (glibc y bionic)
    }
#endif

    // ---------------------------------------------------------------- arranque tipado
    // Caja con la función y el argumento tipados: viaja como void* y se libera en el hilo.
    // Copia el valor de T, así que vale cualquier tipo (clases, structs, enteros, string).
    memory_unsafe class ThreadStart<T>
    {
        public delegate*<T, void> Fn;
        public T Arg;

        public static void Run(void* self)
        {
            ThreadStart<T> b = (ThreadStart<T>)self;
            delegate*<T, void> fn = b.Fn;
            T arg = b.Arg;
            delete b;
            fn(arg);
        }
    }

    // Caja con un delegado (lambdas): viaja como void* hasta el hilo.
    memory_unsafe class ActionStart
    {
        public Action Fn;

        public static void Run(void* self)
        {
            ActionStart b = (ActionStart)self;
            Action fn = b.Fn;
            delete b;
            fn();
        }
    }

    memory_unsafe class ThreadStart0
    {
        public delegate*<void> Fn;

        public static void Run(void* self)
        {
            ThreadStart0 b = (ThreadStart0)self;
            delegate*<void> fn = b.Fn;
            delete b;
            fn();
        }
    }

    // ---------------------------------------------------------------- Thread
    public memory_unsafe class Thread
    {
        delegate*<void*, void> start;
        void* arg;
        ulong handle;   // pthread_t o HANDLE
        bool started;
        bool finished;  // ya se hizo Join o Detach

        // Prepara un hilo que ejecutará start(arg); se lanza con Start. memory_unsafe: el
        // argumento es un puntero sin tipo (desde código seguro usa Thread.Run<T>).
        public memory_unsafe Thread(delegate*<void*, void> start, void* arg)
        {
            this.start = start;
            this.arg = arg;
        }

        // Si nadie hizo Join, el hilo se desacopla: sigue ejecutándose y sus recursos
        // se liberan solos al terminar (no borres 'arg' mientras el hilo lo use).
        ~Thread()
        {
            if (started && !finished) Detach();
        }

        // Crea y lanza un hilo en un solo paso (null si el sistema no pudo crearlo).
        public memory_unsafe static Thread Run(delegate*<void*, void> start, void* arg)
        {
            Thread t = new Thread(start, arg);
            if (!t.Start())
            {
                delete t;
                return null;
            }
            return t;
        }

        // Versión segura: lanza start(arg) con un argumento tipado (se copia; si es un objeto,
        // debe seguir vivo hasta que el hilo termine). null si el sistema no pudo crearlo.
        public static Thread Run<T>(delegate*<T, void> start, T arg)
        {
            ThreadStart<T> b = new ThreadStart<T>();
            b.Fn = start;
            b.Arg = arg;
            Thread t = Run(&ThreadStart<T>.Run, (void*)b);
            if (t == null) delete b;
            return t;
        }

        // Lanza un delegado o una lambda: Thread.Run(() => Trabajo(x)).
        public static Thread Run(Action start)
        {
            ActionStart b = new ActionStart();
            b.Fn = start;
            Thread t = Run(&ActionStart.Run, (void*)b);
            if (t == null) delete b;
            return t;
        }

        // Lanza start sin argumentos.
        public static Thread Run(delegate*<void> start)
        {
            ThreadStart0 b = new ThreadStart0();
            b.Fn = start;
            Thread t = Run(&ThreadStart0.Run, (void*)b);
            if (t == null) delete b;
            return t;
        }

        public bool IsStarted => started;

        // El hilo recibe su propia copia de (start, arg): el objeto Thread puede
        // borrarse mientras el hilo sigue ejecutándose.
        WorkItem* NewBlock()
        {
            WorkItem* b = Memory.New<WorkItem>(1);
            b->Fn = start;
            b->Arg = arg;
            return b;
        }

        static void RunBlock(void* p)
        {
            WorkItem* b = (WorkItem*)p;
            delegate*<void*, void> fn = b->Fn;
            void* a = b->Arg;
            Memory.Free(b);
            fn(a);
        }

#if WINDOWS
        // Lanza el hilo; devuelve false si ya estaba lanzado o el sistema falló.
        public bool Start()
        {
            if (started) return false;
            WorkItem* block = NewBlock();
            ulong h = 0;
            if (!faset_thread_spawn(&RunBlock, (void*)block, &h)) return false;
            handle = h;
            started = true;
            return true;
        }

        // Espera a que el hilo termine.
        public void Join()
        {
            if (!started || finished) return;
            Win32Threads.WaitForSingleObject((void*)handle, Win32Threads.Infinite);
            Win32Threads.CloseHandle((void*)handle);
            finished = true;
        }

        // Deja que el hilo termine por su cuenta (ya no se podrá hacer Join).
        public void Detach()
        {
            if (!started || finished) return;
            Win32Threads.CloseHandle((void*)handle);
            finished = true;
        }

        // Identificador del hilo actual.
        public static long CurrentId => (long)Win32Threads.GetCurrentThreadId();

        // Cede el procesador a otro hilo.
        public static void Yield() { Win32Threads.SwitchToThread(); }
#else
        // Lanza el hilo; devuelve false si ya estaba lanzado o el sistema falló.
        public bool Start()
        {
            if (started) return false;
            WorkItem* block = NewBlock();
            ulong id = 0;
            if (!faset_thread_spawn(&RunBlock, (void*)block, &id)) return false;
            handle = id;
            started = true;
            return true;
        }

        // Espera a que el hilo termine.
        public void Join()
        {
            if (!started || finished) return;
            Posix.pthread_join(handle, null);
            finished = true;
        }

        // Deja que el hilo termine por su cuenta (ya no se podrá hacer Join).
        public void Detach()
        {
            if (!started || finished) return;
            Posix.pthread_detach(handle);
            finished = true;
        }

        // Identificador del hilo actual.
        public static long CurrentId => (long)Posix.pthread_self();

        // Cede el procesador a otro hilo.
        public static void Yield() { Posix.sched_yield(); }
#endif

        // Duerme el hilo actual.
        public static void Sleep(long milliseconds) { faset_sleep_ms(milliseconds); }

        // Número de procesadores lógicos disponibles.
        public static int HardwareConcurrency => faset_cpu_count();
    }

    // ---------------------------------------------------------------- Mutex
    public memory_unsafe class Mutex
    {
        void* handle;

#if WINDOWS
        public Mutex()
        {
            handle = Memory.AllocZeroed(16);  // SRWLOCK (SRWLOCK_INIT = 0)
            Win32Threads.InitializeSRWLock(handle);
        }

        ~Mutex() { Memory.Free(handle); }

        public void Lock() { Win32Threads.AcquireSRWLockExclusive(handle); }
        public bool TryLock() => Win32Threads.TryAcquireSRWLockExclusive(handle) != 0;
        public void Unlock() { Win32Threads.ReleaseSRWLockExclusive(handle); }
#else
        public Mutex()
        {
            handle = Memory.AllocZeroed(Posix.MutexSize);
            Posix.pthread_mutex_init(handle, null);
        }

        ~Mutex()
        {
            Posix.pthread_mutex_destroy(handle);
            Memory.Free(handle);
        }

        public void Lock() { Posix.pthread_mutex_lock(handle); }
        public bool TryLock() => Posix.pthread_mutex_trylock(handle) == 0;
        public void Unlock() { Posix.pthread_mutex_unlock(handle); }
#endif

        // Objeto del sistema (pthread_mutex_t* o SRWLOCK*).
        public void* NativeHandle => handle;
    }

    // ---------------------------------------------------------------- RecursiveMutex
    // El hilo que lo tiene puede volver a bloquearlo; hay que desbloquearlo las mismas veces.
    public memory_unsafe class RecursiveMutex
    {
        void* handle;

#if WINDOWS
        public RecursiveMutex()
        {
            handle = Memory.AllocZeroed(64);  // CRITICAL_SECTION
            Win32Threads.InitializeCriticalSection(handle);
        }

        ~RecursiveMutex()
        {
            Win32Threads.DeleteCriticalSection(handle);
            Memory.Free(handle);
        }

        public void Lock() { Win32Threads.EnterCriticalSection(handle); }
        public bool TryLock() => Win32Threads.TryEnterCriticalSection(handle) != 0;
        public void Unlock() { Win32Threads.LeaveCriticalSection(handle); }
#else
        public RecursiveMutex()
        {
            handle = Memory.AllocZeroed(Posix.MutexSize);
            void* attr = Memory.AllocZeroed(Posix.AttrSize);
            Posix.pthread_mutexattr_init(attr);
            Posix.pthread_mutexattr_settype(attr, Posix.RecursiveKind);
            Posix.pthread_mutex_init(handle, attr);
            Posix.pthread_mutexattr_destroy(attr);
            Memory.Free(attr);
        }

        ~RecursiveMutex()
        {
            Posix.pthread_mutex_destroy(handle);
            Memory.Free(handle);
        }

        public void Lock() { Posix.pthread_mutex_lock(handle); }
        public bool TryLock() => Posix.pthread_mutex_trylock(handle) == 0;
        public void Unlock() { Posix.pthread_mutex_unlock(handle); }
#endif
    }

    // ---------------------------------------------------------------- ConditionVariable
    // Se usa siempre con un Mutex bloqueado por el hilo que espera. Como en C/C++,
    // puede haber despertares espurios: comprueba la condición en un bucle.
    //
    //    m.Lock;
    //    while (!listo) cv.Wait(m);
    //    m.Unlock;
    public memory_unsafe class ConditionVariable
    {
        void* handle;

#if WINDOWS
        public ConditionVariable()
        {
            handle = Memory.AllocZeroed(16);  // CONDITION_VARIABLE
            Win32Threads.InitializeConditionVariable(handle);
        }

        ~ConditionVariable() { Memory.Free(handle); }

        public void Wait(Mutex m) { Win32Threads.SleepConditionVariableSRW(handle, m.NativeHandle, Win32Threads.Infinite, 0); }

        // Espera como mucho 'milliseconds'; devuelve false si venció el plazo.
        public bool Wait(Mutex m, long milliseconds)
        {
            uint ms = milliseconds <= 0 ? 0 : (milliseconds >= 0xFFFFFFFE ? 0xFFFFFFFE : (uint)milliseconds);
            return Win32Threads.SleepConditionVariableSRW(handle, m.NativeHandle, ms, 0) != 0;
        }

        public void NotifyOne() { Win32Threads.WakeConditionVariable(handle); }
        public void NotifyAll() { Win32Threads.WakeAllConditionVariable(handle); }
#else
        public ConditionVariable()
        {
            handle = Memory.AllocZeroed(Posix.CondSize);
            Posix.pthread_cond_init(handle, null);
        }

        ~ConditionVariable()
        {
            Posix.pthread_cond_destroy(handle);
            Memory.Free(handle);
        }

        public void Wait(Mutex m) { Posix.pthread_cond_wait(handle, m.NativeHandle); }

        // Espera como mucho 'milliseconds'; devuelve false si venció el plazo.
        public bool Wait(Mutex m, long milliseconds)
        {
            void* ts = Memory.AllocZeroed(Posix.TimespecSize);  // struct timespec (plazo absoluto)
            faset_timespec_after_ms(ts, milliseconds);
            bool ok = Posix.pthread_cond_timedwait(handle, m.NativeHandle, ts) == 0;
            Memory.Free(ts);
            return ok;
        }

        public void NotifyOne() { Posix.pthread_cond_signal(handle); }
        public void NotifyAll() { Posix.pthread_cond_broadcast(handle); }
#endif
    }

    // ---------------------------------------------------------------- Semaphore
    // (Semaphore, ThreadPool y Channel avisan con el mutex tomado: así quien despierta
    //  puede borrar el objeto en cuanto vuelve, sin que el otro hilo lo siga usando.)
    public memory_unsafe class Semaphore
    {
        Mutex mutex = new Mutex();
        ConditionVariable cv = new ConditionVariable();
        long count;

        public Semaphore(long initialCount) { count = initialCount; }

        ~Semaphore()
        {
            delete cv;
            delete mutex;
        }

        // Resta uno al contador; si es cero, espera a que otro hilo llame a Release.
        public void Wait()
        {
            mutex.Lock();
            while (count <= 0) cv.Wait(mutex);
            count--;
            mutex.Unlock();
        }

        // Como Wait, pero como mucho 'milliseconds'; devuelve false si venció el plazo.
        public bool Wait(long milliseconds)
        {
            long deadline = faset_ticks_ms() + milliseconds;
            mutex.Lock();
            while (count <= 0)
            {
                long left = deadline - faset_ticks_ms();
                if (left <= 0 || !cv.Wait(mutex, left))
                {
                    if (count > 0) break;
                    mutex.Unlock();
                    return false;
                }
            }
            count--;
            mutex.Unlock();
            return true;
        }

        public bool TryWait()
        {
            mutex.Lock();
            bool ok = count > 0;
            if (ok) count--;
            mutex.Unlock();
            return ok;
        }

        public void Release() { Release(1); }

        public void Release(long n)
        {
            if (n <= 0) return;
            mutex.Lock();
            count += n;
            if (n == 1) cv.NotifyOne();
            else cv.NotifyAll();
            mutex.Unlock();
        }

        public long Count
        {
            get
            {
                mutex.Lock();
                long c = count;
                mutex.Unlock();
                return c;
            }
        }
    }

    // ---------------------------------------------------------------- Atomic
    // Operaciones atómicas secuencialmente consistentes sobre memoria compartida:
    //    Atomic.Increment(&contador);
    //    if (Atomic.CompareExchange(&estado, 1, 0) == 0) { ... }   // devuelve el valor anterior
    public memory_unsafe static class Atomic
    {
        // Devuelven el valor nuevo.
        public static int Increment(int* p) => faset_atomic_add_i32(p, 1);
        public static long Increment(long* p) => faset_atomic_add_i64(p, 1);
        public static int Decrement(int* p) => faset_atomic_add_i32(p, -1);
        public static long Decrement(long* p) => faset_atomic_add_i64(p, -1);
        public static int Add(int* p, int v) => faset_atomic_add_i32(p, v);
        public static long Add(long* p, long v) => faset_atomic_add_i64(p, v);

        public static int Load(int* p) => faset_atomic_load_i32(p);
        public static long Load(long* p) => faset_atomic_load_i64(p);
        public static void* Load(void** p) => faset_atomic_load_ptr(p);
        public static void Store(int* p, int v) { faset_atomic_store_i32(p, v); }
        public static void Store(long* p, long v) { faset_atomic_store_i64(p, v); }
        public static void Store(void** p, void* v) { faset_atomic_store_ptr(p, v); }

        // Escriben 'v' y devuelven el valor anterior.
        public static int Exchange(int* p, int v) => faset_atomic_xchg_i32(p, v);
        public static long Exchange(long* p, long v) => faset_atomic_xchg_i64(p, v);
        public static void* Exchange(void** p, void* v) => faset_atomic_xchg_ptr(p, v);

        // Si *p == comparand, escribe 'value'. Siempre devuelve el valor anterior (como en C#).
        public static int CompareExchange(int* p, int value, int comparand) => faset_atomic_cas_i32(p, value, comparand);
        public static long CompareExchange(long* p, long value, long comparand) => faset_atomic_cas_i64(p, value, comparand);
        public static void* CompareExchange(void** p, void* value, void* comparand) => faset_atomic_cas_ptr(p, value, comparand);

        // Barrera de memoria completa.
        public static void Fence() { faset_atomic_fence(); }
    }

    // Contador atómico de 32 bits.
    public memory_unsafe class AtomicInt
    {
        int value;

        public AtomicInt() { }
        public AtomicInt(int initial) { value = initial; }

        public int Value => faset_atomic_load_i32(&value);
        public void Set(int v) { faset_atomic_store_i32(&value, v); }
        public int Increment() => faset_atomic_add_i32(&value, 1);
        public int Decrement() => faset_atomic_add_i32(&value, -1);
        public int Add(int v) => faset_atomic_add_i32(&value, v);
        public int Exchange(int v) => faset_atomic_xchg_i32(&value, v);
        public int CompareExchange(int v, int comparand) => faset_atomic_cas_i32(&value, v, comparand);
        public int* Pointer => &value;
    }

    // Contador atómico de 64 bits.
    public memory_unsafe class AtomicLong
    {
        long value;

        public AtomicLong() { }
        public AtomicLong(long initial) { value = initial; }

        public long Value => faset_atomic_load_i64(&value);
        public void Set(long v) { faset_atomic_store_i64(&value, v); }
        public long Increment() => faset_atomic_add_i64(&value, 1);
        public long Decrement() => faset_atomic_add_i64(&value, -1);
        public long Add(long v) => faset_atomic_add_i64(&value, v);
        public long Exchange(long v) => faset_atomic_xchg_i64(&value, v);
        public long CompareExchange(long v, long comparand) => faset_atomic_cas_i64(&value, v, comparand);
        public long* Pointer => &value;
    }

    // ---------------------------------------------------------------- ThreadPool
    // Hilos fijos que ejecutan trabajos en orden de llegada:
    //    auto pool = new ThreadPool(4);
    //    pool.Submit(&Trabajo, dato);   // Submit<T>: seguro; Submit(fn, void*): memory_unsafe
    //    pool.WaitIdle;     // espera a que no quede nada pendiente
    //    delete pool;         // termina lo pendiente y une los hilos
    public memory_unsafe struct WorkItem
    {
        public delegate*<void*, void> Fn;
        public void* Arg;
    }

    public memory_unsafe class ThreadPool
    {
        Mutex mutex = new Mutex();
        ConditionVariable hasWork = new ConditionVariable();
        ConditionVariable idle = new ConditionVariable();
        Queue<WorkItem> queue = new Queue<WorkItem>();
        Thread* workers;
        int workerCount;
        int active;      // trabajos en ejecución
        bool stopping;

        // Un hilo por procesador lógico.
        public ThreadPool() { Init(faset_cpu_count()); }
        public ThreadPool(int threads) { Init(threads); }

        ~ThreadPool()
        {
            Shutdown();
            delete queue;
            delete idle;
            delete hasWork;
            delete mutex;
        }

        void Init(int threads)
        {
            if (threads < 1) threads = 1;
            workers = new Thread[threads];
            workerCount = threads;
            for (int i = 0; i < threads; i++) workers[i] = Thread.Run(&WorkerLoop, (void*)this);
        }

        public int ThreadCount => workerCount;

        // Encola fn(arg) con un argumento tipado; false si el grupo ya se está cerrando.
        public bool Submit<T>(delegate*<T, void> fn, T arg)
        {
            ThreadStart<T> b = new ThreadStart<T>();
            b.Fn = fn;
            b.Arg = arg;
            if (Submit(&ThreadStart<T>.Run, (void*)b)) return true;
            delete b;
            return false;
        }

        // Encola un delegado o una lambda: pool.Submit(() => Procesar(dato)).
        public bool Submit(Action job)
        {
            ActionStart b = new ActionStart();
            b.Fn = job;
            if (Submit(&ActionStart.Run, (void*)b)) return true;
            delete b;
            return false;
        }

        // Encola fn(arg); devuelve false si el grupo ya se está cerrando.
        public memory_unsafe bool Submit(delegate*<void*, void> fn, void* arg)
        {
            WorkItem w = new WorkItem();
            w.Fn = fn;
            w.Arg = arg;
            mutex.Lock();
            if (stopping)
            {
                mutex.Unlock();
                return false;
            }
            queue.Enqueue(w);
            hasWork.NotifyOne();
            mutex.Unlock();
            return true;
        }

        // Trabajos en cola o en ejecución.
        public int Pending
        {
            get
            {
                mutex.Lock();
                int n = queue.Count + active;
                mutex.Unlock();
                return n;
            }
        }

        // Espera a que la cola esté vacía y ningún trabajo se esté ejecutando.
        public void WaitIdle()
        {
            mutex.Lock();
            while (queue.Count > 0 || active > 0) idle.Wait(mutex);
            mutex.Unlock();
        }

        // Ejecuta lo que quede en la cola y une los hilos (lo llama el destructor).
        public void Shutdown()
        {
            if (workers == null) return;
            mutex.Lock();
            stopping = true;
            hasWork.NotifyAll();
            mutex.Unlock();
            for (int i = 0; i < workerCount; i++)
            {
                if (workers[i] == null) continue;
                workers[i].Join();
                delete workers[i];
            }
            delete[] workers;
            workers = null;
            workerCount = 0;
        }

        static void WorkerLoop(void* self)
        {
            ThreadPool p = (ThreadPool)self;
            p.mutex.Lock();
            for (;;)
            {
                while (p.queue.Count == 0 && !p.stopping) p.hasWork.Wait(p.mutex);
                if (p.queue.Count == 0) break;  // cerrando y sin trabajo
                WorkItem w = p.queue.Dequeue();
                p.active++;
                p.mutex.Unlock();
                w.Fn(w.Arg);
                p.mutex.Lock();
                p.active--;
                if (p.queue.Count == 0 && p.active == 0) p.idle.NotifyAll();
            }
            p.mutex.Unlock();
        }
    }

    // ---------------------------------------------------------------- Parallel
    memory_unsafe class ParallelBody<T>
    {
        public delegate*<int, T, void> Fn;
        public T Arg;

        public static void Call(int i, void* self)
        {
            ParallelBody<T> b = (ParallelBody<T>)self;
            b.Fn(i, b.Arg);
        }
    }

    memory_unsafe class ParallelAction
    {
        public Action<int> Fn;

        public static void Call(int i, void* self)
        {
            ParallelAction b = (ParallelAction)self;
            b.Fn(i);
        }
    }

    public memory_unsafe static class Parallel
    {
        // Ejecuta body(i) para cada i en [fromInclusive, toExclusive) en varios hilos (el orden no
        // está definido): Parallel.For(0, n, i => datos[i] = Calcular(i)).
        public static void For(int fromInclusive, int toExclusive, Action<int> body)
        {
            For(fromInclusive, toExclusive, body, faset_cpu_count());
        }

        public static void For(int fromInclusive, int toExclusive, Action<int> body, int maxThreads)
        {
            ParallelAction b = new ParallelAction();
            b.Fn = body;
            For(fromInclusive, toExclusive, &ParallelAction.Call, (void*)b, maxThreads);
            delete b;
        }

        // body(elemento) para cada elemento de la lista, en varios hilos.
        public static void ForEach<T>(List<T> items, Action<T> body)
        {
            For(0, items.Count, i => body(items[i]));
        }

        // Ejecuta body(i, arg) para cada i en [fromInclusive, toExclusive) repartiendo los
        // índices entre los procesadores; vuelve cuando han terminado todos. El orden no está
        // definido. 'arg' se comparte entre los hilos: si es un objeto, protégelo (Mutex,
        // AtomicLong...) o escribe en posiciones distintas.
        public static void For<T>(int fromInclusive, int toExclusive, delegate*<int, T, void> body, T arg)
        {
            For<T>(fromInclusive, toExclusive, body, arg, faset_cpu_count());
        }

        // Igual, con un número máximo de hilos (incluido el que llama).
        public static void For<T>(int fromInclusive, int toExclusive, delegate*<int, T, void> body, T arg, int maxThreads)
        {
            ParallelBody<T> b = new ParallelBody<T>();
            b.Fn = body;
            b.Arg = arg;
            For(fromInclusive, toExclusive, &ParallelBody<T>.Call, (void*)b, maxThreads);
            delete b;
        }

        // Versiones con puntero sin tipo (memory_unsafe).
        public memory_unsafe static void For(int fromInclusive, int toExclusive, delegate*<int, void*, void> body, void* arg)
        {
            For(fromInclusive, toExclusive, body, arg, faset_cpu_count());
        }

        public memory_unsafe static void For(int fromInclusive, int toExclusive, delegate*<int, void*, void> body, void* arg, int maxThreads)
        {
            int n = toExclusive - fromInclusive;
            if (n <= 0) return;
            if (maxThreads < 1) maxThreads = 1;
            int threads = n < maxThreads ? n : maxThreads;
            ParallelRange r = new ParallelRange();
            r.Next = fromInclusive;
            r.End = toExclusive;
            r.Body = body;
            r.Arg = arg;
            int chunk = n / (threads * 8);
            r.Chunk = chunk < 1 ? 1 : chunk;
            Thread* extra = new Thread[threads];
            for (int i = 1; i < threads; i++) extra[i] = Thread.Run(&ParallelRange.Run, (void*)r);
            ParallelRange.Run((void*)r);  // el hilo que llama también trabaja
            for (int i = 1; i < threads; i++)
            {
                if (extra[i] == null) continue;
                extra[i].Join();
                delete extra[i];
            }
            delete[] extra;
            delete r;
        }
    }

    memory_unsafe class ParallelRange
    {
        public long Next;
        public int End;
        public int Chunk;
        public delegate*<int, void*, void> Body;
        public void* Arg;

        public static void Run(void* self)
        {
            ParallelRange r = (ParallelRange)self;
            for (;;)
            {
                long start = faset_atomic_add_i64(&r.Next, r.Chunk) - r.Chunk;
                if (start >= r.End) return;
                long stop = start + r.Chunk;
                if (stop > r.End) stop = r.End;
                for (int i = (int)start; i < (int)stop; i++) r.Body(i, r.Arg);
            }
        }
    }

    // ---------------------------------------------------------------- Channel<T>
    // Cola segura entre hilos (productor/consumidor). Con capacidad > 0, Send espera
    // mientras esté llena; con capacidad 0 no tiene límite. Tras Close, los
    // receptores vacían lo que quede y después Receive devuelve false.
    //
    //    auto ch = new Channel<int>(16);
    //    ch.Send(42);                         // productor
    //    int v;
    //    while (ch.Receive(out v)) { ... }    // consumidor
    public memory_unsafe class Channel<T>
    {
        Mutex mutex = new Mutex();
        ConditionVariable notEmpty = new ConditionVariable();
        ConditionVariable notFull = new ConditionVariable();
        T* items;
        int head;
        int count;
        int capacity;  // tamaño del búfer
        int limit;     // 0 = sin límite
        bool closed;

        public Channel() { }
        public Channel(int capacity)
        {
            limit = capacity < 0 ? 0 : capacity;
            if (limit > 0) Grow(limit);
        }

        ~Channel()
        {
            Memory.Free(items);
            delete notFull;
            delete notEmpty;
            delete mutex;
        }

        void Grow(int n)
        {
            T* fresh = Memory.New<T>(n);
            for (int i = 0; i < count; i++) fresh[i] = items[(head + i) % capacity];
            Memory.Free(items);
            items = fresh;
            head = 0;
            capacity = n;
        }

        void Push(T item)
        {
            if (count == capacity) Grow(capacity < 8 ? 8 : capacity * 2);
            items[(head + count) % capacity] = item;
            count++;
        }

        // Envía (esperando si la cola está llena); devuelve false si el canal está cerrado.
        public bool Send(T item)
        {
            mutex.Lock();
            while (limit > 0 && count >= limit && !closed) notFull.Wait(mutex);
            if (closed)
            {
                mutex.Unlock();
                return false;
            }
            Push(item);
            notEmpty.NotifyOne();
            mutex.Unlock();
            return true;
        }

        // Envía sin esperar; false si está llena o cerrada.
        public bool TrySend(T item)
        {
            mutex.Lock();
            if (closed || (limit > 0 && count >= limit))
            {
                mutex.Unlock();
                return false;
            }
            Push(item);
            notEmpty.NotifyOne();
            mutex.Unlock();
            return true;
        }

        // Recibe (esperando si está vacía); false si está cerrada y vacía.
        public bool Receive(out T item)
        {
            mutex.Lock();
            while (count == 0 && !closed) notEmpty.Wait(mutex);
            return Take(out item);
        }

        // Como Receive, pero espera como mucho 'milliseconds'.
        public bool Receive(out T item, long milliseconds)
        {
            long deadline = faset_ticks_ms() + milliseconds;
            mutex.Lock();
            while (count == 0 && !closed)
            {
                long left = deadline - faset_ticks_ms();
                if (left <= 0) break;
                notEmpty.Wait(mutex, left);
            }
            return Take(out item);
        }

        // Recibe sin esperar; false si no hay nada.
        public bool TryReceive(out T item)
        {
            mutex.Lock();
            return Take(out item);
        }

        // Se llama con el mutex bloqueado y lo desbloquea.
        bool Take(out T item)
        {
            if (count == 0)
            {
                item = default(T);
                mutex.Unlock();
                return false;
            }
            item = items[head];
            head = (head + 1) % capacity;
            count--;
            if (limit > 0) notFull.NotifyOne();
            mutex.Unlock();
            return true;
        }

        // Cierra el canal: Send falla y los receptores terminan cuando se vacía.
        public void Close()
        {
            mutex.Lock();
            closed = true;
            notEmpty.NotifyAll();
            notFull.NotifyAll();
            mutex.Unlock();
        }

        public bool IsClosed
        {
            get
            {
                mutex.Lock();
                bool c = closed;
                mutex.Unlock();
                return c;
            }
        }

        public int Count
        {
            get
            {
                mutex.Lock();
                int n = count;
                mutex.Unlock();
                return n;
            }
        }

        // Capacidad máxima (0 = sin límite).
        public int Capacity => limit;
    }
}
