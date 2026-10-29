using std;
public class Punto { public int X; int secreto; }
public static class Program
{
    static int Doble(int x) { if (x > 0) return x * 2; }
    public static void Main()
    {
        int a = 3.5;
        long l = 5;
        int b = l;
        string s = 42;
        Punto p = new Punto();
        p.secreto = 1;
        int* q = &a;
        q.X = 3;
        Desconocido(1);
        bool z = a;
        a + 1;
        var v = null;
        void* vp = q;
        int w = *vp;
        Console.WriteLine(Program);
        int a = 9;
    }
}
