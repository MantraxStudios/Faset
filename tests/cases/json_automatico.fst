// JSON automático: Json.Serialize / Json.Deserialize<T> generan al compilar el código de cada
// tipo (clases, structs, registros, herencia, List, Dictionary, HashSet, T?, enums por nombre,
// objetos anidados), con [JsonName], [JsonIgnore], JsonOptions y errores con línea y columna.
using std.collections;
using std.json;

enum Color { Rojo, Verde, Azul }

class Direccion
{
    public string Calle = "";
    public int Numero;
}

struct Medida
{
    public double Valor;
    public string Unidad;
}

record Punto(int X, int Y);

class Base
{
    public int Id;
}

class Persona : Base
{
    public string Nombre = "";
    public int Edad;
    [JsonName("correo_e")] public string Email = "";
    [JsonIgnore] public string Clave = "secreta";
    public double Altura { get; set; }
    public Color Favorito;
    public int? Hijos;
    public List<string> Etiquetas = new List<string>();
    public Dictionary<string, int> Notas = new Dictionary<string, int>();
    public Direccion Casa;
    public Medida Peso;
    public bool Activo;
    public char Inicial = 'ñ';
    public Persona Pareja;
    public int Calculada => Edad * 2;   // solo lectura: se escribe pero no se lee
}

void Main()
{
    Persona p = new Persona();
    p.Id = 1;
    p.Nombre = "Ana \"la\" Pérez\n";
    p.Edad = 30;
    p.Email = "ana@ejemplo.es";
    p.Altura = 1.72;
    p.Favorito = Color.Verde;
    p.Etiquetas.Add("a");
    p.Etiquetas.Add("b");
    p.Notas["mates"] = 9;
    p.Casa = new Direccion();
    p.Casa.Calle = "Mayor";
    p.Casa.Numero = 3;
    p.Peso.Valor = 61.5;
    p.Peso.Unidad = "kg";
    string s = Json.Serialize(p);
    Console.WriteLine(s);

    JsonOptions o = new JsonOptions();
    o.Indented = true;
    o.CamelCase = true;
    o.IgnoreNull = true;
    string bonito = Json.Serialize(p, o);
    Console.WriteLine(bonito);

    // Ida y vuelta.
    Persona q = Json.Deserialize<Persona>(s);
    Console.WriteLine(Json.Serialize(q) == s);
    Console.WriteLine($"{q.Nombre.Trim()} {q.Casa.Calle} {q.Peso.Unidad} {q.Clave} {q.Hijos == null}");
    Persona r = Json.Deserialize<Persona>(bonito, o);
    Console.WriteLine(Json.Serialize(r) == s);

    // Colecciones en la raíz, anidadas y con claves numéricas.
    List<List<int>> ll = Json.Deserialize<List<List<int>>>("[[1, 2], [], [3]]");
    Console.WriteLine(Json.Serialize(ll));
    Dictionary<int, string> d = Json.Deserialize<Dictionary<int, string>>("{\"1\": \"uno\", \"2\": \"dos\"}");
    Console.WriteLine(d[2] + " " + Json.Serialize(d));
    HashSet<string> hs = new HashSet<string>();
    hs.Add("x");
    Console.WriteLine(Json.Serialize(hs));
    Console.WriteLine(Json.Serialize(new Punto(1, 2)));
    Medida? sin = null;
    Console.WriteLine(Json.Serialize(sin));
    Medida? m = Json.Deserialize<Medida?>("{\"Valor\": 1e3, \"Unidad\": \"g\\u00e9\\ud83d\\ude00\", \"Extra\": [1, {\"a\": null}]}");
    Console.WriteLine($"{m.Value.Valor} {m.Value.Unidad}");
    Console.WriteLine(Json.Serialize(long.MaxValue) + " " + Json.Serialize(ulong.MaxValue) + " " + Json.Serialize((byte)200));
    Console.WriteLine(Json.Deserialize<Color>("\"Azul\"").ToString() + " " + Json.Deserialize<Color>("0").ToString());
    JsonOptions ci = new JsonOptions();
    ci.CaseInsensitive = true;
    Console.WriteLine(Json.Deserialize<Direccion>("{\"CALLE\": \"Sol\"}", ci).Calle);

    // Errores: JsonException (una FormatException) con línea y columna.
    try { Json.Deserialize<Persona>("{\n  \"Edad\": \"treinta\"\n}"); }
    catch (JsonException e) { Console.WriteLine($"{e.Line}:{e.Column} {e.Message}"); }
    try { Json.Deserialize<Persona>("{\"Edad\": 1,}"); }
    catch (FormatException e) { Console.WriteLine(e.Message); }
    try { Json.Deserialize<Persona>("{\"Favorito\": \"Negro\"}"); }
    catch (JsonException e) { Console.WriteLine(e.Message); }
    try { Json.Deserialize<byte>("300"); }
    catch (JsonException e) { Console.WriteLine(e.Message); }
    try { Json.Deserialize<int>("1.5"); }
    catch (JsonException e) { Console.WriteLine(e.Message); }
    try { Json.Deserialize<int>("1 2"); }
    catch (JsonException e) { Console.WriteLine(e.Message); }
    try { Json.Deserialize<string>("\"abc"); }
    catch (JsonException e) { Console.WriteLine(e.Message); }
    try { Json.Deserialize<List<int>>("[1,\n2"); }
    catch (JsonException e) { Console.WriteLine(e.Message); }
    Persona ciclo = new Persona();
    ciclo.Pareja = ciclo;
    try { Json.Serialize(ciclo); }
    catch (InvalidOperationException e) { Console.WriteLine(e.Message); }
}
