// Acceso a un miembro a través de una referencia nula.
class Nodo
{
    public int Valor;
    public Nodo Siguiente;
}

void main()
{
    Nodo n = new Nodo();
    n.Valor = 3;
    println(n.Valor);
    println(n.Siguiente.Valor);
    println("no se llega aquí");
}
