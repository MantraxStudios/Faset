using std;

union Forma
{
    Circulo(double Radio),
    Rect(double Ancho, double Alto),
    Punto
}

class Programa
{
    static double Area(Forma f) => f switch
    {
        Forma.Circulo(var r) => 3.14 * r * r,
        Rect(var a, var h) => a * h,
        Punto => 0,
    };

    static void Main()
    {
        Forma f = Forma.Circulo(2);
        Option<int> o = Some(4);
        println(Area(f));
    }
}
