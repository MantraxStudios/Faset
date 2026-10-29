using std.ui;

namespace HolaUI
{
    public static class Program
    {
        public static int Main()
        {
            auto window = new MainWindow();
            int code = Application.Run(window.Window);
            delete window;
            return code;
        }
    }
}
