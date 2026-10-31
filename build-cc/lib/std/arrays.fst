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
        [TrackCaller] public static func IndexError(index: long, length: long) { faset_panic_index(index, length); }

        [TrackCaller] public static func CheckSize(size: long)
        {
            if (size < 0) throw new OverflowException("el tamaño de un arreglo no puede ser negativo: " + size);
            if (size > 2147483647) throw new OverflowException("el arreglo es demasiado grande: " + size + " elementos");
        }
    }

    // ---------------------------------------------------------------- Index: ^n
    public struct Index
    {
        var value: int;
        var fromEnd: bool;

        public init(value: int, fromEnd: bool)
        {
            if (value < 0) throw new ArgumentOutOfRangeException("value", "Index: el valor no puede ser negativo (" + value + ")");
            this.value = value;
            this.fromEnd = fromEnd;
        }

        public init(value: int) : this(value, false) { }

        public prop Value: int => value;
        public prop IsFromEnd: bool => fromEnd;
        public static prop Start: Index => new Index(0, false);
        public static prop End: Index => new Index(0, true);
        [TrackCaller] public static func FromStart(value: int) -> Index => new Index(value, false);
        [TrackCaller] public static func FromEnd(value: int) -> Index => new Index(value, true);

        // Posición dentro de una secuencia de 'length' elementos.
        public func GetOffset(length: int) -> int => fromEnd ? length - value : value;

        public func ToString() -> string => fromEnd ? "^" + value : "" + value;
    }

    // ---------------------------------------------------------------- Range: a..b
    public struct Range
    {
        var start: Index;
        var end: Index;

        public init(start: Index, end: Index)
        {
            this.start = start;
            this.end = end;
        }

        public prop Start: Index => start;
        public prop End: Index => end;
        public static prop All: Range => new Range(Index.Start, Index.End);
        public static func StartAt(start: Index) -> Range => new Range(start, Index.End);
        public static func EndAt(end: Index) -> Range => new Range(Index.Start, end);

        // (inicio, longitud) dentro de una secuencia de 'length' elementos.
        [TrackCaller] public func GetOffsetAndLength(length: int) -> (int, int)
        {
            int s = start.GetOffset(length);
            int e = end.GetOffset(length);
            if (s < 0 || e > length || s > e)
                throw new ArgumentOutOfRangeException("range", "el rango " + ToString() + " se sale de los límites (longitud " + length + ")");
            return (s, e - s);
        }

        public func ToString() -> string => start.ToString() + ".." + end.ToString();
    }

    // ---------------------------------------------------------------- T[]
    public sealed memory_unsafe class Array<T> : IEnumerable<T>
    {
        var items: T*;
        var length: int;

        public init(length: long)
        {
            ArrayRuntime.CheckSize(length);
            items = new T[length];
            this.length = (int)length;
        }

        public prop Length: int => length;
        public prop LongLength: long => length;
        public prop Rank: int => 1;
        // Como List<T>.Count: el código escrito para listas (y 'params') sigue funcionando.
        public prop Count: int => length;
        public prop IsEmpty: bool => length == 0;
        // Puntero a los elementos (solo desde memory_unsafe). El arreglo no cambia de tamaño.
        public prop Data: T* => items;

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

        func Copy(start: int, count: int) -> T[]
        {
            T[] r = new T[count];
            Memory.CopyItems<T>(r.items, items + start, count);
            return r;
        }

        public func GetEnumerator() -> ArrayEnumerator<T> => new ArrayEnumerator<T>(this);
        // Como IEnumerable<T> (LINQ perezoso, parámetros IEnumerable<T>): ver collections/iteradores.fst.
        IEnumerator<T> IEnumerable<T>.GetEnumerator() { for (int i = 0; i < length; i++) yield return items[i]; }

        // Copia superficial (los elementos de clase se comparten).
        public func Clone() -> T[] => Copy(0, length);
        public func ToArray() -> T[] => Copy(0, length);

        public func ToList() -> List<T>
        {
            List<T> r = new List<T>(length);
            for (int i = 0; i < length; i++) r.Add(items[i]);
            return r;
        }

        // Vistas sin copia.
        public func AsSpan() -> Span<T> => new Span<T>(this);
        [TrackCaller] public func AsSpan(start: int) -> Span<T> => new Span<T>(this, start, length - start);
        [TrackCaller] public func AsSpan(start: int, count: int) -> Span<T> => new Span<T>(this, start, count);
        [TrackCaller] public func AsSpan(range: Range) -> Span<T>
        {
            var (s, n) = range.GetOffsetAndLength(length);
            return new Span<T>(this, s, n);
        }

        [TrackCaller] public func CopyTo(destination: T[], index: int)
        {
            if (index < 0 || index > destination.Length || length > destination.Length - index)
                throw new ArgumentException("CopyTo: el destino es demasiado pequeño");
            Memory.CopyItems<T>(destination.items + index, items, length);
        }

        public func Fill(value: T)
        {
            for (int i = 0; i < length; i++) items[i] = value;
        }

        public func IndexOf(item: T) -> int
        {
            for (int i = 0; i < length; i++)
                if (items[i] == item) return i;
            return -1;
        }

        public func Contains(item: T) -> bool => IndexOf(item) >= 0;

        // Mismos elementos en el mismo orden (con ==).
        public func SequenceEqual(other: T[]) -> bool
        {
            if (other == null || other.length != length) return false;
            for (int i = 0; i < length; i++)
                if (!(items[i] == other.items[i])) return false;
            return true;
        }

        // ============================================================ LINQ
        //  Como en List<T>: evaluación inmediata; las operaciones que producen una secuencia
        //  devuelven una List<T> nueva (usa .ToArray() para volver a un arreglo).

        public func Where(predicate: Func<T, bool>) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) r.Add(items[i]);
            return r;
        }

        public func Where(predicate: Func<T, int, bool>) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = 0; i < length; i++)
                if (predicate(items[i], i)) r.Add(items[i]);
            return r;
        }

        public func Select<U>(selector: Func<T, U>) -> List<U>
        {
            List<U> r = new List<U>(length);
            for (int i = 0; i < length; i++) r.Add(selector(items[i]));
            return r;
        }

        public func Select<U>(selector: Func<T, int, U>) -> List<U>
        {
            List<U> r = new List<U>(length);
            for (int i = 0; i < length; i++) r.Add(selector(items[i], i));
            return r;
        }

        public func SelectMany<U>(selector: Func<T, List<U>>) -> List<U>
        {
            List<U> r = new List<U>();
            for (int i = 0; i < length; i++) r.AddRange(selector(items[i]));
            return r;
        }

        public func ForEach(action: Action<T>)
        {
            for (int i = 0; i < length; i++) action(items[i]);
        }

        public func Any() -> bool => length > 0;

        public func Any(predicate: Func<T, bool>) -> bool
        {
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) return true;
            return false;
        }

        public func All(predicate: Func<T, bool>) -> bool
        {
            for (int i = 0; i < length; i++)
                if (!predicate(items[i])) return false;
            return true;
        }

        public func Count(predicate: Func<T, bool>) -> int
        {
            int n = 0;
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) n++;
            return n;
        }

        [TrackCaller] public func First() -> T
        {
            if (length == 0) throw new InvalidOperationException("First: el arreglo está vacío");
            return items[0];
        }

        [TrackCaller] public func First(predicate: Func<T, bool>) -> T
        {
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) return items[i];
            throw new InvalidOperationException("First: ningún elemento cumple la condición");
        }

        public func FirstOrDefault() -> T => length > 0 ? items[0] : default(T);

        public func FirstOrDefault(predicate: Func<T, bool>) -> T
        {
            for (int i = 0; i < length; i++)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        [TrackCaller] public func Last() -> T
        {
            if (length == 0) throw new InvalidOperationException("Last: el arreglo está vacío");
            return items[length - 1];
        }

        [TrackCaller] public func Last(predicate: Func<T, bool>) -> T
        {
            for (int i = length - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            throw new InvalidOperationException("Last: ningún elemento cumple la condición");
        }

        public func LastOrDefault() -> T => length > 0 ? items[length - 1] : default(T);

        public func LastOrDefault(predicate: Func<T, bool>) -> T
        {
            for (int i = length - 1; i >= 0; i--)
                if (predicate(items[i])) return items[i];
            return default(T);
        }

        public func Sum() -> T
        {
            T s = default(T);
            for (int i = 0; i < length; i++) s += items[i];
            return s;
        }

        public func Sum<U>(selector: Func<T, U>) -> U
        {
            U s = default(U);
            for (int i = 0; i < length; i++) s += selector(items[i]);
            return s;
        }

        [TrackCaller] public func Min() -> T
        {
            T m = First();
            for (int i = 1; i < length; i++)
                if (items[i] < m) m = items[i];
            return m;
        }

        [TrackCaller] public func Max() -> T
        {
            T m = First();
            for (int i = 1; i < length; i++)
                if (m < items[i]) m = items[i];
            return m;
        }

        [TrackCaller] public func Min<U>(selector: Func<T, U>) -> U => ToList().Min<U>(selector);
        [TrackCaller] public func Max<U>(selector: Func<T, U>) -> U => ToList().Max<U>(selector);
        [TrackCaller] public func MinBy<K>(key: Func<T, K>) -> T => ToList().MinBy<K>(key);
        [TrackCaller] public func MaxBy<K>(key: Func<T, K>) -> T => ToList().MaxBy<K>(key);
        [TrackCaller] public func Average() -> double => ToList().Average();
        [TrackCaller] public func Average<U>(selector: Func<T, U>) -> double => ToList().Average<U>(selector);
        public func OrderBy<K>(key: Func<T, K>) -> List<T> => ToList().OrderBy<K>(key);
        public func OrderByDescending<K>(key: Func<T, K>) -> List<T> => ToList().OrderByDescending<K>(key);
        public func Distinct() -> List<T> => ToList().Distinct();
        public func TakeWhile(predicate: Func<T, bool>) -> List<T> => ToList().TakeWhile(predicate);
        public func SkipWhile(predicate: Func<T, bool>) -> List<T> => ToList().SkipWhile(predicate);
        public func GroupBy<K>(key: Func<T, K>) -> List<Grouping<K, T>> => ToList().GroupBy<K>(key);
        public func ToDictionary<K>(key: Func<T, K>) -> Dictionary<K, T> => ToList().ToDictionary<K>(key);
        public func ToDictionary<K, V>(key: Func<T, K>, value: Func<T, V>) -> Dictionary<K, V> => ToList().ToDictionary<K, V>(key, value);
        [TrackCaller] public T Aggregate(Func<T, T, T> func) => ToList().Aggregate(func);
        public A Aggregate<A>(A seed, Func<A, T, A> func) => ToList().Aggregate<A>(seed, func);

        public func Take(n: int) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = 0; i < length && i < n; i++) r.Add(items[i]);
            return r;
        }

        public func Skip(n: int) -> List<T>
        {
            List<T> r = new List<T>();
            for (int i = n < 0 ? 0 : n; i < length; i++) r.Add(items[i]);
            return r;
        }

        public func Concat(other: T[]) -> List<T>
        {
            List<T> r = ToList();
            r.AddRange(other);
            return r;
        }

        public func Zip<U, R>(other: U[], f: Func<T, U, R>) -> List<R>
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
        var array: T[];
        var index: int;

        public init(source: T[])
        {
            array = source;
            index = -1;
        }

        public prop Current: T => array[index];

        public func MoveNext() -> bool
        {
            index++;
            return index < array.Length;
        }
    }

    // ---------------------------------------------------------------- T[,] y T[,,]
    //  Los elementos están seguidos por filas (el último índice cambia más rápido).
    public sealed class Array2D<T>
    {
        var data: T[];
        var n0: int;
        var n1: int;

        public init(length0: int, length1: int)
        {
            ArrayRuntime.CheckSize(length0);
            ArrayRuntime.CheckSize(length1);
            ArrayRuntime.CheckSize((long)length0 * length1);
            n0 = length0;
            n1 = length1;
            data = new T[length0 * length1];
        }

        public prop Length: int => data.Length;
        public prop Rank: int => 2;

        [TrackCaller] public func GetLength(dimension: int) -> int
        {
            if (dimension == 0) return n0;
            if (dimension == 1) return n1;
            throw new IndexOutOfRangeException("GetLength: la dimensión " + dimension + " no existe (el arreglo tiene 2)");
        }

        [TrackCaller] public func GetUpperBound(dimension: int) -> int => GetLength(dimension) - 1;
        [TrackCaller] public func GetLowerBound(dimension: int) -> int => GetLength(dimension) * 0;

        [TrackCaller] public T& operator[]((int, int) index)
        {
            int i = index.Item1;
            int j = index.Item2;
            if ((uint)i >= (uint)n0) ArrayRuntime.IndexError(i, n0);
            if ((uint)j >= (uint)n1) ArrayRuntime.IndexError(j, n1);
            return data[i * n1 + j];
        }

        public func GetEnumerator() -> ArrayEnumerator<T> => data.GetEnumerator();
        public func Fill(value: T) { data.Fill(value); }

        public func Clone() -> T[,]
        {
            T[,] r = new T[n0, n1];
            for (int i = 0; i < data.Length; i++) r.data[i] = data[i];
            return r;
        }

        // Los elementos en orden de filas, en un arreglo de una dimensión.
        public func ToArray() -> T[] => data.Clone();
    }

    public sealed class Array3D<T>
    {
        var data: T[];
        var n0: int;
        var n1: int;
        var n2: int;

        public init(length0: int, length1: int, length2: int)
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

        public prop Length: int => data.Length;
        public prop Rank: int => 3;

        [TrackCaller] public func GetLength(dimension: int) -> int
        {
            if (dimension == 0) return n0;
            if (dimension == 1) return n1;
            if (dimension == 2) return n2;
            throw new IndexOutOfRangeException("GetLength: la dimensión " + dimension + " no existe (el arreglo tiene 3)");
        }

        [TrackCaller] public func GetUpperBound(dimension: int) -> int => GetLength(dimension) - 1;
        [TrackCaller] public func GetLowerBound(dimension: int) -> int => GetLength(dimension) * 0;

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

        public func GetEnumerator() -> ArrayEnumerator<T> => data.GetEnumerator();
        public func Fill(value: T) { data.Fill(value); }
        public func ToArray() -> T[] => data.Clone();
    }

    // ---------------------------------------------------------------- Array (estática)
    public memory_unsafe static class Array
    {
        public static func Empty<T>() -> T[] => new T[0];

        // Ordena con 'operator<' (string compara por orden).
        public static func Sort<T>(array: T[]) { Algorithms.Sort<T>(array.Data, array.Length); }

        // Ordena con una comparación (negativo, cero o positivo). Estable.
        public static func Sort<T>(array: T[], comparison: Comparison<T>) { Algorithms.StableSort<T>(array.Data, array.Length, comparison); }

        [TrackCaller] public static func Sort<T>(array: T[], index: int, length: int)
        {
            CheckSegment(array.Length, index, length);
            Algorithms.Sort<T>(array.Data + index, length);
        }

        public static func Reverse<T>(array: T[]) { Algorithms.Reverse<T>(array.Data, array.Length); }

        [TrackCaller] public static func Reverse<T>(array: T[], index: int, length: int)
        {
            CheckSegment(array.Length, index, length);
            Algorithms.Reverse<T>(array.Data + index, length);
        }

        public static func IndexOf<T>(array: T[], value: T) -> int => array.IndexOf(value);

        [TrackCaller] public static func IndexOf<T>(array: T[], value: T, startIndex: int) -> int
        {
            CheckSegment(array.Length, startIndex, array.Length - startIndex);
            for (int i = startIndex; i < array.Length; i++)
                if (array[i] == value) return i;
            return -1;
        }

        public static func LastIndexOf<T>(array: T[], value: T) -> int
        {
            for (int i = array.Length - 1; i >= 0; i--)
                if (array[i] == value) return i;
            return -1;
        }

        public static func Fill<T>(array: T[], value: T) { array.Fill(value); }

        [TrackCaller] public static func Fill<T>(array: T[], value: T, startIndex: int, count: int)
        {
            CheckSegment(array.Length, startIndex, count);
            for (int i = 0; i < count; i++) array[startIndex + i] = value;
        }

        // Copia 'length' elementos del principio de 'source' al principio de 'destination'.
        [TrackCaller] public static func Copy<T>(source: T[], destination: T[], length: int) { Copy<T>(source, 0, destination, 0, length); }

        // Admite que origen y destino sean el mismo arreglo y se solapen.
        [TrackCaller] public static func Copy<T>(source: T[], sourceIndex: int, destination: T[], destinationIndex: int, length: int)
        {
            CheckSegment(source.Length, sourceIndex, length);
            CheckSegment(destination.Length, destinationIndex, length);
            Memory.CopyItems<T>(destination.Data + destinationIndex, source.Data + sourceIndex, length);
        }

        // Cambia el tamaño: crea un arreglo nuevo con los elementos que caben (Array.Resize(ref a, n)).
        [TrackCaller] public static func Resize<T>(array: T[]&, newSize: int)
        {
            T[] r = new T[newSize];
            if (array != null) Copy<T>(array, r, array.Length < newSize ? array.Length : newSize);
            array = r;
        }

        // Búsqueda binaria en un arreglo ordenado: el índice, o el complemento (~) del lugar donde
        // iría si no está (un número negativo).
        public static func BinarySearch<T>(array: T[], value: T) -> int
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
        public static func Clear<T>(array: T[]) { array.Fill(default(T)); }

        [TrackCaller] public static func Clear<T>(array: T[], index: int, length: int) { Fill<T>(array, default(T), index, length); }

        public static func Exists<T>(array: T[], match: Predicate<T>) -> bool => FindIndex<T>(array, match) >= 0;
        public static func TrueForAll<T>(array: T[], match: Predicate<T>) -> bool
        {
            for (int i = 0; i < array.Length; i++)
                if (!match(array[i])) return false;
            return true;
        }

        public static func Find<T>(array: T[], match: Predicate<T>) -> T
        {
            for (int i = 0; i < array.Length; i++)
                if (match(array[i])) return array[i];
            return default(T);
        }

        public static func FindLast<T>(array: T[], match: Predicate<T>) -> T
        {
            for (int i = array.Length - 1; i >= 0; i--)
                if (match(array[i])) return array[i];
            return default(T);
        }

        public static func FindIndex<T>(array: T[], match: Predicate<T>) -> int
        {
            for (int i = 0; i < array.Length; i++)
                if (match(array[i])) return i;
            return -1;
        }

        public static func FindLastIndex<T>(array: T[], match: Predicate<T>) -> int
        {
            for (int i = array.Length - 1; i >= 0; i--)
                if (match(array[i])) return i;
            return -1;
        }

        public static func FindAll<T>(array: T[], match: Predicate<T>) -> T[]
        {
            List<T> r = new List<T>();
            for (int i = 0; i < array.Length; i++)
                if (match(array[i])) r.Add(array[i]);
            return r.ToArray();
        }

        public static func ConvertAll<T, U>(array: T[], converter: Func<T, U>) -> U[]
        {
            U[] r = new U[array.Length];
            for (int i = 0; i < array.Length; i++) r[i] = converter(array[i]);
            return r;
        }

        public static func ForEach<T>(array: T[], action: Action<T>)
        {
            for (int i = 0; i < array.Length; i++) action(array[i]);
        }

        [TrackCaller] static func CheckSegment(total: int, index: int, length: int)
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
        var array: T[];      // origen: un arreglo...
        var list: List<T>;   // ...o una lista (se indexa a través de ella: puede crecer o encoger)
        var start: int;
        var length: int;

        public init(array: T[])
        {
            this.array = array;
            length = array == null ? 0 : array.Length;
        }

        public init(array: T[], start: int, length: int)
        {
            int total = array == null ? 0 : array.Length;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "Span: el tramo se sale del arreglo");
            this.array = array;
            this.start = start;
            this.length = length;
        }

        public init(list: List<T>)
        {
            this.list = list;
            length = list == null ? 0 : list.Count;
        }

        public init(list: List<T>, start: int, length: int)
        {
            int total = list == null ? 0 : list.Count;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "Span: el tramo se sale de la lista");
            this.list = list;
            this.start = start;
            this.length = length;
        }

        public static prop Empty: Span<T> => default(Span<T>);
        public prop Length: int => length;
        public prop IsEmpty: bool => length == 0;

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

        [TrackCaller] public func Slice(start: int) -> Span<T> => Slice(start, length - start);

        [TrackCaller] public func Slice(start: int, length: int) -> Span<T>
        {
            if (start < 0 || length < 0 || start > this.length || length > this.length - start)
                throw new ArgumentOutOfRangeException("start", "Span.Slice: el tramo se sale de la vista");
            Span<T> r = this;
            r.start = this.start + start;
            r.length = length;
            return r;
        }

        public func AsReadOnly() -> ReadOnlySpan<T> => array != null ? new ReadOnlySpan<T>(array, start, length) : new ReadOnlySpan<T>(list, start, length);

        public func Fill(value: T)
        {
            for (int i = 0; i < length; i++) this[i] = value;
        }

        public func Clear() { Fill(default(T)); }

        [TrackCaller] public func CopyTo(destination: Span<T>)
        {
            if (destination.Length < length) throw new ArgumentException("Span.CopyTo: el destino es demasiado pequeño");
            if (array != null && destination.array == array && destination.start > start)
                for (int i = length - 1; i >= 0; i--) destination[i] = this[i];  // solapados: de atrás adelante
            else
                for (int i = 0; i < length; i++) destination[i] = this[i];
        }

        public func ToArray() -> T[]
        {
            T[] r = new T[length];
            for (int i = 0; i < length; i++) r[i] = this[i];
            return r;
        }

        public func ToList() -> List<T>
        {
            List<T> r = new List<T>(length);
            for (int i = 0; i < length; i++) r.Add(this[i]);
            return r;
        }

        public func IndexOf(item: T) -> int
        {
            for (int i = 0; i < length; i++)
                if (this[i] == item) return i;
            return -1;
        }

        public func Contains(item: T) -> bool => IndexOf(item) >= 0;

        public func Reverse()
        {
            for (int i = 0, j = length - 1; i < j; i++, j--)
            {
                T t = this[i];
                this[i] = this[j];
                this[j] = t;
            }
        }

        // Ordena el tramo en su sitio con 'operator<'.
        public func Sort()
        {
            if (length == 0) return;
            if (array != null) Algorithms.Sort<T>(array.Data + start, length);
            else Algorithms.Sort<T>(list.Data + start, length);
        }

        public func GetEnumerator() -> SpanItems<T> => new SpanItems<T>(array, list, start, length);
    }

    public memory_unsafe struct ReadOnlySpan<T>
    {
        var array: T[];
        var list: List<T>;
        var start: int;
        var length: int;

        public init(array: T[])
        {
            this.array = array;
            length = array == null ? 0 : array.Length;
        }

        public init(array: T[], start: int, length: int)
        {
            int total = array == null ? 0 : array.Length;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "ReadOnlySpan: el tramo se sale del arreglo");
            this.array = array;
            this.start = start;
            this.length = length;
        }

        public init(list: List<T>)
        {
            this.list = list;
            length = list == null ? 0 : list.Count;
        }

        public init(list: List<T>, start: int, length: int)
        {
            int total = list == null ? 0 : list.Count;
            if (start < 0 || length < 0 || start > total || length > total - start)
                throw new ArgumentOutOfRangeException("start", "ReadOnlySpan: el tramo se sale de la lista");
            this.list = list;
            this.start = start;
            this.length = length;
        }

        public static prop Empty: ReadOnlySpan<T> => default(ReadOnlySpan<T>);
        public prop Length: int => length;
        public prop IsEmpty: bool => length == 0;

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

        [TrackCaller] public func Slice(start: int) -> ReadOnlySpan<T> => Slice(start, length - start);

        [TrackCaller] public func Slice(start: int, length: int) -> ReadOnlySpan<T>
        {
            if (start < 0 || length < 0 || start > this.length || length > this.length - start)
                throw new ArgumentOutOfRangeException("start", "ReadOnlySpan.Slice: el tramo se sale de la vista");
            ReadOnlySpan<T> r = this;
            r.start = this.start + start;
            r.length = length;
            return r;
        }

        [TrackCaller] public func CopyTo(destination: Span<T>)
        {
            if (destination.Length < length) throw new ArgumentException("ReadOnlySpan.CopyTo: el destino es demasiado pequeño");
            T[] tmp = ToArray();  // el destino puede solaparse con esta vista
            for (int i = 0; i < length; i++) destination[i] = tmp[i];
        }

        public func ToArray() -> T[]
        {
            T[] r = new T[length];
            for (int i = 0; i < length; i++) r[i] = this[i];
            return r;
        }

        public func ToList() -> List<T>
        {
            List<T> r = new List<T>(length);
            for (int i = 0; i < length; i++) r.Add(this[i]);
            return r;
        }

        public func IndexOf(item: T) -> int
        {
            for (int i = 0; i < length; i++)
                if (this[i] == item) return i;
            return -1;
        }

        public func Contains(item: T) -> bool => IndexOf(item) >= 0;

        public func GetEnumerator() -> SpanItems<T> => new SpanItems<T>(array, list, start, length);
    }

    // Enumerador de Span<T> y ReadOnlySpan<T> para foreach.
    public struct SpanItems<T>
    {
        var array: T[];
        var list: List<T>;
        var start: int;
        var length: int;
        var index: int;

        public init(array: T[], list: List<T>, start: int, length: int)
        {
            this.array = array;
            this.list = list;
            this.start = start;
            this.length = length;
            index = -1;
        }

        [TrackCaller] public prop Current: T => array != null ? array[start + index] : list[start + index];

        public func MoveNext() -> bool
        {
            index++;
            return index < length;
        }
    }

    // ---------------------------------------------------------------- IEnumerable<T> -> T[]
    public static class ArrayLinq
    {
        // Recorre la secuencia (perezosa o no) y guarda sus elementos en un arreglo nuevo.
        public static func ToArray<T>(this source: IEnumerable<T>) -> T[] => source.ToList().ToArray();
    }

    // ---------------------------------------------------------------- rangos sobre cadenas
    public static class RangeExtensions
    {
        // s[1..3]: la subcadena del rango (en bytes UTF-8, como s[i] y s.Length).
        [TrackCaller] public static func Slice(this s: string, range: Range) -> string
        {
            var (start, n) = range.GetOffsetAndLength(s.Length);
            return s.Substring(start, n);
        }

        // s[^1]: el byte en esa posición.
        [TrackCaller] public static func At(this s: string, index: Index) -> byte => s[index.GetOffset(s.Length)];
    }
}
