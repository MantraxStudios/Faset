// Proyecto de pruebas (<IsTestProject>): sin Main, se ejecuta con 'faset test'.
using std;
using std.test;

public class CadenasTests
{
    [Test]
    public void Mayusculas() { Assert.Equal("HOLA", "hola".ToUpper()); }

    [TestCase("abc", 3)]
    [TestCase("", 0)]
    public static void Longitud(string s, int n) { Assert.Equal(n, s.Length); }
}
