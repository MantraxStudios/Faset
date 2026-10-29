// Prueba de async/await en std.ui sin pantalla (la ejecuta tests/run.sh):
//   FASET_UI_SCREENSHOT=x.bmp FASET_UI_SCRIPT="click 50 25 | wait 400" ./prueba
// El manejador 'async void' del botón espera (Task.Delay y Task.Run) y, al volver, sigue en el
// hilo de la interfaz (UiSynchronizationContext), donde actualiza la etiqueta.
using std;
using std.task;
using std.thread;
using std.ui;

public partial class MainWindow
{
    long uiThread;

    public MainWindow()
    {
        InitializeComponent();
        uiThread = Thread.CurrentId;
    }

    bool EnLaInterfaz() => Thread.CurrentId == uiThread;

    async void OnClick(Widget sender)
    {
        lblEstado.Text = "esperando";
        Console.WriteLine("click: hilo de la interfaz = " + EnLaInterfaz());
        await Task.Delay(50);
        Console.WriteLine("tras Task.Delay: hilo de la interfaz = " + EnLaInterfaz());
        int n = await Task.Run(() => EnLaInterfaz() ? -1 : 6 * 7);  // en el grupo de hilos
        Console.WriteLine("tras Task.Run: hilo de la interfaz = " + EnLaInterfaz() + ", resultado " + n);
        lblEstado.Text = "listo: " + n;
    }

    public void Report() { Console.WriteLine("etiqueta: " + lblEstado.Text); }
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
