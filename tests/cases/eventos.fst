// Eventos: += / -=, multicast, invocación sin manejadores e Invoke.
using std.collections;

delegate void Aviso(string quien, int valor);

class Termostato
{
    public string Nombre;
    int temperatura;
    public event Action<int> Cambiado;
    public event Aviso Alarma;
    public static event Action<string> Global;

    public Termostato(string n) { Nombre = n; }

    public int Temperatura
    {
        get => temperatura;
        set
        {
            temperatura = value;
            Cambiado(value);              // sin manejadores no hace nada
            if (value > 30) Alarma.Invoke(Nombre, value);
            Global(Nombre + " = " + value);
        }
    }

    public bool TieneManejadores => Cambiado != null;
}

class Registro
{
    public List<string> Lineas = new List<string>();
    public void Anotar(int v) { Lineas.Add("registro " + v); }
}

void Imprimir(int v) { println("imprimir " + v); }

int main()
{
    var t = new Termostato("salón");
    t.Temperatura = 18;
    println(t.TieneManejadores);

    var reg = new Registro();
    int suma = 0;
    Action<int> sumar = v => suma += v;
    t.Cambiado += Imprimir;
    t.Cambiado += sumar;
    t.Cambiado += reg.Anotar;
    t.Alarma += (q, v) => println("¡alarma en " + q + ": " + v + "!");
    Termostato.Global += s => println("global: " + s);
    t.Temperatura = 21;
    t.Temperatura = 35;
    println(suma);

    // -= quita el manejador (los métodos se comparan por función y objeto)
    t.Cambiado -= Imprimir;
    t.Cambiado -= reg.Anotar;
    t.Temperatura = 1;
    println(suma);
    println(reg.Lineas.Count);
    t.Cambiado -= sumar;
    println(t.TieneManejadores);
    t.Temperatura = 2;

    // Una lambda distinta (aunque sea igual) no quita nada
    t.Cambiado += v => println("A " + v);
    t.Cambiado -= v => println("A " + v);
    t.Temperatura = 3;

    // Delegados multicast fuera de eventos: devuelven el último resultado
    Func<int> varios = () => 1;
    varios += () => 2;
    varios += () => 3;
    println(varios());
    Action<string> eco = null;
    eco += x => println("1:" + x);
    eco += x => println("2:" + x);
    eco("hola");
    return 0;
}
