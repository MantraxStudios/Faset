// Un switch de expresión sin '_' que no contempla el valor termina con panic.
string Nombre(int n) => n switch
{
    1 => "uno",
    2 or 3 => "pocos",
    > 10 => "muchos",
};

void main()
{
    println(Nombre(2));
    println(Nombre(50));
    println(Nombre(7));
    println("no se llega aquí");
}
