// Recorrido por la sintaxis mixta C# / C++ y la biblioteca estándar.
// Ejecuta:  faset run examples/mixto.fst

using namespace std::collections;
using std.text;
using Texto = std.text.Text;

namespace Juego::Modelo
{
    struct Punto
    {
        int X, Y;
        Punto(int x, int y) { X = x; Y = y; }
        static Punto operator +(Punto a, Punto b) => new Punto(a.X + b.X, a.Y + b.Y);
        static bool operator ==(Punto a, Punto b) => a.X == b.X && a.Y == b.Y;
        static bool operator <(Punto a, Punto b) => a.X < b.X || (a.X == b.X && a.Y < b.Y);
        int Manhattan => Math::Abs(X) + Math::Abs(Y);
    }

    class Inventario
    {
    public:
        Inventario() { }
        ~Inventario() { delete items; }
        void Agregar(string nombre, int cantidad) { items[nombre] += cantidad; }
        int Cantidad(string nombre) => items.GetOrDefault(nombre, 0);
        int Total => items.Count;
    private:
        Dictionary<string, int> items = new Dictionary<string, int>();
    }
}

// Funciones y variables globales (estilo C++)
int contadorGlobal = 0;

void Incrementar(int& x) { x++; contadorGlobal++; }

T Mayor<T>(T a, T b) => a < b ? b : a;

int CompararDesc(int a, int b) => b - a;
bool EsPar(int x) => x % 2 == 0;
int AlCuadrado(int x) => x * x;

static class Extensiones
{
    public static int Doble(this int x) => x * 2;
}

int main()
{
    using_test();
    return 0;
}

void using_test()
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
    auto lista = new List<int>();
    for (int i = 10; i > 0; i--) lista.Add(i);
    lista[0] = 100;
    lista.Sort();
    println(lista[0]);
    println(lista.Last());
    println(lista.Sum());
    lista.Sort(&CompararDesc);
    println(lista.First());
    auto pares = lista.Where(&EsPar);
    println(pares.Count);
    auto cuadrados = pares.Select<int>(&AlCuadrado);
    println(cuadrados.Max());
    delete lista; delete pares; delete cuadrados;

    // structs con operadores, namespaces con ::
    Juego::Modelo::Punto p = new Juego::Modelo::Punto(1, 2) + new Juego.Modelo.Punto(3, -7);
    println(p.X);
    println(p.Manhattan);
    println(p == new Juego::Modelo::Punto(4, -5));
    println(p != new Juego::Modelo::Punto(4, -5));
    auto puntos = new List<Juego::Modelo::Punto>();
    puntos.Add(new Juego::Modelo::Punto(3, 1));
    puntos.Add(new Juego::Modelo::Punto(1, 9));
    puntos.Add(new Juego::Modelo::Punto(1, 2));
    puntos.Sort();
    println(puntos[0].Y);
    println(puntos.Contains(new Juego::Modelo::Punto(3, 1)));
    delete puntos;

    // Dictionary + clase con secciones public:/private:
    auto inv = new Juego::Modelo::Inventario();
    inv.Agregar("espada", 1);
    inv.Agregar("poción", 3);
    inv.Agregar("poción", 2);
    println(inv.Cantidad("poción"));
    println(inv.Cantidad("escudo"));
    println(inv.Total);
    delete inv;

    // texto
    auto sb = new StringBuilder();
    sb.Append("x=").Append(42).Append(", y=").Append(1.5).Append(' ').Append('ñ');
    println(sb.View());
    delete sb;
    auto partes = Texto.Split("uno,dos,,tres", ",");
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
    auto set = new HashSet<string>();
    set.Add("a"); set.Add("b"); set.Add("a");
    println(set.Count);
    delete set;
    auto pila = new Stack<char>();
    pila.Push('x'); pila.Push('y');
    println(pila.Pop());
    delete pila;
    auto cola = new Queue<long>();
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
