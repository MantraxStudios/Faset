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
        T* items;
        int count;
        int capacity;
        int version;  // cambia con cada modificación: foreach detecta cambios durante el recorrido

        public List() { }
        public List(int initialCapacity) { Reserve(initialCapacity); }
        ~List() { Memory.Free(items); }

        public int Count => count;
        public int Capacity => capacity;
        public bool IsEmpty => count == 0;
        // Contador de modificaciones (lo usa ListEnumerator para detectar cambios en un foreach).
        public int Version => version;
        public ListEnumerator<T> GetEnumerator() => new ListEnumerator<T>(this);
        // Como IEnumerable<T> (LINQ perezoso, parámetros IEnumerable<T>): ver collections/iteradores.fst.
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in this) yield return x; }
        // Puntero a los elementos (válido hasta la próxima modificación).
        public T* Data => items;

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

        [TrackCaller] public List<T> GetRange(int index, int n)
        {
            if (index < 0 || n < 0 || index > count || n > count - index)
                throw new ArgumentOutOfRangeException("List.GetRange: el tramo se sale de la lista", null);
            List<T> r = new List<T>(n);
            for (int i = 0; i < n; i++) r.Add(items[index + i]);
            return r;
        }

        public T[] ToArray()
        {
            T[] r = new T[count];
            Memory.CopyItems<T>(r.Data, items, count);
            return r;
        }

        public void AddRange(T[] other)
        {
            version++;
            Reserve(count + other.Length);
            Memory.CopyItems<T>(items + count, other.Data, other.Length);
            count += other.Length;
        }

        public void Reserve(int n)
        {
            if (n <= capacity) return;
            items = Memory.Resize<T>(items, n);
            capacity = n;
        }

        public void Add(T item)
        {
            if (count == capacity) Reserve(capacity < 8 ? 8 : capacity * 2);
            items[count] = item;
            count++;
            version++;
        }

        public void AddRange(List<T> other)
        {
            version++;
            Reserve(count + other.Count);
            for (int i = 0; i < other.Count; i++) items[count + i] = other.Data[i];
            count += other.Count;
        }

        [TrackCaller] public void Insert(int index, T item)
        {
            if (index < 0 || index > count) throw new ArgumentOutOfRangeException("List.Insert: índice fuera de rango", null);
            if (count == capacity) Reserve(capacity < 8 ? 8 : capacity * 2);
            for (int i = count; i > index; i--) items[i] = items[i - 1];
            items[index] = item;
            count++;
            version++;
        }

        [TrackCaller] public void RemoveAt(int index)
        {
            if (index < 0 || index >= count) throw new ArgumentOutOfRangeException("List.RemoveAt: índice fuera de rango", null);
            for (int i = index; i < count - 1; i++) items[i] = items[i + 1];
            count--;
            version++;
        }

        public bool Remove(T item)
        {
            int i = IndexOf(item);
            if (i < 0) return false;
            RemoveAt(i);
            return true;
        }

        public int IndexOf(T item)
        {
            for (int i = 0; i < count; i++)
                if (items[i] == item) return i;
            return -1;
        }

        public bool Contains(T item) => IndexOf(item) >= 0;
        public void Clear() { count = 0; version++; }

        [TrackCaller] public T First()
        {
            if (count == 0) throw new InvalidOperationException("List.First: la lista está vacía");
            return items[0];
        }

        [TrackCaller] public T Last()
        {
            if (count == 0) throw new InvalidOperationException("List.Last: la lista está vacía");
            return items[count - 1];
        }

        [TrackCaller] public T Pop()
        {
            if (count == 0) throw new InvalidOperationException("List.Pop: la lista está vacía");
            count--;
            version++;
            return items[count];
        }

        public void Reverse() { Algorithms.Reverse<T>(items, count); version++; }
        public void Sort() { Algorithms.Sort<T>(items, count); version++; }
        public void Sort(delegate*<T, T, int> compare) { Algorithms.Sort<T>(items, count, compare); version++; }

        public T Sum()
        {
            T s = default(T);
            for (int i = 0; i < count; i++) s += items[i];
            return s;
        }

        public T Min()
        {
            T m = First();
            for (int i = 1; i < count; i++)
                if (items[i] < m) m = items[i];
            return m;
        }

        public T Max()
        {
            T m = First();
            for (int i = 1; i < count; i++)
                if (m < items[i]) m = items[i];
            return m;
        }

        public void ForEach(delegate*<T, void> action)
        {
            for (int i = 0; i < count; i++) action(items[i]);
        }

        // Nueva lista con los elementos que cumplen 'predicate'.
        public List<T> Where(delegate*<T, bool> predicate)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) r.Add(items[i]);
            return r;
        }

        // Nueva lista con 'f' aplicada a cada elemento.
        public List<U> Select<U>(delegate*<T, U> f)
        {
            List<U> r = new List<U>(count);
            for (int i = 0; i < count; i++) r.Add(f(items[i]));
            return r;
        }

        public bool Any(delegate*<T, bool> predicate)
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return true;
            return false;
        }

        public bool All(delegate*<T, bool> predicate)
        {
            for (int i = 0; i < count; i++)
                if (!predicate(items[i])) return false;
            return true;
        }

        // Copia independiente.
        public List<T> Clone()
        {
            List<T> r = new List<T>(count);
            r.AddRange(this);
            return r;
        }

        // ============================================================ LINQ y delegados
        //  Operaciones de estilo LINQ con lambdas (Func/Action). La evaluación es inmediata:
        //  cada operación devuelve una lista nueva (la original no cambia).

        // Criterio de OrderBy/ThenBy de esta lista (lo usa ThenBy para encadenar).
        Func<T, T, int> orden;

        // Ordena en el sitio con una comparación (negativo, cero o positivo). Estable.
        public void Sort(Comparison<T> comparison) { Algorithms.StableSort<T>(items, count, comparison); }

        public void ForEach(Action<T> action)
        {
            for (int i = 0; i < count; i++) action(items[i]);
        }

        public List<T> Where(Func<T, bool> predicate)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) r.Add(items[i]);
            return r;
        }

        // Con el índice del elemento: lista.Where((x, i) => i % 2 == 0)
        public List<T> Where(Func<T, int, bool> predicate)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count; i++)
                if (predicate(items[i], i)) r.Add(items[i]);
            return r;
        }

        public List<U> Select<U>(Func<T, U> selector)
        {
            List<U> r = new List<U>(count);
            for (int i = 0; i < count; i++) r.Add(selector(items[i]));
            return r;
        }

        public List<U> Select<U>(Func<T, int, U> selector)
        {
            List<U> r = new List<U>(count);
            for (int i = 0; i < count; i++) r.Add(selector(items[i], i));
            return r;
        }

        // Aplana: cada elemento produce una lista.
        public List<U> SelectMany<U>(Func<T, List<U>> selector)
        {
            List<U> r = new List<U>();
            for (int i = 0; i < count; i++) r.AddRange(selector(items[i]));
            return r;
        }

        // Ordenaciones estables por clave (la clave necesita 'operator<'; string compara por orden).
        public List<T> OrderBy<K>(Func<T, K> key)
        {
            return Ordered((a, b) => Algorithms.CompareKeys<K>(key(a), key(b)));
        }

        public List<T> OrderByDescending<K>(Func<T, K> key)
        {
            return Ordered((a, b) => Algorithms.CompareKeys<K>(key(b), key(a)));
        }

        // Criterio secundario: solo sobre el resultado de OrderBy/OrderByDescending/ThenBy.
        [TrackCaller] public List<T> ThenBy<K>(Func<T, K> key)
        {
            if (orden == null) panic("ThenBy: la lista no viene de OrderBy, OrderByDescending ni ThenBy");
            Func<T, T, int> previo = orden;
            return Ordered((a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(a), key(b));
            });
        }

        [TrackCaller] public List<T> ThenByDescending<K>(Func<T, K> key)
        {
            if (orden == null) panic("ThenByDescending: la lista no viene de OrderBy, OrderByDescending ni ThenBy");
            Func<T, T, int> previo = orden;
            return Ordered((a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(b), key(a));
            });
        }

        List<T> Ordered(Func<T, T, int> comparison)
        {
            List<T> r = Clone();
            Algorithms.StableSort<T>(r.items, r.count, comparison);
            r.orden = comparison;
            return r;
        }

        [TrackCaller] public T First(Func<T, bool> predicate)
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return items[i];
            panic("List.First: ningún elemento cumple la condición");
            return default(T);
        }

        public T FirstOrDefault() => count > 0 ? items[0] : default(T);

        public T FirstOrDefault(Func<T, bool> predicate)
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        [TrackCaller] public T Last(Func<T, bool> predicate)
        {
            for (int i = count - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            panic("List.Last: ningún elemento cumple la condición");
            return default(T);
        }

        public T LastOrDefault() => count > 0 ? items[count - 1] : default(T);

        public T LastOrDefault(Func<T, bool> predicate)
        {
            for (int i = count - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        public bool Any() => count > 0;

        public bool Any(Func<T, bool> predicate)
        {
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) return true;
            return false;
        }

        public bool All(Func<T, bool> predicate)
        {
            for (int i = 0; i < count; i++)
                if (!predicate(items[i])) return false;
            return true;
        }

        // Cuántos cumplen la condición (lista.Count sin paréntesis es el total).
        public int Count(Func<T, bool> predicate)
        {
            int n = 0;
            for (int i = 0; i < count; i++)
                if (predicate(items[i])) n++;
            return n;
        }

        public U Sum<U>(Func<T, U> selector)
        {
            U s = default(U);
            for (int i = 0; i < count; i++) s += selector(items[i]);
            return s;
        }

        [TrackCaller] public U Min<U>(Func<T, U> selector)
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

        [TrackCaller] public U Max<U>(Func<T, U> selector)
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
        [TrackCaller] public T MinBy<K>(Func<T, K> key)
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

        [TrackCaller] public T MaxBy<K>(Func<T, K> key)
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

        [TrackCaller] public double Average()
        {
            if (count == 0) panic("List.Average: la lista está vacía");
            return (double)Sum() / count;
        }

        [TrackCaller] public double Average<U>(Func<T, U> selector)
        {
            if (count == 0) panic("List.Average: la lista está vacía");
            return (double)Sum<U>(selector) / count;
        }

        // Sin repetidos, en el orden de la primera aparición (T necesita Hash.Of y '==').
        public List<T> Distinct()
        {
            List<T> r = new List<T>();
            Dictionary<T, bool> seen = new Dictionary<T, bool>();
            for (int i = 0; i < count; i++)
                if (seen.Add(items[i], true)) r.Add(items[i]);
            return r;
        }

        public List<T> Take(int n)
        {
            if (n > count) n = count;
            List<T> r = new List<T>(n < 0 ? 0 : n);
            for (int i = 0; i < n; i++) r.Add(items[i]);
            return r;
        }

        public List<T> Skip(int n)
        {
            if (n < 0) n = 0;
            List<T> r = new List<T>();
            for (int i = n; i < count; i++) r.Add(items[i]);
            return r;
        }

        public List<T> TakeWhile(Func<T, bool> predicate)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < count && predicate(items[i]); i++) r.Add(items[i]);
            return r;
        }

        public List<T> SkipWhile(Func<T, bool> predicate)
        {
            int i = 0;
            while (i < count && predicate(items[i])) i++;
            List<T> r = new List<T>();
            for (; i < count; i++) r.Add(items[i]);
            return r;
        }

        // Grupos por clave, en el orden de la primera aparición de cada clave.
        public List<Grouping<K, T>> GroupBy<K>(Func<T, K> key)
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

        public List<T> ToList() => Clone();

        // Diccionario clave -> elemento (si una clave se repite, gana el último).
        public Dictionary<K, T> ToDictionary<K>(Func<T, K> key)
        {
            Dictionary<K, T> d = new Dictionary<K, T>();
            for (int i = 0; i < count; i++) d.Set(key(items[i]), items[i]);
            return d;
        }

        public Dictionary<K, V> ToDictionary<K, V>(Func<T, K> key, Func<T, V> value)
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
        public List<R> Zip<U, R>(List<U> other, Func<T, U, R> f)
        {
            int n = count < other.Count ? count : other.Count;
            List<R> r = new List<R>(n);
            for (int i = 0; i < n; i++) r.Add(f(items[i], other[i]));
            return r;
        }

        public List<T> Concat(List<T> other)
        {
            List<T> r = Clone();
            r.AddRange(other);
            return r;
        }

        // ---- búsquedas al estilo de List<T> de .NET
        public T Find(Predicate<T> match)
        {
            for (int i = 0; i < count; i++)
                if (match(items[i])) return items[i];
            return default(T);
        }

        public T FindLast(Predicate<T> match)
        {
            for (int i = count - 1; i >= 0; i--)
                if (match(items[i])) return items[i];
            return default(T);
        }

        public List<T> FindAll(Predicate<T> match) => Where(match);

        public int FindIndex(Predicate<T> match)
        {
            for (int i = 0; i < count; i++)
                if (match(items[i])) return i;
            return -1;
        }

        public bool Exists(Predicate<T> match) => FindIndex(match) >= 0;

        public bool TrueForAll(Predicate<T> match) => All(match);

        // Quita los elementos que cumplen la condición; devuelve cuántos quitó.
        public int RemoveAll(Predicate<T> match)
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

        public List<U> ConvertAll<U>(Func<T, U> converter) => Select<U>(converter);
    }

    // Delegados de .NET (estructurales: Predicate<int> es el mismo tipo que Func<int, bool>).
    public delegate bool Predicate<T>(T obj);
    public delegate int Comparison<T>(T x, T y);

    // Resultado de GroupBy: la clave y los elementos del grupo.
    public class Grouping<K, T> : IEnumerable<T>
    {
        public K Key;
        public List<T> Items = new List<T>();
        public Grouping(K key) { Key = key; }
        public int Count => Items.Count;
        [TrackCaller] public T operator[](int index) => Items[index];
        public ListEnumerator<T> GetEnumerator() => Items.GetEnumerator();
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in Items) yield return x; }
    }

    // Enumerador de List<T> para foreach. Si la lista se modifica durante el recorrido,
    // MoveNext termina con panic (como InvalidOperationException en C#).
    public memory_unsafe struct ListEnumerator<T>
    {
        List<T> list;
        int index;
        int version;

        public ListEnumerator(List<T> source)
        {
            list = source;
            index = -1;
            version = source.Version;
        }

        public T Current => list.Data[index];

        [TrackCaller] public bool MoveNext()
        {
            if (version != list.Version) panic("List: la colección se modificó durante un foreach");
            index++;
            return index < list.Count;
        }
    }

    // ---------------------------------------------------------------- Stack<T>
    public class Stack<T> : IEnumerable<T>
    {
        List<T> items = new List<T>();
        ~Stack() { delete items; }

        public int Count => items.Count;
        public bool IsEmpty => items.Count == 0;
        public void Push(T item) { items.Add(item); }
        [TrackCaller] public T Pop() => items.Pop();
        [TrackCaller] public T Peek() => items.Last();
        public void Clear() { items.Clear(); }
        // foreach recorre la pila de la base a la cima (en el orden en que se apilaron).
        public ListEnumerator<T> GetEnumerator() => items.GetEnumerator();
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in items) yield return x; }
    }

    // ---------------------------------------------------------------- Queue<T> (búfer circular)
    public memory_unsafe class Queue<T> : IEnumerable<T>
    {
        T* items;
        int head;
        int count;
        int capacity;

        ~Queue() { Memory.Free(items); }

        public int Count => count;
        public bool IsEmpty => count == 0;

        public void Enqueue(T item)
        {
            if (count == capacity) Grow();
            items[(head + count) % capacity] = item;
            count++;
        }

        [TrackCaller] public T Dequeue()
        {
            if (count == 0) throw new InvalidOperationException("Queue.Dequeue: la cola está vacía");
            T item = items[head];
            head = (head + 1) % capacity;
            count--;
            return item;
        }

        [TrackCaller] public T Peek()
        {
            if (count == 0) throw new InvalidOperationException("Queue.Peek: la cola está vacía");
            return items[head];
        }

        public void Clear() { head = 0; count = 0; }

        // foreach recorre la cola en orden de salida (del primero al último).
        IEnumerator<T> IEnumerable<T>.GetEnumerator()
        {
            for (int i = 0; i < count; i++) yield return items[(head + i) % capacity];
        }

        void Grow()
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
        K* keys;
        V* values;
        byte* used;  // 0 = libre, 1 = ocupado, 2 = borrado
        int count;
        int capacity;
        int tombstones;
        int version;  // cambia con cada inserción o borrado (foreach detecta cambios)

        ~Dictionary()
        {
            Memory.Free(keys);
            Memory.Free(values);
            Memory.Free(used);
        }

        public int Count => count;
        public bool IsEmpty => count == 0;

        // ---- para DictionaryEnumerator (foreach): huecos de la tabla y contador de cambios
        public int Version => version;
        public int SlotCount => capacity;
        public bool SlotUsed(int i) => used[i] == 1;
        public K SlotKey(int i) => keys[i];
        public V SlotValue(int i) => values[i];
        public DictionaryEnumerator<K, V> GetEnumerator() => new DictionaryEnumerator<K, V>(this);
        IEnumerator<KeyValuePair<K, V>> IEnumerable<KeyValuePair<K, V>>.GetEnumerator()
        {
            foreach (KeyValuePair<K, V> kv in this) yield return kv;
        }

        int Find(K key)
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

        void Rehash(int newCap)
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

        int Slot(K key)
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

        public void Set(K key, V value)
        {
            int i = Slot(key);  // Slot puede reasignar 'values': se evalúa primero
            values[i] = value;
        }

        public bool Add(K key, V value)
        {
            if (Find(key) >= 0) return false;
            Set(key, value);
            return true;
        }

        public bool TryGetValue(K key, out V value)
        {
            int i = Find(key);
            if (i < 0) return false;
            value = values[i];
            return true;
        }

        [TrackCaller] public V Get(K key)
        {
            int i = Find(key);
            if (i < 0) throw new KeyNotFoundException("Dictionary.Get: la clave no existe");
            return values[i];
        }

        public V GetOrDefault(K key, V fallback)
        {
            int i = Find(key);
            return i < 0 ? fallback : values[i];
        }

        public bool ContainsKey(K key) => Find(key) >= 0;

        public bool Remove(K key)
        {
            int i = Find(key);
            if (i < 0) return false;
            used[i] = 2;
            count--;
            tombstones++;
            version++;
            return true;
        }

        public void Clear()
        {
            if (capacity > 0) Memory.Set(used, 0, capacity);
            count = 0;
            tombstones = 0;
            version++;
        }

        // Nuevas listas con las claves / valores.
        public List<K> Keys()
        {
            List<K> r = new List<K>(count);
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) r.Add(keys[i]);
            return r;
        }

        public List<V> Values()
        {
            List<V> r = new List<V>(count);
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) r.Add(values[i]);
            return r;
        }

        // ---- con delegados
        // Pares clave/valor (para usar LINQ: dic.Pairs().Where(p => p.Value > 3)).
        public List<KeyValuePair<K, V>> Pairs()
        {
            List<KeyValuePair<K, V>> r = new List<KeyValuePair<K, V>>(count);
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) r.Add(new KeyValuePair<K, V>(keys[i], values[i]));
            return r;
        }

        public void ForEach(Action<K, V> action)
        {
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1) action(keys[i], values[i]);
        }

        // Valor de la clave; si no existe, lo crea con factory(clave).
        public V GetOrAdd(K key, Func<K, V> factory)
        {
            int i = Find(key);
            if (i >= 0) return values[i];
            V v = factory(key);
            Set(key, v);
            return v;
        }

        public bool Any(Func<K, V, bool> predicate)
        {
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1 && predicate(keys[i], values[i])) return true;
            return false;
        }

        public int Count(Func<K, V, bool> predicate)
        {
            int n = 0;
            for (int i = 0; i < capacity; i++)
                if (used[i] == 1 && predicate(keys[i], values[i])) n++;
            return n;
        }

        // Quita las entradas que cumplen la condición; devuelve cuántas quitó.
        public int RemoveAll(Func<K, V, bool> predicate)
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
        public K Key;
        public V Value;

        public KeyValuePair(K key, V value)
        {
            Key = key;
            Value = value;
        }

        public void Deconstruct(out K key, out V value)
        {
            key = Key;
            value = Value;
        }
    }

    // Enumerador de Dictionary<K, V> para foreach (orden de la tabla hash, no de inserción).
    public struct DictionaryEnumerator<K, V>
    {
        Dictionary<K, V> dict;
        int index;
        int version;

        public DictionaryEnumerator(Dictionary<K, V> source)
        {
            dict = source;
            index = -1;
            version = source.Version;
        }

        public KeyValuePair<K, V> Current => new KeyValuePair<K, V>(dict.SlotKey(index), dict.SlotValue(index));

        [TrackCaller] public bool MoveNext()
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
        DictionaryEnumerator<T, bool> inner;

        public HashSetEnumerator(DictionaryEnumerator<T, bool> e) { inner = e; }

        public T Current => inner.Current.Key;
        [TrackCaller] public bool MoveNext() => inner.MoveNext();
    }

    // ---------------------------------------------------------------- HashSet<T>
    public class HashSet<T> : IEnumerable<T>
    {
        Dictionary<T, bool> map = new Dictionary<T, bool>();
        ~HashSet() { delete map; }

        public int Count => map.Count;
        public bool IsEmpty => map.Count == 0;
        public bool Add(T item) => map.Add(item, true);
        public bool Contains(T item) => map.ContainsKey(item);
        public bool Remove(T item) => map.Remove(item);
        public void Clear() { map.Clear(); }
        public List<T> ToList() => map.Keys();
        public T[] ToArray() => map.Keys().ToArray();
        public void UnionWith(T[] other) { foreach (T x in other) Add(x); }
        public void UnionWith(List<T> other) { foreach (T x in other) Add(x); }
        public HashSetEnumerator<T> GetEnumerator() => new HashSetEnumerator<T>(map.GetEnumerator());
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { foreach (T x in this) yield return x; }
    }

    // ---------------------------------------------------------------- algoritmos genéricos
    public memory_unsafe static class Algorithms
    {
        public static void Swap<T>(T& a, T& b)
        {
            T t = a;
            a = b;
            b = t;
        }

        public static void Reverse<T>(T* data, int n)
        {
            for (int i = 0, j = n - 1; i < j; i++, j--) Swap<T>(data[i], data[j]);
        }

        public static void Fill<T>(T* data, int n, T value)
        {
            for (int i = 0; i < n; i++) data[i] = value;
        }

        // Ordena con 'operator<' (quicksort + inserción).
        public static void Sort<T>(T* data, int n)
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
        public static void Sort<T>(T* data, int n, delegate*<T, T, int> compare)
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
        public static int BinarySearch<T>(T* data, int n, T value)
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
        public static void StableSort<T>(T* data, int n, Func<T, T, int> compare)
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

        static void MergeSort<T>(T* data, T* tmp, int n, Func<T, T, int> compare)
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
        public static int CompareKeys<K>(K a, K b) => a < b ? -1 : (b < a ? 1 : 0);

        public static T Min<T>(T a, T b) => b < a ? b : a;
        public static T Max<T>(T a, T b) => a < b ? b : a;
    }
}
