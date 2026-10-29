// Errores de compilación de las excepciones.
class NoEsExcepcion { public string Message; }

[ExceptionBase("NoEsExcepcion")]
class MalaBase { }

[ExceptionBase("NoExiste")]
class SinBase { }

int Uno()
{
    try { return 1; }
    finally { return 2; }
}

void main()
{
    throw new NoEsExcepcion();
    throw;
    try { } catch (NoEsExcepcion e) { }
    try { } catch (Exception e) { } catch (FormatException e) { }
    try { } catch (ArgumentException e) { } catch (ArgumentNullException e) { }
    for (int i = 0; i < 3; i++)
    {
        try { } finally { break; }
        try { } finally { continue; }
    }
    try { } finally { throw; }
    throw 42;
    try { } catch { } catch (Exception e) { }
}
