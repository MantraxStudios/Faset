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
        public string Expected;
        public string Actual;
        public bool HasValues;

        public AssertException(string message) : base(message)
        {
            Expected = "";
            Actual = "";
        }

        public AssertException(string message, string expected, string actual) : base(message)
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
        public static string Show<T>(T value) => Describe(value);
        static string Describe<T>(T value) where T : struct => $"{value}";
        static string Describe(object value) => value == null ? "null" : value.ToString();
        static string Describe(string value) => "\"" + value + "\"";
        static string Describe(bool value) => value ? "true" : "false";
        static string Describe(char value) => "'" + value + "'";

        static string With(string what, string message) => message.Length > 0 ? what + ": " + message : what;

        [TrackCaller] public static void Equal<T>(T expected, T actual) { Equal(expected, actual, ""); }
        [TrackCaller] public static void Equal<T>(T expected, T actual, string message)
        {
            if (!(expected == actual))
                throw new AssertException(With("Assert.Equal: los valores no coinciden", message), Show(expected), Show(actual));
        }

        // Enteros y reales de tipos distintos (Assert.Equal(5, x) con 'long x').
        [TrackCaller] public static void Equal(long expected, long actual) { Equal<long>(expected, actual, ""); }
        [TrackCaller] public static void Equal(long expected, long actual, string message) { Equal<long>(expected, actual, message); }
        [TrackCaller] public static void Equal(double expected, double actual) { Equal<double>(expected, actual, ""); }
        [TrackCaller] public static void Equal(double expected, double actual, string message) { Equal<double>(expected, actual, message); }

        [TrackCaller] public static void NotEqual<T>(T notExpected, T actual) { NotEqual(notExpected, actual, ""); }
        [TrackCaller] public static void NotEqual<T>(T notExpected, T actual, string message)
        {
            if (notExpected == actual)
                throw new AssertException(With("Assert.NotEqual: los valores son iguales", message), "distinto de " + Show(notExpected),
                                          Show(actual));
        }

        [TrackCaller] public static void NotEqual(long notExpected, long actual) { NotEqual<long>(notExpected, actual, ""); }
        [TrackCaller] public static void NotEqual(double notExpected, double actual) { NotEqual<double>(notExpected, actual, ""); }

        [TrackCaller] public static void True(bool condition) { True(condition, ""); }
        [TrackCaller] public static void True(bool condition, string message)
        {
            if (!condition) throw new AssertException(With("Assert.True: la condición es falsa", message), "true", "false");
        }

        [TrackCaller] public static void False(bool condition) { False(condition, ""); }
        [TrackCaller] public static void False(bool condition, string message)
        {
            if (condition) throw new AssertException(With("Assert.False: la condición es verdadera", message), "false", "true");
        }

        // Objetos (clases); 'null' de un T? se comprueba con Assert.False(x.HasValue).
        [TrackCaller] public static void Null(object value) { Null(value, ""); }
        [TrackCaller] public static void Null(object value, string message)
        {
            if (value != null) throw new AssertException(With("Assert.Null: el valor no es null", message), "null", Show(value));
        }

        [TrackCaller] public static void NotNull(object value) { NotNull(value, ""); }
        [TrackCaller] public static void NotNull(object value, string message)
        {
            if (value == null) throw new AssertException(With("Assert.NotNull: el valor es null", message), "distinto de null", "null");
        }

        // |expected - actual| <= tolerance (para double y float).
        [TrackCaller] public static void Near(double expected, double actual, double tolerance) { Near(expected, actual, tolerance, ""); }
        [TrackCaller] public static void Near(double expected, double actual, double tolerance, string message)
        {
            double d = expected - actual;
            if (d < 0) d = -d;
            if (!(d <= tolerance))
                throw new AssertException(With("Assert.Near: la diferencia es " + d + " (tolerancia " + tolerance + ")", message),
                                          Show(expected), Show(actual));
        }

        // La cadena contiene el fragmento.
        [TrackCaller] public static void Contains(string expectedSubstring, string actual)
        {
            if (!actual.Contains(expectedSubstring))
                throw new AssertException("Assert.Contains: la cadena no contiene el fragmento", "contiene " + Show(expectedSubstring),
                                          Show(actual));
        }

        // La lista contiene el elemento.
        [TrackCaller] public static void Contains<T>(T expected, List<T> collection)
        {
            if (!collection.Contains(expected))
                throw new AssertException("Assert.Contains: la lista no contiene el elemento", "contiene " + Show(expected),
                                          collection.Count + " elemento(s)");
        }

        [TrackCaller] public static void DoesNotContain(string unexpectedSubstring, string actual)
        {
            if (actual.Contains(unexpectedSubstring))
                throw new AssertException("Assert.DoesNotContain: la cadena contiene el fragmento",
                                          "no contiene " + Show(unexpectedSubstring), Show(actual));
        }

        [TrackCaller] public static void DoesNotContain<T>(T unexpected, List<T> collection)
        {
            if (collection.Contains(unexpected))
                throw new AssertException("Assert.DoesNotContain: la lista contiene el elemento", "no contiene " + Show(unexpected),
                                          collection.Count + " elemento(s)");
        }

        // La acción lanza una excepción de tipo E (o derivada); la devuelve para seguir comprobándola.
        [TrackCaller] public static E Throws<E>(Action action)
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
        [TrackCaller] public static void Fail(string message) { throw new AssertException("Assert.Fail: " + message); }
        [TrackCaller] public static void Fail() { throw new AssertException("Assert.Fail"); }
    }

    // ---------------------------------------------------------------- TestHarness
    // Lo usa el 'main' que genera 'faset test' (no hace falta usarlo a mano). Informa de cada
    // prueba en la salida estándar con líneas "##faset-test## ..." que lee el ejecutor.
    public class TestHarness
    {
        int from;
        int current;
        long started;

        public TestHarness()
        {
            for (int i = 1; i + 1 < Environment.ArgCount(); i++)
                if (Environment.GetArg(i) == "--faset-test-desde") from = Environment.GetArg(i + 1).ToInt();
        }

        // ¿Hay que ejecutar la prueba 'index'? (tras un panic se sigue desde la siguiente)
        public bool Start(int index)
        {
            if (index < from) return false;
            current = index;
            Emit("begin " + index);
            started = Time.TickNs();
            return true;
        }

        public void Pass() { Emit("pass " + current + " " + Micros()); }

        public void Fail(Exception e)
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

        public int Finish()
        {
            Emit("end");
            return 0;
        }

        long Micros() => (Time.TickNs() - started) / 1000;

        static string Escape(string s) => Text.Replace(Text.Replace(Text.Replace(s, "\\", "\\\\"), "\r", "\\r"), "\n", "\\n");

        static void Emit(string line)
        {
            Console.WriteLine("##faset-test## " + line);
            Console.Flush();
        }
    }
}
