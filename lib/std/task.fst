// =============================================================================
//  std.task  —  tareas asíncronas: Task, Task<T>, async / await y cancelación.
//
//    Task / Task<T>             operación en curso (o terminada) con su resultado o su excepción
//    Task.Run(() => ...)        ejecuta en el grupo de hilos
//    Task.Delay(ms)             tarea que termina pasado el plazo (un temporizador, sin ocupar hilos)
//    Task.WhenAll / WhenAny     esperar a varias tareas
//    Task.FromResult(v), Task.CompletedTask
//    t.Result, t.Wait()         esperar bloqueando el hilo
//    t.ContinueWith(t => ...)   continuación
//    CancellationTokenSource / CancellationToken   cancelación cooperativa
//    SynchronizationContext     dónde siguen los métodos async tras un 'await'
//
//  Métodos async (el compilador los convierte en máquinas de estados; ver docs "async y await"):
//
//    static async Task<int> Sumar(int a, int b)
//    {
//        await Task.Delay(100);         // no bloquea: el método se suspende y vuelve después
//        return a + b;
//    }
//    static async Task Main()
//    {
//        int r = await Sumar(1, 2);
//        Console.WriteLine(r);
//    }
//
//  Una excepción no atrapada dentro de una tarea se guarda en ella (IsFaulted, Exception) y la
//  vuelven a lanzar 'await', Result y Wait(). OperationCanceledException deja la tarea cancelada.
//
//  Planificación: tras un 'await', el método sigue en el SynchronizationContext que había al
//  esperar (en una aplicación std.ui, el hilo de la interfaz); si no había ninguno, en un hilo del
//  grupo de hilos de las tareas.
// =============================================================================
using std.collections;
using std.thread;

namespace std.task
{
    // ---------------------------------------------------------------- runtime
    static extern void faset_exc_rethrow_obj(void* e);
    static extern bool faset_exc_is_named(void* e, string name);
    static extern void* faset_sync_ctx_get();
    static extern void faset_sync_ctx_set(void* c);
    static extern long faset_ticks_ms();
    static extern int faset_cpu_count();
    // Cerrojo y variable de condición globales de las tareas (objetos de C: no dependen del orden de
    // inicialización de los campos estáticos de los módulos).
    static extern void faset_task_lock();
    static extern void faset_task_unlock();
    static extern void faset_task_notify();
    static extern void faset_task_wait(long milliseconds);

    public enum TaskStatus { Running, RanToCompletion, Faulted, Canceled }

    // ---------------------------------------------------------------- excepciones
    // Una tarea cancelada (Task.Delay con un token cancelado, CancellationToken...).
    public class TaskCanceledException : OperationCanceledException
    {
        public TaskCanceledException() { Message = "Se canceló una tarea."; }
        public TaskCanceledException(string message) { Message = message; }
    }

    // Varias excepciones (Task.WhenAll guarda aquí todas las de sus tareas; await lanza la primera).
    public class AggregateException : Exception
    {
        public List<Exception> InnerExceptions = new List<Exception>();

        public AggregateException() { Message = "Se produjeron uno o varios errores."; }
        public AggregateException(List<Exception> inner)
        {
            Message = "Se produjeron uno o varios errores.";
            for (int i = 0; i < inner.Count; i++) InnerExceptions.Add(inner[i]);
            if (inner.Count > 0) InnerException = inner[0];
        }
    }

    // ---------------------------------------------------------------- planificadores
    // Dónde se ejecutan las continuaciones. Por defecto, en el grupo de hilos de las tareas;
    // std.ui instala uno propio en el hilo de la interfaz (los 'await' vuelven a ese hilo).
    public memory_unsafe class SynchronizationContext
    {
        static List<SynchronizationContext> installed;

        // Ejecuta 'action' en este contexto, más tarde (sin esperar a que termine).
        public virtual void Post(Action action) { TaskScheduler.Queue(action); }

        // El contexto del hilo actual (null: ninguno, las continuaciones van al grupo de hilos).
        public static SynchronizationContext Current => (SynchronizationContext)faset_sync_ctx_get();

        // Instala 'context' como contexto del hilo actual.
        public static void SetSynchronizationContext(SynchronizationContext context)
        {
            if (context != null)
            {
                faset_task_lock();  // el puntero por hilo no es una raíz del recolector: se guarda aquí
                if (installed == null) installed = new List<SynchronizationContext>();
                if (!installed.Contains(context)) installed.Add(context);
                faset_task_unlock();
            }
            faset_sync_ctx_set((void*)context);
        }
    }

    // Grupo de hilos de las tareas (se crea al usarlo por primera vez).
    public memory_unsafe static class TaskScheduler
    {
        static ThreadPool pool;

        // Hilos del grupo: el número de procesadores (al menos 4).
        public static int ThreadCount
        {
            get
            {
                Pool();
                return pool.ThreadCount;
            }
        }

        static ThreadPool Pool()
        {
            faset_task_lock();
            if (pool == null)
            {
                int n = faset_cpu_count();
                if (n < 4) n = 4;
                pool = new ThreadPool(n);
            }
            ThreadPool p = pool;
            faset_task_unlock();
            return p;
        }

        // Encola 'action' en el grupo de hilos.
        public static void Queue(Action action) { Pool().Submit(action); }
    }

    // Continuación pendiente de una tarea.
    memory_unsafe class TaskContinuation
    {
        public Action Fn;
        public SynchronizationContext Context;  // null: grupo de hilos
        public TaskContinuation Next;
    }

    // ---------------------------------------------------------------- Task
    public memory_unsafe class Task
    {
        // Un cerrojo y una variable de condición para todas las tareas (los cambios son cortos):
        // faset_task_lock / faset_task_wait / faset_task_notify.
        static Task completed;

        internal int state;  // 0 en curso, 1 completada, 2 con error, 3 cancelada
        internal Exception error;
        TaskContinuation conts;

        public Task() { }

        // ---- estado
        public bool IsCompleted => State() != 0;
        public bool IsCompletedSuccessfully => State() == 1;
        public bool IsFaulted => State() == 2;
        public bool IsCanceled => State() == 3;

        public TaskStatus Status
        {
            get
            {
                int s = State();
                return s == 0 ? TaskStatus.Running : s == 1 ? TaskStatus.RanToCompletion
                     : s == 2 ? TaskStatus.Faulted : TaskStatus.Canceled;
            }
        }

        // La excepción que hizo fallar la tarea (null si no falló; también si se canceló).
        public Exception Exception
        {
            get
            {
                faset_task_lock();
                Exception e = state == 2 ? error : null;
                faset_task_unlock();
                return e;
            }
        }

        internal int State()
        {
            faset_task_lock();
            int s = state;
            faset_task_unlock();
            return s;
        }

        // ---- terminar (TaskCompletionSource también los usa)
        internal bool Finish(int st, Exception e)
        {
            faset_task_lock();
            if (state != 0)
            {
                faset_task_unlock();
                return false;
            }
            state = st;
            error = e;
            TaskContinuation list = conts;
            conts = null;
            faset_task_notify();
            faset_task_unlock();
            // Las continuaciones se registraron al revés (lista enlazada): se lanzan en orden.
            TaskContinuation ordered = null;
            while (list != null)
            {
                TaskContinuation next = list.Next;
                list.Next = ordered;
                ordered = list;
                list = next;
            }
            while (ordered != null)
            {
                Dispatch(ordered.Fn, ordered.Context);
                ordered = ordered.Next;
            }
            return true;
        }

        static void Dispatch(Action fn, SynchronizationContext ctx)
        {
            if (ctx != null) ctx.Post(fn);
            else TaskScheduler.Queue(fn);
        }

        public bool TrySetResult() => Finish(1, null);

        public void SetResult()
        {
            if (!Finish(1, null)) throw new InvalidOperationException("La tarea ya había terminado.");
        }

        // Una OperationCanceledException deja la tarea cancelada; cualquier otra, con error.
        public bool TrySetException(Exception e)
        {
            if (e == null) e = new Exception("Excepción nula en una tarea.");
            return Finish(faset_exc_is_named((void*)e, "OperationCanceledException") ? 3 : 2, e);
        }

        public void SetException(Exception e)
        {
            if (!TrySetException(e)) throw new InvalidOperationException("La tarea ya había terminado.");
        }

        public bool TrySetCanceled() => Finish(3, new TaskCanceledException());

        // ---- await (el patrón que usa el compilador)
        public Task GetAwaiter() => this;

        // Registra la continuación de un 'await': correrá en el SynchronizationContext actual (o en el
        // grupo de hilos) cuando la tarea termine; si ya terminó, se encola enseguida.
        public void OnCompleted(Action continuation) { AddContinuation(continuation, SynchronizationContext.Current); }

        // Como OnCompleted, pero siempre en el grupo de hilos (ConfigureAwait(false)).
        public void OnCompletedAnywhere(Action continuation) { AddContinuation(continuation, null); }

        internal void AddContinuation(Action fn, SynchronizationContext ctx)
        {
            faset_task_lock();
            if (state == 0)
            {
                TaskContinuation c = new TaskContinuation();
                c.Fn = fn;
                c.Context = ctx;
                c.Next = conts;
                conts = c;
                faset_task_unlock();
                return;
            }
            faset_task_unlock();
            Dispatch(fn, ctx);
        }

        // Fin de un 'await': lanza la excepción de la tarea si falló o se canceló.
        public void GetResult()
        {
            Wait();
        }

        internal void ThrowIfFailed()
        {
            if (state >= 2) faset_exc_rethrow_obj((void*)error);
        }

        // ---- esperar bloqueando (¡no en el hilo de la interfaz si la tarea necesita volver a él!)
        public void Wait()
        {
            faset_task_lock();
            while (state == 0) faset_task_wait(-1);
            faset_task_unlock();
            ThrowIfFailed();
        }

        // Espera como mucho 'milliseconds'; false si la tarea no terminó a tiempo.
        public bool Wait(int milliseconds)
        {
            long deadline = faset_ticks_ms() + milliseconds;
            faset_task_lock();
            while (state == 0)
            {
                long left = deadline - faset_ticks_ms();
                if (left <= 0) break;
                faset_task_wait(left);
            }
            bool done = state != 0;
            faset_task_unlock();
            if (done) ThrowIfFailed();
            return done;
        }

        // await t.ConfigureAwait(false): la continuación no vuelve al contexto (sigue en el grupo de hilos).
        public ConfiguredTaskAwaitable ConfigureAwait(bool continueOnCapturedContext)
        {
            return new ConfiguredTaskAwaitable(this, continueOnCapturedContext);
        }

        // ---- continuaciones
        // 'action' se ejecuta (en el grupo de hilos) cuando esta tarea termine, haya ido bien o no.
        public Task ContinueWith(Action<Task> action)
        {
            Task next = new Task();
            Task self = this;
            AddContinuation(() =>
            {
                try
                {
                    action(self);
                    next.TrySetResult();
                }
                catch (Exception e)
                {
                    next.TrySetException(e);
                }
            }, null);
            return next;
        }

        public Task<R> ContinueWith<R>(Func<Task, R> fn)
        {
            Task<R> next = new Task<R>();
            Task self = this;
            AddContinuation(() =>
            {
                try
                {
                    next.TrySetResult(fn(self));
                }
                catch (Exception e)
                {
                    next.TrySetException(e);
                }
            }, null);
            return next;
        }

        // ---- fábricas
        public static Task CompletedTask
        {
            get
            {
                faset_task_lock();
                if (completed == null)
                {
                    completed = new Task();
                    completed.state = 1;
                }
                Task t = completed;
                faset_task_unlock();
                return t;
            }
        }

        public static Task<T> FromResult<T>(T value)
        {
            Task<T> t = new Task<T>();
            t.TrySetResult(value);
            return t;
        }

        public static Task FromException(Exception e)
        {
            Task t = new Task();
            t.TrySetException(e);
            return t;
        }

        public static Task FromCanceled()
        {
            Task t = new Task();
            t.TrySetCanceled();
            return t;
        }

        // Ejecuta 'action' en el grupo de hilos.
        public static Task Run(Action action)
        {
            Task t = new Task();
            TaskScheduler.Queue(() =>
            {
                try
                {
                    action();
                    t.TrySetResult();
                }
                catch (Exception e)
                {
                    t.TrySetException(e);
                }
            });
            return t;
        }

        public static Task<T> Run<T>(Func<T> fn)
        {
            Task<T> t = new Task<T>();
            TaskScheduler.Queue(() =>
            {
                try
                {
                    t.TrySetResult(fn());
                }
                catch (Exception e)
                {
                    t.TrySetException(e);
                }
            });
            return t;
        }

        // Task.Run(async () => { ... }): la tarea devuelta termina cuando termina la interior.
        public static Task Run(Func<Task> fn)
        {
            Task t = new Task();
            TaskScheduler.Queue(() =>
            {
                try
                {
                    Task inner = fn();
                    inner.AddContinuation(() => t.CopyFrom(inner), null);
                }
                catch (Exception e)
                {
                    t.TrySetException(e);
                }
            });
            return t;
        }

        public static Task<T> Run<T>(Func<Task<T>> fn)
        {
            Task<T> t = new Task<T>();
            TaskScheduler.Queue(() =>
            {
                try
                {
                    Task<T> inner = fn();
                    inner.AddContinuation(() => t.CopyFrom(inner), null);
                }
                catch (Exception e)
                {
                    t.TrySetException(e);
                }
            });
            return t;
        }

        internal void CopyFrom(Task other)
        {
            int s = other.State();
            if (s == 1) TrySetResult();
            else Finish(s, other.error);
        }

        // Tarea que termina dentro de 'milliseconds' (la completa el hilo de los temporizadores).
        public static Task Delay(int milliseconds)
        {
            Task t = new Task();
            if (milliseconds <= 0)
            {
                t.TrySetResult();
                return t;
            }
            TaskTimers.Add(t, faset_ticks_ms() + milliseconds);
            return t;
        }

        // Igual, pero se cancela (TaskCanceledException) si se cancela el token antes del plazo.
        public static Task Delay(int milliseconds, CancellationToken token)
        {
            if (token.IsCancellationRequested) return FromCanceled();
            Task t = Delay(milliseconds);
            if (token.CanBeCanceled) token.Register(() => { t.TrySetCanceled(); });
            return t;
        }

        // Cede el hilo: 'await Task.Yield()' suspende siempre y el resto del método sigue más tarde
        // (en el contexto actual o en el grupo de hilos).
        public static YieldAwaitable Yield() => new YieldAwaitable();

        // Termina cuando terminan todas (con error si alguna falla: la primera excepción).
        public static Task WhenAll(params List<Task> tasks)
        {
            Task all = new Task();
            int n = tasks.Count;
            if (n == 0)
            {
                all.TrySetResult();
                return all;
            }
            WhenAllState st = new WhenAllState();
            st.Pending = n;
            st.All = all;
            st.Tasks = new List<Task>();
            for (int i = 0; i < n; i++) st.Tasks.Add(tasks[i]);
            for (int i = 0; i < n; i++) st.Tasks[i].AddContinuation(() => st.OneDone(), null);
            return all;
        }

        // Con resultados: una lista con el de cada tarea, en el mismo orden.
        public static Task<List<T>> WhenAll<T>(params List<Task<T>> tasks)
        {
            Task<List<T>> all = new Task<List<T>>();
            List<Task> plain = new List<Task>();
            for (int i = 0; i < tasks.Count; i++) plain.Add(tasks[i]);
            List<Task<T>> copy = new List<Task<T>>();
            for (int i = 0; i < tasks.Count; i++) copy.Add(tasks[i]);
            Task done = WhenAll(plain);
            done.AddContinuation(() =>
            {
                int s = done.State();
                if (s != 1)
                {
                    all.Finish(s, done.error);
                    return;
                }
                List<T> values = new List<T>();
                for (int i = 0; i < copy.Count; i++) values.Add(copy[i].value);
                all.TrySetResult(values);
            }, null);
            return all;
        }

        // Termina cuando termina la primera; su resultado es esa tarea.
        public static Task<Task> WhenAny(params List<Task> tasks)
        {
            Task<Task> any = new Task<Task>();
            for (int i = 0; i < tasks.Count; i++)
            {
                Task t = tasks[i];
                t.AddContinuation(() => { any.TrySetResult(t); }, null);
            }
            return any;
        }

        // Main async (lo llama el main de C generado): espera y relanza la excepción si falló.
        public static void RunMain(Task t) { t.Wait(); }
    }

    // Estado compartido de Task.WhenAll.
    memory_unsafe class WhenAllState
    {
        public int Pending;
        public Task All;
        public List<Task> Tasks;

        public void OneDone()
        {
            faset_task_lock();
            Pending--;
            bool last = Pending == 0;
            faset_task_unlock();
            if (!last) return;
            List<Exception> errors = new List<Exception>();
            bool canceled = false;
            for (int i = 0; i < Tasks.Count; i++)
            {
                int s = Tasks[i].State();
                if (s == 2) errors.Add(Tasks[i].error);
                else if (s == 3) canceled = true;
            }
            if (errors.Count > 0) All.Finish(2, errors[0]);
            else if (canceled) All.TrySetCanceled();
            else All.TrySetResult();
        }
    }

    // Task.Yield(): nunca está completa, así que 'await' siempre suspende y sigue más tarde.
    public memory_unsafe class YieldAwaitable
    {
        public YieldAwaitable GetAwaiter() => this;
        public bool IsCompleted => false;
        public void OnCompleted(Action continuation)
        {
            SynchronizationContext ctx = SynchronizationContext.Current;
            if (ctx != null) ctx.Post(continuation);
            else TaskScheduler.Queue(continuation);
        }
        public void GetResult() { }
    }

    // ---------------------------------------------------------------- Task<T>
    public memory_unsafe class Task<T> : Task
    {
        internal T value;

        public Task() { }

        // El resultado (espera bloqueando si aún no terminó; lanza la excepción si falló).
        public T Result
        {
            get
            {
                Wait();
                return value;
            }
        }

        public new Task<T> GetAwaiter() => this;

        public new T GetResult()
        {
            Wait();
            return value;
        }

        public bool TrySetResult(T v)
        {
            faset_task_lock();
            if (state != 0)
            {
                faset_task_unlock();
                return false;
            }
            value = v;
            faset_task_unlock();
            return Finish(1, null);
        }

        public void SetResult(T v)
        {
            if (!TrySetResult(v)) throw new InvalidOperationException("La tarea ya había terminado.");
        }

        internal void CopyFrom(Task<T> other)
        {
            int s = other.State();
            if (s == 1) TrySetResult(other.value);
            else Finish(s, other.error);
        }

        public new ConfiguredTaskAwaitable<T> ConfigureAwait(bool continueOnCapturedContext)
        {
            return new ConfiguredTaskAwaitable<T>(this, continueOnCapturedContext);
        }

        public Task ContinueWith(Action<Task<T>> action)
        {
            Task next = new Task();
            Task<T> self = this;
            AddContinuation(() =>
            {
                try
                {
                    action(self);
                    next.TrySetResult();
                }
                catch (Exception e)
                {
                    next.TrySetException(e);
                }
            }, null);
            return next;
        }

        public Task<R> ContinueWith<R>(Func<Task<T>, R> fn)
        {
            Task<R> next = new Task<R>();
            Task<T> self = this;
            AddContinuation(() =>
            {
                try
                {
                    next.TrySetResult(fn(self));
                }
                catch (Exception e)
                {
                    next.TrySetException(e);
                }
            }, null);
            return next;
        }
    }

    // ---------------------------------------------------------------- ConfigureAwait
    // Un 'awaitable' propio: GetAwaiter/IsCompleted/OnCompleted/GetResult (el mismo patrón que Task).
    public memory_unsafe class ConfiguredTaskAwaitable
    {
        Task task;
        bool capture;

        public ConfiguredTaskAwaitable(Task task, bool capture)
        {
            this.task = task;
            this.capture = capture;
        }

        public ConfiguredTaskAwaitable GetAwaiter() => this;
        public bool IsCompleted => task.IsCompleted;
        public void OnCompleted(Action continuation)
        {
            if (capture) task.OnCompleted(continuation);
            else task.OnCompletedAnywhere(continuation);
        }
        public void GetResult() { task.GetResult(); }
    }

    public memory_unsafe class ConfiguredTaskAwaitable<T>
    {
        Task<T> task;
        bool capture;

        public ConfiguredTaskAwaitable(Task<T> task, bool capture)
        {
            this.task = task;
            this.capture = capture;
        }

        public ConfiguredTaskAwaitable<T> GetAwaiter() => this;
        public bool IsCompleted => task.IsCompleted;
        public void OnCompleted(Action continuation)
        {
            if (capture) task.OnCompleted(continuation);
            else task.OnCompletedAnywhere(continuation);
        }
        public T GetResult() => task.GetResult();
    }

    // ---------------------------------------------------------------- TaskCompletionSource<T>
    // Una tarea que completa el propio programa (para envolver APIs con callbacks).
    public memory_unsafe class TaskCompletionSource<T>
    {
        Task<T> task = new Task<T>();

        public Task<T> Task => task;
        public void SetResult(T value) { task.SetResult(value); }
        public bool TrySetResult(T value) => task.TrySetResult(value);
        public void SetException(Exception e) { task.SetException(e); }
        public bool TrySetException(Exception e) => task.TrySetException(e);
        public bool TrySetCanceled() => task.TrySetCanceled();
    }

    // ---------------------------------------------------------------- temporizadores
    // Un hilo propio duerme hasta el vencimiento más cercano y completa las tareas de Task.Delay
    // (ningún hilo del grupo se queda bloqueado esperando).
    memory_unsafe class DelayEntry
    {
        public long Due;
        public Task Task;
    }

    memory_unsafe static class TaskTimers
    {
        static List<DelayEntry> entries;  // ordenadas por vencimiento
        static Thread worker;

        public static void Add(Task t, long due)
        {
            DelayEntry e = new DelayEntry();
            e.Due = due;
            e.Task = t;
            faset_task_lock();
            if (entries == null) entries = new List<DelayEntry>();
            int i = entries.Count;
            while (i > 0 && entries[i - 1].Due > due) i--;
            entries.Insert(i, e);
            if (worker == null) worker = Thread.Run(() => Loop());
            faset_task_notify();
            faset_task_unlock();
        }

        // Comparte el cerrojo y la condición de las tareas (cualquier aviso lo despierta y revisa).
        static void Loop()
        {
            faset_task_lock();
            for (;;)
            {
                if (entries.Count == 0)
                {
                    faset_task_wait(-1);
                    continue;
                }
                long now = faset_ticks_ms();
                DelayEntry first = entries[0];
                if (first.Due > now)
                {
                    faset_task_wait(first.Due - now);
                    continue;
                }
                entries.RemoveAt(0);
                faset_task_unlock();
                first.Task.TrySetResult();
                faset_task_lock();
            }
        }
    }

    // ---------------------------------------------------------------- cancelación
    // Cancelación cooperativa: quien quiere cancelar llama a Cancel(); el código cancelable mira
    // IsCancellationRequested o llama a ThrowIfCancellationRequested() (OperationCanceledException).
    public memory_unsafe class CancellationTokenSource
    {
        bool canceled;
        List<Action> callbacks = new List<Action>();

        public CancellationTokenSource() { }

        // Se cancela sola pasados 'milliseconds'.
        public CancellationTokenSource(int milliseconds) { CancelAfter(milliseconds); }

        public bool IsCancellationRequested
        {
            get
            {
                faset_task_lock();
                bool c = canceled;
                faset_task_unlock();
                return c;
            }
        }

        public CancellationToken Token => new CancellationToken(this);

        // Pide la cancelación y ejecuta las acciones registradas (en este hilo, en orden).
        public void Cancel()
        {
            faset_task_lock();
            if (canceled)
            {
                faset_task_unlock();
                return;
            }
            canceled = true;
            List<Action> run = callbacks;
            callbacks = new List<Action>();
            faset_task_unlock();
            for (int i = 0; i < run.Count; i++) run[i]();
        }

        public void CancelAfter(int milliseconds)
        {
            CancellationTokenSource self = this;
            Task.Delay(milliseconds).AddContinuation(() => self.Cancel(), null);
        }

        internal void Register(Action callback)
        {
            faset_task_lock();
            if (!canceled)
            {
                callbacks.Add(callback);
                faset_task_unlock();
                return;
            }
            faset_task_unlock();
            callback();
        }
    }

    public memory_unsafe struct CancellationToken
    {
        CancellationTokenSource source;

        public CancellationToken(CancellationTokenSource source) { this.source = source; }

        // Un token que nunca se cancela.
        public static CancellationToken None => new CancellationToken(null);

        public bool CanBeCanceled => source != null;
        public bool IsCancellationRequested => source != null && source.IsCancellationRequested;

        public void ThrowIfCancellationRequested()
        {
            if (IsCancellationRequested) throw new OperationCanceledException("Se canceló la operación.");
        }

        // 'callback' se ejecuta al cancelar (enseguida si ya estaba cancelado).
        public void Register(Action callback)
        {
            if (source != null) source.Register(callback);
        }
    }
}
