// Índice fuera de rango en un T[] fuera de un 'try': panic con la línea del acceso.
void main()
{
    int[] a = [1, 2, 3];
    int i = 3;
    println(a[0]);
    println(a[i]);
    println("no se llega aquí");
}
