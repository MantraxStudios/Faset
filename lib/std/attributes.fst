// =============================================================================
//  std (atributos)  —  base de los atributos de usuario y atributos estándar.
//
//    [AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
//    class Rango : Attribute
//    {
//        public int Min, Max;
//        public Rango(int min, int max) { Min = min; Max = max; }
//    }
//
//    class Persona { [Rango(0, 150)] public int Edad; }
//
//  El compilador evalúa los argumentos de los atributos al compilar: la reflexión de tiempo de
//  compilación los lee sin coste (f.Atributo<Rango>().Max) y la de ejecución
//  (std.reflection) puede crearlos como objetos. Este archivo se carga siempre, como core.fst.
// =============================================================================
namespace std
{
    // Dónde se puede poner un atributo. Los valores los usa el compilador (src/Comptime.h).
    public enum AttributeTargets
    {
        Class = 1, Struct = 2, Enum = 4, Interface = 8, Field = 16, Property = 32,
        Method = 64, Constructor = 128, Parameter = 256, All = 511
    }

    // Clase base de todos los atributos de usuario.
    public class Attribute
    {
        // Nombre del atributo tal como se escribe ("Rango" para RangoAttribute).
        public func AttributeName() -> string
        {
            string n = GetType().Name;
            if (n.Length > 9 && n.Substring(n.Length - 9) == "Attribute") return n.Substring(0, n.Length - 9);
            return n;
        }
    }

    // [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct, AllowMultiple = true)]
    [AttributeUsage(AttributeTargets.Class)]
    public sealed class AttributeUsage : Attribute
    {
        public var ValidOn: AttributeTargets
        public var AllowMultiple: bool
        public var Inherited: bool = true
        public init(validOn: AttributeTargets) { ValidOn = validOn; }
    }

    // [Obsolete("usa Otro")]: aviso al compilar cada uso; [Obsolete("...", true)]: error.
    public sealed class Obsolete : Attribute
    {
        public var Message: string = ""
        public var IsError: bool
        public init() { }
        public init(message: string) { Message = message; }
        public init(message: string, isError: bool)
        {
            Message = message;
            IsError = isError;
        }
    }

    // [Conditional("DEBUG")]: si el símbolo no está definido (#if), las llamadas al método
    // desaparecen al compilar, con sus argumentos (no se evalúan). Solo métodos 'void'.
    [AttributeUsage(AttributeTargets.Method, AllowMultiple = true)]
    public sealed class Conditional : Attribute
    {
        public var Symbol: string
        public init(symbol: string) { Symbol = symbol; }
    }

    // [Reflectable]: la clase (y sus derivadas) o el struct lleva metadatos para la reflexión al
    // ejecutar (std.reflection: GetFields, GetMethods, Activator.CreateInstance...).
    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct)]
    public sealed class Reflectable : Attribute { }

    // void Comprobar(bool cond, [CallerArgumentExpression("cond")] string texto): si la llamada no
    // pasa 'texto', el compilador pone el código fuente del argumento 'cond'.
    [AttributeUsage(AttributeTargets.Parameter)]
    public sealed class CallerArgumentExpression : Attribute
    {
        public var ParameterName: string
        public init(parameterName: string) { ParameterName = parameterName; }
    }
}
