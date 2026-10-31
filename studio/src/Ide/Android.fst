// =============================================================================
//  Integración con Android: dispositivos (adb), emuladores (AVD) y la vista del
//  dispositivo dentro del IDE.
//
//  La lista de dispositivos y el arranque del emulador usan el propio compilador
//  ('faset android devices | avds | emulator'). La vista refleja la pantalla con un
//  flujo continuo 'adb exec-out screenrecord --output-format=raw-frames' (RGB sin
//  comprimir, escalado al tamaño del panel) que lee un hilo aparte; si el dispositivo
//  no lo admite, se vuelve a 'adb exec-out screencap' (un proceso por captura).
//  Toques, gestos y teclas van por un único 'adb shell' persistente ('input ...'),
//  sin lanzar un proceso por evento. Todo corre en procesos hijos o en el hilo
//  lector: el IDE nunca se bloquea.
// =============================================================================
using std.collections;
using std.text;
using std.io;
using std.os;
using std.thread;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    // Flujo continuo de la pantalla del dispositivo. 'screenrecord --output-format=raw-frames'
    // escribe fotogramas RGB (3 bytes por píxel, sin cabecera) del tamaño pedido, y solo
    // cuando la pantalla cambia. Un hilo lee la tubería, convierte cada fotograma completo a
    // RGBA y deja listo el último; el IDE lo sube a la GPU únicamente cuando hay uno nuevo.
    public memory_unsafe class ScreenStream
    {
        public var Width: int;                // tamaño de los fotogramas
        public var Height: int;
        public var DeviceW: int;              // pantalla lógica del dispositivo al arrancar (para el ratón)
        public var DeviceH: int;
        public var StartedMs: long;
        var proc: Process;
        var thread: Thread;
        var mutex: Mutex = new Mutex();
        var stop: AtomicInt = new AtomicInt();
        var ended: AtomicInt = new AtomicInt();
        var frames: AtomicLong = new AtomicLong();
        var ready: byte*;                     // último fotograma completo (RGBA), protegido por 'mutex'
        var spare: byte*;                     // el siguiente que escribe el hilo
        var fresh: bool;                      // 'ready' aún no se ha subido (protegido por 'mutex')

        deinit
        {
            Stop();
            if (proc != null) delete proc;
            Memory.Free(ready);
            Memory.Free(spare);
            delete mutex;
            delete stop;
            delete ended;
            delete frames;
        }

        // 'unlimited': --time-limit 0 (Android 11+); si no, 180 s (el máximo antiguo).
        public func Start(adb: string, serial: string, w: int, h: int, deviceW: int, deviceH: int, unlimited: bool) -> bool
        {
            Width = w;
            Height = h;
            DeviceW = deviceW;
            DeviceH = deviceH;
            StringBuilder size = new StringBuilder();
            size.Append((long)w).Append("x").Append((long)h);
            ProcessStartInfo si = new ProcessStartInfo(adb);
            si.AddArgument("-s").AddArgument(serial).AddArgument("exec-out").AddArgument("screenrecord");
            si.AddArgument("--output-format=raw-frames").AddArgument("--time-limit").AddArgument(unlimited ? "0" : "180");
            si.AddArgument("--size").AddArgument(size.View()).AddArgument("-");
            si.RedirectStandardOutput = true;
            si.RedirectStandardError = true;
            si.NewProcessGroup = true;
            si.CreateNoWindow = true;
            proc = Process.Start(si);
            delete si;
            delete size;
            if (proc == null) return false;
            ready = (byte*)Memory.Alloc((long)w * h * 4);
            spare = (byte*)Memory.Alloc((long)w * h * 4);
            StartedMs = Environment.TickCount64();
            thread = Thread.Run(&Loop, this);
            if (thread == null)
            {
                proc.Kill();
                return false;
            }
            return true;
        }

        // Para el hilo (que termina adb) y espera a que acabe.
        public func Stop()
        {
            if (thread == null) return;
            stop.Set(1);
            thread.Join();
            delete thread;
            thread = null;
        }

        public prop Frames: long => frames.Value;

        // adb terminó (dispositivo desconectado, límite de tiempo, screenrecord no disponible...).
        public prop Ended: bool => ended.Value != 0;

        // Sube el último fotograma si hay uno nuevo. Devuelve true si lo subió.
        public func TakeFrame(r: Renderer) -> bool
        {
            mutex.Lock();
            bool got = fresh;
            if (got) r.SetImage(ready, Width, Height, Width * 4);
            fresh = false;
            mutex.Unlock();
            return got;
        }

        // ------------------------------------------------------------------ hilo lector

        static func Loop(s: ScreenStream)
        {
            long frameBytes = (long)s.Width * s.Height * 3;
            byte* rgb = (byte*)Memory.Alloc(frameBytes);
            long fill = 0;
            while (s.stop.Value == 0)
            {
                // Espera (sin gastar CPU) a que adb escriba; vuelve en cuanto hay datos.
                if (!s.proc.WaitForOutput(20))
                {
                    if (s.proc.OutputEnded) break;
                    continue;
                }
                s.proc.ClearError();
                string chunk = s.proc.Output;
                byte* p = chunk.Ptr;
                long n = chunk.Length, i = 0;
                while (i < n)
                {
                    long take = Math.Min(n - i, frameBytes - fill);
                    Memory.Copy(rgb + fill, p + i, take);
                    fill += take;
                    i += take;
                    if (fill == frameBytes)
                    {
                        s.Publish(rgb);
                        fill = 0;
                    }
                }
                s.proc.ClearOutput();
            }
            s.proc.Kill();
            s.proc.WaitForExit(1000);
            Memory.Free(rgb);
            s.ended.Set(1);
        }

        // RGB -> RGBA opaco en el búfer libre y se intercambia con el listo.
        func Publish(rgb: byte*)
        {
            long n = (long)Width * Height;
            uint* d = (uint*)spare;
            byte* src = rgb;
            for (long k = 0; k < n; k++)
            {
                d[k] = 0xFF000000 | ((uint)src[2] << 16) | ((uint)src[1] << 8) | (uint)src[0];
                src += 3;
            }
            mutex.Lock();
            byte* t = ready;
            ready = spare;
            spare = t;
            fresh = true;
            mutex.Unlock();
            frames.Increment();
        }
    }

    public memory_unsafe class AndroidTools
    {
        public const float ToolbarHeight = 44;

        public var Compiler: string = "";                          // ruta del compilador (vista)
        public var Serials: List<string> = new List<string>();     // dispositivos listos (copias)
        public var Models: List<string> = new List<string>();
        public var Avds: List<string> = new List<string>();        // emuladores instalados (copias)
        public var Device: string = String.Copy("");               // dispositivo elegido (copia)
        public var StartingAvd: string = String.Copy("");          // emulador arrancando ("" = ninguno)
        public var Status: string = "";                            // mensaje para la barra de estado (vista literal)
        public var Focused: bool;                                   // el teclado va al dispositivo
        public var ScreenW: int;                                    // tamaño lógico de la pantalla (píxeles del dispositivo)
        public var ScreenH: int;
        public var HasFrame: bool;
        public var Listed: bool;                                    // ya se consultó la lista al menos una vez
        public var Fps: double;                                     // fotogramas mostrados por segundo

        var adb: string = String.Copy("");
        var listProc: ChildProcess;
        var listOut: StringBuilder = new StringBuilder();
        var listStage: int;                                         // 0 dispositivos, 1 AVD
        var emuProc: ChildProcess;
        var emuOut: StringBuilder = new StringBuilder();
        var screenProc: ChildProcess;                               // screencap (solo si no hay flujo)
        var screenFile: string = String.Copy("");
        var lastShotMs: long;
        var inputs: List<ChildProcess> = new List<ChildProcess>();

        // Flujo continuo de la pantalla (screenrecord) y su estado.
        var stream: ScreenStream;
        var streamUnsupported: bool;                                // falló varias veces: se usa screencap
        var unlimited: bool = true;                                 // --time-limit 0 (si falla, 180 s)
        var streamFailures: int;
        var streamRetryMs: long;
        var wantW: int;                                             // tamaño de flujo deseado (último calculado)
        var wantH: int;
        var wantSinceMs: long;
        var boxW: float;                                            // hueco para la pantalla en el panel (de Draw)
        var boxH: float;
        var fpsMs: long;
        var fpsFrames: long;

        // 'adb shell' persistente: recibe las órdenes 'input' y las consultas de tamaño y giro.
        var shell: Process;
        var shellOut: StringBuilder = new StringBuilder();
        var shellRetryMs: long;
        var naturalW: int;                                          // 'wm size' (orientación natural)
        var naturalH: int;
        var rotation: int = -1;                                     // 0..3 (-1 = aún no se sabe)
        var probeMs: long;
        var firstProbeMs: long;

        // Geometría del último dibujo (para el ratón).
        var imgX: float;
        var imgY: float;
        var imgW: float;
        var imgH: float;
        var barX: float;
        var barY: float;
        var barW: float;
        var pressing: bool;
        var pressX: float;
        var pressY: float;
        var pressMs: long;
        public var HoverButton: int = -1;

        public init()
        {
            string tmp = Path.GetTempPath();
            string pid = Convert.ToString(Environment.ProcessId);
            string name = String.Concat("faset-screen-", pid, ".raw");
            String.Free(screenFile);
            screenFile = Path.Combine(tmp, name);
            String.Free(name);
            String.Free(pid);
            String.Free(tmp);
            FindAdb();
        }

        deinit
        {
            FreeAll(Serials);
            FreeAll(Models);
            FreeAll(Avds);
            delete Serials;
            delete Models;
            delete Avds;
            if (listProc != null) delete listProc;
            if (emuProc != null) delete emuProc;
            if (screenProc != null) delete screenProc;
            Shutdown();
            for (int i = 0; i < inputs.Count; i++) delete inputs[i];
            delete inputs;
            delete listOut;
            delete emuOut;
            delete shellOut;
            File.Delete(screenFile);
            String.Free(screenFile);
            String.Free(Device);
            String.Free(StartingAvd);
            String.Free(adb);
        }

        static func FreeAll(l: List<string>)
        {
            for (int i = 0; i < l.Count; i++) String.Free(l[i]);
            l.Clear();
        }

        // Termina el flujo de la pantalla y el shell persistente (al cerrar el IDE o cambiar de dispositivo).
        public func Shutdown()
        {
            StopStream();
            if (shell != null)
            {
                shell.CloseInput();
                shell.Kill();
                delete shell;
                shell = null;
            }
            shellOut.Clear();
        }

        func StopStream()
        {
            if (stream == null) return;
            delete stream;   // el destructor para el hilo y termina adb
            stream = null;
        }

        public prop AdbFound: bool => adb.Length > 0;

        // Hay un flujo de pantalla activo: el bucle principal debe despertar más a menudo.
        public prop Streaming: bool => stream != null;
        public prop Busy: bool => (listProc != null && listProc.IsRunning) || StartingAvd.Length > 0;

        // adb: $ANDROID_HOME, $ANDROID_SDK_ROOT o ~/Android/Sdk (platform-tools), o el PATH.
        func FindAdb()
        {
            string exe = OS.IsWindows ? "adb.exe" : "adb";
            string home = Settings.HomeFolder();
            List<string> roots = new List<string>();
            roots.Add(Environment.GetVariable("ANDROID_HOME"));
            roots.Add(Environment.GetVariable("ANDROID_SDK_ROOT"));
#if WINDOWS
            // Donde lo instalan 'faset setup android' y Android Studio: %LOCALAPPDATA%\Android\Sdk.
            string local = Environment.GetVariable("LOCALAPPDATA");
            roots.Add(local.Length > 0 ? Path.Combine(local, "Android/Sdk") : String.Copy(""));
            String.Free(local);
#endif
            roots.Add(Path.Combine(home, "Android/Sdk"));
            roots.Add(Path.Combine(home, "AppData/Local/Android/Sdk"));
            roots.Add(Path.Combine(home, "Library/Android/sdk"));
            for (int i = 0; i < roots.Count; i++)
            {
                if (adb.Length == 0 && roots[i].Length > 0)
                {
                    string tools = Path.Combine(roots[i], "platform-tools");
                    string candidate = Path.Combine(tools, exe);
                    String.Free(tools);
                    if (File.Exists(candidate))
                    {
                        String.Free(adb);
                        adb = candidate;
                    }
                    else String.Free(candidate);
                }
                String.Free(roots[i]);
            }
            delete roots;
            String.Free(home);
            string found;
            if (adb.Length == 0 && Process.Capture(OS.IsWindows ? "where adb.exe" : "command -v adb", out found) == 0)
            {
                // 'where' (Windows) puede listar varias coincidencias: vale la primera línea.
                string first = found.Trim();
                int nl = first.IndexOf("\n");
                if (nl > 0) first = first.Substring(0, nl).Trim();
                String.Free(adb);
                adb = String.Copy(first);
            }
        }

        // ------------------------------------------------------------------ dispositivos

        // Vuelve a consultar dispositivos conectados y emuladores instalados (en segundo plano).
        public func Refresh()
        {
            if (Compiler.Length == 0 || (listProc != null && listProc.IsRunning)) return;
            listStage = 0;
            StartList("devices");
        }

        func StartList(what: string)
        {
            listOut.Clear();
            if (listProc == null) listProc = new ChildProcess();
            string q = Analyzer.Quote(Compiler);
            string cmd = String.Concat(q, " android ", what);
            listProc.Start(cmd, ".");
            String.Free(cmd);
            String.Free(q);
        }

        // Arranca un emulador sin ventana: su pantalla se ve en el panel Dispositivo.
        public func StartEmulator(avd: string)
        {
            if (Compiler.Length == 0 || StartingAvd.Length > 0) return;
            String.Free(StartingAvd);
            StartingAvd = String.Copy(avd);
            emuOut.Clear();
            if (emuProc == null) emuProc = new ChildProcess();
            string q = Analyzer.Quote(Compiler);
            string qa = Analyzer.Quote(avd);
            string cmd = String.Concat(q, " android emulator ", String.Concat(qa, " --headless"));
            emuProc.Start(cmd, ".");
            String.Free(cmd);
            String.Free(qa);
            String.Free(q);
            Status = "Starting the Android emulator…";
        }

        public func Select(serial: string)
        {
            if (serial == Device) return;
            Shutdown();
            String.Free(Device);
            Device = String.Copy(serial);
            HasFrame = false;
            naturalW = 0;
            naturalH = 0;
            rotation = -1;
            probeMs = 0;
            firstProbeMs = 0;
            streamUnsupported = false;
            unlimited = true;
            streamFailures = 0;
            streamRetryMs = 0;
        }

        public func ModelOf(serial: string) -> string
        {
            for (int i = 0; i < Serials.Count; i++)
                if (Serials[i] == serial) return Models[i];
            return "";
        }

        public func IsOnline(serial: string) -> bool
        {
            for (int i = 0; i < Serials.Count; i++)
                if (Serials[i] == serial) return true;
            return false;
        }

        // ------------------------------------------------------------------ actualización

        // Atiende los procesos en marcha; 'showing' indica si el panel del dispositivo se ve.
        // Devuelve true si hay que redibujar.
        public func Update(r: Renderer, showing: bool) -> bool
        {
            bool redraw = false;
            long now = Environment.TickCount64();
            if (listProc != null && listProc.IsRunning)
            {
                Analyzer.ReadChild(listProc, listOut);
                if (listProc.HasExited)
                {
                    Analyzer.ReadChild(listProc, listOut);
                    if (listStage == 0) ParseDevices();
                    else ParseAvds();
                    if (listStage == 0)
                    {
                        listStage = 1;
                        StartList("avds");
                    }
                    else Listed = true;
                    redraw = true;
                }
            }
            if (emuProc != null && StartingAvd.Length > 0)
            {
                Analyzer.ReadChild(emuProc, emuOut);
                if (emuProc.HasExited)
                {
                    Analyzer.ReadChild(emuProc, emuOut);
                    // La salida estándar termina con el serial del emulador listo.
                    List<string> lines = Text.Split(emuOut.View(), "\n");
                    string serial = "";
                    for (int i = 0; i < lines.Count; i++)
                    {
                        string l = lines[i].Trim();
                        if (l.StartsWith("emulator-")) serial = l;
                    }
                    if (serial.Length > 0)
                    {
                        Select(serial);
                        Status = "Android emulator ready";
                    }
                    else Status = "The Android emulator could not be started (see 'faset doctor')";
                    delete lines;
                    String.Free(StartingAvd);
                    StartingAvd = String.Copy("");
                    Refresh();
                    redraw = true;
                }
            }
            for (int i = inputs.Count - 1; i >= 0; i--)
                if (inputs[i].HasExited)
                {
                    delete inputs[i];
                    inputs.RemoveAt(i);
                }
            bool live = Device.Length > 0 && adb.Length > 0;
            if (shell != null) ReadShell();
            if (live && showing) Probe(now);
            if (UpdateStream(r, live && showing, now)) redraw = true;
            // Recuento de fotogramas por segundo (se muestra bajo la pantalla).
            if (now - fpsMs >= 1000)
            {
                double fps = fpsMs == 0 ? 0.0 : fpsFrames * 1000.0 / (now - fpsMs);
                if (fps != Fps) redraw = true;
                Fps = fps;
                fpsFrames = 0;
                fpsMs = now;
            }
            // Sin flujo (el dispositivo no admite screenrecord): una captura a la vez, como mucho cada 120 ms.
            if (screenProc != null && screenProc.HasExited)
            {
                LoadFrame(r);
                delete screenProc;
                screenProc = null;
                redraw = true;
            }
            if (showing && streamUnsupported && screenProc == null && live && now - lastShotMs >= 120)
            {
                lastShotMs = now;
                screenProc = new ChildProcess();
                string qa = Analyzer.Quote(adb), qs = Analyzer.Quote(Device), qf = Analyzer.Quote(screenFile);
                StringBuilder sb = new StringBuilder();
                sb.Append(qa).Append(" -s ").Append(qs).Append(" exec-out screencap > ").Append(qf);
                screenProc.Start(sb.View(), ".");
                delete sb;
                String.Free(qa);
                String.Free(qs);
                String.Free(qf);
            }
            return redraw;
        }

        // ------------------------------------------------------------------ flujo de la pantalla

        // Arranca, reinicia (tamaño o giro distintos, adb terminado) o para el flujo y sube el
        // último fotograma. Devuelve true si hay que redibujar.
        func UpdateStream(r: Renderer, wanted: bool, now: long) -> bool
        {
            if (!wanted || streamUnsupported)
            {
                StopStream();
                return false;
            }
            // Hace falta el tamaño y el giro del dispositivo (los da el shell persistente).
            if (naturalW <= 0 || naturalH <= 0) return false;
            if (rotation < 0)
            {
                // 'dumpsys display' de algunos dispositivos no informa del giro: se supone vertical.
                if (firstProbeMs == 0 || now - firstProbeMs < 3000) return false;
                rotation = 0;
            }
            bool turned = rotation == 1 || rotation == 3;
            int lw = turned ? naturalH : naturalW, lh = turned ? naturalW : naturalH;
            int tw = 0, th = 0;
            StreamSize(lw, lh, out tw, out th);
            if (tw != wantW || th != wantH)
            {
                wantW = tw;
                wantH = th;
                wantSinceMs = now;
            }
            bool redraw = false;
            if (stream != null)
            {
                if (stream.TakeFrame(r))
                {
                    ScreenW = stream.DeviceW;
                    ScreenH = stream.DeviceH;
                    HasFrame = true;
                    fpsFrames++;
                    redraw = true;
                }
                if (stream.Ended)
                {
                    // Sin un solo fotograma: '--time-limit 0' no se admite (Android < 11) o falla
                    // screenrecord. Tras varios intentos se usa screencap.
                    if (stream.Frames == 0)
                    {
                        streamFailures++;
                        if (streamFailures == 1) unlimited = false;
                        if (streamFailures >= 3) streamUnsupported = true;
                        streamRetryMs = now + 500;
                    }
                    else streamFailures = 0;
                    StopStream();
                }
                else
                {
                    // El panel cambió de tamaño o el dispositivo giró: se pide otro tamaño cuando
                    // el nuevo se mantiene un momento (al arrastrar el borde del panel no se
                    // reinicia a cada píxel). Diferencias pequeñas no compensan el corte.
                    bool rotated = lw != stream.DeviceW || lh != stream.DeviceH;
                    int dw = Math.Abs(tw - stream.Width);
                    bool resized = dw > 16 && dw * 10 > stream.Width;
                    if ((rotated || resized) && now - wantSinceMs >= 300) StopStream();
                }
            }
            if (stream == null && !streamUnsupported && now >= streamRetryMs)
            {
                stream = new ScreenStream();
                if (!stream.Start(adb, Device, tw, th, lw, lh, unlimited))
                {
                    delete stream;
                    stream = null;
                    streamUnsupported = true;
                }
            }
            return redraw;
        }

        // Tamaño del flujo: la pantalla lógica reducida al hueco del panel (y a la textura del
        // renderizador), conservando la proporción. Pedir menos píxeles es lo que da fluidez.
        func StreamSize(lw: int, lh: int, out tw: int, out th: int)
        {
            double bw = boxW > 0 ? (double)boxW : (double)Renderer.ImageSize;
            double bh = boxH > 0 ? (double)boxH : (double)Renderer.ImageSize;
            bw = Math.Min(bw, (double)Renderer.ImageSize);
            bh = Math.Min(bh, (double)Renderer.ImageSize);
            double k = Math.Min(1.0, Math.Min(bw / lw, bh / lh));
            k = Math.Max(k, Math.Min(1.0, 160.0 / Math.Min((double)lw, (double)lh)));   // ni demasiado pequeño
            tw = Math.Max(2, (int)(lw * k) / 2 * 2);
            th = Math.Max(2, (int)(lh * k) / 2 * 2);
        }

        // ------------------------------------------------------------------ shell persistente

        // Arranca 'adb -s <serial> shell' con la entrada redirigida (si no está ya en marcha).
        func EnsureShell(now: long) -> bool
        {
            if (shell != null && !shell.HasExited) return true;
            if (shell != null)
            {
                delete shell;
                shell = null;
            }
            if (adb.Length == 0 || Device.Length == 0 || now < shellRetryMs) return false;
            shellRetryMs = now + 1000;
            ProcessStartInfo si = new ProcessStartInfo(adb);
            si.AddArgument("-s").AddArgument(Device).AddArgument("shell");
            si.RedirectStandardInput = true;
            si.RedirectStandardOutput = true;
            si.MergeStandardError = true;
            si.NewProcessGroup = true;
            si.CreateNoWindow = true;
            shell = Process.Start(si);
            delete si;
            shellOut.Clear();
            return shell != null;
        }

        // Envía una orden de shell al dispositivo. Por el shell persistente no hay que lanzar un
        // proceso (ni abrir una conexión con adb) por cada toque o tecla.
        func Send(command: string)
        {
            if (adb.Length == 0 || Device.Length == 0) return;
            if (EnsureShell(Environment.TickCount64()))
            {
                StringBuilder line = new StringBuilder();
                line.Append(command).Append("\n");
                bool ok = shell.WriteInput(line.View());
                delete line;
                if (ok) return;
            }
            // Sin shell persistente: un proceso por orden.
            string q = CommandLine.QuoteShell(command);
            string args = String.Concat("shell ", q);
            Shell(args);
            String.Free(args);
            String.Free(q);
        }

        // Pregunta tamaño y giro de la pantalla cada segundo (barato: no crea procesos).
        func Probe(now: long)
        {
            if (now - probeMs < 1000) return;
            probeMs = now;
            if (firstProbeMs == 0) firstProbeMs = now;
            if (naturalW <= 0) Send("wm size; dumpsys display | grep -m1 mCurrentOrientation");
            else Send("dumpsys display | grep -m1 mCurrentOrientation");
        }

        // Lee las respuestas del shell: "Physical size: 1080x2400", "Override size: ..." y
        // "mCurrentOrientation=1". Lo demás (errores de 'input'...) se descarta.
        func ReadShell()
        {
            shell.ReadOutput(shellOut);
            for (;;)
            {
                string all = shellOut.View();
                int nl = all.IndexOf("\n");
                if (nl < 0) break;
                string line = all.Substring(0, nl).Trim();
                int colon = line.IndexOf(":");
                if ((line.StartsWith("Physical size:") || line.StartsWith("Override size:")) && colon > 0)
                {
                    string dims = line.Substring(colon + 1).Trim();
                    int x = dims.IndexOf("x");
                    if (x > 0)
                    {
                        int w = dims.Substring(0, x).ToInt(), h = dims.Substring(x + 1).ToInt();
                        if (w > 0 && h > 0)
                        {
                            naturalW = w;
                            naturalH = h;
                        }
                    }
                }
                else if (line.StartsWith("mCurrentOrientation="))
                {
                    int rot = line.Substring(20).ToInt();
                    if (rot >= 0 && rot <= 3) rotation = rot;
                }
                string rest = String.Copy(all.Substring(nl + 1));
                shellOut.Clear();
                shellOut.Append(rest);
                String.Free(rest);
            }
            // Una línea sin terminar muy larga no es de las que interesan.
            if (shellOut.Length > 4096) shellOut.Clear();
        }

        func ParseDevices()
        {
            FreeAll(Serials);
            FreeAll(Models);
            List<string> lines = Text.Split(listOut.View(), "\n");
            for (int i = 0; i < lines.Count; i++)
            {
                List<string> cols = Text.Split(lines[i].Trim(), "\t");
                if (cols.Count >= 2 && cols[1] == "device")
                {
                    Serials.Add(String.Copy(cols[0]));
                    Models.Add(String.Copy(cols.Count >= 3 ? cols[2] : ""));
                }
                delete cols;
            }
            delete lines;
            // Si no hay dispositivo elegido, se toma el primero conectado.
            if (Device.Length == 0 && Serials.Count > 0) Select(Serials[0]);
        }

        func ParseAvds()
        {
            FreeAll(Avds);
            List<string> lines = Text.Split(listOut.View(), "\n");
            for (int i = 0; i < lines.Count; i++)
            {
                string l = lines[i].Trim();
                if (l.Length > 0 && !l.StartsWith("faset:") && !l.StartsWith("INFO")) Avds.Add(String.Copy(l));
            }
            delete lines;
        }

        // Cabecera de screencap: ancho, alto, formato (1 = RGBA_8888) y, en Android 9+, espacio de color.
        func LoadFrame(r: Renderer)
        {
            byte* data = null;
            long len = 0;
            if (File.TryReadAllBytes(screenFile, out data, out len) && len > 12)
            {
                int w = *(int*)data, h = *(int*)(data + 4), format = *(int*)(data + 8);
                long pixels = (long)w * h * 4;
                long header = len - pixels;
                if (w > 0 && h > 0 && format == 1 && (header == 12 || header == 16))
                {
                    // El canal alfa de la captura no es fiable: se fuerza a opaco.
                    byte* px = data + header;
                    for (long i = 3; i < pixels; i += 4) px[i] = 255;
                    r.SetImage(px, w, h, w * 4);
                    ScreenW = w;
                    ScreenH = h;
                    HasFrame = true;
                    fpsFrames++;
                }
            }
            Memory.Free(data);
        }

        // ------------------------------------------------------------------ entrada

        // Lanza 'adb -s <serial> <args>' en un proceso aparte (órdenes de adb como 'emu rotate').
        func Shell(args: string)
        {
            if (adb.Length == 0 || Device.Length == 0) return;
            string qa = Analyzer.Quote(adb), qs = Analyzer.Quote(Device);
            StringBuilder sb = new StringBuilder();
            sb.Append(qa).Append(" -s ").Append(qs).Append(" ").Append(args);
            ChildProcess p = new ChildProcess();
            p.Start(sb.View(), ".");
            inputs.Add(p);
            delete sb;
            String.Free(qa);
            String.Free(qs);
        }

        func KeyEvent(code: int)
        {
            string n = Convert.ToString(code);
            string args = String.Concat("input keyevent ", n);
            Send(args);
            String.Free(args);
            String.Free(n);
        }

        public func Rotate()
        {
            Shell("emu rotate");
            probeMs = Environment.TickCount64() - 300;   // vuelve a preguntar el giro enseguida
        }

        // Punto de la ventana -> píxel del dispositivo.
        func ToDevice(px: float, py: float, out dx: int, out dy: int)
        {
            dx = (int)Math.Clamp((px - imgX) / imgW * ScreenW, 0.0, ScreenW - 1.0);
            dy = (int)Math.Clamp((py - imgY) / imgH * ScreenH, 0.0, ScreenH - 1.0);
        }

        func InScreen(px: float, py: float) -> bool => HasFrame && px >= imgX && py >= imgY && px < imgX + imgW && py < imgY + imgH;

        // Botones bajo la pantalla: 0 atrás, 1 inicio, 2 recientes, 3 girar.
        func ButtonAt(px: float, py: float) -> int
        {
            if (Device.Length == 0 || py < barY || py >= barY + 32 || px < barX || px >= barX + barW) return -1;
            return (int)Math.Floor((px - barX) / (barW / 4));
        }

        // Devuelve true si el panel usó el clic.
        public func MouseDown(px: float, py: float) -> bool
        {
            int b = ButtonAt(px, py);
            if (b >= 0)
            {
                Focused = true;
                if (b == 0) KeyEvent(4);
                else if (b == 1) KeyEvent(3);
                else if (b == 2) KeyEvent(187);
                else Rotate();
                return true;
            }
            if (!InScreen(px, py)) return false;
            Focused = true;
            pressing = true;
            pressX = px;
            pressY = py;
            pressMs = Environment.TickCount64();
            return true;
        }

        public func MouseUp(px: float, py: float)
        {
            if (!pressing) return;
            pressing = false;
            int x0 = 0, y0 = 0, x1 = 0, y1 = 0;
            ToDevice(pressX, pressY, out x0, out y0);
            ToDevice(px, py, out x1, out y1);
            StringBuilder sb = new StringBuilder();
            if (Math.Abs(px - pressX) + Math.Abs(py - pressY) < 6)
            {
                long held = Environment.TickCount64() - pressMs;
                if (held > 500) sb.Append("input swipe ").Append((long)x0).Append(" ").Append((long)y0).Append(" ").Append((long)x0).Append(" ").Append((long)y0).Append(" ").Append(held);
                else sb.Append("input tap ").Append((long)x0).Append(" ").Append((long)y0);
            }
            else
            {
                long ms = Math.Max(80, Math.Min(1500, Environment.TickCount64() - pressMs));
                sb.Append("input swipe ").Append((long)x0).Append(" ").Append((long)y0).Append(" ")
                  .Append((long)x1).Append(" ").Append((long)y1).Append(" ").Append(ms);
            }
            Send(sb.View());
            delete sb;
        }

        public func Scroll(px: float, py: float, lines: int)
        {
            if (!InScreen(px, py)) return;
            int x = 0, y = 0;
            ToDevice(px, py, out x, out y);
            int dy = -lines * ScreenH / 12;
            int y2 = Math.Clamp(y + dy, 0, ScreenH - 1);
            StringBuilder sb = new StringBuilder();
            sb.Append("input swipe ").Append((long)x).Append(" ").Append((long)y).Append(" ").Append((long)x).Append(" ").Append((long)y2).Append(" 120");
            Send(sb.View());
            delete sb;
        }

        // Teclado con el panel enfocado: se escribe en el dispositivo. Devuelve true si la usó.
        public func Key(e: Event) -> bool
        {
            if (!Focused || Device.Length == 0) return false;
            uint k = e.Key;
            if (k == Keys.BackSpace) KeyEvent(67);
            else if (k == Keys.Delete) KeyEvent(112);
            else if (k == Keys.Return || k == Keys.KeypadEnter) KeyEvent(66);
            else if (k == Keys.Escape) KeyEvent(4);
            else if (k == Keys.Tab) KeyEvent(61);
            else if (k == Keys.Left) KeyEvent(21);
            else if (k == Keys.Right) KeyEvent(22);
            else if (k == Keys.Up) KeyEvent(19);
            else if (k == Keys.Down) KeyEvent(20);
            else if (!e.Ctrl && e.Char >= 0x20)
            {
                // 'input text' no admite espacios: se envían como %s.
                StringBuilder t = new StringBuilder();
                if (e.Char == ' ') t.Append("%s");
                else t.Append(e.Char);
                string q = CommandLine.QuoteShell(t.View());
                string args = String.Concat("input text ", q);
                Send(args);
                String.Free(args);
                String.Free(q);
                delete t;
            }
            else return false;
            return true;
        }

        // ------------------------------------------------------------------ dibujo

        public func Draw(r: Renderer, x: float, y: float, w: float, h: float, mouseX: float, mouseY: float)
        {
            float top = y + 46, bottom = y + h - 8;
            float availW = w - 32, availH = bottom - top - ToolbarHeight - 16;
            boxW = availW;   // el flujo se pide a este tamaño
            boxH = availH;
            r.PushClip(x, top - 6, w, h - 40);
            if (!AdbFound)
            {
                Center(r, x, w, top + 30, L.T("Android SDK not found"), L.T("Install it with Android Studio or set ANDROID_HOME"));
                r.PopClip();
                return;
            }
            if (Device.Length == 0)
            {
                string hint = StartingAvd.Length > 0 ? L.T("Starting the emulator… this can take a minute") : L.T("Choose a device or start an emulator in the target selector");
                Center(r, x, w, top + 30, L.T("No Android device"), hint);
                r.PopClip();
                return;
            }
            if (!HasFrame)
            {
                Center(r, x, w, top + 30, Device, L.T("Waiting for the device screen…"));
                r.PopClip();
                return;
            }
            // Teléfono: marco redondeado con la pantalla escalada para caber en el panel.
            float k = (float)Math.Min((double)(availW / ScreenW), (double)(availH / ScreenH));
            imgW = ScreenW * k;
            imgH = ScreenH * k;
            imgX = x + (w - imgW) / 2;
            imgY = top + 8;
            r.Shadow(imgX - 8, imgY - 8, imgW + 16, imgH + 16, 22, 18, Color.Hex(0x000000, 0.55f));
            r.RoundRect(imgX - 8, imgY - 8, imgW + 16, imgH + 16, 22, Color.Hex(0x0b0b0d));
            r.RoundBorder(imgX - 8, imgY - 8, imgW + 16, imgH + 16, 22, 1, Focused ? Theme.TextSecondary : Theme.BorderStrong);
            r.Image(imgX, imgY, imgW, imgH, new Color(1, 1, 1, 1));
            // Botones: atrás, inicio, recientes, girar
            barW = (float)Math.Min(220.0, (double)w - 32);
            barX = x + (w - barW) / 2;
            barY = imgY + imgH + 16;
            HoverButton = ButtonAt(mouseX, mouseY);
            r.RoundRect(barX, barY, barW, 32, 16, Theme.Elevated);
            float bw = barW / 4;
            for (int i = 0; i < 4; i++)
            {
                float cx = barX + bw * i + bw / 2, cy = barY + 16;
                if (HoverButton == i) r.RoundRect(barX + bw * i + 3, barY + 3, bw - 6, 26, 13, Theme.Hover);
                Color c = HoverButton == i ? Theme.White : Theme.TextSecondary;
                if (i == 0)
                {
                    // Triángulo hacia la izquierda con barras escalonadas
                    for (int s = 0; s < 6; s++) r.Rect(cx - 5 + s * 2, cy - s, 1.6f, s * 2 + 1.6f, c);
                }
                else if (i == 1) r.RoundBorder(cx - 6, cy - 6, 12, 12, 6, 1.6f, c);
                else if (i == 2) r.RoundBorder(cx - 5.5f, cy - 5.5f, 11, 11, 2, 1.6f, c);
                else
                {
                    r.RoundBorder(cx - 6, cy - 6, 12, 12, 6, 1.6f, c);
                    r.Rect(cx + 2, cy - 8, 5, 4, Theme.Elevated);
                    r.Rect(cx + 3, cy - 7, 4, 1.6f, c);
                    r.Rect(cx + 5.4f, cy - 7, 1.6f, 4, c);
                }
            }
            StringBuilder info = new StringBuilder();
            info.Append(Device).Append("  ·  ").Append(ModelOf(Device));
            if (Fps > 0) info.Append("  ·  ").Append((long)Math.Round(Fps)).Append(" fps");
            r.Text(r.UiSmall, x + (w - r.TextWidth(r.UiSmall, info.View())) / 2, barY + 40, info.View(), Theme.TextTertiary);
            delete info;
            r.PopClip();
        }

        func Center(r: Renderer, x: float, w: float, y: float, title: string, hint: string)
        {
            r.Text(r.UiBold, x + (w - r.TextWidth(r.UiBold, title)) / 2, y, title, Theme.Text);
            r.Text(r.UiSmall, x + (w - r.TextWidth(r.UiSmall, hint)) / 2, y + 24, hint, Theme.TextTertiary);
        }

        public func Contains(px: float, py: float) -> bool => InScreen(px, py) || ButtonAt(px, py) >= 0;
    }
}
