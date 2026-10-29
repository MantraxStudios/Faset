// Prueba de VideoPlayer sin pantalla (la ejecuta tests/run.sh si GStreamer puede decodificar H.264).
// clip.mp4 dura 1,5 s: rojo (0-0,5 s), verde (0,5-1 s) y azul (1-1,5 s), 64x36 con sonido.
// Uso: FASET_UI_SCREENSHOT=x.bmp FASET_UI_SCRIPT="click 160 95 | wait 750" ./prueba
using std;
using std.ui;

public partial class MainWindow
{
    public bool Opened;
    public bool Ended;

    public MainWindow() { InitializeComponent(); }

    void OnOpened(Widget sender) { Opened = true; }
    void OnEnded(Widget sender) { Ended = true; }
    void OnFailed(Widget sender) { Console.WriteLine("error: " + Video.Error); }

    public void Report()
    {
        Console.WriteLine("abierto: " + Convert.ToString(Opened));
        Console.WriteLine("tamaño: " + String.FromInt(Video.NaturalWidth) + "x" + String.FromInt(Video.NaturalHeight));
        Console.WriteLine("reproduciendo: " + Convert.ToString(Video.IsPlaying));
        Console.WriteLine("terminado: " + Convert.ToString(Ended));
        Console.WriteLine("color: " + ColorAt(40, 40));
    }

    // Color dominante de un píxel del lienzo.
    public string ColorAt(int x, int y)
    {
        uint c = 0;
        memory_unsafe { c = Window.Canvas.Pixels[y * Window.Canvas.Width + x]; }
        uint r = (c >> 16) & 0xff, g = (c >> 8) & 0xff, b = c & 0xff;
        if (r > 180 && g < 80 && b < 80) return "rojo";
        if (g > 180 && r < 80 && b < 80) return "verde";
        if (b > 180 && r < 80 && g < 80) return "azul";
        return "otro";
    }
}

public static class Program
{
    public static int Main()
    {
        auto w = new MainWindow();
        int code = Application.Run(w.Window);
        w.Report();
        return code;
    }
}
