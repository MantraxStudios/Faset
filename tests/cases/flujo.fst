// defer / errdefer (orden inverso, return, break, excepciones, '?') y el operador |>.
using std;
using std.collections;

static class Ext
{
    public static int Triple(this int x) => x * 3;
}

class Programa
{
    static List<string> Log = new List<string>();

    static int ConDefer(int n)
    {
        defer Log.Add("primero registrado");
        defer Log.Add("segundo registrado");
        if (n > 0) return n * 2;
        Log.Add("cuerpo");
        return 0;
    }

    static void EnBucle()
    {
        for (int i = 0; i < 3; i++)
        {
            defer Log.Add("fin " + i);
            if (i == 1) continue;
            if (i == 2) break;
            Log.Add("vuelta " + i);
        }
    }

    static void Lanza(bool fallar)
    {
        defer Log.Add("defer siempre");
        errdefer Log.Add("errdefer: solo con error");
        if (fallar) throw new Exception("boom");
        Log.Add("sin error");
    }

    static Result<int, string> Parsear(string s)
    {
        int n;
        if (int.TryParse(s, out n)) return Ok(n);
        return Err("no es un número: " + s);
    }

    static Result<int, string> ConPropagacion(string s)
    {
        errdefer Log.Add("errdefer por '?' con " + s);
        int n = Parsear(s)?;
        return Ok(n + 1);
    }

    static int Doble(int x) => x * 2;
    static int Suma(int a, int b) => a + b;

    static void Volcar()
    {
        foreach (var l in Log) println(l);
        Log.Clear();
    }

    static void Main()
    {
        println(ConDefer(5));
        Volcar();
        println(ConDefer(0));
        Volcar();
        EnBucle();
        Volcar();
        Lanza(false);
        Volcar();
        try { Lanza(true); } catch (Exception e) { println("atrapada: " + e.Message); }
        Volcar();
        println(ConPropagacion("4").ToString());
        Volcar();
        println(ConPropagacion("x").ToString());
        Volcar();

        // |> pasa el valor como primer argumento.
        println(5 |> Doble);
        println(5 |> Suma(10));
        println(5 |> Doble |> Suma(1) |> Doble);
        println(4 |> Triple());
        println(7 |> x => x * x);
        Func<int, int> neg = x => -x;
        println(3 |> (neg));
        println("hola" |> ToUpper());
    }
}
