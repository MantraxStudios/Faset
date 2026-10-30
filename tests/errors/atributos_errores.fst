// Errores de atributos: destino no permitido ([AttributeUsage]), repetidos, desconocidos, clases
// que no derivan de Attribute, argumentos que no encajan, [Obsolete(..., true)] y [Conditional].
[AttributeUsage(AttributeTargets.Field)]
class SoloCampo : Attribute { }

class Rango : Attribute
{
    public int Min;
    public Rango(int m) { Min = m; }
}

class NoEsAtributo { }

[SoloCampo] class Mal { }

class Otra
{
    [SoloCampo] public int A;
    [Rango(1)] [Rango(2)] public int B;
    [Desconocido] public int C;
    [Rango("x")] public int D;
    [Rango(1, Max = 3)] public int E;
    [NoEsAtributo] public int F;
    [SoloCampo] public void G() { }
    [Export] public int H;
}

[Obsolete("ya no existe", true)] void Prohibido() { }
[Conditional("DEBUG")] int NoVoid() => 1;

void Main()
{
    Prohibido();
}
