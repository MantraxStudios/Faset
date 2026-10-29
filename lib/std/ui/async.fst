// =============================================================================
//  std.ui — async / await en la interfaz.
//
//  Window.Run instala en su hilo un UiSynchronizationContext: un 'await' dentro de un método
//  async empezado en el hilo de la interfaz (un manejador de eventos 'async void', por ejemplo)
//  sigue después en ese mismo hilo. Las continuaciones se encolan con Post desde cualquier hilo,
//  Post despierta la espera del bucle (Wait) y el bucle las ejecuta entre eventos; así es seguro
//  tocar los controles después de un 'await':
//
//      async void OnClick(Widget sender)
//      {
//          lblEstado.Text = "Descargando...";
//          string s = await http.GetStringAsync("https://example.com/");   // no bloquea la ventana
//          lblEstado.Text = "Recibidos " + s.Length + " bytes";            // de nuevo en el hilo de la interfaz
//      }
//
//  Sin pantalla (FASET_UI_SCREENSHOT), el verbo "wait MS" del guion ejecuta también las
//  continuaciones que lleguen durante la espera (tiempo real).
// =============================================================================
using std.collections;
using std.task;
using std.thread;
using std.video;

namespace std.ui
{
    // Despertar el bucle de eventos desde otro hilo (runtime de C: tubería en POSIX, evento en Windows).
    public memory_unsafe static class UiLoop
    {
        public static extern void faset_loop_wake();
        public static extern void faset_loop_wait_msgs(int ms);
        public static extern bool faset_wait_fd_wake(int fd, int ms);

        // Despierta al hilo de la interfaz si está esperando eventos.
        public static void Wake() { NativeWindow.Wake(); }

        // Espera como mucho 'milliseconds' a que alguien llame a Wake (sin ventana: guion de pruebas).
        public static void WaitWake(int milliseconds) { faset_wait_fd_wake(-1, milliseconds); }
    }

    // Contexto de sincronización del hilo de la interfaz.
    public memory_unsafe class UiSynchronizationContext : SynchronizationContext
    {
        Mutex m = new Mutex();
        List<Action> queue = new List<Action>();

        // Encola 'action' para el hilo de la interfaz (desde cualquier hilo) y despierta el bucle.
        public override void Post(Action action)
        {
            m.Lock();
            queue.Add(action);
            m.Unlock();
            UiLoop.faset_loop_wake();  // también despierta "wait" del guion sin pantalla
            NativeWindow.Wake();
        }

        public bool HasPending
        {
            get
            {
                m.Lock();
                bool r = queue.Count > 0;
                m.Unlock();
                return r;
            }
        }

        // Ejecuta lo pendiente (solo desde el hilo de la interfaz); devuelve cuántas acciones corrió.
        public int RunPending()
        {
            m.Lock();
            if (queue.Count == 0)
            {
                m.Unlock();
                return 0;
            }
            List<Action> run = queue;
            queue = new List<Action>();
            m.Unlock();
            for (int i = 0; i < run.Count; i++) run[i]();
            return run.Count;
        }
    }

    public partial class Window
    {
        UiSynchronizationContext sync;

        // El contexto de sincronización de esta ventana (el de su hilo).
        public UiSynchronizationContext SyncContext => sync;

        void InstallSync()
        {
            if (sync == null) sync = new UiSynchronizationContext();
            SynchronizationContext.SetSynchronizationContext(sync);
        }

        bool HasPosted => sync != null && sync.HasPending;

        // Continuaciones de los métodos async que volvieron al hilo de la interfaz.
        void RunPosted()
        {
            if (sync == null) return;
            for (int round = 0; round < 64 && sync.RunPending() > 0; round++) { }
        }

        // Guion sin pantalla: deja pasar 'milliseconds' de tiempo real procesando vídeos y continuaciones.
        void PumpFor(int milliseconds)
        {
            long end = Environment.TickCount64() + milliseconds;
            for (;;)
            {
                VideoPlayer.Tick();
                RunPosted();
                long left = end - Environment.TickCount64();
                if (left <= 0) break;
                UiLoop.WaitWake(left < 5 ? (int)left : 5);
            }
            RunPosted();
        }
    }
}
