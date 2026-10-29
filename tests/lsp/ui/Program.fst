using std.ui;

namespace PruebaUi
{
    public static class Program
    {
        public static int Main()
        {
            auto v = new Ventana();
            int code = Application.Run(v.Window);
            delete v;
            return code;
        }
    }
}
