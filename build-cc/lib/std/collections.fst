// =============================================================================
//  std.collections  —  colecciones genéricas y algoritmos.
//
//    List<T>, Stack<T>, Queue<T>, Dictionary<K, V>, HashSet<T>, KeyValuePair<K, V>
//    Enumeradores para foreach: ListEnumerator<T>, DictionaryEnumerator<K, V>, ...
//    Algorithms: Sort, BinarySearch, Reverse, Swap, Min, Max, Fill
//
//  Las colecciones son clases: se crean con 'new' y se liberan con 'delete'
//  (su destructor libera la memoria interna). Como en C++, las plantillas se
//  comprueban al usarse: List<T>.Sort solo exige 'operator<' si la llamas.
// =============================================================================
using std.hash;

namespace std.collections
{
    // ---------------------------------------------------------------- List<T>
    public memory_unsafe class List<T> : IEnumerable<T>
    {
        var items: T*;
        var count: int;
        var capacity: int;
        var version: int;  // cambia con cada modificación: foreach detecta cambios durante el recorrido

        public init() { }
        public init(initialCapacity: int) { Reserve(initialCapacity); }
        deinit { Memory.Free(items); }

        public prop Count: int => count;
        public prop Capacity: int => capacity;
        public prop IsEmpty: bool => count == 0;
        // Contador de modificaciones (lo usa ListEnumerator para detectar cambios en un foreach).
        public prop Version: int => version;
        public func GetEnumerator() -> ListEnumerator<T> => new ListEnumerator<T>(this);
        // Como IEnumerable<T> (LINQ perezoso, parámetros IEnumerable<T>): ver collections/iteradores.fst.
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in this) yield return x; }
        // Puntero a los elementos (válido hasta la próxima modificación).
        public prop Data: T* => items;

        [TrackCaller] public T& operator[](int index)
        {
            if (index < 0 || index >= count) throw new ArgumentOutOfRangeException("List: índice fuera de rango", null);
            return items[index];
        }

        // ---- arreglos, índices y rangos (ver arrays.fst)
        [TrackCaller] public T& operator[](Index index) => this[index.GetOffset(count)];

        // lista[1..3]: copia de los elementos del rango (como GetRange).
        [TrackCaller] public List<T> operator[](Range range)
        {
            var (s, n) = range.GetOffsetAndLength(count);
            return GetRange(s, n);
        }

        [TrackCaller] public func GetRange(index: int, n: int) -> List<T>
        {
            if (index < 0 || n < 0 || index > count || n > count - index)
                throw new ArgumentOutOfRangeException("List.GetRange: el tramo se sale de la lista", null);
            List<T> r = new List<T>(n);
            for (int i = 0; i < n; i++) r.Add(items[index + i]);
            return r;
        }

        public func ToArray() -> T[]
        {
            T[] r = new T[count];
            Memory.CopyItems<T>(r.Data, items, count);
            return r;
        }

        public func AddRange(other: T[])
        {
            version++;
            Reserve(count + other.Length);
            Memory.CopyItems<T>(items + count, other.Data, other.Length);
            count += other.Length;
        }

        public func Reserve(n: int)
        {
            if (n <= capacity) return;
            items = Memory.Resize<T>(items, n);
            capacity = n;
        }

        public func Add(item: T)
        {
            if (count == capacity) Reserve(capacity < 8 ? 8 : capacity * 2);
            items[count] = item;
            count++;
            version++;
        }

        public func AddRange(other: List<T>)
        {
            version++;
            Reserve(count + other.Count);
            for (int i = 0; i < other.Count; i++) items[count + i] = other.Data[i];
            count += other.Count;
        }

        [TrackCaller] public func Insert(index: int, item: T)
        {
            if (index < 0 || index > count) throw new ArgumentOutOfRangeException("List.Insert: índice fuera de rango", null);
            if (count == capacity) Reserve(capacity < 8 ? 8 : capacity * 2);
            for (int i = count; i > index; i--) items[i] = items[i - 1];
            items[index] = item;
            count++;
            version++;
        }

        [TrackCaller] public func RemoveAt(index: int)
        {
            if (index < 0 || index >= count) throw new ArgumentOutOfRangeException("List.RemoveAt: índice fuera de rango", null);
            for (int i = index; i < count - 1; i++) items[i] = items[i + 1];
            count--;
            version++;
        }

        public func Remove(item: T) -> bool
        {
            int i = IndexOf(item);
            if (i < 0) return false;
            RemoveAt(i);
            return true;
        }

        public func IndexOf(item: T) -> int
        {
            for (int i = 0; i < count; i++)
                if (items[i] == item) return i;
            return -1;
        }

        public func Contains(item: T) -> bool => IndexOf(item) >= 0;
        public func Clear() { count = 0; version++; }

        [TrackCaller] public func First() -> T
        {
            if (count == 0) throw new InvalidOperationException("List.First: la lista está vacía");
            return items[0];
        }

        [TrackCaller] public func Last() -> T
        {
            if (count == 0) throw new InvalidOperationException("List.Last: la lista está vacía");
            return items[count - 1];
        }

        [TrackCaller] public func Pop() -> T
        {
            if (count == 0) throw new InvalidOperationException("List.Pop: la lista está vacía");
            count--;
            version++;
            return items[count];
        }

        public func Reverse() { Algorithms.Reverse<T>(items, count); version++; }
        public func Sort() { Algorithms.Sort<T>(items, count); version++; }
        public func Sort(compare: delegate*<T, T, int>) { Algorithms.Sort<T>(items, count, compare); version++; }

        public func Sum() -> T
        {
            T s = default(T);
            for (int i = 0; i < count; i++) s += items[i];
            return s;
        }

        public func Min() -> T
        {
            T m = First();
            for (int i = 1; i < count; i++)
                if (items[i] < m) m = items[i];
            return m;
        }

        public func Max() -> T
        {
            T m = First();
            for (int i = 1; i < count; i++)
                if (m < items[i]) m = items[i];
            return m;
        }

        public func ForEach(action: delegate*<T, void>)
        {
            for (int i = 0; i < count; i++) action(items[i]);
        }

        // Nueva lista con los elementos que cumplen 'predicate'.
        public func Where(predicate: delegate*<T, bool>) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) r.Add(items[i]);
            return r;
        }

        // Nueva lista con 'f' aplicada a cada elemento.
        public func Select<U>(f: delegate*<T, U>) -> List<U>
        {
            List<U> r = new List<U>(count);
            for (int i = 0; i < count; i++) r.Add(f(items[i]));
            return r;
        }

        public func Any(predicate: delegate*<T, bool>) -> bool
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return true;
            return false;
        }

        public func All(predicate: delegate*<T, bool>) -> bool
        {
            for (int i = 0; i < count; i++)
                if (!predicate(items[i])) return false;
            return true;
        }

        // Copia independiente.
        public func Clone() -> List<T>
        {
            List<T> r = new List<T>(count);
            r.AddRange(this);
            return r;
        }

        // ============================================================ LINQ y delegados
        //  Operaciones de estilo LINQ con lambdas (Func/Action). La evaluación es inmediata:
        //  cada operación devuelve una lista nueva (la original no cambia).

        // Criterio de OrderBy/ThenBy de esta lista (lo usa ThenBy para encadenar).
        var orden: Func<T, T, int>;

        // Ordena en el sitio con una comparación (negativo, cero o positivo). Estable.
        public func Sort(comparison: Comparison<T>) { Algorithms.StableSort<T>(items, count, comparison); }

        public func ForEach(action: Action<T>)
        {
            for (int i = 0; i < count; i++) action(items[i]);
        }

        public func Where(predicate: Func<T, bool>) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) r.Add(items[i]);
            return r;
        }

        // Con el índice del elemento: lista.Where((x, i) => i % 2 == 0)
        public func Where(predicate: Func<T, int, bool>) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count; i++)
                if (predicate(items[i], i)) r.Add(items[i]);
            return r;
        }

        public func Select<U>(selector: Func<T, U>) -> List<U>
        {
            List<U> r = new List<U>(count);
            for (int i = 0; i < count; i++) r.Add(selector(items[i]));
            return r;
        }

        public func Select<U>(selector: Func<T, int, U>) -> List<U>
        {
            List<U> r = new List<U>(count);
            for (int i = 0; i < count; i++) r.Add(selector(items[i], i));
            return r;
        }

        // Aplana: cada elemento produce una lista.
        public func SelectMany<U>(selector: Func<T, List<U>>) -> List<U>
        {
            List<U> r = new List<U>();
            for (int i = 0; i < count; i++) r.AddRange(selector(items[i]));
            return r;
        }

        // Ordenaciones estables por clave (la clave necesita 'operator<'; string compara por orden).
        public func OrderBy<K>(key: Func<T, K>) -> List<T>
        {
            return Ordered((a, b) => Algorithms.CompareKeys<K>(key(a), key(b)));
        }

        public func OrderByDescending<K>(key: Func<T, K>) -> List<T>
        {
            return Ordered((a, b) => Algorithms.CompareKeys<K>(key(b), key(a)));
        }

        // Criterio secundario: solo sobre el resultado de OrderBy/OrderByDescending/ThenBy.
        [TrackCaller] public func ThenBy<K>(key: Func<T, K>) -> List<T>
        {
            if (orden == null) panic("ThenBy: la lista no viene de OrderBy, OrderByDescending ni ThenBy");
            Func<T, T, int> previo = orden;
            return Ordered((a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(a), key(b));
            });
        }

        [TrackCaller] public func ThenByDescending<K>(key: Func<T, K>) -> List<T>
        {
            if (orden == null) panic("ThenByDescending: la lista no viene de OrderBy, OrderByDescending ni ThenBy");
            Func<T, T, int> previo = orden;
            return Ordered((a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(b), key(a));
            });
        }

        func Ordered(comparison: Func<T, T, int>) -> List<T>
        {
            List<T> r = Clone();
            Algorithms.StableSort<T>(r.items, r.count, comparison);
            r.orden = comparison;
            return r;
        }

        [TrackCaller] public func First(predicate: Func<T, bool>) -> T
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return items[i];
            panic("List.First: ningún elemento cumple la condición");
            return default(T);
        }

        public func FirstOrDefault() -> T => count > 0 ? items[0] : default(T);

        public func FirstOrDefault(predicate: Func<T, bool>) -> T
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        [TrackCaller] public func Last(predicate: Func<T, bool>) -> T
        {
            for (int i = count - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            panic("List.Last: ningún elemento cumple la condición");
            return default(T);
        }

        public func LastOrDefault() -> T => count > 0 ? items[count - 1] : default(T);

        public func LastOrDefault(predicate: Func<T, bool>) -> T
        {
            for (int i = count - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        public func Any() -> bool => count > 0;

        public func Any(predicate: Func<T, bool>) -> bool
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return true;
            return false;
        }

        public func All(predicate: Func<T, bool>) -> bool
        {
            for (int i = 0; i < count; i++)
                if (!predicate(items[i])) return false;
            return true;
        }

        // Cuántos cumplen la condición (lista.Count sin paréntesis es el total).
        public func Count(predicate: Func<T, bool>) -> int
        {
            int n = 0;
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) n++;
            return n;
        }

        public func Sum<U>(selector: Func<T, U>) -> U
        {
            U s = default(U);
            for (int i = 0; i < count; i++) s += selector(items[i]);
            return s;
        }

        [TrackCaller] public func Min<U>(selector: Func<T, U>) -> U
        {
            if (count == 0) panic("List.Min: la lista está vacía");
            U m = selector(items[0]);
            for (int i = 1; i < count; i++)
            {
                U v = selector(items[i]);
                if (v < m) m = v;
            }
            return m;
        }

        [TrackCaller] public func Max<U>(selector: Func<T, U>) -> U
        {
            if (count == 0) panic("List.Max: la lista está vacía");
            U m = selector(items[0]);
            for (int i = 1; i < count; i++)
            {
                U v = selector(items[i]);
                if (m < v) m = v;
            }
            return m;
        }

        // Elemento con la clave mínima / máxima (el primero si hay empate).
        [TrackCaller] public func MinBy<K>(key: Func<T, K>) -> T
        {
            if (count == 0) panic("List.MinBy: la lista está vacía");
            int best = 0;
            K bk = key(items[0]);
            for (int i = 1; i < count; i++)
            {
                K k = key(items[i]);
                if (k < bk)
                {
                    bk = k;
                    best = i;
                }
            }
            return items[best];
        }

        [TrackCaller] public func MaxBy<K>(key: Func<T, K>) -> T
        {
            if (count == 0) panic("List.MaxBy: la lista está vacía");
            int best = 0;
            K bk = key(items[0]);
            for (int i = 1; i < count; i++)
            {
                K k = key(items[i]);
                if (bk < k)
                {
                    bk = k;
                    best = i;
                }
            }
            return items[best];
        }

        [TrackCaller] public func Average() -> double
        {
            if (count == 0) panic("List.Average: la lista está vacía");
            return (double)Sum() / count;
        }

        [TrackCaller] public func Average<U>(selector: Func<T, U>) -> double
        {
            if (count == 0) panic("List.Average: la lista está vacía");
            return (double)Sum<U>(selector) / count;
        }

        // Sin repetidos, en el orden de la primera aparición (T necesita Hash.Of y '==').
        public func Distinct() -> List<T>
        {
            List<T> r = new List<T>();
            Dictionary<T, bool> seen = new Dictionary<T, bool>();
            for (int i = 0; i < count; i++)
                if (seen.Add(items[i], true)) r.Add(items[i]);
            return r;
        }

        public func Take(n: int) -> List<T>
        {
            if (n > count) n = count;
            List<T> r = new List<T>(n < 0 ? 0 : n);
            for (int i = 0; i < n; i++) r.Add(items[i]);
            return r;
        }

        public func Skip(n: int) -> List<T>
        {
            if (n < 0) n = 0;
            List<T> r = new List<T>();
            for (int i = n; i < count; i++) r.Add(items[i]);
            return r;
        }

        public func TakeWhile(predicate: Func<T, bool>) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count && predicate(items[i]); i++) r.Add(items[i]);
            return r;
        }

        public func SkipWhile(predicate: Func<T, bool>) -> List<T>
        {
            int i = 0;
            while (i < count && predicate(items[i])) i++;
            List<T> r = new List<T>();
            for (; i < count; i++) r.Add(items[i]);
            return r;
        }

        // Grupos por clave, en el orden de la primera aparición de cada clave.
        public func GroupBy<K>(key: Func<T, K>) -> List<Grouping<K, T>>
        {
            List<Grouping<K, T>> r = new List<Grouping<K, T>>();
            Dictionary<K, int> index = new Dictionary<K, int>();
            for (int i = 0; i < count; i++)
            {
                K k = key(items[i]);
                int at = 0;
                if (!index.TryGetValue(k, out at))
                {
                    at = r.Count;
                    index.Set(k, at);
                    r.Add(new Grouping<K, T>(k));
                }
                r[at].Items.Add(items[i]);
            }
            return r;
        }

        public func ToList() -> List<T> => Clone();

        // Diccionario clave -> elemento (si una clave se repite, gana el último).
        public func ToDictionary<K>(key: Func<T, K>) -> Dictionary<K, T>
        {
            Dictionary<K, T> d = new Dictionary<K, T>();
            for (int i = 0; i < count; i++) d.Set(key(items[i]), items[i]);
            return d;
        }

        public func ToDictionary<K, V>(key: Func<T, K>, value: Func<T, V>) -> Dictionary<K, V>
        {
            Dictionary<K, V> d = new Dictionary<K, V>();
            for (int i = 0; i < count; i++) d.Set(key(items[i]), value(items[i]));
            return d;
        }

        // Acumula de izquierda a derecha: lista.Aggregate((a, b) => a + b)
        [TrackCaller] public T Aggregate(Func<T, T, T> func)
        {
            if (count == 0) panic("List.Aggregate: la lista está vacía");
            T acc = items[0];
            for (int i = 1; i < count; i++) acc = func(acc, items[i]);
            return acc;
        }

        // Con semilla: lista.Aggregate("", (s, x) => s + x)
        public A Aggregate<A>(A seed, Func<A, T, A> func)
        {
            A acc = seed;
            for (int i = 0; i < count; i++) acc = func(acc, items[i]);
            return acc;
        }

        // Combina elemento a elemento (hasta la lista más corta).
        public func Zip<U, R>(other: List<U>, f: Func<T, U, R>) -> List<R>
        {
            int n = count < other.Count ? count : other.Count;
            List<R> r = new List<R>(n);
            for (int i = 0; i < n; i++) r.Add(f(items[i], other[i]));
            return r;
        }

        public func Concat(other: List<T>) -> List<T>
        {
            List<T> r = Clone();
            r.AddRange(other);
            return r;
        }

        // ---- búsquedas al estilo de List<T> de .NET
        public func Find(match: Predicate<T>) -> T
        {
            for (int i = 0; i < count; i++)
                if (match(items[i])) return items[i];
            return default(T);
        }

        public func FindLast(match: Predicate<T>) -> T
        {
            for (int i = count - 1; i >= 0; i--)
                if (match(items[i])) return items[i];
            return default(T);
        }

        public func FindAll(match: Predicate<T>) -> List<T> => Where(match);

        public func FindIndex(match: Predicate<T>) -> int
        {
            for (int i = 0; i < count; i++)
                if (match(items[i])) return i;
            return -1;
        }

        public func Exists(match: Predicate<T>) -> bool => FindIndex(match) >= 0;

        public func TrueForAll(match: Predicate<T>) -> bool => All(match);

        // Quita los elementos que cumplen la condición; devuelve cuántos quitó.
        public func RemoveAll(match: Predicate<T>) -> int
        {
            int w = 0;
            for (int i = 0; i < count; i++)
            {
                if (match(items[i])) continue;
                items[w] = items[i];
                w++;
            }
            int removed = count - w;
            for (int i = w; i < count; i++) items[i] = default(T);
            count = w;
            return removed;
        }

        public func ConvertAll<U>(converter: Func<T, U>) -> List<U> => Select<U>(converter);
    }

    // Delegados de .NET (estructurales: Predicate<int> es el mismo tipo que Func<int, bool>).
    public delegate bool Predicate<T>(T obj);
    public delegate int Comparison<T>(T x, T y);

    // Resultado de GroupBy: la clave y los elementos del grupo.
    public class Grouping<K, T> : IEnumerable<T>
    {
        public var Key: K;
        public var Items: List<T> = new List<T>();
        public init(key: K) { Key = key; }
        public prop Count: int => Items.Count;
        [TrackCaller] public T operator[](int index) => Items[index];
        public func GetEnumerator() -> ListEnumerator<T> => Items.GetEnumerator();
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in Items) yield return x; }
    }

    // Enumerador de List<T> para foreach. Si la lista se modifica durante el recorrido,
    // MoveNext termina con panic (como InvalidOperationException en C#).
    public memory_unsafe struct ListEnumerator<T>
    {
        var list: List<T>;
        var index: int;
        var version: int;

        public init(source: List<T>)
        {
            list = source;
            index = -1;
            version = source.Version;
        }

        public prop Current: T => list.Data[index];

        [TrackCaller] public func MoveNext() -> bool
        {
            if (version != list.Version) panic("List: la colección se modificó durante un foreach");
            index++;
            return index < list.Count;
        }
    }

    // ---------------------------------------------------------------- Stack<T>
    public class Stack<T> : IEnumerable<T>
    {
        var items: List<T> = new List<T>();
        deinit { delete items; }

        public prop Count: int => items.Count;
        public prop IsEmpty: bool => items.Count == 0;
        public func Push(item: T) { items.Add(item); }
        [TrackCaller] public func Pop() -> T => items.Pop();
        [TrackCaller] public func Peek() -> T => items.Last();
        public func Clear() { items.Clear(); }
        // foreach recorre la pila de la base a la cima (en el orden en que se apilaron).
        public func GetEnumerator() -> ListEnumerator<T> => items.GetEnumerator();
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in items) yield return x; }
    }

    // ---------------------------------------------------------------- Queue<T> (búfer circular)
    public memory_unsafe class Queue<T> : IEnumerable<T>
    {
        var items: T*;
        var head: int;
        var count: int;
        var capacity: int;

        deinit { Memory.Free(items); }

        public prop Count: int => count;
        public prop IsEmpty: bool => count == 0;

        public func Enqueue(item: T)
        {
            if (count == capacity) Grow();
            items[(head + count) % capacity] = item;
            count++;
        }

        [TrackCaller] public func Dequeue() -> T
        {
            if (count == 0) throw new InvalidOperationException("Queue.Dequeue: la cola está vacía");
            T item = items[head];
            head = (head + 1) % capacity;
            count--;
            return item;
        }

        [TrackCaller] public func Peek() -> T
        {
            if (count == 0) throw new InvalidOperationException("Queue.Peek: la cola está vacía");
            return items[head];
        }

        public func Clear() { head = 0; count = 0; }

        // foreach recorre la cola en orden de salida (del primero al último).
        IEnumerator<T> IEnumerable<T>.GetEnumerator()
        {
            for (int i = 0; i < count; i++) yield return items[(head + i) % capacity];
        }

        func Grow()
        {
            int newCap = capacity < 8 ? 8 : capacity * 2;
            T* n = Memory.New<T>(newCap);
            for (int i = 0; i < count; i++) n[i] = items[(head + i) % capacity];
            Memory.Free(items);
            items = n;
            head = 0;
            capacity = newCap;
        }
    }

    // ---------------------------------------------------------------- Dictionary<K, V> (tabla hash)
    //  Las claves deben tener un Hash.Of(K) (enteros, char, string, punteros...).
    public memory_unsafe class Dictionary<K, V> : IEnumerable<KeyValuePair<K, V>>
    {
        var keys: K*;
        var values: V*;
        var used: byte*;  // 0 = libre, 1 = ocupado, 2 = borrado
        var count: int;
        var capacity: int;
        var tombstones: int;
        var version: int;  // cambia con cada inserción o borrado (foreach detecta cambios)

        deinit
        {
            Memory.Free(keys);
            Memory.Free(values);
            Memory.Free(used);
        }

        public prop Count: int => count;
        public prop IsEmpty: bool => count == 0;

        // ---- para DictionaryEnumerator (foreach): huecos de la tabla y contador de cambios
        public prop Version: int => version;
        public prop SlotCount: int => capacity;
        public func SlotUsed(i: int) -> bool => used[i] == 1;
        public func SlotKey(i: int) -> K => keys[i];
        public func SlotValue(i: int) -> V => values[i];
        public func GetEnumerator() -> DictionaryEnumerator<K, V> => new DictionaryEnumerator<K, V>(this);
        IEnumerator<KeyValuePair<K, V>> IEnumerable<KeyValuePair<K, V>>.GetEnumerator()
        {
            foreach (KeyValuePair<K, V> kv in this) yield return kv;
        }

        func Find(key: K) -> int
        {
            if (capacity == 0) return -1;
            int mask = capacity - 1;
            int i = (int)(Hash.Of(key) & (ulong)mask);
            for (int probe = 0; probe < capacity; probe++)
            {
                if (used[i] == 0) return -1;
                if (used[i] == 1 && keys[i] == key) return i;
                i = (i + 1) & mask;
            }
            return -1;
        }

        func Rehash(newCap: int)
        {
            K* oldKeys = keys;
            V* oldValues = values;
            byte* oldUsed = used;
            int oldCap = capacity;
            keys = Memory.New<K>(newCap);
            values = Memory.New<V>(newCap);
            used = Memory.New<byte>(newCap);
            capacity = newCap;
            count = 0;
            tombstones = 0;
            for (int i = 0; i < oldCap; i++)
                if (oldUsed[i] == 1) Set(oldKeys[i], oldValues[i]);
            Memory.Free(oldKeys);
            Memory.Free(oldValues);
            Memory.Free(oldUsed);
        }

        func Slot(key: K) -> int
        {
            if ((count + tombstones + 1) * 4 >= capacity * 3) Rehash(capacity < 16 ? 16 : capacity * 2);
            int mask = capacity - 1;
            int i = (int)(Hash.Of(key) & (ulong)mask);
            int firstFree = -1;
            for (;;)
            {
                if (used[i] == 0)
                {
                    int slot = firstFree >= 0 ? firstFree : i;
                    if (used[slot] == 2) tombstones--;
                    used[slot] = 1;
                    keys[slot] = key;
                    values[slot] = default(V);
                    count++;
                    version++;
                    return slot;
                }
                if (used[i] == 2 && firstFree < 0) firstFree = i;
                if (used[i] == 1 && keys[i] == key) return i;
                i = (i + 1) & mask;
            }
        }

        // Como en C++: dict[clave] crea la entrada (con valor por defecto) si no existe.
        public V& operator[](K key)
        {
            int i = Slot(key);
            return values[i];
        }

        public func Set(key: K, value: V)
        {
            int i = Slot(key);  // Slot puede reasignar 'values': se evalúa primero
            values[i] = value;
        }

        public func Add(key: K, value: V) -> bool
        {
            if (Find(key) >= 0) return false;
            Set(key, value);
            return true;
        }

        public func TryGetValue(key: K, out value: V) -> bool
        {
            int i = Find(key);
            if (i < 0) return false;
            value = values[i];
            return true;
        }

        [TrackCaller] public func Get(key: K) -> V
        {
            int i = Find(key);
            if (i < 0) throw new KeyNotFoundException("Dictionary.Get: la clave no existe");
            return values[i];
        }

        public func GetOrDefault(key: K, fallback: V) -> V
        {
            int i = Find(key);
            return i < 0 ? fallback : values[i];
        }

        public func ContainsKey(key: K) -> bool => Find(key) >= 0;

        public func Remove(key: K) -> bool
        {
            int i = Find(key);
            if (i < 0) return false;
            used[i] = 2;
            count--;
            tombstones++;
            version++;
            return true;
        }

        public func Clear()
        {
            if (capacity > 0) Memory.Set(used, 0, capacity);
            count = 0;
            tombstones = 0;
            version++;
        }

        // Nuevas listas con las claves / valores.
        public func Keys() -> List<K>
        {
            List<K> r = new List<K>(count);
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) r.Add(keys[i]);
            return r;
        }

        public func Values() -> List<V>
        {
            List<V> r = new List<V>(count);
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) r.Add(values[i]);
            return r;
        }

        // ---- con delegados
        // Pares clave/valor (para usar LINQ: dic.Pairs().Where(p => p.Value > 3)).
        public func Pairs() -> List<KeyValuePair<K, V>>
        {
            List<KeyValuePair<K, V>> r = new List<KeyValuePair<K, V>>(count);
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) r.Add(new KeyValuePair<K, V>(keys[i], values[i]));
            return r;
        }

        public func ForEach(action: Action<K, V>)
        {
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) action(keys[i], values[i]);
        }

        // Valor de la clave; si no existe, lo crea con factory(clave).
        public func GetOrAdd(key: K, factory: Func<K, V>) -> V
        {
            int i = Find(key);
            if (i >= 0) return values[i];
            V v = factory(key);
            Set(key, v);
            return v;
        }

        public func Any(predicate: Func<K, V, bool>) -> bool
        {
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1 && predicate(keys[i], values[i])) return true;
            return false;
        }

        public func Count(predicate: Func<K, V, bool>) -> int
        {
            int n = 0;
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1 && predicate(keys[i], values[i])) n++;
            return n;
        }

        // Quita las entradas que cumplen la condición; devuelve cuántas quitó.
        public func RemoveAll(predicate: Func<K, V, bool>) -> int
        {
            int n = 0;
            for (int i = 0; i < capacity; i++)
            {
                if (used[i] != 1 || !predicate(keys[i], values[i])) continue;
                used[i] = 2;
                count--;
                tombstones++;
                n++;
            }
            return n;
        }
    }

    // Par clave/valor de un Dictionary (lo que recorre foreach y devuelve Pairs()). Admite deconstrucción:
    //   foreach (var (clave, valor) in dic) ...
    public struct KeyValuePair<K, V>
    {
        public var Key: K;
        public var Value: V;

        public init(key: K, value: V)
        {
            Key = key;
            Value = value;
        }

        public func Deconstruct(out key: K, out value: V)
        {
            key = Key;
            value = Value;
        }
    }

    // Enumerador de Dictionary<K, V> para foreach (orden de la tabla hash, no de inserción).
    public struct DictionaryEnumerator<K, V>
    {
        var dict: Dictionary<K, V>;
        var index: int;
        var version: int;

        public init(source: Dictionary<K, V>)
        {
            dict = source;
            index = -1;
            version = source.Version;
        }

        public prop Current: KeyValuePair<K, V> => new KeyValuePair<K, V>(dict.SlotKey(index), dict.SlotValue(index));

        [TrackCaller] public func MoveNext() -> bool
        {
            if (version != dict.Version) panic("Dictionary: la colección se modificó durante un foreach");
            index++;
            while (index < dict.SlotCount && !dict.SlotUsed(index)) index++;
            return index < dict.SlotCount;
        }
    }

    // Enumerador de HashSet<T> para foreach.
    public struct HashSetEnumerator<T>
    {
        var inner: DictionaryEnumerator<T, bool>;

        public init(e: DictionaryEnumerator<T, bool>) { inner = e; }

        public prop Current: T => inner.Current.Key;
        [TrackCaller] public func MoveNext() -> bool => inner.MoveNext();
    }

    // ---------------------------------------------------------------- HashSet<T>
    public class HashSet<T> : IEnumerable<T>
    {
        var map: Dictionary<T, bool> = new Dictionary<T, bool>();
        deinit { delete map; }

        public prop Count: int => map.Count;
        public prop IsEmpty: bool => map.Count == 0;
        public func Add(item: T) -> bool => map.Add(item, true);
        public func Contains(item: T) -> bool => map.ContainsKey(item);
        public func Remove(item: T) -> bool => map.Remove(item);
        public func Clear() { map.Clear(); }
        public func ToList() -> List<T> => map.Keys();
        public func ToArray() -> T[] => map.Keys().ToArray();
        public func UnionWith(other: T[]) { foreach (T x in other) Add(x); }
        public func UnionWith(other: List<T>) { foreach (T x in other) Add(x); }
        public func GetEnumerator() -> HashSetEnumerator<T> => new HashSetEnumerator<T>(map.GetEnumerator());
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in this) yield return x; }
    }

    // ---------------------------------------------------------------- algoritmos genéricos
    public memory_unsafe static class Algorithms
    {
        public static func Swap<T>(a: T&, b: T&)
        {
            T t = a;
            a = b;
            b = t;
        }

        public static func Reverse<T>(data: T*, n: int)
        {
            for (int i = 0, j = n - 1; i < j; i++, j--) Swap<T>(data[i], data[j]);
        }

        public static func Fill<T>(data: T*, n: int, value: T)
        {
            for (int i = 0; i < n; i++) data[i] = value;
        }

        // Ordena con 'operator<' (quicksort + inserción).
        public static func Sort<T>(data: T*, n: int)
        {
            if (n < 2) return;
            if (n <= 16)
            {
                for (int i = 1; i < n; i++)
                {
                    T v = data[i];
                    int j = i - 1;
                    while (j >= 0 && v < data[j])
                    {
                        data[j + 1] = data[j];
                        j--;
                    }
                    data[j + 1] = v;
                }
                return;
            }
            T pivot = data[n / 2];
            int lo = 0, hi = n - 1;
            while (lo <= hi)
            {
                while (data[lo] < pivot) lo++;
                while (pivot < data[hi]) hi--;
                if (lo <= hi)
                {
                    Swap<T>(data[lo], data[hi]);
                    lo++;
                    hi--;
                }
            }
            Sort<T>(data, hi + 1);
            Sort<T>(data + lo, n - lo);
        }

        // Ordena con una función de comparación: negativo, cero o positivo.
        public static func Sort<T>(data: T*, n: int, compare: delegate*<T, T, int>)
        {
            if (n < 2) return;
            if (n <= 16)
            {
                for (int i = 1; i < n; i++)
                {
                    T v = data[i];
                    int j = i - 1;
                    while (j >= 0 && compare(v, data[j]) < 0)
                    {
                        data[j + 1] = data[j];
                        j--;
                    }
                    data[j + 1] = v;
                }
                return;
            }
            T pivot = data[n / 2];
            int lo = 0, hi = n - 1;
            while (lo <= hi)
            {
                while (compare(data[lo], pivot) < 0) lo++;
                while (compare(pivot, data[hi]) < 0) hi--;
                if (lo <= hi)
                {
                    Swap<T>(data[lo], data[hi]);
                    lo++;
                    hi--;
                }
            }
            Sort<T>(data, hi + 1, compare);
            Sort<T>(data + lo, n - lo, compare);
        }

        // Búsqueda binaria en datos ordenados: índice o -1.
        public static func BinarySearch<T>(data: T*, n: int, value: T) -> int
        {
            int lo = 0, hi = n - 1;
            while (lo <= hi)
            {
                int mid = lo + (hi - lo) / 2;
                if (data[mid] < value) lo = mid + 1;
                else if (value < data[mid]) hi = mid - 1;
                else return mid;
            }
            return -1;
        }

        // Ordenación estable (mezcla) con una comparación: negativo, cero o positivo.
        public static func StableSort<T>(data: T*, n: int, compare: Func<T, T, int>)
        {
            if (n < 2) return;
            if (n <= 16)
            {
                for (int i = 1; i < n; i++)
                {
                    T v = data[i];
                    int j = i - 1;
                    while (j >= 0 && compare(v, data[j]) < 0)
                    {
                        data[j + 1] = data[j];
                        j--;
                    }
                    data[j + 1] = v;
                }
                return;
            }
            T* tmp = Memory.New<T>(n);
            MergeSort<T>(data, tmp, n, compare);
            Memory.Free(tmp);
        }

        static func MergeSort<T>(data: T*, tmp: T*, n: int, compare: Func<T, T, int>)
        {
            if (n <= 16)
            {
                StableSort<T>(data, n, compare);
                return;
            }
            int mid = n / 2;
            MergeSort<T>(data, tmp, mid, compare);
            MergeSort<T>(data + mid, tmp, n - mid, compare);
            int i = 0, j = mid, k = 0;
            while (i < mid && j < n)
            {
                if (compare(data[j], data[i]) < 0) tmp[k++] = data[j++];
                else tmp[k++] = data[i++];
            }
            while (i < mid) tmp[k++] = data[i++];
            while (j < n) tmp[k++] = data[j++];
            for (int q = 0; q < n; q++) data[q] = tmp[q];
        }

        // -1, 0 o 1 según 'operator<' (claves de OrderBy).
        public static func CompareKeys<K>(a: K, b: K) -> int => a < b ? -1 : (b < a ? 1 : 0);

        public static func Min<T>(a: T, b: T) -> T => b < a ? b : a;
        public static func Max<T>(a: T, b: T) -> T => a < b ? b : a;
    }
}
