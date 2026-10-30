// Option<T> y Result<T, E>, el operador '?' de propagación, conversión de errores (From e
// 'implicit'), interoperabilidad con T? y con las excepciones.
using std;
using std.collections;
using std.task;

class ErrorApp
{
    public string Texto;
    public ErrorApp(string t) { Texto = t; }
    public static ErrorApp From(string s) => new ErrorApp("app: " + s);
    public override string ToString() => "ErrorApp(" + Texto + ")";
}

class Base { public virtual string Q() => "base"; }
class Derivado : Base { public override string Q() => "derivado"; }

class Programa
{
    static Result<int, string> Parsear(string s)
    {
        int n;
        if (int.TryParse(s, out n)) return Ok(n);
        return Err("no es un número: " + s);
    }

    static Result<int, string> SumaDe(string a, string b)
    {
        int x = Parsear(a)?;
        var y = Parsear(b)?;
        return Ok(x + y);
    }

    static Result<int, ErrorApp> ConFrom(string s)
    {
        int n = Parsear(s)?;   // string -> ErrorApp con ErrorApp.From
        return Ok(n * 10);
    }

    static Result<int, long> Codigos(Result<int, int> r)
    {
        return Ok(r? + 1);    // int -> long (conversión implícita)
    }

    static Result<int, Base> Clases(Result<int, Derivado> r)
    {
        int v = r?;           // Derivado -> Base
        return Ok(v);
    }

    static Option<int> Primero(List<int> l) => l.Count > 0 ? Some(l[0]) : None;

    static Option<int> DobleDelPrimero(List<int> l)
    {
        int v = Primero(l)?;
        return Some(v * 2);
    }

    static Option<string> Largo(string? s) => s is string t && t.Length > 3 ? Some(t) : None;

    static int Llamadas = 0;
    static Result<int, string> Contar(int v) { Llamadas++; return v < 0 ? Err("negativo") : Ok(v); }

    // '?' dentro de una expresión: los operandos se evalúan en orden.
    static Result<int, string> Expresion(int a, int b) => Ok(Contar(a)? * 100 + Contar(b)?);

    static async Task<Result<int, string>> Asincrono(string s)
    {
        await Task.Delay(1);
        int n = Parsear(s)?;
        await Task.Delay(1);
        return Ok(n + 1);
    }

    static List<string> L(string a, string b, string c)
    {
        var l = new List<string>();
        l.Add(a);
        l.Add(b);
        l.Add(c);
        return l;
    }

    static Result<int, string> EnBucle(List<string> partes)
    {
        int total = 0;
        foreach (var p in partes)
        {
            total += Parsear(p)?;
        }
        return Ok(total);
    }

    static void Main()
    {
        println((Parsear("12")).ToString());
        println((Parsear("x")).ToString());
        println((SumaDe("1", "2")).ToString());
        println((SumaDe("1", "dos")).ToString());
        println((ConFrom("3")).ToString());
        println((ConFrom("tres")).ToString());
        println((Codigos(Ok(4))).ToString());
        println((Codigos(Err(7))).ToString());
        println(Clases(Err(new Derivado())) switch { Err(var b) => b.Q(), Ok(var v) => "ok" });
        var una = new List<int>();
        una.Add(21);
        println((DobleDelPrimero(una)).ToString());
        println((DobleDelPrimero(new List<int>())).ToString());
        println((Largo("hola")).ToString());
        println((Largo("ho")).ToString());
        println((Largo(null)).ToString());
        println((Expresion(1, 2)).ToString());
        println((Expresion(-1, 2)).ToString());
        println(Llamadas);
        println((Asincrono("41").Result).ToString());
        println((Asincrono("z").Result).ToString());
        println((EnBucle(L("1", "2", "3"))).ToString());
        println((EnBucle(L("1", "b", "3"))).ToString());

        // Combinadores.
        Result<int, string> bien = Ok(5);
        Result<int, string> mal = Err("fallo");
        println(bien.IsOk + " " + mal.IsErr);
        println((bien.Map(x => x * 2)).ToString());
        println((mal.Map(x => x * 2)).ToString());
        println((bien.AndThen(x => x > 3 ? Ok(x) : Err("pequeño"))).ToString());
        println((bien.AndThen(x => x > 9 ? Result<int, string>.Ok(x) : Result<int, string>.Err("pequeño"))).ToString());
        println((mal.MapErr(e => e.Length)).ToString());
        println(mal.UnwrapOr(-1));
        println(mal.UnwrapOrElse(e => e.Length));
        println(bien.Unwrap());
        println((bien.ToOption()).ToString());
        println(mal.Match(v => "valor " + v, e => "error " + e));

        Option<string> nombre = Some("Ana");
        Option<string> nadie = None;
        println(nombre.IsSome + " " + nadie.IsNone);
        println((nombre.Map(s => s.Length)).ToString());
        println((nadie.Map(s => s.Length)).ToString());
        println(nadie.UnwrapOr("anónimo"));
        println((nombre.Filter(s => s.StartsWith("B"))).ToString());
        println((nadie.OkOr("vacío")).ToString());
        println(nombre == Some("Ana"));
        println(nombre == nadie);

        // Interoperabilidad con T?.
        int? quizas = 3;
        Option<int> o = quizas;
        println((o).ToString());
        int? nulo = null;
        Option<int> o2 = nulo;
        println((o2).ToString());
        int? vuelta = Option<int>.Some(8);
        println(vuelta ?? -1);
        int? vacio = Option<int>.None.ToNullable();
        println(vacio == null);

        // Unwrap lanza UnwrapException: se puede atrapar.
        try
        {
            mal.Unwrap();
        }
        catch (UnwrapException ex)
        {
            println("atrapada: " + ex.Message);
        }
        try
        {
            nadie.Expect("se esperaba un nombre");
        }
        catch (UnwrapException ex)
        {
            println("atrapada: " + ex.Message);
        }

        // Result.Try convierte una excepción en un Err.
        var t1 = Result.Try(() => int.Parse("77"));
        var t2 = Result.Try(() => int.Parse("x7"));
        println((t1).ToString());
        println(t2.IsErr);
        println(t2 switch { Ok(var v) => "ok", Err(var ex) => "error: " + ex.Message });

        // switch exhaustivo sobre Result / Option con patrones anidados.
        foreach (var s in L("5", "50", "no"))
        {
            string d = Parsear(s) match
            {
                Ok(> 10) => "grande",
                Ok(var v) => "pequeño " + v,
                Err(var e) => e,
            };
            println(d);
        }
        Option<Option<int>> anidada = Some(Some(1));
        println(anidada switch { Some(Some(var x)) => x, Some(None) => -1, None => -2 });
    }
}
