// =============================================================================
//  std.json  —  lectura y escritura de JSON.
//
//    JsonValue raiz = Json.Parse(texto);     // null si el texto no es válido
//    string nombre = raiz.Get("nombre").AsString;
//    delete raiz;                            // libera todo el árbol
//
//    StringBuilder sb = new StringBuilder;
//    Json.WriteString(sb, "texto con \"comillas\"");
//
//    string texto = Json.Serialize(persona);              // serialización automática: el código
//    Persona p = Json.Deserialize<Persona>(texto);        // de cada tipo se genera al compilar
// =============================================================================
using std.collections;
using std.text;

namespace std.json
{
    public enum JsonKind { Null, Bool, Number, String, Array, Object }

    public class JsonValue
    {
        public JsonKind Kind;
        public bool BoolValue;
        public double NumberValue;
        public string StringValue;          // copia propia
        public List<JsonValue> Items;       // Array
        public List<string> Keys;           // Object (copias propias)
        public List<JsonValue> Values;      // Object

        public JsonValue(JsonKind kind)
        {
            Kind = kind;
            if (kind == JsonKind.Array) Items = new List<JsonValue>();
            if (kind == JsonKind.Object)
            {
                Keys = new List<string>();
                Values = new List<JsonValue>();
            }
        }

        ~JsonValue()
        {
            if (Kind == JsonKind.String) String.Free(StringValue);
            if (Items != null)
            {
                for (int i = 0; i < Items.Count; i++) delete Items[i];
                delete Items;
            }
            if (Keys != null)
            {
                for (int i = 0; i < Keys.Count; i++)
                {
                    String.Free(Keys[i]);
                    delete Values[i];
                }
                delete Keys;
                delete Values;
            }
        }

        public int Count => Kind == JsonKind.Array ? Items.Count : (Kind == JsonKind.Object ? Keys.Count : 0);
        public bool IsNull => Kind == JsonKind.Null;

        // Elemento de un arreglo (null si no existe).
        public JsonValue At(int index)
        {
            if (Kind != JsonKind.Array || index < 0 || index >= Items.Count) return null;
            return Items[index];
        }

        // Miembro de un objeto (null si no existe).
        public JsonValue Get(string key)
        {
            if (Kind != JsonKind.Object) return null;
            for (int i = 0; i < Keys.Count; i++)
                if (Keys[i] == key) return Values[i];
            return null;
        }

        public bool Has(string key) => Get(key) != null;

        // Las vistas devueltas apuntan a la memoria del árbol: válidas hasta 'delete'.
        public string AsString() => Kind == JsonKind.String ? StringValue : "";
        public double AsNumber() => Kind == JsonKind.Number ? NumberValue : 0;
        public int AsInt() => (int)AsNumber();
        public bool AsBool() => Kind == JsonKind.Bool && BoolValue;

        // Atajos: valor de un miembro con un valor por defecto.
        public string GetString(string key)
        {
            JsonValue v = Get(key);
            return v != null ? v.AsString() : "";
        }

        public int GetInt(string key)
        {
            JsonValue v = Get(key);
            return v != null ? v.AsInt() : 0;
        }
    }

    // Analizador recursivo.
    class JsonReader
    {
        string text;
        int pos;
        public bool Failed;

        public JsonReader(string s) { text = s; }

        void SkipSpace()
        {
            while (pos < text.Length)
            {
                byte c = text[pos];
                if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
                pos++;
            }
        }

        bool Match(string word)
        {
            if (pos + word.Length > text.Length) return false;
            for (int i = 0; i < word.Length; i++)
                if (text[pos + i] != word[i]) return false;
            pos += word.Length;
            return true;
        }

        int Hex(byte c)
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            Failed = true;
            return 0;
        }

        int ReadHex4()
        {
            if (pos + 4 > text.Length)
            {
                Failed = true;
                return 0;
            }
            int v = 0;
            for (int i = 0; i < 4; i++) v = v * 16 + Hex(text[pos++]);
            return v;
        }

        string ReadString()
        {
            pos++;  // comilla inicial
            StringBuilder sb = new StringBuilder();
            while (pos < text.Length && text[pos] != '"')
            {
                byte c = text[pos++];
                if (c != '\\')
                {
                    // Copia de bytes UTF-8 tal cual.
                    int start = pos - 1;
                    while (pos < text.Length && text[pos] != '"' && text[pos] != '\\') pos++;
                    sb.Append(text.Substring(start, pos - start));
                    continue;
                }
                if (pos >= text.Length) break;
                byte e = text[pos++];
                if (e == 'n') sb.Append('\n');
                else if (e == 't') sb.Append('\t');
                else if (e == 'r') sb.Append('\r');
                else if (e == 'b') sb.Append('\b');
                else if (e == 'f') sb.Append('\f');
                else if (e == 'u')
                {
                    int cp = ReadHex4();
                    if (cp >= 0xD800 && cp < 0xDC00 && Match("\\u"))
                    {
                        int lo = ReadHex4();
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    sb.Append((char)cp);
                }
                else sb.Append((char)e);
            }
            if (pos >= text.Length) Failed = true;
            pos++;
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public JsonValue ReadValue()
        {
            SkipSpace();
            if (pos >= text.Length)
            {
                Failed = true;
                return null;
            }
            byte c = text[pos];
            if (c == '{')
            {
                pos++;
                JsonValue obj = new JsonValue(JsonKind.Object);
                SkipSpace();
                if (pos < text.Length && text[pos] == '}')
                {
                    pos++;
                    return obj;
                }
                while (!Failed)
                {
                    SkipSpace();
                    if (pos >= text.Length || text[pos] != '"')
                    {
                        Failed = true;
                        break;
                    }
                    string key = ReadString();
                    SkipSpace();
                    if (!Match(":"))
                    {
                        String.Free(key);
                        Failed = true;
                        break;
                    }
                    JsonValue v = ReadValue();
                    if (v == null)
                    {
                        String.Free(key);
                        break;
                    }
                    obj.Keys.Add(key);
                    obj.Values.Add(v);
                    SkipSpace();
                    if (Match(",")) continue;
                    if (!Match("}")) Failed = true;
                    break;
                }
                return obj;
            }
            if (c == '[')
            {
                pos++;
                JsonValue arr = new JsonValue(JsonKind.Array);
                SkipSpace();
                if (pos < text.Length && text[pos] == ']')
                {
                    pos++;
                    return arr;
                }
                while (!Failed)
                {
                    JsonValue v = ReadValue();
                    if (v == null) break;
                    arr.Items.Add(v);
                    SkipSpace();
                    if (Match(",")) continue;
                    if (!Match("]")) Failed = true;
                    break;
                }
                return arr;
            }
            if (c == '"')
            {
                JsonValue s = new JsonValue(JsonKind.String);
                s.StringValue = ReadString();
                return s;
            }
            if (Match("true") || Match("false"))
            {
                JsonValue b = new JsonValue(JsonKind.Bool);
                b.BoolValue = text[pos - 1] == 'e' && text[pos - 2] == 'u';
                return b;
            }
            if (Match("null")) return new JsonValue(JsonKind.Null);
            int start = pos;
            while (pos < text.Length)
            {
                byte d = text[pos];
                if ((d >= '0' && d <= '9') || d == '-' || d == '+' || d == '.' || d == 'e' || d == 'E') pos++;
                else break;
            }
            double num = 0;
            if (pos == start || !Convert.TryToDouble(text.Substring(start, pos - start), out num))
            {
                Failed = true;
                return null;
            }
            JsonValue n = new JsonValue(JsonKind.Number);
            n.NumberValue = num;
            return n;
        }
    }

    public static class Json
    {
        // Analiza un texto JSON. Devuelve null si no es válido. Libera el resultado con delete.
        public static JsonValue Parse(string text)
        {
            JsonReader r = new JsonReader(text);
            JsonValue v = r.ReadValue();
            bool failed = r.Failed;
            delete r;
            if (failed)
            {
                delete v;
                return null;
            }
            return v;
        }

        // Escribe 's' como cadena JSON (con comillas y escapes).
        public static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            int start = 0;
            for (int i = 0; i < s.Length; i++)
            {
                byte c = s[i];
                if (c != '"' && c != '\\' && c >= 0x20) continue;
                sb.Append(s.Substring(start, i - start));
                if (c == '"') sb.Append("\\\"");
                else if (c == '\\') sb.Append("\\\\");
                else if (c == '\n') sb.Append("\\n");
                else if (c == '\r') sb.Append("\\r");
                else if (c == '\t') sb.Append("\\t");
                else
                {
                    sb.Append("\\u00");
                    sb.Append("0123456789abcdef".Substring(c >> 4, 1));
                    sb.Append("0123456789abcdef".Substring(c & 15, 1));
                }
                start = i + 1;
            }
            sb.Append(s.Substring(start));
            sb.Append('"');
        }

        // ---- serialización automática (JsonSerializer): código generado al compilar para cada tipo

        // Objeto -> texto JSON. Clases, structs, registros, T[], List<T>, Dictionary<K, V>, T?, enums
        // (por su nombre) y tipos anidados; [JsonName("x")] cambia el nombre y [JsonIgnore] lo omite.
        public static string Serialize<T>(T value) => Serialize<T>(value, null);
        public static string Serialize<T>(T value, JsonOptions options)
        {
            JsonWriter w = new JsonWriter(options);
            JsonSerializer.Write<T>(w, value);
            return w.ToString();
        }

        // Texto JSON -> objeto. JsonException (una FormatException) con la línea y la columna del
        // error si el texto no es válido o no encaja con el tipo.
        public static T Deserialize<T>(string text) => Deserialize<T>(text, null);
        public static T Deserialize<T>(string text, JsonOptions options)
        {
            JsonParser p = new JsonParser(text, options);
            T r = JsonSerializer.Read<T>(p);
            p.End();
            return r;
        }
    }

    // ---------------------------------------------------------------- serialización automática
    //
    //  Json.Serialize(obj) y Json.Deserialize<T>(texto) no usan reflexión al ejecutar: JsonSerializer
    //  recorre con 'comptime foreach' los miembros de cada tipo al compilar y genera, por cada T, un
    //  código directo (w.Key("Nombre"); Write(w, obj.Nombre); ...), como haría un generador de código.

    // Opciones de Serialize / Deserialize.
    public class JsonOptions
    {
        public bool Indented;                    // saltos de línea y sangría
        public string IndentText = "  ";
        public bool CamelCase;                   // "NombreCompleto" -> "nombreCompleto" (también al leer)
        public bool IgnoreNull;                  // no escribe los miembros que valen null
        public bool CaseInsensitive;             // al leer, los nombres no distinguen mayúsculas
        public bool EnumsAsNumbers;              // enums como números en vez de por su nombre
        public int MaxDepth = 64;                // anidamiento máximo (referencias circulares)
    }

    // [JsonName("nombre")]: nombre del miembro en el JSON (tiene prioridad sobre CamelCase).
    [AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
    public sealed class JsonName : Attribute
    {
        public string Name;
        public JsonName(string name) { Name = name; }
    }

    // [JsonIgnore]: el miembro no se escribe ni se lee.
    [AttributeUsage(AttributeTargets.Field | AttributeTargets.Property)]
    public sealed class JsonIgnore : Attribute { }

    // Error al leer JSON: texto mal formado o que no encaja con el tipo pedido.
    public class JsonException : FormatException
    {
        public int Line;
        public int Column;
        public JsonException(string message, int line, int column)
        {
            Message = message + " (línea " + line + ", columna " + column + ")";
            Line = line;
            Column = column;
        }
    }

    // Escritor de JSON con sangría opcional.
    public class JsonWriter
    {
        StringBuilder sb = new StringBuilder();
        public JsonOptions Options;
        int depth;
        bool first = true;
        bool afterKey;

        public JsonWriter(JsonOptions options) { Options = options == null ? new JsonOptions() : options; }

        void NewLine()
        {
            sb.Append('\n');
            for (int i = 0; i < depth; i++) sb.Append(Options.IndentText);
        }

        // Separador antes de un valor (coma y sangría), salvo justo después de una clave.
        void Before()
        {
            if (afterKey)
            {
                afterKey = false;
                return;
            }
            if (depth > 0)
            {
                if (!first) sb.Append(',');
                if (Options.Indented) NewLine();
            }
            first = false;
        }

        void Open(char c)
        {
            Before();
            if (depth >= Options.MaxDepth)
                throw new InvalidOperationException("JSON: se superó la profundidad máxima de " + Options.MaxDepth + " (¿referencia circular?)");
            sb.Append(c);
            depth++;
            first = true;
        }

        void Close(char c)
        {
            depth--;
            if (!first && Options.Indented) NewLine();
            sb.Append(c);
            first = false;
        }

        public void BeginObject() => Open('{');
        public void EndObject() => Close('}');
        public void BeginArray() => Open('[');
        public void EndArray() => Close(']');

        // Clave de un objeto; 'camel' es la misma en camelCase (se usa con Options.CamelCase).
        public void Key(string name, string camel)
        {
            Before();
            Json.WriteString(sb, Options.CamelCase ? camel : name);
            sb.Append(Options.Indented ? ": " : ":");
            afterKey = true;
        }
        public void Key(string name) => Key(name, name);

        public void Null() { Before(); sb.Append("null"); }
        public void Bool(bool v) { Before(); sb.Append(v ? "true" : "false"); }
        public void Long(long v) { Before(); sb.Append(v); }
        public void ULong(ulong v) { Before(); sb.Append(v); }
        public void String(string s) { Before(); Json.WriteString(sb, s); }
        public void Double(double v)
        {
            Before();
            if (v != v || v - v != 0) sb.Append("null");  // NaN e infinito no existen en JSON
            else sb.Append(v);
        }

        public override string ToString() => sb.ToString();
    }

    // Lector de JSON por tokens, con la línea y la columna para los errores (JsonException).
    public class JsonParser
    {
        string text;
        int pos;
        int line = 1;
        int lineStart;
        public JsonOptions Options;
        int depth;

        public JsonParser(string text, JsonOptions options)
        {
            this.text = text;
            Options = options == null ? new JsonOptions() : options;
        }

        public void Fail(string message) => throw new JsonException(message, line, pos - lineStart + 1);

        // Posición actual (tras los espacios) y error en una posición anterior de la misma línea.
        public int Position
        {
            get
            {
                SkipSpace();
                return pos;
            }
        }
        public void FailAt(int position, string message) => throw new JsonException(message, line, position - lineStart + 1);

        void SkipSpace()
        {
            while (pos < text.Length)
            {
                byte c = text[pos];
                if (c == '\n')
                {
                    line++;
                    lineStart = pos + 1;
                }
                else if (c != ' ' && c != '\t' && c != '\r') break;
                pos++;
            }
        }

        // Siguiente carácter significativo (0 al final del texto).
        public byte Peek()
        {
            SkipSpace();
            return pos < text.Length ? text[pos] : (byte)0;
        }

        string Describe()
        {
            if (pos >= text.Length) return "el final del texto";
            byte c = text[pos];
            if (c == '"') return "una cadena";
            if (c == '{') return "un objeto";
            if (c == '[') return "un array";
            if (c == 't' || c == 'f') return "un booleano";
            if (c == 'n') return "null";
            if ((c >= '0' && c <= '9') || c == '-') return "un número";
            return "'" + text.Substring(pos, 1) + "'";
        }

        public void Expected(string what) => Fail("se esperaba " + what + " pero se encontró " + Describe());

        bool Word(string w)
        {
            if (pos + w.Length > text.Length) return false;
            for (int i = 0; i < w.Length; i++)
                if (text[pos + i] != w[i]) return false;
            pos += w.Length;
            return true;
        }

        // null: lo consume y devuelve true.
        public bool TryNull() => Peek() == 'n' && Word("null");

        public bool ReadBool()
        {
            byte c = Peek();
            if (c == 't' && Word("true")) return true;
            if (c == 'f' && Word("false")) return false;
            Expected("un booleano");
            return false;
        }

        int Hex()
        {
            if (pos >= text.Length) Fail("secuencia \\u incompleta");
            byte c = text[pos++];
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            pos--;
            Fail("dígito hexadecimal no válido en \\u");
            return 0;
        }

        public string ReadString()
        {
            if (Peek() != '"') Expected("una cadena");
            pos++;
            int start = pos;
            // Sin escapes: una vista del texto, sin copiar.
            while (pos < text.Length && text[pos] != '"' && text[pos] != '\\' && text[pos] >= 0x20) pos++;
            if (pos < text.Length && text[pos] == '"') return text.Substring(start, (pos++) - start);
            StringBuilder sb = new StringBuilder();
            sb.Append(text.Substring(start, pos - start));
            while (true)
            {
                if (pos >= text.Length) Fail("cadena sin cerrar");
                byte c = text[pos];
                if (c == '"') break;
                if (c < 0x20) Fail("carácter de control sin escapar en una cadena");
                if (c != '\\')
                {
                    int s = pos;
                    while (pos < text.Length && text[pos] != '"' && text[pos] != '\\' && text[pos] >= 0x20) pos++;
                    sb.Append(text.Substring(s, pos - s));
                    continue;
                }
                pos++;
                if (pos >= text.Length) Fail("cadena sin cerrar");
                byte e = text[pos++];
                if (e == 'n') sb.Append('\n');
                else if (e == 't') sb.Append('\t');
                else if (e == 'r') sb.Append('\r');
                else if (e == 'b') sb.Append('\b');
                else if (e == 'f') sb.Append('\f');
                else if (e == '"' || e == '\\' || e == '/') sb.Append((char)e);
                else if (e == 'u')
                {
                    int cp = (Hex() << 12) | (Hex() << 8) | (Hex() << 4) | Hex();
                    if (cp >= 0xD800 && cp < 0xDC00 && Word("\\u"))
                    {
                        int lo = (Hex() << 12) | (Hex() << 8) | (Hex() << 4) | Hex();
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    }
                    sb.Append((char)cp);
                }
                else
                {
                    pos--;
                    Fail("secuencia de escape no válida '\\" + text.Substring(pos, 1) + "'");
                }
            }
            pos++;
            return sb.ToString();
        }

        // Texto del número siguiente (sin convertir).
        string NumberText()
        {
            byte c = Peek();
            if (!((c >= '0' && c <= '9') || c == '-')) Expected("un número");
            int start = pos;
            while (pos < text.Length)
            {
                byte d = text[pos];
                if ((d >= '0' && d <= '9') || d == '-' || d == '+' || d == '.' || d == 'e' || d == 'E') pos++;
                else break;
            }
            return text.Substring(start, pos - start);
        }

        public double ReadDouble()
        {
            int start = pos;
            string s = NumberText();
            double v = 0;
            if (!Convert.TryToDouble(s, out v))
            {
                pos = start;
                Fail("número no válido '" + s + "'");
            }
            return v;
        }

        // Entero en [min, max]; 'tipo' es el nombre para el mensaje.
        public long ReadLong(long min, long max, string tipo)
        {
            SkipSpace();
            int start = pos;
            string s = NumberText();
            long v = 0;
            if (!Convert.TryToInt64(s, out v))
            {
                pos = start;
                double d = 0;
                if (Convert.TryToDouble(s, out d)) Fail("se esperaba un entero (" + tipo + ") pero se encontró " + s);
                Fail("número no válido '" + s + "'");
            }
            if (v < min || v > max)
            {
                pos = start;
                Fail("el número " + s + " no cabe en '" + tipo + "'");
            }
            return v;
        }

        public ulong ReadULong()
        {
            SkipSpace();
            int start = pos;
            string s = NumberText();
            ulong v = 0;
            for (int i = 0; i < s.Length; i++)
            {
                byte d = s[i];
                if (d < '0' || d > '9' || v > 1844674407370955161UL || (v == 1844674407370955161UL && d > '5'))
                {
                    pos = start;
                    Fail("el número " + s + " no cabe en 'ulong'");
                }
                v = v * 10 + (ulong)(d - '0');
            }
            return v;
        }

        public void BeginObject()
        {
            if (Peek() != '{') Expected("un objeto");
            pos++;
            if (++depth > Options.MaxDepth) Fail("se superó la profundidad máxima de " + Options.MaxDepth);
            first = true;
        }

        bool first;

        // Siguiente clave del objeto (y sus ':'), o false al llegar a '}'.
        public bool NextKey(out string key)
        {
            key = "";
            byte c = Peek();
            if (c == '}')
            {
                pos++;
                depth--;
                first = false;
                return false;
            }
            if (!first)
            {
                if (c != ',') Expected("',' o '}'");
                pos++;
            }
            first = false;
            key = ReadString();
            if (Peek() != ':') Expected("':'");
            pos++;
            return true;
        }

        public void BeginArray()
        {
            if (Peek() != '[') Expected("un array");
            pos++;
            if (++depth > Options.MaxDepth) Fail("se superó la profundidad máxima de " + Options.MaxDepth);
            first = true;
        }

        // ¿Hay otro elemento en el array? (consume la ',' o el ']')
        public bool NextItem()
        {
            byte c = Peek();
            if (c == ']')
            {
                pos++;
                depth--;
                first = false;
                return false;
            }
            if (!first)
            {
                if (c != ',') Expected("',' o ']'");
                pos++;
            }
            first = false;
            return true;
        }

        // ¿Es 'key' el nombre del miembro? (exacto, en camelCase o sin distinguir mayúsculas)
        public bool KeyIs(string key, string name, string camel)
        {
            if (key == name || (Options.CamelCase && key == camel)) return true;
            return Options.CaseInsensitive && key.ToLower() == name.ToLower();
        }

        // Salta un valor cualquiera (miembros que el tipo no tiene).
        public void Skip()
        {
            byte c = Peek();
            if (c == '{')
            {
                BeginObject();
                string k;
                while (NextKey(out k)) Skip();
            }
            else if (c == '[')
            {
                BeginArray();
                while (NextItem()) Skip();
            }
            else if (c == '"') ReadString();
            else if (c == 't' || c == 'f') ReadBool();
            else if (c == 'n')
            {
                if (!TryNull()) Expected("un valor");
            }
            else ReadDouble();
        }

        // Tras el valor raíz solo puede haber espacios.
        public void End()
        {
            if (Peek() != 0) Fail("texto sobrante después del valor JSON");
        }
    }

    // Código de serialización generado al compilar para cada tipo.
    public static class JsonSerializer
    {
        // "NombreCompleto" -> "nombreCompleto" (se evalúa al compilar).
        public comptime static string Camel(string s)
        {
            if (s.Length == 0) return s;
            return s.Substring(0, 1).ToLower() + s.Substring(1);
        }

        public static void Write<T>(JsonWriter w, T v)
        {
            comptime if (Tipo<T>.EsTexto) w.String(v);
            else comptime if (Tipo<T>.EsBool) w.Bool(v);
            else comptime if (Tipo<T>.EsChar) w.String($"{v}");
            else comptime if (Tipo<T>.EsEnum)
            {
                if (w.Options.EnumsAsNumbers)
                {
                    w.Long((long)v);
                    return;
                }
                comptime foreach (var e in Tipo<T>.Valores)
                {
                    if (v == e.Valor)
                    {
                        w.String(e.Nombre);
                        return;
                    }
                }
                w.Long((long)v);  // valor sin nombre (combinación de banderas...)
            }
            else comptime if (Tipo<T>.EsEntero)
            {
                comptime if (typeof(T) == typeof(ulong)) w.ULong(v);
                else w.Long(v);
            }
            else comptime if (Tipo<T>.EsDecimal) w.Double(v);
            else comptime if (Tipo<T>.EsNullable)
            {
                if (v.HasValue) Write<T.Subyacente>(w, v.Value);
                else w.Null();
            }
            else comptime if (Tipo<T>.EsLista || Tipo<T>.EsConjunto || Tipo<T>.EsArreglo)
            {
                if (v == null)
                {
                    w.Null();
                    return;
                }
                w.BeginArray();
                foreach (var x in v) Write<T.Elemento>(w, x);
                w.EndArray();
            }
            else comptime if (Tipo<T>.EsDiccionario)
            {
                if (v == null)
                {
                    w.Null();
                    return;
                }
                w.BeginObject();
                foreach (var kv in v)
                {
                    w.Key($"{kv.Key}");
                    Write<T.Valor>(w, kv.Value);
                }
                w.EndObject();
            }
            else comptime if (Tipo<T>.EsClase || Tipo<T>.EsStruct)
            {
                comptime if (Tipo<T>.EsClase)
                {
                    if (v == null)
                    {
                        w.Null();
                        return;
                    }
                }
                w.BeginObject();
                comptime foreach (var f in Tipo<T>.Miembros)
                {
                    comptime if (!f.TieneAtributo<JsonIgnore>())
                    {
                        var valor = f.Get(v);
                        comptime if (!Tipo<f.Tipo>.EsTexto && (Tipo<f.Tipo>.EsReferencia || Tipo<f.Tipo>.EsNullable))
                        {
                            if (!(w.Options.IgnoreNull && valor == null))
                            {
                                comptime if (f.TieneAtributo<JsonName>()) w.Key(f.Atributo<JsonName>().Name);
                                else w.Key(f.Nombre, Camel(f.Nombre));
                                Write<f.Tipo>(w, valor);
                            }
                        }
                        else
                        {
                            comptime if (f.TieneAtributo<JsonName>()) w.Key(f.Atributo<JsonName>().Name);
                            else w.Key(f.Nombre, Camel(f.Nombre));
                            Write<f.Tipo>(w, valor);
                        }
                    }
                }
                w.EndObject();
            }
            else static_assert(false, "Json.Serialize no sabe escribir el tipo '" + Tipo<T>.Nombre + "'");
        }

        public static T Read<T>(JsonParser p)
        {
            comptime if (Tipo<T>.EsTexto)
            {
                if (p.TryNull()) return "";  // las cadenas de Faset no son null
                return p.ReadString();
            }
            else comptime if (Tipo<T>.EsBool) return p.ReadBool();
            else comptime if (Tipo<T>.EsChar)
            {
                string s = p.ReadString();
                foreach (char c in s) return c;
                p.Fail("se esperaba un carácter pero la cadena está vacía");
                return default;
            }
            else comptime if (Tipo<T>.EsEnum)
            {
                if (p.Peek() != '"') return (T)p.ReadLong(int.MinValue, int.MaxValue, Tipo<T>.Nombre);
                int at = p.Position;
                string s = p.ReadString();
                comptime foreach (var e in Tipo<T>.Valores)
                {
                    if (p.KeyIs(s, e.Nombre, Camel(e.Nombre))) return e.Valor;
                }
                p.FailAt(at, "'" + s + "' no es un valor de " + Tipo<T>.Nombre);
                return default;
            }
            else comptime if (Tipo<T>.EsEntero)
            {
                comptime if (typeof(T) == typeof(ulong)) return p.ReadULong();
                else return (T)p.ReadLong((long)T.MinValue, (long)T.MaxValue, Tipo<T>.Nombre);
            }
            else comptime if (Tipo<T>.EsDecimal) return (T)p.ReadDouble();
            else comptime if (Tipo<T>.EsNullable)
            {
                if (p.TryNull()) return null;
                return Read<T.Subyacente>(p);
            }
            else comptime if (Tipo<T>.EsLista || Tipo<T>.EsConjunto)
            {
                if (p.TryNull()) return null;
                T l = new T();
                p.BeginArray();
                while (p.NextItem()) l.Add(Read<T.Elemento>(p));
                return l;
            }
            else comptime if (Tipo<T>.EsArreglo)
            {
                if (p.TryNull()) return null;
                List<T.Elemento> l = new List<T.Elemento>();
                p.BeginArray();
                while (p.NextItem()) l.Add(Read<T.Elemento>(p));
                T a = new T(l.Count);
                for (int i = 0; i < l.Count; i++) a[i] = l[i];
                return a;
            }
            else comptime if (Tipo<T>.EsDiccionario)
            {
                if (p.TryNull()) return null;
                T d = new T();
                p.BeginObject();
                string k;
                while (p.NextKey(out k))
                {
                    comptime if (Tipo<T.Clave>.EsTexto) d[k] = Read<T.Valor>(p);
                    else
                    {
                        JsonParser kp = new JsonParser(Tipo<T.Clave>.EsEnum ? "\"" + k + "\"" : k, p.Options);
                        T.Clave clave = Read<T.Clave>(kp);
                        d[clave] = Read<T.Valor>(p);
                    }
                }
                return d;
            }
            else comptime if ((Tipo<T>.EsClase || Tipo<T>.EsStruct) && !Tipo<T>.TieneConstructorVacio)
            {
                static_assert(false, "Json.Deserialize necesita que '" + Tipo<T>.Nombre + "' tenga un constructor público sin parámetros");
                return default;
            }
            else comptime if (Tipo<T>.EsClase || Tipo<T>.EsStruct)
            {
                comptime if (Tipo<T>.EsClase)
                {
                    if (p.TryNull()) return null;
                }
                T obj = new T();
                p.BeginObject();
                string key;
                while (p.NextKey(out key))
                {
                    comptime foreach (var f in Tipo<T>.Miembros)
                    {
                        comptime if (f.PuedeEscribir && !f.TieneAtributo<JsonIgnore>())
                        {
                            comptime if (f.TieneAtributo<JsonName>())
                            {
                                if (p.KeyIs(key, f.Atributo<JsonName>().Name, f.Atributo<JsonName>().Name))
                                {
                                    f.Set(obj, Read<f.Tipo>(p));
                                    continue;
                                }
                            }
                            else
                            {
                                if (p.KeyIs(key, f.Nombre, Camel(f.Nombre)))
                                {
                                    f.Set(obj, Read<f.Tipo>(p));
                                    continue;
                                }
                            }
                        }
                    }
                    p.Skip();
                }
                return obj;
            }
            else
            {
                static_assert(false, "Json.Deserialize no sabe leer el tipo '" + Tipo<T>.Nombre + "'");
                return default;
            }
        }
    }
}
