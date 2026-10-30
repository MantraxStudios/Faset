// Tipos anidados (clases, structs, enums, interfaces, records y delegados dentro de una clase),
// nombres calificados Externa.Interna, clases genéricas con tipos anidados, 'using static' y
// alias de 'using'.
using std.collections;
using static std.Math;
using static Externa.Modo;
using Par = Externa.Interna;
using Texto = std.text.StringBuilder;

class Externa
{
    static int contador = 0;
    public class Interna
    {
        public int Valor;
        public Interna(int v) { Valor = v; contador++; }   // ve los miembros privados de Externa
        public int Total() => Valor + contador;
        public class Profunda { public string Hola() => "profunda " + Doble(contador); }
    }
    public enum Modo { Lento, Rapido }
    public struct Celda { public int X; }
    public interface IForma { double Area(); }
    public record Punto(int X, int Y);
    class Secreta { public int Z = 9; }
    public delegate int Op(int a);

    static int Doble(int x) => x * 2;
    public static int Usar() { var s = new Secreta(); return s.Z; }
    public Modo M = Modo.Rapido;
    public Op Duplicar = x => x * 2;
}

class Derivada : Externa
{
    public Interna Crear() => new Interna(100);   // tipos anidados heredados
}

class Cuadrado : Externa.IForma
{
    public double Area() => 4.0;
}

class Caja<T>
{
    class Nodo
    {
        public T Valor;
        public Nodo Sig;
        public Nodo(T v) { Valor = v; }
    }
    Nodo cabeza;
    int n;
    public void Poner(T v) { var x = new Nodo(v); x.Sig = cabeza; cabeza = x; n++; }
    public T Primero() => cabeza.Valor;
    public int Cuenta => n;
    public List<T> Todos()
    {
        var r = new List<T>();
        for (Nodo x = cabeza; x != null; x = x.Sig) r.Add(x.Valor);
        return r;
    }
}

void main()
{
    var i = new Externa.Interna(5);
    println(i.Total());
    println(new Externa.Interna.Profunda().Hola());
    Externa.Modo m = Externa.Modo.Lento;
    println(m.ToString() + " " + Rapido.ToString());
    var c = new Externa.Celda { X = 3 };
    println(c.X);
    Externa.IForma f = new Cuadrado();
    println(f.Area());
    var p = new Externa.Punto(1, 2);
    println(p.ToString());
    Externa.Op op = x => x * 3;
    println(op(14) + new Externa().Duplicar(1));
    println(Externa.Usar());
    Par q = new Par(1);
    println(q.Total());
    println(new Derivada().Crear().Valor);
    var cj = new Caja<string>();
    cj.Poner("a");
    cj.Poner("b");
    println(cj.Primero() + " " + cj.Cuenta + " " + cj.Todos().Count);
    var ci = new Caja<int>();
    ci.Poner(7);
    println(ci.Primero());
    println(new Externa().M.ToString());
    println(Sqrt(16.0) + Max(3, 7) + Abs(-2));
    var sb = new Texto();
    sb.Append("texto");
    println(sb.ToString());
}
