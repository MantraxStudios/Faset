// Proyecto de ejemplo para 'faset test' (tests/run.sh): tests/CalcTests.fst no entra en 'faset build'.
using std;

namespace Calc
{
    public static class Ops
    {
        public static int Suma(int a, int b) => a + b;
        public static int Divide(int a, int b) => a / b;
        public static double Raiz(double x) => Math.Sqrt(x);
    }

    public class Program
    {
        public static void Main() { println(Ops.Suma(2, 3)); }
    }
}
