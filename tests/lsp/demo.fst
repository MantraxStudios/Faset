using std::collections;

struct Punto
{
    int X, Y;
    int Suma => X + Y;
}

int Doble(int x) => x * 2;

void main()
{
    auto lista = new List<int>();
    lista.Add(Doble(3));
    Punto p = new Punto();
    int malo = "texto";
    println(lista.Count);
}
