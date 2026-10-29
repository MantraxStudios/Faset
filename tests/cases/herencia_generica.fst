// Herencia con plantillas, propiedades virtuales con 'set', ocultación con 'new', sobrecargas
// con conversiones a la base, miembros estáticos heredados y structs con 'override ToString'.
using std.collections;

abstract class Coleccion<T>
{
    protected List<T> items = new List<T>();
    public int Cantidad => items.Count;
    public abstract void Poner(T x);
    public abstract T Sacar();
    public virtual string Tipo => "colección";
    public override string ToString() => Tipo + "(" + Cantidad + ")";
}

class Pila<T> : Coleccion<T>
{
    public override void Poner(T x) { items.Add(x); }
    public override T Sacar()
    {
        T x = items[items.Count - 1];
        items.RemoveAt(items.Count - 1);
        return x;
    }
    public override string Tipo => "pila";
}

class Cola<T> : Coleccion<T>
{
    public override void Poner(T x) { items.Add(x); }
    public override T Sacar()
    {
        T x = items[0];
        items.RemoveAt(0);
        return x;
    }
}

class Termometro
{
    double grados;
    public virtual double Grados
    {
        get { return grados; }
        set { grados = value; }
    }
    public static string Unidad = "C";
    public static string Describir(Termometro t) => t.Grados + " " + Unidad;
}

class TermometroLimitado : Termometro
{
    public override double Grados
    {
        get { return base.Grados; }
        set { base.Grados = value > 100 ? 100 : value; }
    }
}

class Base
{
    public string Quien() => "Base";
    public virtual string Virtual() => "Base.Virtual";
}

class Derivada : Base
{
    public new string Quien() => "Derivada";             // oculta (no es virtual)
    public new virtual string Virtual() => "Derivada.Virtual";  // nueva entrada en la vtable
}

struct Dinero
{
    public long Centimos;
    public Dinero(long c) { Centimos = c; }
    public override string ToString() => (Centimos / 100) + "," + (Centimos % 100) + " EUR";
}

class Animal { }
class Perro : Animal { }
class Caniche : Perro { }

string Que(Animal a) => "animal";
string Que(Perro p) => "perro";
string Que(object o) => "objeto";

void Main()
{
    List<Coleccion<int>> todas = new List<Coleccion<int>>();
    todas.Add(new Pila<int>());
    todas.Add(new Cola<int>());
    for (int i = 0; i < todas.Count; i++)
    {
        Coleccion<int> c = todas[i];
        c.Poner(1);
        c.Poner(2);
        c.Poner(3);
        string antes = c.ToString();
        int x = c.Sacar();
        Console.WriteLine(antes + " saca " + x + " -> " + c);
    }
    Coleccion<string> s = new Pila<string>();
    s.Poner("hola");
    Console.WriteLine(s.Sacar() + " " + (s is Pila<string>) + " " + (s is Cola<string>));

    Termometro t = new TermometroLimitado();
    t.Grados = 250;
    Console.WriteLine(Termometro.Describir(t));
    t.Grados = 20;
    Console.WriteLine(TermometroLimitado.Describir(t) + " " + TermometroLimitado.Unidad);

    Derivada d = new Derivada();
    Base b = d;
    Console.WriteLine(d.Quien() + " " + b.Quien());
    Console.WriteLine(d.Virtual() + " " + b.Virtual());

    Dinero precio = new Dinero(1250);
    Console.WriteLine(precio.ToString());

    Console.WriteLine(Que(new Caniche()) + " " + Que(new Animal()) + " " + Que(new Termometro()));
}
