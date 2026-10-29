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
    public memory_unsafe class List<T>
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
        // Puntero a los elementos (válido hasta la próxima modificación).
        public T* Data => items;

        [TrackCaller] public T& operator[](int index)
        {
            if (index < 0 || index >= count) panic("List: índice fuera de rango");
            return items[index];
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
            if (index < 0 || index > count) panic("List.Insert: índice fuera de rango");
            if (count == capacity) Reserve(capacity < 8 ? 8 : capacity * 2);
            for (int i = count; i > index; i--) items[i] = items[i - 1];
            items[index] = item;
            count++;
            version++;
        }

        [TrackCaller] public void RemoveAt(int index)
        {
            if (index < 0 || index >= count) panic("List.RemoveAt: índice fuera de rango");
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
            if (count == 0) panic("List.First: la lista está vacía");
            return items[0];
        }

        [TrackCaller] public T Last()
        {
            if (count == 0) panic("List.Last: la lista está vacía");
            return items[count - 1];
        }

        [TrackCaller] public T Pop()
        {
            if (count == 0) panic("List.Pop: la lista está vacía");
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
    public class Stack<T>
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
    }

    // ---------------------------------------------------------------- Queue<T> (búfer circular)
    public memory_unsafe class Queue<T>
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
            if (count == 0) panic("Queue.Dequeue: la cola está vacía");
            T item = items[head];
            head = (head + 1) % capacity;
            count--;
            return item;
        }

        [TrackCaller] public T Peek()
        {
            if (count == 0) panic("Queue.Peek: la cola está vacía");
            return items[head];
        }

        public void Clear() { head = 0; count = 0; }

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
    public memory_unsafe class Dictionary<K, V>
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
            if (i < 0) panic("Dictionary.Get: la clave no existe");
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
    }

    // Par clave/valor de un Dictionary (lo que recorre foreach). Admite deconstrucción:
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
    public class HashSet<T>
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
        public HashSetEnumerator<T> GetEnumerator() => new HashSetEnumerator<T>(map.GetEnumerator());
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

        public static T Min<T>(T a, T b) => b < a ? b : a;
        public static T Max<T>(T a, T b) => a < b ? b : a;
    }
}
