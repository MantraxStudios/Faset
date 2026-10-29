using std;

namespace Demo
{
    public enum Color { Rojo, Verde = 5, Azul }

    public struct Vec2
    {
        public double X;
        public double Y;

        public Vec2(double x, double y) { X = x; Y = y; }

        public double Length() => Math.Sqrt(X * X + Y * Y);
        public Vec2 Add(Vec2 o) { return new Vec2(X + o.X, Y + o.Y); }
        public void Scale(double k) { X *= k; Y *= k; }
    }

    // Lista enlazada con gestión manual de memoria (como en C++).
    public class Node
    {
        public int Value;
        public Node Next;
        public Node(int v) { Value = v; }
    }

    public class IntList
    {
        Node head;
        int count = 0;
        public static int Destroyed = 0;

        public void Push(int v)
        {
            Node n = new Node(v);
            n.Next = head;
            head = n;
            count++;
        }

        public int Count() { return count; }

        public int Sum()
        {
            int s = 0;
            for (Node n = head; n != null; n = n.Next) s += n.Value;
            return s;
        }

        ~IntList()
        {
            Node n = head;
            while (n != null)
            {
                Node next = n.Next;
                delete n;
                Destroyed++;
                n = next;
            }
        }
    }

    public static class Program
    {
        static void Swap(int* a, int* b)
        {
            int t = *a;
            *a = *b;
            *b = t;
        }

        static string Name(Color c)
        {
            switch (c)
            {
                case Color.Rojo: return "rojo";
                case Color.Verde: return "verde";
                default: return "otro";
            }
        }

        public static int Main()
        {
            // Punteros y dirección de variables
            int x = 1, y = 2;
            Swap(&x, &y);
            Console.Write("swap: "); Console.Write(x); Console.Write(" "); Console.WriteLine(y);

            // Arreglos en el heap con aritmética de punteros
            int n = 10;
            long* nums = new long[n];
            for (int i = 0; i < n; i++) nums[i] = (long)i * i;
            long total = 0;
            for (long* p = nums; p < nums + n; p++) total += *p;
            Console.Write("suma de cuadrados: "); Console.WriteLine(total);
            delete[] nums;

            // Structs (valor) y punteros a structs
            Vec2 v = new Vec2(3, 4);
            Console.Write("|v| = "); Console.WriteLine(v.Length());
            Vec2* pv = &v;
            pv->Scale(2);
            Console.Write("v escalado: "); Console.Write(v.X); Console.Write(", "); Console.WriteLine(pv->Y);
            Console.Write("suma temporal: "); Console.WriteLine(v.Add(new Vec2(1, 1)).Length());
            Vec2* heapVec = (Vec2*)Memory.AllocZeroed(sizeof(Vec2));
            heapVec->X = 1.5;
            Console.Write("vec en heap: "); Console.WriteLine(heapVec->X);
            Memory.Free(heapVec);

            // Clases (referencias) con destructor
            IntList list = new IntList();
            for (int i = 1; i <= 100; i++) list.Push(i);
            Console.Write("lista: "); Console.Write(list.Count()); Console.Write(" elementos, suma "); Console.WriteLine(list.Sum());
            delete list;
            Console.Write("nodos liberados: "); Console.WriteLine(IntList.Destroyed);

            // Enums y switch
            Color c = Color.Azul;
            Console.Write("Azul = "); Console.WriteLine((int)c);
            Console.WriteLine(Name(Color.Verde));
            Console.WriteLine(Name(c));

            // Cadenas
            string s = "Faset";
            string t = String.Concat(s, " es nativo");
            Console.WriteLine(t);
            Console.Write("longitud: "); Console.WriteLine(t.Length);
            Console.WriteLine(s == "Faset");
            String.Free(t);

            // Conversiones y tipos sin signo
            byte bt = 250;
            bt += 10;
            Console.Write("byte desbordado: "); Console.WriteLine(bt);
            uint u = 3000000000;
            Console.WriteLine(u + 1);
            Console.WriteLine(sizeof(Vec2));
            Console.WriteLine(Environment.CurrentPlatform() == Platform.Linux);
            return 0;
        }
    }
}
