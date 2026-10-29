using std;

// Aplicación de Windows con la API Win32 (MessageBoxA usa la página de códigos ANSI). Compilar con:
//   faset build examples/ventana_windows.fst --target windows --gui -l user32
static class User32
{
    public const uint MB_OK = 0;
    public const uint MB_ICONINFORMATION = 0x40;

    public static extern int MessageBoxA(void* owner, byte* text, byte* caption, uint type);
}

static class Program
{
    static void Main()
    {
        memory_unsafe { User32.MessageBoxA(null, "Hola desde Faset!".Ptr, "Faset".Ptr, User32.MB_OK | User32.MB_ICONINFORMATION); }
    }
}
