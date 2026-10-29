// =============================================================================
//  std.ui — Timer: componente no visual que lanza Tick cada Interval milisegundos.
//
//      <Timer Name="Reloj" Interval="1000" Enabled="true" Tick="OnTick" />
//
//  El evento llega en el hilo de la interfaz, desde el bucle de Window.Run: la
//  espera de eventos se acorta para despertar a tiempo. Un Timer se añade a la
//  ventana con Window.AddComponent (el código del .fstui lo hace solo).
// =============================================================================
namespace std.ui
{
    public memory_unsafe partial class Widget
    {
        int interval;
        long due;   // próximo disparo (ms de Environment.TickCount64; 0 = sin programar)

        // Timer: milisegundos entre dos Tick (mínimo 1).
        public int Interval
        {
            get => interval;
            set
            {
                interval = value < 1 ? 1 : value;
                due = 0;
            }
        }

        // Timer: empieza a contar desde ahora.
        public void Start()
        {
            Enabled = true;
            due = 0;
        }

        // Timer: se detiene. WebView: deja de cargar la página.
        public void Stop()
        {
            if (Kind == WidgetKind.WebView)
            {
                StopLoading();
                return;
            }
            Enabled = false;
            due = 0;
        }

        // Dispara el Tick si ya toca; devuelve los ms hasta el siguiente o -1 si está parado.
        internal int TimerUpdate(long now)
        {
            if (!Enabled || interval <= 0)
            {
                due = 0;
                return -1;
            }
            if (due == 0) due = now + interval;
            if (now >= due)
            {
                due += interval;
                if (due <= now) due = now + interval;  // si se retrasó mucho, no se acumulan disparos
                RaiseEvent(tickEvent);
                if (!Enabled) return -1;
            }
            return (int)(due - now);
        }
    }

    public partial class Window
    {
        long simTime = -1;   // reloj simulado del guion de pruebas ("wait MS")

        // Actualiza los componentes; devuelve los ms hasta el próximo temporizador (-1 = ninguno).
        int UpdateComponents(long now)
        {
            int best = -1;
            for (int i = 0; i < Components.Count; i++)
            {
                Widget c = Components[i];
                if (c.Kind != WidgetKind.Timer) continue;
                int until = c.TimerUpdate(now);
                if (until >= 0 && (best < 0 || until < best)) best = until;
            }
            return best;
        }
    }
}
