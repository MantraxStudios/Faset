using std.ui;

namespace Interfaz
{
    // Prueba sin pantalla de los controles de std.ui generados desde Ventana.fstui.
    public partial class Ventana
    {
        public int Ticks;
        public int Pintadas;

        public Ventana() { InitializeComponent(); }

        // "r,g,b,a" de un color 0xAARRGGBB
        static string Rgba(uint c) => Convert.ToString((long)((c >> 16) & 255)) + "," + Convert.ToString((long)((c >> 8) & 255)) + "," +
                                      Convert.ToString((long)(c & 255)) + "," + Convert.ToString((long)(c >> 24));

        static void Imagen(string ruta)
        {
            Image img = Image.FromFile(ruta);
            if (img == null)
            {
                println(ruta + ": " + Image.LastError);
                return;
            }
            println(ruta + ": " + Convert.ToString((long)img.Width) + "x" + Convert.ToString((long)img.Height) + " " + Rgba(img.GetPixel(0, 0)));
        }

        public void Probar()
        {
            // Decodificación: PNG (con alfa), JPEG, BMP y GIF (primer fotograma).
            Imagen("Assets/a.png");
            println("a.png (1,0) alfa = " + Convert.ToString((long)(Image.FromFile("Assets/a.png").GetPixel(1, 0) >> 24)));
            Imagen("Assets/b.jpg");
            Imagen("Assets/c.bmp");
            Imagen("Assets/d.gif");
            Imagen("Assets/no-existe.png");

            Window w = Window;
            w.Render();
            println("PictureBox: " + (foto.Image != null ? "cargada" : "vacía"));
            println("Pestaña inicial: " + Convert.ToString((long)tabs.SelectedIndex) + " de " + Convert.ToString((long)tabs.PageCount));
            println("Pintadas > 0: " + Convert.ToString(Pintadas > 0));
            memory_unsafe
            {
                // El Canvas está en (11, 76): su primer píxel es el rojo del FillRect.
                Canvas c = w.Canvas;
                uint px = c.Pixels[76 * c.Width + 11];
                uint fuera = c.Pixels[90 * c.Width + 30];
                println("Píxel del lienzo: " + Rgba(px | 0xff000000) + " / " + Rgba(fuera | 0xff000000));
            }

            // Ratón en el Canvas (coordenadas locales)
            w.Simulate("click 61 96");
            // Pestañas: clic en "Uno" y Ctrl+Tab
            w.Simulate("click 40 58");
            w.Simulate("key ctrl+tab");
            // Árbol: elegir, expandir con →, bajar y activar con Enter; doble clic
            w.Simulate("click 400 49 | key right | key down | key enter");
            println("Expandido: " + Convert.ToString(raiz.Expanded));
            w.Simulate("key left | key left");
            w.Simulate("dblclick 400 49");
            println("Expandido tras doble clic: " + Convert.ToString(raiz.Expanded));
            // Menú: clic en la cabecera y en el elemento; submenú con el teclado; atajo Ctrl+S
            w.Simulate("click 20 15 | click 40 48");
            println("Menú abierto: " + Convert.ToString(w.MenuOpen));
            w.Simulate("click 20 15 | key down | key down | key right | key enter");
            w.Simulate("key ctrl+s");
            mnuGuardar.Enabled = false;
            w.Simulate("key ctrl+s");
            println("Ctrl+S con el elemento deshabilitado: sin evento");
            // Menú contextual del árbol
            w.Simulate("rclick 400 49");
            println("Menú contextual abierto: " + Convert.ToString(w.MenuOpen));
            w.Simulate("key down | key enter");
            // Temporizador: 1 segundo simulado con Interval = 100
            w.Simulate("wait 1000");
            println("Ticks: " + Convert.ToString((long)Ticks));
            reloj.Stop();
            w.Simulate("wait 500");
            println("Ticks tras Stop: " + Convert.ToString((long)Ticks));
        }

        void OnGuardar(Widget sender) { println("Click: " + sender.Text); }
        void OnSub(Widget sender) { println("Submenú: " + sender.Text); }
        void OnTab(Widget sender) { println("Pestaña: " + tabs.SelectedPage.Text); }
        void OnNodo(Widget sender) { println("Nodo: " + arbol.SelectedNode.FullPath); }
        void OnActivado(Widget sender) { println("Activado: " + arbol.SelectedNode.Text + " [" + arbol.SelectedNode.Tag + "]"); }
        void OnBorrar(Widget sender) { println("Contextual: " + sender.Text + " sobre " + ctx.SourceControl.Name); }
        void OnTick(Widget sender) { Ticks++; }

        void OnPintar(Widget sender, Graphics g)
        {
            Pintadas++;
            g.Clear(Rgb.Of(0x000000));
            g.FillRect(0, 0, 10, 10, Rgb.Of(0xff0000));
        }

        void OnRaton(Widget sender, MouseArgs e)
        {
            println("Ratón: " + Convert.ToString(e.X) + ", " + Convert.ToString(e.Y) + " botón " + Convert.ToString(e.Button));
        }
    }
}
