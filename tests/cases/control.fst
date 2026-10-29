using std;

struct Rect
{
    public Punto Min;
    public Punto Max;
    public int Area() { return (Max.X - Min.X) * (Max.Y - Min.Y); }
}

struct Punto
{
    public int X, Y;
    public Punto(int x, int y) { X = x; Y = y; }
}

class Contador
{
    public static int Instancias = 0;
    public const int Limite = 3;
    int valor = 10;
    string nombre;

    public Contador() { Instancias++; nombre = "sin nombre"; }
    public Contador(string n) { Instancias++; nombre = n; }
    public Contador(string n, int v) { Instancias++; nombre = n; valor = v; }

    public int Valor() { return valor; }
    public string Nombre() { return nombre; }
    public void Sumar(int n) { valor += n; }
    public void Sumar(double d) { valor += (int)d * 100; }
}

static class Program
{
    static int Fib(int n) => n < 2 ? n : Fib(n - 1) + Fib(n - 2);

    static void Rellenar(int** destino, int n)
    {
        *destino = new int[n];
        for (int i = 0; i < n; i++) (*destino)[i] = i + 1;
    }

    static int Main()
    {
        // bucles
        int suma = 0;
        for (int i = 0; i < 20; i++)
        {
            if (i % 2 == 0) continue;
            if (i > 15) break;
            suma += i;
        }
        Console.WriteLine(suma);
        int k = 0;
        do { k += 3; } while (k < 10);
        Console.WriteLine(k);
        int w = 100;
        while (true) { w /= 2; if (w < 10) break; }
        Console.WriteLine(w);
        Console.WriteLine(Fib(20));

        // operadores
        int bits = 1 << 10 | 5;
        Console.WriteLine(bits);
        Console.WriteLine(bits >> 2 & 0xFF);
        Console.WriteLine(~0);
        Console.WriteLine(-7 / 2);
        Console.WriteLine(-7 % 2);
        Console.WriteLine(10 > 5 && !(3 == 4));
        char c = 'a';
        c++;
        Console.WriteLine(c);
        Console.WriteLine(c - 'a');
        Console.WriteLine((char)('A' + 2));
        long big = int.MaxValue;
        big = big * 2;
        Console.WriteLine(big);
        ulong ul = ulong.MaxValue;
        Console.WriteLine(ul);
        Console.WriteLine(1.5f * 2);
        Console.WriteLine(0.1 + 0.2);
        Console.WriteLine(1e20);
        Console.WriteLine(5 > 3 ? "si" : "no");
        sbyte sb = (sbyte)200;
        Console.WriteLine(sb);

        // structs anidados por valor
        Rect r = new Rect();
        r.Max = new Punto(4, 5);
        r.Min.X = 1;
        Console.WriteLine(r.Area());

        // clases, sobrecargas de constructores y métodos, campos estáticos y const
        Contador a = new Contador();
        Contador b = new Contador("b");
        Contador d = new Contador("d", 7);
        a.Sumar(5);
        d.Sumar(2.0);
        Console.WriteLine(a.Valor());
        Console.WriteLine(b.Nombre());
        Console.WriteLine(d.Valor());
        Console.WriteLine(Contador.Instancias);
        Console.WriteLine(Contador.Limite * 2);
        delete a; delete b; delete d;

        // puntero a puntero
        int* datos = null;
        Rellenar(&datos, 5);
        int total = 0;
        for (int i = 0; i < 5; i++) total += datos[i];
        Console.WriteLine(total);
        delete[] datos;
        Console.WriteLine(datos != null);

        // memoria cruda
        byte* buf = (byte*)Memory.Alloc(4);
        Memory.Set(buf, 65, 3);
        buf[3] = 0;
        Console.WriteLine(String.FromCString(buf));
        Memory.Free(buf);
        return 3;
    }
}
