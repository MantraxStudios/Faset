// VideoPlayer: lo que no depende de los códecs instalados (formato de tiempo, valores por
// defecto, errores al abrir y dibujo del marcador sin vídeo).
using std;
using std.ui;
using std.video;
using std.os;

public static class Program
{
    public static int Main()
    {
        Console.WriteLine(VideoTime.Format(0));
        Console.WriteLine(VideoTime.Format(65.9));
        Console.WriteLine(VideoTime.Format(3723));
        Console.WriteLine(VideoTime.Format(-4));

        auto v = VideoPlayer.Create("video", 10, 10, 200, 120);
        Console.WriteLine(v.View.Kind == WidgetKind.VideoPlayer && v.View.Player == v ? "control enlazado" : "mal");
        Console.WriteLine(v.Stretch == VideoStretch.Uniform && v.ShowControls && !v.Loop ? "por defecto ok" : "mal");
        v.Volume = 3;
        Console.WriteLine("volumen: " + String.FromDouble(v.Volume));
        v.Volume = -1;
        Console.WriteLine("volumen: " + String.FromDouble(v.Volume));
        Console.WriteLine("duración sin vídeo: " + String.FromDouble(v.Duration));
        v.Play();  // sin Source no hace nada
        Console.WriteLine("reproduciendo: " + Convert.ToString(v.IsPlaying));

        // Un archivo que no existe termina en Failed (con o sin GStreamer instalado).
        v.Source = "no_existe_video_faset.mp4";
        long end = Environment.TickCount64() + 5000;
        while (!v.HasFailed && Environment.TickCount64() < end)
        {
            VideoPlayer.Tick();
            EventWait.WaitFd(-1, 10);
        }
        Console.WriteLine("falló: " + Convert.ToString(v.HasFailed) + ", con mensaje: " + Convert.ToString(v.Error.Length > 0));
        Console.WriteLine("reproduciendo: " + Convert.ToString(v.IsPlaying));

        // En una ventana se dibuja el marcador (fondo negro e icono claro) aunque no haya vídeo.
        auto w = new Window("t", 220, 140);
        w.Add(v.View);
        v.Close();
        w.Render();
        uint corner = 0, icon = 0;
        memory_unsafe
        {
            corner = w.Canvas.Pixels[15 * w.Canvas.Width + 15];
            for (int y = 40; y < 100; y++)
                for (int x = 80; x < 140; x++)
                    if ((w.Canvas.Pixels[y * w.Canvas.Width + x] & 0xff) > icon) icon = w.Canvas.Pixels[y * w.Canvas.Width + x] & 0xff;
        }
        Console.WriteLine("fondo negro: " + Convert.ToString(corner == 0) + ", icono visible: " + Convert.ToString(icon > 60));
        return 0;
    }
}
