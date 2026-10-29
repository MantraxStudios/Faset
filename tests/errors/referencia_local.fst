// Devolver una referencia (T&) a memoria que desaparece al salir del método.
struct Punto
{
    public int X;
    public int Y;
}

class Prueba
{
    static int campo;

    static int& Local()
    {
        int x = 1;
        return x;
    }

    static int& CampoDeLocal()
    {
        Punto p = new Punto();
        return p.X;
    }

    static int& Parametro(Punto p)
    {
        return p.Y;
    }

    static int& Mismo(ref int v) { return v; }

    static int& APartirDeRef()
    {
        int y = 2;
        return Mismo(ref y);
    }

    static int& Estatico() { return campo; }   // correcto
    static int& DeRef(ref Punto p) { return p.X; }   // correcto

    static void Main() { }
}
