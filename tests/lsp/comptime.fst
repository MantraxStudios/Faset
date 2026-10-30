using std;

class Rango : Attribute
{
    public int Min, Max;
    public Rango(int min, int max) { Min = min; Max = max; }
}

class Persona
{
    [Rango(0, 150)] public int Edad;
}

class Programa
{
    static comptime int Doble(int x) => x * 2;

    static void Main()
    {
        comptime foreach (var f in Tipo<Persona>.Campos) println(f.Nombre);
        int d = Doble(4);
        println(d);
    }
}
