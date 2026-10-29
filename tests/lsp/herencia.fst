interface ISonido
{
    string Sonido();
}

abstract class Animal : ISonido
{
    protected string nombre = "";
    public abstract string Sonido();
    public virtual string Hablar() => nombre + " hace " + Sonido();
}

class Perro : Animal
{
    public override string Sonido() => "guau";
    public override string Hablar() => base.Hablar() + "!";
    public void Jugar()
    {
        nombre = "Rex";
    }
}

void Main()
{
    Perro p = new Perro();
    p.Jugar();
}
