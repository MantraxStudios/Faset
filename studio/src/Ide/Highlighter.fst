// =============================================================================
//  Tema de colores (oscuro, al estilo de Visual Studio) y resaltado de sintaxis.
// =============================================================================
using std.collections;
using FasetStudio.Gfx;

namespace FasetStudio.Ide
{
    // Tema monocromo: negro, grises y blanco. El color solo se usa para los errores.
    public static class Theme
    {
        // Superficies (de más profunda a más elevada)
        public static Color Base => Color.Hex(0x0a0a0b);          // fondo de la ventana y separaciones
        public static Color Surface => Color.Hex(0x131315);       // paneles
        public static Color Editor => Color.Hex(0x101012);        // área de código
        public static Color Elevated => Color.Hex(0x1b1b1e);      // pestaña activa, botones, ventanas emergentes
        public static Color Hover => Color.Hex(0x222226);
        public static Color Active => Color.Hex(0x2b2b30);
        public static Color Border => Color.Hex(0x232327);
        public static Color BorderStrong => Color.Hex(0x34343a);

        // Texto
        public static Color Text => Color.Hex(0xe6e6e8);
        public static Color TextSecondary => Color.Hex(0xa0a0a8);
        public static Color TextTertiary => Color.Hex(0x6c6c74);
        public static Color TextDisabled => Color.Hex(0x4a4a50);
        public static Color White => Color.Hex(0xffffff);
        public static Color Black => Color.Hex(0x000000);

        // Editor
        public static Color CurrentLine => Color.Hex(0x17171a);
        public static Color Selection => Color.Hex(0x2e2f35);
        public static Color SelectionInactive => Color.Hex(0x232327);
        public static Color Caret => Color.Hex(0xffffff);
        public static Color LineNumber => Color.Hex(0x48484f);
        public static Color LineNumberActive => Color.Hex(0xd4d4d8);
        public static Color ScrollThumb => Color.Hex(0xffffff, 0.12f);
        public static Color Shadow => Color.Hex(0x000000, 0.55f);

        // Estados
        public static Color Error => Color.Hex(0xf04f4f);
        public static Color Warning => Color.Hex(0xe0b341);
        public static Color Info => Color.Hex(0x9a9aa2);
        public static Color Success => Color.Hex(0xd4d4d8);

        // Colores de sintaxis: tonos suaves que contrastan con la interfaz monocroma.
        public static Color Syntax(byte kind)
        {
            switch (kind)
            {
                case 1: return Color.Hex(0xff7b72);   // palabra clave (coral)
                case 2: return Color.Hex(0xff7b72);   // control de flujo
                case 3: return Color.Hex(0xffa657);   // tipo (naranja)
                case 4: return Color.Hex(0xa5d6ff);   // cadena (azul claro)
                case 5: return Color.Hex(0x79c0ff);   // número (azul)
                case 6: return Color.Hex(0x8b949e);   // comentario (gris, cursiva)
                case 7: return Color.Hex(0xd2a8ff);   // función (lila)
                case 8: return Color.Hex(0x79c0ff);   // miembro
                case 9: return Color.Hex(0x8b949e);   // directiva
                case 10: return Color.Hex(0x7ee787);  // carácter de escape (verde)
                default: return Color.Hex(0xe6edf3);
            }
        }

        // 0 regular, 1 negrita, 2 cursiva
        public static int SyntaxStyle(byte kind) => kind == 6 ? 2 : 0;
    }

    public static class TokenKind
    {
        public const byte Plain = 0;
        public const byte Keyword = 1;
        public const byte Control = 2;
        public const byte Type = 3;
        public const byte String = 4;
        public const byte Number = 5;
        public const byte Comment = 6;
        public const byte Function = 7;
        public const byte Member = 8;
        public const byte Directive = 9;
        public const byte Escape = 10;
    }

    public memory_unsafe class Highlighter
    {
        Dictionary<string, byte> words = new Dictionary<string, byte>();

        public Highlighter()
        {
            AddAll("namespace using import class struct enum interface public private protected internal static extern const readonly memory_unsafe virtual override abstract sealed new delete sizeof typeof nameof this base null nullptr true false var auto delegate operator ref out in is as with record params default get set where typename inline event and or not async", TokenKind.Keyword);
            AddAll("if else while do for foreach break continue return switch case goto throw try catch finally when await yield", TokenKind.Control);
            AddAll("void bool char sbyte byte short ushort int uint long ulong float double string object Func Action", TokenKind.Type);
        }

        ~Highlighter() { delete words; }

        void AddAll(string list, byte kind)
        {
            auto parts = std.text.Text.Split(list, " ");
            for (int i = 0; i < parts.Count; i++) words.Set(parts[i], kind);
            delete parts;
        }

        static bool IsIdentStart(byte c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80;
        static bool IsIdent(byte c) => IsIdentStart(c) || (c >= '0' && c <= '9');
        static bool IsDigit(byte c) => c >= '0' && c <= '9';

        // Colorea 'line' (un byte de 'kinds' por byte de texto). 'inComment' indica si la
        // línea empieza dentro de un comentario /* */; devuelve el estado al final de la línea.
        public bool Colorize(string line, byte* kinds, bool inComment)
        {
            int n = line.Length;
            int i = 0;
            while (i < n)
            {
                if (inComment)
                {
                    int start = i;
                    while (i < n && !(line[i] == '*' && i + 1 < n && line[i + 1] == '/')) i++;
                    if (i < n)
                    {
                        i += 2;
                        inComment = false;
                    }
                    Memory.Set(kinds + start, TokenKind.Comment, i - start);
                    continue;
                }
                byte c = line[i];
                if (c == '/' && i + 1 < n && line[i + 1] == '/')
                {
                    Memory.Set(kinds + i, TokenKind.Comment, n - i);
                    return false;
                }
                if (c == '/' && i + 1 < n && line[i + 1] == '*')
                {
                    inComment = true;
                    kinds[i] = TokenKind.Comment;
                    kinds[i + 1] = TokenKind.Comment;
                    i += 2;
                    continue;
                }
                if (c == '#' && line.Trim().StartsWith("#"))
                {
                    Memory.Set(kinds + i, TokenKind.Directive, n - i);
                    return false;
                }
                // Cadena interpolada: $"..{expr,alineación:formato}..", $@"..", @$"..".
                if ((c == '$' && i + 1 < n && (line[i + 1] == '"' || (line[i + 1] == '@' && i + 2 < n && line[i + 2] == '"'))) ||
                    (c == '@' && i + 2 < n && line[i + 1] == '$' && line[i + 2] == '"'))
                {
                    i = ColorizeInterpolated(line, kinds, i);
                    continue;
                }
                if (c == '"' || c == '\'' || (c == '@' && i + 1 < n && line[i + 1] == '"'))
                {
                    bool verbatim = c == '@';
                    int start = i;
                    if (verbatim) i++;
                    byte quote = line[i];
                    i++;
                    while (i < n)
                    {
                        if (!verbatim && line[i] == '\\' && i + 1 < n)
                        {
                            kinds[i] = TokenKind.Escape;
                            kinds[i + 1] = TokenKind.Escape;
                            i += 2;
                            continue;
                        }
                        kinds[i] = TokenKind.String;
                        if (line[i] == quote)
                        {
                            i++;
                            break;
                        }
                        i++;
                    }
                    for (int k = start; k < i; k++)
                        if (kinds[k] != TokenKind.Escape) kinds[k] = TokenKind.String;
                    continue;
                }
                if (IsDigit(c) || (c == '.' && i + 1 < n && IsDigit(line[i + 1])))
                {
                    int start = i;
                    while (i < n && (IsIdent(line[i]) || line[i] == '.')) i++;
                    Memory.Set(kinds + start, TokenKind.Number, i - start);
                    continue;
                }
                if (IsIdentStart(c))
                {
                    int start = i;
                    while (i < n && IsIdent(line[i])) i++;
                    string word = line.Substring(start, i - start);
                    byte kind = TokenKind.Plain;
                    if (!words.TryGetValue(word, out kind))
                    {
                        kind = TokenKind.Plain;
                        int j = i;
                        while (j < n && line[j] == ' ') j++;
                        bool afterDot = start > 0 && (line[start - 1] == '.' || (start > 1 && line[start - 1] == '>' && line[start - 2] == '-'));
                        if (j < n && line[j] == '(') kind = TokenKind.Function;
                        else if (j < n && line[j] == '<' && c >= 'A' && c <= 'Z') kind = TokenKind.Type;
                        else if (j + 1 < n && line[j] == ':' && line[j + 1] == ':') kind = TokenKind.Type;
                        else if (afterDot) kind = TokenKind.Member;
                        else if (c >= 'A' && c <= 'Z') kind = TokenKind.Type;
                    }
                    Memory.Set(kinds + start, kind, i - start);
                    continue;
                }
                kinds[i] = TokenKind.Plain;
                i++;
            }
            return inComment;
        }

        // Colorea una cadena interpolada a partir de 'i' (en '$' o '@'); devuelve la posición
        // siguiente. El texto es cadena; '{{', '}}' y las llaves de los huecos, escape; el código
        // de cada hueco se colorea como código normal y el formato (:F2) como cadena.
        int ColorizeInterpolated(string line, byte* kinds, int i)
        {
            int n = line.Length;
            bool verbatim = false;
            while (i < n && (line[i] == '$' || line[i] == '@'))
            {
                if (line[i] == '@') verbatim = true;
                kinds[i] = TokenKind.String;
                i++;
            }
            if (i < n) kinds[i] = TokenKind.String;  // comilla de apertura
            i++;
            while (i < n)
            {
                byte d = line[i];
                if (d == '"')
                {
                    if (verbatim && i + 1 < n && line[i + 1] == '"')
                    {
                        kinds[i] = TokenKind.Escape;
                        kinds[i + 1] = TokenKind.Escape;
                        i += 2;
                        continue;
                    }
                    kinds[i] = TokenKind.String;
                    return i + 1;
                }
                if ((!verbatim && d == '\\' && i + 1 < n) || ((d == '{' || d == '}') && i + 1 < n && line[i + 1] == d))
                {
                    kinds[i] = TokenKind.Escape;
                    kinds[i + 1] = TokenKind.Escape;
                    i += 2;
                    continue;
                }
                if (d != '{')
                {
                    kinds[i] = TokenKind.String;
                    i++;
                    continue;
                }
                kinds[i] = TokenKind.Escape;  // '{' del hueco
                i++;
                int start = i;
                int depth = 0;
                while (i < n)
                {
                    byte e = line[i];
                    if (e == '"' || e == '\'')
                    {
                        i++;
                        while (i < n && line[i] != e) i++;
                    }
                    else if (e == '(' || e == '[' || e == '{') depth++;
                    else if ((e == ')' || e == ']' || e == '}') && depth > 0) depth--;
                    else if (depth == 0 && (e == '}' || (e == ':' && !(i + 1 < n && line[i + 1] == ':') && line[i - 1] != ':'))) break;
                    i++;
                }
                if (i > n) i = n;
                if (i > start) Colorize(line.Substring(start, i - start), kinds + start, false);
                if (i < n && line[i] == ':')
                {
                    int f = i;
                    while (i < n && line[i] != '}' && line[i] != '"') i++;
                    Memory.Set(kinds + f, TokenKind.String, i - f);
                }
                if (i < n && line[i] == '}')
                {
                    kinds[i] = TokenKind.Escape;
                    i++;
                }
            }
            return i;
        }
    }
}
