// Leer .Value de un T? vacío termina con panic.
void main()
{
    int? a = 5;
    int? b = null;
    println(a.Value);
    println(b ?? -1);
    println(b.Value);
    println("no se llega aquí");
}
