// Fibonacci recursivo: llamadas a función y aritmética entera.
static class Program
{
    static int Fib(int n) => n < 2 ? n : Fib(n - 1) + Fib(n - 2);

    static int Main()
    {
        Console.WriteLine(Fib(37));
        return 0;
    }
}
