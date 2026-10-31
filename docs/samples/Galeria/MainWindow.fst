using std.ui;

namespace Galeria
{
    // Código de MainWindow.fstui: los controles (txtName, sldLevel, btnBuild...)
    // los genera el compilador en la otra mitad de esta clase parcial.
    public partial class MainWindow
    {
        public init() { InitializeComponent(); }

        deinit { delete Window; }

        func OnNameChanged(sender: Widget)
        {
            string title = String.Concat("Proyecto: ", txtName.Text);
            lblTitle.Text = title;
            String.Free(title);
        }

        func OnLevelChanged(sender: Widget) { prgLevel.Value = sldLevel.Value; }

        func OnBuild(sender: Widget) { lblSubtitle.Text = "Compilando..."; }

        func OnCancel(sender: Widget) { Window.Close(); }
    }
}
