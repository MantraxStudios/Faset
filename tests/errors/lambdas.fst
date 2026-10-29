using std.collections;

class Termostato
{
    public event Action<int> Cambiado;
    public event int NoEsDelegado;
    public void Poner(int t) { Cambiado(t); }
}

struct Punto
{
    public int X;
    public Func<int> Mal() => () => X;
}

string Texto(string s) => s;

void ConRef(ref int x)
{
    Action a = () => x++;
}

int main()
{
    Func<int, int> f = (a, b) => a + b;
    Func<int, string> g = x => x + 1;
    Func<int, int> h = (string s) => 1;
    Func<int, int> ok = x => x;
    ok(1, 2);
    ok("hola");
    var t = new Termostato();
    t.Cambiado(3);
    t.Cambiado = null;
    var sinTipo = x => x;
    Func<int, int> grupo = Texto;
    int n = x => x;
    Action a = () => { return 5; };
    Func<int> sinRetorno = () => { };
    Func<void> nada = null;
    var l = new List<int>();
    var r = l.Where(x => x.Length > 2);
    Action<int> cuerpo = x => x * 2;
    return 0;
}
