// Casos límite: implementación heredada de una interfaz, métodos por defecto, ToString sin
// 'override', derivar de List<T>, base.F() encadenado, patrones 'is' en bucles y ': this(...)'.
using std.collections;

interface ISaludo
{
    string Nombre();
    string Saludar() { return "Hola, " + Nombre(); }
}

class Base
{
    public string Nombre() => "base";
}

class Hija : Base, ISaludo
{
}

class Nota
{
    public string ToString() => "nota sin override";
}

class MiLista : List<int>
{
    public int Doble(int i) => this[i] * 2;
}

class Nodo<T>
{
    public T Valor;
    public Nodo<T> Sig;
    public virtual string Describir() => "nodo " + Valor;
}

class NodoEtiquetado<T> : Nodo<T>
{
    public string Etiqueta = "";
    public override string Describir() => Etiqueta + ": " + base.Describir();
}

class A { public virtual int F() => 1; }
class B : A { public override int F() => base.F() + 10; }
class C : B { public override int F() => base.F() + 100; }

class Con
{
    public int X;
    public Con() : this(7) { }
    public Con(int x) { X = x; }
}
class ConDer : Con
{
    public int Y = 3;
    public ConDer() { }
}

void Main()
{
    ISaludo s = new Hija();
    Console.WriteLine(s.Saludar());
    Console.WriteLine(new Nota());
    object o = new Nota();
    Console.WriteLine(o.ToString());
    MiLista l = new MiLista();
    l.Add(21);
    Console.WriteLine(l.Doble(0) + " " + l.Count);
    NodoEtiquetado<int> n = new NodoEtiquetado<int>();
    n.Valor = 5;
    n.Etiqueta = "x";
    Nodo<int> nb = n;
    Console.WriteLine(nb.Describir());
    A a = new C();
    Console.WriteLine(a.F());
    List<object> cosas = new List<object>();
    cosas.Add(new Nota());
    cosas.Add(n);
    cosas.Add(new C());
    int i = 0;
    while (i < cosas.Count)
    {
        if (cosas[i] is Nota x) Console.WriteLine("nota: " + x);
        else if (cosas[i] is A x2) Console.WriteLine("A: " + x2.F());
        else Console.WriteLine("otro: " + cosas[i].GetType().Name);
        i++;
    }
    for (int k = 0; k < 2; k++)
    {
        if (cosas[k] is Nota y) Console.WriteLine("de nuevo " + y.ToString());
    }
    ConDer cd = new ConDer();
    Console.WriteLine(cd.X + " " + cd.Y);
}
