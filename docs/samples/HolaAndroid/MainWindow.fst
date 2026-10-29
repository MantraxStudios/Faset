using std.ui;

namespace HolaAndroid
{
    // Code-behind of MainWindow.fstui: the designer generates the controls
    // (lblTitle, txtName, btnGreet...) in the other half of this partial class.
    public partial class MainWindow
    {
        int greetings;

        public MainWindow() { InitializeComponent(); }

        ~MainWindow() { delete Window; }

        void OnNameChanged(Widget sender)
        {
            string name = txtName.Text.Length > 0 ? txtName.Text : "Faset";
            string title = String.Concat("Hola, ", name, chkExcited.Checked ? "!" : "");
            lblTitle.Text = title;
            String.Free(title);
        }

        void OnVolumeChanged(Widget sender) { prgVolume.Value = sldVolume.Value; }

        void OnGreetClick(Widget sender)
        {
            greetings++;
            string n = Convert.ToString(greetings);
            string text = String.Concat("Saludos: ", n, "");
            lblSubtitle.Text = text;
            String.Free(text);
            String.Free(n);
        }

        void OnCloseClick(Widget sender) { Window.Close(); }
    }
}
