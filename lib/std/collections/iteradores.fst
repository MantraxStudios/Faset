// =============================================================================
//  std.collections (iteradores)  —  IEnumerable<T>, IEnumerator<T> y el generador de 'yield'.
//
//    IEnumerable<T>     algo que se puede recorrer: GetEnumerator()
//    IEnumerator<T>     un recorrido en curso: MoveNext(), Current, Dispose()
//    Generador<T>       lo que devuelve un iterador (un método con 'yield return'); lo crea el
//                       compilador, no hace falta usarlo directamente
//
//  List<T>, Dictionary<K, V>, HashSet<T>, Stack<T>, Queue<T> y string son IEnumerable. Su foreach
//  sigue usando su enumerador struct (sin reservar memoria); a través de la interfaz se recorren
//  con un enumerador de clase.
//
//    static IEnumerable<int> Pares(int hasta)
//    {
//        for (int i = 0; i <= hasta; i += 2)
//            yield return i;          // el método se suspende aquí hasta el siguiente MoveNext()
//    }
// =============================================================================
namespace std.collections
{
    // Un recorrido en curso. Dispose() termina el recorrido antes de tiempo (foreach lo llama al
    // salir del bucle): en un iterador ejecuta sus bloques 'finally' pendientes.
    public interface IEnumerator<T>
    {
        T Current { get; }
        bool MoveNext();
        void Dispose();
    }

    // Algo que se puede recorrer con foreach y con los operadores de LINQ (perezosos).
    public interface IEnumerable<T>
    {
        IEnumerator<T> GetEnumerator();
    }

    // El objeto que devuelve un iterador. 'paso' ejecuta el cuerpo hasta el siguiente 'yield'
    // (0 = MoveNext, 1 = Dispose); 'clonar' crea otro recorrido desde el principio con los mismos
    // argumentos (cada GetEnumerator() empieza de nuevo, salvo el primero, que es él mismo).
    public sealed class Generador<T> : IEnumerable<T>, IEnumerator<T>
    {
        public var __actual: T;  // lo asigna 'yield return'
        var paso: Func<int, bool>;
        var clonar: Func<Generador<T>>;
        var entregado: bool;

        public init(paso: Func<int, bool>, clonar: Func<Generador<T>>)
        {
            this.paso = paso;
            this.clonar = clonar;
        }

        public prop Current: T => __actual;
        public func MoveNext() -> bool => paso(0);
        public func Dispose() { paso(1); }

        public func GetEnumerator() -> IEnumerator<T>
        {
            if (!entregado)
            {
                entregado = true;
                return this;
            }
            Generador<T> otro = clonar();
            otro.entregado = true;
            return otro;
        }
    }
}
