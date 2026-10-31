// =============================================================================
//  std  —  Option<T> y Result<T, E>: errores sin excepciones (siempre disponible).
//
//  Son uniones (tipos algebraicos) de la biblioteca, por valor (structs):
//
//    union Option<T>    { None, Some(T Value) }
//    union Result<T, E> { Ok(T Value), Err(E Error) }
//
//  Some, None, Ok y Err se pueden escribir sin calificar (como el preludio de Rust); el tipo se
//  infiere de los argumentos o del destino:
//
//    Result<int, string> Parsear(string s)
//    {
//        if (int.TryParse(s, out int n)) return Ok(n);
//        return Err("no es un número: " + s);
//    }
//
//    Result<int, string> Doble(string s)
//    {
//        int n = Parsear(s)?;          // si es Err, Doble devuelve ese Err en el acto
//        return Ok(n * 2);
//    }
//
//    string texto = Parsear("42") switch { Ok(var n) => $"vale {n}", Err(var e) => e };
//
//  Unwrap() / Expect(): si no hay valor lanzan UnwrapException. Dentro de un 'try' se puede
//  atrapar; sin 'try' termina el programa como un panic (código 101) con la ubicación de la
//  llamada. Result.Try(() => ...) convierte una excepción en un Err.
//
//  Interoperabilidad con T?: un T? se convierte implícitamente en Option<T> (null es None) y un
//  Option<T> de un tipo por valor en T? (None es null); ToNullable() y FromNullable(v) lo hacen
//  de forma explícita.
// =============================================================================
namespace std
{
    // Unwrap() o Expect() sobre un None o un Err.
    public class UnwrapException : InvalidOperationException
    {
        public init(message: string) { Message = message; }
    }

    // ---------------------------------------------------------------- Option<T>
    public union Option<T>
    {
        None,
        Some(T Value);

        public prop IsSome: bool => __caso == 1;
        public prop IsNone: bool => __caso == 0;

        // El valor; con None lanza UnwrapException.
        [TrackCaller] public func Unwrap() -> T
        {
            if (__caso != 1) throw new UnwrapException("Option.Unwrap(): el valor es None");
            return __Some_Value;
        }

        // El valor; con None lanza UnwrapException con el mensaje indicado.
        [TrackCaller] public func Expect(message: string) -> T
        {
            if (__caso != 1) throw new UnwrapException(message);
            return __Some_Value;
        }

        public func UnwrapOr(other: T) -> T => __caso == 1 ? __Some_Value : other;
        public func UnwrapOrDefault() -> T => __Some_Value;  // con None es default(T)
        public func UnwrapOrElse(f: Func<T>) -> T => __caso == 1 ? __Some_Value : f();

        public func Map<U>(f: Func<T, U>) -> Option<U>
        {
            if (__caso == 1) return Option<U>.Some(f(__Some_Value));
            return Option<U>.None;
        }

        public func AndThen<U>(f: Func<T, Option<U>>) -> Option<U>
        {
            if (__caso == 1) return f(__Some_Value);
            return Option<U>.None;
        }

        public func Filter(predicate: Func<T, bool>) -> Option<T>
        {
            if (__caso == 1 && predicate(__Some_Value)) return this;
            return None;
        }

        public func Or(other: Option<T>) -> Option<T> => __caso == 1 ? this : other;
        public func OrElse(f: Func<Option<T>>) -> Option<T> => __caso == 1 ? this : f();

        // Some(v) -> Ok(v); None -> Err(error).
        public func OkOr<E>(error: E) -> Result<T, E>
        {
            if (__caso == 1) return Result<T, E>.Ok(__Some_Value);
            return Result<T, E>.Err(error);
        }

        public func Match<U>(some: Func<T, U>, none: Func<U>) -> U => __caso == 1 ? some(__Some_Value) : none();

        // T? con el valor (null si es None).
        public func ToNullable() -> T?
        {
            T? r = null;
            if (__caso == 1) r = __Some_Value;
            return r;
        }

        public static func FromNullable(value: T?) -> Option<T>
        {
            if (value == null) return None;
            return Some(value ?? default(T));
        }
    }

    // ---------------------------------------------------------------- Result<T, E>
    public union Result<T, E>
    {
        Ok(T Value),
        Err(E Error);

        public prop IsOk: bool => __caso == 0;
        public prop IsErr: bool => __caso == 1;

        // El valor; con Err lanza UnwrapException ("Result.Unwrap(): Err(...)").
        [TrackCaller] public func Unwrap() -> T
        {
            if (__caso != 0) throw new UnwrapException("Result.Unwrap(): " + ToString());
            return __Ok_Value;
        }

        [TrackCaller] public func Expect(message: string) -> T
        {
            if (__caso != 0) throw new UnwrapException(message + ": " + ToString());
            return __Ok_Value;
        }

        // El error; con Ok lanza UnwrapException.
        [TrackCaller] public func UnwrapErr() -> E
        {
            if (__caso != 1) throw new UnwrapException("Result.UnwrapErr(): " + ToString());
            return __Err_Error;
        }

        public func UnwrapOr(other: T) -> T => __caso == 0 ? __Ok_Value : other;
        public func UnwrapOrDefault() -> T => __Ok_Value;  // con Err es default(T)
        public func UnwrapOrElse(f: Func<E, T>) -> T => __caso == 0 ? __Ok_Value : f(__Err_Error);

        public func Map<U>(f: Func<T, U>) -> Result<U, E>
        {
            if (__caso == 0) return Result<U, E>.Ok(f(__Ok_Value));
            return Result<U, E>.Err(__Err_Error);
        }

        public func MapErr<F>(f: Func<E, F>) -> Result<T, F>
        {
            if (__caso == 0) return Result<T, F>.Ok(__Ok_Value);
            return Result<T, F>.Err(f(__Err_Error));
        }

        public func AndThen<U>(f: Func<T, Result<U, E>>) -> Result<U, E>
        {
            if (__caso == 0) return f(__Ok_Value);
            return Result<U, E>.Err(__Err_Error);
        }

        public func Or(other: Result<T, E>) -> Result<T, E> => __caso == 0 ? this : other;
        public func OrElse(f: Func<E, Result<T, E>>) -> Result<T, E> => __caso == 0 ? this : f(__Err_Error);

        // Ok(v) -> Some(v); Err -> None   (y al revés para el error).
        public func ToOption() -> Option<T> => __caso == 0 ? Option<T>.Some(__Ok_Value) : Option<T>.None;
        public func ErrOption() -> Option<E> => __caso == 1 ? Option<E>.Some(__Err_Error) : Option<E>.None;

        public func Match<U>(ok: Func<T, U>, err: Func<E, U>) -> U => __caso == 0 ? ok(__Ok_Value) : err(__Err_Error);
    }

    // Result.Try(() => ...): ejecuta la función y convierte una excepción en un Err.
    public static class Result
    {
        public static func Try<T>(f: Func<T>) -> Result<T, Exception>
        {
            try
            {
                return Result<T, Exception>.Ok(f());
            }
            catch (Exception e)
            {
                return Result<T, Exception>.Err(e);
            }
        }
    }
}
