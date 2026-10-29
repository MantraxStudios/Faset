using std.ui;

namespace Controles
{
    public static class Program
    {
        public static int Main()
        {
            auto main = new MainWindow();
            return Application.Run(main.Window);
        }
    }
}
