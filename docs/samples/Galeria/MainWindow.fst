using std.ui;

namespace Galeria
{
    // Código de MainWindow.fstui: los controles (txtName, sldLevel, btnBuild...)
    // los genera el compilador en la otra mitad de esta clase parcial.
    public partial class MainWindow
    {
        public MainWindow() { InitializeComponent(); }

        ~MainWindow() { delete Window; }

        void OnNameChanged(Widget sender)
        {
            string title = String.Concat("Proyecto: ", txtName.Text);
            lblTitle.Text = title;
            String.Free(title);
        }

        void OnLevelChanged(Widget sender) { prgLevel.Value = sldLevel.Value; }

        void OnBuild(Widget sender) { lblSubtitle.Text = "Compilando..."; }

        void OnCancel(Widget sender) { Window.Close(); }
    }
}
