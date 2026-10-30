// Reflexión al ejecutar sobre structs: viajan en un Boxed<T>; SetValue e Invoke cambian el struct
// dentro de la caja, y Reflection.TypeOf da su tipo.
using std;
using std.collections;
using std.reflection;

[Reflectable]
public struct Punto
{
    public int X;
    public int Y { get; set; }
    public int Suma() => X + Y;
    public void Mover(int d) { X += d; }
}

class Program
{
    static void Main()
    {
        object o = Reflection.Box(new Punto { X = 1, Y = 2 });
        Type t = typeof(Punto);
        foreach (FieldInfo f in t.GetMembers()) Console.WriteLine($"{f.Name} = {f.GetValue(o)}");
        t.GetField("X").SetValue(o, Reflection.Box(10));
        t.GetProperty("Y").SetValue(o, Reflection.Box(5));
        t.GetMethod("Mover").Invoke(o, new List<object> { Reflection.Box(3) });
        Console.WriteLine(Reflection.Unbox<int>(t.GetMethod("Suma").Invoke(o)));
        Punto p = Reflection.Unbox<Punto>(o);
        Console.WriteLine($"{p.X} {p.Y} {Reflection.TypeOf(o).Name}");
        object n = Activator.CreateInstance(typeof(Punto));
        Console.WriteLine(Reflection.TypeName(n));
        try { t.GetField("X").GetValue(Reflection.Box(3)); } catch (ArgumentException e) { Console.WriteLine(e.Message); }
    }
}
