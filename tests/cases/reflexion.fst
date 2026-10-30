// Reflexión al ejecutar (std.reflection): GetFields / GetProperties / GetMethods con nombres,
// tipos, atributos, GetValue / SetValue / Invoke y Activator.CreateInstance. Solo llevan
// metadatos las clases [Reflectable] (y derivadas) y las usadas en typeof(X).GetFields()...
using std.collections;
using std.reflection;

class Columna : Attribute
{
    public string Nombre;
    public Columna(string n) { Nombre = n; }
}

[Reflectable]
class Entidad
{
    public int Id;
}

class Cliente : Entidad   // hereda [Reflectable]
{
    [Columna("nombre_cliente")] public string Nombre = "";
    public double Saldo { get; set; }
    public int Doble => Id * 2;
    public string Saludar(string otro, int veces)
    {
        string s = "";
        for (int i = 0; i < veces; i++) s += "hola " + otro + "; ";
        return s;
    }
    public void Ingresar(double cantidad) { Saldo += cantidad; }
    public static int Sumar(int a, int b) => a + b;
}

class Coche
{
    public string Marca = "Seat";
    public int Puertas = 5;
}

class SinMetadatos { public int A; }

void Main()
{
    Cliente c = new Cliente();
    c.Id = 7;
    c.Nombre = "Ana";
    c.Saldo = 10.5;
    Type t = c.GetType();
    foreach (FieldInfo f in t.GetFields())
    {
        Columna col = f.GetCustomAttribute<Columna>();
        Console.WriteLine($"campo {f.Name}: {f.FieldType.Name} = {f.GetValue(c)}" + (col == null ? "" : " columna " + col.Nombre));
    }
    foreach (FieldInfo p in t.GetProperties()) Console.WriteLine($"propiedad {p.Name}: {p.FieldType.Name} = {p.GetValue(c)} escribible={p.CanWrite}");
    foreach (MethodInfo m in t.GetMethods()) Console.WriteLine($"método {m}");

    t.GetField("Nombre").SetValue(c, Reflection.Box("Luis"));
    t.GetProperty("Saldo").SetValue(c, Reflection.Box(99.25));
    Console.WriteLine($"{c.Nombre} {c.Saldo}");
    int id = Reflection.Unbox<int>(t.GetField("Id").GetValue(c));
    Console.WriteLine(id + 1);

    List<object> args = new List<object>();
    args.Add(Reflection.Box("Eva"));
    args.Add(Reflection.Box(2));
    Console.WriteLine(t.GetMethod("Saludar").Invoke(c, args));
    List<object> cantidad = new List<object>();
    cantidad.Add(Reflection.Box(0.75));
    t.GetMethod("Ingresar").Invoke(c, cantidad);
    Console.WriteLine(c.Saldo);
    List<object> sum = new List<object>();
    sum.Add(Reflection.Box(2));
    sum.Add(Reflection.Box(3));
    Console.WriteLine(t.GetMethod("Sumar").Invoke(null, sum));

    // Metadatos pedidos por el uso: typeof(Coche).GetFields() y Activator.
    object o = Activator.CreateInstance(typeof(Coche));
    foreach (FieldInfo f in typeof(Coche).GetFields()) Console.WriteLine($"{f.Name} = {f.GetValue(o)}");
    Coche k = Activator.CreateInstance<Coche>();
    Console.WriteLine(k.Marca);
    Console.WriteLine(typeof(Entidad).GetFields().Count);

    // Errores al ejecutar.
    try { t.GetField("Id").SetValue(c, Reflection.Box("x")); }
    catch (InvalidCastException e) { Console.WriteLine(e.Message); }
    try { t.GetProperty("Doble").SetValue(c, Reflection.Box(1)); }
    catch (InvalidOperationException e) { Console.WriteLine(e.Message); }
    try { t.GetField("Id").GetValue(new Coche()); }
    catch (ArgumentException e) { Console.WriteLine(e.Message); }
    Type sin = new SinMetadatos().GetType();
    Console.WriteLine(sin.HasMetadata());
    try { sin.GetFields(); }
    catch (InvalidOperationException e) { Console.WriteLine(e.Message); }
}
