// Operadores de null: ?? ??= ?. ?[] y tipos por valor anulables (int?, double?, struct?).
using std.collections;

class Nodo
{
    public int Valor;
    public Nodo Siguiente;
    public string Nombre = "nodo";
    public Nodo(int v) { Valor = v; }
    public int Doble() => Valor * 2;
    public void Saludar() { println("hola desde " + Valor); }
    public Nodo Hijo => Siguiente;
}

struct Punto
{
    public int X;
    public int Y;
    public Punto(int x, int y) { X = x; Y = y; }
}

int? Buscar(List<int> xs, int objetivo)
{
    for (int i = 0; i < xs.Count; i++)
        if (xs[i] == objetivo) return i;
    return null;
}

double? Media(List<int> xs)
{
    if (xs.Count == 0) return null;
    double s = 0;
    foreach (int x in xs) s += x;
    return s / xs.Count;
}

void Mostrar(int? v) { println(v.HasValue ? "valor " + v.Value : "sin valor"); }

void main()
{
    // ?? con clases
    Nodo a = new Nodo(1);
    Nodo nada = null;
    println((nada ?? a).Valor);
    println((a ?? nada).Valor);
    Nodo b = nada ?? nada ?? new Nodo(3);
    println(b.Valor);

    // ?. y ?[] con resultado null o con valor (int?)
    a.Siguiente = new Nodo(2);
    int? v1 = a?.Valor;
    int? v2 = nada?.Valor;
    println(v1 ?? -1);
    println(v2 ?? -1);
    println(a.Siguiente?.Siguiente?.Valor ?? -1);
    println(a?.Siguiente?.Valor ?? -1);
    println(a?.Hijo?.Doble() ?? -1);
    println(nada?.Hijo?.Doble() ?? -1);
    println(a?.Nombre.Length ?? 0);
    println(nada?.Nombre ?? "(sin nombre)");
    a?.Saludar();
    nada?.Saludar();
    List<int> lista = new List<int>();
    lista.Add(7);
    List<int> sinLista = null;
    println(lista?[0] ?? 0);
    println(sinLista?[0] ?? 0);
    println(sinLista?.Count ?? 0);

    // ??= con clases y con T?
    Nodo c = null;
    c ??= new Nodo(10);
    c ??= new Nodo(20);
    println(c.Valor);
    int? cache = null;
    cache ??= 5;
    cache ??= 6;
    println(cache.Value);

    // int?: conversiones, comparaciones, HasValue, GetValueOrDefault
    int? n = null;
    println(n == null);
    println(n != null);
    println(n.HasValue);
    println(n.GetValueOrDefault());
    println(n.GetValueOrDefault(99));
    n = 4;
    println(n == null);
    println(n == 4);
    println(n != 4);
    println(n > 3);
    println(n < 3);
    println(4 == n);
    int? m = 4;
    println(n == m);
    m = null;
    println(n == m);
    int? o = null;
    println(m == o);
    long? largo = 7;  // int -> long?
    println(largo ?? 0);
    Mostrar(3);
    Mostrar(null);
    Mostrar(n);

    // Métodos que devuelven T?
    lista.Add(9);
    lista.Add(11);
    int? pos = Buscar(lista, 9);
    if (pos != null) println("9 está en " + pos.Value);
    println(Buscar(lista, 100) == null);
    println(Media(lista) ?? 0.0);
    println(Media(new List<int>()) ?? 0.0);

    // T? de structs, cadenas y bool
    Punto? p = null;
    println(p.HasValue);
    p = new Punto(1, 2);
    println(p?.X ?? 0);
    string? texto = null;
    println(texto ?? "vacío");
    texto = "lleno";
    println(texto ?? "vacío");
    bool? bandera = null;
    println(bandera ?? false);

    // T? en interpolación y concatenación: vacío si no hay valor
    int? sinValor = null;
    println($"[{n}] [{sinValor}] [{Media(lista):F1}]");
    println("concat: " + n + "|" + sinValor + "|");

    // T? en colecciones
    List<int?> opcionales = new List<int?>();
    opcionales.Add(1);
    opcionales.Add(null);
    opcionales.Add(3);
    int sumaOpc = 0;
    foreach (int? x in opcionales) sumaOpc += x ?? 100;
    println(sumaOpc);
}
