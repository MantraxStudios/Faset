// Recolector de basura: sin delete ni String.Free, con ciclos, destructores y conversiones seguras.
using std.collections;

class Nodo
{
    public int Valor;
    public Nodo Siguiente;
    public string Nombre;
    public Nodo(int v) { Valor = v; Nombre = "n" + v; }
}

class Recurso
{
    public static int Cerrados;
    ~Recurso() { Cerrados++; }
}

int main()
{
    long suma = 0;
    for (int i = 0; i < 400000; i++)
    {
        Nodo a = new Nodo(i);
        a.Siguiente = new Nodo(i + 1);
        a.Siguiente.Siguiente = a;   // ciclo: también se recupera
        suma += a.Siguiente.Valor + a.Nombre.Length;
    }
    println(suma);

    var lista = new List<Nodo>();
    for (int i = 0; i < 50000; i++) lista.Add(new Nodo(i));
    for (int i = 0; i < 200000; i++) { string s = "basura " + i; suma += s.Length; }
    GC.Collect();
    long total = 0;
    for (int i = 0; i < lista.Count; i++) total += lista[i].Valor + lista[i].Nombre.Length;
    println(total);
    println(GC.Collections > 0);
    println(GC.HeapBytes < 200L * 1024 * 1024);

    for (int i = 0; i < 1000; i++) { Recurso r = new Recurso(); }
    GC.Collect();
    GC.Collect();
    println(Recurso.Cerrados > 900);

    // Concatenación con '+' como en C#.
    string t = "a" + 1 + 'b' + 2.5 + true + 3u;
    t += "!";
    t += 7;
    println(t);

    // Desplazamientos y conversiones sin comportamiento indefinido.
    int uno = 1;
    int n = 33;
    println(uno << n);          // 2 (33 & 31 = 1)
    println(-1 << 1);           // -2
    long big = 1L << 63;
    println(big < 0);
    double enorme = 1e20;
    println((int)enorme);       // saturado: 2147483647
    println((int)(-enorme));
    double nan = 0.0 / 0.0;
    println((int)nan);          // 0
    println((byte)300.7);       // 255
    return 0;
}
