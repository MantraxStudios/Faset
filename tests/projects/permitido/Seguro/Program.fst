// Código seguro: usa las API sin punteros de un proyecto con <AllowUnsafe> y de un
// archivo con la directiva 'memory_unsafe;'.
namespace Seguro
{
    public static class Program
    {
        public static void Main()
        {
            Console.Write("directiva: ");
            Console.WriteLine(Crudo.Tercero());
            Console.Write("proyecto: ");
            Console.WriteLine(Nativo.Bloque.SumaHasta(4) + 2);
        }
    }
}
