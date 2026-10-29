// Lambdas dentro de plantillas, delegados declarados en clases y en memory_unsafe, y coste.
using std.collections;

// Caché perezosa genérica: guarda un Func<T> y lo evalúa una sola vez.
class Perezoso<T>
{
    Func<T> fabrica;
    T valor;
    bool hecho;
    public Perezoso(Func<T> f) { fabrica = f; }
    public T Valor
    {
        get
        {
            if (!hecho)
            {
                valor = fabrica();
                hecho = true;
            }
            return valor;
        }
    }
    // Lambda dentro de la plantilla que captura 'this' y un parámetro
    public Func<T, bool> IgualA() => x => x == Valor;
}

class Boton
{
    public delegate void Pulsado(Boton b, int veces);
    public event Pulsado AlPulsar;
    public string Texto;
    int veces;
    public Boton(string t) { Texto = t; }
    public void Pulsar()
    {
        veces++;
        AlPulsar(this, veces);
    }
}

// Pila de deshacer: lista de acciones
class Historial
{
    List<Action> deshacer = new List<Action>();
    public void Hacer(Action hacer, Action anular)
    {
        hacer();
        deshacer.Add(anular);
    }
    public void Deshacer()
    {
        if (deshacer.Count == 0) return;
        deshacer.Pop()();
    }
}

static List<U> Mapear<T, U>(List<T> l, Func<T, U> f)
{
    var r = new List<U>();
    for (int i = 0; i < l.Count; i++) r.Add(f(l[i]));
    return r;
}

memory_unsafe int LeerPuntero(int* p, Func<int, int> f) => f(*p);

int main()
{
    int evaluaciones = 0;
    var p = new Perezoso<string>(() => { evaluaciones++; return "calculado"; });
    string v1 = p.Valor;
    string v2 = p.Valor;
    println(v1 + " " + v2 + " " + evaluaciones);
    var esIgual = p.IgualA();
    println(esIgual("calculado") + " " + esIgual("otro"));

    var b = new Boton("Aceptar");
    b.AlPulsar += (boton, n) => println(boton.Texto + " x" + n);
    b.Pulsar();
    b.Pulsar();

    int x = 0;
    var h = new Historial();
    h.Hacer(() => x += 5, () => x -= 5);
    h.Hacer(() => x *= 10, () => x /= 10);
    println(x);
    h.Deshacer();
    println(x);
    h.Deshacer();
    println(x);

    var nums = new List<int>();
    nums.Add(1);
    nums.Add(2);
    nums.Add(3);
    var textos = Mapear(nums, n => "#" + n);
    println(textos[0] + textos[1] + textos[2]);
    var largos = Mapear(textos, t => t.Length * 1.5);
    println(largos.Sum());

    memory_unsafe
    {
        int valor = 20;
        println(LeerPuntero(&valor, v => v + 1));
    }

    // Diccionario de comandos
    var comandos = new Dictionary<string, Func<int, int, int>>();
    comandos.Set("suma", (a, c) => a + c);
    comandos.Set("max", (a, c) => a > c ? a : c);
    println(comandos.Get("suma")(2, 3) + " " + comandos.Get("max")(2, 3));
    var cuenta = new Dictionary<string, int>();
    cuenta.GetOrAdd("a", k => 7);
    println(cuenta.GetOrAdd("a", k => 99));
    cuenta.Set("b", 2);
    cuenta.Set("c", 30);
    println(cuenta.Pairs().Where(kv => kv.Value > 5).Count);
    cuenta.RemoveAll((k, v) => v < 10);
    println(cuenta.Count);
    int sumaValores = 0;
    cuenta.ForEach((k, v) => sumaValores += v);
    println(sumaValores);
    return 0;
}
