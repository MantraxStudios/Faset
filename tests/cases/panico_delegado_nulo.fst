// Llamar a un delegado nulo es un panic (los eventos sin manejadores no hacen nada).
int main()
{
    Func<int, int> f = x => x + 1;
    println(f(1));
    f = null;
    println(f(2));
    println("no se llega aquí");
    return 0;
}
