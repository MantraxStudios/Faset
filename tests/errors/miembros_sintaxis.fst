// Errores de sintaxis de constructores estáticos, tipos anidados e indizadores.
class A
{
    static A() { }
    static A() { }
    public static A(int x) { }
}

interface IB { class X { } }

class C
{
    static C() : base() { }
}

class D
{
    public int this[int i] { }
}
