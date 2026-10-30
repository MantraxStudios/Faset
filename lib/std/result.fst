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
        public UnwrapException(string message) { Message = message; }
    }

    // ---------------------------------------------------------------- Option<T>
    public union Option<T>
    {
        None,
        Some(T Value);

        public bool IsSome => __caso == 1;
        public bool IsNone => __caso == 0;

        // El valor; con None lanza UnwrapException.
        [TrackCaller] public T Unwrap()
        {
            if (__caso != 1) throw new UnwrapException("Option.Unwrap(): el valor es None");
            return __Some_Value;
        }

        // El valor; con None lanza UnwrapException con el mensaje indicado.
        [TrackCaller] public T Expect(string message)
        {
            if (__caso != 1) throw new UnwrapException(message);
            return __Some_Value;
        }

        public T UnwrapOr(T other) => __caso == 1 ? __Some_Value : other;
        public T UnwrapOrDefault() => __Some_Value;  // con None es default(T)
        public T UnwrapOrElse(Func<T> f) => __caso == 1 ? __Some_Value : f();

        public Option<U> Map<U>(Func<T, U> f)
        {
            if (__caso == 1) return Option<U>.Some(f(__Some_Value));
            return Option<U>.None;
        }

        public Option<U> AndThen<U>(Func<T, Option<U>> f)
        {
            if (__caso == 1) return f(__Some_Value);
            return Option<U>.None;
        }

        public Option<T> Filter(Func<T, bool> predicate)
        {
            if (__caso == 1 && predicate(__Some_Value)) return this;
            return None;
        }

        public Option<T> Or(Option<T> other) => __caso == 1 ? this : other;
        public Option<T> OrElse(Func<Option<T>> f) => __caso == 1 ? this : f();

        // Some(v) -> Ok(v); None -> Err(error).
        public Result<T, E> OkOr<E>(E error)
        {
            if (__caso == 1) return Result<T, E>.Ok(__Some_Value);
            return Result<T, E>.Err(error);
        }

        public U Match<U>(Func<T, U> some, Func<U> none) => __caso == 1 ? some(__Some_Value) : none();

        // T? con el valor (null si es None).
        public T? ToNullable()
        {
            T? r = null;
            if (__caso == 1) r = __Some_Value;
            return r;
        }

        public static Option<T> FromNullable(T? value)
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

        public bool IsOk => __caso == 0;
        public bool IsErr => __caso == 1;

        // El valor; con Err lanza UnwrapException ("Result.Unwrap(): Err(...)").
        [TrackCaller] public T Unwrap()
        {
            if (__caso != 0) throw new UnwrapException("Result.Unwrap(): " + ToString());
            return __Ok_Value;
        }

        [TrackCaller] public T Expect(string message)
        {
            if (__caso != 0) throw new UnwrapException(message + ": " + ToString());
            return __Ok_Value;
        }

        // El error; con Ok lanza UnwrapException.
        [TrackCaller] public E UnwrapErr()
        {
            if (__caso != 1) throw new UnwrapException("Result.UnwrapErr(): " + ToString());
            return __Err_Error;
        }

        public T UnwrapOr(T other) => __caso == 0 ? __Ok_Value : other;
        public T UnwrapOrDefault() => __Ok_Value;  // con Err es default(T)
        public T UnwrapOrElse(Func<E, T> f) => __caso == 0 ? __Ok_Value : f(__Err_Error);

        public Result<U, E> Map<U>(Func<T, U> f)
        {
            if (__caso == 0) return Result<U, E>.Ok(f(__Ok_Value));
            return Result<U, E>.Err(__Err_Error);
        }

        public Result<T, F> MapErr<F>(Func<E, F> f)
        {
            if (__caso == 0) return Result<T, F>.Ok(__Ok_Value);
            return Result<T, F>.Err(f(__Err_Error));
        }

        public Result<U, E> AndThen<U>(Func<T, Result<U, E>> f)
        {
            if (__caso == 0) return f(__Ok_Value);
            return Result<U, E>.Err(__Err_Error);
        }

        public Result<T, E> Or(Result<T, E> other) => __caso == 0 ? this : other;
        public Result<T, E> OrElse(Func<E, Result<T, E>> f) => __caso == 0 ? this : f(__Err_Error);

        // Ok(v) -> Some(v); Err -> None   (y al revés para el error).
        public Option<T> ToOption() => __caso == 0 ? Option<T>.Some(__Ok_Value) : Option<T>.None;
        public Option<E> ErrOption() => __caso == 1 ? Option<E>.Some(__Err_Error) : Option<E>.None;

        public U Match<U>(Func<T, U> ok, Func<E, U> err) => __caso == 0 ? ok(__Ok_Value) : err(__Err_Error);
    }

    // Result.Try(() => ...): ejecuta la función y convierte una excepción en un Err.
    public static class Result
    {
        public static Result<T, Exception> Try<T>(Func<T> f)
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
