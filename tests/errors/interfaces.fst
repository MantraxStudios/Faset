// Errores de interfaces (ver interfaces.expected).
interface IVolador
{
    void Volar();
    int Alas { get; }
}

interface IMal
{
    int campo;                                                 // 10: campo en una interfaz
    static void Estatico() { }                                 // 11: estático en una interfaz
    private void Privado();                                    // 12: no público
}

class Pajaro : IVolador                                        // 15: falta Alas
{
    public void Volar() { }
}

class Avion : IVolador
{
    void Volar() { }                                           // 22: implementa pero no es public
    public int Alas => 2;
}

class Cohete : IVolador
{
    public int Volar() { return 0; }                           // 28: tipo de retorno distinto
    public int Alas => 0;
}

struct Globo : IVolador                                        // 32: un struct también debe implementarla
{
    public void Volar() { }
}

class Repetida : IVolador, IVolador                            // 37: interfaz repetida
{
    public void Volar() { }
    public int Alas => 1;
}

class Mal : IVolador, Pajaro { }                               // 43: la clase base va primero

struct Punto : IVolador
{
    public void Volar() { }
    public int Alas => 0;
}

void Main()
{
    IVolador v = new IVolador();                               // 53: no se instancia una interfaz
    Punto p = new Punto();
    IVolador w = p;                                            // 55: sin boxing
    v.Aterrizar();                                             // 56: no existe
}
