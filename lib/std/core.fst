// =============================================================================
//  std  —  núcleo de la biblioteca estándar de Faset (siempre disponible).
//
//  Se importa automáticamente en todos los archivos (como 'using std;').
//  Contiene: Console, Math, Memory, String, Char, Convert, Int32/Int64/Double/Boolean
//  (int.Parse...), Environment, extensiones de 'string' y las funciones globales
//  print/println/panic/assert. Las excepciones están en exceptions.fst (también implícito).
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
    public func print(v: string) { Console.Write(v); }
    public func print(v: long) { Console.Write(v); }
    public func print(v: double) { Console.Write(v); }
    public func print(v: char) { Console.Write(v); }
    public func print(v: bool) { Console.Write(v ? "true" : "false"); }
    public func println() { Console.WriteLine(); }
    public func println(v: string) { Console.WriteLine(v); }
    public func println(v: long) { Console.WriteLine(v); }
    public func println(v: double) { Console.WriteLine(v); }
    public func println(v: char) { Console.WriteLine(v); }
    public func println(v: bool) { Console.WriteLine(v ? "true" : "false"); }

    // Termina el programa con un mensaje de error en stderr y código de salida 101:
    //   Faset panic: <mensaje> at archivo.fst:línea
    // [TrackCaller]: la ubicación es la de quien llama (no la de esta función).
    [TrackCaller] public func panic(message: string) { memory_unsafe { faset_panic_at(message); } }

    // Comprueba una condición; si es falsa, termina con 'message'.
    [TrackCaller] public func assert(condition: bool, message: string)
    {
        if (!condition) panic(message);
    }

    // ---------------------------------------------------------------- Console
    public memory_unsafe static class Console
    {
        public static func Write(v: string) { faset_write_str(v); }
        public static func Write(v: int) { faset_write_i64(v); }
        public static func Write(v: long) { faset_write_i64(v); }
        public static func Write(v: uint) { faset_write_u64(v); }
        public static func Write(v: ulong) { faset_write_u64(v); }
        public static func Write(v: float) { faset_write_f32(v); }
        public static func Write(v: double) { faset_write_f64(v); }
        public static func Write(v: char) { faset_write_char(v); }
        public static func Write(v: void*) { faset_write_ptr(v); }
        public static func Write(v: bool) { faset_write_str(v ? "True" : "False"); }
        // Objetos: su ToString() (virtual); null no escribe nada.
        public static func Write(v: object) { if (v != null) faset_write_str(v.ToString()); }

        public static func WriteLine() { faset_write_char('\n'); }
        public static func WriteLine(v: string) { Write(v); WriteLine(); }
        public static func WriteLine(v: int) { Write(v); WriteLine(); }
        public static func WriteLine(v: long) { Write(v); WriteLine(); }
        public static func WriteLine(v: uint) { Write(v); WriteLine(); }
        public static func WriteLine(v: ulong) { Write(v); WriteLine(); }
        public static func WriteLine(v: float) { Write(v); WriteLine(); }
        public static func WriteLine(v: double) { Write(v); WriteLine(); }
        public static func WriteLine(v: char) { Write(v); WriteLine(); }
        public static func WriteLine(v: bool) { Write(v); WriteLine(); }
        public static func WriteLine(v: object) { Write(v); WriteLine(); }
        public static func WriteLine(v: void*) { Write(v); WriteLine(); }

        // Escribe en la salida de error.
        public static func Error(v: string) { faset_write_err_str(v); }
        public static func ErrorLine(v: string) { faset_write_err_str(v); faset_write_err_str("\n"); }

        public static func Flush() { faset_flush(); }

        // Devuelve una cadena nueva.
        public static func ReadLine() -> string { return faset_read_line(); }
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

        public static func Sqrt(x: double) -> double => sqrt(x);
        public static func Cbrt(x: double) -> double => cbrt(x);
        public static func Pow(x: double, y: double) -> double => pow(x, y);
        public static func Sin(x: double) -> double => sin(x);
        public static func Cos(x: double) -> double => cos(x);
        public static func Tan(x: double) -> double => tan(x);
        public static func Asin(x: double) -> double => asin(x);
        public static func Acos(x: double) -> double => acos(x);
        public static func Atan(x: double) -> double => atan(x);
        public static func Atan2(y: double, x: double) -> double => atan2(y, x);
        public static func Sinh(x: double) -> double => sinh(x);
        public static func Cosh(x: double) -> double => cosh(x);
        public static func Tanh(x: double) -> double => tanh(x);
        public static func Exp(x: double) -> double => exp(x);
        public static func Log(x: double) -> double => log(x);
        public static func Log2(x: double) -> double => log2(x);
        public static func Log10(x: double) -> double => log10(x);
        public static func Floor(x: double) -> double => floor(x);
        public static func Ceiling(x: double) -> double => ceil(x);
        public static func Truncate(x: double) -> double => trunc(x);
        public static func Round(x: double) -> double => rint(x);
        public static func Mod(x: double, y: double) -> double => fmod(x, y);
        public static func Hypot(x: double, y: double) -> double => hypot(x, y);

        public static func Abs(x: double) -> double => fabs(x);
        public static func Abs(x: int) -> int => x < 0 ? -x : x;
        public static func Abs(x: long) -> long => x < 0 ? -x : x;
        public static func Sign(x: double) -> int => x > 0 ? 1 : (x < 0 ? -1 : 0);
        public static func Sign(x: long) -> int => x > 0 ? 1 : (x < 0 ? -1 : 0);

        public static func Min(a: int, b: int) -> int => a < b ? a : b;
        public static func Min(a: long, b: long) -> long => a < b ? a : b;
        public static func Min(a: double, b: double) -> double => a < b ? a : b;
        public static func Max(a: int, b: int) -> int => a > b ? a : b;
        public static func Max(a: long, b: long) -> long => a > b ? a : b;
        public static func Max(a: double, b: double) -> double => a > b ? a : b;
        public static func Clamp(v: int, lo: int, hi: int) -> int => v < lo ? lo : (v > hi ? hi : v);
        public static func Clamp(v: long, lo: long, hi: long) -> long => v < lo ? lo : (v > hi ? hi : v);
        public static func Clamp(v: double, lo: double, hi: double) -> double => v < lo ? lo : (v > hi ? hi : v);

        public static func Lerp(a: double, b: double, t: double) -> double => a + (b - a) * t;
        public static func DegToRad(deg: double) -> double => deg * (PI / 180.0);
        public static func RadToDeg(rad: double) -> double => rad * (180.0 / PI);
        public static func IsNaN(x: double) -> bool => x != x;

        public static func Gcd(a: long, b: long) -> long
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

        public static func Lcm(a: long, b: long) -> long => a == 0 || b == 0 ? 0 : Abs(a / Gcd(a, b) * b);

        public static func IsPrime(n: long) -> bool
        {
            if (n < 2) return false;
            if (n % 2 == 0) return n == 2;
            for (long d = 3; d * d <= n; d += 2)
                if (n % d == 0) return false;
            return true;
        }

        // Potencia entera rápida.
        public static func IPow(b: long, e: int) -> long
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
        public memory_unsafe static func Alloc(size: long) -> void* => faset_alloc(size);
        // Bloque de bytes que nunca contendrá punteros: el recolector no lo recorre (más rápido).
        public memory_unsafe static func AllocBytes(size: long) -> byte* => (byte*)faset_alloc_atomic(size);
        public memory_unsafe static func AllocZeroed(size: long) -> void* => faset_alloc_zeroed(size);
        public memory_unsafe static func Realloc(p: void*, size: long) -> void* => faset_realloc(p, size);
        public memory_unsafe static func Free(p: void*) { faset_free(p); }
        public memory_unsafe static func Copy(dst: void*, src: void*, n: long) { faset_mem_copy(dst, src, n); }
        public memory_unsafe static func Set(dst: void*, value: int, n: long) { faset_mem_set(dst, value, n); }
        public memory_unsafe static func Compare(a: void*, b: void*, n: long) -> int => faset_mem_compare(a, b, n);

        // Reserva 'count' elementos de tipo T inicializados a cero.
        public memory_unsafe static func New<T>(count: long) -> T* => (T*)faset_alloc_zeroed(sizeof(T) * count);

        // Cambia el tamaño de un bloque de elementos T.
        public memory_unsafe static func Resize<T>(p: T*, count: long) -> T* => (T*)faset_realloc(p, sizeof(T) * count);

        // Copia 'count' elementos de tipo T.
        public memory_unsafe static func CopyItems<T>(dst: T*, src: T*, count: long) { faset_mem_copy(dst, src, sizeof(T) * count); }
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
        public static func Collect() { faset_gc_collect(); }
        // Bytes que el montón ocupa ahora.
        public static prop HeapBytes: long => faset_gc_heap_bytes();
        // Bytes en uso (vivos tras la última recolección más lo reservado desde entonces).
        public static prop TotalMemory: long => faset_gc_live_bytes();
        // Recolecciones hechas desde que empezó el programa.
        public static prop Collections: long => faset_gc_count();
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
        public static func Concat(a: string, b: string) -> string => faset_str_concat(a, b);
        public static func Concat(a: string, b: string, c: string) -> string
        {
            string ab = faset_str_concat(a, b);
            string r = faset_str_concat(ab, c);
            faset_str_free(ab);
            return r;
        }
        public static func Copy(s: string) -> string => faset_str_copy(s);
        public static func FromInt(v: long) -> string => faset_i64_to_str(v);
        public static func FromUInt(v: ulong) -> string => faset_u64_to_str(v);
        public static func FromDouble(v: double) -> string => faset_f64_to_str(v);
        // Ya no hace falta: el recolector recupera las cadenas. Se conserva por compatibilidad.
        public static func Free(s: string) { faset_str_free(s); }

        // Vistas (no copian ni reservan memoria).
        public static func FromCString(p: byte*) -> string => faset_str_from_cstr(p);
        public static func FromBytes(p: byte*, length: long) -> string => faset_str_make(p, length);
    }

    // ---------------------------------------------------------------- extensiones de string
    //  Las cadenas son vistas UTF-8 inmutables: Substring/Trim no copian.
    public memory_unsafe static class StringExtensions
    {
        public static func IsEmpty(this s: string) -> bool => s.Length == 0;

        public static func StartsWith(this s: string, prefix: string) -> bool
        {
            if (prefix.Length > s.Length) return false;
            for (int i = 0; i < prefix.Length; i++)
                if (s[i] != prefix[i]) return false;
            return true;
        }

        public static func EndsWith(this s: string, suffix: string) -> bool
        {
            int off = s.Length - suffix.Length;
            if (off < 0) return false;
            for (int i = 0; i < suffix.Length; i++)
                if (s[off + i] != suffix[i]) return false;
            return true;
        }

        public static func IndexOf(this s: string, sub: string) -> int => s.IndexOf(sub, 0);

        public static func IndexOf(this s: string, sub: string, start: int) -> int
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

        public static func LastIndexOf(this s: string, sub: string) -> int
        {
            for (int i = s.Length - sub.Length; i >= 0; i--)
            {
                int j = 0;
                while (j < sub.Length && s[i + j] == sub[j]) j++;
                if (j == sub.Length) return i;
            }
            return -1;
        }

        public static func Contains(this s: string, sub: string) -> bool => s.IndexOf(sub, 0) >= 0;

        public static func Count(this s: string, sub: string) -> int
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

        [TrackCaller] public static func Substring(this s: string, start: int, length: int) -> string
        {
            if (start < 0 || length < 0 || start + length > s.Length) throw new ArgumentOutOfRangeException("Substring: rango fuera de la cadena", null);
            return String.FromBytes(s.Ptr + start, length);
        }

        [TrackCaller] public static func Substring(this s: string, start: int) -> string => s.Substring(start, s.Length - start);

        public static func TrimStart(this s: string) -> string
        {
            int i = 0;
            while (i < s.Length && Char.IsWhiteSpace((char)s[i])) i++;
            return String.FromBytes(s.Ptr + i, s.Length - i);
        }

        public static func TrimEnd(this s: string) -> string
        {
            int n = s.Length;
            while (n > 0 && Char.IsWhiteSpace((char)s[n - 1])) n--;
            return String.FromBytes(s.Ptr, n);
        }

        public static func Trim(this s: string) -> string => s.TrimStart().TrimEnd();

        public static func CompareTo(this a: string, b: string) -> int
        {
            int n = a.Length < b.Length ? a.Length : b.Length;
            for (int i = 0; i < n; i++)
                if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
            return a.Length == b.Length ? 0 : (a.Length < b.Length ? -1 : 1);
        }

        public static func Equals(this a: string, b: string) -> bool => a == b;

        public static func EqualsIgnoreCase(this a: string, b: string) -> bool
        {
            if (a.Length != b.Length) return false;
            for (int i = 0; i < a.Length; i++)
                if (Char.ToLower((char)a[i]) != Char.ToLower((char)b[i])) return false;
            return true;
        }

        // Copias nuevas.
        public static func ToUpper(this s: string) -> string
        {
            byte* p = (byte*)Memory.Alloc(s.Length + 1);
            for (int i = 0; i < s.Length; i++) p[i] = (byte)Char.ToUpper((char)s[i]);
            p[s.Length] = 0;
            return String.FromBytes(p, s.Length);
        }

        public static func ToLower(this s: string) -> string
        {
            byte* p = (byte*)Memory.Alloc(s.Length + 1);
            for (int i = 0; i < s.Length; i++) p[i] = (byte)Char.ToLower((char)s[i]);
            p[s.Length] = 0;
            return String.FromBytes(p, s.Length);
        }

        // Conversión a C: la cadena resultante termina en '\0' (copia).
        public static func ToCString(this s: string) -> string => String.Copy(s);

        [TrackCaller] public static func ToInt(this s: string) -> int => Convert.ToInt32(s);
        [TrackCaller] public static func ToLong(this s: string) -> long => Convert.ToInt64(s);
        [TrackCaller] public static func ToDouble(this s: string) -> double => Convert.ToDouble(s);
    }

    // ---------------------------------------------------------------- Char (ASCII)
    public static class Char
    {
        public static func IsDigit(c: char) -> bool => c >= '0' && c <= '9';
        public static func IsLetter(c: char) -> bool => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0xC0;
        public static func IsLetterOrDigit(c: char) -> bool => IsLetter(c) || IsDigit(c);
        public static func IsUpper(c: char) -> bool => c >= 'A' && c <= 'Z';
        public static func IsLower(c: char) -> bool => c >= 'a' && c <= 'z';
        public static func IsWhiteSpace(c: char) -> bool => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
        public static func ToUpper(c: char) -> char => IsLower(c) ? (char)(c - 32) : c;
        public static func ToLower(c: char) -> char => IsUpper(c) ? (char)(c + 32) : c;
        public static func DigitValue(c: char) -> int => IsDigit(c) ? (int)(c - '0') : -1;
    }

    // ---------------------------------------------------------------- Convert
    public memory_unsafe static class Convert
    {
        static extern bool faset_parse_i64(string s, long* outValue);
        static extern bool faset_parse_f64(string s, double* outValue);

        public static func TryToInt64(s: string, out value: long) -> bool
        {
            long v = 0;
            bool ok = faset_parse_i64(s.Trim(), &v);
            value = v;
            return ok;
        }

        public static func TryToInt32(s: string, out value: int) -> bool
        {
            long v = 0;
            bool ok = faset_parse_i64(s.Trim(), &v) && v >= int.MinValue && v <= int.MaxValue;
            value = (int)v;
            return ok;
        }

        public static func TryToDouble(s: string, out value: double) -> bool
        {
            double v = 0;
            bool ok = faset_parse_f64(s.Trim(), &v);
            value = v;
            return ok;
        }

        [TrackCaller] public static func ToInt64(s: string) -> long
        {
            long v = 0;
            if (!TryToInt64(s, out v)) throw new FormatException("Convert.ToInt64: formato no válido");
            return v;
        }

        [TrackCaller] public static func ToInt32(s: string) -> int
        {
            int v = 0;
            if (!TryToInt32(s, out v)) throw new FormatException("Convert.ToInt32: formato no válido");
            return v;
        }

        [TrackCaller] public static func ToDouble(s: string) -> double
        {
            double v = 0;
            if (!TryToDouble(s, out v)) throw new FormatException("Convert.ToDouble: formato no válido");
            return v;
        }

        // Crean cadenas nuevas.
        public static func ToString(v: long) -> string => String.FromInt(v);
        public static func ToString(v: double) -> string => String.FromDouble(v);
        public static func ToString(v: bool) -> string => String.Copy(v ? "True" : "False");
    }

    // ---------------------------------------------------------------- int.Parse, double.TryParse...
    //  Como en C#: int.Parse(s) es Int32.Parse(s) (long -> Int64, double -> Double, bool -> Boolean).
    //  Parse lanza FormatException (texto no válido) u OverflowException (no cabe en el tipo);
    //  TryParse devuelve false y no lanza nada.
    public static class Int32
    {
        [TrackCaller] public static func Parse(s: string) -> int
        {
            long v = 0;
            if (!Convert.TryToInt64(s, out v)) throw new FormatException("int.Parse: '" + s + "' no es un número entero");
            if (v < int.MinValue || v > int.MaxValue) throw new OverflowException("int.Parse: '" + s + "' no cabe en un int");
            return (int)v;
        }
        public static func TryParse(s: string, out result: int) -> bool => Convert.TryToInt32(s, out result);
    }

    public static class Int64
    {
        [TrackCaller] public static func Parse(s: string) -> long
        {
            long v = 0;
            if (!Convert.TryToInt64(s, out v)) throw new FormatException("long.Parse: '" + s + "' no es un número entero");
            return v;
        }
        public static func TryParse(s: string, out result: long) -> bool => Convert.TryToInt64(s, out result);
    }

    public static class Double
    {
        [TrackCaller] public static func Parse(s: string) -> double
        {
            double v = 0;
            if (!Convert.TryToDouble(s, out v)) throw new FormatException("double.Parse: '" + s + "' no es un número");
            return v;
        }
        public static func TryParse(s: string, out result: double) -> bool => Convert.TryToDouble(s, out result);
    }

    public static class Boolean
    {
        [TrackCaller] public static func Parse(s: string) -> bool
        {
            bool v = false;
            if (!TryParse(s, out v)) throw new FormatException("bool.Parse: '" + s + "' no es True ni False");
            return v;
        }
        public static func TryParse(s: string, out result: bool) -> bool
        {
            string t = s.Trim().ToLower();
            result = t == "true";
            return t == "true" || t == "false";
        }
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

        public static func Exit(code: int) { faset_exit(code); }
        public static func TickCount64() -> long => faset_ticks_ms();
        public static func ArgCount() -> int => faset_arg_count();
        public static func GetArg(index: int) -> string => faset_arg_get(index);
        public static func CurrentPlatform() -> Platform => (Platform)faset_platform();

        // Devuelve una copia o "" si no existe.
        public static func GetVariable(name: string) -> string
        {
            string value;
            TryGetVariable(name, out value);
            return value;
        }

        // Como GetVariable, pero distingue una variable vacía de una que no existe.
        // 'value' es siempre una copia.
        public static func TryGetVariable(name: string, out value: string) -> bool
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
        public static func Length(s: string) -> int
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
        public static func Encode(s: string) -> ushort*
        {
            int length;
            return Encode(s, out length);
        }

        // Igual, y devuelve en 'length' el número de unidades (sin el 0 final).
        public static func Encode(s: string, out length: int) -> ushort*
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
        public static func Decode(w: ushort*) -> string
        {
            int n = 0;
            if (w != null) while (w[n] != 0) n++;
            return Decode(w, n);
        }

        // Cadena UTF-8 nueva a partir de 'count' unidades UTF-16.
        public static func Decode(w: ushort*, count: int) -> string
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
        static func NextCodePoint(s: string, ref i: int) -> char
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
    // ---------------------------------------------------------------- Nullable<T> (T?)
    //  'int? x = null;' es un Nullable<int>. El compilador añade la conversión desde T y desde
    //  null, los operadores ?? ??= ?. y las comparaciones (x == null, x == 5, x < y).
    public struct Nullable<T>
    {
        var hasValue: bool;  // el orden de los campos lo usa el compilador: {hasValue, value}
        var value: T;

        public init(v: T)
        {
            hasValue = true;
            value = v;
        }

        public prop HasValue: bool => hasValue;

        [TrackCaller] public prop Value: T
        {
            get
            {
                if (!hasValue) panic("Nullable: no tiene valor (comprueba HasValue o usa ??)");
                return value;
            }
        }

        public func GetValueOrDefault() -> T => value;
        public func GetValueOrDefault(defaultValue: T) -> T => hasValue ? value : defaultValue;
    }

    // ---------------------------------------------------------------- foreach sobre string
    //  foreach (char c in texto) recorre los caracteres (puntos de código Unicode), no los bytes:
    //  "año" da 'a', 'ñ', 'o'. Una secuencia UTF-8 no válida da U+FFFD.
    public struct StringEnumerator
    {
        var text: string;
        var pos: int;
        var current: char;

        public init(s: string)
        {
            text = s;
            pos = 0;
            current = '\0';
        }

        public prop Current: char => current;

        public func MoveNext() -> bool
        {
            if (pos >= text.Length) return false;
            int b = text[pos];
            pos++;
            int extra = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : b >= 0xC0 ? 1 : 0;
            int cp = extra == 3 ? b & 0x07 : extra == 2 ? b & 0x0F : extra == 1 ? b & 0x1F : b;
            if (b >= 0x80 && extra == 0) cp = 0xFFFD;
            for (int k = 0; k < extra; k++)
            {
                if (pos >= text.Length || (text[pos] & 0xC0) != 0x80)
                {
                    cp = 0xFFFD;
                    break;
                }
                cp = (cp << 6) | (text[pos] & 0x3F);
                pos++;
            }
            current = (char)cp;
            return true;
        }
    }

    public static class StringEnumeration
    {
        public static func GetEnumerator(this s: string) -> StringEnumerator => new StringEnumerator(s);
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
        public virtual func ToString() -> string { return faset_type_fullname(faset_obj_type((void*)this)); }
        // Por defecto, igualdad de referencias.
        public virtual func Equals(other: object) -> bool { return (void*)this == (void*)other; }
        public virtual func GetHashCode() -> int { return faset_obj_hash((void*)this); }
        // Tipo del objeto en tiempo de ejecución (el más derivado).
        public func GetType() -> Type { return Type.FromHandle(faset_obj_type((void*)this)); }
        public static func ReferenceEquals(a: object, b: object) -> bool { return (void*)a == (void*)b; }
        public static func Equals(a: object, b: object) -> bool
        {
            if ((void*)a == (void*)b) return true;
            if ((void*)a == null || (void*)b == null) return false;
            return a.Equals(b);
        }
    }

    // Descripción de un tipo: typeof(T) u obj.GetType(). Dos Type del mismo tipo son iguales (==).
    public sealed memory_unsafe class Type
    {
        private var handle: void*;
        private init(h: void*) { handle = h; }
        public memory_unsafe static func FromHandle(h: void*) -> Type
        {
            if (h == null) return null;
            return new Type(h);
        }
        public memory_unsafe prop Handle: void* => handle;

        public prop Name: string => faset_type_name(handle);
        public prop FullName: string => faset_type_fullname(handle);
        public prop BaseType: Type => FromHandle(faset_type_base(handle));
        public prop IsClass: bool => faset_type_kind(handle) == 0;
        public prop IsInterface: bool => faset_type_kind(handle) == 1;
        public prop IsEnum: bool => faset_type_kind(handle) == 2;
        public prop IsValueType: bool => faset_type_kind(handle) >= 2;
        public prop IsAbstract: bool => (faset_type_flags(handle) & 1) != 0 || IsInterface;
        public prop IsSealed: bool => (faset_type_flags(handle) & 2) != 0;
        public prop IsRecord: bool => (faset_type_flags(handle) & 4) != 0;

        // ¿Se puede asignar un valor de tipo 'other' a una variable de este tipo?
        public func IsAssignableFrom(other: Type) -> bool
        {
            if ((void*)other == null) return false;
            return faset_type_assignable(handle, other.handle);
        }
        public func IsSubclassOf(other: Type) -> bool
        {
            if ((void*)other == null || other.handle == handle) return false;
            return IsClass && faset_type_assignable(other.handle, handle);
        }
        public func IsInstanceOfType(o: object) -> bool
        {
            if ((void*)o == null) return false;
            return faset_type_assignable(handle, faset_obj_type((void*)o));
        }
        public func GetEnumNames() -> std.collections.List<string>
        {
            std.collections.List<string> names = new std.collections.List<string>();
            int n = faset_type_enum_count(handle);
            for (int i = 0; i < n; i++) names.Add(faset_type_enum_name(handle, i));
            return names;
        }

        public override func ToString() -> string => FullName;
        public override func Equals(o: object) -> bool
        {
            Type t = o as Type;
            return (void*)t != null && t.handle == handle;
        }
        public override func GetHashCode() -> int => faset_obj_hash(handle);
        public operator ==(a: Type, b: Type) -> bool
        {
            void* x = (void*)a;
            void* y = (void*)b;
            if (x == null || y == null) return x == y;
            return a.handle == b.handle;
        }
        public operator !=(a: Type, b: Type) -> bool => !(a == b);
    }

    // ---------------------------------------------------------------- Enum
    //  Color c = Color.Rojo;  c.ToString() == "Rojo";  Enum.Parse<Color>("Verde", out c)
    public memory_unsafe static class Enum
    {
        public static func GetName<T>(value: T) -> string => value.ToString();
        public static func Count<T>() -> int => faset_type_enum_count(typeof(T).Handle);
        public static func IsDefined<T>(name: string) -> bool
        {
            T v;
            return TryParse<T>(name, out v);
        }
        // Busca el miembro con ese nombre: devuelve false (y default) si no existe.
        public static func TryParse<T>(name: string, out value: T) -> bool
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
        public static func Parse<T>(name: string, out value: T) -> bool => TryParse<T>(name, out value);
        // Como TryParse, pero termina con 'panic' si el nombre no existe.
        [TrackCaller] public static func Parse<T>(name: string) -> T
        {
            T v;
            if (!TryParse<T>(name, out v)) panic("'" + name + "' no es un valor de " + typeof(T).Name);
            return v;
        }
        public static func GetNames<T>() -> std.collections.List<string> => typeof(T).GetEnumNames();
        public static func GetValues<T>() -> std.collections.List<T>
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
        public static func CompareTo(this a: int, b: int) -> int => a < b ? -1 : a > b ? 1 : 0;
        public static func CompareTo(this a: long, b: long) -> int => a < b ? -1 : a > b ? 1 : 0;
        public static func CompareTo(this a: uint, b: uint) -> int => a < b ? -1 : a > b ? 1 : 0;
        public static func CompareTo(this a: ulong, b: ulong) -> int => a < b ? -1 : a > b ? 1 : 0;
        public static func CompareTo(this a: double, b: double) -> int => a < b ? -1 : a > b ? 1 : 0;
        public static func CompareTo(this a: float, b: float) -> int => a < b ? -1 : a > b ? 1 : 0;
        public static func CompareTo(this a: char, b: char) -> int => a < b ? -1 : a > b ? 1 : 0;
    }
}
