// Json.Deserialize con un constructor con parámetros (records posicionales, clases y structs):
// cada parámetro recibe el miembro de su nombre y los demás miembros escribibles se asignan después.
using std;
using std.collections;
using std.json;

public record Punto(int X, int Y);
public record Persona(string Nombre, int Edad, List<Punto> Lugares)
{
    public string Nota { get; set; } = "sin nota";
}
public class Caja
{
    public Caja(int ancho, string etiqueta) { Ancho = ancho; Etiqueta = etiqueta + "!"; }
    public int Ancho { get; private set; }
    public string Etiqueta { get; private set; }
    [JsonName("color")] public string Color { get; set; }
}
public struct Par
{
    public Par(int a, int b) { A = a; B = b; }
    public int A;
    public int B;
}

class Program
{
    static void Main()
    {
        var p = Json.Deserialize<Punto>("{\"X\": 3, \"Y\": -4, \"z\": 9}");
        Console.WriteLine($"{p.X} {p.Y}");
        var q = Json.Deserialize<Persona>("{\"Nota\": \"hola\", \"Nombre\": \"Ana\", \"Lugares\": [{\"X\":1,\"Y\":2}]}");
        Console.WriteLine($"{q.Nombre} {q.Edad} {q.Lugares.Count} {q.Lugares[0].Y} {q.Nota}");
        Console.WriteLine(Json.Serialize(q));
        var q2 = Json.Deserialize<Persona>(Json.Serialize(q));
        Console.WriteLine(q2.Nombre == q.Nombre && q2.Nota == q.Nota && q2.Lugares[0] == q.Lugares[0]);
        var c = Json.Deserialize<Caja>("{\"ancho\": 5, \"ETIQUETA\": \"x\", \"color\": \"rojo\"}", new JsonOptions { CaseInsensitive = true });
        Console.WriteLine($"{c.Ancho} {c.Etiqueta} {c.Color}");
        var par = Json.Deserialize<Par>("{\"A\": 1, \"B\": 2}");
        Console.WriteLine(par.A + par.B);
        Console.WriteLine(Json.Deserialize<Punto>("null") == null);
        var lista = Json.Deserialize<List<Punto>>("[{\"X\":1},{\"Y\":5}]");
        Console.WriteLine($"{lista[0]} {lista[1]}");
    }
}
