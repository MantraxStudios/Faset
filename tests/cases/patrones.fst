// switch sobre cadenas, switch de expresión, patrones (constante, relacional, and/or/not,
// null, _, var, propiedades, posicionales), guardas 'when' y 'is' con patrones.
enum Dia { Lunes, Martes, Sabado, Domingo }

class Persona
{
    public string Nombre;
    public int Edad;
    public Persona Pareja;
    public Persona(string n, int e) { Nombre = n; Edad = e; }
}

string Cantidad(int x) => x switch
{
    0 => "cero",
    1 => "uno",
    2 or 3 => "pocos",
    > 10 and <= 100 => "muchos",
    > 100 => "muchísimos",
    < 0 => "negativo",
    _ => "algunos"
};

string Comando(string s)
{
    switch (s)
    {
        case "abrir":
        case "open":
            return "abriendo";
        case "cerrar":
            return "cerrando";
        default:
            return "¿" + s + "?";
    }
}

string Clasificar(Persona p) => p switch
{
    null => "nadie",
    { Edad: < 18 } => p.Nombre + " es menor",
    { Nombre: "Ana", Edad: var e } => "Ana con " + e,
    { Pareja: { Nombre: var pn } } => p.Nombre + " está con " + pn,
    _ => p.Nombre + " es adulto"
};

string Cuadrante((int, int) pt) => pt switch
{
    (0, 0) => "origen",
    (> 0, > 0) => "primero",
    (< 0, > 0) => "segundo",
    (_, 0) or (0, _) => "eje",
    _ => "otro"
};

double Tarifa(Dia d, int edad) => d switch
{
    Dia.Sabado or Dia.Domingo when edad < 12 => 2.5,
    Dia.Sabado or Dia.Domingo => 5,
    _ => 4
};

int Prioridad(char c)
{
    switch (c)
    {
        case >= 'a' and <= 'z': return 1;
        case >= 'A' and <= 'Z': return 2;
        case var otro when otro >= '0' && otro <= '9': return 3;
        default: return 0;
    }
}

string Semana(Dia d)
{
    // switch clásico sobre enum, con una guarda: se reescribe como cadena de 'if'
    switch (d)
    {
        case Dia.Sabado:
        case Dia.Domingo:
            return "fin de semana";
        case var x when x == Dia.Lunes:
            return "lunes otra vez";
        default:
            return "laborable";
    }
}

void main()
{
    for (int i = -5; i <= 500; i = i < 4 ? i + 1 : i * 7)
        print(i + ":" + Cantidad(i) + " ");
    println();

    println(Comando("abrir") + " " + Comando("open") + " " + Comando("cerrar") + " " + Comando("volar"));

    Persona ana = new Persona("Ana", 30);
    Persona leo = new Persona("Leo", 12);
    Persona eva = new Persona("Eva", 40);
    Persona tom = new Persona("Tom", 50);
    eva.Pareja = tom;
    println(Clasificar(null));
    println(Clasificar(leo));
    println(Clasificar(ana));
    println(Clasificar(eva));
    println(Clasificar(tom));

    println(Cuadrante((0, 0)) + " " + Cuadrante((2, 3)) + " " + Cuadrante((-1, 4)) + " " + Cuadrante((5, 0)) + " " +
            Cuadrante((0, -2)) + " " + Cuadrante((-1, -1)));
    println(Tarifa(Dia.Sabado, 8) + " " + Tarifa(Dia.Domingo, 30) + " " + Tarifa(Dia.Lunes, 8));
    println(Prioridad('q') + " " + Prioridad('Q') + " " + Prioridad('7') + " " + Prioridad('#'));
    println(Semana(Dia.Domingo) + ", " + Semana(Dia.Lunes) + ", " + Semana(Dia.Martes));

    // 'is' con patrones
    int t = 7;
    println(t is > 0 and < 10);
    println(t is 1 or 2);
    println(t is not 7);
    string s = "hola";
    println(s is "hola");
    println(ana is { Edad: >= 18 });
    println(leo is { Edad: >= 18 });
    Persona nadie = null;
    println(nadie is null);
    println(ana is not null);
    int? quizas = 15;
    if (quizas is int valor && valor > 10) println("quizás vale " + valor);
    if (t is var copia) println("copia " + copia);
    println(quizas is > 10);
    quizas = null;
    println(quizas is > 10);
    println(quizas is null);

    // switch de expresión: resultado con null -> T?, y cadenas
    int? codigo = s switch { "hola" => 1, "adiós" => 2, _ => null };
    println(codigo ?? 0);
    string corto = t switch { < 5 => "bajo", _ => "alto" };
    println(corto);
    double mezcla = t switch { 7 => 1, _ => 2.5 };
    println(mezcla);

    // switch sobre cadenas con 'when' y 'break' dentro de un bucle
    int vueltas = 0;
    while (true)
    {
        vueltas++;
        switch (s)
        {
            case "hola" when vueltas < 3:
                println("vuelta " + vueltas);
                break;
            case "hola":
                println("basta");
                break;
        }
        if (vueltas >= 3) break;
    }
}
