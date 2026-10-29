// =============================================================================
//  std.text  —  construcción y manipulación de texto.
//
//    StringBuilder           búfer de texto que crece (como en C#)
//    Text.Split / Join / Replace / Repeat / PadLeft / PadRight / Reverse
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
}
