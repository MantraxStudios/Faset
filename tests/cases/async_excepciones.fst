// async / await y excepciones: try/catch/finally alrededor de 'await' (los marcos de setjmp se
// restablecen al reanudar), excepciones antes y después de la suspensión, 'await' dentro de catch
// y finally, 'throw;' tras un 'await', return pendiente con un finally que espera, y excepciones
// guardadas en la tarea (IsFaulted, Exception, Result, Wait).
using std;
using std.task;

public static class Program
{
    static async Task Falla(int ms, string msg)
    {
        if (ms > 0) await Task.Delay(ms);
        throw new InvalidOperationException(msg);
    }

    static async Task<int> Valor(int v)
    {
        await Task.Delay(1);
        return v;
    }

    static async Task<int> ConFinally()
    {
        try
        {
            await Task.Delay(1);
            return 42;  // el return espera a que termine el finally (que también espera)
        }
        finally
        {
            await Task.Delay(1);
            Console.WriteLine("  finally de ConFinally");
        }
    }

    static async Task<string> Bucle()
    {
        string s = "";
        for (int i = 0; i < 4; i++)
        {
            try
            {
                await Task.Delay(1);
                if (i % 2 == 1) throw new FormatException("impar " + i);
                s += "ok" + i + " ";
            }
            catch (FormatException e)
            {
                s += "[" + e.Message + "] ";
                if (i == 3) break;  // sale del bucle a través del try
                continue;
            }
            finally
            {
                s += "f" + i + " ";
            }
        }
        return s;
    }

    static async Task Main()
    {
        Console.WriteLine("1) excepción después de varios await");
        try
        {
            Console.WriteLine("  try: antes");
            await Task.Delay(2);
            Console.WriteLine("  try: tras el primer await");
            int v = await Valor(5);
            await Falla(2, "fallo " + v);
            Console.WriteLine("  no se ve");
        }
        catch (InvalidOperationException e)
        {
            Console.WriteLine("  catch: " + e.Message);
            await Task.Delay(1);
            Console.WriteLine("  catch: tras await");
        }
        finally
        {
            Console.WriteLine("  finally: antes");
            await Task.Delay(1);
            Console.WriteLine("  finally: después");
        }

        Console.WriteLine("2) excepción antes del primer await (sin suspender)");
        try
        {
            await Falla(0, "inmediata");
        }
        catch (Exception e)
        {
            Console.WriteLine("  catch: " + e.Message);
        }

        Console.WriteLine("3) return pendiente y finally con await");
        Console.WriteLine("  resultado " + await ConFinally());

        Console.WriteLine("4) try anidados");
        try
        {
            try
            {
                await Task.Delay(1);
                throw new FormatException("interna");
            }
            finally
            {
                Console.WriteLine("  finally interno");
                await Task.Delay(1);
                Console.WriteLine("  finally interno tras await");
            }
        }
        catch (FormatException e)
        {
            Console.WriteLine("  externo: " + e.Message);
        }

        Console.WriteLine("5) throw; tras un await en el catch");
        try
        {
            try
            {
                await Falla(1, "relanzada");
            }
            catch (Exception e)
            {
                await Task.Delay(1);
                Console.WriteLine("  catch: " + e.Message);
                throw;
            }
        }
        catch (InvalidOperationException e2)
        {
            Console.WriteLine("  arriba: " + e2.Message + " (" + e2.TypeName + ")");
        }

        Console.WriteLine("6) break/continue a través de try con await");
        Console.WriteLine("  " + await Bucle());

        Console.WriteLine("7) la excepción queda en la tarea");
        Task t = Falla(1, "guardada");
        try
        {
            t.Wait();
        }
        catch (InvalidOperationException e)
        {
            Console.WriteLine("  Wait: " + e.Message);
        }
        Console.WriteLine("  IsFaulted " + t.IsFaulted + ", IsCompleted " + t.IsCompleted + ", Exception " + t.Exception.Message);
        Task<int> r = Task.Run(() =>
        {
            int cero = 0;
            return 10 / cero;
        });
        try
        {
            Console.WriteLine(r.Result);
        }
        catch (DivideByZeroException e)
        {
            Console.WriteLine("  Result: " + e.TypeName);
        }
        try
        {
            await Task.Run(() => { throw new FormatException("en Task.Run"); });
        }
        catch (FormatException e)
        {
            Console.WriteLine("  await Task.Run: " + e.Message);
        }
        Console.WriteLine("fin");
    }
}
