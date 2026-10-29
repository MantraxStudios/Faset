// Un error del runtime dentro de un 'try' cuyas cláusulas no lo atrapan: se ejecuta el
// 'finally' y el programa termina con el mismo mensaje que el panic de siempre.
class Punto { public int X; }

void main()
{
    Punto p = null;
    try
    {
        println("antes");
        println(p.X);
    }
    catch (FormatException e) { println("no es un FormatException"); }
    finally { println("finally"); }
    println("no se llega aquí");
}
