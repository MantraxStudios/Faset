// La directiva 'memory_unsafe;' convierte todo este archivo en un contexto memory_unsafe;
// el resto del proyecto sigue siendo seguro.
memory_unsafe;

namespace Seguro
{
    public static class Crudo
    {
        public static int Tercero()
        {
            int x = 3;
            int* p = &x;
            return *p;
        }
    }
}
