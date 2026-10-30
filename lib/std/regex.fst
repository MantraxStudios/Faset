// =============================================================================
//  std.regex  —  expresiones regulares con la sintaxis de .NET (System.Text.RegularExpressions).
//
//    var r = new Regex(@"(?<anio>\d{4})-(?<mes>\d\d)");
//    Match m = r.Match("Fecha: 2024-05");
//    if (m.Success) println($"{m.Groups["anio"].Value} / {m.Groups[2].Value}");   // 2024 / 05
//
//    foreach (Match x in Regex.Matches("a1 b22 c333", @"\d+")) println(x.Value);
//    string s = Regex.Replace("Juan Pérez", @"(\w+) (\w+)", "$2, $1");              // "Pérez, Juan"
//    string t = Regex.Replace("1 2 3", @"\d", m => $"{int.Parse(m.Value) * 10}");   // "10 20 30"
//    List<string> partes = Regex.Split("a, b;c", @"[,;]\s*");                       // a | b | c
//    bool ok = Regex.IsMatch("HOLA", "^hola$", RegexOptions.IgnoreCase);
//
//  Admite: clases [a-z] [^...] [a-z-[aeiou]], \d \w \s \b \B \A \z \Z \G (Unicode: \w y \d
//  reconocen letras y dígitos de otros alfabetos), \p{L} \p{Lu} \p{N}..., cuantificadores
//  * + ? {n} {n,} {n,m} y sus versiones perezosas (*? +? ...), alternancia, grupos con
//  captura, con nombre (?<n>...) y sin captura (?:...), referencias \1 y \k<n>, búsquedas
//  alrededor (?=...) (?!...) (?<=...) (?<!...), grupos atómicos (?>...) y opciones en línea
//  (?i) (?m) (?s) (?n) (?x). No admite RightToLeft ni grupos de balanceo (?<a-b>...).
//
//  Motor (lib/regex/faset_regex.c): una Pike VM de tiempo lineal para casi todos los patrones,
//  así que (a+)+b no explota con textos largos. Los patrones con referencias hacia atrás,
//  búsquedas alrededor o grupos atómicos usan retroceso con un presupuesto de pasos (y el
//  tiempo límite opcional del constructor): si se agota, se lanza RegexMatchTimeoutException.
//
//  Las posiciones (Index, Length, startat) son de bytes en el texto UTF-8, como en el resto de
//  std (Substring, IndexOf). '.' y las clases consumen un carácter completo.
//  Un patrón mal escrito lanza RegexParseException (es un ArgumentException).
// =============================================================================
using std.collections;
using std.text;
using std.time;

namespace std.regex
{
    // Opciones (se combinan con '|'). Los valores son los de .NET.
    public enum RegexOptions
    {
        None = 0,
        IgnoreCase = 1,               // sin distinguir mayúsculas (también á/Á, ñ/Ñ...)
        Multiline = 2,                // ^ y $ en cada línea
        ExplicitCapture = 4,          // solo capturan los grupos con nombre
        Singleline = 16,              // '.' también coincide con '\n'
        IgnorePatternWhitespace = 32, // espacios y comentarios '#' del patrón se ignoran
        NonBacktracking = 1024        // exige el motor lineal (error si el patrón necesita retroceso)
    }

    // El patrón no es válido. Offset es la posición (en bytes) donde se detectó el error.
    [ExceptionBase("ArgumentException")]
    public class RegexParseException
    {
        public int Offset;

        public RegexParseException() { Message = "El patrón de la expresión regular no es válido."; }
        public RegexParseException(string message) { Message = message; }

        public string ToString() => Exception.Describe(this);
    }

    // La búsqueda superó el tiempo límite o el presupuesto de pasos del motor de retroceso.
    [ExceptionBase("Exception")]
    public class RegexMatchTimeoutException
    {
        public string Pattern;
        public string Input;

        public RegexMatchTimeoutException() { Message = "Se agotó el tiempo de la expresión regular."; }
        public RegexMatchTimeoutException(string message) { Message = message; }

        public string ToString() => Exception.Describe(this);
    }

    // Funciones de lib/regex/faset_regex.c.
    memory_unsafe static class RegexNative
    {
        public static extern void* faset_regex_compile(string pattern, int options, string* error);
        public static extern void faset_regex_free(void* re);
        public static extern int faset_regex_group_count(void* re);
        public static extern string faset_regex_group_name(void* re, int i);
        public static extern int faset_regex_match(void* re, string text, long start, long* caps, long maxSteps, long timeoutMs);
    }

    // ---------------------------------------------------------------- Group, Match

    // Un grupo de una coincidencia. Si no participó, Success es false y Value "".
    public class Group
    {
        internal string input;
        internal int index;     // -1 si no participó
        internal int length;
        internal string name;

        internal Group(string input, int index, int length, string name)
        {
            this.input = input;
            this.index = index;
            this.length = length;
            this.name = name;
        }

        public bool Success => index >= 0;
        // Posición (en bytes) donde empieza en el texto (0 si no participó).
        public int Index => index >= 0 ? index : 0;
        public int Length => length;
        // Nombre del grupo ("1", "2"... para los grupos sin nombre).
        public string Name => name;
        public string Value => index >= 0 ? input.Substring(index, length) : "";

        public override string ToString() => Value;
    }

    // Los grupos de una coincidencia: por número (m.Groups[1]) o por nombre (m.Groups["anio"]).
    // El grupo 0 es la coincidencia completa. Un número o nombre que no existe da un grupo sin éxito.
    public class GroupCollection : IEnumerable<Group>
    {
        Match match;

        internal GroupCollection(Match m) { match = m; }

        public int Count => match.regex == null ? 1 : match.regex.groupCount;

        public Group operator[](int i) => match.GetGroup(i);

        public Group operator[](string name)
        {
            int n = match.regex == null ? -1 : match.regex.GroupNumberFromName(name);
            return match.GetGroup(n < 0 ? Count : n);
        }

        // ¿Existe un grupo con ese nombre (aunque no haya participado)?
        public bool ContainsKey(string name) => match.regex != null && match.regex.GroupNumberFromName(name) >= 0;

        public bool TryGetValue(string name, out Group g)
        {
            g = this[name];
            return ContainsKey(name);
        }

        IEnumerator<Group> IEnumerable<Group>.GetEnumerator()
        {
            for (int i = 0; i < Count; i++) yield return match.GetGroup(i);
        }
    }

    // Resultado de una búsqueda. Si no hay coincidencia, Success es false.
    public memory_unsafe class Match : Group
    {
        internal Regex regex;
        internal long* caps;    // inicio y fin de cada grupo (-1 si no participó)
        List<Group> cache;
        GroupCollection groups;

        internal Match(Regex regex, string input, long* caps)
            : base(input, caps == null ? -1 : (int)caps[0], caps == null ? 0 : (int)(caps[1] - caps[0]), "0")
        {
            this.regex = regex;
            this.caps = caps;
        }

        // Coincidencia vacía sin éxito.
        public static Match Empty => new Match(null, "", null);

        public GroupCollection Groups
        {
            get
            {
                if (groups == null) groups = new GroupCollection(this);
                return groups;
            }
        }

        internal Group GetGroup(int i)
        {
            if (i == 0) return this;
            int n = regex == null ? 1 : regex.groupCount;
            if (i < 0 || i >= n || caps == null) return new Group(input, -1, 0, "");
            if (cache == null)
            {
                cache = new List<Group>();
                for (int k = 0; k < n; k++) cache.Add(null);
            }
            if (cache[i] == null)
            {
                long a = caps[2 * i];
                long b = caps[2 * i + 1];
                cache[i] = new Group(input, a < 0 ? -1 : (int)a, a < 0 ? 0 : (int)(b - a), regex.GroupNameFromNumber(i));
            }
            return cache[i];
        }

        // Siguiente coincidencia del mismo patrón a partir de esta (sin éxito si no hay más).
        public Match NextMatch()
        {
            if (!Success || regex == null) return Empty;
            int from = index + length;
            if (length == 0)
            {
                if (from >= input.Length) return Empty;
                from += Regex.CharLength(input, from);
            }
            return regex.Match(input, from);
        }

        // Aplica una plantilla de reemplazo ($1, ${nombre}...) a esta coincidencia.
        public string Result(string replacement)
        {
            if (!Success) throw new InvalidOperationException("Match.Result: la coincidencia no tuvo éxito");
            StringBuilder sb = new StringBuilder();
            regex.Expand(sb, this, replacement);
            return sb.ToString();
        }
    }

    // ---------------------------------------------------------------- Regex

    // Una expresión regular compilada. Es inmutable: se puede compartir entre hilos.
    public memory_unsafe class Regex
    {
        void* handle;
        string pattern;
        RegexOptions options;
        long timeoutMs;          // 0 = sin límite de tiempo (solo el presupuesto de pasos)
        internal int groupCount;
        List<string> names;      // nombre de cada grupo ("0", "1"... o el nombre)

        public Regex(string pattern) { Init(pattern, RegexOptions.None, 0); }

        public Regex(string pattern, RegexOptions options) { Init(pattern, options, 0); }

        // Con tiempo límite por búsqueda: si se supera se lanza RegexMatchTimeoutException.
        public Regex(string pattern, RegexOptions options, TimeSpan matchTimeout)
        {
            long ms = matchTimeout.TotalMillisecondsLong;
            if (ms <= 0) throw new ArgumentOutOfRangeException("matchTimeout", "Regex: el tiempo límite debe ser positivo");
            Init(pattern, options, ms);
        }

        [TrackCaller] void Init(string p, RegexOptions o, long ms)
        {
            pattern = String.Copy(p);
            options = o;
            timeoutMs = ms;
            string error = "";
            void* h = RegexNative.faset_regex_compile(pattern, (int)o, &error);
            if (h == null)
            {
                RegexParseException e = new RegexParseException("patrón no válido '" + p + "': " + error);
                e.ParamName = "pattern";
                throw e;
            }
            handle = h;
            groupCount = RegexNative.faset_regex_group_count(h);
            names = new List<string>();
            for (int i = 0; i < groupCount; i++)
            {
                string n = RegexNative.faset_regex_group_name(h, i);
                names.Add(n.Length > 0 ? n : $"{i}");
            }
        }

        ~Regex()
        {
            if (handle != null) RegexNative.faset_regex_free(handle);
            handle = null;
        }

        public RegexOptions Options => options;
        public override string ToString() => pattern;

        // ---------------------------------------------------------------- grupos

        // Nombres de los grupos por número: "0", "1"..., y después los grupos con nombre.
        public List<string> GetGroupNames()
        {
            List<string> r = new List<string>();
            for (int i = 0; i < groupCount; i++) r.Add(names[i]);
            return r;
        }

        public List<int> GetGroupNumbers()
        {
            List<int> r = new List<int>();
            for (int i = 0; i < groupCount; i++) r.Add(i);
            return r;
        }

        // Número del grupo 'name' ("anio" o "2"); -1 si no existe.
        public int GroupNumberFromName(string name)
        {
            for (int i = 0; i < groupCount; i++)
                if (names[i] == name) return i;
            return -1;
        }

        // Nombre del grupo 'i' ("" si no existe).
        public string GroupNameFromNumber(int i) => i >= 0 && i < groupCount ? names[i] : "";

        // ---------------------------------------------------------------- búsqueda

        // ¿Hay alguna coincidencia en 'input'?
        [TrackCaller] public bool IsMatch(string input) => Run(input, 0) != null;

        [TrackCaller] public bool IsMatch(string input, int startat) => Run(input, CheckStart(input, startat)) != null;

        // Primera coincidencia (Success es false si no hay ninguna).
        [TrackCaller] public Match Match(string input) => Match(input, 0);

        // Primera coincidencia a partir de 'startat' (^ sigue refiriéndose al principio del texto;
        // \G, a 'startat'; las búsquedas hacia atrás ven el texto anterior).
        [TrackCaller] public Match Match(string input, int startat)
        {
            long* caps = Run(input, CheckStart(input, startat));
            return new Match(this, input, caps);   // sin éxito si caps es null
        }

        // Todas las coincidencias que no se solapan, de izquierda a derecha. Tras una coincidencia
        // vacía se avanza un carácter (como .NET: Matches("abc", "x*") da 4 vacías).
        [TrackCaller] public List<Match> Matches(string input) => Matches(input, 0);

        [TrackCaller] public List<Match> Matches(string input, int startat)
        {
            List<Match> r = new List<Match>();
            Match m = Match(input, startat);
            while (m.Success)
            {
                r.Add(m);
                m = m.NextMatch();
            }
            return r;
        }

        // Número de coincidencias.
        [TrackCaller] public int Count(string input) => Matches(input).Count;

        // ---------------------------------------------------------------- reemplazo

        // Reemplaza cada coincidencia por 'replacement', que puede usar $0 / $& (la coincidencia),
        // $1..$n, ${nombre}, $` (lo anterior), $' (lo posterior), $+ (último grupo), $_ (todo el
        // texto) y $$ (un '$').
        [TrackCaller] public string Replace(string input, string replacement) => Replace(input, replacement, -1, 0);

        // Solo las primeras 'count' coincidencias (-1: todas).
        [TrackCaller] public string Replace(string input, string replacement, int count) => Replace(input, replacement, count, 0);

        [TrackCaller] public string Replace(string input, string replacement, int count, int startat)
        {
            StringBuilder sb = new StringBuilder();
            int last = 0;
            int n = 0;
            Match m = Match(input, startat);
            while (m.Success && (count < 0 || n < count))
            {
                sb.Append(input.Substring(last, m.Index - last));
                Expand(sb, m, replacement);
                last = m.Index + m.Length;
                n++;
                m = m.NextMatch();
            }
            if (n == 0) return input;
            sb.Append(input.Substring(last));
            return sb.ToString();
        }

        // Reemplaza cada coincidencia por lo que devuelva 'evaluator'.
        [TrackCaller] public string Replace(string input, Func<Match, string> evaluator) => Replace(input, evaluator, -1);

        [TrackCaller] public string Replace(string input, Func<Match, string> evaluator, int count)
        {
            StringBuilder sb = new StringBuilder();
            int last = 0;
            int n = 0;
            Match m = Match(input, 0);
            while (m.Success && (count < 0 || n < count))
            {
                sb.Append(input.Substring(last, m.Index - last));
                sb.Append(evaluator(m));
                last = m.Index + m.Length;
                n++;
                m = m.NextMatch();
            }
            if (n == 0) return input;
            sb.Append(input.Substring(last));
            return sb.ToString();
        }

        // ---------------------------------------------------------------- Split

        // Parte 'input' por las coincidencias. Como en .NET, los grupos que capturan se incluyen
        // en el resultado (en orden de número) y una coincidencia vacía parte entre caracteres.
        [TrackCaller] public List<string> Split(string input) => Split(input, -1);

        // Como mucho 'count' partes (la última lleva el resto del texto).
        [TrackCaller] public List<string> Split(string input, int count)
        {
            List<string> r = new List<string>();
            if (count == 1)
            {
                r.Add(input);
                return r;
            }
            int last = 0;
            Match m = Match(input, 0);
            while (m.Success && (count < 0 || r.Count < count - 1))
            {
                r.Add(input.Substring(last, m.Index - last));
                for (int i = 1; i < groupCount; i++)
                {
                    Group g = m.Groups[i];
                    if (g.Success) r.Add(g.Value);
                }
                last = m.Index + m.Length;
                m = m.NextMatch();
            }
            r.Add(input.Substring(last));
            return r;
        }

        // ---------------------------------------------------------------- estáticos

        [TrackCaller] public static bool IsMatch(string input, string pattern) => new Regex(pattern).IsMatch(input);
        [TrackCaller] public static bool IsMatch(string input, string pattern, RegexOptions options) => new Regex(pattern, options).IsMatch(input);
        [TrackCaller] public static Match Match(string input, string pattern) => new Regex(pattern).Match(input);
        [TrackCaller] public static Match Match(string input, string pattern, RegexOptions options) => new Regex(pattern, options).Match(input);
        [TrackCaller] public static List<Match> Matches(string input, string pattern) => new Regex(pattern).Matches(input);
        [TrackCaller] public static List<Match> Matches(string input, string pattern, RegexOptions options) => new Regex(pattern, options).Matches(input);
        [TrackCaller] public static string Replace(string input, string pattern, string replacement) => new Regex(pattern).Replace(input, replacement);
        [TrackCaller] public static string Replace(string input, string pattern, string replacement, RegexOptions options) =>
            new Regex(pattern, options).Replace(input, replacement);
        [TrackCaller] public static string Replace(string input, string pattern, Func<Match, string> evaluator) => new Regex(pattern).Replace(input, evaluator);
        [TrackCaller] public static string Replace(string input, string pattern, Func<Match, string> evaluator, RegexOptions options) =>
            new Regex(pattern, options).Replace(input, evaluator);
        [TrackCaller] public static List<string> Split(string input, string pattern) => new Regex(pattern).Split(input);
        [TrackCaller] public static List<string> Split(string input, string pattern, RegexOptions options) => new Regex(pattern, options).Split(input);

        // Escapa los metacaracteres (\ * + ? | { [ ( ) ^ $ . # y espacios) para buscar 'text' literalmente.
        public static string Escape(string text)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < text.Length; i++)
            {
                char c = (char)text[i];
                if (c == '\n') sb.Append("\\n");
                else if (c == '\r') sb.Append("\\r");
                else if (c == '\t') sb.Append("\\t");
                else if (c == '\f') sb.Append("\\f");
                else
                {
                    if (c == '\\' || c == '*' || c == '+' || c == '?' || c == '|' || c == '{' || c == '[' || c == '(' ||
                        c == ')' || c == '^' || c == '$' || c == '.' || c == '#' || c == ' ')
                        sb.Append('\\');
                    sb.AppendByte(text[i]);
                }
            }
            return sb.ToString();
        }

        // Lo contrario de Escape: quita las barras y convierte \n \t \r \f \e \a \xHH \uHHHH.
        [TrackCaller] public static string Unescape(string text)
        {
            StringBuilder sb = new StringBuilder();
            int i = 0;
            while (i < text.Length)
            {
                char c = (char)text[i];
                if (c != '\\' || i + 1 >= text.Length)
                {
                    sb.AppendByte(text[i]);
                    i++;
                    continue;
                }
                char e = (char)text[i + 1];
                i += 2;
                if (e == 'n') sb.Append('\n');
                else if (e == 'r') sb.Append('\r');
                else if (e == 't') sb.Append('\t');
                else if (e == 'f') sb.Append('\f');
                else if (e == 'e') sb.AppendByte(27);
                else if (e == 'a') sb.AppendByte(7);
                else if (e == 'x' || e == 'u')
                {
                    int digits = e == 'x' ? 2 : 4;
                    int v = 0;
                    for (int k = 0; k < digits; k++)
                    {
                        int d = i + k < text.Length ? HexDigit((char)text[i + k]) : -1;
                        if (d < 0) throw new RegexParseException("Regex.Unescape: secuencia \\" + (e == 'x' ? "x" : "u") + " incompleta");
                        v = v * 16 + d;
                    }
                    i += digits;
                    sb.Append((char)v);
                }
                else sb.AppendByte(text[i - 1]);
            }
            return sb.ToString();
        }

        // ---------------------------------------------------------------- interno

        static int HexDigit(char c)
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        }

        // Bytes del carácter UTF-8 que empieza en 'i' (1 si no es una secuencia válida).
        internal static int CharLength(string s, int i)
        {
            int b = s[i];
            int n = (b & 0xE0) == 0xC0 ? 2 : (b & 0xF0) == 0xE0 ? 3 : (b & 0xF8) == 0xF0 ? 4 : 1;
            if (i + n > s.Length) return 1;
            for (int k = 1; k < n; k++)
                if ((s[i + k] & 0xC0) != 0x80) return 1;
            return n;
        }

        [TrackCaller] static int CheckStart(string input, int startat)
        {
            if (startat < 0 || startat > input.Length)
                throw new ArgumentOutOfRangeException("startat", "Regex: la posición inicial está fuera del texto");
            return startat;
        }

        // Busca desde 'start'; devuelve las posiciones de los grupos o null si no hay coincidencia.
        [TrackCaller] long* Run(string input, int start)
        {
            long* caps = Memory.New<long>(2 * groupCount);
            int r = RegexNative.faset_regex_match(handle, input, start, caps, 0, timeoutMs);
            if (r == 1) return caps;
            if (r == 0) return null;
            RegexMatchTimeoutException e = new RegexMatchTimeoutException(
                timeoutMs > 0 ? $"la expresión regular '{pattern}' superó el tiempo límite de {timeoutMs} ms"
                              : $"la expresión regular '{pattern}' agotó su presupuesto de pasos (retroceso catastrófico)");
            e.Pattern = pattern;
            e.Input = input;
            throw e;
        }

        // Añade a 'sb' la plantilla 'rep' aplicada a 'm'.
        internal void Expand(StringBuilder sb, Match m, string rep)
        {
            int i = 0;
            while (i < rep.Length)
            {
                char c = (char)rep[i];
                if (c != '$' || i + 1 >= rep.Length)
                {
                    sb.AppendByte(rep[i]);
                    i++;
                    continue;
                }
                char d = (char)rep[i + 1];
                if (d == '$') { sb.Append('$'); i += 2; }
                else if (d == '&') { sb.Append(m.Value); i += 2; }
                else if (d == '`') { sb.Append(m.input.Substring(0, m.Index)); i += 2; }
                else if (d == '\'') { sb.Append(m.input.Substring(m.Index + m.Length)); i += 2; }
                else if (d == '_') { sb.Append(m.input); i += 2; }
                else if (d == '+')
                {
                    // Último grupo (el de número más alto) que participó.
                    for (int g = groupCount - 1; g >= 0; g--)
                        if (m.Groups[g].Success || g == 0)
                        {
                            sb.Append(m.Groups[g].Value);
                            break;
                        }
                    i += 2;
                }
                else if (d == '{')
                {
                    int close = rep.IndexOf("}", i + 2);
                    int g = close < 0 ? -1 : GroupNumberFromName(rep.Substring(i + 2, close - i - 2));
                    if (g < 0)
                    {
                        sb.Append('$');   // ${...} de un grupo que no existe: se deja tal cual
                        i++;
                        continue;
                    }
                    sb.Append(m.Groups[g].Value);
                    i = close + 1;
                }
                else if (d >= '0' && d <= '9')
                {
                    // El número más largo que sea un grupo existente ($10 si hay 10 grupos; si no, $1 y '0').
                    int g = -1;
                    int end = i + 1;
                    int v = 0;
                    int k = i + 1;
                    while (k < rep.Length && rep[k] >= '0' && rep[k] <= '9' && v < 100000)
                    {
                        v = v * 10 + (rep[k] - '0');
                        k++;
                        if (v < groupCount)
                        {
                            g = v;
                            end = k;
                        }
                    }
                    if (g < 0)
                    {
                        sb.Append('$');
                        i++;
                        continue;
                    }
                    sb.Append(m.Groups[g].Value);
                    i = end;
                }
                else
                {
                    sb.Append('$');
                    i++;
                }
            }
        }
    }
}
