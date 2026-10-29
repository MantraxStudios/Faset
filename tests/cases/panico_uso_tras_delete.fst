// Uso de un objeto después de 'delete' (use-after-free).
class Cuenta
{
    public int Saldo;
    public void Ingresar(int n) { Saldo += n; }
}

void main()
{
    Cuenta c = new Cuenta();
    c.Ingresar(10);
    println(c.Saldo);
    delete c;
    c.Ingresar(5);
    println("no se llega aquí");
}
