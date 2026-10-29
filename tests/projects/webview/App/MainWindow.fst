// Control WebView de std.ui sin pantalla: la clase que genera el .fstui, su API y el
// marco de vista previa que se dibuja cuando no hay navegador nativo (FASET_UI_SCREENSHOT).
using std.ui;
using std.io;
using std.os;

namespace Prueba
{
    public partial class MainWindow
    {
        public int Navegaciones;

        public MainWindow() { InitializeComponent(); }

        void OnNavigated(Widget sender) { Navegaciones++; }

        void OnTitle(Widget sender) { lblEstado.Text = sender.Title; }

        void OnMessage(Widget sender, string message) { lblEstado.Text = message; }

        memory_unsafe static uint Pixel(byte* bmp, int width, int x, int y)
        {
            byte* p = bmp + 54 + ((long)y * width + x) * 4;
            return ((uint)p[2] << 16) | ((uint)p[1] << 8) | p[0];
        }

        public memory_unsafe int Probar()
        {
            Console.WriteLine(Web.Kind == WidgetKind.WebView ? "tipo: WebView" : "tipo: otro");
            Console.WriteLine("Source: " + Web.Source);
            Web.Navigate("https://faset.dev/docs");
            Console.WriteLine("Url: " + Web.Url);
            Console.WriteLine(Web.CanGoBack || Web.CanGoForward ? "historial: sí" : "historial: no");
            Console.WriteLine(Web.HasNativeWebView ? "nativo: sí" : "nativo: no");
            // Sin vista nativa los scripts y mensajes se encolan hasta la primera carga.
            Web.ExecuteScript("document.title = 'x';");
            Web.PostMessage("comillas \" y <etiquetas>\n");
            Console.WriteLine("título: '" + Web.Title + "', mensaje: '" + Web.Message + "'");

            string shot = Path.Combine(Path.GetTempPath(), "faset_prueba_webview.bmp");
            Environment.SetVariable("FASET_UI_SCREENSHOT", shot);
            int code = Application.Run(Window);
            Console.WriteLine("captura: " + Convert.ToString(code));

            byte* data = null;
            long length = 0;
            if (!File.TryReadAllBytes(shot, out data, out length) || length < 54 + 400 * 300 * 4)
            {
                Console.WriteLine("no se pudo leer la captura");
                return 1;
            }
            // Tema claro: cuerpo = Surface (blanco), fondo de la ventana = gris, separador de la barra = Border.
            Console.WriteLine(Pixel(data, 400, 200, 200) == 0xffffff ? "cuerpo: ok" : "cuerpo: mal");
            Console.WriteLine(Pixel(data, 400, 5, 200) == 0xf5f5f6 ? "fondo: ok" : "fondo: mal");
            Console.WriteLine(Pixel(data, 400, 200, 74) == 0xdedee2 ? "barra: ok" : "barra: mal");
            int ink = 0;
            for (int y = 47; y < 68; y++)
                for (int x = 92; x < 380; x++)
                    if (Pixel(data, 400, x, y) != 0xffffff && Pixel(data, 400, x, y) != 0xdedee2) ink++;
            Console.WriteLine(ink > 50 ? "dirección: dibujada" : "dirección: vacía");
            Memory.Free(data);
            File.Delete(shot);
            Console.WriteLine("navegaciones: " + Convert.ToString(Navegaciones));
            return 0;
        }
    }
}
