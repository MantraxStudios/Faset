using std.collections;

class Producto
{
    public string Nombre;
    public double Precio;
}

void main()
{
    var ps = new List<Producto>();
    var caros = ps.Where(p => p.Precio > 10).Select(p => p.Nombre);
    Func<int, int> f = x => x * 2;
}
