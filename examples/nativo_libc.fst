using std;

// Interoperabilidad directa con C: cualquier función nativa se declara como
// 'static extern' y se llama sin envoltorios ni marshalling. Llamar a código nativo
// (y usar punteros como '.Ptr') exige un contexto 'memory_unsafe'.
static class LibC
{
    public static extern int printf(byte* format, ...);
    public static extern int abs(int x);
    public static extern void qsort(void* data, ulong count, ulong size, void* compare);
}

static class Program
{
    static void Main()
    {
        memory_unsafe
        {
            LibC.printf("printf nativo: %d + %d = %d\n".Ptr, 2, 3, 2 + 3);
            LibC.printf("double: %.3f, cadena: %s\n".Ptr, Math.PI, "Faset".Ptr);
            Console.WriteLine(LibC.abs(-42));
        }
    }
}
