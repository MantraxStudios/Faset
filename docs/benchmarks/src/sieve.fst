// Criba de Eratóstenes hasta 20 000 000: acceso a memoria y bucles.
static class Program
{
    static int Main()
    {
        int n = 20000000;
        byte* compuesto = new byte[n + 1];   // reservado a cero
        int cuenta = 0;
        for (int i = 2; i <= n; i++)
        {
            if (compuesto[i] != 0) continue;
            cuenta++;
            for (long j = (long)i * i; j <= n; j += i) compuesto[j] = 1;
        }
        Console.WriteLine(cuenta);
        delete[] compuesto;
        return 0;
    }
}
