// 'delete' dos veces del mismo objeto: se detecta antes de llamar otra vez al destructor.
class Recurso
{
    public int Id;
    public Recurso(int id) { Id = id; }
    ~Recurso() { print("liberado "); println(Id); }
}

void main()
{
    Recurso r = new Recurso(7);
    Recurso alias = r;
    delete r;
    delete alias;
    println("no se llega aquí");
}
