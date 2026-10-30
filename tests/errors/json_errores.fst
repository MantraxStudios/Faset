// Json.Serialize / Deserialize: los tipos que no se pueden leer o escribir se detectan al compilar
// (static_assert en el código generado, con la cadena "requerido por" hasta esta llamada).
using std.json;

// Dos constructores con parámetros y ninguno vacío: no se sabe cuál usar al leer.
class Punto
{
    public int X;
    public Punto(int x) { X = x; }
    public Punto(int x, int y) { X = x + y; }
}
class ConFuncion { public Func<int, int> F; }

void Main()
{
    Punto p = Json.Deserialize<Punto>("{}");
    string s = Json.Serialize(new ConFuncion());
}
