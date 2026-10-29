// =============================================================================
//  std.json  —  lectura y escritura de JSON.
//
//    JsonValue raiz = Json.Parse(texto);     // null si el texto no es válido
//    string nombre = raiz.Get("nombre").AsString();
//    delete raiz;                            // libera todo el árbol
//
//    StringBuilder sb = new StringBuilder();
//    Json.WriteString(sb, "texto con \"comillas\"");
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
    }
}
