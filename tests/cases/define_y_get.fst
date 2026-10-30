#define TRAZA
#undef DEBUG
// #define / #undef al principio del archivo (solo valen en él) con #if y [Conditional], y
// propiedades automáticas { get; } asignadas en el constructor, como en C#.
using std;

class Log
{
    [Conditional("TRAZA")] public static void Traza(string s) { Console.WriteLine("traza: " + s); }
    [Conditional("DEBUG")] public static void Depura(string s) { Console.WriteLine("debug: " + s); }
}

class Persona
{
    public string Nombre { get; }
    public int Edad { get; }
    public static int Creadas { get; }
    static Persona() { Creadas = 100; }
    public Persona(string nombre, int edad) { Nombre = nombre; this.Edad = edad * 2; }
}

class Program
{
    static void Main()
    {
        Log.Traza("uno");
        Log.Depura("dos");
#if TRAZA
        Console.WriteLine("TRAZA definido");
#endif
#if DEBUG
        Console.WriteLine("DEBUG definido");
#endif
        var p = new Persona("Ana", 20);
        Console.WriteLine($"{p.Nombre} {p.Edad} {Persona.Creadas}");
    }
}
