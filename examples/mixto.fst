// Recorrido por la sintaxis mixta C# / C++ y la biblioteca estándar.
// Ejecuta:  faset run examples/mixto.fst

using namespace std::collections;
using std.text;
using Texto = std.text.Text;

namespace Juego::Modelo
{
    struct Punto
    {
        var X: int, Y: int;
        init(x: int, y: int) { X = x; Y = y; }
        operator +(a: Punto, b: Punto) -> Punto => new Punto(a.X + b.X, a.Y + b.Y);
        operator ==(a: Punto, b: Punto) -> bool => a.X == b.X && a.Y == b.Y;
        operator <(a: Punto, b: Punto) -> bool => a.X < b.X || (a.X == b.X && a.Y < b.Y);
        prop Manhattan: int => Math::Abs(X) + Math::Abs(Y);
    }

    class Inventario
    {
    public:
        init() { }
        deinit { delete items; }
        func Agregar(nombre: string, cantidad: int) { items[nombre] += cantidad; }
        func Cantidad(nombre: string) -> int => items.GetOrDefault(nombre, 0);
        prop Total: int => items.Count;
    private:
        var items: Dictionary<string, int> = new Dictionary<string, int>();
    }
}

// Funciones y variables globales (estilo C++)
int contadorGlobal = 0;

void Incrementar(int& x) { x++; contadorGlobal++; }

func Mayor<T>(a: T, b: T) -> T => a < b ? b : a;

func CompararDesc(a: int, b: int) -> int => b - a;
func EsPar(x: int) -> bool => x % 2 == 0;
func AlCuadrado(x: int) -> int => x * x;

static class Extensiones
{
    public static func Doble(this x: int) -> int => x * 2;
}

func main() -> int
{
    using_test();
    return 0;
}

func using_test()
{
    // referencias
    int a = 5;
    Incrementar(a);
    Incrementar(ref a);
    int& r = a;
    r += 10;
    println(a);
    println(contadorGlobal);

    // plantillas
    println(Mayor(3, 9));
    println(Mayor<double>(2.5, 1.5));
    println(Mayor("abc", "abd") == "abd");

    // List<T> con operator[] por referencia, lambdas vía punteros a función
    var lista = new List<int>();
    for (int i = 10; i > 0; i--) lista.Add(i);
    lista[0] = 100;
    lista.Sort();
    println(lista[0]);
    println(lista.Last());
    println(lista.Sum());
    lista.Sort(&CompararDesc);
    println(lista.First());
    var pares = lista.Where(&EsPar);
    println(pares.Count);
    var cuadrados = pares.Select<int>(&AlCuadrado);
    println(cuadrados.Max());
    delete lista; delete pares; delete cuadrados;

    // structs con operadores, namespaces con ::
    Juego::Modelo::Punto p = new Juego::Modelo::Punto(1, 2) + new Juego.Modelo.Punto(3, -7);
    println(p.X);
    println(p.Manhattan);
    println(p == new Juego::Modelo::Punto(4, -5));
    println(p != new Juego::Modelo::Punto(4, -5));
    var puntos = new List<Juego::Modelo::Punto>();
    puntos.Add(new Juego::Modelo::Punto(3, 1));
    puntos.Add(new Juego::Modelo::Punto(1, 9));
    puntos.Add(new Juego::Modelo::Punto(1, 2));
    puntos.Sort();
    println(puntos[0].Y);
    println(puntos.Contains(new Juego::Modelo::Punto(3, 1)));
    delete puntos;

    // Dictionary + clase con secciones public:/private:
    var inv = new Juego::Modelo::Inventario();
    inv.Agregar("espada", 1);
    inv.Agregar("poción", 3);
    inv.Agregar("poción", 2);
    println(inv.Cantidad("poción"));
    println(inv.Cantidad("escudo"));
    println(inv.Total);
    delete inv;

    // texto
    var sb = new StringBuilder();
    sb.Append("x=").Append(42).Append(", y=").Append(1.5).Append(' ').Append('ñ');
    println(sb.View());
    delete sb;
    var partes = Texto.Split("uno,dos,,tres", ",");
    println(partes.Count);
    string unido = Text.Join(partes, " | ");
    println(unido);
    String.Free(unido);
    delete partes;
    string s = "  Hola Mundo  ";
    println(s.Trim());
    println(s.Trim().ToUpper());
    println(s.Contains("Mundo"));
    println(s.Trim().StartsWith("Hola"));
    println("42".ToInt() + 1);
    println(7.Doble());

    // HashSet, Stack, Queue
    var set = new HashSet<string>();
    set.Add("a"); set.Add("b"); set.Add("a");
    println(set.Count);
    delete set;
    var pila = new Stack<char>();
    pila.Push('x'); pila.Push('y');
    println(pila.Pop());
    delete pila;
    var cola = new Queue<long>();
    for (long i = 0; i < 20; i++) cola.Enqueue(i);
    for (int i = 0; i < 5; i++) cola.Dequeue();
    println(cola.Peek());
    delete cola;

    // puntero a función como variable
    delegate*<int, int, int> f = &CompararDesc;
    println(f(1, 10));
    println(Math::Gcd(84, 36));
    println(nullptr == null);
}
