// Fuera de 'memory_unsafe' cada línea marcada da un error (ver memory_unsafe.expected).
using std.collections;

static class Nativo
{
    public static extern int abs(int x);              // declarar un extern sí está permitido
}

class Nodo
{
    public int Valor;
    public int* Crudo;                                    // 12: campo puntero
}

class Otra { public int X; }
struct Punto { public int X; }

memory_unsafe void Peligrosa() { }

void Recibe(int* p) { }                                  // 20: parámetro puntero

void main()
{
    int x = 1;
    int* p = null;                                        // 25: variable puntero
    int y = *p;                                           // 26: desreferenciar
    auto q = &x;                                          // 27: dirección
    int w = p[1];                                         // 28: indexar un puntero
    p++;                                                  // 29: aritmética de punteros
    auto r = p + 1;                                       // 30: aritmética de punteros
    Punto* pp = null;                                     // 31: variable puntero
    pp->X = 1;                                            // 32: '->'
    long* arr = new long[4];                              // 33: new T[n] como puntero
    auto s = "hola".Ptr;                                  // 34: .Ptr
    Nodo n = new Nodo();
    Otra o = (Otra)n;                                     // 36: reinterpretar una referencia
    int a = Nativo.abs(-3);                               // 37: llamar a un extern
    Peligrosa();                                          // 38: método memory_unsafe
    auto mem = Memory.Alloc(16);                          // 39: Memory.* es memory_unsafe
    List<int> l = new List<int>();
    auto d = l.Data;                                      // 41: API que devuelve un puntero
    List<int*> lp = null;                                 // 42: argumento genérico puntero
    int c = n.Crudo[0];                                   // 43: valor puntero de un campo
    long sz = sizeof(int);                                // sizeof sí está permitido
    delete l;
    delete n;
}
