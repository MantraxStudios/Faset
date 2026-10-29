// El recolector ve las excepciones en vuelo: mientras corre un 'finally' (o el filtro de un
// 'catch') la excepción solo está en el marco del 'try', en la pila. Con mucha basura y
// recolecciones forzadas, el objeto lanzado y lo que referencia deben seguir intactos.
using std.collections;

[ExceptionBase("Exception")]
class ConDatosException
{
    public List<string> Datos;
    public ConDatosException(int n)
    {
        Message = "datos " + n;
        Datos = new List<string>();
        for (int i = 0; i < n; i++) Datos.Add("elemento " + i);
    }
}

long Basura(int n)
{
    long total = 0;
    for (int i = 0; i < n; i++)
    {
        var l = new List<string>();
        l.Add("basura " + i);
        total += l[0].Length;
    }
    return total;
}

void Profundo(int nivel, int n)
{
    if (nivel == 0) throw new ConDatosException(n);
    try { Profundo(nivel - 1, n); }
    finally
    {
        // La excepción solo está en el marco de este 'try': el recolector debe verla.
        Basura(2000);
        GC.Collect();
    }
}

bool Filtro(Exception e)
{
    Basura(20000);
    GC.Collect();
    return e.Message.Length > 0;
}

void main()
{
    long antes = GC.Collections;
    try { Profundo(20, 500); }
    catch (ConDatosException e) when (Filtro(e))
    {
        GC.Collect();
        long suma = 0;
        for (int i = 0; i < e.Datos.Count; i++) suma += e.Datos[i].Length;
        println(e.Message + ": " + e.Datos.Count + " elementos, " + suma + " bytes");
        println(e.Datos[0] + " / " + e.Datos[499]);
    }

    // Muchas excepciones seguidas (con InnerException) no acumulan memoria.
    long atrapadas = 0;
    for (int i = 0; i < 200000; i++)
    {
        try
        {
            try { throw new FormatException("f" + i); }
            catch (FormatException e) { throw new InvalidOperationException("envoltura " + i, e); }
        }
        catch (InvalidOperationException e)
        {
            if (e.InnerException.Message == "f" + i) atrapadas++;
        }
    }
    println("atrapadas: " + atrapadas);
    GC.Collect();
    println(GC.Collections > antes);
    println(GC.HeapBytes < 64L * 1024 * 1024);

    // Errores del runtime con basura de por medio.
    long nulos = 0;
    for (int i = 0; i < 50000; i++)
    {
        try
        {
            List<int> l = i % 2 == 0 ? new List<int>() : null;
            l.Add(i);
        }
        catch (NullReferenceException) { nulos++; }
    }
    println("nulos: " + nulos);
}
