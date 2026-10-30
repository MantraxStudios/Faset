// std.regex: coincidencias, grupos (con nombre), cuantificadores voraces y perezosos, anclas,
// opciones, Unicode, búsquedas alrededor, referencias, Replace ($n y evaluador), Split, Escape,
// errores de sintaxis y protección contra el retroceso catastrófico.
using std.regex;
using std.collections;
using std.text;
using std.time;

void Ver(string que, string obtenido) { println(que + ": " + obtenido); }

string Lista(List<string> l) => "[" + Text.Join(l, "|") + "]";

string Todas(string input, string patron) => Todas(input, patron, RegexOptions.None);

string Todas(string input, string patron, RegexOptions opciones)
{
    List<string> v = new List<string>();
    foreach (Match m in Regex.Matches(input, patron, opciones)) v.Add($"{m.Index}:{m.Value}");
    return Lista(v);
}

void main()
{
    // ---- básico
    println(Regex.IsMatch("hola mundo", "mun"));
    println(Regex.IsMatch("hola mundo", "^mundo"));
    Match m = Regex.Match("Fecha: 2024-05-17.", @"(\d{4})-(\d\d)-(\d\d)");
    println($"{m.Success} {m.Index} {m.Length} {m.Value} {m.Groups[1].Value}/{m.Groups[2].Value}/{m.Groups[3].Value} grupos={m.Groups.Count}");
    println(Regex.Match("abc", "x").Success);
    println(Regex.Match("abc", "x").Value.Length);

    // ---- grupos con nombre y sin captura
    var fecha = new Regex(@"(?<anio>\d{4})-(?<mes>\d\d)(?:-(?<dia>\d\d))?");
    Match f = fecha.Match("desde 2023-11 hasta 2024-02-29");
    println($"{f.Groups["anio"].Value} {f.Groups["mes"].Value} dia={f.Groups["dia"].Success}");
    Match f2 = f.NextMatch();
    println($"{f2.Groups["anio"].Value} {f2.Groups["mes"].Value} {f2.Groups["dia"].Value} {f2.Groups["dia"].Name}");
    println(Lista(fecha.GetGroupNames()));
    println($"{fecha.GroupNumberFromName("mes")} {fecha.GroupNumberFromName("nada")} {f.Groups["nada"].Success}");
    List<string> gs = new List<string>();
    foreach (Group g in f2.Groups) gs.Add(g.Name + "=" + g.Value);
    println(Lista(gs));

    // ---- cuantificadores
    Ver("voraz", Regex.Match("<a><b>", "<.+>").Value);
    Ver("perezoso", Regex.Match("<a><b>", "<.+?>").Value);
    Ver("{2,3}", Todas("aaaaaaa", "a{2,3}"));
    Ver("{2,3}?", Todas("aaaaa", "a{2,3}?"));
    Ver("vacías", Todas("abc", "x*"));
    Ver("a*", Todas("baaac", "a*"));
    Ver("alternancia", Todas("gato perro pez", "perro|gato|pe"));

    // ---- clases y escapes
    Ver("\\w+", Todas("año_2024, niño-ÑU", @"\w+"));
    Ver("\\d", Todas("a1b٣c", @"\d"));
    Ver("\\s", Regex.Replace("a \t b\nc", @"\s+", "_"));
    Ver("\\b", Todas("el elefante del", @"\bel\b"));
    Ver("[^aeiou ]", Regex.Replace("murciélago", "[^aeiou]", "."));
    Ver("rango", Todas("A-z 09 _", "[A-Z0-9_-]+"));
    Ver("\\p{Lu}", Todas("Árbol de Ébano", @"\p{Lu}"));
    Ver("resta", Todas("abcdefg", "[a-g-[aeiou]]+"));
    Ver("punto UTF-8", Regex.Match("€x", "^.").Value);

    // ---- opciones
    println(Regex.IsMatch("HOLA", "^hola$", RegexOptions.IgnoreCase));
    println(Regex.IsMatch("ÁRBOL", "árbol", RegexOptions.IgnoreCase));
    Ver("Multiline", Todas("uno\ndos\ntres", "(?m)^\\w+$"));
    Ver("sin Multiline", Todas("uno\ndos\ntres", "^\\w+$"));
    Ver("$ antes de \\n final", Regex.Match("fin\n", "fin$").Value);
    println(Regex.IsMatch("a\nb", "a.b"));
    println(Regex.IsMatch("a\nb", "a.b", RegexOptions.Singleline));
    println(Regex.Matches("Uno dos", "(?i)UNO|DOS").Count);
    Ver("combinadas", Todas("Ab\naB", "^ab$", RegexOptions.IgnoreCase | RegexOptions.Multiline));
    Ver("x", Regex.Match("tel: 555-1234", @"(\d{3}) - (\d{4})  # número", RegexOptions.IgnorePatternWhitespace).Value);
    Ver("ExplicitCapture", $"{new Regex(@"(a)(?<b>b)", RegexOptions.ExplicitCapture).Match("ab").Groups.Count}");

    // ---- búsquedas alrededor, referencias, grupos atómicos (motor de retroceso)
    Ver("(?=)", Todas("precio: 100€ 200$ 300€", @"\d+(?=€)"));
    Ver("(?!)", Todas("foo1 foo2 bar3", @"\b(?!foo)\w+"));
    Ver("(?<=)", Todas("$5 €7 $9", @"(?<=\$)\d"));
    Ver("(?<!)", Todas("x1 y2 x3", @"(?<!x)\d"));
    Ver("\\1", Todas("hola hola mundo mundo adiós", @"\b(\w+) \1\b"));
    Ver("\\k<n>", Regex.Match("abcabc", @"(?<t>abc)\k<t>").Value);
    Ver("(?>)", $"{Regex.IsMatch("aaab", "(?>a+)ab")} {Regex.IsMatch("aaab", "(?:a+)ab")}");

    // ---- Replace
    Ver("$2, $1", Regex.Replace("Juan Pérez", @"(\w+) (\w+)", "$2, $1"));
    Ver("${n}", Regex.Replace("2024-05", @"(?<a>\d+)-(?<m>\d+)", "${m}/${a}"));
    Ver("$$ $& $0", Regex.Replace("x=5", @"\d", "[$$ $& $0]"));
    Ver("$` $'", Regex.Replace("abc", "b", "<$`|$'>"));
    Ver("$9 sin grupo", Regex.Replace("ab", "(a)", "$9-$1"));
    Ver("evaluador", Regex.Replace("1 2 3", @"\d", x => $"{int.Parse(x.Value) * 10}"));
    Ver("count", new Regex("a").Replace("aaaa", "b", 2));
    Ver("vacío", Regex.Replace("abc", "", "-"));
    Ver("Result", Regex.Match("Ana 31", @"(\w+) (\d+)").Result("$2 años: $1"));

    // ---- Split
    Ver("Split", Lista(Regex.Split("a, b;c ,d", @"\s*[,;]\s*")));
    Ver("Split grupos", Lista(Regex.Split("1+2-3", "([+-])")));
    Ver("Split vacío", Lista(Regex.Split("abc", "")));
    Ver("Split sin coincidencias", Lista(Regex.Split("abc", "x")));
    Ver("Split count", Lista(new Regex(",").Split("a,b,c,d", 2)));

    // ---- Escape / Unescape
    string esc = Regex.Escape("1+1=2? (sí) [a] $5.00 #x");
    println(esc);
    println(Regex.IsMatch("total: 1+1=2? (sí) [a] $5.00 #x", esc));
    println(Regex.Unescape(esc));
    println(Regex.Unescape(@"a\tb\x41é"));

    // ---- Matches desde una posición y \G
    Ver("startat", Todas("x", "x") + " " + new Regex(@"\d").Match("1a2b3", 1).Value);
    Ver("\\G", $"{new Regex(@"\G\d").Match("12a3", 2).Success} {new Regex(@"\G\d").Match("12a3", 1).Value}");

    // ---- errores de sintaxis
    List<string> malos = new List<string>();
    malos.Add("(abc"); malos.Add("a)"); malos.Add("[a-"); malos.Add("a{2,1}"); malos.Add("*a");
    malos.Add(@"\k<x>"); malos.Add("(?<n>a)(?<n"); malos.Add(@"\p{Nada}");
    foreach (string p in malos)
    {
        try
        {
            new Regex(p);
            println("sin error: " + p);
        }
        catch (RegexParseException e) { println("error: " + e.Message); }
    }
    try { new Regex("(a"); } catch (ArgumentException e) { println("como ArgumentException: " + e.ParamName); }

    // ---- sin explosiones: (a+)+b con 30 000 'a' (Pike VM: tiempo lineal)
    string muchas = Text.Repeat("a", 30000);
    println(Regex.IsMatch(muchas, "(a+)+b"));
    println(Regex.IsMatch(muchas + "b", "^(a|aa)+b$"));
    // Con retroceso (referencia hacia atrás) el presupuesto o el tiempo límite cortan la búsqueda.
    try
    {
        new Regex(@"^(\w+\s?)*\1$", RegexOptions.None, TimeSpan.FromMilliseconds(200)).IsMatch(Text.Repeat("palabra ", 40) + "!");
        println("terminó");
    }
    catch (RegexMatchTimeoutException e) { println("tiempo agotado: " + (e.Pattern.Length > 0)); }
    try
    {
        new Regex("(a+)+b", RegexOptions.NonBacktracking);
        new Regex(@"(a)\1", RegexOptions.NonBacktracking);
    }
    catch (RegexParseException e) { println("NonBacktracking: " + e.Message); }
}
