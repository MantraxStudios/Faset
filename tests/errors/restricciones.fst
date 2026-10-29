// Restricciones genéricas (where) y registros (ver restricciones.expected).
using std.collections;

class Animal { }
class Perro : Animal { }
class Piedra { }
abstract class Abstracta { }
class SinVacio
{
    public SinVacio(int x) { }
}

T Mayor<T>(T a, T b) where T : IComparable<T> => a.CompareTo(b) > 0 ? a : b;
T Crear<T>() where T : new() => new T();
void SoloClases<T>(T x) where T : class { }
void SoloValores<T>(T x) where T : struct { }
void SoloAnimales<T>(T x) where T : Animal { }

class Jaula<T> where T : Animal
{
    public T Ocupante;
}

class Mala<T> where U : class { }                              // 24: U no es un parámetro

record Punto(int X, int Y);
record struct Color(int R);

void Main()
{
    int m = Mayor(1, 2);                                       // correcto: int cumple IComparable<int>
    Piedra p = Mayor(new Piedra(), new Piedra());              // 32: Piedra no es IComparable<Piedra>
    Abstracta a = Crear<Abstracta>();                          // 33: abstracta: no cumple new()
    SinVacio s = Crear<SinVacio>();                            // 34: sin constructor sin parámetros
    SoloClases(5);                                             // 35: int no es una clase
    SoloValores(new Perro());                                  // 36: Perro no es un struct
    SoloAnimales(new Perro());                                 // correcto
    SoloAnimales(new Piedra());                                // 38: Piedra no deriva de Animal
    Jaula<Perro> j = new Jaula<Perro>();                       // correcto
    Jaula<Piedra> k = new Jaula<Piedra>();                     // 40: Piedra no deriva de Animal
    Mala<int> z = new Mala<int>();

    Punto q = new Punto(1, 2);
    Punto r = q with { Z = 3 };                                // 44: no existe Z
    Piedra w = new Piedra() with { };                          // 45: no es un registro
    Punto t = q with { X = "uno" };                            // 46: tipo incorrecto
    Color c = new Color(1);
    object o = c;                                              // 48: un struct no es un object
    q.X = 5;                                                   // 49: propiedad de solo lectura
}
