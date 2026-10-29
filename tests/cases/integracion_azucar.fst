using std.collections;

int main()
{
    var nums = new List<int>();
    for (int i = 1; i <= 4; i++) nums.Add(i);

    // foreach + lambdas: cada vuelta captura su propia variable
    var fs = new List<Func<int>>();
    foreach (var n in nums) fs.Add(() => n * 10);
    foreach (var f in fs) Console.Write($"{f()} ");
    println("");

    // break dentro de foreach que cruza un finally
    foreach (var n in nums)
    {
        try
        {
            if (n == 3) break;
            println($"vuelta {n}");
        }
        finally { println($"finally {n}"); }
    }

    // continue + excepciones dentro de foreach
    int suma = 0;
    foreach (var n in nums)
    {
        try { if (n % 2 == 0) throw new Exception("par"); suma += n; }
        catch (Exception e) { continue; }
    }
    println($"suma impares = {suma}");

    // ?. sobre delegado nulo y no nulo, ?? y T?
    Func<int, int> doble = null;
    int? r = doble?.Invoke(4);
    println($"r = {r ?? -1}");
    doble = x => x * 2;
    println($"r = {doble?.Invoke(4) ?? -1}");

    // tuplas desde lambdas y switch de expresión
    Func<int, (int, string)> clasif = x => (x, x switch { < 2 => "poco", 2 or 3 => "medio", _ => "mucho" });
    foreach (var n in nums) { var (v, t) = clasif(n); Console.Write($"{v}:{t} "); }
    println("");

    // LINQ + interpolación con formato
    double prom = nums.Where(x => x > 1).Average(x => (double)x);
    println($"promedio {prom:F2}");
    return 0;
}
