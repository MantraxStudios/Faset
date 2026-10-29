// Todas las formas de 'memory_unsafe' y el código seguro que convive con ellas.
using std.collections;

// Clase 'memory_unsafe': su implementación usa punteros, pero su API pública (sin punteros
// en la firma) se puede usar desde código seguro.
public memory_unsafe class Pila
{
    int* datos = Memory.New<int>(4);
    int capacidad = 4;
    int cuenta;

    ~Pila() { Memory.Free(datos); }

    public int Cuenta => cuenta;

    public void Meter(int v)
    {
        if (cuenta == capacidad)
        {
            capacidad *= 2;
            datos = Memory.Resize<int>(datos, capacidad);
        }
        *(datos + cuenta) = v;
        cuenta++;
    }

    [TrackCaller] public int Sacar()
    {
        if (cuenta == 0) panic("Pila.Sacar: la pila está vacía");
        cuenta--;
        return datos[cuenta];
    }
}

// Namespace 'memory_unsafe': todo lo declarado dentro es confiable.
memory_unsafe namespace Bajo.Nivel
{
    public static class Bits
    {
        public static ulong DeDouble(double d) => *(ulong*)&d;
    }

    public void Rellenar(byte* p, int n, byte v)
    {
        for (int i = 0; i < n; i++) p[i] = v;
    }
}

// Método 'memory_unsafe': solo se puede llamar desde un contexto memory_unsafe.
memory_unsafe int Suma(int* datos, int n)
{
    int s = 0;
    for (int* p = datos; p < datos + n; p++) s += *p;
    return s;
}

// Código seguro: clases, List<T>, referencias y punteros a función sin 'memory_unsafe'.
class Nodo
{
    public int Valor;
    public Nodo Siguiente;
    public Nodo(int v, Nodo s) { Valor = v; Siguiente = s; }
}

bool EsPar(int x) => x % 2 == 0;
void Doblar(ref int x) { x *= 2; }

void main()
{
    Pila pila = new Pila();
    for (int i = 1; i <= 10; i++) pila.Meter(i * i);
    println(pila.Cuenta);
    println(pila.Sacar());
    delete pila;

    println(Bajo.Nivel.Bits.DeDouble(1.0) == 4607182418800017408UL);

    memory_unsafe
    {
        byte* buf = (byte*)Memory.Alloc(8);
        Bajo.Nivel.Rellenar(buf, 8, 7);
        int* nums = new int[3];
        nums[0] = 1; nums[1] = 2; nums[2] = buf[5];
        println(Suma(nums, 3));
        delete[] nums;
        Memory.Free(buf);
    }

    Nodo lista = new Nodo(1, new Nodo(2, new Nodo(3, null)));
    int total = 0;
    for (Nodo n = lista; n != null; n = n.Siguiente) total += n.Valor;
    println(total);
    while (lista != null)
    {
        Nodo sig = lista.Siguiente;
        delete lista;
        lista = sig;
    }

    List<int> l = new List<int>();
    for (int i = 0; i < 6; i++) l.Add(i);
    List<int> pares = l.Where(&EsPar);
    println(pares.Count);
    int x = 21;
    Doblar(ref x);
    println(x);
    delete pares;
    delete l;
}
