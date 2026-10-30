// Casos combinados: valores por defecto en interfaces y overrides (se usan los del tipo estático),
// indizadores virtuales, constructores estáticos en genéricos, tipos anidados en structs y 'required' heredado.
using std.collections;
interface IForma { string Nombre(string prefijo = "forma"); }
class Base : IForma
{
    public virtual string Nombre(string prefijo = "base") => prefijo + ":Base";
    public virtual int this[int i] { get { return i; } }
}
class Der : Base
{
    public override string Nombre(string prefijo = "der") => prefijo + ":Der";
    public override int this[int i] { get { return i * 100; } }
}
class Gen<T>
{
    public static List<T> Cache = new List<T>();
    public static int Inits;
    static Gen() { Inits = 7; }
    public T Primero(T defecto = default) => Cache.Count > 0 ? Cache[0] : defecto;
}
struct Tablero
{
    public enum Ficha { Vacia, X, O }
    public Ficha Centro;
    public int this[int f, int c] => f * 3 + c;
}
class Animal { public required string Nombre; }
class Perro : Animal { public required int Edad; }
void main()
{
    IForma f = new Der();
    Base b = new Der();
    println(f.Nombre());
    println(b.Nombre());
    println(b[2]);
    println(Gen<int>.Inits);
    println(new Gen<string>().Primero("x"));
    var t = new Tablero { Centro = Tablero.Ficha.X };
    switch (t.Centro) { case Tablero.Ficha.X: println("X"); break; default: println("?"); break; }
    println(t[1, 1]);
    var p = new Perro { Nombre = "Rex", Edad = 3 };
    println(p.Nombre + p.Edad);
}
