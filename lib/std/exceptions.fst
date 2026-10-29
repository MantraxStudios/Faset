// =============================================================================
//  std  —  excepciones (siempre disponible, como core.fst).
//
//    try { ... }
//    catch (FormatException e) when (e.Message.Length > 0) { ... }
//    catch (Exception e) { println(e.ToString()); }
//    finally { ... }
//
//    throw new ArgumentNullException("nombre");
//    throw;                       // dentro de un catch: relanza la misma excepción
//
//  Exception es la raíz: 'catch (Exception e)' atrapa cualquier excepción. Los errores del
//  runtime (referencia nula, índice fuera de rango, división por cero) se lanzan como
//  NullReferenceException, IndexOutOfRangeException y DivideByZeroException cuando hay un
//  'try' activo en el hilo; si no, siguen siendo un panic. Una excepción sin 'catch' termina
//  el programa como un panic (código 101) con su tipo, su mensaje y dónde se lanzó.
//
//  Jerarquía (provisional, hasta que Faset tenga herencia): una clase es una excepción si
//  lleva [ExceptionBase("Base")]. Hereda los campos de la base (Message, InnerException...),
//  se puede usar donde se espera la base (Exception e = new FormatException("x")) y la
//  atrapan los 'catch' de la base. Los métodos no se heredan: cada clase declara su ToString.
//
//    [ExceptionBase("Exception")]
//    public class SaldoInsuficienteException
//    {
//        public double Falta;
//        public SaldoInsuficienteException(double falta)
//        {
//            Message = "Saldo insuficiente";
//            Falta = falta;
//        }
//    }
//
//  Cuando exista la herencia esto se escribirá 'class SaldoInsuficienteException : Exception'.
// =============================================================================
namespace std
{
    // ---------------------------------------------------------------- Exception
    public class Exception
    {
        // El compilador y el runtime dependen de estos cinco campos y de su orden.
        ulong __excType;               // descriptor del tipo real (lo rellena el constructor)
        public string TypeName;        // nombre de la clase real de la excepción ("FormatException")
        public string Message;         // descripción del error
        public Exception InnerException;  // excepción que causó esta (o null)
        public string StackTrace;      // dónde se lanzó: "   en Clase.Metodo (archivo.fst:12)"

        public Exception() { Message = "Se produjo una excepción."; }
        public Exception(string message) { Message = message; }
        public Exception(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        // "Tipo: mensaje", la excepción interna y la ubicación (como en .NET).
        public string ToString() => Describe(this);

        public static string Describe(Exception e)
        {
            string s = e.Message.Length > 0 ? e.TypeName + ": " + e.Message : e.TypeName;
            if (e.InnerException != null)
                s = s + "\n ---> " + e.InnerException.ToString() + "\n   --- Fin de la excepción interna ---";
            if (e.StackTrace.Length > 0) s = s + "\n" + e.StackTrace;
            return s;
        }
    }

    // ---------------------------------------------------------------- argumentos
    [ExceptionBase("Exception")]
    public class ArgumentException
    {
        public string ParamName;  // parámetro que causó el error (o "")

        public ArgumentException() { Message = "El valor no está dentro del intervalo esperado."; }
        public ArgumentException(string message) { Message = message; }
        public ArgumentException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }
        public ArgumentException(string message, string paramName)
        {
            Message = WithParam(message, paramName);
            ParamName = paramName;
        }

        public string ToString() => Exception.Describe(this);

        // "mensaje (Parámetro 'x')"
        public static string WithParam(string message, string paramName)
        {
            if (paramName.Length == 0) return message;
            return message + " (Parámetro '" + paramName + "')";
        }
    }

    [ExceptionBase("ArgumentException")]
    public class ArgumentNullException
    {
        public ArgumentNullException() { Message = "El valor no puede ser nulo."; }
        public ArgumentNullException(string paramName)
        {
            Message = ArgumentException.WithParam("El valor no puede ser nulo.", paramName);
            ParamName = paramName;
        }
        public ArgumentNullException(string paramName, string message)
        {
            Message = ArgumentException.WithParam(message, paramName);
            ParamName = paramName;
        }
        public ArgumentNullException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("ArgumentException")]
    public class ArgumentOutOfRangeException
    {
        public ArgumentOutOfRangeException() { Message = "El argumento está fuera del intervalo de valores válidos."; }
        public ArgumentOutOfRangeException(string paramName)
        {
            Message = ArgumentException.WithParam("El argumento está fuera del intervalo de valores válidos.", paramName);
            ParamName = paramName;
        }
        public ArgumentOutOfRangeException(string paramName, string message)
        {
            Message = ArgumentException.WithParam(message, paramName);
            ParamName = paramName;
        }
        public ArgumentOutOfRangeException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    // ---------------------------------------------------------------- estado y formato
    [ExceptionBase("Exception")]
    public class InvalidOperationException
    {
        public InvalidOperationException() { Message = "La operación no es válida en el estado actual del objeto."; }
        public InvalidOperationException(string message) { Message = message; }
        public InvalidOperationException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class FormatException
    {
        public FormatException() { Message = "El formato no es válido."; }
        public FormatException(string message) { Message = message; }
        public FormatException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class NotImplementedException
    {
        public NotImplementedException() { Message = "El método o la operación no están implementados."; }
        public NotImplementedException(string message) { Message = message; }
        public NotImplementedException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class NotSupportedException
    {
        public NotSupportedException() { Message = "La operación no está soportada."; }
        public NotSupportedException(string message) { Message = message; }
        public NotSupportedException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class KeyNotFoundException
    {
        public KeyNotFoundException() { Message = "La clave no existe en el diccionario."; }
        public KeyNotFoundException(string message) { Message = message; }
        public KeyNotFoundException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class TimeoutException
    {
        public TimeoutException() { Message = "Se agotó el tiempo de espera de la operación."; }
        public TimeoutException(string message) { Message = message; }
        public TimeoutException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class OperationCanceledException
    {
        public OperationCanceledException() { Message = "Se canceló la operación."; }
        public OperationCanceledException(string message) { Message = message; }
        public OperationCanceledException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class InvalidCastException
    {
        public InvalidCastException() { Message = "La conversión especificada no es válida."; }
        public InvalidCastException(string message) { Message = message; }
        public InvalidCastException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    // ---------------------------------------------------------------- entrada/salida
    [ExceptionBase("Exception")]
    public class IOException
    {
        public IOException() { Message = "Error de entrada/salida."; }
        public IOException(string message) { Message = message; }
        public IOException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("IOException")]
    public class FileNotFoundException
    {
        public string FileName;  // ruta que no se encontró (o "")

        public FileNotFoundException() { Message = "No se encontró el archivo."; }
        public FileNotFoundException(string message) { Message = message; }
        public FileNotFoundException(string message, string fileName)
        {
            Message = message;
            FileName = fileName;
        }
        public FileNotFoundException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("IOException")]
    public class DirectoryNotFoundException
    {
        public DirectoryNotFoundException() { Message = "No se encontró el directorio."; }
        public DirectoryNotFoundException(string message) { Message = message; }
        public DirectoryNotFoundException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    // ---------------------------------------------------------------- errores del runtime
    //  Las lanza el runtime (con un 'try' activo) en lugar de un panic.
    [ExceptionBase("Exception")]
    public class NullReferenceException
    {
        public NullReferenceException() { Message = "referencia nula (null): el objeto no existe"; }
        public NullReferenceException(string message) { Message = message; }
        public NullReferenceException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class IndexOutOfRangeException
    {
        public IndexOutOfRangeException() { Message = "índice fuera de rango"; }
        public IndexOutOfRangeException(string message) { Message = message; }
        public IndexOutOfRangeException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class ArithmeticException
    {
        public ArithmeticException() { Message = "Error en una operación aritmética."; }
        public ArithmeticException(string message) { Message = message; }
        public ArithmeticException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("ArithmeticException")]
    public class DivideByZeroException
    {
        public DivideByZeroException() { Message = "división entera por cero"; }
        public DivideByZeroException(string message) { Message = message; }
        public DivideByZeroException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }

    [ExceptionBase("ArithmeticException")]
    public class OverflowException
    {
        public OverflowException() { Message = "desbordamiento en una operación aritmética"; }
        public OverflowException(string message) { Message = message; }
        public OverflowException(string message, Exception innerException)
        {
            Message = message;
            InnerException = innerException;
        }

        public string ToString() => Exception.Describe(this);
    }
}
