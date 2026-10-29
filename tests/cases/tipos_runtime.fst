// Información de tipos en tiempo de ejecución: is / as / conversiones comprobadas, typeof,
// GetType, nameof, object (ToString / Equals / GetHashCode) y enums (ToString, Parse, GetNames).
using std.collections;

namespace Zoo
{
    public class Animal
    {
        public string Nombre;
        public Animal(string n) { Nombre = n; }
    }
    public class Perro : Animal
    {
        public Perro(string n) : base(n) { }
        public void Ladrar() { Console.WriteLine(Nombre + ": ¡guau!"); }
    }
    public class Gato : Animal
    {
        public Gato(string n) : base(n) { }
    }
    public class Caniche : Perro
    {
        public Caniche() : base("Fifí") { }
    }
}

using Zoo;

enum Color { Rojo, Verde = 5, Azul }

class Punto
{
    public int X, Y;
    public Punto(int x, int y) { X = x; Y = y; }
    public override bool Equals(object o) => o is Punto p && p.X == X && p.Y == Y;
    public override int GetHashCode() => X * 31 + Y;
}

class Caja<T>
{
}

void Describir(Animal a)
{
    if (a is Perro p)
    {
        p.Ladrar();
        return;
    }
    if (a is not Gato) Console.WriteLine(a.Nombre + " no es ni perro ni gato");
    else Console.WriteLine(a.Nombre + " es un gato");
}

void Main()
{
    List<Animal> zoo = new List<Animal>();
    zoo.Add(new Perro("Rex"));
    zoo.Add(new Gato("Tom"));
    zoo.Add(new Animal("Nemo"));
    zoo.Add(new Caniche());
    for (int i = 0; i < zoo.Count; i++) Describir(zoo[i]);

    Animal a = zoo[3];
    Console.WriteLine(a is Perro);
    Console.WriteLine(a is Caniche);
    Console.WriteLine(a is Gato);
    Console.WriteLine(a is Animal);
    Animal nadie = null;
    Console.WriteLine(nadie is Animal);
    Console.WriteLine(nadie is null);
    Console.WriteLine((a as Gato) == null);
    Perro p = (Perro)a;  // conversión comprobada: correcta
    p.Ladrar();
    Perro sinNada = (Perro)nadie;  // null se convierte sin error
    Console.WriteLine(sinNada == null);

    // typeof / GetType / Type
    Type t = a.GetType();
    Console.WriteLine(t.Name + " | " + t.FullName + " | " + t);
    Console.WriteLine(t.BaseType.Name + " <- " + t.BaseType.BaseType.Name + " <- " + t.BaseType.BaseType.BaseType.FullName);
    Console.WriteLine(t.BaseType.BaseType.BaseType.BaseType == null);
    Console.WriteLine(t == typeof(Caniche));
    Console.WriteLine(t != typeof(Perro));
    Console.WriteLine(typeof(Animal).IsAssignableFrom(t));
    Console.WriteLine(typeof(Gato).IsAssignableFrom(t));
    Console.WriteLine(t.IsSubclassOf(typeof(Animal)));
    Console.WriteLine(typeof(Perro).IsInstanceOfType(a));
    Console.WriteLine(typeof(int).Name + " " + typeof(string).Name + " " + typeof(Color).Name + " " + typeof(Caja<int>).Name);
    Console.WriteLine(typeof(Color).IsEnum);
    Console.WriteLine(typeof(object).FullName);

    // nameof
    int contador = 3;
    Console.WriteLine(nameof(contador) + " " + nameof(Perro) + " " + nameof(a.Nombre) + " " + nameof(Describir));

    // object: ToString por defecto, Equals y GetHashCode reemplazados
    object o1 = new Punto(1, 2);
    object o2 = new Punto(1, 2);
    Console.WriteLine(o1.ToString());
    Console.WriteLine(o1 == o2);  // referencias distintas
    Console.WriteLine(o1.Equals(o2));
    Console.WriteLine(object.Equals(o1, o2));
    Console.WriteLine(object.ReferenceEquals(o1, o1));
    Console.WriteLine(o1.GetHashCode() == o2.GetHashCode());
    Console.WriteLine(new Animal("x").Equals(new Animal("x")));
    Console.WriteLine(o1);

    // enums
    Color c = Color.Azul;
    Console.WriteLine(c.ToString() + " " + Color.Verde.ToString() + " " + ((Color)42).ToString());
    Color leido;
    if (Enum.Parse<Color>("Verde", out leido)) Console.WriteLine("leído: " + leido.ToString() + " = " + (int)leido);
    Console.WriteLine(Enum.TryParse<Color>("Morado", out leido));
    Console.WriteLine(Enum.Parse<Color>("Rojo").ToString());
    List<string> nombres = Enum.GetNames<Color>();
    for (int i = 0; i < nombres.Count; i++) Console.Write(nombres[i] + " ");
    Console.WriteLine();
    List<Color> valores = Enum.GetValues<Color>();
    for (int i = 0; i < valores.Count; i++) Console.Write((int)valores[i] + " ");
    Console.WriteLine();
    Console.WriteLine(Enum.Count<Color>() + " " + Enum.IsDefined<Color>("Azul") + " " + Enum.GetName(Color.Rojo));
}
