namespace Base
{
    // Plantilla y estado estático definidos en la biblioteca más profunda.
    public class Caja<T>
    {
        public T Valor;
        public Caja(T v) { Valor = v; }
    }

    public static class Contador
    {
        static int total = 100;
        public static int Siguiente() { total++; return total; }
    }
}
