// Orden de la inicialización estática por dependencias (aunque las clases estén declaradas en
// otro orden o en otros módulos) y constructores estáticos 'static Clase() { ... }'.
using std.thread;
using std.collections;

class Primero
{
    public static int Valor = Segundo.Base * 2;   // lee un campo de una clase declarada después
    public static int Doble() => Valor * 2;
}

class Segundo
{
    public static int Base = Tercero.Calcular() + Limite;   // a través de un método
    public const int Limite = 100;
}

class Tercero
{
    static int semilla = 5;
    public static int Calcular() => semilla + 1;
}

class Config
{
    public static int Ancho;
    public static string Nombre = "cfg";
    public static List<string> Log = new List<string>();
    static Config()
    {
        Ancho = Nombre.Length * 10;   // después de los inicializadores de sus campos
        Log.Add("static Config()");
    }
}

class Usa
{
    public static int X = Config.Ancho + 1;   // el constructor estático de Config va antes
}

class Contador
{
    public static int Creados;
    public int Id;
    public Contador() { Creados++; Id = Creados; }
}

class Unico
{
    public static Contador Instancia = new Contador();   // el constructor lee Contador.Creados
    static Unico() { println("static Unico(): " + Instancia.Id); }
}

class Seguro
{
    // Un Mutex estático (std.thread): su constructor usa constantes de otro módulo.
    static Mutex cerrojo = new Mutex();
    static int total;
    public static void Sumar(int n) { cerrojo.Lock(); total += n; cerrojo.Unlock(); }
    public static int Total => total;
}

void main()
{
    println(Primero.Valor);
    println(Primero.Doble());
    println(Usa.X);
    println(Config.Log[0]);
    var hilos = new List<Thread>();
    for (int i = 0; i < 4; i++) hilos.Add(Thread.Run(() => { for (int k = 0; k < 1000; k++) Seguro.Sumar(1); }));
    foreach (var h in hilos) h.Join();
    println(Seguro.Total);
}
