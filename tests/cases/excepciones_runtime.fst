// Errores del runtime como excepciones (con un 'try' activo) y excepciones de la biblioteca:
// nulos, índices, divisiones, punteros a función, List, Dictionary, Queue, Convert, int.Parse,
// File.ReadAllText, Substring y DateTime.
using std.collections;
using std.io;
using std.time;

class Nodo
{
    public int Valor;
    public Nodo Siguiente;
}

int Cero() => 0;
int MenosUno() => -1;

string Probar(int caso)
{
    try
    {
        Nodo n = null;
        string s = "abc";
        var lista = new List<int>();
        lista.Add(1);
        var dic = new Dictionary<string, int>();
        dic.Set("uno", 1);
        switch (caso)
        {
            case 0: return "valor " + n.Valor;
            case 1: return "byte " + (int)s[10];
            case 2: return "div " + (10 / Cero());
            case 3: return "mod " + (10 % Cero());
            case 4: { int m = int.MinValue; return "ovf " + (m / MenosUno()); }
            case 5: { long x = 5; x /= Cero(); return "div= " + x; }
            case 6: { delegate*<int> f = null; return "fn " + f(); }
            case 7: return "lista " + lista[3];
            case 8: { lista.RemoveAt(-1); return "nunca"; }
            case 9: return "get " + dic.Get("dos");
            case 10: { var q = new Queue<int>(); return "cola " + q.Dequeue(); }
            case 11: { var st = new Stack<int>(); return "pila " + st.Pop(); }
            case 12: return "convert " + Convert.ToInt32("doce");
            case 13: return "parse " + int.Parse("12x");
            case 14: return "parse " + int.Parse("99999999999");
            case 15: return "double " + double.Parse("1,5,6");
            case 16: return "archivo " + File.ReadAllText("/no/existe/de/verdad.txt");
            case 17: return "sub " + s.Substring(2, 5);
            case 18: return "fecha " + DateTime.ParseIso("ayer").Year;
            case 19: return "lista vacía " + new List<int>().First();
            case 20: return "bool " + bool.Parse("quizá");
        }
        return "sin error";
    }
    catch (NullReferenceException e) { return "NullReferenceException: " + e.Message; }
    catch (IndexOutOfRangeException e) { return "IndexOutOfRangeException: " + e.Message; }
    catch (ArithmeticException e) { return e.TypeName + ": " + e.Message; }
    catch (ArgumentOutOfRangeException e) { return "ArgumentOutOfRangeException: " + e.Message; }
    catch (KeyNotFoundException e) { return "KeyNotFoundException: " + e.Message; }
    catch (InvalidOperationException e) { return "InvalidOperationException: " + e.Message; }
    catch (FormatException e) { return "FormatException: " + e.Message; }
    catch (FileNotFoundException e) { return "FileNotFoundException: " + e.FileName; }
}

void main()
{
    for (int i = 0; i <= 21; i++) println(i + " -> " + Probar(i));

    // TryParse no lanza nada.
    int v = 0;
    bool ok = int.TryParse(" 42 ", out v);
    println(ok + " " + v);
    println(int.TryParse("x", out v));
    long l = 0;
    ok = long.TryParse("-9000000000", out l);
    println(ok + " " + l);
    double d = 0;
    ok = double.TryParse("2.5", out d);
    println(ok + " " + d);
    bool b = false;
    ok = bool.TryParse("TRUE", out b);
    println(ok + " " + b);
    println(int.Parse("-17") + long.Parse("3"));
    println(char.IsDigit('7'));

    // El indexador de string sigue lanzando dentro de funciones llamadas desde el try.
    try { println(Cadena("hola", 9)); }
    catch (Exception e) { println(e.TypeName + " | " + e.StackTrace.Trim()); }
}

char Cadena(string s, int i) => (char)s[i];
