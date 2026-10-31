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
        var __excType: ulong;               // descriptor del tipo real (lo rellena el constructor)
        public var TypeName: string;        // nombre de la clase real de la excepción ("FormatException")
        public var Message: string;         // descripción del error
        public var InnerException: Exception;  // excepción que causó esta (o null)
        public var StackTrace: string;      // dónde se lanzó: "   en Clase.Metodo (archivo.fst:12)"

        public init() { Message = "Se produjo una excepción."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        // "Tipo: mensaje", la excepción interna y la ubicación (como en .NET).
        public func ToString() -> string => Describe(this);

        public static func Describe(e: Exception) -> string
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
        public var ParamName: string;  // parámetro que causó el error (o "")

        public init() { Message = "El valor no está dentro del intervalo esperado."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }
        public init(message: string, paramName: string)
        {
            Message = WithParam(message, paramName);
            ParamName = paramName;
        }

        public func ToString() -> string => Exception.Describe(this);

        // "mensaje (Parámetro 'x')"
        public static func WithParam(message: string, paramName: string) -> string
        {
            if (paramName.Length == 0) return message;
            return message + " (Parámetro '" + paramName + "')";
        }
    }

    [ExceptionBase("ArgumentException")]
    public class ArgumentNullException
    {
        public init() { Message = "El valor no puede ser nulo."; }
        public init(paramName: string)
        {
            Message = ArgumentException.WithParam("El valor no puede ser nulo.", paramName);
            ParamName = paramName;
        }
        public init(paramName: string, message: string)
        {
            Message = ArgumentException.WithParam(message, paramName);
            ParamName = paramName;
        }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("ArgumentException")]
    public class ArgumentOutOfRangeException
    {
        public init() { Message = "El argumento está fuera del intervalo de valores válidos."; }
        public init(paramName: string)
        {
            Message = ArgumentException.WithParam("El argumento está fuera del intervalo de valores válidos.", paramName);
            ParamName = paramName;
        }
        public init(paramName: string, message: string)
        {
            Message = ArgumentException.WithParam(message, paramName);
            ParamName = paramName;
        }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    // ---------------------------------------------------------------- estado y formato
    [ExceptionBase("Exception")]
    public class InvalidOperationException
    {
        public init() { Message = "La operación no es válida en el estado actual del objeto."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class FormatException
    {
        public init() { Message = "El formato no es válido."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class NotImplementedException
    {
        public init() { Message = "El método o la operación no están implementados."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class NotSupportedException
    {
        public init() { Message = "La operación no está soportada."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class KeyNotFoundException
    {
        public init() { Message = "La clave no existe en el diccionario."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class TimeoutException
    {
        public init() { Message = "Se agotó el tiempo de espera de la operación."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class OperationCanceledException
    {
        public init() { Message = "Se canceló la operación."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class InvalidCastException
    {
        public init() { Message = "La conversión especificada no es válida."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    // ---------------------------------------------------------------- entrada/salida
    [ExceptionBase("Exception")]
    public class IOException
    {
        public init() { Message = "Error de entrada/salida."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("IOException")]
    public class FileNotFoundException
    {
        public var FileName: string;  // ruta que no se encontró (o "")

        public init() { Message = "No se encontró el archivo."; }
        public init(message: string) { Message = message; }
        public init(message: string, fileName: string)
        {
            Message = message;
            FileName = fileName;
        }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("IOException")]
    public class DirectoryNotFoundException
    {
        public init() { Message = "No se encontró el directorio."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    // ---------------------------------------------------------------- errores del runtime
    //  Las lanza el runtime (con un 'try' activo) en lugar de un panic.
    [ExceptionBase("Exception")]
    public class NullReferenceException
    {
        public init() { Message = "referencia nula (null): el objeto no existe"; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class IndexOutOfRangeException
    {
        public init() { Message = "índice fuera de rango"; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("Exception")]
    public class ArithmeticException
    {
        public init() { Message = "Error en una operación aritmética."; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("ArithmeticException")]
    public class DivideByZeroException
    {
        public init() { Message = "división entera por cero"; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }

    [ExceptionBase("ArithmeticException")]
    public class OverflowException
    {
        public init() { Message = "desbordamiento en una operación aritmética"; }
        public init(message: string) { Message = message; }
        public init(message: string, innerException: Exception)
        {
            Message = message;
            InnerException = innerException;
        }

        public func ToString() -> string => Exception.Describe(this);
    }
}
