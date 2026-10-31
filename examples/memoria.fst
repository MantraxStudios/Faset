using std;

namespace Demo
{
    public enum Color { Rojo, Verde = 5, Azul }

    public struct Vec2
    {
        public var X: double;
        public var Y: double;

        public init(x: double, y: double) { X = x; Y = y; }

        public func Length() -> double => Math.Sqrt(X * X + Y * Y);
        public func Add(o: Vec2) -> Vec2 { return new Vec2(X + o.X, Y + o.Y); }
        public func Scale(k: double) { X *= k; Y *= k; }
    }

    // Lista enlazada con gestión manual de memoria (como en C++).
    public class Node
    {
        public var Value: int;
        public var Next: Node;
        public init(v: int) { Value = v; }
    }

    public class IntList
    {
        var head: Node;
        var count: int = 0;
        public static var Destroyed: int = 0;

        public func Push(v: int)
        {
            Node n = new Node(v);
            n.Next = head;
            head = n;
            count++;
        }

        public func Count() -> int { return count; }

        public func Sum() -> int
        {
            int s = 0;
            for (Node n = head; n != null; n = n.Next) s += n.Value;
            return s;
        }

        deinit
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
        // Recibe punteros: el método entero es 'memory_unsafe' y solo se puede
        // llamar desde un contexto memory_unsafe.
        memory_unsafe static void Swap(int* a, int* b)
        {
            int t = *a;
            *a = *b;
            *b = t;
        }

        static func Name(c: Color) -> string
        {
            switch (c)
            {
                case Color.Rojo: return "rojo";
                case Color.Verde: return "verde";
                default: return "otro";
            }
        }

        public static func Main() -> int
        {
            // Punteros y dirección de variables: solo dentro de 'memory_unsafe'.
            int x = 1, y = 2;
            memory_unsafe { Swap(&x, &y); }
            Console.Write("swap: "); Console.Write(x); Console.Write(" "); Console.WriteLine(y);

            // Arreglos en el heap con aritmética de punteros
            int n = 10;
            memory_unsafe
            {
                long* nums = new long[n];
                for (int i = 0; i < n; i++) nums[i] = (long)i * i;
                long total = 0;
                for (long* p = nums; p < nums + n; p++) total += *p;
                Console.Write("suma de cuadrados: "); Console.WriteLine(total);
                delete[] nums;
            }

            // Structs (valor) y punteros a structs
            Vec2 v = new Vec2(3, 4);
            Console.Write("|v| = "); Console.WriteLine(v.Length());
            memory_unsafe
            {
                Vec2* pv = &v;
                pv->Scale(2);
                Console.Write("v escalado: "); Console.Write(v.X); Console.Write(", "); Console.WriteLine(pv->Y);
            }
            Console.Write("suma temporal: "); Console.WriteLine(v.Add(new Vec2(1, 1)).Length());
            memory_unsafe
            {
                Vec2* heapVec = (Vec2*)Memory.AllocZeroed(sizeof(Vec2));
                heapVec->X = 1.5;
                Console.Write("vec en heap: "); Console.WriteLine(heapVec->X);
                Memory.Free(heapVec);
            }

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
