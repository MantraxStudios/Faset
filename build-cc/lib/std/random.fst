// =============================================================================
//  std.random  —  generador de números pseudoaleatorios (xorshift64*).
//  Rápido y reproducible; NO apto para criptografía.
// =============================================================================
using std.time;

namespace std.random
{
    public memory_unsafe struct Random
    {
        var state: ulong

        public init(seed: ulong) { state = seed == 0 ? 0x9E3779B97F4A7C15UL : seed; }

        // Semilla a partir del reloj.
        public static func FromTime() -> Random => new Random((ulong)Time.NowUnixMs() * 6364136223846793005UL + 1442695040888963407UL);

        public func NextULong() -> ulong
        {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            return state * 2685821657736338717UL;
        }

        // Entero no negativo.
        public func Next() -> int => (int)(NextULong() >> 33);

        // Entero en [0, max).
        public func Next(max: int) -> int
        {
            if (max <= 0) return 0;
            return (int)(NextULong() % (ulong)max);
        }

        // Entero en [min, max).
        public func Next(min: int, max: int) -> int
        {
            if (max <= min) return min;
            return min + (int)(NextULong() % (ulong)(max - min));
        }

        // Real en [0, 1).
        public func NextDouble() -> double => (NextULong() >> 11) * (1.0 / 9007199254740992.0);

        public func NextDouble(min: double, max: double) -> double => min + (max - min) * NextDouble();

        public func NextBool() -> bool => (NextULong() & 1UL) != 0;

        // Mezcla un arreglo (Fisher-Yates).
        public func Shuffle<T>(data: T*, n: int)
        {
            for (int i = n - 1; i > 0; i--)
            {
                int j = Next(i + 1);
                T t = data[i];
                data[i] = data[j];
                data[j] = t;
            }
        }
    }
}
