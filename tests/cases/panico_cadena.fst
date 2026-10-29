// Índice fuera de rango al leer un byte de una cadena.
void main()
{
    string s = "abc";
    println((int)s[2]);
    int i = s.Length + 2;
    println((int)s[i]);
    println("no se llega aquí");
}
