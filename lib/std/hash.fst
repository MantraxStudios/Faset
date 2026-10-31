// =============================================================================
//  std.hash  —  funciones hash (FNV-1a de 64 bits y mezcla de enteros).
//  Las usa Dictionary<K, V> / HashSet<T>.
// =============================================================================
namespace std.hash
{
    public memory_unsafe static class Hash
    {
        public const ulong FnvOffset = 14695981039346656037UL;
        public const ulong FnvPrime = 1099511628211UL;

        // Mezcla de bits (splitmix64): buena distribución para claves enteras.
        public static func Mix(x: ulong) -> ulong
        {
            x ^= x >> 30;
            x *= 0xBF58476D1CE4E5B9UL;
            x ^= x >> 27;
            x *= 0x94D049BB133111EBUL;
            x ^= x >> 31;
            return x;
        }

        public static func Of(v: int) -> ulong => Mix((ulong)v);
        public static func Of(v: uint) -> ulong => Mix(v);
        public static func Of(v: long) -> ulong => Mix((ulong)v);
        public static func Of(v: ulong) -> ulong => Mix(v);
        public static func Of(v: char) -> ulong => Mix(v);
        public static func Of(v: bool) -> ulong => v ? 1UL : 0UL;
        public static func Of(p: void*) -> ulong => Mix((ulong)p);

        public static func Of(v: double) -> ulong
        {
            double d = v == 0.0 ? 0.0 : v;  // +0 y -0 producen el mismo hash
            return Mix(*(ulong*)&d);
        }

        public static func Of(s: string) -> ulong => Bytes(s.Ptr, s.Length);

        // Enums: el hash de su valor numérico (permite Dictionary<MiEnum, V> y HashSet<MiEnum>).
        // Los demás tipos (short, byte, float, T*...) siguen por las conversiones implícitas de Widen,
        // porque este Of<T> le gana a Of(int) cuando el argumento no es exactamente de un tipo de arriba.
        public static func Of<T>(v: T) -> ulong
        {
            comptime if (Tipo<T>.EsEnum) { return Mix((ulong)(long)v); }
            else { return Widen(v); }
        }

        static func Widen(v: int) -> ulong => Of(v);
        static func Widen(v: uint) -> ulong => Of(v);
        static func Widen(v: long) -> ulong => Of(v);
        static func Widen(v: ulong) -> ulong => Of(v);
        static func Widen(v: double) -> ulong => Of(v);
        static func Widen(p: void*) -> ulong => Of(p);

        // FNV-1a sobre un bloque de bytes.
        public static func Bytes(data: byte*, length: long) -> ulong
        {
            ulong h = FnvOffset;
            for (long i = 0; i < length; i++)
            {
                h ^= data[i];
                h *= FnvPrime;
            }
            return h;
        }

        public static func Combine(a: ulong, b: ulong) -> ulong => a ^ (b + 0x9E3779B97F4A7C15UL + (a << 6) + (a >> 2));
    }
}
