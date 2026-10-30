// Atributos de usuario: clases que derivan de Attribute, con argumentos del constructor y
// propiedades con nombre evaluados al compilar; [AttributeUsage]; lectura con la reflexión de
// tiempo de compilación; a.Crear() para tenerlos al ejecutar; [Obsolete] (aviso), [Conditional]
// y [CallerArgumentExpression].
using std.collections;

[AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
class Rango : Attribute
{
    public int Min, Max;
    public string Mensaje = "fuera de rango";
    public Rango(int min, int max)
    {
        Min = min;
        Max = max;
    }
}

[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = true)]
class EtiquetaAttribute : Attribute
{
    public string Texto;
    public EtiquetaAttribute(string texto) { Texto = texto; }
}

class Descripcion : Attribute
{
    public string Texto;
    public Descripcion(string t) { Texto = t; }
}

const int EdadMaxima = 150;

[Etiqueta("modelo")]
[Etiqueta("persona")]
class Persona
{
    public string Nombre = "";
    [Rango(0, EdadMaxima, Mensaje = "edad no válida")] public int Edad;
    [Rango(1, 300)] public int Altura { get; set; }

    [Etiqueta("accion")] public void Saludar([Descripcion("a quién")] string otro) { Console.WriteLine("hola " + otro); }
}

// Validación genérica: el compilador genera un 'if' por cada miembro con [Rango].
List<string> Validar<T>(T obj)
{
    List<string> errores = new List<string>();
    comptime foreach (var f in Tipo<T>.Miembros)
    {
        comptime if (f.TieneAtributo<Rango>())
        {
            comptime var r = f.Atributo<Rango>();
            if (f.Get(obj) < r.Min || f.Get(obj) > r.Max)
                errores.Add($"{f.Nombre}: {r.Mensaje} ({f.Get(obj)} no está entre {r.Min} y {r.Max})");
        }
    }
    return errores;
}

[Obsolete("usa Nuevo")] int Viejo() => 1;
[Conditional("NO_DEFINIDO")] void Traza(string s) { Console.WriteLine("traza: " + s); }
[Conditional("DEBUG")] void Depurar(string s) { Console.WriteLine("depurar: " + s); }

int efectos = 0;
string ConEfecto()
{
    efectos++;
    return "x";
}

void Comprobar(bool cond, [CallerArgumentExpression("cond")] string texto = "")
{
    Console.WriteLine((cond ? "ok: " : "falló: ") + texto);
}

void Main()
{
    Persona p = new Persona();
    p.Nombre = "Ana";
    p.Edad = 200;
    p.Altura = 170;
    foreach (string e in Validar(p)) Console.WriteLine(e);
    p.Edad = 30;
    Console.WriteLine(Validar(p).Count);

    // Atributos de la clase, de un método y de un parámetro.
    comptime foreach (var a in Tipo<Persona>.AtributosDe<EtiquetaAttribute>()) Console.WriteLine("clase: " + a.Texto);
    comptime foreach (var m in Tipo<Persona>.Metodos)
    {
        comptime foreach (var a in m.Atributos) comptime if (a is EtiquetaAttribute) Console.WriteLine($"método {m.Nombre}: {a.Texto}");
        comptime foreach (var prm in m.Parametros)
            comptime if (prm.TieneAtributo<Descripcion>()) Console.WriteLine($"parámetro {prm.Nombre}: {prm.Atributo<Descripcion>().Texto}");
    }

    // El atributo como objeto al ejecutar.
    comptime foreach (var f in Tipo<Persona>.Miembros)
    {
        comptime foreach (var a in f.Atributos)
        {
            Attribute obj = a.Crear();
            Rango r = obj as Rango;
            Console.WriteLine($"{f.Nombre}: {obj.AttributeName()} {r.Min}..{r.Max} '{r.Mensaje}'");
        }
    }

    Console.WriteLine(Viejo());
    Traza(ConEfecto());   // desaparece: no se evalúa ConEfecto()
    Depurar(ConEfecto());
    Console.WriteLine(efectos);
    int x = 3;
    Comprobar(x > 5);
    Comprobar(x * 2 == 6 && p.Nombre == "Ana");
    Console.WriteLine(nameof(Persona.Edad) + " " + nameof(Validar));
}
