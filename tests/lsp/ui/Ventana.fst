using std.ui;

namespace PruebaUi
{
    public partial class Ventana
    {
        public Ventana() { InitializeComponent(); }

        void OnAceptar(Widget sender) { btnAceptar.Text = "ok"; }
    }
}
