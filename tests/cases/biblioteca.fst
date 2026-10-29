using std.io;
using std.time;
using std.random;
using std.math;
using std.mem;
using std.os;
using std.collections;

static class Program
{
    static void Main()
    {
        // io
        string ruta = "prueba_faset.txt";
        File.WriteAllText(ruta, "línea 1\n");
        File.AppendAllText(ruta, "línea 2\n");
        string contenido = File.ReadAllText(ruta);
        Console.Write(contenido);
        Console.WriteLine(File.Exists(ruta));
        String.Free(contenido);
        File.Delete(ruta);
        Console.WriteLine(File.Exists(ruta));
        string leido;
        Console.WriteLine(File.TryReadAllText("no_existe.txt", out leido));
        Console.WriteLine(Path.GetExtension("/home/u/foto.png"));
        Console.WriteLine(Path.GetFileNameWithoutExtension("C:\\docs\\informe.pdf"));
        string comb = Path.Combine("carpeta", "archivo.txt");
        Console.WriteLine(comb);
        String.Free(comb);

        // time
        Stopwatch sw = Stopwatch.StartNew();
        Time.Sleep(20);
        sw.Stop();
        Console.WriteLine(sw.ElapsedMs >= 15);
        Console.WriteLine(Time.NowUnixSeconds() > 1700000000);

        // random reproducible
        Random rng = new Random(42);
        int a = rng.Next(100), b = rng.Next(100);
        Random rng2 = new Random(42);
        Console.WriteLine(a == rng2.Next(100) && b == rng2.Next(100));
        double d = rng.NextDouble();
        Console.WriteLine(d >= 0 && d < 1);
        int* datos = new int[10];
        for (int i = 0; i < 10; i++) datos[i] = i;
        rng.Shuffle<int>(datos, 10);
        Algorithms.Sort<int>(datos, 10);
        Console.WriteLine(datos[9]);
        Console.WriteLine(Algorithms.BinarySearch<int>(datos, 10, 7));
        delete[] datos;

        // math
        Vec2 v = new Vec2(3, 4);
        Console.WriteLine(v.Length);
        Vec2 w = v * 2 + Vec2.One;
        Console.WriteLine(w.X);
        Console.WriteLine((-w).Y);
        Vec3 c = Vec3.Cross(new Vec3(1, 0, 0), new Vec3(0, 1, 0));
        Console.WriteLine(c.Z);
        Rect rc = new Rect(0, 0, 10, 10);
        Console.WriteLine(rc.Contains(new Vec2(5, 5)));
        Console.WriteLine(Interp.Remap(5, 0, 10, 100, 200));
        Console.WriteLine(Math.IsPrime(97));
        Console.WriteLine(Math.IPow(2, 40));

        // mem
        Arena arena = new Arena(1024);
        for (int i = 0; i < 1000; i++)
        {
            long* p = arena.New<long>();
            *p = i;
        }
        Console.WriteLine(arena.BytesUsed >= 16000);
        delete arena;
        int* buf = Memory.New<int>(5);
        Span<int> span = new Span<int>(buf, 5);
        span.Fill(7);
        span[2] = 9;
        Console.WriteLine(span.Slice(1, 3)[1]);
        Memory.Free(buf);
        Box<Vec2> caja = new Box<Vec2>(new Vec2(1, 2));
        caja.Value().Y = 20;
        Console.WriteLine(caja.Get()->Y);
        delete caja;

        // os
        Console.WriteLine(OS.Name());
        Console.WriteLine(OS.IsLinux);
        Console.WriteLine(Process.Run("exit 3") != 0);
    }
}
