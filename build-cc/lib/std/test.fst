// =============================================================================
//  std.test  —  pruebas unitarias para 'faset test'.
//
//    using std.test;
//
//    public class CalculadoraTests
//    {
//        [Setup]    public void Preparar() { ... }       // antes de cada prueba de la clase
//        [Teardown] public void Limpiar() { ... }        // después de cada una (aunque falle)
//
//        [Test]
//        public void Suma() { Assert.Equal(4, 2 + 2); }
//
//        [TestCase(1, 2, 3)]
//        [TestCase(-1, 1, 0)]
//        public void SumaVarios(int a, int b, int esperado) { Assert.Equal(esperado, a + b); }
//
//        [Test, Ignore("pendiente del nuevo motor")]
//        public void Lenta() { ... }
//    }
//
//  'faset test' busca los métodos [Test] y [TestCase], genera el 'main' que los ejecuta y
//  muestra un resumen. Cada prueba corre dentro de un 'try': una aserción que falla o una
//  excepción la marca como fallida y se sigue con la siguiente. Un panic (que termina el
//  proceso) también se informa: el ejecutor vuelve a lanzar el programa desde la prueba siguiente.
//
//  Assert: Equal, NotEqual, True, False, Null, NotNull, Throws<E>, Near, Contains,
//          DoesNotContain, Fail. Todas son [TrackCaller]: el fallo apunta a la línea de la prueba.
// =============================================================================
using std.collections;
using std.text;
using std.time;

namespace std.test
{
    // ---------------------------------------------------------------- AssertException
    // La lanza una aserción que no se cumple. Expected y Actual describen los dos valores
    // (HasValues indica si la aserción los compara).
    public class AssertException : Exception
    {
        public var Expected: string;
        public var Actual: string;
        public var HasValues: bool;

        public init(message: string) : base(message)
        {
            Expected = "";
            Actual = "";
        }

        public init(message: string, expected: string, actual: string) : base(message)
        {
            Expected = expected;
            Actual = actual;
            HasValues = true;
        }
    }

    // ---------------------------------------------------------------- Assert
    public static class Assert
    {
        // Texto de un valor para los mensajes (las cadenas, entre comillas).
        public static func Show<T>(value: T) -> string => Describe(value);
        static func Describe<T>(value: T) -> string where T : struct => $"{value}";
        static func Describe(value: object) -> string => value == null ? "null" : value.ToString();
        static func Describe(value: string) -> string => "\"" + value + "\"";
        static func Describe(value: bool) -> string => value ? "true" : "false";
        static func Describe(value: char) -> string => "'" + value + "'";

        static func With(what: string, message: string) -> string => message.Length > 0 ? what + ": " + message : what;

        [TrackCaller] public static func Equal<T>(expected: T, actual: T) { Equal(expected, actual, ""); }
        [TrackCaller] public static func Equal<T>(expected: T, actual: T, message: string)
        {
            if (!(expected == actual))
                throw new AssertException(With("Assert.Equal: los valores no coinciden", message), Show(expected), Show(actual));
        }

        // Enteros y reales de tipos distintos (Assert.Equal(5, x) con 'long x').
        [TrackCaller] public static func Equal(expected: long, actual: long) { Equal<long>(expected, actual, ""); }
        [TrackCaller] public static func Equal(expected: long, actual: long, message: string) { Equal<long>(expected, actual, message); }
        [TrackCaller] public static func Equal(expected: double, actual: double) { Equal<double>(expected, actual, ""); }
        [TrackCaller] public static func Equal(expected: double, actual: double, message: string) { Equal<double>(expected, actual, message); }

        [TrackCaller] public static func NotEqual<T>(notExpected: T, actual: T) { NotEqual(notExpected, actual, ""); }
        [TrackCaller] public static func NotEqual<T>(notExpected: T, actual: T, message: string)
        {
            if (notExpected == actual)
                throw new AssertException(With("Assert.NotEqual: los valores son iguales", message), "distinto de " + Show(notExpected),
                                          Show(actual));
        }

        [TrackCaller] public static func NotEqual(notExpected: long, actual: long) { NotEqual<long>(notExpected, actual, ""); }
        [TrackCaller] public static func NotEqual(notExpected: double, actual: double) { NotEqual<double>(notExpected, actual, ""); }

        [TrackCaller] public static func True(condition: bool) { True(condition, ""); }
        [TrackCaller] public static func True(condition: bool, message: string)
        {
            if (!condition) throw new AssertException(With("Assert.True: la condición es falsa", message), "true", "false");
        }

        [TrackCaller] public static func False(condition: bool) { False(condition, ""); }
        [TrackCaller] public static func False(condition: bool, message: string)
        {
            if (condition) throw new AssertException(With("Assert.False: la condición es verdadera", message), "false", "true");
        }

        // Objetos (clases); 'null' de un T? se comprueba con Assert.False(x.HasValue).
        [TrackCaller] public static func Null(value: object) { Null(value, ""); }
        [TrackCaller] public static func Null(value: object, message: string)
        {
            if (value != null) throw new AssertException(With("Assert.Null: el valor no es null", message), "null", Show(value));
        }

        [TrackCaller] public static func NotNull(value: object) { NotNull(value, ""); }
        [TrackCaller] public static func NotNull(value: object, message: string)
        {
            if (value == null) throw new AssertException(With("Assert.NotNull: el valor es null", message), "distinto de null", "null");
        }

        // |expected - actual| <= tolerance (para double y float).
        [TrackCaller] public static func Near(expected: double, actual: double, tolerance: double) { Near(expected, actual, tolerance, ""); }
        [TrackCaller] public static func Near(expected: double, actual: double, tolerance: double, message: string)
        {
            double d = expected - actual;
            if (d < 0) d = -d;
            if (!(d <= tolerance))
                throw new AssertException(With("Assert.Near: la diferencia es " + d + " (tolerancia " + tolerance + ")", message),
                                          Show(expected), Show(actual));
        }

        // La cadena contiene el fragmento.
        [TrackCaller] public static func Contains(expectedSubstring: string, actual: string)
        {
            if (!actual.Contains(expectedSubstring))
                throw new AssertException("Assert.Contains: la cadena no contiene el fragmento", "contiene " + Show(expectedSubstring),
                                          Show(actual));
        }

        // La lista contiene el elemento.
        [TrackCaller] public static func Contains<T>(expected: T, collection: List<T>)
        {
            if (!collection.Contains(expected))
                throw new AssertException("Assert.Contains: la lista no contiene el elemento", "contiene " + Show(expected),
                                          collection.Count + " elemento(s)");
        }

        [TrackCaller] public static func DoesNotContain(unexpectedSubstring: string, actual: string)
        {
            if (actual.Contains(unexpectedSubstring))
                throw new AssertException("Assert.DoesNotContain: la cadena contiene el fragmento",
                                          "no contiene " + Show(unexpectedSubstring), Show(actual));
        }

        [TrackCaller] public static func DoesNotContain<T>(unexpected: T, collection: List<T>)
        {
            if (collection.Contains(unexpected))
                throw new AssertException("Assert.DoesNotContain: la lista contiene el elemento", "no contiene " + Show(unexpected),
                                          collection.Count + " elemento(s)");
        }

        // La acción lanza una excepción de tipo E (o derivada); la devuelve para seguir comprobándola.
        [TrackCaller] public static func Throws<E>(action: Action) -> E
        {
            try
            {
                action();
            }
            catch (E e)
            {
                return e;
            }
            catch (Exception other)
            {
                throw new AssertException("Assert.Throws: se lanzó otra excepción (" + other.Message + ")", typeof(E).Name, other.TypeName);
            }
            throw new AssertException("Assert.Throws: no se lanzó ninguna excepción", typeof(E).Name, "sin excepción");
        }

        // Falla siempre.
        [TrackCaller] public static func Fail(message: string) { throw new AssertException("Assert.Fail: " + message); }
        [TrackCaller] public static func Fail() { throw new AssertException("Assert.Fail"); }
    }

    // ---------------------------------------------------------------- TestHarness
    // Lo usa el 'main' que genera 'faset test' (no hace falta usarlo a mano). Informa de cada
    // prueba en la salida estándar con líneas "##faset-test## ..." que lee el ejecutor.
    public class TestHarness
    {
        var from: int;
        var current: int;
        var started: long;

        public init()
        {
            for (int i = 1; i + 1 < Environment.ArgCount(); i++)
                if (Environment.GetArg(i) == "--faset-test-desde") from = Environment.GetArg(i + 1).ToInt();
        }

        // ¿Hay que ejecutar la prueba 'index'? (tras un panic se sigue desde la siguiente)
        public func Start(index: int) -> bool
        {
            if (index < from) return false;
            current = index;
            Emit("begin " + index);
            started = Time.TickNs();
            return true;
        }

        public func Pass() { Emit("pass " + current + " " + Micros()); }

        public func Fail(e: Exception)
        {
            long us = Micros();
            Emit("type " + current + " " + Escape(e.TypeName));
            Emit("msg " + current + " " + Escape(e.Message));
            Emit("trace " + current + " " + Escape(e.StackTrace));
            if (e is AssertException a)
            {
                if (a.HasValues)
                {
                    Emit("expected " + current + " " + Escape(a.Expected));
                    Emit("actual " + current + " " + Escape(a.Actual));
                }
            }
            Emit("fail " + current + " " + us);
        }

        public func Finish() -> int
        {
            Emit("end");
            return 0;
        }

        func Micros() -> long => (Time.TickNs() - started) / 1000;

        static func Escape(s: string) -> string => Text.Replace(Text.Replace(Text.Replace(s, "\\", "\\\\"), "\r", "\\r"), "\n", "\\n");

        static func Emit(line: string)
        {
            Console.WriteLine("##faset-test## " + line);
            Console.Flush();
        }
    }
}
