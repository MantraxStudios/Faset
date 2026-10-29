// async / await con lambdas y el resto del lenguaje: lambdas async (con y sin resultado, con
// capturas compartidas), métodos virtuales y genéricos async, bucles (for, while con await en la
// condición, foreach), && / || / ?: con await, interpolación, switch, patrones y 'using'.
using std;
using std.collections;
using std.task;

class Cuenta
{
    public int Saldo;
    public virtual async Task<int> Ingresar(int n)
    {
        await Task.Delay(1);
        Saldo += n;
        return Saldo;
    }
}

class CuentaDoble : Cuenta
{
    public override async Task<int> Ingresar(int n)
    {
        int r = await base.Ingresar(n * 2);
        return r + 1000;
    }
}

class Recurso
{
    public string Nombre;
    public Recurso(string n) { Nombre = n; }
    ~Recurso() { Console.WriteLine("  liberado " + Nombre); }
}

public static class Program
{
    static async Task<T> Eco<T>(T x)
    {
        await Task.Yield();
        return x;
    }

    static async Task<bool> Si(bool v)
    {
        await Task.Delay(1);
        return v;
    }

    static async Task Main()
    {
        Console.WriteLine("1) lambdas async y capturas");
        int capturada = 1;
        Func<int, Task<int>> f = async n =>
        {
            await Task.Delay(1);
            capturada += n;  // la misma variable que ve el método (captura por referencia)
            return capturada * 10;
        };
        Console.WriteLine("  f(4) = " + await f(4) + ", capturada = " + capturada);
        Func<Task> g = async () => await Task.Delay(1);
        await g();
        Func<Task<string>> h = async () => "expresión " + await Eco(5);
        Console.WriteLine("  " + await h());
        var fs = new List<Func<Task<int>>>();
        for (int i = 0; i < 3; i++)
        {
            int copia = i;
            fs.Add(async () =>
            {
                await Task.Delay(3 - copia);
                return copia * copia;
            });
        }
        int suma = 0;
        foreach (var fn in fs) suma += await fn();
        Console.WriteLine("  suma = " + suma);
        Action<int> sumar = x => capturada += x;
        sumar(100);
        Console.WriteLine("  capturada = " + capturada);

        Console.WriteLine("2) virtuales y genéricos");
        Cuenta c = new CuentaDoble();
        Console.WriteLine("  override = " + await c.Ingresar(5));
        Console.WriteLine("  genérico = " + await Eco("hola") + " " + await Eco(2.5));

        Console.WriteLine("3) bucles");
        int total = 0;
        for (int i = 0; i < 5; i++) total += await Eco(i);
        int k = 0;
        while (await Si(k < 3)) k++;
        var lista = new List<int>();
        lista.Add(10);
        lista.Add(20);
        foreach (var x in lista)
        {
            await Task.Delay(1);
            total += x;
        }
        int d = 0;
        do
        {
            d += await Eco(2);
        } while (d < 6);
        Console.WriteLine("  total = " + total + ", k = " + k + ", d = " + d);

        Console.WriteLine("4) expresiones");
        bool b1 = k > 100 && await Si(true);   // no se espera: && no evalúa la derecha
        bool b2 = k == 3 || await Si(false);
        bool b3 = k == 3 && await Si(true);
        string cond = k == 3 ? await Eco("tres") : await Eco("otro");
        Console.WriteLine("  " + b1 + " " + b2 + " " + b3 + " " + cond);
        Console.WriteLine($"  interpolación {await Eco(7)} y {await Eco("x")}");
        string s = await Eco("abc");
        Cuenta nula = null;
        Console.WriteLine("  longitud " + (await Eco(s)).Length + ", ?? " + (await Eco(nula) ?? c).Saldo + ", ?. " + (await Eco(c))?.Saldo);

        Console.WriteLine("5) switch, patrones y using");
        switch (await Eco(2))
        {
            case 1:
                Console.WriteLine("  uno");
                break;
            case 2:
                await Task.Delay(1);
                Console.WriteLine("  dos");
                break;
        }
        Cuenta o = c;
        if (o is CuentaDoble cd)
        {
            await Task.Delay(1);
            Console.WriteLine("  patrón: saldo " + cd.Saldo);
        }
        string texto = await Eco(3) switch { 1 => "uno", 3 => "tres", _ => "otro" };
        Console.WriteLine("  switch de expresión: " + texto);
        {
            using var r = new Recurso("A");
            await Task.Delay(1);
            Console.WriteLine("  usando " + r.Nombre);
        }
        Console.WriteLine("fin");
    }
}
