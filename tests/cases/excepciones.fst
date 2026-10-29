// Excepciones: throw/catch entre funciones, jerarquía ([ExceptionBase]), orden de las cláusulas,
// catch sin variable y 'catch { }', excepciones propias, InnerException y ToString.
using std.collections;

[ExceptionBase("Exception")]
class SaldoInsuficienteException
{
    public double Falta;
    public SaldoInsuficienteException(double falta)
    {
        Message = "saldo insuficiente";
        Falta = falta;
    }
    public string ToString() => Exception.Describe(this);
}

// Una excepción propia que deriva de otra de std.
[ExceptionBase("ArgumentException")]
class CuentaNoValidaException
{
    public CuentaNoValidaException(string cuenta) { Message = "cuenta no válida: " + cuenta; ParamName = "cuenta"; }
}

class Cuenta
{
    public string Nombre;
    public double Saldo;
    public Cuenta(string n, double s) { Nombre = n; Saldo = s; }

    public void Retirar(double cantidad)
    {
        if (cantidad <= 0) throw new ArgumentOutOfRangeException("cantidad", "debe ser positiva");
        if (cantidad > Saldo) throw new SaldoInsuficienteException(cantidad - Saldo);
        Saldo -= cantidad;
    }
}

Cuenta Buscar(string nombre)
{
    if (nombre.Length == 0) throw new ArgumentNullException("nombre");
    if (nombre[0] == '#') throw new CuentaNoValidaException(nombre);
    return new Cuenta(nombre, 100);
}

// Atraviesa varias funciones sin 'try'.
int Nivel3(int n)
{
    if (n > 2) throw new InvalidOperationException("demasiado profundo: " + n);
    return n;
}
int Nivel2(int n) => Nivel3(n + 1) * 10;
int Nivel1(int n) => Nivel2(n + 1) + 1;

string Clasificar(int caso)
{
    try
    {
        if (caso == 0) throw new FormatException("formato");
        if (caso == 1) throw new ArgumentNullException("x");
        if (caso == 2) throw new FileNotFoundException("no está", "datos.txt");
        if (caso == 3) throw new IOException("disco");
        if (caso == 4) throw new NotImplementedException();
        if (caso == 5) throw new DivideByZeroException();
        return "sin excepción";
    }
    catch (ArgumentException e) { return "argumento (" + e.TypeName + ", " + e.ParamName + ")"; }
    catch (FileNotFoundException e) { return "archivo " + e.FileName; }
    catch (IOException e) { return "E/S: " + e.Message; }
    catch (ArithmeticException e) { return "aritmética: " + e.TypeName; }
    catch (FormatException) { return "formato (sin variable)"; }
    catch { return "cualquier otra"; }
}

void main()
{
    // Entre funciones.
    try
    {
        println(Nivel1(0));
        println(Nivel1(5));
        println("no se llega");
    }
    catch (InvalidOperationException e)
    {
        println("atrapada: " + e.Message);
        println(e.StackTrace);
    }

    for (int i = 0; i <= 6; i++) println(i + ": " + Clasificar(i));

    // Excepciones propias.
    Cuenta c = Buscar("ana");
    try
    {
        c.Retirar(30);
        c.Retirar(-1);
    }
    catch (ArgumentOutOfRangeException e) { println(e.Message + " | " + e.ParamName); }
    try { c.Retirar(500); }
    catch (SaldoInsuficienteException e) { println(e.Message + ", faltan " + e.Falta); println(e.ToString()); }
    try { Buscar("#99"); }
    catch (ArgumentException e) { println(e.TypeName + ": " + e.Message + " [" + e.ParamName + "]"); }
    try { Buscar(""); }
    catch (Exception e) { println(e.ToString()); }

    // Una excepción se puede usar como su base (conversión implícita) y guardar.
    Exception guardada = null;
    try { throw new KeyNotFoundException("clave 'x'"); }
    catch (Exception e) { guardada = e; }
    println(guardada.TypeName + " / " + guardada.Message);
    Exception base = new FormatException("como base");
    println(base.TypeName);

    // InnerException y ToString.
    try
    {
        try { throw new FormatException("interna"); }
        catch (FormatException e) { throw new InvalidOperationException("externa", e); }
    }
    catch (Exception e)
    {
        println(e.Message + " <- " + e.InnerException.Message + " (" + e.InnerException.TypeName + ")");
        println(e.ToString());
    }

    // Exception sin argumentos y mensajes por defecto.
    try { throw new Exception(); }
    catch (Exception e) { println("[" + e.Message + "]"); }
    try { throw new TimeoutException(); }
    catch (TimeoutException e) { println(e.Message); }
    try { throw new OperationCanceledException(); }
    catch (Exception e) { println(e.TypeName); }
    try { throw new NotSupportedException("no"); }
    catch (NotSupportedException e) { println(e.TypeName + ": " + e.Message); }
    println("fin");
}
