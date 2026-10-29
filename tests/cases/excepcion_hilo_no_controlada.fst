// Una excepción sin 'catch' en un hilo secundario termina todo el programa (como en .NET),
// aunque el hilo principal esté dentro de un 'try': cada hilo tiene su propia pila de 'try'.
using std.thread;

void Trabajo(int n)
{
    if (n > 0) throw new TimeoutException("el hilo " + n + " tardó demasiado");
}

void main()
{
    println("inicio");
    try
    {
        Thread t = Thread.Run(&Trabajo, 7);
        t.Join();
        Thread.Sleep(1000);
    }
    catch (Exception e) { println("el principal no la atrapa"); }
    println("no se llega aquí");
}
