using std.ui;

namespace Controles
{
    public static class Program
    {
        public static func Main() -> int
        {
            var main = new MainWindow();
            return Application.Run(main.Window);
        }
    }
}
