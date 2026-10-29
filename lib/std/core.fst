// =============================================================================
//  std  —  núcleo de la biblioteca estándar de Faset (siempre disponible).
//
//  Se importa automáticamente en todos los archivos (como 'using std;').
//  Contiene: Console, Math, Memory, String, Char, Convert, Environment,
//  extensiones de 'string' y las funciones globales print/println/panic/assert.
//
//  Seguridad de memoria: las clases que llaman al runtime en C o manejan punteros
//  están marcadas 'memory_unsafe' (implementación confiable); su API pública sigue
//  siendo utilizable desde código seguro salvo los miembros con punteros en la firma
//  y los marcados 'memory_unsafe' (Memory.*).
// =============================================================================
namespace std
{
    public enum Platform { Linux, Windows, Android, MacOS, Unknown }

    // ---------------------------------------------------------------- runtime (C)
    //  Funciones nativas: como todo 'extern', solo se pueden llamar desde memory_unsafe.
    static extern void faset_write_str(string s);
    static extern void faset_write_err_str(string s);
    static extern void faset_write_i64(long v);
    static extern void faset_write_u64(ulong v);
    static extern void faset_write_f64(double v);
    static extern void faset_write_f32(float v);
    static extern void faset_write_char(char c);
    static extern void faset_write_ptr(void* p);
    static extern void faset_flush();
    static extern string faset_read_line();
    static extern void faset_panic(string msg);
    [TrackCaller] static extern void faset_panic_at(string msg);

    // ---------------------------------------------------------------- funciones globales (estilo C++)
    public void print(string v) { Console.Write(v); }
    public void print(long v) { Console.Write(v); }
    public void print(double v) { Console.Write(v); }
    public void print(char v) { Console.Write(v); }
    public void print(bool v) { Console.Write(v ? "true" : "false"); }
    public void println() { Console.WriteLine(); }
    public void println(string v) { Console.WriteLine(v); }
    public void println(long v) { Console.WriteLine(v); }
    public void println(double v) { Console.WriteLine(v); }
    public void println(char v) { Console.WriteLine(v); }
    public void println(bool v) { Console.WriteLine(v ? "true" : "false"); }

    // Termina el programa con un mensaje de error en stderr y código de salida 101:
    //   Faset panic: <mensaje> at archivo.fst:línea
    // [TrackCaller]: la ubicación es la de quien llama (no la de esta función).
    [TrackCaller] public void panic(string message) { memory_unsafe { faset_panic_at(message); } }

    // Comprueba una condición; si es falsa, termina con 'message'.
    [TrackCaller] public void assert(bool condition, string message)
    {
        if (!condition) panic(message);
    }

    // ---------------------------------------------------------------- Console
    public memory_unsafe static class Console
    {
        public static void Write(string v) { faset_write_str(v); }
        public static void Write(int v) { faset_write_i64(v); }
        public static void Write(long v) { faset_write_i64(v); }
        public static void Write(uint v) { faset_write_u64(v); }
        public static void Write(ulong v) { faset_write_u64(v); }
        public static void Write(float v) { faset_write_f32(v); }
        public static void Write(double v) { faset_write_f64(v); }
        public static void Write(char v) { faset_write_char(v); }
        public static void Write(void* v) { faset_write_ptr(v); }
        public static void Write(bool v) { faset_write_str(v ? "True" : "False"); }
        // Objetos: su ToString() (virtual); null no escribe nada.
        public static void Write(object v) { if (v != null) faset_write_str(v.ToString()); }

        public static void WriteLine() { faset_write_char('\n'); }
        public static void WriteLine(string v) { Write(v); WriteLine(); }
        public static void WriteLine(int v) { Write(v); WriteLine(); }
        public static void WriteLine(long v) { Write(v); WriteLine(); }
        public static void WriteLine(uint v) { Write(v); WriteLine(); }
        public static void WriteLine(ulong v) { Write(v); WriteLine(); }
        public static void WriteLine(float v) { Write(v); WriteLine(); }
        public static void WriteLine(double v) { Write(v); WriteLine(); }
        public static void WriteLine(char v) { Write(v); WriteLine(); }
        public static void WriteLine(bool v) { Write(v); WriteLine(); }
        public static void WriteLine(object v) { Write(v); WriteLine(); }
        public static void WriteLine(void* v) { Write(v); WriteLine(); }

        // Escribe en la salida de error.
        public static void Error(string v) { faset_write_err_str(v); }
        public static void ErrorLine(string v) { faset_write_err_str(v); faset_write_err_str("\n"); }

        public static void Flush() { faset_flush(); }

        // Devuelve una cadena nueva.
        public static string ReadLine() { return faset_read_line(); }
    }

    // ---------------------------------------------------------------- Math
    public memory_unsafe static class Math
    {
        public const double PI = 3.14159265358979323846;
        public const double E = 2.71828182845904523536;
        public const double Tau = 6.28318530717958647692;

        static extern double sqrt(double x);
        static extern double cbrt(double x);
        static extern double pow(double x, double y);
        static extern double sin(double x);
        static extern double cos(double x);
        static extern double tan(double x);
        static extern double asin(double x);
        static extern double acos(double x);
        static extern double atan(double x);
        static extern double atan2(double y, double x);
        static extern double sinh(double x);
        static extern double cosh(double x);
        static extern double tanh(double x);
        static extern double exp(double x);
        static extern double log(double x);
        static extern double log2(double x);
        static extern double log10(double x);
        static extern double floor(double x);
        static extern double ceil(double x);
        static extern double trunc(double x);
        static extern double rint(double x);
        static extern double fabs(double x);
        static extern double fmod(double x, double y);
        static extern double hypot(double x, double y);

        public static double Sqrt(double x) => sqrt(x);
        public static double Cbrt(double x) => cbrt(x);
        public static double Pow(double x, double y) => pow(x, y);
        public static double Sin(double x) => sin(x);
        public static double Cos(double x) => cos(x);
        public static double Tan(double x) => tan(x);
        public static double Asin(double x) => asin(x);
        public static double Acos(double x) => acos(x);
        public static double Atan(double x) => atan(x);
        public static double Atan2(double y, double x) => atan2(y, x);
        public static double Sinh(double x) => sinh(x);
        public static double Cosh(double x) => cosh(x);
        public static double Tanh(double x) => tanh(x);
        public static double Exp(double x) => exp(x);
        public static double Log(double x) => log(x);
        public static double Log2(double x) => log2(x);
        public static double Log10(double x) => log10(x);
        public static double Floor(double x) => floor(x);
        public static double Ceiling(double x) => ceil(x);
        public static double Truncate(double x) => trunc(x);
        public static double Round(double x) => rint(x);
        public static double Mod(double x, double y) => fmod(x, y);
        public static double Hypot(double x, double y) => hypot(x, y);

        public static double Abs(double x) => fabs(x);
        public static int Abs(int x) => x < 0 ? -x : x;
        public static long Abs(long x) => x < 0 ? -x : x;
        public static int Sign(double x) => x > 0 ? 1 : (x < 0 ? -1 : 0);
        public static int Sign(long x) => x > 0 ? 1 : (x < 0 ? -1 : 0);

        public static int Min(int a, int b) => a < b ? a : b;
        public static long Min(long a, long b) => a < b ? a : b;
        public static double Min(double a, double b) => a < b ? a : b;
        public static int Max(int a, int b) => a > b ? a : b;
        public static long Max(long a, long b) => a > b ? a : b;
        public static double Max(double a, double b) => a > b ? a : b;
        public static int Clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
        public static long Clamp(long v, long lo, long hi) => v < lo ? lo : (v > hi ? hi : v);
        public static double Clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

        public static double Lerp(double a, double b, double t) => a + (b - a) * t;
        public static double DegToRad(double deg) => deg * (PI / 180.0);
        public static double RadToDeg(double rad) => rad * (180.0 / PI);
        public static bool IsNaN(double x) => x != x;

        public static long Gcd(long a, long b)
        {
            a = Abs(a);
            b = Abs(b);
            while (b != 0)
            {
                long t = a % b;
                a = b;
                b = t;
            }
            return a;
        }

        public static long Lcm(long a, long b) => a == 0 || b == 0 ? 0 : Abs(a / Gcd(a, b) * b);

        public static bool IsPrime(long n)
        {
            if (n < 2) return false;
            if (n % 2 == 0) return n == 2;
            for (long d = 3; d * d <= n; d += 2)
                if (n % d == 0) return false;
            return true;
        }

        // Potencia entera rápida.
        public static long IPow(long b, int e)
        {
            long r = 1;
            while (e > 0)
            {
                if ((e & 1) != 0) r *= b;
                b *= b;
                e >>= 1;
            }
            return r;
        }
    }

    // ---------------------------------------------------------------- Memory (gestión manual estilo C/C++)
    //  Toda la API es 'memory_unsafe': solo se puede usar desde código memory_unsafe.
    public memory_unsafe static class Memory
    {
        static extern void* faset_alloc(long size);
        static extern void* faset_alloc_zeroed(long size);
        static extern void* faset_realloc(void* p, long size);
        static extern void faset_free(void* p);
        static extern void faset_mem_copy(void* dst, void* src, long n);
        static extern void faset_mem_set(void* dst, int value, long n);
        static extern int faset_mem_compare(void* a, void* b, long n);
        static extern void* faset_alloc_atomic(long size);

        //  La memoria es del recolector de basura: Free no la libera (solo devuelve a C la que
        //  venga de bibliotecas de C), así que nunca queda un puntero colgando.
        public memory_unsafe static void* Alloc(long size) => faset_alloc(size);
        // Bloque de bytes que nunca contendrá punteros: el recolector no lo recorre (más rápido).
        public memory_unsafe static byte* AllocBytes(long size) => (byte*)faset_alloc_atomic(size);
        public memory_unsafe static void* AllocZeroed(long size) => faset_alloc_zeroed(size);
        public memory_unsafe static void* Realloc(void* p, long size) => faset_realloc(p, size);
        public memory_unsafe static void Free(void* p) { faset_free(p); }
        public memory_unsafe static void Copy(void* dst, void* src, long n) { faset_mem_copy(dst, src, n); }
        public memory_unsafe static void Set(void* dst, int value, long n) { faset_mem_set(dst, value, n); }
        public memory_unsafe static int Compare(void* a, void* b, long n) => faset_mem_compare(a, b, n);

        // Reserva 'count' elementos de tipo T inicializados a cero.
        public memory_unsafe static T* New<T>(long count) => (T*)faset_alloc_zeroed(sizeof(T) * count);

        // Cambia el tamaño de un bloque de elementos T.
        public memory_unsafe static T* Resize<T>(T* p, long count) => (T*)faset_realloc(p, sizeof(T) * count);

        // Copia 'count' elementos de tipo T.
        public memory_unsafe static void CopyItems<T>(T* dst, T* src, long count) { faset_mem_copy(dst, src, sizeof(T) * count); }
    }

    // ---------------------------------------------------------------- GC (recolector de basura)
    //  Faset recupera la memoria solo: no hace falta 'delete' ni String.Free.
    public memory_unsafe static class GC
    {
        static extern void faset_gc_collect();
        static extern long faset_gc_heap_bytes();
        static extern long faset_gc_live_bytes();
        static extern long faset_gc_count();

        // Fuerza una recolección completa (y ejecuta los destructores pendientes).
        public static void Collect() { faset_gc_collect(); }
        // Bytes que el montón ocupa ahora.
        public static long HeapBytes => faset_gc_heap_bytes();
        // Bytes en uso (vivos tras la última recolección más lo reservado desde entonces).
        public static long TotalMemory => faset_gc_live_bytes();
        // Recolecciones hechas desde que empezó el programa.
        public static long Collections => faset_gc_count();
    }

    // ---------------------------------------------------------------- String
    public memory_unsafe static class String
    {
        static extern string faset_str_concat(string a, string b);
        static extern string faset_str_copy(string s);
        static extern string faset_str_from_cstr(byte* p);
        static extern string faset_str_make(byte* p, long len);
        static extern void faset_str_free(string s);
        static extern string faset_i64_to_str(long v);
        static extern string faset_u64_to_str(ulong v);
        static extern string faset_f64_to_str(double v);

        public const string Empty = "";

        // Las funciones que crean cadenas nuevas reservan memoria del recolector.
        public static string Concat(string a, string b) => faset_str_concat(a, b);
        public static string Concat(string a, string b, string c)
        {
            string ab = faset_str_concat(a, b);
            string r = faset_str_concat(ab, c);
            faset_str_free(ab);
            return r;
        }
        public static string Copy(string s) => faset_str_copy(s);
        public static string FromInt(long v) => faset_i64_to_str(v);
        public static string FromUInt(ulong v) => faset_u64_to_str(v);
        public static string FromDouble(double v) => faset_f64_to_str(v);
        // Ya no hace falta: el recolector recupera las cadenas. Se conserva por compatibilidad.
        public static void Free(string s) { faset_str_free(s); }

        // Vistas (no copian ni reservan memoria).
        public static string FromCString(byte* p) => faset_str_from_cstr(p);
        public static string FromBytes(byte* p, long length) => faset_str_make(p, length);
    }

    // ---------------------------------------------------------------- extensiones de string
    //  Las cadenas son vistas UTF-8 inmutables: Substring/Trim no copian.
    public memory_unsafe static class StringExtensions
    {
        public static bool IsEmpty(this string s) => s.Length == 0;

        public static bool StartsWith(this string s, string prefix)
        {
            if (prefix.Length > s.Length) return false;
            for (int i = 0; i < prefix.Length; i++)
                if (s[i] != prefix[i]) return false;
            return true;
        }

        public static bool EndsWith(this string s, string suffix)
        {
            int off = s.Length - suffix.Length;
            if (off < 0) return false;
            for (int i = 0; i < suffix.Length; i++)
                if (s[off + i] != suffix[i]) return false;
            return true;
        }

        public static int IndexOf(this string s, string sub) => s.IndexOf(sub, 0);

        public static int IndexOf(this string s, string sub, int start)
        {
            if (sub.Length == 0) return start <= s.Length ? start : -1;
            for (int i = start; i + sub.Length <= s.Length; i++)
            {
                int j = 0;
                while (j < sub.Length && s[i + j] == sub[j]) j++;
                if (j == sub.Length) return i;
            }
            return -1;
        }

        public static int LastIndexOf(this string s, string sub)
        {
            for (int i = s.Length - sub.Length; i >= 0; i--)
            {
                int j = 0;
                while (j < sub.Length && s[i + j] == sub[j]) j++;
                if (j == sub.Length) return i;
            }
            return -1;
        }

        public static bool Contains(this string s, string sub) => s.IndexOf(sub, 0) >= 0;

        public static int Count(this string s, string sub)
        {
            if (sub.Length == 0) return 0;
            int n = 0;
            int i = s.IndexOf(sub, 0);
            while (i >= 0)
            {
                n++;
                i = s.IndexOf(sub, i + sub.Length);
            }
            return n;
        }

        [TrackCaller] public static string Substring(this string s, int start, int length)
        {
            if (start < 0 || length < 0 || start + length > s.Length) panic("Substring: rango fuera de la cadena");
            return String.FromBytes(s.Ptr + start, length);
        }

        [TrackCaller] public static string Substring(this string s, int start) => s.Substring(start, s.Length - start);

        public static string TrimStart(this string s)
        {
            int i = 0;
            while (i < s.Length && Char.IsWhiteSpace((char)s[i])) i++;
            return String.FromBytes(s.Ptr + i, s.Length - i);
        }

        public static string TrimEnd(this string s)
        {
            int n = s.Length;
            while (n > 0 && Char.IsWhiteSpace((char)s[n - 1])) n--;
            return String.FromBytes(s.Ptr, n);
        }

        public static string Trim(this string s) => s.TrimStart().TrimEnd();

        public static int CompareTo(this string a, string b)
        {
            int n = a.Length < b.Length ? a.Length : b.Length;
            for (int i = 0; i < n; i++)
                if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
            return a.Length == b.Length ? 0 : (a.Length < b.Length ? -1 : 1);
        }

        public static bool Equals(this string a, string b) => a == b;

        public static bool EqualsIgnoreCase(this string a, string b)
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++)
                if (Char.ToLower((char)a[i]) != Char.ToLower((char)b[i])) return false;
            return true;
        }

        // Copias nuevas.
        public static string ToUpper(this string s)
        {
            byte* p = (byte*)Memory.Alloc(s.Length + 1);
            for (int i = 0; i < s.Length; i++) p[i] = (byte)Char.ToUpper((char)s[i]);
            p[s.Length] = 0;
            return String.FromBytes(p, s.Length);
        }

        public static string ToLower(this string s)
        {
            byte* p = (byte*)Memory.Alloc(s.Length + 1);
            for (int i = 0; i < s.Length; i++) p[i] = (byte)Char.ToLower((char)s[i]);
            p[s.Length] = 0;
            return String.FromBytes(p, s.Length);
        }

        // Conversión a C: la cadena resultante termina en '\0' (copia).
        public static string ToCString(this string s) => String.Copy(s);

        [TrackCaller] public static int ToInt(this string s) => Convert.ToInt32(s);
        [TrackCaller] public static long ToLong(this string s) => Convert.ToInt64(s);
        [TrackCaller] public static double ToDouble(this string s) => Convert.ToDouble(s);
    }

    // ---------------------------------------------------------------- Char (ASCII)
    public static class Char
    {
        public static bool IsDigit(char c) => c >= '0' && c <= '9';
        public static bool IsLetter(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0xC0;
        public static bool IsLetterOrDigit(char c) => IsLetter(c) || IsDigit(c);
        public static bool IsUpper(char c) => c >= 'A' && c <= 'Z';
        public static bool IsLower(char c) => c >= 'a' && c <= 'z';
        public static bool IsWhiteSpace(char c) => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
        public static char ToUpper(char c) => IsLower(c) ? (char)(c - 32) : c;
        public static char ToLower(char c) => IsUpper(c) ? (char)(c + 32) : c;
        public static int DigitValue(char c) => IsDigit(c) ? (int)(c - '0') : -1;
    }

    // ---------------------------------------------------------------- Convert
    public memory_unsafe static class Convert
    {
        static extern bool faset_parse_i64(string s, long* outValue);
        static extern bool faset_parse_f64(string s, double* outValue);

        public static bool TryToInt64(string s, out long value)
        {
            long v = 0;
            bool ok = faset_parse_i64(s.Trim(), &v);
            value = v;
            return ok;
        }

        public static bool TryToInt32(string s, out int value)
        {
            long v = 0;
            bool ok = faset_parse_i64(s.Trim(), &v) && v >= int.MinValue && v <= int.MaxValue;
            value = (int)v;
            return ok;
        }

        public static bool TryToDouble(string s, out double value)
        {
            double v = 0;
            bool ok = faset_parse_f64(s.Trim(), &v);
            value = v;
            return ok;
        }

        [TrackCaller] public static long ToInt64(string s)
        {
            long v = 0;
            if (!TryToInt64(s, out v)) panic("Convert.ToInt64: formato no válido");
            return v;
        }

        [TrackCaller] public static int ToInt32(string s)
        {
            int v = 0;
            if (!TryToInt32(s, out v)) panic("Convert.ToInt32: formato no válido");
            return v;
        }

        [TrackCaller] public static double ToDouble(string s)
        {
            double v = 0;
            if (!TryToDouble(s, out v)) panic("Convert.ToDouble: formato no válido");
            return v;
        }

        // Crean cadenas nuevas.
        public static string ToString(long v) => String.FromInt(v);
        public static string ToString(double v) => String.FromDouble(v);
        public static string ToString(bool v) => String.Copy(v ? "True" : "False");
    }

    // ---------------------------------------------------------------- Environment
    public memory_unsafe static partial class Environment
    {
        static extern void faset_exit(int code);
        static extern long faset_ticks_ms();
        static extern int faset_arg_count();
        static extern string faset_arg_get(int i);
        static extern int faset_platform();
        static extern string faset_getenv(string name);

        public static void Exit(int code) { faset_exit(code); }
        public static long TickCount64() => faset_ticks_ms();
        public static int ArgCount() => faset_arg_count();
        public static string GetArg(int index) => faset_arg_get(index);
        public static Platform CurrentPlatform() => (Platform)faset_platform();

        // Devuelve una copia o "" si no existe.
        public static string GetVariable(string name)
        {
            string value;
            TryGetVariable(name, out value);
            return value;
        }

        // Como GetVariable, pero distingue una variable vacía de una que no existe.
        // 'value' es siempre una copia.
        public static bool TryGetVariable(string name, out string value)
        {
#if WINDOWS
            ushort* w = Utf16.Encode(name);
            uint n = GetEnvironmentVariableW(w, null, 0);
            if (n == 0)
            {
                Memory.Free(w);
                value = String.Copy("");
                return GetLastError() != 203;  // ERROR_ENVVAR_NOT_FOUND
            }
            ushort* buf = Memory.New<ushort>(n + 1);
            uint got = GetEnvironmentVariableW(w, buf, n + 1);
            value = Utf16.Decode(buf, got < n ? (int)got : (int)n - 1);
            Memory.Free(buf);
            Memory.Free(w);
            return true;
#else
            string v = faset_getenv(name);
            if (v.Ptr == null)
            {
                value = String.Copy("");
                return false;
            }
            value = v;
            return true;
#endif
        }

#if WINDOWS
        static extern uint GetEnvironmentVariableW(ushort* name, ushort* buffer, uint size);
        static extern uint GetLastError();
#endif
    }

    // ---------------------------------------------------------------- Utf16
    //  Conversión UTF-8 <-> UTF-16 (para las API W de Windows, JNI, etc.).
    //  Las secuencias no válidas se sustituyen por U+FFFD.
    public memory_unsafe static class Utf16
    {
        // Número de unidades UTF-16 que ocupa 's'.
        public static int Length(string s)
        {
            int n = 0, i = 0;
            while (i < s.Length)
            {
                char c = NextCodePoint(s, ref i);
                n += c >= 0x10000 ? 2 : 1;
            }
            return n;
        }

        // Copia terminada en 0.
        public static ushort* Encode(string s)
        {
            int length;
            return Encode(s, out length);
        }

        // Igual, y devuelve en 'length' el número de unidades (sin el 0 final).
        public static ushort* Encode(string s, out int length)
        {
            ushort* w = Memory.New<ushort>(Length(s) + 1);
            int n = 0, i = 0;
            while (i < s.Length)
            {
                char c = NextCodePoint(s, ref i);
                if (c >= 0x10000)
                {
                    uint v = (uint)c - 0x10000;
                    w[n++] = (ushort)(0xD800 + (v >> 10));
                    w[n++] = (ushort)(0xDC00 + (v & 0x3FF));
                }
                else w[n++] = (ushort)c;
            }
            w[n] = 0;
            length = n;
            return w;
        }

        // Cadena UTF-8 nueva a partir de texto UTF-16 terminado en 0.
        public static string Decode(ushort* w)
        {
            int n = 0;
            if (w != null) while (w[n] != 0) n++;
            return Decode(w, n);
        }

        // Cadena UTF-8 nueva a partir de 'count' unidades UTF-16.
        public static string Decode(ushort* w, int count)
        {
            byte* p = (byte*)Memory.Alloc((long)count * 3 + 1);
            int n = 0;
            for (int i = 0; i < count; i++)
            {
                uint c = w[i];
                if (c >= 0xD800 && c < 0xDC00 && i + 1 < count && w[i + 1] >= 0xDC00 && w[i + 1] < 0xE000)
                {
                    c = 0x10000 + ((c - 0xD800) << 10) + ((uint)w[i + 1] - 0xDC00);
                    i++;
                }
                else if (c >= 0xD800 && c < 0xE000) c = 0xFFFD;
                if (c < 0x80) p[n++] = (byte)c;
                else if (c < 0x800)
                {
                    p[n++] = (byte)(0xC0 | (c >> 6));
                    p[n++] = (byte)(0x80 | (c & 0x3F));
                }
                else if (c < 0x10000)
                {
                    p[n++] = (byte)(0xE0 | (c >> 12));
                    p[n++] = (byte)(0x80 | ((c >> 6) & 0x3F));
                    p[n++] = (byte)(0x80 | (c & 0x3F));
                }
                else
                {
                    p[n++] = (byte)(0xF0 | (c >> 18));
                    p[n++] = (byte)(0x80 | ((c >> 12) & 0x3F));
                    p[n++] = (byte)(0x80 | ((c >> 6) & 0x3F));
                    p[n++] = (byte)(0x80 | (c & 0x3F));
                }
            }
            p[n] = 0;
            return String.FromBytes(p, n);
        }

        // Decodifica el punto de código UTF-8 que empieza en 'i' y avanza 'i'.
        static char NextCodePoint(string s, ref int i)
        {
            uint b = s[i];
            int extra = b < 0x80 ? 0 : (b & 0xE0) == 0xC0 ? 1 : (b & 0xF0) == 0xE0 ? 2 : (b & 0xF8) == 0xF0 ? 3 : -1;
            if (extra < 0 || i + extra >= s.Length)
            {
                i++;
                return (char)0xFFFD;
            }
            uint c = extra == 0 ? b : b & (uint)(0x3F >> extra);
            for (int k = 1; k <= extra; k++)
            {
                uint t = s[i + k];
                if ((t & 0xC0) != 0x80)
                {
                    i += k;
                    return (char)0xFFFD;
                }
                c = (c << 6) | (t & 0x3F);
            }
            i += extra + 1;
            if ((extra == 1 && c < 0x80) || (extra == 2 && c < 0x800) || (extra == 3 && (c < 0x10000 || c > 0x10FFFF)) ||
                (c >= 0xD800 && c < 0xE000)) return (char)0xFFFD;
            return (char)c;
        }
    }

    // ---------------------------------------------------------------- object y Type
    //  Toda clase deriva implícitamente de 'object' (std.Object). Los tipos primitivos, 'string'
    //  y los structs no son objetos (no hay boxing): no se convierten a 'object'.
    static extern void* faset_obj_type(void* o);
    static extern int faset_obj_hash(void* o);
    static extern string faset_type_name(void* t);
    static extern string faset_type_fullname(void* t);
    static extern void* faset_type_base(void* t);
    static extern int faset_type_kind(void* t);
    static extern int faset_type_flags(void* t);
    static extern bool faset_type_assignable(void* to, void* from);
    static extern int faset_type_enum_count(void* t);
    static extern string faset_type_enum_name(void* t, int i);
    static extern int faset_type_enum_value(void* t, int i);

    public memory_unsafe class Object
    {
        // Por defecto, el nombre completo del tipo (p. ej. "Zoo.Perro").
        public virtual string ToString() { return faset_type_fullname(faset_obj_type((void*)this)); }
        // Por defecto, igualdad de referencias.
        public virtual bool Equals(object other) { return (void*)this == (void*)other; }
        public virtual int GetHashCode() { return faset_obj_hash((void*)this); }
        // Tipo del objeto en tiempo de ejecución (el más derivado).
        public Type GetType() { return Type.FromHandle(faset_obj_type((void*)this)); }
        public static bool ReferenceEquals(object a, object b) { return (void*)a == (void*)b; }
        public static bool Equals(object a, object b)
        {
            if ((void*)a == (void*)b) return true;
            if ((void*)a == null || (void*)b == null) return false;
            return a.Equals(b);
        }
    }

    // Descripción de un tipo: typeof(T) u obj.GetType(). Dos Type del mismo tipo son iguales (==).
    public sealed memory_unsafe class Type
    {
        private void* handle;
        private Type(void* h) { handle = h; }
        public memory_unsafe static Type FromHandle(void* h)
        {
            if (h == null) return null;
            return new Type(h);
        }
        public memory_unsafe void* Handle => handle;

        public string Name => faset_type_name(handle);
        public string FullName => faset_type_fullname(handle);
        public Type BaseType => FromHandle(faset_type_base(handle));
        public bool IsClass => faset_type_kind(handle) == 0;
        public bool IsInterface => faset_type_kind(handle) == 1;
        public bool IsEnum => faset_type_kind(handle) == 2;
        public bool IsValueType => faset_type_kind(handle) >= 2;
        public bool IsAbstract => (faset_type_flags(handle) & 1) != 0 || IsInterface;
        public bool IsSealed => (faset_type_flags(handle) & 2) != 0;
        public bool IsRecord => (faset_type_flags(handle) & 4) != 0;

        // ¿Se puede asignar un valor de tipo 'other' a una variable de este tipo?
        public bool IsAssignableFrom(Type other)
        {
            if ((void*)other == null) return false;
            return faset_type_assignable(handle, other.handle);
        }
        public bool IsSubclassOf(Type other)
        {
            if ((void*)other == null || other.handle == handle) return false;
            return IsClass && faset_type_assignable(other.handle, handle);
        }
        public bool IsInstanceOfType(object o)
        {
            if ((void*)o == null) return false;
            return faset_type_assignable(handle, faset_obj_type((void*)o));
        }
        public std.collections.List<string> GetEnumNames()
        {
            std.collections.List<string> names = new std.collections.List<string>();
            int n = faset_type_enum_count(handle);
            for (int i = 0; i < n; i++) names.Add(faset_type_enum_name(handle, i));
            return names;
        }

        public override string ToString() => FullName;
        public override bool Equals(object o)
        {
            Type t = o as Type;
            return (void*)t != null && t.handle == handle;
        }
        public override int GetHashCode() => faset_obj_hash(handle);
        public static bool operator==(Type a, Type b)
        {
            void* x = (void*)a;
            void* y = (void*)b;
            if (x == null || y == null) return x == y;
            return a.handle == b.handle;
        }
        public static bool operator!=(Type a, Type b) => !(a == b);
    }

    // ---------------------------------------------------------------- Enum
    //  Color c = Color.Rojo;  c.ToString() == "Rojo";  Enum.Parse<Color>("Verde", out c)
    public memory_unsafe static class Enum
    {
        public static string GetName<T>(T value) => value.ToString();
        public static int Count<T>() => faset_type_enum_count(typeof(T).Handle);
        public static bool IsDefined<T>(string name)
        {
            T v;
            return TryParse<T>(name, out v);
        }
        // Busca el miembro con ese nombre: devuelve false (y default) si no existe.
        public static bool TryParse<T>(string name, out T value)
        {
            void* t = typeof(T).Handle;
            int n = faset_type_enum_count(t);
            for (int i = 0; i < n; i++)
            {
                if (faset_type_enum_name(t, i) == name)
                {
                    value = (T)faset_type_enum_value(t, i);
                    return true;
                }
            }
            value = default(T);
            return false;
        }
        public static bool Parse<T>(string name, out T value) => TryParse<T>(name, out value);
        // Como TryParse, pero termina con 'panic' si el nombre no existe.
        [TrackCaller] public static T Parse<T>(string name)
        {
            T v;
            if (!TryParse<T>(name, out v)) panic("'" + name + "' no es un valor de " + typeof(T).Name);
            return v;
        }
        public static std.collections.List<string> GetNames<T>() => typeof(T).GetEnumNames();
        public static std.collections.List<T> GetValues<T>()
        {
            void* t = typeof(T).Handle;
            std.collections.List<T> values = new std.collections.List<T>();
            int n = faset_type_enum_count(t);
            for (int i = 0; i < n; i++) values.Add((T)faset_type_enum_value(t, i));
            return values;
        }
    }

    // ---------------------------------------------------------------- interfaces genéricas
    //  Los tipos primitivos y 'string' cumplen 'where T : IComparable<T>' e IEquatable<T>.
    public interface IComparable<T> { int CompareTo(T other); }
    public interface IEquatable<T> { bool Equals(T other); }

    public static class ComparableExtensions
    {
        public static int CompareTo(this int a, int b) => a < b ? -1 : a > b ? 1 : 0;
        public static int CompareTo(this long a, long b) => a < b ? -1 : a > b ? 1 : 0;
        public static int CompareTo(this uint a, uint b) => a < b ? -1 : a > b ? 1 : 0;
        public static int CompareTo(this ulong a, ulong b) => a < b ? -1 : a > b ? 1 : 0;
        public static int CompareTo(this double a, double b) => a < b ? -1 : a > b ? 1 : 0;
        public static int CompareTo(this float a, float b) => a < b ? -1 : a > b ? 1 : 0;
        public static int CompareTo(this char a, char b) => a < b ? -1 : a > b ? 1 : 0;
    }
}
