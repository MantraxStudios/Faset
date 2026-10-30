// Json.Serialize / Deserialize: los tipos que no se pueden leer o escribir se detectan al compilar
// (static_assert en el código generado, con la cadena "requerido por" hasta esta llamada).
using std.json;

record Punto(int X, int Y);
class ConFuncion { public Func<int, int> F; }

void Main()
{
    Punto p = Json.Deserialize<Punto>("{}");
    string s = Json.Serialize(new ConFuncion());
}
