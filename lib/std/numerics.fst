// =============================================================================
//  std.numerics  —  enteros de precisión arbitraria (BigInteger) y decimales exactos (Decimal).
//
//    BigInteger f = BigInteger.One;
//    for (int i = 2; i <= 30; i++) f *= i;                   // operadores mixtos con long
//    println($"{f}");                                        // 265252859812191058636308480000000
//    BigInteger p = BigInteger.Parse("170141183460469231731687303715884105727");
//    println($"{BigInteger.ModPow(new BigInteger(3), p - 1, p)}");   // 1 (p es primo)
//
//    Decimal precio = Decimal.Parse("19.99");
//    Decimal total = precio * 3 + Decimal.Parse("0.03");     // 60.00: sin errores de base 2
//    println($"{Decimal.Round(Decimal.Parse("2.345"), 2)}"); // 2.34 (al par, como Math.Round de C#)
//
//  BigInteger: inmutable, con signo y sin límite de tamaño. Multiplicación de Karatsuba para
//  números grandes y división de Knuth (lib/numerics/faset_numerics.c). La división trunca
//  hacia cero y el resto lleva el signo del dividendo, como en C#.
//
//  Decimal es el System.Decimal de .NET: 96 bits de mantisa entera, de 0 a 28 cifras decimales
//  (unas 28-29 cifras significativas) y signo. Las sumas y restas de importes son exactas; si
//  un resultado no cabe se redondea al par (banker's rounding) y si ni con 0 decimales cabe,
//  lanza OverflowException. Conserva la escala: 1.50 + 1.50 da 3.00.
//
//  En Faset 'decimal' no es (aún) una palabra clave ni hay literales 1.5m: se escribe Decimal y
//  se construye con Decimal.Parse("1.5"), new Decimal(15, 1) (15 · 10^-1) o new Decimal(150L).
//  Tampoco hay conversiones implícitas: los operadores aceptan long en cualquier lado
//  (precio * 3, 1 + x) y las conversiones a otros tipos son métodos (ToInt64, ToDouble).
// =============================================================================
using std.text;

namespace std.numerics
{
    // Cómo redondear un valor que está justo en medio (los valores son los de .NET).
    public enum MidpointRounding
    {
        ToEven = 0,               // al par: 2.5 -> 2, 3.5 -> 4 (el de Math.Round; evita sesgos)
        AwayFromZero = 1,         // alejándose de cero: 2.5 -> 3, -2.5 -> -3 (el "escolar")
        ToZero = 2,               // truncar
        ToNegativeInfinity = 3,   // hacia abajo (Floor)
        ToPositiveInfinity = 4    // hacia arriba (Ceiling)
    }

    // Funciones de lib/numerics/faset_numerics.c.
    memory_unsafe static class Num
    {
        public static extern int faset_big_cmp(uint* a, int an, uint* b, int bn);
        public static extern int faset_big_add(uint* a, int an, uint* b, int bn, uint* output);
        public static extern int faset_big_sub(uint* a, int an, uint* b, int bn, uint* output);
        public static extern int faset_big_mul(uint* a, int an, uint* b, int bn, uint* output);
        public static extern int faset_big_divmod(uint* a, int an, uint* b, int bn, uint* q, uint* r, int* rn);
        public static extern int faset_big_shl(uint* a, int an, int bits, uint* output);
        public static extern int faset_big_shr(uint* a, int an, int bits, uint* output);
        public static extern int faset_big_to_string(uint* a, int an, byte* output);
        public static extern int faset_big_from_digits(byte* s, long n, uint* output);

        public static extern int faset_dec_op(int op, uint alo, uint amid, uint ahi, int af, uint blo, uint bmid, uint bhi, int bf,
                                              uint* lo, uint* mid, uint* hi, int* flags);
        public static extern int faset_dec_cmp(uint alo, uint amid, uint ahi, int af, uint blo, uint bmid, uint bhi, int bf);
        public static extern int faset_dec_round(uint alo, uint amid, uint ahi, int af, int decimals, int mode,
                                                 uint* lo, uint* mid, uint* hi, int* flags);
        public static extern int faset_dec_to_string(uint lo, uint mid, uint hi, int f, byte* output);
        public static extern int faset_dec_parse(string s, uint* lo, uint* mid, uint* hi, int* flags);
        public static extern int faset_dec_from_double(double v, uint* lo, uint* mid, uint* hi, int* flags);
        public static extern double faset_dec_to_double(uint lo, uint mid, uint hi, int f);

        public static func Words(n: int) -> uint* => (uint*)Memory.AllocBytes(4 * (n > 0 ? n : 1));
    }

    // ---------------------------------------------------------------- BigInteger

    // Entero con signo de cualquier tamaño. Es inmutable: las operaciones devuelven otro.
    public memory_unsafe struct BigInteger
    {
        var sign: int;      // -1, 0 o 1 (el valor por defecto es 0)
        var mag: uint*;     // magnitud en palabras de 32 bits, la menos significativa primero
        var len: int;       // palabras usadas (sin ceros altos)

        init(sign: int, mag: uint*, len: int)
        {
            this.sign = len == 0 ? 0 : sign;
            this.mag = mag;
            this.len = len;
        }

        public init(value: long)
        {
            mag = Num.Words(2);
            ulong u = value < 0 ? (ulong)(-(value + 1)) + 1UL : (ulong)value;
            mag[0] = (uint)(u & 0xFFFFFFFFUL);
            mag[1] = (uint)(u >> 32);
            len = mag[1] != 0 ? 2 : (mag[0] != 0 ? 1 : 0);
            sign = len == 0 ? 0 : (value < 0 ? -1 : 1);
        }

        public init(value: ulong)
        {
            mag = Num.Words(2);
            mag[0] = (uint)(value & 0xFFFFFFFFUL);
            mag[1] = (uint)(value >> 32);
            len = mag[1] != 0 ? 2 : (mag[0] != 0 ? 1 : 0);
            sign = len == 0 ? 0 : 1;
        }

        public static prop Zero: BigInteger => new BigInteger(0L);
        public static prop One: BigInteger => new BigInteger(1L);
        public static prop MinusOne: BigInteger => new BigInteger(-1L);

        // -1, 0 o 1.
        public prop Sign: int => sign;
        public prop IsZero: bool => sign == 0;
        public prop IsOne: bool => sign == 1 && len == 1 && mag[0] == 1;
        public prop IsEven: bool => sign == 0 || (mag[0] & 1) == 0;

        public prop IsPowerOfTwo: bool
        {
            get
            {
                if (sign != 1) return false;
                uint top = mag[len - 1];
                if ((top & (top - 1)) != 0) return false;
                for (int i = 0; i < len - 1; i++)
                    if (mag[i] != 0) return false;
                return true;
            }
        }

        // Bits necesarios para el valor absoluto (0 para el cero).
        public func GetBitLength() -> long
        {
            if (sign == 0) return 0;
            uint top = mag[len - 1];
            int bits = 0;
            while (top != 0)
            {
                bits++;
                top >>= 1;
            }
            return (long)(len - 1) * 32 + bits;
        }

        // ---------------------------------------------------------------- texto

        // Lee un entero en base 10 ("-123", " +45 "). Lanza FormatException si no lo es.
        [TrackCaller] public static func Parse(s: string) -> BigInteger
        {
            BigInteger r;
            if (!TryParse(s, out r)) throw new FormatException("BigInteger.Parse: '" + s + "' no es un número entero");
            return r;
        }

        public static func TryParse(s: string, out result: BigInteger) -> bool
        {
            result = Zero;
            string t = s.Trim();
            int i = 0;
            int sg = 1;
            if (t.Length > 0 && (t[0] == '-' || t[0] == '+'))
            {
                if (t[0] == '-') sg = -1;
                i = 1;
            }
            if (i >= t.Length) return false;
            for (int k = i; k < t.Length; k++)
                if (t[k] < '0' || t[k] > '9') return false;
            uint* w = Num.Words((t.Length - i) / 9 + 2);
            int n = Num.faset_big_from_digits(t.Ptr + i, t.Length - i, w);
            result = new BigInteger(sg, w, n);
            return true;
        }

        public override func ToString() -> string
        {
            byte* p = Memory.AllocBytes(10 * len + 2);
            int n = 0;
            if (sign < 0) p[n++] = (byte)'-';
            n += Num.faset_big_to_string(mag, len, p + n);
            return String.FromBytes(p, n);
        }

        // Hexadecimal del valor absoluto, con '-' delante si es negativo ("ff", "-1a").
        public func ToHexString() -> string
        {
            if (sign == 0) return "0";
            StringBuilder sb = new StringBuilder();
            if (sign < 0) sb.Append('-');
            string digits = "0123456789abcdef";
            bool started = false;
            for (int i = len - 1; i >= 0; i--)
                for (int s = 28; s >= 0; s -= 4)
                {
                    int d = (int)((mag[i] >> s) & 15);
                    if (d == 0 && !started) continue;
                    started = true;
                    sb.AppendByte(digits[d]);
                }
            return sb.ToString();
        }

        public func GetHashCode() -> int
        {
            ulong h = (ulong)(sign + 1);
            for (int i = 0; i < len; i++) h = (h ^ mag[i]) * 1099511628211UL;
            return (int)(h ^ (h >> 32));
        }

        // ---------------------------------------------------------------- conversiones

        // A long; lanza OverflowException si no cabe.
        [TrackCaller] public func ToInt64() -> long
        {
            if (sign == 0) return 0;
            if (len > 2) throw new OverflowException("BigInteger: el valor no cabe en un long");
            ulong u = mag[0];
            if (len == 2) u |= (ulong)mag[1] << 32;
            if (sign > 0)
            {
                if (u > 9223372036854775807UL) throw new OverflowException("BigInteger: el valor no cabe en un long");
                return (long)u;
            }
            if (u > 9223372036854775808UL) throw new OverflowException("BigInteger: el valor no cabe en un long");
            return u == 9223372036854775808UL ? -9223372036854775807L - 1 : -(long)u;
        }

        [TrackCaller] public func ToInt32() -> int
        {
            long v = ToInt64();
            if (v < -2147483648L || v > 2147483647L) throw new OverflowException("BigInteger: el valor no cabe en un int");
            return (int)v;
        }

        public func TryToInt64(out value: long) -> bool
        {
            value = 0;
            if (len > 2) return false;
            try { value = ToInt64(); }
            catch (OverflowException e) { return false; }
            return true;
        }

        // Aproximación en coma flotante (infinito si es enorme).
        public func ToDouble() -> double
        {
            double r = 0;
            for (int i = len - 1; i >= 0; i--) r = r * 4294967296.0 + mag[i];
            return sign < 0 ? -r : r;
        }

        // ---------------------------------------------------------------- aritmética

        static func CmpMag(a: BigInteger, b: BigInteger) -> int => Num.faset_big_cmp(a.mag, a.len, b.mag, b.len);

        static func AddMag(a: BigInteger, b: BigInteger, sg: int) -> BigInteger
        {
            int n = (a.len > b.len ? a.len : b.len) + 1;
            uint* w = Num.Words(n);
            return new BigInteger(sg, w, Num.faset_big_add(a.mag, a.len, b.mag, b.len, w));
        }

        // |a| - |b| con |a| >= |b|.
        static func SubMag(a: BigInteger, b: BigInteger, sg: int) -> BigInteger
        {
            uint* w = Num.Words(a.len);
            return new BigInteger(sg, w, Num.faset_big_sub(a.mag, a.len, b.mag, b.len, w));
        }

        public operator +(a: BigInteger, b: BigInteger) -> BigInteger
        {
            if (a.sign == 0) return b;
            if (b.sign == 0) return a;
            if (a.sign == b.sign) return AddMag(a, b, a.sign);
            int c = CmpMag(a, b);
            if (c == 0) return Zero;
            return c > 0 ? SubMag(a, b, a.sign) : SubMag(b, a, b.sign);
        }

        public operator -(a: BigInteger) -> BigInteger => new BigInteger(-a.sign, a.mag, a.len);
        public operator -(a: BigInteger, b: BigInteger) -> BigInteger => a + (-b);

        public operator *(a: BigInteger, b: BigInteger) -> BigInteger
        {
            if (a.sign == 0 || b.sign == 0) return Zero;
            uint* w = Num.Words(a.len + b.len);
            return new BigInteger(a.sign * b.sign, w, Num.faset_big_mul(a.mag, a.len, b.mag, b.len, w));
        }

        // Cociente truncado hacia cero y resto con el signo del dividendo (como C#).
        [TrackCaller] public static func DivRem(a: BigInteger, b: BigInteger, out remainder: BigInteger) -> BigInteger
        {
            if (b.sign == 0) throw new DivideByZeroException("BigInteger: división por cero");
            if (CmpMag(a, b) < 0)
            {
                remainder = a;
                return Zero;
            }
            uint* q = Num.Words(a.len - b.len + 1);
            uint* r = Num.Words(b.len);
            int rn = 0;
            int qn = Num.faset_big_divmod(a.mag, a.len, b.mag, b.len, q, r, &rn);
            remainder = new BigInteger(a.sign, r, rn);
            return new BigInteger(a.sign * b.sign, q, qn);
        }

        [TrackCaller] public operator /(a: BigInteger, b: BigInteger) -> BigInteger
        {
            BigInteger r;
            return DivRem(a, b, out r);
        }

        [TrackCaller] public operator %(a: BigInteger, b: BigInteger) -> BigInteger
        {
            BigInteger r;
            DivRem(a, b, out r);
            return r;
        }

        // Desplazamientos: multiplican o dividen (redondeando hacia -infinito, como C#) por 2^n.
        public operator <<(a: BigInteger, n: int) -> BigInteger
        {
            if (n < 0) return a >> -n;
            if (a.sign == 0 || n == 0) return a;
            uint* w = Num.Words(a.len + n / 32 + 1);
            return new BigInteger(a.sign, w, Num.faset_big_shl(a.mag, a.len, n, w));
        }

        public operator >>(a: BigInteger, n: int) -> BigInteger
        {
            if (n < 0) return a << -n;
            if (a.sign == 0 || n == 0) return a;
            if (a.sign < 0) return -((-a - One) >> n) - One;   // -x >> n = -((x - 1) >> n) - 1
            uint* w = Num.Words(a.len);
            return new BigInteger(1, w, Num.faset_big_shr(a.mag, a.len, n, w));
        }

        // Comparaciones.
        public static func Compare(a: BigInteger, b: BigInteger) -> int
        {
            if (a.sign != b.sign) return a.sign < b.sign ? -1 : 1;
            int c = CmpMag(a, b);
            return a.sign < 0 ? -c : c;
        }

        public func CompareTo(other: BigInteger) -> int => Compare(this, other);
        public func Equals(other: BigInteger) -> bool => Compare(this, other) == 0;

        public operator ==(a: BigInteger, b: BigInteger) -> bool => Compare(a, b) == 0;
        public operator <(a: BigInteger, b: BigInteger) -> bool => Compare(a, b) < 0;
        public operator >(a: BigInteger, b: BigInteger) -> bool => Compare(a, b) > 0;
        public operator <=(a: BigInteger, b: BigInteger) -> bool => Compare(a, b) <= 0;
        public operator >=(a: BigInteger, b: BigInteger) -> bool => Compare(a, b) >= 0;

        // Mezclados con long (Faset no tiene conversiones implícitas definidas por el usuario).
        public operator +(a: BigInteger, b: long) -> BigInteger => a + new BigInteger(b);
        public operator +(a: long, b: BigInteger) -> BigInteger => new BigInteger(a) + b;
        public operator -(a: BigInteger, b: long) -> BigInteger => a - new BigInteger(b);
        public operator -(a: long, b: BigInteger) -> BigInteger => new BigInteger(a) - b;
        public operator *(a: BigInteger, b: long) -> BigInteger => a * new BigInteger(b);
        public operator *(a: long, b: BigInteger) -> BigInteger => new BigInteger(a) * b;
        [TrackCaller] public operator /(a: BigInteger, b: long) -> BigInteger => a / new BigInteger(b);
        [TrackCaller] public operator /(a: long, b: BigInteger) -> BigInteger => new BigInteger(a) / b;
        [TrackCaller] public operator %(a: BigInteger, b: long) -> BigInteger => a % new BigInteger(b);
        [TrackCaller] public operator %(a: long, b: BigInteger) -> BigInteger => new BigInteger(a) % b;
        public operator ==(a: BigInteger, b: long) -> bool => Compare(a, new BigInteger(b)) == 0;
        public operator <(a: BigInteger, b: long) -> bool => Compare(a, new BigInteger(b)) < 0;
        public operator >(a: BigInteger, b: long) -> bool => Compare(a, new BigInteger(b)) > 0;
        public operator <=(a: BigInteger, b: long) -> bool => Compare(a, new BigInteger(b)) <= 0;
        public operator >=(a: BigInteger, b: long) -> bool => Compare(a, new BigInteger(b)) >= 0;

        // ---------------------------------------------------------------- funciones

        public static func Abs(a: BigInteger) -> BigInteger => a.sign < 0 ? -a : a;
        public static func Negate(a: BigInteger) -> BigInteger => -a;
        public static func Min(a: BigInteger, b: BigInteger) -> BigInteger => a <= b ? a : b;
        public static func Max(a: BigInteger, b: BigInteger) -> BigInteger => a >= b ? a : b;

        // a^exponent (exponent >= 0), por cuadrados sucesivos.
        [TrackCaller] public static func Pow(a: BigInteger, exponent: int) -> BigInteger
        {
            if (exponent < 0) throw new ArgumentOutOfRangeException("exponent", "BigInteger.Pow: el exponente no puede ser negativo");
            BigInteger result = One;
            BigInteger b = a;
            int e = exponent;
            while (e > 0)
            {
                if ((e & 1) != 0) result = result * b;
                e >>= 1;
                if (e > 0) b = b * b;
            }
            return result;
        }

        // (value^exponent) % modulus sin calcular la potencia completa. Como en .NET, el resultado
        // lleva el signo de value^exponent.
        [TrackCaller] public static func ModPow(value: BigInteger, exponent: BigInteger, modulus: BigInteger) -> BigInteger
        {
            if (exponent.sign < 0) throw new ArgumentOutOfRangeException("exponent", "BigInteger.ModPow: el exponente no puede ser negativo");
            if (modulus.sign == 0) throw new DivideByZeroException("BigInteger.ModPow: módulo cero");
            BigInteger m = Abs(modulus);
            BigInteger result = One % m;
            BigInteger b = Abs(value) % m;
            long bits = exponent.GetBitLength();
            for (long i = 0; i < bits; i++)
            {
                if ((exponent.mag[(int)(i / 32)] >> (int)(i % 32) & 1) != 0) result = result * b % m;
                if (i + 1 < bits) b = b * b % m;
            }
            if (value.sign < 0 && !exponent.IsEven) result = -result;
            return result;
        }

        // Máximo común divisor (siempre >= 0), con el algoritmo de Euclides.
        public static func GreatestCommonDivisor(a: BigInteger, b: BigInteger) -> BigInteger
        {
            BigInteger x = Abs(a);
            BigInteger y = Abs(b);
            while (!y.IsZero)
            {
                BigInteger t = x % y;
                x = y;
                y = t;
            }
            return x;
        }

        public static func Gcd(a: BigInteger, b: BigInteger) -> BigInteger => GreatestCommonDivisor(a, b);

        // Raíz cuadrada entera (la parte entera de √a), por el método de Newton.
        [TrackCaller] public static func Sqrt(a: BigInteger) -> BigInteger
        {
            if (a.sign < 0) throw new ArgumentOutOfRangeException("a", "BigInteger.Sqrt: el valor no puede ser negativo");
            if (a.sign == 0) return a;
            BigInteger x = One << (int)((a.GetBitLength() + 1) / 2);
            for (;;)
            {
                BigInteger y = (x + a / x) >> 1;
                if (y >= x) return x;
                x = y;
            }
        }
    }

    // ---------------------------------------------------------------- Decimal

    // Número decimal exacto de 128 bits (System.Decimal de .NET), para dinero y cantidades que
    // deben sumar exacto: Decimal.Parse("0.1") + Decimal.Parse("0.2") == Decimal.Parse("0.3").
    public memory_unsafe struct Decimal
    {
        var lo: uint;
        var mid: uint;
        var hi: uint;
        var flags: int;     // escala en los bits 16..23 y signo en el bit 31 (como en .NET)

        init(lo: uint, mid: uint, hi: uint, flags: int)
        {
            this.lo = lo;
            this.mid = mid;
            this.hi = hi;
            this.flags = flags;
        }

        public init(value: long)
        {
            ulong u = value < 0 ? (ulong)(-(value + 1)) + 1UL : (ulong)value;
            lo = (uint)(u & 0xFFFFFFFFUL);
            mid = (uint)(u >> 32);
            hi = 0;
            flags = value < 0 ? (int)0x80000000 : 0;
        }

        // unscaled · 10^-scale: new Decimal(1999, 2) es 19.99.
        public init(unscaled: long, scale: int)
        {
            if (scale < 0 || scale > 28) throw new ArgumentOutOfRangeException("scale", "Decimal: la escala debe estar entre 0 y 28");
            ulong u = unscaled < 0 ? (ulong)(-(unscaled + 1)) + 1UL : (ulong)unscaled;
            lo = (uint)(u & 0xFFFFFFFFUL);
            mid = (uint)(u >> 32);
            hi = 0;
            flags = (scale << 16) | (unscaled < 0 ? (int)0x80000000 : 0);
        }

        // Como el constructor de .NET: mantisa de 96 bits (lo, mid, hi), signo y escala.
        public init(lo: int, mid: int, hi: int, isNegative: bool, scale: byte)
        {
            if (scale > 28) throw new ArgumentOutOfRangeException("scale", "Decimal: la escala debe estar entre 0 y 28");
            this.lo = (uint)lo;
            this.mid = (uint)mid;
            this.hi = (uint)hi;
            flags = ((int)scale << 16) | (isNegative ? (int)0x80000000 : 0);
        }

        // Desde un double, con 15 cifras significativas (como .NET): new Decimal(0.1) es 0.1.
        public init(value: double)
        {
            uint a = 0;
            uint b = 0;
            uint c = 0;
            int f = 0;
            if (Num.faset_dec_from_double(value, &a, &b, &c, &f) != 0)
                throw new OverflowException("Decimal: el valor es demasiado grande o no es un número");
            lo = a;
            mid = b;
            hi = c;
            flags = f;
        }

        public static prop Zero: Decimal => new Decimal(0L);
        public static prop One: Decimal => new Decimal(1L);
        public static prop MinusOne: Decimal => new Decimal(-1L);
        // ±79 228 162 514 264 337 593 543 950 335
        public static prop MaxValue: Decimal => new Decimal(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0);
        public static prop MinValue: Decimal => new Decimal(0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, (int)0x80000000);

        // Cifras decimales (0..28): Decimal.Parse("1.50").Scale es 2.
        public prop Scale: int => (flags >> 16) & 0xFF;
        public prop IsNegative: bool => flags < 0 && !IsZero;
        public prop IsZero: bool => lo == 0 && mid == 0 && hi == 0;
        public prop Sign: int => IsZero ? 0 : (flags < 0 ? -1 : 1);

        // ---------------------------------------------------------------- texto

        // Lee "123.45", "-0.5", " +7 " o "1.5e3" (con '.' como separador). Las cifras que no
        // caben se redondean. Lanza FormatException u OverflowException.
        [TrackCaller] public static func Parse(s: string) -> Decimal
        {
            uint a = 0;
            uint b = 0;
            uint c = 0;
            int f = 0;
            int rc = Num.faset_dec_parse(s, &a, &b, &c, &f);
            if (rc == 3) throw new FormatException("Decimal.Parse: '" + s + "' no es un número");
            if (rc != 0) throw new OverflowException("Decimal.Parse: '" + s + "' es demasiado grande para un Decimal");
            return new Decimal(a, b, c, f);
        }

        public static func TryParse(s: string, out result: Decimal) -> bool
        {
            uint a = 0;
            uint b = 0;
            uint c = 0;
            int f = 0;
            int rc = Num.faset_dec_parse(s, &a, &b, &c, &f);
            result = rc == 0 ? new Decimal(a, b, c, f) : Zero;
            return rc == 0;
        }

        // Con todas sus cifras decimales: "19.90", "-3", "0.0001".
        public override func ToString() -> string
        {
            byte* p = Memory.AllocBytes(64);
            int n = Num.faset_dec_to_string(lo, mid, hi, flags, p);
            return String.FromBytes(p, n);
        }

        // Formatos de .NET (cultura invariante): "F2" (2 decimales), "N2" (además, separador de
        // miles ','), "F0", "N". Redondean alejándose de cero en los empates, como .NET.
        [TrackCaller] public func ToString(format: string) -> string
        {
            if (format.Length == 0 || format == "G" || format == "g") return ToString();
            char kind = (char)format[0];
            if (kind != 'F' && kind != 'f' && kind != 'N' && kind != 'n')
                throw new FormatException("Decimal.ToString: formato no admitido '" + format + "' (usa F, N o G)");
            int digits = 2;
            if (format.Length > 1)
            {
                digits = int.Parse(format.Substring(1));
                if (digits < 0 || digits > 28) throw new FormatException("Decimal.ToString: demasiados decimales en '" + format + "'");
            }
            Decimal r = Round(this, digits, MidpointRounding.AwayFromZero);
            string s = r.ToString();
            bool neg = s.StartsWith("-");
            if (neg) s = s.Substring(1);
            int dot = s.IndexOf(".");
            string ent = dot < 0 ? s : s.Substring(0, dot);
            string frac = dot < 0 ? "" : s.Substring(dot + 1);
            StringBuilder sb = new StringBuilder();
            if (neg) sb.Append('-');
            if (kind == 'N' || kind == 'n')
            {
                for (int i = 0; i < ent.Length; i++)
                {
                    if (i > 0 && (ent.Length - i) % 3 == 0) sb.Append(',');
                    sb.AppendByte(ent[i]);
                }
            }
            else sb.Append(ent);
            if (digits > 0)
            {
                sb.Append('.');
                sb.Append(frac);
                for (int i = frac.Length; i < digits; i++) sb.Append('0');
            }
            return sb.ToString();
        }

        // Mismo hash para 1.5 y 1.50 (son iguales).
        public func GetHashCode() -> int
        {
            Decimal n = Normalize(this);
            ulong h = ((ulong)n.hi << 40) ^ ((ulong)n.mid << 20) ^ n.lo ^ ((ulong)(uint)n.flags << 7);
            h = (h ^ (h >> 31)) * 0xBF58476D1CE4E5B9UL;
            return (int)(h ^ (h >> 32));
        }

        // ---------------------------------------------------------------- conversiones

        public func ToDouble() -> double => Num.faset_dec_to_double(lo, mid, hi, flags);

        // Parte entera (truncada hacia cero) como long; OverflowException si no cabe.
        [TrackCaller] public func ToInt64() -> long
        {
            Decimal t = Truncate(this);
            if (t.hi != 0 || (t.mid & 0x80000000) != 0)
            {
                if (t.flags < 0 && t.hi == 0 && t.mid == 0x80000000 && t.lo == 0) return -9223372036854775807L - 1;
                throw new OverflowException("Decimal: el valor no cabe en un long");
            }
            long v = (long)(((ulong)t.mid << 32) | t.lo);
            return t.flags < 0 ? -v : v;
        }

        [TrackCaller] public func ToInt32() -> int
        {
            long v = ToInt64();
            if (v < -2147483648L || v > 2147483647L) throw new OverflowException("Decimal: el valor no cabe en un int");
            return (int)v;
        }

        // ---------------------------------------------------------------- aritmética

        [TrackCaller] static func Op(op: int, a: Decimal, b: Decimal) -> Decimal
        {
            uint x = 0;
            uint y = 0;
            uint z = 0;
            int f = 0;
            int rc = Num.faset_dec_op(op, a.lo, a.mid, a.hi, a.flags, b.lo, b.mid, b.hi, b.flags, &x, &y, &z, &f);
            if (rc == 2) throw new DivideByZeroException("Decimal: división por cero");
            if (rc != 0) throw new OverflowException("Decimal: el resultado es demasiado grande para un Decimal");
            return new Decimal(x, y, z, f);
        }

        [TrackCaller] public operator +(a: Decimal, b: Decimal) -> Decimal => Op(0, a, b);
        [TrackCaller] public operator -(a: Decimal, b: Decimal) -> Decimal => Op(1, a, b);
        [TrackCaller] public operator *(a: Decimal, b: Decimal) -> Decimal => Op(2, a, b);
        // Cociente con hasta 28 decimales: 1 / 3 = 0.3333333333333333333333333333.
        [TrackCaller] public operator /(a: Decimal, b: Decimal) -> Decimal => Op(3, a, b);
        // Resto con el signo del dividendo: 7.5 % 2 = 1.5.
        [TrackCaller] public operator %(a: Decimal, b: Decimal) -> Decimal => Op(4, a, b);
        public operator -(a: Decimal) -> Decimal => new Decimal(a.lo, a.mid, a.hi, a.flags ^ (int)0x80000000);

        public static func Compare(a: Decimal, b: Decimal) -> int => Num.faset_dec_cmp(a.lo, a.mid, a.hi, a.flags, b.lo, b.mid, b.hi, b.flags);
        public func CompareTo(other: Decimal) -> int => Compare(this, other);
        public func Equals(other: Decimal) -> bool => Compare(this, other) == 0;

        public operator ==(a: Decimal, b: Decimal) -> bool => Compare(a, b) == 0;
        public operator <(a: Decimal, b: Decimal) -> bool => Compare(a, b) < 0;
        public operator >(a: Decimal, b: Decimal) -> bool => Compare(a, b) > 0;
        public operator <=(a: Decimal, b: Decimal) -> bool => Compare(a, b) <= 0;
        public operator >=(a: Decimal, b: Decimal) -> bool => Compare(a, b) >= 0;

        // Mezclados con long: precio * 3, total - 1.
        [TrackCaller] public operator +(a: Decimal, b: long) -> Decimal => Op(0, a, new Decimal(b));
        [TrackCaller] public operator +(a: long, b: Decimal) -> Decimal => Op(0, new Decimal(a), b);
        [TrackCaller] public operator -(a: Decimal, b: long) -> Decimal => Op(1, a, new Decimal(b));
        [TrackCaller] public operator -(a: long, b: Decimal) -> Decimal => Op(1, new Decimal(a), b);
        [TrackCaller] public operator *(a: Decimal, b: long) -> Decimal => Op(2, a, new Decimal(b));
        [TrackCaller] public operator *(a: long, b: Decimal) -> Decimal => Op(2, new Decimal(a), b);
        [TrackCaller] public operator /(a: Decimal, b: long) -> Decimal => Op(3, a, new Decimal(b));
        [TrackCaller] public operator /(a: long, b: Decimal) -> Decimal => Op(3, new Decimal(a), b);
        [TrackCaller] public operator %(a: Decimal, b: long) -> Decimal => Op(4, a, new Decimal(b));
        public operator ==(a: Decimal, b: long) -> bool => Compare(a, new Decimal(b)) == 0;
        public operator <(a: Decimal, b: long) -> bool => Compare(a, new Decimal(b)) < 0;
        public operator >(a: Decimal, b: long) -> bool => Compare(a, new Decimal(b)) > 0;
        public operator <=(a: Decimal, b: long) -> bool => Compare(a, new Decimal(b)) <= 0;
        public operator >=(a: Decimal, b: long) -> bool => Compare(a, new Decimal(b)) >= 0;

        [TrackCaller] public static func Add(a: Decimal, b: Decimal) -> Decimal => Op(0, a, b);
        [TrackCaller] public static func Subtract(a: Decimal, b: Decimal) -> Decimal => Op(1, a, b);
        [TrackCaller] public static func Multiply(a: Decimal, b: Decimal) -> Decimal => Op(2, a, b);
        [TrackCaller] public static func Divide(a: Decimal, b: Decimal) -> Decimal => Op(3, a, b);
        [TrackCaller] public static func Remainder(a: Decimal, b: Decimal) -> Decimal => Op(4, a, b);
        public static func Negate(a: Decimal) -> Decimal => -a;
        public static func Abs(a: Decimal) -> Decimal => a.flags < 0 ? -a : a;
        public static func Min(a: Decimal, b: Decimal) -> Decimal => a <= b ? a : b;
        public static func Max(a: Decimal, b: Decimal) -> Decimal => a >= b ? a : b;

        // ---------------------------------------------------------------- redondeo

        // Al entero más cercano; los empates al par (2.5 -> 2, 3.5 -> 4), como Math.Round de C#.
        public static func Round(d: Decimal) -> Decimal => Round(d, 0, MidpointRounding.ToEven);
        public static func Round(d: Decimal, mode: MidpointRounding) -> Decimal => Round(d, 0, mode);
        [TrackCaller] public static func Round(d: Decimal, decimals: int) -> Decimal => Round(d, decimals, MidpointRounding.ToEven);

        [TrackCaller] public static func Round(d: Decimal, decimals: int, mode: MidpointRounding) -> Decimal
        {
            if (decimals < 0 || decimals > 28) throw new ArgumentOutOfRangeException("decimals", "Decimal.Round: los decimales deben estar entre 0 y 28");
            uint x = 0;
            uint y = 0;
            uint z = 0;
            int f = 0;
            Num.faset_dec_round(d.lo, d.mid, d.hi, d.flags, decimals, (int)mode, &x, &y, &z, &f);
            return new Decimal(x, y, z, f);
        }

        public static func Truncate(d: Decimal) -> Decimal => Round(d, 0, MidpointRounding.ToZero);
        public static func Floor(d: Decimal) -> Decimal => Round(d, 0, MidpointRounding.ToNegativeInfinity);
        public static func Ceiling(d: Decimal) -> Decimal => Round(d, 0, MidpointRounding.ToPositiveInfinity);

        // Sin ceros finales: 1.500 -> 1.5, 2.00 -> 2.
        public static func Normalize(d: Decimal) -> Decimal
        {
            Decimal r = d;
            while (r.Scale > 0)
            {
                Decimal t = Round(r, r.Scale - 1, MidpointRounding.ToZero);
                if (t != r) break;
                r = t;
            }
            if (r.IsZero) return Zero;
            return r;
        }
    }
}
