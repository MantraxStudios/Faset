// División entera por cero: panic en lugar de SIGFPE.
int Cero() => 0;

void main()
{
    int a = 10;
    println(a / 3);
    println(a % Cero());
    println("no se llega aquí");
}
