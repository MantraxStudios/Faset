using std.ui;

namespace Galeria
{
    public static class Program
    {
        public static func Main() -> int
        {
            var window = new MainWindow();
            int code = Application.Run(window.Window);
            delete window;
            return code;
        }
    }
}
