// =============================================================================
//  std.time  —  reloj, pausas y cronómetro.
// =============================================================================
namespace std.time
{
    static extern long faset_ticks_ms();
    static extern long faset_time_unix_ms();
    static extern void faset_sleep_ms(long ms);

    public static class Time
    {
        // Milisegundos desde un punto arbitrario (monótono: para medir intervalos).
        public static long TickMs() => faset_ticks_ms();
        // Milisegundos desde 1970-01-01 UTC.
        public static long NowUnixMs() => faset_time_unix_ms();
        public static long NowUnixSeconds() => faset_time_unix_ms() / 1000;
        public static void Sleep(long milliseconds) { faset_sleep_ms(milliseconds); }
    }

    public struct Stopwatch
    {
        long startMs;
        long accumulated;
        bool running;

        public static Stopwatch StartNew()
        {
            Stopwatch s = new Stopwatch();
            s.Start();
            return s;
        }

        public bool IsRunning => running;

        public void Start()
        {
            if (running) return;
            startMs = faset_ticks_ms();
            running = true;
        }

        public void Stop()
        {
            if (!running) return;
            accumulated += faset_ticks_ms() - startMs;
            running = false;
        }

        public void Reset()
        {
            accumulated = 0;
            running = false;
        }

        public void Restart()
        {
            accumulated = 0;
            running = true;
            startMs = faset_ticks_ms();
        }

        public long ElapsedMs => running ? accumulated + faset_ticks_ms() - startMs : accumulated;
        public double ElapsedSeconds => ElapsedMs / 1000.0;
    }
}
