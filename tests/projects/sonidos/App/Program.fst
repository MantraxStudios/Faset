// <Sound> y <Music> en un .fstui: campos generados, AutoPlay y recursos (<Asset>) junto al ejecutable.
using std.ui;
using std.audio;

public partial class Ventana
{
    public Ventana() { InitializeComponent(); }

    void OnTocar(Widget sender) { sndClic.Play(); }

    public void Probar()
    {
        println(sndClic.IsLoaded);
        println(sndClic.Error);
        println(sndClic.Duration);
        println(sndClic.Volume);
        println(sndClic.Pan);
        println(musFondo.IsLoaded);
        println(musFondo.Loop);
        println(musFondo.IsPlaying);         // AutoPlay
        OnTocar(btnTocar);
        println(Audio.ActiveVoices);
        Audio.Render(9600);                  // 0,2 s: el clic (0,1 s) termina, la música repite
        println(Audio.ActiveVoices);
        println(musFondo.IsPlaying);
        musFondo.Stop();
        Audio.Render(480);
        println(Audio.ActiveVoices);
    }
}

void main()
{
    Audio.Open("offline");   // sin dispositivo: el test mezcla con Audio.Render
    Ventana v = new Ventana();
    v.Probar();
}
