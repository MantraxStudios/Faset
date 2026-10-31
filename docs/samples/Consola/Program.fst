using std::collections;

namespace Consola
{
    public static class Program
    {
        public static func Main()
        {
            Console::WriteLine("¡Hola desde Faset!");

            var numeros = new List<int>();
            for (int i = 1; i <= 5; i++) numeros.Add(i * i);
            Console::WriteLine(numeros.Sum());
            delete numeros;
        }
    }
}
