using std;
union Forma { Circulo(double R), Rect(double A, double B), Punto }
union Expr { Num(int V), Neg(Expr E) }
class P
{
    static int A(Forma f) => f switch { Circulo(var r) => 1, Punto => 2 };
    static int B(Option<Option<int>> o) => o switch { Some(Some(var x)) => x, None => 0 };
    static int C(Forma f) => f switch { Triangulo(var x) => 1, _ => 0 };
    static int D(Forma f) => f switch { Rect(var a) => 1, _ => 0 };
    static void E() { var x = None; }
    static int F(string s) { int n = s?; return n; }
    static Result<int, string> G() => Ok(1);
    static int H() { int v = G()?; return v; }
    static void Main()
    {
        Forma f = Forma.Circulo(1, 2);
        Forma g = Forma.Punto();
        Option<int> o = Err("x");
    }
}
