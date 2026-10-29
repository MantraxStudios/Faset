// Lambdas, cierres y conversión de grupos de métodos a delegados.
using std.collections;

delegate int Operacion(int a, int b);
delegate bool Filtro<T>(T valor);

int Doble(int x) => x * 2;
static int Triple(int x) => x * 3;
void Saludar(string s) { println("hola " + s); }

// Un cierre que sobrevive al método que lo creó.
Func<int> NuevoContador()
{
    int n = 0;
    return () => { n++; return n; };
}

// Dos cierres que comparten la misma variable.
class Par
{
    public Func<int> Leer;
    public Action<int> Sumar;
}

Par Compartido()
{
    int valor = 10;
    var p = new Par();
    p.Leer = () => valor;
    p.Sumar = d => valor += d;
    return p;
}

class Cuenta
{
    public string Titular;
    public int Saldo;
    public Cuenta(string t, int s) { Titular = t; Saldo = s; }
    public void Depositar(int x) { Saldo += x; }
    public int Consultar() => Saldo;
    // 'this' capturado (explícito e implícito)
    public Action<int> Depositador() => x => Depositar(x);
    public Func<string> Resumen() => () => Titular + ": " + this.Saldo;
}

struct Vector2
{
    public int X;
    public int Y;
    public int Suma() => X + Y;
}

T Aplicar<T>(T x, Func<T, T> f) => f(x);
R Transformar<T, R>(T x, Func<T, R> f) => f(x);
U Componer<T, R, U>(T x, Func<T, R> f, Func<R, U> g) => g(f(x));

int Usar(Operacion op) => op(6, 7);

int main()
{
    // Formas de escribir una lambda
    Func<int, int> inc = x => x + 1;
    Func<int, int, int> suma = (a, b) => a + b;
    Func<int> cuarenta = () => 40;
    Func<int, int> cuadrado = (int x) => x * x;
    Func<int, string> bloque = x => {
        if (x < 0) return "negativo";
        return "no negativo";
    };
    Action vacia = () => { };
    vacia();
    println(inc(41));
    println(suma(2, 3));
    println(cuarenta() + 2);
    println(cuadrado(9));
    println(bloque(-1) + " " + bloque(3));
    println(inc.Invoke(9));

    // Tipo natural con 'var' (parámetros tipados) y conversión explícita
    var mult = (int a, int b) => a * b;
    println(mult(6, 7));
    var mitad = (double d) => d / 2;
    println(mitad(5));
    var conv = (Func<int, long>)(x => (long)x * 1000000000);
    println(conv(5));

    // Grupos de métodos -> delegado
    Func<int, int> f = Doble;
    println(f(21));
    f = Triple;
    println(f(5));
    Action<string> s = Saludar;
    s("mundo");
    var g = Doble;
    println(g(8));
    var cuenta = new Cuenta("Ana", 100);
    Action<int> dep = cuenta.Depositar;
    dep(50);
    Func<int> consulta = cuenta.Consultar;
    println(consulta());
    // Un struct se copia al convertir su método en delegado (como en C#)
    var v = new Vector2();
    v.X = 1;
    v.Y = 2;
    Func<int> sumaV = v.Suma;
    v.X = 100;
    println(sumaV() + " " + v.Suma());
    // Delegados declarados (estructurales: Operacion es Func<int, int, int>)
    Operacion resta = (a, b) => a - b;
    println(resta(10, 4));
    println(Usar(suma));
    println(Usar((a, b) => a * b));
    Filtro<string> largo = t => t.Length > 3;
    println(largo("abc") + " " + largo("abcd"));

    // Captura por referencia: los cambios se ven en los dos sentidos
    int total = 0;
    Action<int> acumular = x => total += x;
    acumular(5);
    acumular(7);
    println(total);
    total = 100;
    acumular(1);
    println(total);
    Func<int> leerTotal = () => total;
    total = -3;
    println(leerTotal());

    // Cierres que sobreviven al método y contadores independientes
    var c1 = NuevoContador();
    var c2 = NuevoContador();
    c1();
    c1();
    println(c1() + " " + c2());
    var par = Compartido();
    par.Sumar(5);
    par.Sumar(1);
    println(par.Leer());

    // 'this' capturado
    var dep2 = cuenta.Depositador();
    dep2(25);
    println(cuenta.Resumen()());

    // Lambdas anidadas y currificación
    Func<int, Func<int, int>> sumador = a => b => a + b;
    var suma10 = sumador(10);
    println(suma10(5) + " " + sumador(1)(1));
    int base1 = 1000;
    Func<int, Func<int, int>> anidada = a => {
        int local = a * 2;
        return b => base1 + local + b;
    };
    println(anidada(3)(4));
    base1 = 0;
    println(anidada(3)(4));

    // Variables de bucle: 'for' comparte una variable; lo declarado en el cuerpo es nuevo cada vez
    var porIteracion = new List<Func<int>>();
    var compartida = new List<Func<int>>();
    for (int i = 0; i < 3; i++)
    {
        int copia = i;
        porIteracion.Add(() => copia);
        compartida.Add(() => i);
    }
    println(porIteracion[0]() + " " + porIteracion[1]() + " " + porIteracion[2]());
    println(compartida[0]() + " " + compartida[2]());
    int k = 0;
    var mientras = new List<Func<int>>();
    while (k < 3)
    {
        int cuadradoK = k * k;
        mientras.Add(() => cuadradoK);
        k++;
    }
    println(mientras[2]());

    // Recursión a través de una variable capturada
    Func<int, int> fact = null;
    fact = n => n <= 1 ? 1 : n * fact(n - 1);
    println(fact(10));

    // Inferencia de los argumentos genéricos desde las lambdas
    println(Aplicar(5, x => x * 3));
    println(Transformar("hola", t => t.Length));
    println(Transformar(3, x => x * 1.5));
    println(Componer(4, x => x * x, y => "r=" + y));
    println(Transformar(7, Doble));

    // Igualdad y null
    Func<int, int> d1 = Doble;
    Func<int, int> d2 = Doble;
    println(d1 == d2);
    Func<int, int> nulo = null;
    println(nulo == null);
    println(d1 != null);

    // Muchos cierres: el recolector conserva solo los que siguen vivos
    var vivos = new List<Func<int>>();
    for (int i = 0; i < 20000; i++)
    {
        int valor = i;
        Func<int> tmp = () => valor;
        if (i % 1000 == 0) vivos.Add(tmp);
    }
    GC.Collect();
    int sumaVivos = 0;
    for (int i = 0; i < vivos.Count; i++) sumaVivos += vivos[i]();
    println(sumaVivos);
    return 0;
}
