// comptime: funciones y expresiones evaluadas al compilar (tablas, cadenas, constantes),
// static_assert, comptime if / foreach / var y la reflexión de tiempo de compilación Tipo<T>
// en funciones genéricas (cada instancia genera su propio código directo).
using std.collections;
using std.text;

comptime long Factorial(int n) => n <= 1 ? 1 : n * Factorial(n - 1);

comptime List<int> Primos(int hasta)
{
    List<int> r = new List<int>();
    for (int i = 2; i <= hasta; i++)
    {
        bool primo = true;
        for (int d = 2; d * d <= i; d++)
        {
            if (i % d == 0)
            {
                primo = false;
                break;
            }
        }
        if (primo) r.Add(i);
    }
    return r;
}

// Tabla CRC-8 calculada al compilar.
comptime List<byte> TablaCrc()
{
    List<byte> t = new List<byte>();
    for (int i = 0; i < 256; i++)
    {
        int c = i;
        for (int k = 0; k < 8; k++) c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
        t.Add((byte)c);
    }
    return t;
}

comptime string Titulo(string s)
{
    StringBuilder sb = new StringBuilder();
    bool inicio = true;
    foreach (char c in s)
    {
        sb.Append(inicio ? char.ToUpper(c) : c);
        inicio = c == ' ';
    }
    return sb.ToString();
}

int Triple(int x) => x * 3;  // función normal: también se puede evaluar con 'comptime'

class Punto
{
    public int X, Y;
    public Punto(int x, int y)
    {
        X = x;
        Y = y;
    }
    public int Norma1() => (X < 0 ? -X : X) + (Y < 0 ? -Y : Y);
}

struct Pixel
{
    public byte R, G, B, A;
}

enum Dia { Lunes, Martes, Miercoles }

class Config
{
    public const long F10 = comptime Factorial(10);
    public static List<int> P = Primos(50);
    public static List<byte> Crc = TablaCrc();
}

static_assert(Factorial(5) == 120, "el factorial falla");
static_assert(sizeof(Pixel) == 4, "Pixel debe ocupar 4 bytes");

int Crc8(string s)
{
    int c = 0;
    for (int i = 0; i < s.Length; i++) c = Config.Crc[c ^ s[i]];
    return c;
}

// Describe cualquier tipo en tiempo de compilación.
string Describir<T>()
{
    string s = Tipo<T>.Nombre + ":";
    comptime if (Tipo<T>.EsLista) s += " lista de " + Tipo<T.Elemento>.Nombre;
    else comptime if (Tipo<T>.EsDiccionario) s += $" diccionario {Tipo<T.Clave>.Nombre} -> {Tipo<T.Valor>.Nombre}";
    else comptime if (Tipo<T>.EsEnum) s += " enum con " + Tipo<T>.Valores.Count + " valores";
    else comptime if (Tipo<T>.EsStruct) s += " struct de " + sizeof(T) + " bytes";
    else comptime if (Tipo<T>.EsClase)
    {
        comptime foreach (var f in Tipo<T>.Miembros) s += $" {f.Tipo.Nombre} {f.Nombre};";
        comptime foreach (var m in Tipo<T>.Metodos) s += $" {m.Nombre}()";
    }
    else s += " primitivo";
    return s;
}

// Suma los campos numéricos de cualquier tipo, sin reflexión al ejecutar.
double SumaNumericos<T>(T obj)
{
    double total = 0;
    comptime foreach (var f in Tipo<T>.Campos)
        comptime if (f.Tipo.EsNumerico) total += f.Get(obj);
    return total;
}

void Main()
{
    Console.WriteLine(Config.F10);
    Console.WriteLine(Config.P.Count + " primos, el último " + Config.P[Config.P.Count - 1]);
    Console.WriteLine(Crc8("123456789"));
    Console.WriteLine(Titulo("hola mundo en faset"));
    Console.WriteLine(comptime Triple(14));
    const int K = comptime (1 << 10) + 1;
    Console.WriteLine(K);
    Console.WriteLine(comptime new Punto(3, -4).Norma1());
    comptime var nombres = Tipo<Dia>.Valores;
    comptime foreach (var d in nombres) Console.WriteLine($"{d.Nombre} = {d.Entero}");
    Console.WriteLine(Describir<Punto>());
    Console.WriteLine(Describir<Pixel>());
    Console.WriteLine(Describir<List<string>>());
    Console.WriteLine(Describir<Dictionary<string, int>>());
    Console.WriteLine(Describir<Dia>());
    Console.WriteLine(Describir<double>());
    Pixel px = new Pixel();
    px.R = 10;
    px.B = 5;
    Console.WriteLine(SumaNumericos(px));
    Console.WriteLine(SumaNumericos(new Punto(2, 40)));
    comptime if (sizeof(long) == 8) Console.WriteLine("long de 64 bits");
    else Console.WriteLine("¿?");
}
