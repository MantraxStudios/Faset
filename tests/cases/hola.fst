using std;

namespace Demo
{
    public static class Program
    {
        public static void Main()
        {
            Console.WriteLine("¡Hola, mundo desde Faset!");
            int a = 7, b = 3;
            Console.Write("a + b = "); Console.WriteLine(a + b);
            Console.Write("a / b = "); Console.WriteLine(a / b);
            Console.Write("7.0 / 2 = "); Console.WriteLine(7.0 / 2);
            Console.Write("raíz de 2 = "); Console.WriteLine(Math.Sqrt(2));
            Console.WriteLine(int.MaxValue);
            Console.WriteLine(-2147483648);
            Console.WriteLine('ñ');
            Console.WriteLine(a > b);
        }
    }
}
