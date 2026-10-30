// Implementación explícita de miembros de interfaz (métodos y propiedades): solo se usan a
// través de la interfaz; la clase puede tener a la vez un miembro propio con el mismo nombre.
interface IForma
{
    double Area();
    string Nombre { get; }
}

class Cuadro : IForma
{
    double l;
    public Cuadro(double l) { this.l = l; }
    double IForma.Area() => l * l;
    string IForma.Nombre => "cuadro";
    public double Area() => -1;
}

static void Main()
{
    Cuadro c = new Cuadro(3);
    IForma f = c;
    Console.WriteLine(f.Area() + " " + f.Nombre + " " + c.Area());
}
