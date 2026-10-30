// =============================================================================
//  std (arreglos)  —  T[], arreglos multidimensionales, índices, rangos y vistas.
//
//    T[]          Array<T>: objeto del recolector con su longitud (int[] a = new int[5];);
//                 también es IEnumerable<T> (LINQ perezoso)
//    T[,] T[,,]   Array2D<T> / Array3D<T>: rectangulares (GetLength, Rank)
//    Array        Sort, Reverse, IndexOf, Fill, Copy, Resize, BinarySearch, Clear...
//    Index        ^1 (desde el final)        Range   1..3, ..^1, 2..
//    Span<T>      vista que se puede modificar de un tramo de un arreglo o una lista (sin copiar)
//    ReadOnlySpan<T>  vista de solo lectura
//
//  Se importa automáticamente (como core.fst). Las clases son 'memory_unsafe' porque guardan
//  los elementos en memoria del recolector (implementación confiable), pero su API pública es
//  segura: todos los accesos comprueban los límites. Los elementos sin punteros (números,
//  structs de números) se reservan como memoria "atómica" que el recolector no recorre.
//
//  El compilador traduce a[i] sobre un T[] directamente a una comprobación de límites y un
//  acceso (sin llamada); la covarianza de C# (string[] -> object[]) no existe en Faset.
// =============================================================================
using std.collections;

namespace std
{
    // ---------------------------------------------------------------- errores de índice
    memory_unsafe static class ArrayRuntime
    {
        [TrackCaller] static extern void faset_panic_index(long index, long length);

        // IndexOutOfRangeException dentro de un 'try'; si no, panic (igual que a[i] fuera de rango).
        [TrackCaller] public static void IndexError(long index, long length) { faset_panic_index(index, length); }

        [TrackCaller] public static void CheckSize(long size)
        {
            if (size < 0) throw new OverflowException("el tamaño de un arreglo no puede ser negativo: " + size);
            if (size > 2147483647) throw new OverflowException("el arreglo es demasiado grande: " + size + " elementos");
        }
    }

    // ---------------------------------------------------------------- Index: ^n
    public struct Index
    {
        int value;
        bool fromEnd;

        public Index(int value, bool fromEnd)
        {
            if (value < 0) throw new ArgumentOutOfRangeException("value", "Index: el valor no puede ser negativo (" + value + ")");
            this.value = value;
            this.fromEnd = fromEnd;
        }

        public Index(int value) : this(value, false) { }

        public int Value => value;
        public bool IsFromEnd => fromEnd;
        public static Index Start => new Index(0, false);
        public static Index End => new Index(0, true);
        [TrackCaller] public static Index FromStart(int value) => new Index(value, false);
        [TrackCaller] public static Index FromEnd(int value) => new Index(value, true);

        // Posición dentro de una secuencia de 'length' elementos.
        public int GetOffset(int length) => fromEnd ? length - value : value;

        public string ToString() => fromEnd ? "^" + value : "" + value;
    }

    // ---------------------------------------------------------------- Range: a..b
    public struct Range
    {
        Index start;
        Index end;

        public Range(Index start, Index end)
        {
            this.start = start;
            this.end = end;
        }

        public Index Start => start;
        public Index End => end;
        public static Range All => new Range(Index.Start, Index.End);
        public static Range StartAt(Index start) => new Range(start, Index.End);
        public static Range EndAt(Index end) => new Range(Index.Start, end);

        // (inicio, longitud) dentro de una secuencia de 'length' elementos.
        [TrackCaller] public (int, int) GetOffsetAndLength(int length)
        {
            int s = start.GetOffset(length);
            int e = end.GetOffset(length);
            if (s < 0 || e > length || s > e)
                throw new ArgumentOutOfRangeException("range", "el rango " + ToString() + " se sale de los límites (longitud " + length + ")");
            return (s, e - s);
        }

        public string ToString() => start.ToString() + ".." + end.ToString();
    }

    // ---------------------------------------------------------------- T[]
    public sealed memory_unsafe class Array<T> : IEnumerable<T>
    {
        T* items;
        int length;

        public Array(long length)
        {
            ArrayRuntime.CheckSize(length);
            items = new T[length];
            this.length = (int)length;
        }

        public int Length => length;
        public long LongLength => length;
        public int Rank => 1;
        // Como List<T>.Count: el código escrito para listas (y 'params') sigue funcionando.
        public int Count => length;
        public bool IsEmpty => length == 0;
        // Puntero a los elementos (solo desde memory_unsafe). El arreglo no cambia de tamaño.
        public T* Data => items;

        [TrackCaller] public T& operator[](int index)
        {
            if ((uint)index >= (uint)length) ArrayRuntime.IndexError(index, length);
            return items[index];
        }

        [TrackCaller] public T& operator[](long index)
        {
            if ((ulong)index >= (ulong)length) ArrayRuntime.IndexError(index, length);
            return items[index];
        }

        [TrackCaller] public T& operator[](Index index)
        {
            int i = index.GetOffset(length);
            if ((uint)i >= (uint)length) ArrayRuntime.IndexError(i, length);
            return items[i];
        }

        // a[1..3]: copia de los elementos del rango.
        [TrackCaller] public T[] operator[](Range range)
        {
            var (s, n) = range.GetOffsetAndLength(length);
            return Copy(s, n);
        }

        T[] Copy(int start, int count)
        {
            T[] r = new T[count];
            Memory.CopyItems<T>(r.items, items + start, count);
            return r;
        }

        public ArrayEnumerator<T> GetEnumerator() => new ArrayEnumerator<T>(this);
        // Como IEnumerable<T> (LINQ perezoso, parámetros IEnumerable<T>): ver collections/iteradores.fst.
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { for (int i = 0; i < length; i++) yield return items[i]; }

        // Copia superficial (los elementos de clase se comparten).
        public T[] Clone() => Copy(0, length);
        public T[] ToArray() => Copy(0, length);

        public List<T> ToList()
        {
            List<T> r = new List<T>(length);
            for (int i = 0; i < length; i++) r.Add(items[i]);
            return r;
        }

        // Vistas sin copia.
        public Span<T> AsSpan() => new Span<T>(this);
        [TrackCaller] public Span<T> AsSpan(int start) => new Span<T>(this, start, length - start);
        [TrackCaller] public Span<T> AsSpan(int start, int count) => new Span<T>(this, start, count);
        [TrackCaller] public Span<T> AsSpan(Range range)
        {
            var (s, n) = range.GetOffsetAndLength(length);
            return new Span<T>(this, s, n);
        }

        [TrackCaller] public void CopyTo(T[] destination, int index)
        {
            if (index < 0 || index > destination.Length || length > destination.Length - index)
                throw new ArgumentException("CopyTo: el destino es demasiado pequeño");
            Memory.CopyItems<T>(destination.items + index, items, length);
        }

        public void Fill(T value)
        {
            for (int i = 0; i < length; i++) items[i] = value;
        }

        public int IndexOf(T item)
        {
            for (int i = 0; i < length; i++)
                if (items[i] == item) return i;
            return -1;
        }

        public bool Contains(T item) => IndexOf(item) >= 0;

        // Mismos elementos en el mismo orden (con ==).
        public bool SequenceEqual(T[] other)
        {
            if (other == null || other.length != length) return false;
            for (int i = 0; i < length; i++)
                if (!(items[i] == other.items[i])) return false;
            return true;
        }

        // ============================================================ LINQ
        //  Como en List<T>: evaluación inmediata; las operaciones que producen una secuencia
        //  devuelven una List<T> nueva (usa .ToArray() para volver a un arreglo).

        public List<T> Where(Func<T, bool> predicate)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) r.Add(items[i]);
            return r;
        }

        public List<T> Where(Func<T, int, bool> predicate)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < length; i++)
                if (predicate(items[i], i)) r.Add(items[i]);
            return r;
        }

        public List<U> Select<U>(Func<T, U> selector)
        {
            List<U> r = new List<U>(length);
            for (int i = 0; i < length; i++) r.Add(selector(items[i]));
            return r;
        }

        public List<U> Select<U>(Func<T, int, U> selector)
        {
            List<U> r = new List<U>(length);
            for (int i = 0; i < length; i++) r.Add(selector(items[i], i));
            return r;
        }

        public List<U> SelectMany<U>(Func<T, List<U>> selector)
        {
            List<U> r = new List<U>();
            for (int i = 0; i < length; i++) r.AddRange(selector(items[i]));
            return r;
        }

        public void ForEach(Action<T> action)
        {
            for (int i = 0; i < length; i++) action(items[i]);
        }

        public bool Any() => length > 0;

        public bool Any(Func<T, bool> predicate)
        {
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) return true;
            return false;
        }

        public bool All(Func<T, bool> predicate)
        {
            for (int i = 0; i < length; i++)
                if (!predicate(items[i])) return false;
            return true;
        }

        public int Count(Func<T, bool> predicate)
        {
            int n = 0;
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) n++;
            return n;
        }

        [TrackCaller] public T First()
        {
            if (length == 0) throw new InvalidOperationException("First: el arreglo está vacío");
            return items[0];
        }

        [TrackCaller] public T First(Func<T, bool> predicate)
        {
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) return items[i];
            throw new InvalidOperationException("First: ningún elemento cumple la condición");
        }

        public T FirstOrDefault() => length > 0 ? items[0] : default(T);

        public T FirstOrDefault(Func<T, bool> predicate)
        {
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        [TrackCaller] public T Last()
        {
            if (length == 0) throw new InvalidOperationException("Last: el arreglo está vacío");
            return items[length - 1];
        }

        [TrackCaller] public T Last(Func<T, bool> predicate)
        {
            for (int i = length - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            throw new InvalidOperationException("Last: ningún elemento cumple la condición");
        }

        public T LastOrDefault() => length > 0 ? items[length - 1] : default(T);

        public T LastOrDefault(Func<T, bool> predicate)
        {
            for (int i = length - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        public T Sum()
        {
            T s = default(T);
            for (int i = 0; i < length; i++) s += items[i];
            return s;
        }

        public U Sum<U>(Func<T, U> selector)
        {
            U s = default(U);
            for (int i = 0; i < length; i++) s += selector(items[i]);
            return s;
        }

        [TrackCaller] public T Min()
        {
            T m = First();
            for (int i = 1; i < length; i++)
                if (items[i] < m) m = items[i];
            return m;
        }

        [TrackCaller] public T Max()
        {
            T m = First();
            for (int i = 1; i < length; i++)
                if (m < items[i]) m = items[i];
            return m;
        }

        [TrackCaller] public U Min<U>(Func<T, U> selector) => ToList().Min<U>(selector);
        [TrackCaller] public U Max<U>(Func<T, U> selector) => ToList().Max<U>(selector);
        [TrackCaller] public T MinBy<K>(Func<T, K> key) => ToList().MinBy<K>(key);
        [TrackCaller] public T MaxBy<K>(Func<T, K> key) => ToList().MaxBy<K>(key);
        [TrackCaller] public double Average() => ToList().Average();
        [TrackCaller] public double Average<U>(Func<T, U> selector) => ToList().Average<U>(selector);
        public List<T> OrderBy<K>(Func<T, K> key) => ToList().OrderBy<K>(key);
        public List<T> OrderByDescending<K>(Func<T, K> key) => ToList().OrderByDescending<K>(key);
        public List<T> Distinct() => ToList().Distinct();
        public List<T> TakeWhile(Func<T, bool> predicate) => ToList().TakeWhile(predicate);
        public List<T> SkipWhile(Func<T, bool> predicate) => ToList().SkipWhile(predicate);
        public List<Grouping<K, T>> GroupBy<K>(Func<T, K> key) => ToList().GroupBy<K>(key);
        public Dictionary<K, T> ToDictionary<K>(Func<T, K> key) => ToList().ToDictionary<K>(key);
        public Dictionary<K, V> ToDictionary<K, V>(Func<T, K> key, Func<T, V> value) => ToList().ToDictionary<K, V>(key, value);
        [TrackCaller] public T Aggregate(Func<T, T, T> func) => ToList().Aggregate(func);
        public A Aggregate<A>(A seed, Func<A, T, A> func) => ToList().Aggregate<A>(seed, func);

        public List<T> Take(int n)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < length && i < n; i++) r.Add(items[i]);
            return r;
        }

        public List<T> Skip(int n)
        {
            List<T> r = new List<T>();
            for (int i = n < 0 ? 0 : n; i < length; i++) r.Add(items[i]);
            return r;
        }

        public List<T> Concat(T[] other)
        {
            List<T> r = ToList();
            r.AddRange(other);
            return r;
        }

        public List<R> Zip<U, R>(U[] other, Func<T, U, R> f)
        {
            List<R> r = new List<R>();
            for (int i = 0; i < length && i < other.Length; i++) r.Add(f(items[i], other[i]));
            return r;
        }
    }

    // Enumerador de T[] para foreach (el compilador recorre los arreglos con un bucle de índices;
    // este enumerador lo usan las llamadas explícitas a GetEnumerator()).
    public struct ArrayEnumerator<T>
    {
        T[] array;
        int index;

        public ArrayEnumerator(T[] source)
        {
            array = source;
            index = -1;
        }

        public T Current => array[index];

        public bool MoveNext()
        {
            index++;
            return index < array.Length;
        }
    }

    // ---------------------------------------------------------------- T[,] y T[,,]
    //  Los elementos están seguidos por filas (el último índice cambia más rápido).
    public sealed class Array2D<T>
    {
        T[] data;
        int n0;
        int n1;

        public Array2D(int length0, int length1)
        {
            ArrayRuntime.CheckSize(length0);
            ArrayRuntime.CheckSize(length1);
            ArrayRuntime.CheckSize((long)length0 * length1);
            n0 = length0;
            n1 = length1;
            data = new T[length0 * length1];
        }

        public int Length => data.Length;
        public int Rank => 2;

        [TrackCaller] public int GetLength(int dimension)
        {
            if (dimension == 0) return n0;
            if (dimension == 1) return n1;
            throw new IndexOutOfRangeException("GetLength: la dimensión " + dimension + " no existe (el arreglo tiene 2)");
        }

        [TrackCaller] public int GetUpperBound(int dimension) => GetLength(dimension) - 1;
        [TrackCaller] public int GetLowerBound(int dimension) => GetLength(dimension) * 0;

        [TrackCaller] public T& operator[]((int, int) index)
        {
            int i = index.Item1;
            int j = index.Item2;
            if ((uint)i >= (uint)n0) ArrayRuntime.IndexError(i, n0);
            if ((uint)j >= (uint)n1) ArrayRuntime.IndexError(j, n1);
            return data[i * n1 + j];
        }

        public ArrayEnumerator<T> GetEnumerator() => data.GetEnumerator();
        public void Fill(T value) { data.Fill(value); }

        public T[,] Clone()
        {
            T[,] r = new T[n0, n1];
            for (int i = 0; i < data.Length; i++) r.data[i] = data[i];
            return r;
        }

        // Los elementos en orden de filas, en un arreglo de una dimensión.
        public T[] ToArray() => data.Clone();
    }

    public sealed class Array3D<T>
    {
        T[] data;
        int n0;
        int n1;
        int n2;

        public Array3D(int length0, int length1, int length2)
        {
            ArrayRuntime.CheckSize(length0);
            ArrayRuntime.CheckSize(length1);
            ArrayRuntime.CheckSize(length2);
            ArrayRuntime.CheckSize((long)length0 * length1 * length2);
            n0 = length0;
            n1 = length1;
            n2 = length2;
            data = new T[length0 * length1 * length2];
        }

        public int Length => data.Length;
        public int Rank => 3;

        [TrackCaller] public int GetLength(int dimension)
        {
            if (dimension == 0) return n0;
            if (dimension == 1) return n1;
            if (dimension == 2) return n2;
            throw new IndexOutOfRangeException("GetLength: la dimensión " + dimension + " no existe (el arreglo tiene 3)");
        }

        [TrackCaller] public int GetUpperBound(int dimension) => GetLength(dimension) - 1;
        [TrackCaller] public int GetLowerBound(int dimension) => GetLength(dimension) * 0;

        [TrackCaller] public T& operator[]((int, int, int) index)
        {
            int i = index.Item1;
            int j = index.Item2;
            int k = index.Item3;
            if ((uint)i >= (uint)n0) ArrayRuntime.IndexError(i, n0);
            if ((uint)j >= (uint)n1) ArrayRuntime.IndexError(j, n1);
            if ((uint)k >= (uint)n2) ArrayRuntime.IndexError(k, n2);
            return data[(i * n1 + j) * n2 + k];
        }

        public ArrayEnumerator<T> GetEnumerator() => data.GetEnumerator();
        public void Fill(T value) { data.Fill(value); }
        public T[] ToArray() => data.Clone();
    }

    // ---------------------------------------------------------------- Array (estática)
    public memory_unsafe static class Array
    {
        public static T[] Empty<T>() => new T[0];

        // Ordena con 'operator<' (string compara por orden).
        public static void Sort<T>(T[] array) { Algorithms.Sort<T>(array.Data, array.Length); }

        // Ordena con una comparación (negativo, cero o positivo). Estable.
        public static void Sort<T>(T[] array, Comparison<T> comparison) { Algorithms.StableSort<T>(array.Data, array.Length, comparison); }

        [TrackCaller] public static void Sort<T>(T[] array, int index, int length)
        {
            CheckSegment(array.Length, index, length);
            Algorithms.Sort<T>(array.Data + index, length);
        }

        public static void Reverse<T>(T[] array) { Algorithms.Reverse<T>(array.Data, array.Length); }

        [TrackCaller] public static void Reverse<T>(T[] array, int index, int length)
        {
            CheckSegment(array.Length, index, length);
            Algorithms.Reverse<T>(array.Data + index, length);
        }

        public static int IndexOf<T>(T[] array, T value) => array.IndexOf(value);

        [TrackCaller] public static int IndexOf<T>(T[] array, T value, int startIndex)
        {
            CheckSegment(array.Length, startIndex, array.Length - startIndex);
            for (int i = startIndex; i < array.Length; i++)
                if (array[i] == value) return i;
            return -1;
        }

        public static int LastIndexOf<T>(T[] array, T value)
        {
            for (int i = array.Length - 1; i >= 0; i--)
                if (array[i] == value) return i;
            return -1;
        }

        public static void Fill<T>(T[] array, T value) { array.Fill(value); }

        [TrackCaller] public static void Fill<T>(T[] array, T value, int startIndex, int count)
        {
            CheckSegment(array.Length, startIndex, count);
            for (int i = 0; i < count; i++) array[startIndex + i] = value;
        }

        // Copia 'length' elementos del principio de 'source' al principio de 'destination'.
        [TrackCaller] public static void Copy<T>(T[] source, T[] destination, int length) { Copy<T>(source, 0, destination, 0, length); }

        // Admite que origen y destino sean el mismo arreglo y se solapen.
        [TrackCaller] public static void Copy<T>(T[] source, int sourceIndex, T[] destination, int destinationIndex, int length)
        {
            CheckSegment(source.Length, sourceIndex, length);
            CheckSegment(destination.Length, destinationIndex, length);
            Memory.CopyItems<T>(destination.Data + destinationIndex, source.Data + sourceIndex, length);
        }

        // Cambia el tamaño: crea un arreglo nuevo con los elementos que caben (Array.Resize(ref a, n)).
        [TrackCaller] public static void Resize<T>(T[]& array, int newSize)
        {
            T[] r = new T[newSize];
            if (array != null) Copy<T>(array, r, array.Length < newSize ? array.Length : newSize);
            array = r;
        }

        // Búsqueda binaria en un arreglo ordenado: el índice, o el complemento (~) del lugar donde
        // iría si no está (un número negativo).
        public static int BinarySearch<T>(T[] array, T value)
        {
            int lo = 0;
            int hi = array.Length - 1;
            while (lo <= hi)
            {
                int mid = lo + (hi - lo) / 2;
                if (array[mid] < value) lo = mid + 1;
                else if (value < array[mid]) hi = mid - 1;
                else return mid;
            }
            return ~lo;
        }

        // Pone los elementos a su valor por defecto (0, null, false...).
        public static void Clear<T>(T[] array) { array.Fill(default(T)); }

        [TrackCaller] public static void Clear<T>(T[] array, int index, int length) { Fill<T>(array, default(T), index, length); }

        public static bool Exists<T>(T[] array, Predicate<T> match) => FindIndex<T>(array, match) >= 0;
        public static bool TrueForAll<T>(T[] array, Predicate<T> match)
        {
            for (int i = 0; i < array.Length; i++)
                if (!match(array[i])) return false;
            return true;
        }

        public static T Find<T>(T[] array, Predicate<T> match)
        {
            for (int i = 0; i < array.Length; i++)
                if (match(array[i])) return array[i];
            return default(T);
        }

        public static T FindLast<T>(T[] array, Predicate<T> match)
        {
            for (int i = array.Length - 1; i >= 0; i--)
                if (match(array[i])) return array[i];
            return default(T);
        }

        public static int FindIndex<T>(T[] array, Predicate<T> match)
        {
            for (int i = 0; i < array.Length; i++)
                if (match(array[i])) return i;
            return -1;
        }

        public static int FindLastIndex<T>(T[] array, Predicate<T> match)
        {
            for (int i = array.Length - 1; i >= 0; i--)
                if (match(array[i])) return i;
            return -1;
        }

        public static T[] FindAll<T>(T[] array, Predicate<T> match)
        {
            List<T> r = new List<T>();
            for (int i = 0; i < array.Length; i++)
                if (match(array[i])) r.Add(array[i]);
            return r.ToArray();
        }

        public static U[] ConvertAll<T, U>(T[] array, Func<T, U> converter)
        {
            U[] r = new U[array.Length];
            for (int i = 0; i < array.Length; i++) r[i] = converter(array[i]);
            return r;
        }

        public static void ForEach<T>(T[] array, Action<T> action)
        {
            for (int i = 0; i < array.Length; i++) action(array[i]);
        }

        [TrackCaller] static void CheckSegment(int total, int index, int length)
        {
            if (index < 0 || length < 0 || index > total || length > total - index)
                throw new ArgumentOutOfRangeException("index", "el tramo [" + index + ", " + index + " + " + length +
                                                      ") se sale del arreglo (longitud " + total + ")");
        }
    }

    // ---------------------------------------------------------------- Span<T> y ReadOnlySpan<T>
    //  Vista segura (sin copia) de un tramo de un T[] o de una List<T>: comprueba los límites en
    //  cada acceso y mantiene vivo el arreglo o la lista. No confundir con std.mem.Span<T>, la
    //  vista de punteros de bajo nivel (memory_unsafe); si un archivo hace 'using std.mem;',
    //  'Span' se refiere a la de std.mem.
    public memory_unsafe struct Span<T>
    {
        T[] array;      // origen: un arreglo...
        List<T> list;   // ...o una lista (se indexa a través de ella: puede crecer o encoger)
        int start;
        int length;

        public Span(T[] array)
        {
            this.array = array;
            length = array == null ? 0 : array.Length;
        }

        public Span(T[] array, int start, int length)
        {
            int total = array == null ? 0 : array.Length;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "Span: el tramo se sale del arreglo");
            this.array = array;
            this.start = start;
            this.length = length;
        }

        public Span(List<T> list)
        {
            this.list = list;
            length = list == null ? 0 : list.Count;
        }

        public Span(List<T> list, int start, int length)
        {
            int total = list == null ? 0 : list.Count;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "Span: el tramo se sale de la lista");
            this.list = list;
            this.start = start;
            this.length = length;
        }

        public static Span<T> Empty => default(Span<T>);
        public int Length => length;
        public bool IsEmpty => length == 0;

        [TrackCaller] public T& operator[](int index)
        {
            if ((uint)index >= (uint)length) ArrayRuntime.IndexError(index, length);
            if (array != null) return array[start + index];
            return list[start + index];
        }

        [TrackCaller] public T& operator[](Index index) => this[index.GetOffset(length)];

        [TrackCaller] public Span<T> operator[](Range range)
        {
            var (s, n) = range.GetOffsetAndLength(length);
            return Slice(s, n);
        }

        [TrackCaller] public Span<T> Slice(int start) => Slice(start, length - start);

        [TrackCaller] public Span<T> Slice(int start, int length)
        {
            if (start < 0 || length < 0 || start > this.length || length > this.length - start)
                throw new ArgumentOutOfRangeException("start", "Span.Slice: el tramo se sale de la vista");
            Span<T> r = this;
            r.start = this.start + start;
            r.length = length;
            return r;
        }

        public ReadOnlySpan<T> AsReadOnly() => array != null ? new ReadOnlySpan<T>(array, start, length) : new ReadOnlySpan<T>(list, start, length);

        public void Fill(T value)
        {
            for (int i = 0; i < length; i++) this[i] = value;
        }

        public void Clear() { Fill(default(T)); }

        [TrackCaller] public void CopyTo(Span<T> destination)
        {
            if (destination.Length < length) throw new ArgumentException("Span.CopyTo: el destino es demasiado pequeño");
            if (array != null && destination.array == array && destination.start > start)
                for (int i = length - 1; i >= 0; i--) destination[i] = this[i];  // solapados: de atrás adelante
            else
                for (int i = 0; i < length; i++) destination[i] = this[i];
        }

        public T[] ToArray()
        {
            T[] r = new T[length];
            for (int i = 0; i < length; i++) r[i] = this[i];
            return r;
        }

        public List<T> ToList()
        {
            List<T> r = new List<T>(length);
            for (int i = 0; i < length; i++) r.Add(this[i]);
            return r;
        }

        public int IndexOf(T item)
        {
            for (int i = 0; i < length; i++)
                if (this[i] == item) return i;
            return -1;
        }

        public bool Contains(T item) => IndexOf(item) >= 0;

        public void Reverse()
        {
            for (int i = 0, j = length - 1; i < j; i++, j--)
            {
                T t = this[i];
                this[i] = this[j];
                this[j] = t;
            }
        }

        // Ordena el tramo en su sitio con 'operator<'.
        public void Sort()
        {
            if (length == 0) return;
            if (array != null) Algorithms.Sort<T>(array.Data + start, length);
            else Algorithms.Sort<T>(list.Data + start, length);
        }

        public SpanItems<T> GetEnumerator() => new SpanItems<T>(array, list, start, length);
    }

    public memory_unsafe struct ReadOnlySpan<T>
    {
        T[] array;
        List<T> list;
        int start;
        int length;

        public ReadOnlySpan(T[] array)
        {
            this.array = array;
            length = array == null ? 0 : array.Length;
        }

        public ReadOnlySpan(T[] array, int start, int length)
        {
            int total = array == null ? 0 : array.Length;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "ReadOnlySpan: el tramo se sale del arreglo");
            this.array = array;
            this.start = start;
            this.length = length;
        }

        public ReadOnlySpan(List<T> list)
        {
            this.list = list;
            length = list == null ? 0 : list.Count;
        }

        public ReadOnlySpan(List<T> list, int start, int length)
        {
            int total = list == null ? 0 : list.Count;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "ReadOnlySpan: el tramo se sale de la lista");
            this.list = list;
            this.start = start;
            this.length = length;
        }

        public static ReadOnlySpan<T> Empty => default(ReadOnlySpan<T>);
        public int Length => length;
        public bool IsEmpty => length == 0;

        // Solo lectura: devuelve una copia del elemento (no se puede asignar).
        [TrackCaller] public T operator[](int index)
        {
            if ((uint)index >= (uint)length) ArrayRuntime.IndexError(index, length);
            if (array != null) return array[start + index];
            return list[start + index];
        }

        [TrackCaller] public T operator[](Index index) => this[index.GetOffset(length)];

        [TrackCaller] public ReadOnlySpan<T> operator[](Range range)
        {
            var (s, n) = range.GetOffsetAndLength(length);
            return Slice(s, n);
        }

        [TrackCaller] public ReadOnlySpan<T> Slice(int start) => Slice(start, length - start);

        [TrackCaller] public ReadOnlySpan<T> Slice(int start, int length)
        {
            if (start < 0 || length < 0 || start > this.length || length > this.length - start)
                throw new ArgumentOutOfRangeException("start", "ReadOnlySpan.Slice: el tramo se sale de la vista");
            ReadOnlySpan<T> r = this;
            r.start = this.start + start;
            r.length = length;
            return r;
        }

        [TrackCaller] public void CopyTo(Span<T> destination)
        {
            if (destination.Length < length) throw new ArgumentException("ReadOnlySpan.CopyTo: el destino es demasiado pequeño");
            T[] tmp = ToArray();  // el destino puede solaparse con esta vista
            for (int i = 0; i < length; i++) destination[i] = tmp[i];
        }

        public T[] ToArray()
        {
            T[] r = new T[length];
            for (int i = 0; i < length; i++) r[i] = this[i];
            return r;
        }

        public List<T> ToList()
        {
            List<T> r = new List<T>(length);
            for (int i = 0; i < length; i++) r.Add(this[i]);
            return r;
        }

        public int IndexOf(T item)
        {
            for (int i = 0; i < length; i++)
                if (this[i] == item) return i;
            return -1;
        }

        public bool Contains(T item) => IndexOf(item) >= 0;

        public SpanItems<T> GetEnumerator() => new SpanItems<T>(array, list, start, length);
    }

    // Enumerador de Span<T> y ReadOnlySpan<T> para foreach.
    public struct SpanItems<T>
    {
        T[] array;
        List<T> list;
        int start;
        int length;
        int index;

        public SpanItems(T[] array, List<T> list, int start, int length)
        {
            this.array = array;
            this.list = list;
            this.start = start;
            this.length = length;
            index = -1;
        }

        [TrackCaller] public T Current => array != null ? array[start + index] : list[start + index];

        public bool MoveNext()
        {
            index++;
            return index < length;
        }
    }

    // ---------------------------------------------------------------- IEnumerable<T> -> T[]
    public static class ArrayLinq
    {
        // Recorre la secuencia (perezosa o no) y guarda sus elementos en un arreglo nuevo.
        public static T[] ToArray<T>(this IEnumerable<T> source) => source.ToList().ToArray();
    }

    // ---------------------------------------------------------------- rangos sobre cadenas
    public static class RangeExtensions
    {
        // s[1..3]: la subcadena del rango (en bytes UTF-8, como s[i] y s.Length).
        [TrackCaller] public static string Slice(this string s, Range range)
        {
            var (start, n) = range.GetOffsetAndLength(s.Length);
            return s.Substring(start, n);
        }

        // s[^1]: el byte en esa posición.
        [TrackCaller] public static byte At(this string s, Index index) => s[index.GetOffset(s.Length)];
    }
}
