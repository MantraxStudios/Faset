// Lambdas en campos, constructores, propiedades y switch; coste en memoria de llamarlas.
using std.collections;

class Config
{
    public static Func<int, int> Escala = x => x * 10;
    public Func<string> Nombre = () => "config";
    public int Base = 7;
    public Func<int> LeerBase;
    public Config() { LeerBase = () => Base; }
    public Func<int, int> Sumador
    {
        get { int extra = Base * 2; return x => x + extra; }
    }
}

int Clasificar(int v)
{
    int r = 0;
    switch (v)
    {
        case 1:
            int doble = v * 2;
            Func<int> f = () => doble + 100;
            r = f();
            break;
        default:
            r = -1;
            break;
    }
    return r;
}

int main()
{
    println(Config.Escala(4));
    var c = new Config();
    println(c.Nombre());
    c.Base = 9;
    println(c.LeerBase());
    println(c.Sumador(1));
    println(Clasificar(1) + " " + Clasificar(5));

    // Sin capturas: no reserva memoria al crearla ni al llamarla
    GC.Collect();
    long antes = GC.HeapBytes;
    long acc = 0;
    for (int i = 0; i < 1000000; i++)
    {
        Func<int, int> f = x => x + 1;
        acc += f(i);
    }
    long despues = GC.HeapBytes;
    println(acc);
    println(despues - antes < 4096);
    int k = 3;
    Func<int, int> g = x => x * k;
    long antes2 = GC.HeapBytes;
    for (int i = 0; i < 1000000; i++) acc += g(i);
    println(GC.HeapBytes - antes2 < 4096);
    return 0;
}
