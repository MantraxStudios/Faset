// Herencia: clases abstractas, virtual/override, propiedades virtuales, base(...), this(...),
// base.Metodo(), destructores en cadena, sealed y miembros protegidos.
using std.collections;

namespace Geometria
{
    public abstract class Forma
    {
        protected string etiqueta;
        private static int creadas = 0;

        protected Forma(string etiqueta)
        {
            this.etiqueta = etiqueta;
            creadas++;
        }

        public static int Creadas => creadas;
        public abstract double Area();
        public virtual double Perimetro() { return 0; }
        public virtual string Nombre => "forma";
        public string Etiqueta => etiqueta;

        public override string ToString() => Nombre + " '" + etiqueta + "' (área " + Area() + ")";
    }

    public class Rectangulo : Forma
    {
        protected double ancho, alto;
        public Rectangulo(double ancho, double alto) : this("rect", ancho, alto) { }
        public Rectangulo(string etiqueta, double ancho, double alto) : base(etiqueta)
        {
            this.ancho = ancho;
            this.alto = alto;
        }
        public override double Area() => ancho * alto;
        public override double Perimetro() => 2 * (ancho + alto);
        public override string Nombre => "rectángulo";
    }

    public sealed class Cuadrado : Rectangulo
    {
        public Cuadrado(double lado) : base("cuad", lado, lado) { }
        public override string Nombre => "cuadrado";
        // base.Perimetro() llama a la versión de Rectangulo sin despacho virtual.
        public override double Perimetro() => base.Perimetro() + 0;
        public double Lado => ancho;  // campo protegido heredado
    }

    public class Circulo : Forma
    {
        double radio;
        public Circulo(double r) : base("circ") { radio = r; }
        public override double Area() => 3 * radio * radio;
        public override string Nombre => "círculo de radio " + radio;
    }
}

using Geometria;

class Recurso
{
    protected string nombre;
    public Recurso(string n) { nombre = n; }
    ~Recurso() { Console.WriteLine("~Recurso " + nombre); }
}

class Archivo : Recurso
{
    public Archivo(string n) : base(n) { }
    ~Archivo() { Console.WriteLine("~Archivo " + nombre); }
}

class ArchivoLog : Archivo
{
    public ArchivoLog() : base("log") { }
}

void Main()
{
    List<Forma> formas = new List<Forma>();
    formas.Add(new Rectangulo(2, 3));
    formas.Add(new Cuadrado(4));
    formas.Add(new Circulo(1));
    double total = 0;
    for (int i = 0; i < formas.Count; i++)
    {
        Forma f = formas[i];
        Console.WriteLine(f.ToString());
        Console.WriteLine("  perímetro: " + f.Perimetro());
        total += f.Area();
    }
    Console.WriteLine("total: " + total);
    Console.WriteLine("creadas: " + Forma.Creadas);

    Cuadrado c = new Cuadrado(5);
    Rectangulo r = c;
    Forma f2 = r;
    object o = f2;
    Console.WriteLine(c.Lado);
    Console.WriteLine(r.Nombre + " / " + f2.Nombre + " / " + o.ToString());
    Console.WriteLine("concatenado: " + f2);

    // destructores: derivada y luego base
    delete new Archivo("datos");
    delete new ArchivoLog();
}
