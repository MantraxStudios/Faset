// Programa para el test del depurador (tests/run.sh): los números de línea importan.
static class Programa
{
    static int Doble(int n)
    {
        int r = n * 2;
        return r;
    }

    static void Main()
    {
        int total = 20;
        total = total + Doble(1);
        Console.WriteLine("total " + total);
    }
}
