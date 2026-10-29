// Interfaces: varias por clase, herencia de interfaces, propiedades, métodos por defecto,
// interfaces genéricas con plantillas y restricciones 'where'.
using std.collections;

interface IForma
{
    double Area();
    string Nombre { get; }
}

interface IDibujable
{
    void Dibujar();
    // método por defecto: lo usan las clases que no lo implementan
    string Descripcion() { return "dibujable sin descripción"; }
}

interface IEscalable : IForma
{
    void Escalar(double k);
}

class Base
{
    public virtual string Nombre => "base";
}

class Circulo : Base, IEscalable, IDibujable
{
    double r;
    public Circulo(double r) { this.r = r; }
    public double Area() => 3 * r * r;
    public override string Nombre => "círculo";
    public void Escalar(double k) { r = r * k; }
    public void Dibujar() { Console.WriteLine("  ( ) r=" + r); }
}

class Etiqueta : IDibujable
{
    public void Dibujar() { Console.WriteLine("  [etiqueta]"); }
    public string Descripcion() => "una etiqueta";
}

// Interfaz genérica + restricción en una plantilla.
class Version : IComparable<Version>
{
    public int Mayor, Menor;
    public Version(int a, int b) { Mayor = a; Menor = b; }
    public int CompareTo(Version o) => Mayor != o.Mayor ? Mayor - o.Mayor : Menor - o.Menor;
    public override string ToString() => Mayor + "." + Menor;
}

T Maximo<T>(List<T> xs) where T : IComparable<T>
{
    T mejor = xs[0];
    for (int i = 1; i < xs.Count; i++)
        if (xs[i].CompareTo(mejor) > 0) mejor = xs[i];
    return mejor;
}

class Caja<T> where T : class, new()
{
    public T Valor = new T();
}

class Contador
{
    public int N = 7;
}

interface IRepositorio<T>
{
    void Guardar(T x);
    int Cantidad { get; }
}

class Memoria<T> : IRepositorio<T>
{
    List<T> datos = new List<T>();
    public void Guardar(T x) { datos.Add(x); }
    public int Cantidad => datos.Count;
}

void Usar(IRepositorio<string> repo)
{
    repo.Guardar("a");
    repo.Guardar("b");
    Console.WriteLine("guardados: " + repo.Cantidad);
}

void Main()
{
    Circulo c = new Circulo(1);
    IForma f = c;
    IEscalable e = c;
    IDibujable d = c;
    Console.WriteLine(f.Nombre + " " + f.Area());
    e.Escalar(2);
    Console.WriteLine(f.Area());
    d.Dibujar();
    Console.WriteLine(d.Descripcion());

    List<IDibujable> cosas = new List<IDibujable>();
    cosas.Add(c);
    cosas.Add(new Etiqueta());
    for (int i = 0; i < cosas.Count; i++)
    {
        cosas[i].Dibujar();
        Console.WriteLine("  " + cosas[i].Descripcion());
    }

    // conversiones con interfaces: comprobadas
    object o = d;
    Console.WriteLine(o is IForma);
    Console.WriteLine(o is Etiqueta);
    IForma f2 = (IForma)d;
    Console.WriteLine(f2.Nombre);
    IForma nada = cosas[1] as IForma;
    Console.WriteLine(nada == null);
    if (cosas[0] is IEscalable esc) esc.Escalar(0.5);
    Console.WriteLine(c.Area());

    List<Version> vs = new List<Version>();
    vs.Add(new Version(1, 4));
    vs.Add(new Version(2, 1));
    vs.Add(new Version(1, 9));
    Console.WriteLine("máxima: " + Maximo<Version>(vs));
    List<int> ns = new List<int>();
    ns.Add(3);
    ns.Add(11);
    ns.Add(5);
    Console.WriteLine("máximo: " + Maximo(ns));

    Caja<Contador> caja = new Caja<Contador>();
    Console.WriteLine(caja.Valor.N);

    Usar(new Memoria<string>());
    Console.WriteLine(typeof(IForma).IsInterface);
    Console.WriteLine(typeof(IForma).IsAssignableFrom(typeof(Circulo)));
    Console.WriteLine(typeof(IDibujable).IsAssignableFrom(typeof(Version)));
}
