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
        public var Offset: int;

        public init() { Message = "El patrón de la expresión regular no es válido."; }
        public init(message: string) { Message = message; }

        public func ToString() -> string => Exception.Describe(this);
    }

    // La búsqueda superó el tiempo límite o el presupuesto de pasos del motor de retroceso.
    [ExceptionBase("Exception")]
    public class RegexMatchTimeoutException
    {
        public var Pattern: string;
        public var Input: string;

        public init() { Message = "Se agotó el tiempo de la expresión regular."; }
        public init(message: string) { Message = message; }

        public func ToString() -> string => Exception.Describe(this);
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
        internal var input: string;
        internal var index: int;     // -1 si no participó
        internal var length: int;
        internal var name: string;

        internal init(input: string, index: int, length: int, name: string)
        {
            this.input = input;
            this.index = index;
            this.length = length;
            this.name = name;
        }

        public prop Success: bool => index >= 0;
        // Posición (en bytes) donde empieza en el texto (0 si no participó).
        public prop Index: int => index >= 0 ? index : 0;
        public prop Length: int => length;
        // Nombre del grupo ("1", "2"... para los grupos sin nombre).
        public prop Name: string => name;
        public prop Value: string => index >= 0 ? input.Substring(index, length) : "";

        public override func ToString() -> string => Value;
    }

    // Los grupos de una coincidencia: por número (m.Groups[1]) o por nombre (m.Groups["anio"]).
    // El grupo 0 es la coincidencia completa. Un número o nombre que no existe da un grupo sin éxito.
    public class GroupCollection : IEnumerable<Group>
    {
        var match: Match;

        internal init(m: Match) { match = m; }

        public prop Count: int => match.regex == null ? 1 : match.regex.groupCount;

        public Group operator[](int i) => match.GetGroup(i);

        public Group operator[](string name)
        {
            int n = match.regex == null ? -1 : match.regex.GroupNumberFromName(name);
            return match.GetGroup(n < 0 ? Count : n);
        }

        // ¿Existe un grupo con ese nombre (aunque no haya participado)?
        public func ContainsKey(name: string) -> bool => match.regex != null && match.regex.GroupNumberFromName(name) >= 0;

        public func TryGetValue(name: string, out g: Group) -> bool
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
        internal var regex: Regex;
        internal var caps: long*;    // inicio y fin de cada grupo (-1 si no participó)
        var cache: List<Group>;
        var groups: GroupCollection;

        internal init(regex: Regex, input: string, caps: long*)
            : base(input, caps == null ? -1 : (int)caps[0], caps == null ? 0 : (int)(caps[1] - caps[0]), "0")
        {
            this.regex = regex;
            this.caps = caps;
        }

        // Coincidencia vacía sin éxito.
        public static prop Empty: Match => new Match(null, "", null);

        public prop Groups: GroupCollection
        {
            get
            {
                if (groups == null) groups = new GroupCollection(this);
                return groups;
            }
        }

        internal func GetGroup(i: int) -> Group
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
        public func NextMatch() -> Match
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
        public func Result(replacement: string) -> string
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
        var handle: void*;
        var pattern: string;
        var options: RegexOptions;
        var timeoutMs: long;          // 0 = sin límite de tiempo (solo el presupuesto de pasos)
        internal var groupCount: int;
        var names: List<string>;      // nombre de cada grupo ("0", "1"... o el nombre)

        public init(pattern: string) { Init(pattern, RegexOptions.None, 0); }

        public init(pattern: string, options: RegexOptions) { Init(pattern, options, 0); }

        // Con tiempo límite por búsqueda: si se supera se lanza RegexMatchTimeoutException.
        public init(pattern: string, options: RegexOptions, matchTimeout: TimeSpan)
        {
            long ms = matchTimeout.TotalMillisecondsLong;
            if (ms <= 0) throw new ArgumentOutOfRangeException("matchTimeout", "Regex: el tiempo límite debe ser positivo");
            Init(pattern, options, ms);
        }

        [TrackCaller] func Init(p: string, o: RegexOptions, ms: long)
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

        deinit
        {
            if (handle != null) RegexNative.faset_regex_free(handle);
            handle = null;
        }

        public prop Options: RegexOptions => options;
        public override func ToString() -> string => pattern;

        // ---------------------------------------------------------------- grupos

        // Nombres de los grupos por número: "0", "1"..., y después los grupos con nombre.
        public func GetGroupNames() -> List<string>
        {
            List<string> r = new List<string>();
            for (int i = 0; i < groupCount; i++) r.Add(names[i]);
            return r;
        }

        public func GetGroupNumbers() -> List<int>
        {
            List<int> r = new List<int>();
            for (int i = 0; i < groupCount; i++) r.Add(i);
            return r;
        }

        // Número del grupo 'name' ("anio" o "2"); -1 si no existe.
        public func GroupNumberFromName(name: string) -> int
        {
            for (int i = 0; i < groupCount; i++)
                if (names[i] == name) return i;
            return -1;
        }

        // Nombre del grupo 'i' ("" si no existe).
        public func GroupNameFromNumber(i: int) -> string => i >= 0 && i < groupCount ? names[i] : "";

        // ---------------------------------------------------------------- búsqueda

        // ¿Hay alguna coincidencia en 'input'?
        [TrackCaller] public func IsMatch(input: string) -> bool => Run(input, 0) != null;

        [TrackCaller] public func IsMatch(input: string, startat: int) -> bool => Run(input, CheckStart(input, startat)) != null;

        // Primera coincidencia (Success es false si no hay ninguna).
        [TrackCaller] public func Match(input: string) -> Match => Match(input, 0);

        // Primera coincidencia a partir de 'startat' (^ sigue refiriéndose al principio del texto;
        // \G, a 'startat'; las búsquedas hacia atrás ven el texto anterior).
        [TrackCaller] public func Match(input: string, startat: int) -> Match
        {
            long* caps = Run(input, CheckStart(input, startat));
            return new Match(this, input, caps);   // sin éxito si caps es null
        }

        // Todas las coincidencias que no se solapan, de izquierda a derecha. Tras una coincidencia
        // vacía se avanza un carácter (como .NET: Matches("abc", "x*") da 4 vacías).
        [TrackCaller] public func Matches(input: string) -> List<Match> => Matches(input, 0);

        [TrackCaller] public func Matches(input: string, startat: int) -> List<Match>
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
        [TrackCaller] public func Count(input: string) -> int => Matches(input).Count;

        // ---------------------------------------------------------------- reemplazo

        // Reemplaza cada coincidencia por 'replacement', que puede usar $0 / $& (la coincidencia),
        // $1..$n, ${nombre}, $` (lo anterior), $' (lo posterior), $+ (último grupo), $_ (todo el
        // texto) y $$ (un '$').
        [TrackCaller] public func Replace(input: string, replacement: string) -> string => Replace(input, replacement, -1, 0);

        // Solo las primeras 'count' coincidencias (-1: todas).
        [TrackCaller] public func Replace(input: string, replacement: string, count: int) -> string => Replace(input, replacement, count, 0);

        [TrackCaller] public func Replace(input: string, replacement: string, count: int, startat: int) -> string
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
        [TrackCaller] public func Replace(input: string, evaluator: Func<Match, string>) -> string => Replace(input, evaluator, -1);

        [TrackCaller] public func Replace(input: string, evaluator: Func<Match, string>, count: int) -> string
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
        [TrackCaller] public func Split(input: string) -> List<string> => Split(input, -1);

        // Como mucho 'count' partes (la última lleva el resto del texto).
        [TrackCaller] public func Split(input: string, count: int) -> List<string>
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

        [TrackCaller] public static func IsMatch(input: string, pattern: string) -> bool => new Regex(pattern).IsMatch(input);
        [TrackCaller] public static func IsMatch(input: string, pattern: string, options: RegexOptions) -> bool => new Regex(pattern, options).IsMatch(input);
        [TrackCaller] public static func Match(input: string, pattern: string) -> Match => new Regex(pattern).Match(input);
        [TrackCaller] public static func Match(input: string, pattern: string, options: RegexOptions) -> Match => new Regex(pattern, options).Match(input);
        [TrackCaller] public static func Matches(input: string, pattern: string) -> List<Match> => new Regex(pattern).Matches(input);
        [TrackCaller] public static func Matches(input: string, pattern: string, options: RegexOptions) -> List<Match> => new Regex(pattern, options).Matches(input);
        [TrackCaller] public static func Replace(input: string, pattern: string, replacement: string) -> string => new Regex(pattern).Replace(input, replacement);
        [TrackCaller] public static func Replace(input: string, pattern: string, replacement: string, options: RegexOptions) -> string =>
            new Regex(pattern, options).Replace(input, replacement);
        [TrackCaller] public static func Replace(input: string, pattern: string, evaluator: Func<Match, string>) -> string => new Regex(pattern).Replace(input, evaluator);
        [TrackCaller] public static func Replace(input: string, pattern: string, evaluator: Func<Match, string>, options: RegexOptions) -> string =>
            new Regex(pattern, options).Replace(input, evaluator);
        [TrackCaller] public static func Split(input: string, pattern: string) -> List<string> => new Regex(pattern).Split(input);
        [TrackCaller] public static func Split(input: string, pattern: string, options: RegexOptions) -> List<string> => new Regex(pattern, options).Split(input);

        // Escapa los metacaracteres (\ * + ? | { [ ( ) ^ $ . # y espacios) para buscar 'text' literalmente.
        public static func Escape(text: string) -> string
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
        [TrackCaller] public static func Unescape(text: string) -> string
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

        static func HexDigit(c: char) -> int
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        }

        // Bytes del carácter UTF-8 que empieza en 'i' (1 si no es una secuencia válida).
        internal static func CharLength(s: string, i: int) -> int
        {
            int b = s[i];
            int n = (b & 0xE0) == 0xC0 ? 2 : (b & 0xF0) == 0xE0 ? 3 : (b & 0xF8) == 0xF0 ? 4 : 1;
            if (i + n > s.Length) return 1;
            for (int k = 1; k < n; k++)
                if ((s[i + k] & 0xC0) != 0x80) return 1;
            return n;
        }

        [TrackCaller] static func CheckStart(input: string, startat: int) -> int
        {
            if (startat < 0 || startat > input.Length)
                throw new ArgumentOutOfRangeException("startat", "Regex: la posición inicial está fuera del texto");
            return startat;
        }

        // Busca desde 'start'; devuelve las posiciones de los grupos o null si no hay coincidencia.
        [TrackCaller] func Run(input: string, start: int) -> long*
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
        internal func Expand(sb: StringBuilder, m: Match, rep: string)
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
