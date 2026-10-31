using std.ui;
using std.collections;

namespace Controles
{
    // Código de MainWindow.fstui: muestra todos los controles nuevos de std.ui
    // (MenuBar, ContextMenu, TreeView, TabControl, PictureBox, Canvas y Timer).
    public partial class MainWindow
    {
        var bolaX: float = 60;
        var bolaY: float = 60;
        var velX: float = 3.2f;
        var velY: float = 2.4f;
        var ticks: int;
        var ratonX: int = -1;
        var ratonY: int = -1;
        var estrellasX: List<int> = new List<int>();
        var estrellasY: List<int> = new List<int>();
        var estrella: Image;

        public init()
        {
            InitializeComponent();
            estrella = Image.FromFile("Assets/estrella.png");
            if (picPaisaje.Image == null) lblImagen.Text = Image.LastError;
        }

        func Estado(texto: string)
        {
            lblEstado.Text = texto;
            println(texto);
        }

        // ------------------------------------------------------------------ menús

        func OnAbrir(sender: Widget) { Estado("Abrir (" + sender.Text + ")"); }

        func OnGuardar(sender: Widget) { Estado("Guardado: " + (txtNombre.Text.Length > 0 ? txtNombre.Text : "sin nombre")); }

        func OnReciente(sender: Widget) { Estado("Reciente: " + sender.Text); }

        func OnSalir(sender: Widget) { Window.Close(); }

        func OnAnimar(sender: Widget)
        {
            mnuAnimar.Checked = !mnuAnimar.Checked;
            reloj.Enabled = mnuAnimar.Checked;
            Estado(mnuAnimar.Checked ? "Animación activada" : "Animación en pausa");
        }

        func OnAcercaDe(sender: Widget) { Estado("std.ui: controles dibujados por software en Linux, Windows y Android"); }

        func OnMenuArbol(sender: Widget)
        {
            TreeNode n = tvProyecto.SelectedNode;
            Estado(sender.Text + ": " + (n != null ? n.Text : "(nada)"));
        }

        func OnBorrarNodo(sender: Widget)
        {
            TreeNode n = tvProyecto.SelectedNode;
            if (n == null) return;
            if (n.Parent != null) n.Parent.Remove(n);
            else tvProyecto.RemoveNode(n);
            Estado("Borrado: " + n.Text);
        }

        // ------------------------------------------------------------------ árbol y pestañas

        func OnNodo(sender: Widget)
        {
            TreeNode n = tvProyecto.SelectedNode;
            if (n != null) Estado("Nodo: " + n.FullPath);
        }

        func OnNodoActivado(sender: Widget)
        {
            TreeNode n = tvProyecto.SelectedNode;
            if (n == null || n.Tag.Length == 0) return;
            if (n.Tag.StartsWith("Assets/"))
            {
                picPaisaje.Source = n.Tag;
                tabs.SelectedIndex = 0;
            }
            Estado("Abierto: " + n.Tag);
        }

        func OnPestana(sender: Widget) { Estado("Pestaña: " + tabs.SelectedPage.Text); }

        // ------------------------------------------------------------------ imágenes

        func OnModo(sender: Widget)
        {
            picPaisaje.SizeMode = (PictureSizeMode)cmbModo.SelectedIndex;
            picPaisaje.Invalidate();
            Estado("SizeMode = " + cmbModo.SelectedItem);
        }

        // ------------------------------------------------------------------ lienzo y temporizador

        func OnTick(sender: Widget)
        {
            ticks++;
            prgReloj.Value = ticks % 101;
            float w = lienzo.ActualWidth > 0 ? lienzo.ActualWidth : lienzo.Width;
            float h = lienzo.ActualHeight > 0 ? lienzo.ActualHeight : lienzo.Height;
            bolaX = bolaX + velX;
            bolaY = bolaY + velY;
            if (bolaX < 18 || bolaX > w - 18) velX = -velX;
            if (bolaY < 18 || bolaY > h - 18) velY = -velY;
            if (tabs.SelectedIndex == 1) lienzo.Invalidate();
        }

        func OnLienzoAbajo(sender: Widget, e: MouseArgs)
        {
            estrellasX.Add(e.X);
            estrellasY.Add(e.Y);
            Estado("Estrella en " + Convert.ToString(e.X) + ", " + Convert.ToString(e.Y));
            sender.Invalidate();
        }

        func OnLienzoMover(sender: Widget, e: MouseArgs)
        {
            ratonX = e.X;
            ratonY = e.Y;
            sender.Invalidate();
        }

        func OnPintar(sender: Widget, g: Graphics)
        {
            g.FillGradient(0, 0, g.Width, g.Height, Rgb.Of(0x14141c), Rgb.Of(0x1e1e2c), false);
            for (int x = 0; x < g.Width; x += 40) g.DrawLine(x, 0, x, g.Height, Rgb.Alpha(0xffffff, 0.05f));
            for (int y = 0; y < g.Height; y += 40) g.DrawLine(0, y, g.Width, y, Rgb.Alpha(0xffffff, 0.05f));
            // Gráfico de barras
            g.DrawText("Ventas", 20, 16, Rgb.Of(0xececee), 16, true);
            for (int i = 0; i < 6; i++)
            {
                int valor = i == 0 ? 40 : i == 1 ? 75 : i == 2 ? 55 : i == 3 ? 90 : i == 4 ? 65 : 30;
                float bh = valor * 1.4f;
                uint color = Rgb.Mix(Rgb.Of(0x4c8dff), Rgb.Of(0x22c55e), i / 5.0f);
                g.FillRoundRect(24 + i * 34, 180 - bh, 24, bh, 4, color);
            }
            g.DrawLine(16, 181, 230, 181, Rgb.Of(0x8e8e96), 1.5f);
            // Onda
            float px = 260, py = 110 + (float)Math.Sin(ticks * 0.08) * 40;
            for (int i = 1; i <= 60; i++)
            {
                float nx = 260 + i * 5;
                float ny = 110 + (float)Math.Sin(i * 0.25 + ticks * 0.08) * 40;
                g.DrawLine(px, py, nx, ny, Rgb.Of(0xf59e0b), 2);
                px = nx;
                py = ny;
            }
            g.DrawRoundRect(250, 50, 320, 120, 10, Rgb.Alpha(0xffffff, 0.2f), 1);
            // Bola que rebota (la mueve el Timer)
            g.FillCircle(bolaX, bolaY + 4, 16, Rgb.Alpha(0x000000, 0.35f));
            g.FillCircle(bolaX, bolaY, 16, Rgb.Of(0xe5484d));
            g.DrawCircle(bolaX, bolaY, 16, Rgb.Of(0xffffff), 1.5f);
            // Estrellas puestas con el ratón (sprite con transparencia)
            for (int i = 0; i < estrellasX.Count; i++)
                if (estrella != null) g.DrawImage(estrella, estrellasX[i] - 16, estrellasY[i] - 16, 32, 32);
            if (ratonX >= 0)
            {
                string pos = Convert.ToString(ratonX) + ", " + Convert.ToString(ratonY);
                g.DrawText(pos, g.Width - g.MeasureText(pos, 13) - 12, g.Height - 26, Rgb.Of(0x8e8e96), 13);
            }
            g.DrawText("Clic: poner una estrella · Ver > Animación (F5) para pausar", 20, g.Height - 26, Rgb.Of(0x8e8e96), 13);
        }
    }
}
