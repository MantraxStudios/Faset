// =============================================================================
//  std.random  —  generador de números pseudoaleatorios (xorshift64*).
//  Rápido y reproducible; NO apto para criptografía.
// =============================================================================
using std.time;

namespace std.random
{
    public memory_unsafe struct Random
    {
        ulong state;

        public Random(ulong seed) { state = seed == 0 ? 0x9E3779B97F4A7C15UL : seed; }

        // Semilla a partir del reloj.
        public static Random FromTime() => new Random((ulong)Time.NowUnixMs() * 6364136223846793005UL + 1442695040888963407UL);

        public ulong NextULong()
        {
            state ^= state >> 12;
            state ^= state << 25;
            state ^= state >> 27;
            return state * 2685821657736338717UL;
        }

        // Entero no negativo.
        public int Next() => (int)(NextULong() >> 33);

        // Entero en [0, max).
        public int Next(int max)
        {
            if (max <= 0) return 0;
            return (int)(NextULong() % (ulong)max);
        }

        // Entero en [min, max).
        public int Next(int min, int max)
        {
            if (max <= min) return min;
            return min + (int)(NextULong() % (ulong)(max - min));
        }

        // Real en [0, 1).
        public double NextDouble() => (NextULong() >> 11) * (1.0 / 9007199254740992.0);

        public double NextDouble(double min, double max) => min + (max - min) * NextDouble();

        public bool NextBool() => (NextULong() & 1UL) != 0;

        // Mezcla un arreglo (Fisher-Yates).
        public void Shuffle<T>(T* data, int n)
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
