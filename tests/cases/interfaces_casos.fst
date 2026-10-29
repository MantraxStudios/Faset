// Interfaz implementada en parte por una clase abstracta, clases partial con la base en otra
// parte y propiedades get/set de interfaz.
interface IA { int Uno(); int Dos(); }
abstract class Parcial : IA
{
    public int Uno() => 1;
    public abstract int Dos();
}
class Total : Parcial
{
    public override int Dos() => 2;
}
partial class Mitad { public int X = 1; }
partial class Mitad : Parcial { public override int Dos() => 22; }

interface IContador { int Valor { get; set; } }
class Contador : IContador
{
    public int Valor { get; set; }
}

void Main()
{
    IA a = new Total();
    Console.WriteLine(a.Uno() + a.Dos());
    IA m = new Mitad();
    Console.WriteLine(m.Dos() + " " + ((Mitad)m).X);
    IContador c = new Contador();
    c.Valor = 41;
    c.Valor = c.Valor + 1;
    Console.WriteLine(c.Valor);
}
