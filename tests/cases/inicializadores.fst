// Inicializadores de objeto (también anidados), de colección (cualquier tipo con Add), con
// índice, accesores 'init' y miembros 'required'.
using std.collections;

class Direccion
{
    public string Calle = "";
    public int Numero;
}

class Persona
{
    public string Nombre { get; set; } = "";
    public int Edad;
    public Direccion Dir = new Direccion();
    public List<string> Tags = new List<string>();
    public Persona() { println("new Persona"); }
    public Persona(string n) { Nombre = n; }
    public override string ToString() => $"{Nombre} ({Edad}) en {Dir.Calle} {Dir.Numero} [{Tags.Count}]";
}

struct Punto
{
    public int X;
    public int Y;
}

class Bolsa
{
    public List<int> Items = new List<int>();
    public void Add(int a) => Items.Add(a);
    public void Add(int a, int b) { Items.Add(a * b); }
}

record Config
{
    public string Nombre { get; init; } = "x";
    public required int Ancho { get; init; }
}

class Usuario
{
    public required string Login;
    public string Correo { get; init; } = "";
    public Usuario() { Correo = "ninguno"; }  // en el constructor también se puede asignar
}

class Cuenta
{
    public required string Titular { get; set; }
    public double Saldo;
    [SetsRequiredMembers]
    public Cuenta(string t) { Titular = t; }
    public Cuenta() { }
}

int Orden(string que, int v) { println("evalúa " + que); return v; }

void main()
{
    var p = new Persona { Nombre = "Ana", Edad = 3 };
    println(p.ToString());
    var q = new Persona("Luis") { Dir = { Calle = "Mayor", Numero = 5 }, Tags = { "a", "b" } };
    println(q.ToString());
    var pt = new Punto { X = 1, Y = 2 };
    println($"{pt.X},{pt.Y}");
    var l = new List<int> { 1, 2, 3 };
    println(l.Count);
    var dic = new Dictionary<string, int> { ["a"] = 1, { "b", 2 } };
    println(dic["a"] + dic["b"]);
    var b = new Bolsa { 1, { 2, 3 }, 4 };
    foreach (int x in b.Items) print($"{x} ");
    println("");
    var c = new Config { Ancho = 10 };
    println(c.Nombre + " " + c.Ancho);
    var c2 = c with { Nombre = "y" };
    println(c2.Nombre + " " + c2.Ancho);
    var u = new Usuario { Login = "ana" };
    println(u.Login + " " + u.Correo);
    var u2 = new Usuario { Login = "bea", Correo = "b@x" };
    println(u2.Correo);
    var cu = new Cuenta("Eva");
    var cu2 = new Cuenta { Titular = "Teo", Saldo = 5 };
    println(cu.Titular + " " + cu2.Titular + " " + cu2.Saldo);
    var lista = new List<Persona> { new Persona("A") { Edad = 1 }, new Persona("B") };
    println(lista[0].Edad + lista[1].Nombre);
    var matriz = new List<List<int>> { new List<int> { 1, 2 }, new List<int> { 3 } };
    println(matriz[0].Count + matriz[1][0]);
    // Los valores se evalúan en orden, después de crear el objeto.
    var pp = new Punto { Y = Orden("Y", 2), X = Orden("X", 1) };
    println(pp.X * 10 + pp.Y);
}
