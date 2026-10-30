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
        public T __actual;  // lo asigna 'yield return'
        Func<int, Task<bool>> paso;
        Func<GeneradorAsync<T>> clonar;
        bool entregado;

        public GeneradorAsync(Func<int, Task<bool>> paso, Func<GeneradorAsync<T>> clonar)
        {
            this.paso = paso;
            this.clonar = clonar;
        }

        public T Current => __actual;
        public Task<bool> MoveNextAsync() => paso(0);
        public Task DisposeAsync() => paso(1);

        public IAsyncEnumerator<T> GetAsyncEnumerator()
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
        public static async Task<List<T>> ToListAsync<T>(this IAsyncEnumerable<T> source)
        {
            List<T> r = new List<T>();
            await foreach (T x in source) r.Add(x);
            return r;
        }

        // Un IEnumerable<T> como flujo asíncrono.
        public static async IAsyncEnumerable<T> ToAsyncEnumerable<T>(this IEnumerable<T> source)
        {
            foreach (T x in source) yield return x;
        }
    }
}
