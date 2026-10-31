using std.ui;

namespace HolaUI
{
    // Code-behind of MainWindow.fstui: the designer generates the controls
    // (lblTitle, txtName, btnGreet...) in the other half of this partial class.
    public partial class MainWindow
    {
        var greetings: int;

        public init() { InitializeComponent(); }

        deinit { delete Window; }

        func OnNameChanged(sender: Widget)
        {
            string name = txtName.Text.Length > 0 ? txtName.Text : "Faset";
            string title = String.Concat("Hello, ", name, chkExcited.Checked ? "!" : "");
            lblTitle.Text = title;
            String.Free(title);
        }

        func OnVolumeChanged(sender: Widget) { prgVolume.Value = sldVolume.Value; }

        func OnGreetClick(sender: Widget)
        {
            greetings++;
            string n = Convert.ToString(greetings);
            string text = String.Concat("Greeted ", n, greetings == 1 ? " time" : " times");
            lblSubtitle.Text = text;
            String.Free(text);
            String.Free(n);
        }

        func OnCloseClick(sender: Widget) { Window.Close(); }
    }
}
