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
        public init() { Message = "Se canceló una tarea."; }
        public init(message: string) { Message = message; }
    }

    // Varias excepciones (Task.WhenAll guarda aquí todas las de sus tareas; await lanza la primera).
    public class AggregateException : Exception
    {
        public var InnerExceptions: List<Exception> = new List<Exception>();

        public init() { Message = "Se produjeron uno o varios errores."; }
        public init(inner: List<Exception>)
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
        static var installed: List<SynchronizationContext>;

        // Ejecuta 'action' en este contexto, más tarde (sin esperar a que termine).
        public virtual func Post(action: Action) { TaskScheduler.Queue(action); }

        // El contexto del hilo actual (null: ninguno, las continuaciones van al grupo de hilos).
        public static prop Current: SynchronizationContext => (SynchronizationContext)faset_sync_ctx_get();

        // Instala 'context' como contexto del hilo actual.
        public static func SetSynchronizationContext(context: SynchronizationContext)
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
        static var pool: ThreadPool;

        // Hilos del grupo: el número de procesadores (al menos 4).
        public static prop ThreadCount: int
        {
            get
            {
                Pool();
                return pool.ThreadCount;
            }
        }

        static func Pool() -> ThreadPool
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
        public static func Queue(action: Action) { Pool().Submit(action); }
    }

    // Continuación pendiente de una tarea.
    memory_unsafe class TaskContinuation
    {
        public var Fn: Action;
        public var Context: SynchronizationContext;  // null: grupo de hilos
        public var Next: TaskContinuation;
    }

    // ---------------------------------------------------------------- Task
    public memory_unsafe class Task
    {
        // Un cerrojo y una variable de condición para todas las tareas (los cambios son cortos):
        // faset_task_lock / faset_task_wait / faset_task_notify.
        static var completed: Task;

        internal var state: int;  // 0 en curso, 1 completada, 2 con error, 3 cancelada
        internal var error: Exception;
        var conts: TaskContinuation;

        public init() { }

        // ---- estado
        public prop IsCompleted: bool => State() != 0;
        public prop IsCompletedSuccessfully: bool => State() == 1;
        public prop IsFaulted: bool => State() == 2;
        public prop IsCanceled: bool => State() == 3;

        public prop Status: TaskStatus
        {
            get
            {
                int s = State();
                return s == 0 ? TaskStatus.Running : s == 1 ? TaskStatus.RanToCompletion
                     : s == 2 ? TaskStatus.Faulted : TaskStatus.Canceled;
            }
        }

        // La excepción que hizo fallar la tarea (null si no falló; también si se canceló).
        public prop Exception: Exception
        {
            get
            {
                faset_task_lock();
                Exception e = state == 2 ? error : null;
                faset_task_unlock();
                return e;
            }
        }

        internal func State() -> int
        {
            faset_task_lock();
            int s = state;
            faset_task_unlock();
            return s;
        }

        // ---- terminar (TaskCompletionSource también los usa)
        internal func Finish(st: int, e: Exception) -> bool
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

        static func Dispatch(fn: Action, ctx: SynchronizationContext)
        {
            if (ctx != null) ctx.Post(fn);
            else TaskScheduler.Queue(fn);
        }

        public func TrySetResult() -> bool => Finish(1, null);

        public func SetResult()
        {
            if (!Finish(1, null)) throw new InvalidOperationException("La tarea ya había terminado.");
        }

        // Una OperationCanceledException deja la tarea cancelada; cualquier otra, con error.
        public func TrySetException(e: Exception) -> bool
        {
            if (e == null) e = new Exception("Excepción nula en una tarea.");
            return Finish(faset_exc_is_named((void*)e, "OperationCanceledException") ? 3 : 2, e);
        }

        public func SetException(e: Exception)
        {
            if (!TrySetException(e)) throw new InvalidOperationException("La tarea ya había terminado.");
        }

        public func TrySetCanceled() -> bool => Finish(3, new TaskCanceledException());

        // ---- await (el patrón que usa el compilador)
        public func GetAwaiter() -> Task => this;

        // Registra la continuación de un 'await': correrá en el SynchronizationContext actual (o en el
        // grupo de hilos) cuando la tarea termine; si ya terminó, se encola enseguida.
        public func OnCompleted(continuation: Action) { AddContinuation(continuation, SynchronizationContext.Current); }

        // Como OnCompleted, pero siempre en el grupo de hilos (ConfigureAwait(false)).
        public func OnCompletedAnywhere(continuation: Action) { AddContinuation(continuation, null); }

        internal func AddContinuation(fn: Action, ctx: SynchronizationContext)
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
        public func GetResult()
        {
            Wait();
        }

        internal func ThrowIfFailed()
        {
            if (state >= 2) faset_exc_rethrow_obj((void*)error);
        }

        // ---- esperar bloqueando (¡no en el hilo de la interfaz si la tarea necesita volver a él!)
        public func Wait()
        {
            faset_task_lock();
            while (state == 0) faset_task_wait(-1);
            faset_task_unlock();
            ThrowIfFailed();
        }

        // Espera como mucho 'milliseconds'; false si la tarea no terminó a tiempo.
        public func Wait(milliseconds: int) -> bool
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
        public func ConfigureAwait(continueOnCapturedContext: bool) -> ConfiguredTaskAwaitable
        {
            return new ConfiguredTaskAwaitable(this, continueOnCapturedContext);
        }

        // ---- continuaciones
        // 'action' se ejecuta (en el grupo de hilos) cuando esta tarea termine, haya ido bien o no.
        public func ContinueWith(action: Action<Task>) -> Task
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

        public func ContinueWith<R>(fn: Func<Task, R>) -> Task<R>
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
        public static prop CompletedTask: Task
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

        public static func FromResult<T>(value: T) -> Task<T>
        {
            Task<T> t = new Task<T>();
            t.TrySetResult(value);
            return t;
        }

        public static func FromException(e: Exception) -> Task
        {
            Task t = new Task();
            t.TrySetException(e);
            return t;
        }

        public static func FromCanceled() -> Task
        {
            Task t = new Task();
            t.TrySetCanceled();
            return t;
        }

        // Ejecuta 'action' en el grupo de hilos.
        public static func Run(action: Action) -> Task
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

        public static func Run<T>(fn: Func<T>) -> Task<T>
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
        public static func Run(fn: Func<Task>) -> Task
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

        public static func Run<T>(fn: Func<Task<T>>) -> Task<T>
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

        internal func CopyFrom(other: Task)
        {
            int s = other.State();
            if (s == 1) TrySetResult();
            else Finish(s, other.error);
        }

        // Tarea que termina dentro de 'milliseconds' (la completa el hilo de los temporizadores).
        public static func Delay(milliseconds: int) -> Task
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
        public static func Delay(milliseconds: int, token: CancellationToken) -> Task
        {
            if (token.IsCancellationRequested) return FromCanceled();
            Task t = Delay(milliseconds);
            if (token.CanBeCanceled) token.Register(() => { t.TrySetCanceled(); });
            return t;
        }

        // Cede el hilo: 'await Task.Yield()' suspende siempre y el resto del método sigue más tarde
        // (en el contexto actual o en el grupo de hilos).
        public static func Yield() -> YieldAwaitable => new YieldAwaitable();

        // Termina cuando terminan todas (con error si alguna falla: la primera excepción).
        public static func WhenAll(params tasks: List<Task>) -> Task
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
        public static func WhenAll<T>(params tasks: List<Task<T>>) -> Task<List<T>>
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
        public static func WhenAny(params tasks: List<Task>) -> Task<Task>
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
        public static func RunMain(t: Task) { t.Wait(); }
    }

    // Estado compartido de Task.WhenAll.
    memory_unsafe class WhenAllState
    {
        public var Pending: int;
        public var All: Task;
        public var Tasks: List<Task>;

        public func OneDone()
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
        public func GetAwaiter() -> YieldAwaitable => this;
        public prop IsCompleted: bool => false;
        public func OnCompleted(continuation: Action)
        {
            SynchronizationContext ctx = SynchronizationContext.Current;
            if (ctx != null) ctx.Post(continuation);
            else TaskScheduler.Queue(continuation);
        }
        public func GetResult() { }
    }

    // ---------------------------------------------------------------- Task<T>
    public memory_unsafe class Task<T> : Task
    {
        internal var value: T;

        public init() { }

        // El resultado (espera bloqueando si aún no terminó; lanza la excepción si falló).
        public prop Result: T
        {
            get
            {
                Wait();
                return value;
            }
        }

        public new func GetAwaiter() -> Task<T> => this;

        public new func GetResult() -> T
        {
            Wait();
            return value;
        }

        public func TrySetResult(v: T) -> bool
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

        public func SetResult(v: T)
        {
            if (!TrySetResult(v)) throw new InvalidOperationException("La tarea ya había terminado.");
        }

        internal func CopyFrom(other: Task<T>)
        {
            int s = other.State();
            if (s == 1) TrySetResult(other.value);
            else Finish(s, other.error);
        }

        public new func ConfigureAwait(continueOnCapturedContext: bool) -> ConfiguredTaskAwaitable<T>
        {
            return new ConfiguredTaskAwaitable<T>(this, continueOnCapturedContext);
        }

        public func ContinueWith(action: Action<Task<T>>) -> Task
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

        public func ContinueWith<R>(fn: Func<Task<T>, R>) -> Task<R>
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
        var task: Task;
        var capture: bool;

        public init(task: Task, capture: bool)
        {
            this.task = task;
            this.capture = capture;
        }

        public func GetAwaiter() -> ConfiguredTaskAwaitable => this;
        public prop IsCompleted: bool => task.IsCompleted;
        public func OnCompleted(continuation: Action)
        {
            if (capture) task.OnCompleted(continuation);
            else task.OnCompletedAnywhere(continuation);
        }
        public func GetResult() { task.GetResult(); }
    }

    public memory_unsafe class ConfiguredTaskAwaitable<T>
    {
        var task: Task<T>;
        var capture: bool;

        public init(task: Task<T>, capture: bool)
        {
            this.task = task;
            this.capture = capture;
        }

        public func GetAwaiter() -> ConfiguredTaskAwaitable<T> => this;
        public prop IsCompleted: bool => task.IsCompleted;
        public func OnCompleted(continuation: Action)
        {
            if (capture) task.OnCompleted(continuation);
            else task.OnCompletedAnywhere(continuation);
        }
        public func GetResult() -> T => task.GetResult();
    }

    // ---------------------------------------------------------------- TaskCompletionSource<T>
    // Una tarea que completa el propio programa (para envolver APIs con callbacks).
    public memory_unsafe class TaskCompletionSource<T>
    {
        var task: Task<T> = new Task<T>();

        public prop Task: Task<T> => task;
        public func SetResult(value: T) { task.SetResult(value); }
        public func TrySetResult(value: T) -> bool => task.TrySetResult(value);
        public func SetException(e: Exception) { task.SetException(e); }
        public func TrySetException(e: Exception) -> bool => task.TrySetException(e);
        public func TrySetCanceled() -> bool => task.TrySetCanceled();
    }

    // ---------------------------------------------------------------- temporizadores
    // Un hilo propio duerme hasta el vencimiento más cercano y completa las tareas de Task.Delay
    // (ningún hilo del grupo se queda bloqueado esperando).
    memory_unsafe class DelayEntry
    {
        public var Due: long;
        public var Task: Task;
    }

    memory_unsafe static class TaskTimers
    {
        static var entries: List<DelayEntry>;  // ordenadas por vencimiento
        static var worker: Thread;

        public static func Add(t: Task, due: long)
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
        static func Loop()
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
        var canceled: bool;
        var callbacks: List<Action> = new List<Action>();

        public init() { }

        // Se cancela sola pasados 'milliseconds'.
        public init(milliseconds: int) { CancelAfter(milliseconds); }

        public prop IsCancellationRequested: bool
        {
            get
            {
                faset_task_lock();
                bool c = canceled;
                faset_task_unlock();
                return c;
            }
        }

        public prop Token: CancellationToken => new CancellationToken(this);

        // Pide la cancelación y ejecuta las acciones registradas (en este hilo, en orden).
        public func Cancel()
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

        public func CancelAfter(milliseconds: int)
        {
            CancellationTokenSource self = this;
            Task.Delay(milliseconds).AddContinuation(() => self.Cancel(), null);
        }

        internal func Register(callback: Action)
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
        var source: CancellationTokenSource;

        public init(source: CancellationTokenSource) { this.source = source; }

        // Un token que nunca se cancela.
        public static prop None: CancellationToken => new CancellationToken(null);

        public prop CanBeCanceled: bool => source != null;
        public prop IsCancellationRequested: bool => source != null && source.IsCancellationRequested;

        public func ThrowIfCancellationRequested()
        {
            if (IsCancellationRequested) throw new OperationCanceledException("Se canceló la operación.");
        }

        // 'callback' se ejecuta al cancelar (enseguida si ya estaba cancelado).
        public func Register(callback: Action)
        {
            if (source != null) source.Register(callback);
        }
    }
}
