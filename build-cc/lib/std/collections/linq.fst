// =============================================================================
//  std.collections (LINQ perezoso)  —  operadores sobre cualquier IEnumerable<T>.
//
//    Enumerable.Range(1, 10), Enumerable.Repeat(x, n), Enumerable.Empty<T>()
//    Where, Select, SelectMany, Take, Skip, TakeWhile, SkipWhile, Concat, Zip, Distinct,
//    Append, Prepend, Chunk, OrderBy / ThenBy (ordena al empezar a recorrer), GroupBy
//    Aggregate, Any, All, Contains, Count, First, Last, ElementAt, Sum, Min, Max, Average,
//    ToList, ToDictionary, ToHashSet, ForEach
//
//  Como en C#, los operadores que devuelven IEnumerable<T> son PEREZOSOS: no recorren nada hasta
//  que alguien pide elementos (foreach, ToList, Count...), y cada recorrido vuelve a evaluar la
//  cadena entera. Los que devuelven un valor (Count, Sum, First, ToList...) recorren en el acto.
//
//  List<T> tiene además sus propias versiones INMEDIATAS (lista.Where(...) devuelve una List<T>
//  nueva al momento); una List<T> usada como IEnumerable<T> recibe las perezosas:
//      List<int> a = lista.Where(x => x > 2);                       // inmediata (List<T>)
//      IEnumerable<int> b = ((IEnumerable<int>)lista).Where(...);   // perezosa
//      IEnumerable<int> c = lista.AsEnumerable().Where(...);         // perezosa
// =============================================================================
namespace std.collections
{
    public static class Enumerable
    {
        // ------------------------------------------------------------ generadores
        // start, start + 1, ..., start + count - 1
        public static func Range(start: int, count: int) -> IEnumerable<int>
        {
            if (count < 0) throw new ArgumentOutOfRangeException("Enumerable.Range: 'count' es negativo", null);
            for (int i = 0; i < count; i++) yield return start + i;
        }

        public static func Repeat<T>(value: T, count: int) -> IEnumerable<T>
        {
            if (count < 0) throw new ArgumentOutOfRangeException("Enumerable.Repeat: 'count' es negativo", null);
            for (int i = 0; i < count; i++) yield return value;
        }

        public static func Empty<T>() -> IEnumerable<T>
        {
            yield break;
        }

        // Los caracteres de un texto (string como IEnumerable<char>).
        public static func Caracteres(s: string) -> IEnumerable<char>
        {
            foreach (char c in s) yield return c;
        }

        // La colección vista como IEnumerable<T>: sus operadores LINQ serán los perezosos.
        public static func AsEnumerable<T>(this source: IEnumerable<T>) -> IEnumerable<T> => source;

        // ------------------------------------------------------------ filtros y proyecciones
        public static func Where<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> IEnumerable<T>
        {
            foreach (T x in source)
                if (predicate(x)) yield return x;
        }

        public static func Where<T>(this source: IEnumerable<T>, predicate: Func<T, int, bool>) -> IEnumerable<T>
        {
            int i = 0;
            foreach (T x in source)
            {
                if (predicate(x, i)) yield return x;
                i++;
            }
        }

        public static func Select<T, U>(this source: IEnumerable<T>, selector: Func<T, U>) -> IEnumerable<U>
        {
            foreach (T x in source) yield return selector(x);
        }

        public static func Select<T, U>(this source: IEnumerable<T>, selector: Func<T, int, U>) -> IEnumerable<U>
        {
            int i = 0;
            foreach (T x in source)
            {
                yield return selector(x, i);
                i++;
            }
        }

        public static func SelectMany<T, U>(this source: IEnumerable<T>, selector: Func<T, IEnumerable<U>>) -> IEnumerable<U>
        {
            foreach (T x in source)
                foreach (U y in selector(x)) yield return y;
        }

        public static func Take<T>(this source: IEnumerable<T>, count: int) -> IEnumerable<T>
        {
            if (count <= 0) yield break;
            int n = 0;
            foreach (T x in source)
            {
                yield return x;
                n++;
                if (n >= count) yield break;
            }
        }

        public static func Skip<T>(this source: IEnumerable<T>, count: int) -> IEnumerable<T>
        {
            int n = 0;
            foreach (T x in source)
            {
                if (n >= count) yield return x;
                else n++;
            }
        }

        public static func TakeWhile<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> IEnumerable<T>
        {
            foreach (T x in source)
            {
                if (!predicate(x)) yield break;
                yield return x;
            }
        }

        public static func SkipWhile<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> IEnumerable<T>
        {
            bool skipping = true;
            foreach (T x in source)
            {
                if (skipping && predicate(x)) continue;
                skipping = false;
                yield return x;
            }
        }

        public static func Concat<T>(this first: IEnumerable<T>, second: IEnumerable<T>) -> IEnumerable<T>
        {
            foreach (T x in first) yield return x;
            foreach (T x in second) yield return x;
        }

        public static func Append<T>(this source: IEnumerable<T>, element: T) -> IEnumerable<T>
        {
            foreach (T x in source) yield return x;
            yield return element;
        }

        public static func Prepend<T>(this source: IEnumerable<T>, element: T) -> IEnumerable<T>
        {
            yield return element;
            foreach (T x in source) yield return x;
        }

        // Combina elemento a elemento hasta que se acaba la secuencia más corta.
        public static func Zip<T, U, R>(this first: IEnumerable<T>, second: IEnumerable<U>, selector: Func<T, U, R>) -> IEnumerable<R>
        {
            IEnumerator<U> e = second.GetEnumerator();
            try
            {
                foreach (T x in first)
                {
                    if (!e.MoveNext()) yield break;
                    yield return selector(x, e.Current);
                }
            }
            finally
            {
                e.Dispose();
            }
        }

        public static func Zip<T, U>(this first: IEnumerable<T>, second: IEnumerable<U>) -> IEnumerable<(T, U)>
        {
            IEnumerator<U> e = second.GetEnumerator();
            try
            {
                foreach (T x in first)
                {
                    if (!e.MoveNext()) yield break;
                    yield return (x, e.Current);
                }
            }
            finally
            {
                e.Dispose();
            }
        }

        // Sin repetidos, en el orden de la primera aparición (T necesita Hash.Of y '==').
        public static func Distinct<T>(this source: IEnumerable<T>) -> IEnumerable<T>
        {
            Dictionary<T, bool> seen = new Dictionary<T, bool>();
            foreach (T x in source)
                if (seen.Add(x, true)) yield return x;
        }

        public static func DistinctBy<T, K>(this source: IEnumerable<T>, key: Func<T, K>) -> IEnumerable<T>
        {
            Dictionary<K, bool> seen = new Dictionary<K, bool>();
            foreach (T x in source)
                if (seen.Add(key(x), true)) yield return x;
        }

        // Trozos de 'size' elementos (el último puede ser más corto).
        public static func Chunk<T>(this source: IEnumerable<T>, size: int) -> IEnumerable<List<T>>
        {
            if (size <= 0) throw new ArgumentOutOfRangeException("Chunk: el tamaño debe ser positivo", null);
            List<T> chunk = new List<T>(size);
            foreach (T x in source)
            {
                chunk.Add(x);
                if (chunk.Count == size)
                {
                    yield return chunk;
                    chunk = new List<T>(size);
                }
            }
            if (chunk.Count > 0) yield return chunk;
        }

        public static func Reverse<T>(this source: IEnumerable<T>) -> IEnumerable<T>
        {
            List<T> all = ToList<T>(source);
            for (int i = all.Count - 1; i >= 0; i--) yield return all[i];
        }

        // ------------------------------------------------------------ ordenación y grupos
        // Estable; la clave necesita 'operator<'. Se ordena al empezar cada recorrido.
        public static func OrderBy<T, K>(this source: IEnumerable<T>, key: Func<T, K>) -> OrderedEnumerable<T>
        {
            return new OrderedEnumerable<T>(source, (a, b) => Algorithms.CompareKeys<K>(key(a), key(b)));
        }

        public static func OrderByDescending<T, K>(this source: IEnumerable<T>, key: Func<T, K>) -> OrderedEnumerable<T>
        {
            return new OrderedEnumerable<T>(source, (a, b) => Algorithms.CompareKeys<K>(key(b), key(a)));
        }

        // Grupos por clave, en el orden de la primera aparición de cada clave.
        public static func GroupBy<T, K>(this source: IEnumerable<T>, key: Func<T, K>) -> IEnumerable<Grouping<K, T>>
        {
            List<Grouping<K, T>> groups = new List<Grouping<K, T>>();
            Dictionary<K, int> index = new Dictionary<K, int>();
            foreach (T x in source)
            {
                K k = key(x);
                int at = 0;
                if (!index.TryGetValue(k, out at))
                {
                    at = groups.Count;
                    index.Set(k, at);
                    groups.Add(new Grouping<K, T>(k));
                }
                groups[at].Items.Add(x);
            }
            foreach (Grouping<K, T> g in groups) yield return g;
        }

        // ------------------------------------------------------------ resultados (recorren en el acto)
        public static func ToList<T>(this source: IEnumerable<T>) -> List<T>
        {
            List<T> r = new List<T>();
            foreach (T x in source) r.Add(x);
            return r;
        }

        public static func ToHashSet<T>(this source: IEnumerable<T>) -> HashSet<T>
        {
            HashSet<T> r = new HashSet<T>();
            foreach (T x in source) r.Add(x);
            return r;
        }

        // Clave -> elemento (si una clave se repite, gana el último).
        public static func ToDictionary<T, K>(this source: IEnumerable<T>, key: Func<T, K>) -> Dictionary<K, T>
        {
            Dictionary<K, T> d = new Dictionary<K, T>();
            foreach (T x in source) d.Set(key(x), x);
            return d;
        }

        public static func ToDictionary<T, K, V>(this source: IEnumerable<T>, key: Func<T, K>, value: Func<T, V>) -> Dictionary<K, V>
        {
            Dictionary<K, V> d = new Dictionary<K, V>();
            foreach (T x in source) d.Set(key(x), value(x));
            return d;
        }

        public static func ForEach<T>(this source: IEnumerable<T>, action: Action<T>)
        {
            foreach (T x in source) action(x);
        }

        [TrackCaller] public static T Aggregate<T>(this IEnumerable<T> source, Func<T, T, T> func)
        {
            IEnumerator<T> e = source.GetEnumerator();
            try
            {
                if (!e.MoveNext()) throw new InvalidOperationException("Aggregate: la secuencia está vacía");
                T acc = e.Current;
                while (e.MoveNext()) acc = func(acc, e.Current);
                return acc;
            }
            finally
            {
                e.Dispose();
            }
        }

        public static A Aggregate<T, A>(this IEnumerable<T> source, A seed, Func<A, T, A> func)
        {
            A acc = seed;
            foreach (T x in source) acc = func(acc, x);
            return acc;
        }

        public static func Any<T>(this source: IEnumerable<T>) -> bool
        {
            foreach (T x in source) return true;
            return false;
        }

        public static func Any<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> bool
        {
            foreach (T x in source)
                if (predicate(x)) return true;
            return false;
        }

        public static func All<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> bool
        {
            foreach (T x in source)
                if (!predicate(x)) return false;
            return true;
        }

        public static func Contains<T>(this source: IEnumerable<T>, value: T) -> bool
        {
            foreach (T x in source)
                if (x == value) return true;
            return false;
        }

        public static func Count<T>(this source: IEnumerable<T>) -> int
        {
            int n = 0;
            foreach (T x in source) n++;
            return n;
        }

        public static func Count<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> int
        {
            int n = 0;
            foreach (T x in source)
                if (predicate(x)) n++;
            return n;
        }

        [TrackCaller] public static func First<T>(this source: IEnumerable<T>) -> T
        {
            foreach (T x in source) return x;
            throw new InvalidOperationException("First: la secuencia está vacía");
        }

        [TrackCaller] public static func First<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> T
        {
            foreach (T x in source)
                if (predicate(x)) return x;
            throw new InvalidOperationException("First: ningún elemento cumple la condición");
        }

        public static func FirstOrDefault<T>(this source: IEnumerable<T>) -> T
        {
            foreach (T x in source) return x;
            return default(T);
        }

        public static func FirstOrDefault<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> T
        {
            foreach (T x in source)
                if (predicate(x)) return x;
            return default(T);
        }

        [TrackCaller] public static func Last<T>(this source: IEnumerable<T>) -> T
        {
            bool found = false;
            T last = default(T);
            foreach (T x in source)
            {
                last = x;
                found = true;
            }
            if (!found) throw new InvalidOperationException("Last: la secuencia está vacía");
            return last;
        }

        [TrackCaller] public static func Last<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> T
        {
            bool found = false;
            T last = default(T);
            foreach (T x in source)
                if (predicate(x))
                {
                    last = x;
                    found = true;
                }
            if (!found) throw new InvalidOperationException("Last: ningún elemento cumple la condición");
            return last;
        }

        public static func LastOrDefault<T>(this source: IEnumerable<T>) -> T
        {
            T last = default(T);
            foreach (T x in source) last = x;
            return last;
        }

        public static func LastOrDefault<T>(this source: IEnumerable<T>, predicate: Func<T, bool>) -> T
        {
            T last = default(T);
            foreach (T x in source)
                if (predicate(x)) last = x;
            return last;
        }

        [TrackCaller] public static func ElementAt<T>(this source: IEnumerable<T>, index: int) -> T
        {
            int i = 0;
            foreach (T x in source)
            {
                if (i == index) return x;
                i++;
            }
            throw new ArgumentOutOfRangeException("ElementAt: índice fuera de rango", null);
        }

        public static func Sum<T>(this source: IEnumerable<T>) -> T
        {
            T s = default(T);
            foreach (T x in source) s += x;
            return s;
        }

        public static func Sum<T, U>(this source: IEnumerable<T>, selector: Func<T, U>) -> U
        {
            U s = default(U);
            foreach (T x in source) s += selector(x);
            return s;
        }

        [TrackCaller] public static func Min<T>(this source: IEnumerable<T>) -> T
        {
            bool any = false;
            T m = default(T);
            foreach (T x in source)
            {
                if (!any || x < m) m = x;
                any = true;
            }
            if (!any) throw new InvalidOperationException("Min: la secuencia está vacía");
            return m;
        }

        [TrackCaller] public static func Min<T, U>(this source: IEnumerable<T>, selector: Func<T, U>) -> U
        {
            bool any = false;
            U m = default(U);
            foreach (T x in source)
            {
                U v = selector(x);
                if (!any || v < m) m = v;
                any = true;
            }
            if (!any) throw new InvalidOperationException("Min: la secuencia está vacía");
            return m;
        }

        [TrackCaller] public static func Max<T>(this source: IEnumerable<T>) -> T
        {
            bool any = false;
            T m = default(T);
            foreach (T x in source)
            {
                if (!any || m < x) m = x;
                any = true;
            }
            if (!any) throw new InvalidOperationException("Max: la secuencia está vacía");
            return m;
        }

        [TrackCaller] public static func Max<T, U>(this source: IEnumerable<T>, selector: Func<T, U>) -> U
        {
            bool any = false;
            U m = default(U);
            foreach (T x in source)
            {
                U v = selector(x);
                if (!any || m < v) m = v;
                any = true;
            }
            if (!any) throw new InvalidOperationException("Max: la secuencia está vacía");
            return m;
        }

        [TrackCaller] public static func Average<T>(this source: IEnumerable<T>) -> double
        {
            T s = default(T);
            int n = 0;
            foreach (T x in source)
            {
                s += x;
                n++;
            }
            if (n == 0) throw new InvalidOperationException("Average: la secuencia está vacía");
            return (double)s / n;
        }

        [TrackCaller] public static func Average<T, U>(this source: IEnumerable<T>, selector: Func<T, U>) -> double
        {
            U s = default(U);
            int n = 0;
            foreach (T x in source)
            {
                s += selector(x);
                n++;
            }
            if (n == 0) throw new InvalidOperationException("Average: la secuencia está vacía");
            return (double)s / n;
        }
    }

    // Resultado de OrderBy / OrderByDescending: admite ThenBy / ThenByDescending. Es perezoso: copia
    // y ordena los elementos al empezar cada recorrido.
    public class OrderedEnumerable<T> : IEnumerable<T>
    {
        var source: IEnumerable<T>;
        var compare: Func<T, T, int>;

        public init(source: IEnumerable<T>, compare: Func<T, T, int>)
        {
            this.source = source;
            this.compare = compare;
        }

        public func ThenBy<K>(key: Func<T, K>) -> OrderedEnumerable<T>
        {
            Func<T, T, int> previo = compare;
            return new OrderedEnumerable<T>(source, (a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(a), key(b));
            });
        }

        public func ThenByDescending<K>(key: Func<T, K>) -> OrderedEnumerable<T>
        {
            Func<T, T, int> previo = compare;
            return new OrderedEnumerable<T>(source, (a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(b), key(a));
            });
        }

        public func GetEnumerator() -> IEnumerator<T> => Sorted().GetEnumerator();

        func Sorted() -> IEnumerable<T>
        {
            List<T> all = new List<T>();
            foreach (T x in source) all.Add(x);
            all.Sort(compare);
            foreach (T x in all) yield return x;
        }
    }
}
