// 'protected': accesible en la clase y en sus derivadas; 'private' solo en la clase (ver protegido.expected).
class Cuenta
{
    private double saldo;
    protected string titular = "";
    protected Cuenta() { }
    protected void Auditar() { }
    protected int Version => 1;
    private void Interno() { }
    public static Cuenta Crear() => new Cuenta();               // dentro de la clase: correcto
}

class Ahorro : Cuenta
{
    public Ahorro() : base() { }                               // constructor protegido: correcto
    public void Usar()
    {
        titular = "Ana";                                       // protegido heredado: correcto
        Auditar();
        int v = Version;
        this.Auditar();
        saldo = 3;                                             // 22: privado de la base
        Interno();                                             // 23: privado de la base
    }
}

class Otra
{
    public void Probar(Cuenta c, Ahorro a)
    {
        c.titular = "x";                                       // 31: protegido desde fuera
        c.Auditar();                                           // 32: protegido desde fuera
        int v = a.Version;                                     // 33: protegido desde fuera
        Cuenta n = new Cuenta();                               // 34: constructor protegido
    }
}

void Main()
{
    Ahorro a = new Ahorro();
    a.Usar();
    a.Auditar();                                               // 42: protegido desde fuera
}
