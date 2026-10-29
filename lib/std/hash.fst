// =============================================================================
//  std.hash  —  funciones hash (FNV-1a de 64 bits y mezcla de enteros).
//  Las usa Dictionary<K, V> / HashSet<T>.
// =============================================================================
namespace std.hash
{
    public static class Hash
    {
        public const ulong FnvOffset = 14695981039346656037UL;
        public const ulong FnvPrime = 1099511628211UL;

        // Mezcla de bits (splitmix64): buena distribución para claves enteras.
        public static ulong Mix(ulong x)
        {
            x ^= x >> 30;
            x *= 0xBF58476D1CE4E5B9UL;
            x ^= x >> 27;
            x *= 0x94D049BB133111EBUL;
            x ^= x >> 31;
            return x;
        }

        public static ulong Of(int v) => Mix((ulong)v);
        public static ulong Of(uint v) => Mix(v);
        public static ulong Of(long v) => Mix((ulong)v);
        public static ulong Of(ulong v) => Mix(v);
        public static ulong Of(char v) => Mix(v);
        public static ulong Of(bool v) => v ? 1UL : 0UL;
        public static ulong Of(void* p) => Mix((ulong)p);

        public static ulong Of(double v)
        {
            double d = v == 0.0 ? 0.0 : v;  // +0 y -0 producen el mismo hash
            return Mix(*(ulong*)&d);
        }

        public static ulong Of(string s) => Bytes(s.Ptr, s.Length);

        // FNV-1a sobre un bloque de bytes.
        public static ulong Bytes(byte* data, long length)
        {
            ulong h = FnvOffset;
            for (long i = 0; i < length; i++)
            {
                h ^= data[i];
                h *= FnvPrime;
            }
            return h;
        }

        public static ulong Combine(ulong a, ulong b) => a ^ (b + 0x9E3779B97F4A7C15UL + (a << 6) + (a >> 2));
    }
}
