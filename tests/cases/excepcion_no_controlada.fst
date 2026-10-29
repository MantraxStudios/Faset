// Una excepción sin 'catch' termina el programa como un panic (código 101): primero se
// ejecutan los 'finally' pendientes y luego se informa del tipo, el mensaje, la causa
// (InnerException) y dónde se lanzó.
void Cargar(string ruta)
{
    try { throw new FormatException("línea 3: se esperaba un número"); }
    catch (FormatException e) { throw new InvalidOperationException("no se pudo cargar " + ruta, e); }
}

void main()
{
    try
    {
        println("cargando");
        Cargar("config.txt");
    }
    finally { println("finally antes de terminar"); }
    println("no se llega aquí");
}
