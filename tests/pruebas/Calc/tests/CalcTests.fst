// Pruebas de Calc: pasan, fallan, se ignoran, lanzan excepciones y hacen panic (tests/run.sh).
using std;
using std.collections;
using std.test;
using Calc;

public class OpsTests
{
    List<int> log;

    [Setup] public void Preparar() { log = new List<int>(); log.Add(1); }
    [Teardown] public void Limpiar() { println("teardown"); }

    [Test]
    public void Suma() { Assert.Equal(5, Ops.Suma(2, 3)); Assert.Equal(1, log.Count); }

    [TestCase(1, 2, 3)]
    [TestCase(-1, 1, 0)]
    [TestCase(2, 2, 5)]
    public void SumaCasos(int a, int b, int esperado) { Assert.Equal(esperado, Ops.Suma(a, b)); }

    [Test]
    public void Cadenas()
    {
        Assert.Contains("ola", "hola");
        Assert.NotEqual("a", "b");
        Assert.True(1 < 2);
        Assert.False(2 < 1);
        Assert.Null(null);
        Assert.NotNull(log);
        Assert.Near(1.4142, Ops.Raiz(2), 0.001);
    }

    [Test]
    public void DivisionPorCero()
    {
        var e = Assert.Throws<DivideByZeroException>(() => { Ops.Divide(1, 0); });
        Assert.NotNull(e);
    }

    [Test]
    public void FallaConMensaje() { Assert.Equal("hola", "adiós"); }

    [Test, Ignore("pendiente")]
    public void Pendiente() { Assert.Fail("no debe ejecutarse"); }

    [Test]
    public void Excepcion() { throw new InvalidOperationException("roto"); }
}

public static class PanicTests
{
    [Test]
    public static void Panico() { panic("explota"); }

    [Test]
    public static void TrasElPanico() { Assert.Equal(4, Ops.Suma(2, 2)); }
}
