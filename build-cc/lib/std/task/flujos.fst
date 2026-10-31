// =============================================================================
//  std.task (flujos asíncronos)  —  IAsyncEnumerable<T>, IAsyncEnumerator<T> y 'await foreach'.
//
//    static async IAsyncEnumerable<int> Lecturas()
//    {
//        for (int i = 0; i < 3; i++)
//        {
//            await Task.Delay(100);     // espera sin bloquear el hilo
//            yield return i;            // entrega un elemento a quien recorre
//        }
//    }
//
//    await foreach (int x in Lecturas()) Console.WriteLine(x);
//
//  MoveNextAsync() devuelve una Task<bool> (en C# es ValueTask<bool>) que termina con true al llegar
//  al siguiente 'yield return' y con false al final. 'await foreach' llama a DisposeAsync() al salir
//  del bucle (también con break o una excepción): el iterador ejecuta sus bloques 'finally'.
// =============================================================================
using std.collections;

namespace std.task
{
    public interface IAsyncEnumerator<T>
    {
        T Current { get; }
        Task<bool> MoveNextAsync();
        Task DisposeAsync();
    }

    public interface IAsyncEnumerable<T>
    {
        IAsyncEnumerator<T> GetAsyncEnumerator();
    }

    // Lo que devuelve un iterador async (lo crea el compilador). 'paso' ejecuta el cuerpo hasta el
    // siguiente 'yield' (0 = MoveNextAsync, 1 = DisposeAsync) y devuelve la tarea de esa llamada.
    public sealed class GeneradorAsync<T> : IAsyncEnumerable<T>, IAsyncEnumerator<T>
    {
        public var __actual: T;  // lo asigna 'yield return'
        var paso: Func<int, Task<bool>>;
        var clonar: Func<GeneradorAsync<T>>;
        var entregado: bool;

        public init(paso: Func<int, Task<bool>>, clonar: Func<GeneradorAsync<T>>)
        {
            this.paso = paso;
            this.clonar = clonar;
        }

        public prop Current: T => __actual;
        public func MoveNextAsync() -> Task<bool> => paso(0);
        public func DisposeAsync() -> Task => paso(1);

        public func GetAsyncEnumerator() -> IAsyncEnumerator<T>
        {
            if (!entregado)
            {
                entregado = true;
                return this;
            }
            GeneradorAsync<T> otro = clonar();
            otro.entregado = true;
            return otro;
        }
    }

    public static class AsyncEnumerable
    {
        // Todos los elementos de un flujo en una lista.
        public static async func ToListAsync<T>(this source: IAsyncEnumerable<T>) -> Task<List<T>>
        {
            List<T> r = new List<T>();
            await foreach (T x in source) r.Add(x);
            return r;
        }

        // Un IEnumerable<T> como flujo asíncrono.
        public static async func ToAsyncEnumerable<T>(this source: IEnumerable<T>) -> IAsyncEnumerable<T>
        {
            foreach (T x in source) yield return x;
        }
    }
}
