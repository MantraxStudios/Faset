// 'using var' de una variable que captura una lambda (la variable vive en una caja): el
// destructor se llama al salir del ámbito igual que sin captura.
class Recurso
{
    public int V = 3;
    ~Recurso() { println("destruido"); }
}

void Ejecutar(Action a) { a(); }

int main()
{
    {
        using var r = new Recurso();
        Ejecutar(() => println(r.V));
        r.V = 4;
        Ejecutar(() => println(r.V));
    }
    println("fin");
    return 0;
}
