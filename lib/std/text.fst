// =============================================================================
//  std.text  —  construcción y manipulación de texto.
//
//    StringBuilder           búfer de texto que crece (como en C#)
//    Text.Split / Join / Replace / Repeat / PadLeft / PadRight / Reverse
//    Base64, Hex             codificación de datos binarios como texto
//    Encoding                UTF8, Latin1, ASCII, UTF16 (Unicode), BigEndianUnicode
//    Csv, CsvWriter          lectura y escritura de CSV (RFC 4180, con comillas)
//
//  Los datos binarios se guardan en cadenas: un string es una vista de bytes y puede
//  contener cualquier valor (también ceros), no solo texto UTF-8.
// =============================================================================
using std.collections;

namespace std.text
{
    public memory_unsafe class StringBuilder
    {
        byte* buffer;
        int length;
        int capacity;

        public StringBuilder() { }
        public StringBuilder(int initialCapacity) { Reserve(initialCapacity); }
        ~StringBuilder() { Memory.Free(buffer); }

        public int Length => length;

        void Reserve(int n)
        {
            if (n + 1 <= capacity) return;
            int c = capacity < 32 ? 32 : capacity;
            while (c < n + 1) c *= 2;
            buffer = (byte*)Memory.Realloc(buffer, c);
            capacity = c;
        }

        public StringBuilder Append(string s)
        {
            Reserve(length + s.Length);
            Memory.Copy(buffer + length, s.Ptr, s.Length);
            length += s.Length;
            buffer[length] = 0;
            return this;
        }

        public StringBuilder Append(long v)
        {
            string s = String.FromInt(v);
            Append(s);
            String.Free(s);
            return this;
        }

        public StringBuilder Append(ulong v)
        {
            string s = String.FromUInt(v);
            Append(s);
            String.Free(s);
            return this;
        }

        public StringBuilder Append(double v)
        {
            string s = String.FromDouble(v);
            Append(s);
            String.Free(s);
            return this;
        }

        public StringBuilder Append(bool v) => Append(v ? "True" : "False");

        // Añade un carácter Unicode codificado en UTF-8.
        public StringBuilder Append(char c)
        {
            Reserve(length + 4);
            if (c < 0x80)
            {
                buffer[length++] = (byte)c;
            }
            else if (c < 0x800)
            {
                buffer[length++] = (byte)(0xC0 | (c >> 6));
                buffer[length++] = (byte)(0x80 | (c & 0x3F));
            }
            else if (c < 0x10000)
            {
                buffer[length++] = (byte)(0xE0 | (c >> 12));
                buffer[length++] = (byte)(0x80 | ((c >> 6) & 0x3F));
                buffer[length++] = (byte)(0x80 | (c & 0x3F));
            }
            else
            {
                buffer[length++] = (byte)(0xF0 | (c >> 18));
                buffer[length++] = (byte)(0x80 | ((c >> 12) & 0x3F));
                buffer[length++] = (byte)(0x80 | ((c >> 6) & 0x3F));
                buffer[length++] = (byte)(0x80 | (c & 0x3F));
            }
            buffer[length] = 0;
            return this;
        }

        // Añade un byte tal cual (para datos binarios: la cadena resultante puede no ser UTF-8).
        public StringBuilder AppendByte(int b)
        {
            Reserve(length + 1);
            buffer[length++] = (byte)b;
            buffer[length] = 0;
            return this;
        }

        // Añade 'count' bytes de 'data'.
        public memory_unsafe StringBuilder AppendBytes(byte* data, long count)
        {
            Reserve(length + (int)count);
            Memory.Copy(buffer + length, data, count);
            length += (int)count;
            buffer[length] = 0;
            return this;
        }

        // Entero de 16 / 32 / 64 bits en little-endian (formatos binarios: ZIP, WAV...).
        public StringBuilder AppendUInt16LE(int v) => AppendByte(v & 0xFF).AppendByte((v >> 8) & 0xFF);
        public StringBuilder AppendUInt32LE(uint v) => AppendUInt16LE((int)(v & 0xFFFF)).AppendUInt16LE((int)(v >> 16));
        public StringBuilder AppendUInt64LE(ulong v) => AppendUInt32LE((uint)(v & 0xFFFFFFFFUL)).AppendUInt32LE((uint)(v >> 32));

        // Inserta 's' en la posición 'index' (en bytes).
        [TrackCaller] public StringBuilder Insert(int index, string s)
        {
            if (index < 0 || index > length) throw new ArgumentOutOfRangeException("StringBuilder.Insert: índice fuera del texto", "index");
            Reserve(length + s.Length);
            for (int i = length - 1; i >= index; i--) buffer[i + s.Length] = buffer[i];
            Memory.Copy(buffer + index, s.Ptr, s.Length);
            length += s.Length;
            buffer[length] = 0;
            return this;
        }

        // Quita 'count' bytes desde 'start'.
        [TrackCaller] public StringBuilder Remove(int start, int count)
        {
            if (start < 0 || count < 0 || start + count > length) throw new ArgumentOutOfRangeException("StringBuilder.Remove: rango fuera del texto", "start");
            for (int i = start + count; i < length; i++) buffer[i - count] = buffer[i];
            length -= count;
            buffer[length] = 0;
            return this;
        }

        // Sustituye todas las apariciones de 'oldValue' por 'newValue'.
        public StringBuilder Replace(string oldValue, string newValue)
        {
            if (oldValue.Length == 0 || length == 0) return this;
            string r = Text.Replace(View(), oldValue, newValue);
            Clear();
            Append(r);
            return this;
        }

        // Byte en la posición 'index'.
        [TrackCaller] public byte operator[](int index)
        {
            if (index < 0 || index >= length) throw new IndexOutOfRangeException("StringBuilder: índice fuera del texto");
            return buffer[index];
        }

        public StringBuilder AppendLine() => Append("\n");
        public StringBuilder AppendLine(string s) => Append(s).Append("\n");

        public StringBuilder AppendRepeat(string s, int times)
        {
            for (int i = 0; i < times; i++) Append(s);
            return this;
        }

        public void Clear()
        {
            length = 0;
            if (buffer != null) buffer[0] = 0;
        }

        // Copia del contenido.
        public override string ToString() => String.Copy(View());

        // Vista sin copiar: válida hasta la próxima modificación del builder.
        public string View() => String.FromBytes(buffer, length);
    }

    public memory_unsafe static class Text
    {
        // Divide 's' por 'separator'. Las partes son vistas de 's' (no copian).
        // Devuelve una lista nueva
        public static List<string> Split(string s, string separator)
        {
            List<string> parts = new List<string>();
            if (separator.Length == 0)
            {
                parts.Add(s);
                return parts;
            }
            int start = 0;
            int i = s.IndexOf(separator, 0);
            while (i >= 0)
            {
                parts.Add(s.Substring(start, i - start));
                start = i + separator.Length;
                i = s.IndexOf(separator, start);
            }
            parts.Add(s.Substring(start));
            return parts;
        }

        // Une las partes con 'separator' (copia nueva).
        public static string Join(List<string> parts, string separator)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < parts.Count; i++)
            {
                if (i > 0) sb.Append(separator);
                sb.Append(parts[i]);
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public static string Replace(string s, string oldValue, string newValue)
        {
            if (oldValue.Length == 0) return String.Copy(s);
            StringBuilder sb = new StringBuilder(s.Length);
            int start = 0;
            int i = s.IndexOf(oldValue, 0);
            while (i >= 0)
            {
                sb.Append(s.Substring(start, i - start)).Append(newValue);
                start = i + oldValue.Length;
                i = s.IndexOf(oldValue, start);
            }
            sb.Append(s.Substring(start));
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public static string Repeat(string s, int times)
        {
            StringBuilder sb = new StringBuilder(s.Length * times);
            sb.AppendRepeat(s, times);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public static string PadLeft(string s, int width, char pad)
        {
            StringBuilder sb = new StringBuilder(width);
            for (int i = s.Length; i < width; i++) sb.Append(pad);
            sb.Append(s);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public static string PadRight(string s, int width, char pad)
        {
            StringBuilder sb = new StringBuilder(width);
            sb.Append(s);
            for (int i = s.Length; i < width; i++) sb.Append(pad);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Invierte los bytes (correcto para texto ASCII).
        public static string Reverse(string s)
        {
            byte* p = (byte*)Memory.Alloc(s.Length + 1);
            for (int i = 0; i < s.Length; i++) p[i] = s[s.Length - 1 - i];
            p[s.Length] = 0;
            return String.FromBytes(p, s.Length);
        }

        // true si la cadena está vacía o solo contiene espacios.
        public static bool IsNullOrWhiteSpace(string s) => s.Trim().Length == 0;
    }

    // ---------------------------------------------------------------- Base64

    // Base64 (RFC 4648), con el alfabeto estándar (+ /) o el seguro para URL (- _).
    //   Base64.Encode("hola") == "aG9sYQ=="     Base64.Decode("aG9sYQ==") == "hola"
    public memory_unsafe static class Base64
    {
        const string Standard = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        const string UrlSafe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

        // Codifica bytes en Base64 con relleno '='.
        public static string Encode(string data) => EncodeWith(data, Standard, true);

        // Variante para URL y nombres de archivo: '-' y '_' en vez de '+' y '/', sin '='.
        public static string EncodeUrl(string data) => EncodeWith(data, UrlSafe, false);

        // Decodifica Base64 (acepta los dos alfabetos, con o sin '=' y con espacios o saltos
        // de línea entre los caracteres). FormatException si el texto no es Base64.
        [TrackCaller] public static string Decode(string text)
        {
            string r;
            if (!TryDecode(text, out r)) throw new FormatException("Base64.Decode: el texto no es Base64 válido");
            return r;
        }

        public static string DecodeUrl(string text) => Decode(text);

        public static bool TryDecode(string text, out string data)
        {
            byte* p = Memory.AllocBytes(text.Length / 4 * 3 + 4);
            int n = 0;
            uint acc = 0;
            int bits = 0, pad = 0, chars = 0;
            for (int i = 0; i < text.Length; i++)
            {
                int c = text[i];
                int v;
                if (c >= 'A' && c <= 'Z') v = c - 'A';
                else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
                else if (c >= '0' && c <= '9') v = c - '0' + 52;
                else if (c == '+' || c == '-') v = 62;
                else if (c == '/' || c == '_') v = 63;
                else if (c == '=')
                {
                    pad++;
                    continue;
                }
                else if (c == ' ' || c == '\n' || c == '\r' || c == '\t') continue;
                else
                {
                    data = "";
                    return false;
                }
                if (pad > 0)
                {
                    data = "";
                    return false;  // datos después del relleno
                }
                acc = (acc << 6) | (uint)v;
                bits += 6;
                chars++;
                if (bits >= 8)
                {
                    bits -= 8;
                    p[n++] = (byte)(acc >> bits);
                }
            }
            // Un grupo final de 1 carácter no puede codificar ningún byte; los bits sobrantes deben ser 0.
            if (chars % 4 == 1 || pad > 2 || (pad > 0 && (chars + pad) % 4 != 0) || (acc & ((1u << bits) - 1)) != 0)
            {
                data = "";
                return false;
            }
            p[n] = 0;
            data = String.FromBytes(p, n);
            return true;
        }

        static string EncodeWith(string data, string alphabet, bool padding)
        {
            byte* p = Memory.AllocBytes((data.Length + 2) / 3 * 4 + 1);
            int n = 0;
            int i = 0;
            while (i + 2 < data.Length)
            {
                uint v = ((uint)data[i] << 16) | ((uint)data[i + 1] << 8) | data[i + 2];
                p[n++] = alphabet[(int)(v >> 18)];
                p[n++] = alphabet[(int)((v >> 12) & 63)];
                p[n++] = alphabet[(int)((v >> 6) & 63)];
                p[n++] = alphabet[(int)(v & 63)];
                i += 3;
            }
            int rest = data.Length - i;
            if (rest > 0)
            {
                uint v = (uint)data[i] << 16;
                if (rest == 2) v |= (uint)data[i + 1] << 8;
                p[n++] = alphabet[(int)(v >> 18)];
                p[n++] = alphabet[(int)((v >> 12) & 63)];
                if (rest == 2) p[n++] = alphabet[(int)((v >> 6) & 63)];
                else if (padding) p[n++] = (byte)'=';
                if (padding) p[n++] = (byte)'=';
            }
            p[n] = 0;
            return String.FromBytes(p, n);
        }
    }

    // ---------------------------------------------------------------- Hex

    // Hexadecimal: Hex.Encode("\x01\xAB") == "01ab"; Hex.Decode("01AB") devuelve esos 2 bytes.
    public memory_unsafe static class Hex
    {
        // En minúsculas ("00ff").
        public static string Encode(string data) => EncodeWith(data, "0123456789abcdef");
        // En mayúsculas ("00FF"), como Convert.ToHexString de .NET.
        public static string EncodeUpper(string data) => EncodeWith(data, "0123456789ABCDEF");

        // Acepta mayúsculas y minúsculas. FormatException si la longitud es impar o hay
        // caracteres que no son hexadecimales.
        [TrackCaller] public static string Decode(string text)
        {
            string r;
            if (!TryDecode(text, out r)) throw new FormatException("Hex.Decode: el texto no es hexadecimal válido");
            return r;
        }

        public static bool TryDecode(string text, out string data)
        {
            if (text.Length % 2 != 0)
            {
                data = "";
                return false;
            }
            byte* p = Memory.AllocBytes(text.Length / 2 + 1);
            for (int i = 0; i < text.Length; i += 2)
            {
                int hi = Digit(text[i]), lo = Digit(text[i + 1]);
                if (hi < 0 || lo < 0)
                {
                    data = "";
                    return false;
                }
                p[i / 2] = (byte)((hi << 4) | lo);
            }
            p[text.Length / 2] = 0;
            data = String.FromBytes(p, text.Length / 2);
            return true;
        }

        static int Digit(int c)
        {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        }

        static string EncodeWith(string data, string digits)
        {
            byte* p = Memory.AllocBytes((long)data.Length * 2 + 1);
            for (int i = 0; i < data.Length; i++)
            {
                p[2 * i] = (byte)digits[data[i] >> 4];
                p[2 * i + 1] = (byte)digits[data[i] & 15];
            }
            p[data.Length * 2] = 0;
            return String.FromBytes(p, (long)data.Length * 2);
        }
    }

    // ---------------------------------------------------------------- Encoding

    // Codificación de texto, como System.Text.Encoding. Las cadenas de Faset son UTF-8:
    // GetBytes convierte un texto UTF-8 a los bytes de esta codificación y GetString hace lo
    // contrario (devuelve UTF-8). Los caracteres que no se pueden representar se sustituyen
    // por '?' al codificar, y las secuencias no válidas por U+FFFD ('�') al decodificar.
    //
    //   string latin1 = Encoding.Latin1.GetBytes("año");     // 3 bytes: 61 F1 6F
    //   string texto = Encoding.Latin1.GetString(latin1);    // "año" (UTF-8)
    //   string utf16 = Encoding.Unicode.GetBytes("hola");    // UTF-16 little-endian
    public abstract class Encoding
    {
        static Encoding utf8;
        static Encoding latin1;
        static Encoding ascii;
        static Encoding utf16le;
        static Encoding utf16be;

        // UTF-8 (GetBytes copia el texto; GetString sustituye las secuencias no válidas).
        public static Encoding UTF8
        {
            get
            {
                if (utf8 == null) utf8 = new Utf8Encoding();
                return utf8;
            }
        }
        // ISO-8859-1: un byte por carácter (U+0000 a U+00FF).
        public static Encoding Latin1
        {
            get
            {
                if (latin1 == null) latin1 = new SingleByteEncoding("iso-8859-1", 0xFF);
                return latin1;
            }
        }
        // ASCII de 7 bits.
        public static Encoding ASCII
        {
            get
            {
                if (ascii == null) ascii = new SingleByteEncoding("us-ascii", 0x7F);
                return ascii;
            }
        }
        // UTF-16 little-endian (como Encoding.Unicode de .NET y las API W de Windows).
        public static Encoding Unicode
        {
            get
            {
                if (utf16le == null) utf16le = new Utf16Encoding(false);
                return utf16le;
            }
        }
        public static Encoding UTF16 => Unicode;
        // UTF-16 big-endian.
        public static Encoding BigEndianUnicode
        {
            get
            {
                if (utf16be == null) utf16be = new Utf16Encoding(true);
                return utf16be;
            }
        }

        // Codificación por nombre ("utf-8", "latin1", "iso-8859-1", "ascii", "utf-16", "utf-16be"...),
        // sin distinguir mayúsculas. ArgumentException si no se conoce.
        [TrackCaller] public static Encoding GetEncoding(string name)
        {
            string n = Text.Replace(name.Trim().ToLower(), "_", "-");
            if (n == "utf-8" || n == "utf8") return UTF8;
            if (n == "iso-8859-1" || n == "latin1" || n == "latin-1" || n == "iso8859-1" || n == "l1") return Latin1;
            if (n == "us-ascii" || n == "ascii") return ASCII;
            if (n == "utf-16" || n == "utf-16le" || n == "unicode" || n == "utf16") return Unicode;
            if (n == "utf-16be" || n == "unicodefffe") return BigEndianUnicode;
            throw new ArgumentException("Encoding.GetEncoding: codificación desconocida '" + name + "'", "name");
        }

        // Detecta una marca de orden de bytes (BOM) al principio de 'data': devuelve la codificación
        // y en 'bomLength' cuántos bytes ocupa; si no hay BOM, devuelve UTF8 y 0.
        public static Encoding DetectBom(string data, out int bomLength)
        {
            if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
            {
                bomLength = 3;
                return UTF8;
            }
            if (data.Length >= 2 && data[0] == 0xFF && data[1] == 0xFE)
            {
                bomLength = 2;
                return Unicode;
            }
            if (data.Length >= 2 && data[0] == 0xFE && data[1] == 0xFF)
            {
                bomLength = 2;
                return BigEndianUnicode;
            }
            bomLength = 0;
            return UTF8;
        }

        // Decodifica 'data' según su BOM (sin incluirla); sin BOM, como UTF-8.
        public static string DecodeWithBom(string data)
        {
            int n;
            Encoding e = DetectBom(data, out n);
            return e.GetString(data.Substring(n));
        }

        // Nombre web de la codificación ("utf-8", "iso-8859-1"...).
        public abstract string WebName();
        // Convierte texto (UTF-8) a bytes de esta codificación.
        public abstract string GetBytes(string text);
        // Convierte bytes de esta codificación a texto (UTF-8).
        public abstract string GetString(string bytes);
        // Marca de orden de bytes (BOM) de la codificación ("" si no tiene).
        public virtual string GetPreamble() => "";
        // Número de bytes que ocupa 'text' en esta codificación.
        public int GetByteCount(string text) => GetBytes(text).Length;

        public override string ToString() => WebName();

        // Decodifica el punto de código UTF-8 que empieza en 'i' y avanza 'i' (U+FFFD si no es válido).
        public static char NextCodePoint(string s, ref int i)
        {
            uint b = s[i];
            int extra = b < 0x80 ? 0 : (b & 0xE0) == 0xC0 ? 1 : (b & 0xF0) == 0xE0 ? 2 : (b & 0xF8) == 0xF0 ? 3 : -1;
            if (extra < 0)
            {
                i++;
                return (char)0xFFFD;
            }
            uint c = extra == 0 ? b : b & (uint)(0x3F >> extra);
            for (int k = 1; k <= extra; k++)
            {
                if (i + k >= s.Length || (s[i + k] & 0xC0) != 0x80)
                {
                    i += k;
                    return (char)0xFFFD;
                }
                c = (c << 6) | ((uint)s[i + k] & 0x3F);
            }
            i += extra + 1;
            if ((extra == 1 && c < 0x80) || (extra == 2 && c < 0x800) || (extra == 3 && (c < 0x10000 || c > 0x10FFFF)) ||
                (c >= 0xD800 && c < 0xE000)) return (char)0xFFFD;
            return (char)c;
        }
    }

    class Utf8Encoding : Encoding
    {
        public override string WebName() => "utf-8";
        public override string GetBytes(string text) => String.Copy(text);
        public override string GetPreamble() => "\uFEFF";  // EF BB BF
        public override string GetString(string bytes)
        {
            StringBuilder sb = new StringBuilder(bytes.Length);
            int i = 0;
            while (i < bytes.Length)
            {
                if (bytes[i] < 0x80) sb.AppendByte(bytes[i++]);
                else sb.Append(NextCodePoint(bytes, ref i));
            }
            return sb.ToString();
        }
    }

    class SingleByteEncoding : Encoding
    {
        string name;
        int max;
        public SingleByteEncoding(string n, int m)
        {
            name = n;
            max = m;
        }
        public override string WebName() => name;
        public override string GetBytes(string text)
        {
            StringBuilder sb = new StringBuilder(text.Length);
            int i = 0;
            while (i < text.Length)
            {
                char c = NextCodePoint(text, ref i);
                sb.AppendByte(c <= max ? (int)c : '?');
            }
            return sb.ToString();
        }
        public override string GetString(string bytes)
        {
            StringBuilder sb = new StringBuilder(bytes.Length);
            for (int i = 0; i < bytes.Length; i++)
            {
                int b = bytes[i];
                if (b < 0x80) sb.AppendByte(b);
                else sb.Append(b <= max ? (char)b : (char)0xFFFD);
            }
            return sb.ToString();
        }
    }

    class Utf16Encoding : Encoding
    {
        bool bigEndian;
        public Utf16Encoding(bool be) { bigEndian = be; }
        public override string WebName() => bigEndian ? "utf-16BE" : "utf-16";
        public override string GetPreamble()
        {
            StringBuilder sb = new StringBuilder(2);
            Unit(sb, 0xFEFF);
            return sb.ToString();
        }
        void Unit(StringBuilder sb, uint u)
        {
            if (bigEndian) sb.AppendByte((int)(u >> 8)).AppendByte((int)(u & 0xFF));
            else sb.AppendByte((int)(u & 0xFF)).AppendByte((int)(u >> 8));
        }
        public override string GetBytes(string text)
        {
            StringBuilder sb = new StringBuilder(text.Length * 2);
            int i = 0;
            while (i < text.Length)
            {
                uint c = NextCodePoint(text, ref i);
                if (c >= 0x10000)
                {
                    uint v = c - 0x10000;
                    Unit(sb, 0xD800 + (v >> 10));
                    Unit(sb, 0xDC00 + (v & 0x3FF));
                }
                else Unit(sb, c);
            }
            return sb.ToString();
        }
        uint At(string b, int i) => bigEndian ? ((uint)b[i] << 8) | b[i + 1] : ((uint)b[i + 1] << 8) | b[i];
        public override string GetString(string bytes)
        {
            StringBuilder sb = new StringBuilder(bytes.Length);
            int n = bytes.Length / 2;
            for (int k = 0; k < n; k++)
            {
                uint c = At(bytes, 2 * k);
                if (c >= 0xD800 && c < 0xDC00 && k + 1 < n)
                {
                    uint d = At(bytes, 2 * k + 2);
                    if (d >= 0xDC00 && d < 0xE000)
                    {
                        sb.Append((char)(0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)));
                        k++;
                        continue;
                    }
                }
                if (c >= 0xD800 && c < 0xE000) c = 0xFFFD;
                sb.Append((char)c);
            }
            if (bytes.Length % 2 != 0) sb.Append((char)0xFFFD);
            return sb.ToString();
        }
    }

    // ---------------------------------------------------------------- CSV

    // Lectura y escritura de CSV (RFC 4180). Los campos con el separador, comillas o saltos de
    // línea van entre comillas dobles, y una comilla dentro de un campo se escribe "".
    //
    //   var filas = Csv.Parse("nombre,edad\n\"Pérez, Ana\",31\n");
    //   println(filas[1][0]);                       // Pérez, Ana
    //   string texto = Csv.Write(filas);            // vuelve a poner las comillas
    //
    // Se aceptan finales de línea \n y \r\n; una línea vacía al final se ignora. Un campo
    // con comillas sin cerrar, o con texto tras la comilla de cierre, lanza FormatException
    // con el número de línea.
    public static class Csv
    {
        // Todas las filas, separadas por comas.
        [TrackCaller] public static List<List<string>> Parse(string text) => Parse(text, ',');

        // Todas las filas, con otro separador (';' en muchas hojas de cálculo europeas, '\t'...).
        [TrackCaller] public static List<List<string>> Parse(string text, char separator)
        {
            List<List<string>> rows = new List<List<string>>();
            CsvReader r = new CsvReader(text, separator);
            while (r.Read()) rows.Add(r.Fields);
            return rows;
        }

        // Filas como diccionarios: la primera fila da los nombres de las columnas.
        [TrackCaller] public static List<Dictionary<string, string>> ParseWithHeader(string text) => ParseWithHeader(text, ',');

        [TrackCaller] public static List<Dictionary<string, string>> ParseWithHeader(string text, char separator)
        {
            List<Dictionary<string, string>> result = new List<Dictionary<string, string>>();
            List<List<string>> rows = Parse(text, separator);
            if (rows.Count == 0) return result;
            List<string> header = rows[0];
            for (int i = 1; i < rows.Count; i++)
            {
                Dictionary<string, string> d = new Dictionary<string, string>();
                for (int c = 0; c < header.Count; c++) d[header[c]] = c < rows[i].Count ? rows[i][c] : "";
                result.Add(d);
            }
            return result;
        }

        // Texto CSV de las filas (líneas terminadas en \r\n, como pide RFC 4180).
        public static string Write(List<List<string>> rows) => Write(rows, ',');

        public static string Write(List<List<string>> rows, char separator)
        {
            CsvWriter w = new CsvWriter(separator);
            foreach (var row in rows) w.WriteRow(row);
            return w.ToString();
        }

        // Una fila (sin el salto de línea).
        public static string FormatRow(List<string> fields) => FormatRow(fields, ',');

        public static string FormatRow(List<string> fields, char separator)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < fields.Count; i++)
            {
                if (i > 0) sb.Append(separator);
                AppendField(sb, fields[i], separator);
            }
            return sb.ToString();
        }

        // Un campo, entre comillas solo si hace falta.
        public static string FormatField(string field, char separator)
        {
            StringBuilder sb = new StringBuilder();
            AppendField(sb, field, separator);
            return sb.ToString();
        }

        public static void AppendField(StringBuilder sb, string field, char separator)
        {
            bool quote = field.Length > 0 && (field[0] == ' ' || field[field.Length - 1] == ' ');
            for (int i = 0; i < field.Length && !quote; i++)
            {
                int c = field[i];
                if (c == '"' || c == '\n' || c == '\r' || c == separator) quote = true;
            }
            if (!quote)
            {
                sb.Append(field);
                return;
            }
            sb.Append('"');
            sb.Append(Text.Replace(field, "\"", "\"\""));
            sb.Append('"');
        }
    }

    // Lector de CSV fila a fila (para archivos grandes, sin guardar todas las filas):
    //   var r = new CsvReader(texto);
    //   while (r.Read()) println(r.Fields[0]);
    public class CsvReader
    {
        string text;
        int pos;
        int separator;
        int line = 1;
        List<string> fields = new List<string>();

        public CsvReader(string csv) : this(csv, ',') { }

        public CsvReader(string csv, char separatorChar)
        {
            text = csv;
            separator = separatorChar;
            if (text.StartsWith("\uFEFF")) pos = 3;  // EF BB BF  // BOM de UTF-8
        }

        // Campos de la fila actual (una lista nueva en cada Read).
        public List<string> Fields => fields;
        // Número de línea (desde 1) donde empieza la siguiente fila.
        public int Line => line;

        // Lee la siguiente fila; false al final del texto.
        [TrackCaller] public bool Read()
        {
            if (pos >= text.Length) return false;
            fields = new List<string>();
            int startLine = line;
            StringBuilder sb = new StringBuilder();
            while (true)
            {
                // Un campo.
                sb.Clear();
                if (pos < text.Length && text[pos] == '"')
                {
                    pos++;
                    while (true)
                    {
                        if (pos >= text.Length) throw new FormatException("CSV: comillas sin cerrar en el campo que empieza en la línea " + startLine);
                        int c = text[pos];
                        if (c == '"')
                        {
                            if (pos + 1 < text.Length && text[pos + 1] == '"')
                            {
                                sb.AppendByte('"');
                                pos += 2;
                                continue;
                            }
                            pos++;
                            break;
                        }
                        if (c == '\n') line++;
                        sb.AppendByte(c);
                        pos++;
                    }
                    if (pos < text.Length && text[pos] != separator && text[pos] != '\n' && text[pos] != '\r')
                        throw new FormatException("CSV: texto después de las comillas de cierre en la línea " + line);
                }
                else
                {
                    int start = pos;
                    while (pos < text.Length && text[pos] != separator && text[pos] != '\n' && text[pos] != '\r') pos++;
                    sb.Append(text.Substring(start, pos - start));
                }
                fields.Add(sb.ToString());
                if (pos >= text.Length) return true;
                int d = text[pos];
                if (d == separator)
                {
                    pos++;
                    continue;
                }
                // Fin de la fila: \n, \r\n o \r.
                if (d == '\r') pos++;
                if (pos < text.Length && text[pos] == '\n') pos++;
                line++;
                return true;
            }
        }
    }

    // Escritor de CSV: añade filas y devuelve el texto con ToString().
    //   var w = new CsvWriter();
    //   w.WriteRow("nombre", "nota");
    //   w.WriteRow("Ana", "9,5");          // se escribe "9,5" entre comillas
    public class CsvWriter
    {
        StringBuilder sb = new StringBuilder();
        char separator;

        public CsvWriter() { separator = ','; }
        public CsvWriter(char separatorChar) { separator = separatorChar; }

        // Final de línea ("\r\n" por defecto, como pide RFC 4180; "\n" también vale).
        public string NewLine = "\r\n";

        public CsvWriter WriteRow(params string[] fields)
        {
            for (int i = 0; i < fields.Length; i++)
            {
                if (i > 0) sb.Append(separator);
                Csv.AppendField(sb, fields[i], separator);
            }
            sb.Append(NewLine);
            return this;
        }

        public CsvWriter WriteRow(List<string> fields) => WriteRow(fields.ToArray());

        public override string ToString() => sb.ToString();
    }
}
