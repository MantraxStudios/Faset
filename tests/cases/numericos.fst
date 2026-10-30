// std.numerics: BigInteger (aritmética, Karatsuba frente a la multiplicación clásica, división,
// ModPow, Gcd, Sqrt, texto) y Decimal (escala, redondeo al par, división, formatos, errores).
using std.numerics;
using std.collections;

void Comprobar(string nombre, string obtenido, string esperado)
{
    println((obtenido == esperado ? "ok    " : "FALLO ") + nombre + (obtenido == esperado ? "" : " -> " + obtenido + " (se esperaba " + esperado + ")"));
}

BigInteger B(string s) => BigInteger.Parse(s);
Decimal D(string s) => Decimal.Parse(s);

BigInteger Factorial(int n)
{
    BigInteger f = BigInteger.One;
    for (int i = 2; i <= n; i++) f = f * i;
    return f;
}

void main()
{
    // ---------------------------------------------------------------- BigInteger
    Comprobar("30!", Factorial(30).ToString(), "265252859812191058636308480000000");
    Comprobar("2^200", BigInteger.Pow(new BigInteger(2), 200).ToString(),
              "1606938044258990275541962092341162602522202993782792835301376");
    Comprobar("suma con acarreo", (B("18446744073709551615") + 1).ToString(), "18446744073709551616");
    Comprobar("resta negativa", (B("100") - B("1000000000000000000000")).ToString(), "-999999999999999999900");
    Comprobar("producto de signos", (B("-12345678901234567890") * B("98765432109876543210")).ToString(),
              "-1219326311370217952237463801111263526900");
    Comprobar("long.MinValue", new BigInteger(-9223372036854775807L - 1).ToString(), "-9223372036854775808");
    Comprobar("ToInt64", $"{B("-9223372036854775808").ToInt64()}", "-9223372036854775808");
    try { B("9223372036854775808").ToInt64(); println("sin error"); }
    catch (OverflowException e) { println("OverflowException: " + e.Message); }

    // División truncada y resto con el signo del dividendo (como C#).
    Comprobar("7 / -2", (new BigInteger(7) / -2).ToString(), "-3");
    Comprobar("-7 % 2", (new BigInteger(-7) % 2).ToString(), "-1");
    BigInteger num = B("123456789012345678901234567890123456789");
    BigInteger den = B("987654321987654321");
    BigInteger resto;
    BigInteger coc = BigInteger.DivRem(num, den, out resto);
    Comprobar("DivRem", coc.ToString() + " " + resto.ToString(), "124999998748437501153 142745764920524676");
    Comprobar("q*d+r", (coc * den + resto).ToString(), num.ToString());
    try { BigInteger q0 = B("5") / BigInteger.Zero; }
    catch (DivideByZeroException e) { println("DivideByZeroException"); }

    // Karatsuba (números de miles de cifras) frente a la propiedad (a*b)/b == a y (a*b)%b == 0.
    BigInteger a = BigInteger.Pow(B("3"), 20000) - 1;      // ~9543 cifras
    BigInteger b = BigInteger.Pow(B("7"), 15000) + 12345;  // ~12677 cifras
    BigInteger ab = a * b;
    println((ab / b == a) && (ab % b).IsZero && (ab / a == b));
    Comprobar("cifras de a*b", $"{ab.ToString().Length}", $"{a.ToString().Length + b.ToString().Length - 1}");
    string sab = ab.ToString();
    int suma = 0;
    for (int i = 0; i < sab.Length; i++) suma += sab[i] - '0';
    Comprobar("a*b (Python)", sab.Substring(0, 30) + " " + sab.Substring(sab.Length - 30) + " " + suma,
              "786492539041685147061582247479 915315627648212654426922400000 99506");
    Comprobar("Parse(ToString)", (BigInteger.Parse(ab.ToString()) == ab) ? "sí" : "no", "sí");
    // (x+1)^2 = x^2 + 2x + 1 con números grandes.
    BigInteger x = BigInteger.Pow(B("10"), 3000) + 7;
    Comprobar("cuadrado", ((x + 1) * (x + 1) == x * x + 2 * x + 1) ? "sí" : "no", "sí");

    // ModPow y Gcd
    BigInteger p = B("170141183460469231731687303715884105727");   // 2^127 - 1, primo de Mersenne
    Comprobar("Fermat", BigInteger.ModPow(new BigInteger(3), p - 1, p).ToString(), "1");
    Comprobar("ModPow", BigInteger.ModPow(new BigInteger(4), new BigInteger(13), new BigInteger(497)).ToString(), "445");
    Comprobar("ModPow negativo", BigInteger.ModPow(new BigInteger(-2), new BigInteger(3), new BigInteger(5)).ToString(), "-3");
    Comprobar("Gcd", BigInteger.Gcd(Factorial(20), BigInteger.Pow(new BigInteger(6), 30)).ToString(), "1719926784");
    Comprobar("Gcd(0, -5)", BigInteger.GreatestCommonDivisor(BigInteger.Zero, new BigInteger(-5)).ToString(), "5");
    Comprobar("Sqrt", BigInteger.Sqrt(BigInteger.Pow(B("10"), 100) * 2).ToString(),
              "141421356237309504880168872420969807856967187537694");

    // Comparaciones, desplazamientos y otros
    println($"{B("-5") < B("3")} {B("10") >= 10} {B("-100") > -99} {B("42") == 42}");
    Comprobar("<<", (B("1") << 100).ToString(), "1267650600228229401496703205376");
    Comprobar(">>", (B("1267650600228229401496703205377") >> 99).ToString(), "2");
    Comprobar("-7 >> 1", (new BigInteger(-7) >> 1).ToString(), "-4");
    Comprobar("hex", B("-255").ToHexString() + " " + (B("1") << 64).ToHexString(), "-ff 10000000000000000");
    println($"{B("1024").IsPowerOfTwo} {B("1000").IsPowerOfTwo} {B("1024").GetBitLength()} {B("-3").Sign} {BigInteger.Zero.Sign}");
    println($"{B("12345678901234567890").ToDouble()}");
    println(B("  +00042 ").ToString());
    BigInteger nada;
    println($"{BigInteger.TryParse("12a", out nada)} {BigInteger.TryParse("", out nada)} {BigInteger.TryParse("-", out nada)}");
    BigInteger porDefecto;
    println($"{porDefecto} {porDefecto.IsZero} {porDefecto + 5}");
    List<BigInteger> lista = new List<BigInteger>();
    lista.Add(B("30")); lista.Add(B("-2")); lista.Add(B("100000000000000000000")); lista.Add(B("7"));
    lista.Sort();
    println($"{lista[0]} {lista[1]} {lista[2]} {lista[3]}");

    // ---------------------------------------------------------------- Decimal
    Comprobar("0.1 + 0.2", (D("0.1") + D("0.2")).ToString(), "0.3");
    println(D("0.1") + D("0.2") == D("0.3"));
    Comprobar("escala", (D("1.50") + D("1.50")).ToString(), "3.00");
    Comprobar("producto", (D("19.99") * 3).ToString(), "59.97");
    Comprobar("producto de escalas", (D("1.25") * D("0.2")).ToString(), "0.250");
    Comprobar("1/3", (D("1") / 3).ToString(), "0.3333333333333333333333333333");
    Comprobar("2/3", (D("2") / 3).ToString(), "0.6666666666666666666666666667");
    Comprobar("10/4", (D("10") / 4).ToString(), "2.5");
    Comprobar("1/8", (D("1") / 8).ToString(), "0.125");
    Comprobar("4.00/2", (D("4.00") / 2).ToString(), "2.00");
    Comprobar("1/0.5", (D("1") / D("0.5")).ToString(), "2");
    Comprobar("100/3", (D("100") / 3).ToString(), "33.333333333333333333333333333");
    Comprobar("resto", (D("7.5") % 2).ToString() + " " + (D("-7.5") % 2).ToString(), "1.5 -1.5");
    Comprobar("MaxValue", Decimal.MaxValue.ToString(), "79228162514264337593543950335");
    Comprobar("MinValue", Decimal.MinValue.ToString(), "-79228162514264337593543950335");
    try { Decimal m0 = Decimal.MaxValue + 1; println("sin error"); }
    catch (OverflowException e) { println("OverflowException: " + e.Message); }
    try { Decimal m1 = D("1") / Decimal.Zero; }
    catch (DivideByZeroException e) { println("DivideByZeroException: " + e.Message); }
    // Muchas cifras: se redondea a lo que cabe (al par).
    Comprobar("Parse largo", D("1.23456789012345678901234567890123").ToString(), "1.2345678901234567890123456789");
    Comprobar("Parse empate al par", D("0.00000000000000000000000000025").ToString(), "0.0000000000000000000000000002");
    Comprobar("Parse empate con resto", D("0.000000000000000000000000000250001").ToString(), "0.0000000000000000000000000003");
    Comprobar("Parse exponente", D("1.5e3").ToString() + " " + D("-25e-2").ToString(), "1500 -0.25");
    Comprobar("Parse 28 decimales", (D("0.0000000000000000000000000001") * D("0.1")).ToString(), "0.0000000000000000000000000000");
    try { D("1,5"); } catch (FormatException e) { println("FormatException: " + e.Message); }
    try { D("1e30"); } catch (OverflowException e) { println("OverflowException: " + e.Message); }
    Decimal dd;
    println($"{Decimal.TryParse("abc", out dd)} {Decimal.TryParse(" -3.25 ", out dd)} {dd}");

    // Redondeo
    Comprobar("Round al par", $"{Decimal.Round(D("2.5"))} {Decimal.Round(D("3.5"))} {Decimal.Round(D("-2.5"))}", "2 4 -2");
    Comprobar("Round(2.345, 2)", Decimal.Round(D("2.345"), 2).ToString(), "2.34");
    Comprobar("Round(2.355, 2)", Decimal.Round(D("2.355"), 2).ToString(), "2.36");
    Comprobar("AwayFromZero", Decimal.Round(D("2.345"), 2, MidpointRounding.AwayFromZero).ToString(), "2.35");
    Comprobar("Floor/Ceiling/Truncate", $"{Decimal.Floor(D("-2.1"))} {Decimal.Ceiling(D("-2.1"))} {Decimal.Truncate(D("-2.9"))} {Decimal.Floor(D("2.9"))}",
              "-3 -2 -2 2");
    Comprobar("Normalize", Decimal.Normalize(D("1.500")).ToString() + " " + Decimal.Normalize(D("0.000")).ToString(), "1.5 0");

    // Formatos y conversiones
    Comprobar("F2", D("1234.5").ToString("F2") + " " + D("2.345").ToString("F2") + " " + D("-0.004").ToString("F2"), "1234.50 2.35 0.00");
    Comprobar("N2", D("1234567.891").ToString("N2") + " " + D("-999.5").ToString("N0"), "1,234,567.89 -1,000");
    Comprobar("double", new Decimal(0.1).ToString() + " " + new Decimal(1.0 / 3.0).ToString() + " " + new Decimal(-12.5).ToString(),
              "0.1 0.333333333333333 -12.5");
    println(D("2.75").ToDouble());
    println($"{D("-2.75").ToInt64()} {D("99.99").ToInt32()}");
    println($"{D("1.0") == D("1.00")} {D("1.0").GetHashCode() == D("1.00").GetHashCode()} {D("-0.5") < Decimal.Zero} {D("0.5") > 0}");
    println($"{new Decimal(1999, 2)} {new Decimal(-5L)} {Decimal.Zero.Sign} {D("-1.5").Sign} {D("1.50").Scale}");
    Decimal ceroPorDefecto;
    println($"{ceroPorDefecto} {ceroPorDefecto + D("1.5")}");

    // Un importe sumado mil veces: exacto (con double no lo sería).
    Decimal total = Decimal.Zero;
    double totalD = 0;
    for (int i = 0; i < 1000; i++)
    {
        total = total + D("0.10");
        totalD += 0.1;
    }
    println($"{total} {totalD == 100.0}");
}
