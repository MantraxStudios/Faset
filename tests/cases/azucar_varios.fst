// Extras: using (destructor al salir del ámbito, también con return/break/continue), nameof,
// literal 'default', constantes locales, separadores de dígitos y literales binarios,
// y 'params T[]' sin importar std.collections.
class Recurso
{
    string nombre;
    public Recurso(string n) { nombre = n; println("abre " + n); }
    ~Recurso() { println("cierra " + nombre); }
    public void Usar() { println("usa " + nombre); }
}

int Contar(params int[] xs) => xs.Count;

int ConReturn(bool pronto)
{
    using var r = new Recurso("ret");
    if (pronto) return 1;
    r.Usar();
    return 2;
}

struct Config
{
    public int Ancho;
    public string Titulo;
}

void main()
{
    {
        using var a = new Recurso("a");
        using var b = new Recurso("b");
        a.Usar();
        println("fin del bloque");
    }
    using (Recurso c = new Recurso("c"))
    {
        c.Usar();
    }
    using (new Recurso("anónimo")) println("dentro");
    println(ConReturn(true));
    println(ConReturn(false));
    for (int i = 0; i < 3; i++)
    {
        using var it = new Recurso("vuelta" + i);
        if (i == 0) continue;
        if (i == 1) break;
    }
    Recurso nulo = null;
    using (nulo) println("using con null no falla");

    // nameof
    int cantidad = 3;
    println(nameof(cantidad) + " " + nameof(Recurso) + " " + nameof(Config.Titulo) + " " + nameof(Contar));

    // default con tipo por el destino
    int cero = default;
    string vacia = default;
    Config cfg = default;
    double? sinValor = default;
    println(cero + "|" + vacia + "|" + cfg.Ancho + "|" + (sinValor ?? -1));
    println(cero == default);

    // constantes locales, separadores y binarios
    const int Limite = 1_000_000;
    const long Grande = 0x_FFFF_FFFF;
    println(Limite + " " + Grande + " " + 0b1010 + " " + 0b_1111_0000 + " " + 1_234.5_6);

    println(Contar() + Contar(1, 2, 3));
}
