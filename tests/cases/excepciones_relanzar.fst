// throw; (relanzar), filtros 'when', 'throw e' conserva el tipo real y try anidados.
int Contador = 0;

void Lanzar(int codigo)
{
    if (codigo == 404) throw new FileNotFoundException("no encontrado", "x.txt");
    if (codigo == 500) throw new InvalidOperationException("error del servidor");
    throw new ArgumentException("código " + codigo, "codigo");
}

bool Registrar(Exception e)
{
    Contador++;
    println("  registro " + Contador + ": " + e.TypeName);
    return false;  // el filtro no atrapa: solo registra
}

void Intermedio(int codigo)
{
    try { Lanzar(codigo); }
    catch (Exception e)
    {
        println("  intermedio vio " + e.TypeName + ", relanza");
        throw;
    }
}

string Probar(int codigo)
{
    try { Intermedio(codigo); return "ok"; }
    catch (Exception e) when (Registrar(e)) { return "nunca"; }
    catch (IOException e) when (e.Message == "otra cosa") { return "nunca"; }
    catch (IOException e) when (e.Message.Length > 3) { return "E/S: " + e.Message; }
    catch (ArgumentException e) when (e.ParamName == "codigo") { return "argumento: " + e.Message; }
    catch (Exception e) { return "genérica: " + e.Message; }
}

void main()
{
    println(Probar(404));
    println(Probar(500));
    println(Probar(7));

    // throw; conserva el objeto y añade el relanzamiento al StackTrace.
    try
    {
        try { Lanzar(500); }
        catch (InvalidOperationException e) { throw; }
    }
    catch (Exception e)
    {
        println(e.TypeName);
        println(e.StackTrace);
    }

    // 'throw e' con e de tipo Exception: el catch de fuera ve el tipo real.
    try
    {
        try { Lanzar(404); }
        catch (Exception e) { throw e; }
    }
    catch (FileNotFoundException e) { println("tipo real conservado: " + e.FileName); }

    // throw; dentro de un try anidado en el catch: lo atrapa el try interior.
    try { Lanzar(1); }
    catch (ArgumentException e)
    {
        try { throw; }
        catch (ArgumentException otra) { println("misma excepción: " + (otra == e)); }
    }

    // El filtro ve la variable y otras locales.
    int limite = 2;
    for (int i = 0; i < 4; i++)
    {
        try { throw new ArgumentOutOfRangeException("i", "valor " + i); }
        catch (ArgumentOutOfRangeException e) when (i < limite) { println("menor: " + e.Message); }
        catch (ArgumentException e) { println("resto: " + e.TypeName); }
    }

    // Ninguna cláusula coincide: la excepción sigue al try de fuera.
    try
    {
        try { throw new TimeoutException("lento"); }
        catch (FormatException e) { println("nunca"); }
        catch (ArgumentException e) { println("nunca"); }
    }
    catch (TimeoutException e) { println("fuera: " + e.Message); }

    // catch { } y throw; dentro.
    try
    {
        try { throw new NotImplementedException("pendiente"); }
        catch { println("catch sin tipo"); throw; }
    }
    catch (NotImplementedException e) { println("relanzada: " + e.Message); }
}
