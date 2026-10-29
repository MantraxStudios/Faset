// Excepciones compiladas en Release (-O2). Las variables declaradas fuera de un 'try' y
// modificadas dentro deben conservar su último valor en el 'catch', en el 'finally' y después
// (el compilador las declara 'volatile' en C: tras un longjmp, una variable en un registro
// volvería al valor que tenía al entrar en el 'try').
using std.collections;

struct Punto { public int X; public int Y; }
class Caja { public int Valor; }

int Fallar(int n)
{
    if (n >= 0) throw new InvalidOperationException("fallo " + n);
    return n;
}

int Parametro(int n)
{
    try
    {
        n = n * 2;
        Fallar(n);
    }
    catch (Exception) { }
    return n;  // el parámetro modificado dentro del 'try'
}

void Contar(ref int contador)
{
    contador++;
    Fallar(contador);
}

void main()
{
    int entero = 1;
    long largo = 2;
    double real = 0.5;
    string texto = "a";
    Punto p = new Punto();
    Caja caja = null;
    int porRef = 0;
    int iteraciones = 0;
    try
    {
        for (int i = 0; i < 1000; i++)
        {
            entero += i;
            largo *= 3;
            real += 0.25;
            iteraciones++;
        }
        texto = texto + "b";
        p.X = 7;
        p.Y = p.X * 6;
        caja = new Caja();
        caja.Valor = 99;
        Contar(ref porRef);
    }
    catch (InvalidOperationException e)
    {
        println(e.Message);
        println(entero);
        println(largo);
        println(real);
        println(texto);
        println(p.X + p.Y);
        println(caja.Valor);
        println(iteraciones);
    }
    println(porRef);

    // En el finally y en un bucle que sigue después de atrapar.
    int total = 0;
    for (int vuelta = 0; vuelta < 5; vuelta++)
    {
        int parcial = 0;
        try
        {
            parcial = vuelta * 10;
            total += parcial;
            Fallar(vuelta - 2);
            total += 1000;
        }
        catch (Exception) { total += 1; }
        finally { total += parcial; }
    }
    println(total);
    println(Parametro(21));

    // Contador modificado dentro y leído en un catch exterior tras un finally.
    int pasos = 0;
    try
    {
        try
        {
            pasos = 1;
            Fallar(0);
        }
        finally { pasos += 10; }
    }
    catch (Exception) { pasos += 100; }
    println(pasos);

    // Excepciones del runtime en Release también.
    int ceros = 0;
    for (int i = 0; i < 1000; i++)
    {
        try { int z = 100 / (i % 4); }
        catch (DivideByZeroException) { ceros++; }
    }
    println(ceros);
}
