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
        public static IEnumerable<int> Range(int start, int count)
        {
            if (count < 0) throw new ArgumentOutOfRangeException("Enumerable.Range: 'count' es negativo", null);
            for (int i = 0; i < count; i++) yield return start + i;
        }

        public static IEnumerable<T> Repeat<T>(T value, int count)
        {
            if (count < 0) throw new ArgumentOutOfRangeException("Enumerable.Repeat: 'count' es negativo", null);
            for (int i = 0; i < count; i++) yield return value;
        }

        public static IEnumerable<T> Empty<T>()
        {
            yield break;
        }

        // Los caracteres de un texto (string como IEnumerable<char>).
        public static IEnumerable<char> Caracteres(string s)
        {
            foreach (char c in s) yield return c;
        }

        // La colección vista como IEnumerable<T>: sus operadores LINQ serán los perezosos.
        public static IEnumerable<T> AsEnumerable<T>(this IEnumerable<T> source) => source;

        // ------------------------------------------------------------ filtros y proyecciones
        public static IEnumerable<T> Where<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            foreach (T x in source)
                if (predicate(x)) yield return x;
        }

        public static IEnumerable<T> Where<T>(this IEnumerable<T> source, Func<T, int, bool> predicate)
        {
            int i = 0;
            foreach (T x in source)
            {
                if (predicate(x, i)) yield return x;
                i++;
            }
        }

        public static IEnumerable<U> Select<T, U>(this IEnumerable<T> source, Func<T, U> selector)
        {
            foreach (T x in source) yield return selector(x);
        }

        public static IEnumerable<U> Select<T, U>(this IEnumerable<T> source, Func<T, int, U> selector)
        {
            int i = 0;
            foreach (T x in source)
            {
                yield return selector(x, i);
                i++;
            }
        }

        public static IEnumerable<U> SelectMany<T, U>(this IEnumerable<T> source, Func<T, IEnumerable<U>> selector)
        {
            foreach (T x in source)
                foreach (U y in selector(x)) yield return y;
        }

        public static IEnumerable<T> Take<T>(this IEnumerable<T> source, int count)
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

        public static IEnumerable<T> Skip<T>(this IEnumerable<T> source, int count)
        {
            int n = 0;
            foreach (T x in source)
            {
                if (n >= count) yield return x;
                else n++;
            }
        }

        public static IEnumerable<T> TakeWhile<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            foreach (T x in source)
            {
                if (!predicate(x)) yield break;
                yield return x;
            }
        }

        public static IEnumerable<T> SkipWhile<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            bool skipping = true;
            foreach (T x in source)
            {
                if (skipping && predicate(x)) continue;
                skipping = false;
                yield return x;
            }
        }

        public static IEnumerable<T> Concat<T>(this IEnumerable<T> first, IEnumerable<T> second)
        {
            foreach (T x in first) yield return x;
            foreach (T x in second) yield return x;
        }

        public static IEnumerable<T> Append<T>(this IEnumerable<T> source, T element)
        {
            foreach (T x in source) yield return x;
            yield return element;
        }

        public static IEnumerable<T> Prepend<T>(this IEnumerable<T> source, T element)
        {
            yield return element;
            foreach (T x in source) yield return x;
        }

        // Combina elemento a elemento hasta que se acaba la secuencia más corta.
        public static IEnumerable<R> Zip<T, U, R>(this IEnumerable<T> first, IEnumerable<U> second, Func<T, U, R> selector)
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

        public static IEnumerable<(T, U)> Zip<T, U>(this IEnumerable<T> first, IEnumerable<U> second)
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
        public static IEnumerable<T> Distinct<T>(this IEnumerable<T> source)
        {
            Dictionary<T, bool> seen = new Dictionary<T, bool>();
            foreach (T x in source)
                if (seen.Add(x, true)) yield return x;
        }

        public static IEnumerable<T> DistinctBy<T, K>(this IEnumerable<T> source, Func<T, K> key)
        {
            Dictionary<K, bool> seen = new Dictionary<K, bool>();
            foreach (T x in source)
                if (seen.Add(key(x), true)) yield return x;
        }

        // Trozos de 'size' elementos (el último puede ser más corto).
        public static IEnumerable<List<T>> Chunk<T>(this IEnumerable<T> source, int size)
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

        public static IEnumerable<T> Reverse<T>(this IEnumerable<T> source)
        {
            List<T> all = ToList<T>(source);
            for (int i = all.Count - 1; i >= 0; i--) yield return all[i];
        }

        // ------------------------------------------------------------ ordenación y grupos
        // Estable; la clave necesita 'operator<'. Se ordena al empezar cada recorrido.
        public static OrderedEnumerable<T> OrderBy<T, K>(this IEnumerable<T> source, Func<T, K> key)
        {
            return new OrderedEnumerable<T>(source, (a, b) => Algorithms.CompareKeys<K>(key(a), key(b)));
        }

        public static OrderedEnumerable<T> OrderByDescending<T, K>(this IEnumerable<T> source, Func<T, K> key)
        {
            return new OrderedEnumerable<T>(source, (a, b) => Algorithms.CompareKeys<K>(key(b), key(a)));
        }

        // Grupos por clave, en el orden de la primera aparición de cada clave.
        public static IEnumerable<Grouping<K, T>> GroupBy<T, K>(this IEnumerable<T> source, Func<T, K> key)
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
        public static List<T> ToList<T>(this IEnumerable<T> source)
        {
            List<T> r = new List<T>();
            foreach (T x in source) r.Add(x);
            return r;
        }

        public static HashSet<T> ToHashSet<T>(this IEnumerable<T> source)
        {
            HashSet<T> r = new HashSet<T>();
            foreach (T x in source) r.Add(x);
            return r;
        }

        // Clave -> elemento (si una clave se repite, gana el último).
        public static Dictionary<K, T> ToDictionary<T, K>(this IEnumerable<T> source, Func<T, K> key)
        {
            Dictionary<K, T> d = new Dictionary<K, T>();
            foreach (T x in source) d.Set(key(x), x);
            return d;
        }

        public static Dictionary<K, V> ToDictionary<T, K, V>(this IEnumerable<T> source, Func<T, K> key, Func<T, V> value)
        {
            Dictionary<K, V> d = new Dictionary<K, V>();
            foreach (T x in source) d.Set(key(x), value(x));
            return d;
        }

        public static void ForEach<T>(this IEnumerable<T> source, Action<T> action)
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

        public static bool Any<T>(this IEnumerable<T> source)
        {
            foreach (T x in source) return true;
            return false;
        }

        public static bool Any<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            foreach (T x in source)
                if (predicate(x)) return true;
            return false;
        }

        public static bool All<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            foreach (T x in source)
                if (!predicate(x)) return false;
            return true;
        }

        public static bool Contains<T>(this IEnumerable<T> source, T value)
        {
            foreach (T x in source)
                if (x == value) return true;
            return false;
        }

        public static int Count<T>(this IEnumerable<T> source)
        {
            int n = 0;
            foreach (T x in source) n++;
            return n;
        }

        public static int Count<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            int n = 0;
            foreach (T x in source)
                if (predicate(x)) n++;
            return n;
        }

        [TrackCaller] public static T First<T>(this IEnumerable<T> source)
        {
            foreach (T x in source) return x;
            throw new InvalidOperationException("First: la secuencia está vacía");
        }

        [TrackCaller] public static T First<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            foreach (T x in source)
                if (predicate(x)) return x;
            throw new InvalidOperationException("First: ningún elemento cumple la condición");
        }

        public static T FirstOrDefault<T>(this IEnumerable<T> source)
        {
            foreach (T x in source) return x;
            return default(T);
        }

        public static T FirstOrDefault<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            foreach (T x in source)
                if (predicate(x)) return x;
            return default(T);
        }

        [TrackCaller] public static T Last<T>(this IEnumerable<T> source)
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

        [TrackCaller] public static T Last<T>(this IEnumerable<T> source, Func<T, bool> predicate)
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

        public static T LastOrDefault<T>(this IEnumerable<T> source)
        {
            T last = default(T);
            foreach (T x in source) last = x;
            return last;
        }

        public static T LastOrDefault<T>(this IEnumerable<T> source, Func<T, bool> predicate)
        {
            T last = default(T);
            foreach (T x in source)
                if (predicate(x)) last = x;
            return last;
        }

        [TrackCaller] public static T ElementAt<T>(this IEnumerable<T> source, int index)
        {
            int i = 0;
            foreach (T x in source)
            {
                if (i == index) return x;
                i++;
            }
            throw new ArgumentOutOfRangeException("ElementAt: índice fuera de rango", null);
        }

        public static T Sum<T>(this IEnumerable<T> source)
        {
            T s = default(T);
            foreach (T x in source) s += x;
            return s;
        }

        public static U Sum<T, U>(this IEnumerable<T> source, Func<T, U> selector)
        {
            U s = default(U);
            foreach (T x in source) s += selector(x);
            return s;
        }

        [TrackCaller] public static T Min<T>(this IEnumerable<T> source)
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

        [TrackCaller] public static U Min<T, U>(this IEnumerable<T> source, Func<T, U> selector)
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

        [TrackCaller] public static T Max<T>(this IEnumerable<T> source)
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

        [TrackCaller] public static U Max<T, U>(this IEnumerable<T> source, Func<T, U> selector)
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

        [TrackCaller] public static double Average<T>(this IEnumerable<T> source)
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

        [TrackCaller] public static double Average<T, U>(this IEnumerable<T> source, Func<T, U> selector)
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
        IEnumerable<T> source;
        Func<T, T, int> compare;

        public OrderedEnumerable(IEnumerable<T> source, Func<T, T, int> compare)
        {
            this.source = source;
            this.compare = compare;
        }

        public OrderedEnumerable<T> ThenBy<K>(Func<T, K> key)
        {
            Func<T, T, int> previo = compare;
            return new OrderedEnumerable<T>(source, (a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(a), key(b));
            });
        }

        public OrderedEnumerable<T> ThenByDescending<K>(Func<T, K> key)
        {
            Func<T, T, int> previo = compare;
            return new OrderedEnumerable<T>(source, (a, b) => {
                int c = previo(a, b);
                return c != 0 ? c : Algorithms.CompareKeys<K>(key(b), key(a));
            });
        }

        public IEnumerator<T> GetEnumerator() => Sorted().GetEnumerator();

        IEnumerable<T> Sorted()
        {
            List<T> all = new List<T>();
            foreach (T x in source) all.Add(x);
            all.Sort(compare);
            foreach (T x in all) yield return x;
        }
    }
}
