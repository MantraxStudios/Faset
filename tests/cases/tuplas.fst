// Tuplas: tipos (int, string) y con nombres, literales, retorno desde métodos, deconstrucción,
// intercambio, igualdad, tuplas en colecciones y genéricos, y conversión a texto.
using std.collections;

(int, int) DivMod(int a, int b) => (a / b, a % b);

(string nombre, int edad) Persona() => ("Ana", 30);

(int min, int max) Extremos(List<int> xs)
{
    int lo = xs[0], hi = xs[0];
    foreach (int x in xs)
    {
        if (x < lo) lo = x;
        if (x > hi) hi = x;
    }
    return (lo, hi);
}

(T, T) Par<T>(T a) => (a, a);

U Segundo<T, U>((T, U) t) => t.Item2;

struct Rect
{
    public (int x, int y) Origen;
    public (int ancho, int alto) Tam;
    public int Area => Tam.ancho * Tam.alto;
}

void main()
{
    (int, string) t = (1, "a");
    println(t.Item1 + " " + t.Item2);
    var u = (x: 3, y: 4);
    println(u.x * u.x + u.y * u.y);
    (int x, int y) punto = (5, 6);
    println(punto.x + punto.Item2);
    punto.x = 50;
    println(punto.Item1);

    // Retorno de tuplas y deconstrucción
    var (cociente, resto) = DivMod(17, 5);
    println(cociente + " " + resto);
    (string nombre, int edad) = Persona();
    println(nombre + " tiene " + edad);
    var p = Persona();
    println(p.nombre + "/" + p.edad);
    (var q, var r) = DivMod(9, 4);
    println(q + r);
    var (_, soloResto) = DivMod(10, 3);
    println(soloResto);

    // Intercambio y asignación por deconstrucción
    int a = 1, b = 2;
    (a, b) = (b, a);
    println(a + " " + b);
    int c = 0;
    (a, b, c) = (c, a, b);
    println(a + " " + b + " " + c);

    // Igualdad
    println((1, "a") == (1, "a"));
    println((1, "a") == (1, "b"));
    println(t != (1, "a"));
    println(DivMod(7, 2) == (3, 1));

    // Conversión de elementos con el tipo de destino
    (long, double) ancha = (1, 2);
    println(ancha.Item1 + ancha.Item2);

    // Nombres deducidos de las variables
    int ancho = 8, alto = 3;
    var dims = (ancho, alto);
    println(dims.ancho * dims.alto);

    // Tuplas en colecciones y genéricos
    List<(string, int)> notas = new List<(string, int)>();
    notas.Add(("Ana", 9));
    notas.Add(("Luis", 7));
    foreach (var (quien, nota) in notas) println(quien + ": " + nota);
    var mm = Extremos(notas.Select<int>(&NotaDe));
    println(mm.min + ".." + mm.max);
    var par = Par<string>("eco");
    println(par.Item1 + par.Item2);
    println(Segundo<int, string>((1, "dos")));
    Dictionary<string, (int, int)> pos = new Dictionary<string, (int, int)>();
    pos["torre"] = (0, 7);
    println(pos["torre"].Item2);

    // Campos de tupla en structs y tuplas anidadas
    Rect rect = new Rect();
    rect.Tam = (4, 5);
    println(rect.Area);
    var anidada = (1, (2, 3));
    println(anidada.Item2.Item2);

    // Texto: (1, a)
    println($"{t}");
    println($"{punto} {anidada} {(true, 'x', 2.5)}");
    println("tupla: " + DivMod(7, 2));
}

int NotaDe((string, int) n) => n.Item2;
