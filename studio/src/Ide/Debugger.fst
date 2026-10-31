// =============================================================================
//  Depurador de FasetStudio: gdb por su interfaz de máquina (MI).
//
//  El compilador emite '#line N "archivo.fst"' en Debug (o con -g), así que gdb ya
//  trabaja con las líneas de Faset: este archivo solo traduce. FasetStudio lanza
//  'gdb --interpreter=mi3' como proceso hijo con tuberías, le envía órdenes con
//  número ("12-exec-next") y lee sin bloquear sus respuestas ("12^running") y
//  sus avisos asíncronos ("*stopped,reason=...", "=breakpoint-modified,...").
//
//  Nombres del C generado y cómo se muestran:
//    l_x / p_x / self              variable local / parámetro / this
//    f_Campo                       campo
//    fs_Ns_Clase__m_Metodo[_N]     Ns.Clase.Metodo
//    fs_Ns_Clase__ctorN / __dtor   constructor / destructor
//    fs_Ns_f_funcion               función de espacio de nombres
//    faset_string {ptr, len}       string (se lee el texto)
//    fs_std_collections_List_N*    List<T> (Count y elementos)
//
//  La salida del programa va a un archivo temporal que se vuelca en el panel de
//  Salida; los 'panic' (faset_panic_at / faset_panic) y las señales (SIGSEGV...)
//  detienen el programa en la línea de Faset que los provocó.
// =============================================================================
using std.collections;
using std.io;
using std.os;
using std.text;
using std.time;
using FasetStudio.Gfx;

namespace FasetStudio.Ide
{
    // ------------------------------------------------------------------ valores MI

    // Valor de una respuesta MI: cadena (Kind 0), tupla {a=..} (1) o lista [..] (2).
    public memory_unsafe class MiValue
    {
        public var Kind: int;
        public var Str: string = "";
        public var Names: List<string> = new List<string>();
        public var Items: List<MiValue> = new List<MiValue>();

        public prop Count: int => Items.Count;
        public func At(i: int) -> MiValue => i >= 0 && i < Items.Count ? Items[i] : null;

        public func Get(name: string) -> MiValue
        {
            for (int i = 0; i < Names.Count; i++)
                if (Names[i] == name) return Items[i];
            return null;
        }

        // Texto de un campo ("" si no existe o no es una cadena).
        public func S(name: string) -> string
        {
            MiValue v = Get(name);
            return v != null && v.Kind == 0 ? v.Str : "";
        }

        // Analiza "a=1,b={c="2"},d=[...]" (lo que sigue a la clase de un registro).
        public static func ParseResults(s: string, start: int) -> MiValue
        {
            MiValue t = new MiValue();
            t.Kind = 1;
            int pos = start;
            while (pos < s.Length)
            {
                if (s[pos] == ',')
                {
                    pos++;
                    continue;
                }
                string name;
                MiValue v = ParseResult(s, ref pos, out name);
                if (v == null) break;
                t.Names.Add(name);
                t.Items.Add(v);
            }
            return t;
        }

        static func ParseResult(s: string, ref pos: int, out name: string) -> MiValue
        {
            int eq = pos;
            while (eq < s.Length && s[eq] != '=' && s[eq] != ',' && s[eq] != '{' && s[eq] != '"' && s[eq] != '[') eq++;
            if (eq < s.Length && s[eq] == '=')
            {
                name = String.Copy(s.Substring(pos, eq - pos));
                pos = eq + 1;
            }
            else name = "";
            return ParseValue(s, ref pos);
        }

        static func ParseValue(s: string, ref pos: int) -> MiValue
        {
            if (pos >= s.Length) return null;
            MiValue v = new MiValue();
            byte c = s[pos];
            if (c == '"')
            {
                v.Str = ParseCString(s, ref pos);
                return v;
            }
            if (c == '{' || c == '[')
            {
                byte close = c == '{' ? (byte)'}' : (byte)']';
                v.Kind = c == '{' ? 1 : 2;
                pos++;
                while (pos < s.Length && s[pos] != close)
                {
                    if (s[pos] == ',')
                    {
                        pos++;
                        continue;
                    }
                    string name;
                    MiValue item = ParseResult(s, ref pos, out name);
                    if (item == null) break;
                    v.Names.Add(name);
                    v.Items.Add(item);
                }
                if (pos < s.Length) pos++;
                return v;
            }
            // Valor sin comillas (no debería ocurrir): hasta la próxima coma.
            int end = pos;
            while (end < s.Length && s[end] != ',' && s[end] != '}' && s[end] != ']') end++;
            v.Str = String.Copy(s.Substring(pos, end - pos));
            pos = end;
            return v;
        }

        // Cadena C de MI: \" \\ \n \t y \NNN (octal, bytes UTF-8).
        public static func ParseCString(s: string, ref pos: int) -> string
        {
            pos++;  // comilla inicial
            byte* buf = (byte*)Memory.Alloc(s.Length + 1);
            int n = 0;
            while (pos < s.Length && s[pos] != '"')
            {
                byte c = s[pos];
                if (c == '\\' && pos + 1 < s.Length)
                {
                    byte e = s[pos + 1];
                    pos += 2;
                    if (e == 'n') buf[n++] = 10;
                    else if (e == 't') buf[n++] = 9;
                    else if (e == 'r') buf[n++] = 13;
                    else if (e >= '0' && e <= '7')
                    {
                        int val = e - '0';
                        for (int k = 0; k < 2 && pos < s.Length && s[pos] >= '0' && s[pos] <= '7'; k++)
                        {
                            val = val * 8 + (s[pos] - '0');
                            pos++;
                        }
                        buf[n++] = (byte)val;
                    }
                    else buf[n++] = e;
                    continue;
                }
                buf[n++] = c;
                pos++;
            }
            if (pos < s.Length) pos++;  // comilla final
            string r = String.Copy(String.FromBytes(buf, n));
            Memory.Free(buf);
            return r;
        }
    }

    // ------------------------------------------------------------------ modelo

    public class DbgBreakpoint
    {
        public var Path: string = "";       // ruta absoluta del .fst
        public var Line: int;               // 0..n-1
        public var Condition: string = "";  // expresión de Faset ("" = siempre)
        public var Number: int;             // número en gdb (0 = sin insertar)
        public var Verified: bool;          // gdb encontró código en esa línea
    }

    public class DbgFrame
    {
        public var Level: int;
        public var Func: string = "";    // nombre de Faset (Jugador.Atacar)
        public var CFunc: string = "";   // nombre en C
        public var Path: string = "";    // ruta completa ("" si no hay fuente)
        public var Line: int;            // 0..n-1
        public prop IsUser: bool => Path.EndsWith(".fst");
    }

    public class DbgVar
    {
        public var Name: string = "";      // nombre de Faset
        public var Value: string = "";     // texto mostrado
        public var Type: string = "";      // tipo de Faset (o de C si no se reconoce)
        public var CType: string = "";
        public var Expr: string = "";      // expresión de C para gdb
        public var Path: string = "";      // ruta en el árbol (para recordar lo expandido)
        public var Depth: int;
        public var Expandable: bool;
        public var Expanded: bool;
        public var Loaded: bool;
        public var IsPointer: bool;
        public var IsList: bool;
        public var Changed: bool;          // cambió desde la última parada
        public var Error: bool;
        public var Children: List<DbgVar> = new List<DbgVar>();
    }

    // Acceso desde EditorView a los puntos de interrupción y a la línea actual.
    public static class DebugMarks
    {
        public static var Session: Debugger;

        // Fondo de la línea donde está detenido el programa (antes del texto).
        public static func Background(r: Renderer, path: string, line: int, x: float, y: float, w: float, h: float)
        {
            Debugger d = Session;
            if (d == null || !d.Stopped || d.StopLine != line || d.StopPath != path) return;
            Color c = d.SelectedFrame != d.TopFrame ? Color.Hex(0x6fb36f, 0.14f)
                    : d.StopMessage.Length > 0 ? Color.Hex(0xf04f4f, 0.18f) : Color.Hex(0xe0b341, 0.16f);
            r.Rect(x, y, w, h, c);
        }

        // Punto rojo del punto de interrupción y flecha amarilla de la línea actual (margen izquierdo).
        public static func Gutter(r: Renderer, path: string, line: int, x: float, y: float, lh: float)
        {
            Debugger d = Session;
            if (d == null) return;
            float cw = r.Code.CharWidth;
            float size = (float)Math.Min((double)lh * 0.62, (double)cw * 1.5);
            float cx = x + cw * 1.05f, cy = y + lh / 2;
            int bi = d.BreakpointAt(path, line);
            if (bi >= 0)
            {
                DbgBreakpoint bp = d.Breakpoints[bi];
                Color red = Color.Hex(0xe5484d);
                if (d.Active && !bp.Verified) r.RoundBorder(cx - size / 2, cy - size / 2, size, size, size / 2, 1.6f, red);
                else r.RoundRect(cx - size / 2, cy - size / 2, size, size, size / 2, red);
                if (bp.Condition.Length > 0) r.RoundRect(cx - 2, cy - 1, 4, 2, 1, Theme.White);   // condicional: raya blanca
            }
            if (d.Stopped && d.StopLine == line && d.StopPath == path)
            {
                Color c = d.SelectedFrame == d.TopFrame ? Color.Hex(0xf2c94c) : Color.Hex(0x7cc47c);
                float ax = cx - size * 0.55f, aw = size * 0.55f, ah = size * 0.42f;
                r.RoundRect(ax, cy - ah / 2, aw, ah, 1, c);
                // Punta de la flecha: triángulo con rectángulos cada vez más estrechos.
                float tip = size * 0.6f;
                for (int k = 0; k < 6; k++)
                {
                    float t = k / 6.0f;
                    float hh = size * 0.9f * (1 - t);
                    r.Rect(ax + aw + t * tip, cy - hh / 2, tip / 6 + 0.6f, hh, c);
                }
            }
        }
    }

    // ------------------------------------------------------------------ sesión

    public memory_unsafe class Debugger
    {
        // Estado público (lo lee el IDE)
        public var Active: bool;         // hay una sesión de gdb
        public var Stopped: bool;        // el programa está detenido
        public var Running: bool;        // el programa está ejecutándose
        public var StopPath: string = "";    // archivo y línea del marco seleccionado
        public var StopLine: int = -1;
        public var StopMessage: string = ""; // panic, señal o ""
        public var StopChanged: bool;    // nueva parada (el IDE abre el archivo y la consume)
        public var Ended: bool;          // la sesión terminó (el IDE la consume)
        public var Status: string = "";  // mensaje para la barra de estado (el IDE lo consume)
        public var SelectedFrame: int;
        public var TopFrame: int;        // marco donde se detuvo (el primero de Faset si fue un panic o una señal)
        public var Breakpoints: List<DbgBreakpoint> = new List<DbgBreakpoint>();
        public var Frames: List<DbgFrame> = new List<DbgFrame>();
        public var Variables: List<DbgVar> = new List<DbgVar>();
        public var WatchExprs: List<string> = new List<string>();
        public var Watches: List<DbgVar> = new List<DbgVar>();
        public var Output: StringBuilder;      // panel de Salida del IDE
        public var BreakpointsChanged: bool;   // hay que guardarlos (el IDE lo consume)
        public var JustMyCode: bool = true;    // paso a paso sin entrar en la biblioteca estándar

        // Paneles: desplazamiento y filas visibles del último dibujo
        public var VarsScroll: int;
        public var StackScroll: int;
        public var WatchScroll: int;
        var varRows: List<DbgVar> = new List<DbgVar>();
        var watchRows: List<DbgVar> = new List<DbgVar>();

        var gdb: Process;
        var gdbPath: string = "";
        var searched: bool;
        var inBuf: StringBuilder = new StringBuilder();
        var console: StringBuilder = new StringBuilder();     // salida de consola (~"...") de la última orden
        var pending: List<string> = new List<string>();   // registros asíncronos por atender
        var nextToken: int = 1;
        var lastError: string = "";
        var pid: int;
        var outFile: string = "";
        var outOffset: int;
        var lastOutputPoll: long;
        var panicBps: List<int> = new List<int>();
        var lastStep: int;               // 1 next, 2 step, 3 finish (para atravesar código sin .fst)
        var autoSteps: int;
        var frameNames: List<string> = new List<string>();   // nombres de C de las variables del marco
        var frameHasSelf: bool;
        var prevValues: Dictionary<string, string> = new Dictionary<string, string>();
        var curValues: Dictionary<string, string> = new Dictionary<string, string>();
        var expanded: List<string> = new List<string>();     // rutas expandidas (se conservan entre pasos)

        public init() { DebugMarks.Session = this; }

        // ------------------------------------------------------------------ gdb

        // Ruta de gdb ("" si no está instalado).
        public func DebuggerPath() -> string
        {
            if (!searched)
            {
                searched = true;
                string found;
                if (Process.Capture(OS.IsWindows ? "where gdb.exe" : "command -v gdb", out found) == 0 && found.Trim().Length > 0)
                {
                    // 'where' (Windows) puede listar varias coincidencias: vale la primera línea.
                    string first = found.Trim();
                    int nl = first.IndexOf("\n");
                    if (nl > 0) first = first.Substring(0, nl).Trim();
                    gdbPath = String.Copy(first);
                }
            }
            return gdbPath;
        }

        // Arranca gdb con el ejecutable y lo pone en marcha. false (y Status) si no se pudo.
        public func Start(exe: string, cwd: string) -> bool
        {
            if (Active) Stop();
            string path = DebuggerPath();
            if (path.Length == 0)
            {
                Status = "gdb was not found: install it (e.g. sudo apt install gdb) to debug";
                Say(L.T("gdb was not found: install it (e.g. sudo apt install gdb) to debug"));
                return false;
            }
            ProcessStartInfo si = new ProcessStartInfo(path);
            si.AddArgument("--interpreter=mi3").AddArgument("-q").AddArgument("-nx").AddArgument(exe);
            si.RedirectStandardInput = true;
            si.RedirectStandardOutput = true;
            si.MergeStandardError = true;
            si.NewProcessGroup = true;
            si.CreateNoWindow = true;
            si.WorkingDirectory = cwd;
            si.SetEnvironment("LC_ALL", "C.UTF-8");   // mensajes en inglés y cadenas en UTF-8
            gdb = Process.Start(si);
            delete si;
            if (gdb == null)
            {
                Status = "Could not start gdb";
                return false;
            }
            Active = true;
            Stopped = false;
            Running = false;
            Ended = false;
            inBuf.Clear();
            pending.Clear();
            panicBps.Clear();
            Frames.Clear();
            Variables.Clear();
            Watches.Clear();
            StopMessage = "";
            StopLine = -1;
            pid = 0;
            if (Request("-gdb-set mi-async on") == null)
            {
                Say(L.T("gdb does not answer: is it version 9 or newer?"));
                Shutdown();
                return false;
            }
            Request("-gdb-set confirm off");
            Request("-gdb-set pagination off");
            Request("-gdb-set print elements 400");
            Request("-gdb-set print repeats unlimited");
            Request("-gdb-set debuginfod enabled off");
            // El runtime de C (faset_*) se salta al avanzar: 'paso a paso' entra solo en código de Faset.
            // "Solo mi código": también se salta la biblioteca estándar (fs_std_*).
            Request(JustMyCode ? "-interpreter-exec console \"skip -rfu ^(faset_|fs__|fs_std_)\""
                               : "-interpreter-exec console \"skip -rfu ^(faset_|fs__)\"");
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-environment-cd ").Append(Q(cwd));
            Request(cmd.View());
            // Salida del programa a un archivo (se vuelca en el panel de Salida) y sin entrada estándar.
            outFile = Path.Combine(Path.GetTempPath(), String.Concat("fasetstudio-debug-", String.FromInt(Process.CurrentId), ".out"));
            File.Delete(outFile);
            File.WriteAllText(outFile, "");
            outOffset = 0;
            cmd.Clear();
            // gdb para Windows también entiende estas redirecciones (con NUL en vez de /dev/null).
            if (OS.IsWindows) cmd.Append("-exec-arguments > ").Append(Q(outFile)).Append(" 2>&1 < NUL");
            else cmd.Append("-exec-arguments > ").Append(ShellQuote(outFile)).Append(" 2>&1 < /dev/null");
            Request(cmd.View());
            delete cmd;
            for (int i = 0; i < Breakpoints.Count; i++) Insert(Breakpoints[i]);
            InsertPanic("faset_panic_at");
            InsertPanic("faset_panic");
            if (Request("-exec-run") == null)
            {
                Say(lastError);
                Shutdown();
                return false;
            }
            Running = true;
            Status = "Debugging…";
            return true;
        }

        void InsertPanic(string func)
        {
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-break-insert -f ").Append(func);
            MiValue r = Request(cmd.View());
            delete cmd;
            if (r == null) return;
            MiValue b = r.Get("bkpt");
            if (b != null) panicBps.Add(b.S("number").ToInt());
        }

        // Termina la sesión (mata el programa).
        public func Stop()
        {
            if (!Active) return;
            Say(L.T("[debugging stopped]"));
            Status = "Debugging stopped";
            Shutdown();
        }

        func Shutdown()
        {
            if (gdb != null)
            {
                if (!gdb.HasExited)
                {
                    if (Running) Write("-exec-interrupt");
                    Write("-gdb-exit");
                    gdb.WaitForExit(1500);
                    if (!gdb.HasExited)
                    {
                        if (pid > 0)
                        {
                            string ignored;
                            Process.Capture(String.Concat(OS.IsWindows ? "taskkill /F /T /PID " : "kill -9 ", String.FromInt(pid)), out ignored);
                        }
                        gdb.Kill();
                        gdb.WaitForExit(500);
                    }
                }
                delete gdb;
                gdb = null;
            }
            PollOutput(true);
            if (outFile.Length > 0) File.Delete(outFile);
            outFile = "";
            Active = false;
            Stopped = false;
            Running = false;
            StopLine = -1;
            StopPath = "";
            Frames.Clear();
            Variables.Clear();
            Watches.Clear();
            for (int i = 0; i < Breakpoints.Count; i++)
            {
                Breakpoints[i].Number = 0;
                Breakpoints[i].Verified = false;
            }
            Ended = true;
        }

        func Say(text: string)
        {
            if (Output == null || text.Length == 0) return;
            if (Output.Length > 0 && Output.View()[Output.Length - 1] != '\n') Output.Append("\n");
            Output.Append(text).Append("\n");
        }

        static func Q(s: string) -> string
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("\"");
            for (int i = 0; i < s.Length; i++)
            {
                byte c = s[i];
                if (c == '"' || c == '\\') sb.Append("\\");
                sb.Append(s.Substring(i, 1));
            }
            sb.Append("\"");
            string r = sb.ToString();
            delete sb;
            return r;
        }

        static func ShellQuote(s: string) -> string => String.Concat("'", Text.Replace(s, "'", "'\\''"), "'");

        func Write(cmd: string)
        {
            if (gdb == null) return;
            Trace("> ", cmd);
            gdb.WriteInput(cmd);
            gdb.WriteInput("\n");
        }

        // FASET_DEBUG_MI=<archivo>: copia el diálogo con gdb (para diagnosticar el depurador).
        var traceFile: string = "";
        var traceChecked: bool;
        func Trace(dir: string, text: string)
        {
            if (!traceChecked)
            {
                traceChecked = true;
                traceFile = Environment.GetVariable("FASET_DEBUG_MI");
            }
            if (traceFile.Length > 0) File.AppendAllText(traceFile, String.Concat(dir, text, "\n"));
        }

        // Siguiente línea completa de gdb (copia).
        func NextLine(out line: string) -> bool
        {
            if (gdb != null) gdb.ReadOutput(inBuf);
            string all = inBuf.View();
            int nl = all.IndexOf("\n");
            if (nl < 0)
            {
                line = "";
                return false;
            }
            int end = nl > 0 && all[nl - 1] == 13 ? nl - 1 : nl;
            line = String.Copy(all.Substring(0, end));
            Trace("< ", line);
            string rest = String.Copy(all.Substring(nl + 1));
            inBuf.Clear();
            inBuf.Append(rest);
            return true;
        }

        // Orden síncrona: espera su respuesta (^done, ^running...) y guarda los avisos que lleguen
        // mientras tanto. null si gdb respondió ^error (el mensaje queda en lastError).
        func Request(cmd: string) -> MiValue
        {
            if (gdb == null) return null;
            int token = nextToken++;
            string tok = String.FromInt(token);
            console.Clear();
            StringBuilder sb = new StringBuilder();
            sb.Append(tok).Append(cmd);
            Write(sb.View());
            delete sb;
            long deadline = Environment.TickCount64() + 8000;
            while (Environment.TickCount64() < deadline)
            {
                string line;
                while (NextLine(out line))
                {
                    if (line.Length > tok.Length && line.StartsWith(tok) && line[tok.Length] == '^')
                    {
                        int comma = line.IndexOf(",", tok.Length);
                        string cls = comma < 0 ? line.Substring(tok.Length + 1) : line.Substring(tok.Length + 1, comma - tok.Length - 1);
                        MiValue v = MiValue.ParseResults(line, comma < 0 ? line.Length : comma + 1);
                        if (cls == "error")
                        {
                            lastError = String.Copy(v.S("msg"));
                            return null;
                        }
                        return v;
                    }
                    if (line.StartsWith("*") || line.StartsWith("=") || line.StartsWith("@")) pending.Add(line);
                    else if (line.StartsWith("~"))
                    {
                        int p = 1;
                        console.Append(MiValue.ParseCString(line, ref p));
                    }
                }
                if (gdb.HasExited)
                {
                    lastError = "gdb terminated";
                    return null;
                }
                gdb.WaitForOutput(10);
            }
            lastError = "gdb did not answer in time";
            return null;
        }

        // ------------------------------------------------------------------ bucle

        // Atiende a gdb sin bloquear. true si cambió algo que haya que redibujar.
        public func Update() -> bool
        {
            if (!Active) return false;
            bool changed = false;
            string line;
            while (NextLine(out line))
                if (line.StartsWith("*") || line.StartsWith("=") || line.StartsWith("@")) pending.Add(line);
            while (pending.Count > 0)
            {
                string rec = pending[0];
                pending.RemoveAt(0);
                Handle(rec);
                changed = true;
                if (!Active) return true;
            }
            if (gdb != null && gdb.HasExited && Active)
            {
                Say(L.T("[gdb terminated]"));
                Shutdown();
                return true;
            }
            if (PollOutput(false)) changed = true;
            return changed;
        }

        // Copia al panel de Salida lo nuevo que escribió el programa.
        func PollOutput(force: bool) -> bool
        {
            if (outFile.Length == 0 || Output == null) return false;
            long now = Environment.TickCount64();
            if (!force && now - lastOutputPoll < 120) return false;
            lastOutputPoll = now;
            string text;
            if (!File.TryReadAllText(outFile, out text)) return false;
            if (text.Length <= outOffset) return false;
            Output.Append(text.Substring(outOffset));
            outOffset = text.Length;
            return true;
        }

        func Handle(rec: string)
        {
            int comma = rec.IndexOf(",");
            string cls = comma < 0 ? rec.Substring(1) : rec.Substring(1, comma - 1);
            MiValue v = MiValue.ParseResults(rec, comma < 0 ? rec.Length : comma + 1);
            if (rec.StartsWith("@"))
            {
                int p = 1;
                if (Output != null) Output.Append(MiValue.ParseCString(rec, ref p));
                return;
            }
            if (cls == "running")
            {
                Running = true;
                Stopped = false;
            }
            else if (cls == "stopped") OnStopped(v);
            else if (cls == "thread-group-started") pid = v.S("pid").ToInt();
            else if (cls == "breakpoint-modified" || cls == "breakpoint-created")
            {
                MiValue b = v.Get("bkpt");
                if (b != null) UpdateFromGdb(b);
            }
        }

        func OnStopped(v: MiValue)
        {
            string reason = v.S("reason");
            Running = false;
            if (reason.StartsWith("exited"))
            {
                // exit-code viene en octal ("01" = 1)
                string oct = v.S("exit-code");
                int code = 0;
                for (int i = 0; i < oct.Length; i++) code = code * 8 + (oct[i] - '0');
                PollOutput(true);
                string text = L.F("[program exited with code {0}]", String.FromInt(code), "");
                Say(text);
                Status = code == 0 ? "Program finished successfully" : "Program exited with errors";
                Shutdown();
                return;
            }
            if (reason == "exited-signalled")
            {
                Say(String.Concat("[", v.S("signal-name"), "]"));
                Shutdown();
                return;
            }
            Request("-stack-select-frame 0");
            LoadFrames();
            int top = 0;
            for (int i = 0; i < Frames.Count && top == 0 && !Frames[0].IsUser; i++)
                if (Frames[i].IsUser) top = i;
            // Paso a paso que cayó en código sin fuente de Faset (constructores auxiliares, main de C):
            // se sigue avanzando hasta volver a un .fst.
            bool stepping = reason == "end-stepping-range" || reason == "function-finished";
            if (stepping && Frames.Count > 0 && !Frames[0].IsUser && autoSteps < 40)
            {
                autoSteps++;
                bool anyUser = false;
                for (int i = 0; i < Frames.Count; i++)
                    if (Frames[i].IsUser) anyUser = true;
                if (!anyUser || Frames[0].CFunc == "main") Resume("-exec-continue", 0);
                else Resume(lastStep == 2 ? "-exec-step" : lastStep == 3 ? "-exec-finish" : "-exec-next", lastStep);
                return;
            }
            autoSteps = 0;
            if (Request("-data-evaluate-expression \"(int)fflush(0)\"") == null) { }
            PollOutput(true);
            StopMessage = "";
            bool panic = false;
            if (reason == "breakpoint-hit")
            {
                int no = v.S("bkptno").ToInt();
                for (int i = 0; i < panicBps.Count; i++)
                    if (panicBps[i] == no) panic = true;
            }
            if (panic)
            {
                string msg = Evaluate("*msg.ptr@msg.len");
                StopMessage = String.Concat("Faset panic: ", Unquote(msg));
            }
            else if (reason == "signal-received")
            {
                string name = v.S("signal-name");
                StopMessage = name == "SIGINT" ? "" : name + " (" + v.S("signal-meaning") + ")";
                if (name == "SIGINT") Status = "Paused";
            }
            else top = 0;
            if (StopMessage.Length > 0)
            {
                Say(StopMessage);
                Status = panic ? "The program panicked" : "The program received a signal";
            }
            Stopped = true;
            SwapValues();
            TopFrame = top;
            SelectFrame(top);
            StopChanged = true;
        }

        func SwapValues()
        {
            Dictionary<string, string> t = prevValues;
            prevValues = curValues;
            curValues = t;
            curValues.Clear();
        }

        static func Unquote(s: string) -> string
        {
            string t = s.Trim();
            int q1 = t.IndexOf("\"");
            int q2 = t.LastIndexOf("\"");
            if (q1 >= 0 && q2 > q1) return String.Copy(t.Substring(q1 + 1, q2 - q1 - 1));
            return String.Copy(t);
        }

        func LoadFrames()
        {
            Frames.Clear();
            MiValue r = Request("-stack-list-frames 0 63");
            if (r == null) return;
            MiValue stack = r.Get("stack");
            if (stack == null) return;
            for (int i = 0; i < stack.Count; i++)
            {
                MiValue f = stack.At(i);
                DbgFrame fr = new DbgFrame();
                fr.Level = f.S("level").ToInt();
                fr.CFunc = String.Copy(f.S("func"));
                fr.Func = Demangle(fr.CFunc);
                fr.Path = String.Copy(f.S("fullname"));
                string ln = f.S("line");
                fr.Line = ln.Length > 0 ? ln.ToInt() - 1 : -1;
                // Por debajo del main de C solo queda la biblioteca de C.
                if (fr.CFunc == "main" && !fr.IsUser) break;
                Frames.Add(fr);
            }
        }

        // Selecciona un marco de la pila: variables, inspecciones y línea mostrada.
        public func SelectFrame(index: int)
        {
            if (!Stopped || index < 0 || index >= Frames.Count) return;
            SelectedFrame = index;
            DbgFrame f = Frames[index];
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-stack-select-frame ").Append((long)f.Level);
            Request(cmd.View());
            delete cmd;
            StopPath = f.Path;
            StopLine = f.Line;
            LoadVariables();
            RefreshWatches();
        }

        func Resume(cmd: string, step: int)
        {
            if (!Active) return;
            if (SelectedFrame != 0) Request("-stack-select-frame 0");
            lastStep = step;
            if (Request(cmd) == null)
            {
                Status = "";
                Say(lastError);
                return;
            }
            Stopped = false;
            Running = true;
        }

        public func Continue() { if (Stopped) { autoSteps = 0; Resume("-exec-continue", 0); } }
        public func StepOver() { if (Stopped) { autoSteps = 0; Resume("-exec-next", 1); } }
        public func StepInto() { if (Stopped) { autoSteps = 0; Resume("-exec-step", 2); } }
        public func StepOut()
        {
            if (!Stopped) return;
            autoSteps = 0;
            // En Main (el último marco de Faset) 'salir' termina el programa.
            int users = 0;
            for (int i = 0; i < Frames.Count; i++)
                if (Frames[i].IsUser) users++;
            Resume(users <= 1 ? "-exec-continue" : "-exec-finish", 3);
        }
        public func Pause() { if (Active && Running) Request("-exec-interrupt"); }

        // ------------------------------------------------------------------ puntos de interrupción

        public func BreakpointAt(path: string, line: int) -> int
        {
            for (int i = 0; i < Breakpoints.Count; i++)
                if (Breakpoints[i].Line == line && Breakpoints[i].Path == path) return i;
            return -1;
        }

        public func ToggleBreakpoint(path: string, line: int)
        {
            int i = BreakpointAt(path, line);
            if (i >= 0) RemoveBreakpoint(i);
            else AddBreakpoint(path, line, "");
        }

        // Se insertaron (delta > 0) o borraron (delta < 0) líneas a partir de 'line': los puntos que
        // quedan debajo se mueven con su código (en gdb se aplican en la próxima sesión).
        public func ShiftBreakpoints(path: string, line: int, delta: int)
        {
            bool any = false;
            for (int i = Breakpoints.Count - 1; i >= 0; i--)
            {
                DbgBreakpoint b = Breakpoints[i];
                if (b.Path != path || b.Line <= line) continue;
                if (delta < 0 && b.Line <= line - delta)
                {
                    // Su línea desapareció: queda en la línea donde se unió el texto (o se quita si ya hay otro).
                    if (BreakpointAt(path, line) >= 0) { Breakpoints.RemoveAt(i); any = true; continue; }
                    b.Line = line;
                }
                else b.Line += delta;
                any = true;
            }
            if (any) BreakpointsChanged = true;
        }

        public func AddBreakpoint(path: string, line: int, condition: string)
        {
            if (BreakpointAt(path, line) >= 0) return;
            DbgBreakpoint b = new DbgBreakpoint();
            b.Path = String.Copy(path);
            b.Line = line;
            b.Condition = String.Copy(condition);
            Breakpoints.Add(b);
            if (Active) Insert(b);
            BreakpointsChanged = true;
        }

        public func RemoveBreakpoint(i: int)
        {
            if (i < 0 || i >= Breakpoints.Count) return;
            DbgBreakpoint b = Breakpoints[i];
            if (Active && b.Number > 0)
            {
                StringBuilder cmd = new StringBuilder();
                cmd.Append("-break-delete ").Append((long)b.Number);
                Request(cmd.View());
                delete cmd;
            }
            Breakpoints.RemoveAt(i);
            BreakpointsChanged = true;
        }

        public func SetCondition(i: int, condition: string)
        {
            if (i < 0 || i >= Breakpoints.Count) return;
            DbgBreakpoint b = Breakpoints[i];
            b.Condition = String.Copy(condition.Trim());
            if (Active && b.Number > 0)
            {
                StringBuilder cmd = new StringBuilder();
                cmd.Append("-break-condition ").Append((long)b.Number);
                if (b.Condition.Length > 0) cmd.Append(" ").Append(ConditionToC(b));
                Request(cmd.View());
                delete cmd;
            }
            BreakpointsChanged = true;
        }

        func Insert(b: DbgBreakpoint)
        {
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-break-insert -f ");
            if (b.Condition.Length > 0) cmd.Append("-c ").Append(Q(ConditionToC(b))).Append(" ");
            StringBuilder loc = new StringBuilder();
            loc.Append(b.Path).Append(":").Append((long)(b.Line + 1));
            cmd.Append(Q(loc.View()));
            delete loc;
            MiValue r = Request(cmd.View());
            delete cmd;
            if (r == null) return;
            MiValue bk = r.Get("bkpt");
            if (bk == null) return;
            b.Number = bk.S("number").ToInt();
            ApplyLocation(b, bk);
        }

        // La condición se escribe en Faset; los nombres de C se buscan con 'info scope' en esa línea
        // (las variables visibles allí: l_i, p_x, self...).
        func ConditionToC(b: DbgBreakpoint) -> string
        {
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-interpreter-exec console ").Append(Q(String.Concat("info scope ", b.Path, ":") + String.FromInt(b.Line + 1)));
            Request(cmd.View());
            delete cmd;
            List<string> saved = frameNames;
            bool savedSelf = frameHasSelf;
            frameNames = new List<string>();
            frameHasSelf = false;
            List<string> lines = Text.Split(console.View(), "\n");
            for (int i = 0; i < lines.Count; i++)
            {
                string l = lines[i].Trim();
                if (!l.StartsWith("Symbol ")) continue;
                int sp = l.IndexOf(" ", 7);
                if (sp < 0) continue;
                string name = String.Copy(l.Substring(7, sp - 7));
                frameNames.Add(name);
                if (name == "self") frameHasSelf = true;
            }
            delete lines;
            string r = FasetToC(b.Condition, false);
            frameNames = saved;
            frameHasSelf = savedSelf;
            return r;
        }

        func UpdateFromGdb(bk: MiValue)
        {
            int no = bk.S("number").ToInt();
            for (int i = 0; i < Breakpoints.Count; i++)
                if (Breakpoints[i].Number == no) ApplyLocation(Breakpoints[i], bk);
        }

        // gdb mueve el punto a la primera línea con código: se refleja en el editor.
        func ApplyLocation(b: DbgBreakpoint, bk: MiValue)
        {
            string ln = bk.S("line");
            if (ln.Length == 0)
            {
                MiValue locs = bk.Get("locations");
                if (locs != null && locs.Count > 0) ln = locs.At(0).S("line");
            }
            b.Verified = ln.Length > 0;
            if (ln.Length > 0)
            {
                int line = ln.ToInt() - 1;
                if (line != b.Line && line >= 0 && BreakpointAt(b.Path, line) < 0)
                {
                    b.Line = line;
                    BreakpointsChanged = true;
                }
            }
        }

        // Guardado: "ruta\tlínea\tcondición\t..." (rutas relativas a 'root').
        public func Serialize(root: string) -> string
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < Breakpoints.Count; i++)
            {
                DbgBreakpoint b = Breakpoints[i];
                string p = b.Path.StartsWith(root) && b.Path.Length > root.Length + 1 ? b.Path.Substring(root.Length + 1) : b.Path;
                if (i > 0) sb.Append("\t");
                sb.Append(p).Append("\t").Append((long)(b.Line + 1)).Append("\t").Append(Text.Replace(b.Condition, "\t", " "));
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public func Deserialize(root: string, data: string)
        {
            Breakpoints.Clear();
            if (data.Trim().Length == 0) return;
            List<string> parts = Text.Split(data, "\t");
            for (int i = 0; i + 1 < parts.Count; i += 3)
            {
                string p = parts[i].Trim();
                int line = 0;
                if (p.Length == 0 || !Convert.TryToInt32(parts[i + 1].Trim(), out line) || line <= 0) continue;
                string full = p.StartsWith("/") ? String.Copy(p) : Path.Combine(root, p);
                AddBreakpoint(full, line - 1, i + 2 < parts.Count ? parts[i + 2] : "");
            }
            delete parts;
            BreakpointsChanged = false;
        }

        // ------------------------------------------------------------------ variables

        // Valor de una expresión de C ("" si gdb no puede evaluarla).
        func Evaluate(cexpr: string) -> string
        {
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-data-evaluate-expression ").Append(Q(cexpr));
            MiValue r = Request(cmd.View());
            delete cmd;
            return r == null ? "" : String.Copy(r.S("value"));
        }

        func LoadVariables()
        {
            Variables.Clear();
            frameNames.Clear();
            frameHasSelf = false;
            MiValue r = Request("-stack-list-variables --simple-values");
            if (r == null) return;
            MiValue list = r.Get("variables");
            if (list == null) return;
            bool user = SelectedFrame < Frames.Count && Frames[SelectedFrame].IsUser;
            int here = SelectedFrame < Frames.Count ? Frames[SelectedFrame].Line + 1 : 0;
            // Líneas donde se declaran las variables (DWARF, con el Python de gdb): en C la variable existe
            // en todo su bloque, pero en Faset aún no se ha declarado; esas se ocultan (tendrían basura).
            Dictionary<string, int> declLines = new Dictionary<string, int>();
            if (user)
            {
                Request("-interpreter-exec console \"python exec(\\\"b = gdb.selected_frame().block()\\\\nwhile b is not None:\\\\n  for s in b:\\\\n    print('@decl', s.name, s.line)\\\\n  if b.function is not None: break\\\\n  b = b.superblock\\\")\"");
                List<string> lines = Text.Split(console.View(), "\n");
                for (int i = 0; i < lines.Count; i++)
                {
                    List<string> f = Text.Split(lines[i].Trim(), " ");
                    if (f.Count == 3 && f[0] == "@decl" && !declLines.ContainsKey(f[1])) declLines.Set(String.Copy(f[1]), f[2].ToInt());
                    delete f;
                }
                delete lines;
            }
            for (int i = 0; i < list.Count; i++)
            {
                MiValue item = list.At(i);
                string cname = item.S("name");
                if (frameNames.Contains(cname)) continue;   // bloques hermanos con el mismo nombre
                frameNames.Add(String.Copy(cname));
                if (cname == "self") frameHasSelf = true;
                string shown = FasetName(cname);
                if (user && shown.Length == 0) continue;   // temporales del C generado
                int decl = 0;
                if (user && cname.StartsWith("l_") && declLines.TryGetValue(cname, out decl) && decl > here) continue;
                DbgVar v = new DbgVar();
                v.Name = shown.Length > 0 ? shown : String.Copy(cname);
                v.Expr = String.Copy(cname);
                v.Path = String.Copy(v.Name);
                Describe(v, item.S("type"), item.S("value"));
                Variables.Add(v);
            }
            for (int i = 0; i < Variables.Count; i++) Restore(Variables[i]);
        }

        // Vuelve a expandir lo que el usuario tenía abierto.
        func Restore(v: DbgVar)
        {
            if (!v.Expandable || !expanded.Contains(v.Path) || v.Depth > 6) return;
            LoadChildren(v);
            v.Expanded = true;
            for (int i = 0; i < v.Children.Count; i++) Restore(v.Children[i]);
        }

        public func Toggle(v: DbgVar)
        {
            if (!v.Expandable || !Stopped) return;
            if (v.Expanded)
            {
                v.Expanded = false;
                expanded.Remove(v.Path);
                return;
            }
            if (!v.Loaded) LoadChildren(v);
            v.Expanded = true;
            if (!expanded.Contains(v.Path)) expanded.Add(String.Copy(v.Path));
        }

        // Nodo para una expresión de C (tipo y valor con -var-create).
        func MakeNode(name: string, cexpr: string, path: string, depth: int) -> DbgVar
        {
            DbgVar v = new DbgVar();
            v.Name = String.Copy(name);
            v.Expr = String.Copy(cexpr);
            v.Path = String.Copy(path);
            v.Depth = depth;
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-var-create - * ").Append(Q(cexpr));
            MiValue r = Request(cmd.View());
            if (r == null)
            {
                v.Value = String.Copy(lastError);
                v.Error = true;
                delete cmd;
                return v;
            }
            cmd.Clear();
            cmd.Append("-var-delete ").Append(r.S("name"));
            Request(cmd.View());
            delete cmd;
            Describe(v, r.S("type"), r.S("value"));
            return v;
        }

        func Describe(v: DbgVar, ctype: string, raw: string)
        {
            string t = ctype.Trim();
            if (t.StartsWith("const ")) t = t.Substring(6);
            v.CType = String.Copy(t);
            if (t == "faset_string")
            {
                v.Type = "string";
                v.Value = StringValue(v.Expr);
            }
            else if (t.EndsWith("*"))
            {
                string bt = t.Substring(0, t.Length - 1).Trim();
                bool isNull = raw == "0x0" || raw.StartsWith("0x0 ");
                if (bt.StartsWith("fs_"))
                {
                    v.Type = TypeName(bt);
                    v.IsPointer = true;
                    v.IsList = bt.Contains("collections_List_");
                    if (raw.Length == 0) raw = Evaluate(String.Concat("(long)", v.Expr));
                    if (isNull || raw == "0")
                    {
                        v.Value = "null";
                        v.Expandable = false;
                    }
                    else
                    {
                        v.Expandable = true;
                        if (v.IsList)
                        {
                            string n = Evaluate(String.Concat("(", v.Expr, ")->f_count"));
                            v.Value = String.Concat("Count = ", n);
                            string inner = ListElementType(v.Expr);
                            v.Type = String.Concat("List<", inner, ">");
                        }
                        else v.Value = String.Concat("{", v.Type, "}");
                    }
                }
                else
                {
                    v.Type = CTypeName(bt);
                    v.Type = String.Concat(v.Type, "*");
                    v.Value = isNull ? "null" : String.Copy(raw);
                }
            }
            else if (t.StartsWith("fs_") && t.EndsWith("__e"))
            {
                // enum (tipo de C con los nombres de los miembros): fs_Ns_Color__Verde -> Color.Verde
                string en = t.Substring(0, t.Length - 3);
                v.Type = TypeName(en);
                if (raw.Length == 0) raw = Evaluate(v.Expr);
                string last = v.Type.LastIndexOf(".") >= 0 ? v.Type.Substring(v.Type.LastIndexOf(".") + 1) : v.Type;
                v.Value = raw.StartsWith(en) && raw.Length > en.Length + 2 ? String.Concat(last, ".", raw.Substring(en.Length + 2))
                                                                          : String.Copy(raw);
            }
            else if (t.StartsWith("fs_"))
            {
                v.Type = TypeName(t);
                v.Value = String.Concat("{", v.Type, "}");
                v.Expandable = true;
            }
            else
            {
                v.Type = CTypeName(t);
                if (raw.Length == 0) raw = Evaluate(v.Expr);
                v.Value = String.Copy(raw);
            }
            curValues.Set(String.Copy(v.Path), String.Copy(v.Value));
            string before;
            v.Changed = prevValues.TryGetValue(v.Path, out before) && before != v.Value;
        }

        func ListElementType(expr: string) -> string
        {
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-var-create - * ").Append(Q(String.Concat("(", expr, ")->f_items")));
            MiValue r = Request(cmd.View());
            string t = "";
            if (r != null)
            {
                t = r.S("type").Trim();
                cmd.Clear();
                cmd.Append("-var-delete ").Append(r.S("name"));
                Request(cmd.View());
            }
            delete cmd;
            if (t.EndsWith("*")) t = t.Substring(0, t.Length - 1).Trim();
            if (t == "faset_string") return "string";
            return t.StartsWith("fs_") ? TypeName(t) : CTypeName(t);
        }

        // Texto de un faset_string {ptr, len}.
        func StringValue(expr: string) -> string
        {
            string lenText = Evaluate(String.Concat("(", expr, ").len"));
            long len = 0;
            if (!Convert.TryToInt64(lenText, out len)) return String.Copy("?");
            if (len <= 0) return String.Copy("\"\"");
            if (len > 100000000) return String.Copy("?");   // sin inicializar
            long n = len > 300 ? 300 : len;
            StringBuilder e = new StringBuilder();
            e.Append("*(").Append(expr).Append(").ptr@").Append(n);
            string s = Evaluate(e.View());
            delete e;
            if (s.Length == 0) return String.Copy("?");
            // gdb muestra los arrays de bytes como "texto"; con caracteres repetidos puede añadir 'x' <repeats N times>.
            if (len > n) s = String.Concat(s, "…");
            return s;
        }

        func LoadChildren(v: DbgVar)
        {
            v.Loaded = true;
            v.Children.Clear();
            if (v.IsList)
            {
                string countText = Evaluate(String.Concat("(", v.Expr, ")->f_count"));
                int count = 0;
                Convert.TryToInt32(countText, out count);
                int shown = count > 100 ? 100 : count;
                for (int i = 0; i < shown; i++)
                {
                    StringBuilder name = new StringBuilder();
                    name.Append("[").Append((long)i).Append("]");
                    StringBuilder e = new StringBuilder();
                    e.Append("(").Append(v.Expr).Append(")->f_items[").Append((long)i).Append("]");
                    v.Children.Add(MakeNode(name.View(), e.View(), String.Concat(v.Path, name.View()), v.Depth + 1));
                    delete name;
                    delete e;
                }
                if (count > shown)
                {
                    DbgVar more = new DbgVar();
                    more.Name = "…";
                    more.Value = L.F("{0} more items", String.FromInt(count - shown), "");
                    more.Depth = v.Depth + 1;
                    more.Error = true;
                    v.Children.Add(more);
                }
                return;
            }
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-var-create - * ").Append(Q(v.Expr));
            MiValue r = Request(cmd.View());
            if (r == null)
            {
                delete cmd;
                return;
            }
            string vname = String.Copy(r.S("name"));
            cmd.Clear();
            cmd.Append("-var-list-children --simple-values ").Append(vname);
            MiValue ch = Request(cmd.View());
            if (ch != null)
            {
                MiValue kids = ch.Get("children");
                for (int i = 0; kids != null && i < kids.Count; i++)
                {
                    MiValue k = kids.At(i);
                    string exp = k.S("exp");
                    if (exp == "faset_vacio") continue;
                    string shown = exp.StartsWith("f_") ? exp.Substring(2) : exp;
                    DbgVar c = new DbgVar();
                    c.Name = String.Copy(shown);
                    c.Expr = "(" + v.Expr + (v.IsPointer ? ")->" : ").") + exp;
                    c.Path = String.Concat(v.Path, ".", shown);
                    c.Depth = v.Depth + 1;
                    Describe(c, k.S("type"), k.S("value"));
                    v.Children.Add(c);
                }
            }
            cmd.Clear();
            cmd.Append("-var-delete ").Append(vname);
            Request(cmd.View());
            delete cmd;
        }

        // ------------------------------------------------------------------ inspección y hover

        public func AddWatch(expr: string)
        {
            string e = expr.Trim();
            if (e.Length == 0) return;
            WatchExprs.Add(String.Copy(e));
            RefreshWatches();
        }

        public func RemoveWatch(i: int)
        {
            if (i < 0 || i >= WatchExprs.Count) return;
            WatchExprs.RemoveAt(i);
            RefreshWatches();
        }

        func RefreshWatches()
        {
            Watches.Clear();
            for (int i = 0; i < WatchExprs.Count; i++)
            {
                string e = WatchExprs[i];
                DbgVar v;
                if (!Stopped)
                {
                    v = new DbgVar();
                    v.Name = String.Copy(e);
                    v.Error = true;
                }
                else
                {
                    v = MakeNode(e, FasetToC(e, true), String.Concat("watch:", e), 0);
                    Restore(v);
                }
                Watches.Add(v);
            }
        }

        // Texto emergente con el valor de una expresión de Faset ("" si no se puede evaluar).
        public func HoverValue(expr: string) -> string
        {
            if (!Stopped || expr.Length == 0) return "";
            DbgVar v = MakeNode(expr, FasetToC(expr, true), String.Concat("hover:", expr), 0);
            if (v.Error) return "";
            StringBuilder sb = new StringBuilder();
            sb.Append(expr).Append(" = ").Append(v.Value);
            if (v.Type.Length > 0) sb.Append("    (").Append(v.Type).Append(")");
            if (v.Expandable)
            {
                LoadChildren(v);
                for (int i = 0; i < v.Children.Count && i < 8; i++)
                    sb.Append("\n  ").Append(v.Children[i].Name).Append(" = ").Append(v.Children[i].Value);
                if (v.Children.Count > 8) sb.Append("\n  …");
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Traduce una expresión sencilla de Faset a C: jugador.Vida -> l_jugador.f_Vida (gdb acepta '.'
        // sobre punteros), lista[i] -> l_lista->f_items[l_i], s.Length -> s.len, this -> self.
        public func FasetToC(e: string, probeTypes: bool) -> string
        {
            StringBuilder sb = new StringBuilder();
            List<int> chainStarts = new List<int>();
            int chainStart = 0;
            bool afterDot = false;
            int i = 0;
            while (i < e.Length)
            {
                byte c = e[i];
                if (Char.IsLetter((char)c) || c == '_' || c >= 0x80)
                {
                    int j = i;
                    while (j < e.Length && (Char.IsLetterOrDigit((char)e[j]) || e[j] == '_' || e[j] >= 0x80)) j++;
                    string word = e.Substring(i, j - i);
                    if (afterDot)
                    {
                        if (word == "Length") sb.Append("len");
                        else if (word == "Count") sb.Append("f_count");
                        else sb.Append("f_").Append(word);
                    }
                    else
                    {
                        chainStart = sb.Length;
                        if (word == "this") sb.Append("self");
                        else if (word == "null") sb.Append("0");
                        else if (word == "true") sb.Append("1");
                        else if (word == "false") sb.Append("0");
                        else if (frameNames.Contains(String.Concat("l_", word))) sb.Append("l_").Append(word);
                        else if (frameNames.Contains(String.Concat("p_", word))) sb.Append("p_").Append(word);
                        else if (frameHasSelf && !frameNames.Contains(word)) sb.Append("self->f_").Append(word);
                        else sb.Append(word);
                    }
                    afterDot = false;
                    i = j;
                    continue;
                }
                if (Char.IsDigit((char)c))
                {
                    int j = i;
                    while (j < e.Length && (Char.IsLetterOrDigit((char)e[j]) || e[j] == '.')) j++;
                    sb.Append(e.Substring(i, j - i));
                    i = j;
                    afterDot = false;
                    continue;
                }
                if (c == '"')
                {
                    int j = i + 1;
                    while (j < e.Length && e[j] != '"') j += e[j] == '\\' ? 2 : 1;
                    if (j < e.Length) j++;
                    sb.Append(e.Substring(i, Math.Min(j, e.Length) - i));
                    i = j;
                    continue;
                }
                if (c == '.')
                {
                    sb.Append(".");
                    afterDot = true;
                    i++;
                    continue;
                }
                if (c == '[')
                {
                    // Índice: List<T> -> ->f_items[...], string -> .ptr[...]
                    string bse = String.Copy(sb.View().Substring(chainStart));
                    string kind = probeTypes ? TypeOfC(bse) : "";
                    if (kind.Contains("collections_List_"))
                    {
                        string head = String.Copy(sb.View().Substring(0, chainStart));
                        sb.Clear();
                        sb.Append(head).Append("(").Append(bse).Append(")->f_items[");
                    }
                    else if (kind == "faset_string") sb.Append(".ptr[");
                    else sb.Append("[");
                    chainStarts.Add(chainStart);
                    i++;
                    continue;
                }
                if (c == ']')
                {
                    sb.Append("]");
                    if (chainStarts.Count > 0) chainStart = chainStarts.Pop();
                    i++;
                    continue;
                }
                sb.Append(e.Substring(i, 1));
                i++;
            }
            string r = sb.ToString();
            delete sb;
            delete chainStarts;
            return r;
        }

        func TypeOfC(cexpr: string) -> string
        {
            StringBuilder cmd = new StringBuilder();
            cmd.Append("-var-create - * ").Append(Q(cexpr));
            MiValue r = Request(cmd.View());
            string t = "";
            if (r != null)
            {
                t = String.Copy(r.S("type").Trim());
                cmd.Clear();
                cmd.Append("-var-delete ").Append(r.S("name"));
                Request(cmd.View());
            }
            delete cmd;
            return t;
        }

        // ------------------------------------------------------------------ nombres

        // Nombre de Faset de una variable de C ("" para las temporales del compilador).
        public static func FasetName(cname: string) -> string
        {
            if (cname == "self") return String.Copy("this");
            if ((cname.StartsWith("l_") || cname.StartsWith("p_")) && cname.Length > 2) return String.Copy(cname.Substring(2));
            return "";
        }

        // fs_Ns_Clase -> Ns.Clase; fs_std_collections_List_3 -> List (instancia de plantilla).
        public static func TypeName(cname: string) -> string
        {
            string s = cname.StartsWith("fs_") ? cname.Substring(3) : cname;
            // Sufijo numérico de las instancias de plantillas (List_3).
            int us = s.LastIndexOf("_");
            if (us > 0 && IsDigits(s.Substring(us + 1))) s = s.Substring(0, us);
            // La biblioteca estándar se muestra sin su espacio de nombres.
            if (s.StartsWith("std_")) s = s.Substring(s.LastIndexOf("_") + 1);
            return Text.Replace(s, "_", ".");
        }

        static func IsDigits(s: string) -> bool
        {
            if (s.Length == 0) return false;
            for (int i = 0; i < s.Length; i++)
                if (s[i] < '0' || s[i] > '9') return false;
            return true;
        }

        public static func CTypeName(t: string) -> string
        {
            if (t == "int32_t" || t == "int") return String.Copy("int");
            if (t == "int64_t" || t == "long") return String.Copy("long");
            if (t == "uint32_t") return String.Copy("uint");
            if (t == "uint64_t") return String.Copy("ulong");
            if (t == "int16_t") return String.Copy("short");
            if (t == "uint16_t") return String.Copy("ushort");
            if (t == "int8_t") return String.Copy("sbyte");
            if (t == "uint8_t" || t == "unsigned char") return String.Copy("byte");
            if (t == "_Bool") return String.Copy("bool");
            if (t.StartsWith("faset_fn")) return String.Copy("delegate");
            return String.Copy(t);
        }

        static func OperatorName(op: string) -> string
        {
            if (op == "op_add") return "operator+";
            if (op == "op_sub") return "operator-";
            if (op == "op_mul") return "operator*";
            if (op == "op_div") return "operator/";
            if (op == "op_mod") return "operator%";
            if (op == "op_eq") return "operator==";
            if (op == "op_ne") return "operator!=";
            if (op == "op_lt") return "operator<";
            if (op == "op_gt") return "operator>";
            if (op == "op_le") return "operator<=";
            if (op == "op_ge") return "operator>=";
            if (op == "op_index") return "operator[]";
            return op;
        }

        // Nombre de Faset de una función de C.
        public static func Demangle(c: string) -> string
        {
            if (!c.StartsWith("fs_")) return String.Copy(c);
            int m = c.IndexOf("__m_");
            if (m > 0)
            {
                string method = c.Substring(m + 4);
                // Sobrecargas (_1) e instancias genéricas (_g3).
                int us = method.LastIndexOf("_");
                if (us > 0)
                {
                    string tail = method.Substring(us + 1);
                    if (IsDigits(tail) || (tail.StartsWith("g") && IsDigits(tail.Substring(1)))) method = method.Substring(0, us);
                }
                if (method.StartsWith("op_")) method = OperatorName(method);
                return String.Concat(TypeName(c.Substring(0, m)), ".", method);
            }
            int k = c.IndexOf("__ctor");
            if (k > 0)
            {
                string t = TypeName(c.Substring(0, k));
                string last = t.LastIndexOf(".") >= 0 ? t.Substring(t.LastIndexOf(".") + 1) : t;
                return String.Concat(t, ".", last);
            }
            k = c.IndexOf("__dtor");
            if (k > 0)
            {
                string t = TypeName(c.Substring(0, k));
                string last = t.LastIndexOf(".") >= 0 ? t.Substring(t.LastIndexOf(".") + 1) : t;
                return String.Concat(t, ".~", last);
            }
            k = c.IndexOf("__new");
            if (k < 0) k = c.IndexOf("__make");
            if (k < 0) k = c.IndexOf("__init");
            if (k > 0) return String.Concat("new ", TypeName(c.Substring(0, k)));
            // Funciones de espacio de nombres: fs_Ns_f_nombre
            int f = c.IndexOf("f_");
            if (f >= 3 && (f == 3 || c[f - 1] == '_'))
            {
                string ns = f > 3 ? Text.Replace(c.Substring(3, f - 4), "_", ".") : "";
                string name = c.Substring(f + 2);
                return ns.Length > 0 ? String.Concat(ns, ".", name) : String.Copy(name);
            }
            return TypeName(c);
        }

        // ------------------------------------------------------------------ paneles

        static func RowHeight(r: Renderer) -> float => r.Code.LineHeight + 4;

        func Flatten(from: List<DbgVar>, into: List<DbgVar>)
        {
            for (int i = 0; i < from.Count; i++)
            {
                into.Add(from[i]);
                if (from[i].Expanded) Flatten(from[i].Children, into);
            }
        }

        func DrawRows(r: Renderer, rows: List<DbgVar>, scroll: int, x: float, y0: float, w: float, h: float, mx: float, my: float, watch: bool)
        {
            float rh = RowHeight(r);
            int visible = (int)(h / rh) + 1;
            float nameW = 90;
            for (int i = 0; i < visible && scroll + i < rows.Count; i++)
            {
                DbgVar rv = rows[scroll + i];
                float need = 14 + rv.Depth * 16 + 14 + r.TextWidth(r.Code, rv.Name) + 12;
                if (need > nameW) nameW = need;
            }
            nameW = (float)Math.Min((double)nameW, (double)w * 0.5);
            for (int i = 0; i < visible; i++)
            {
                int ri = scroll + i;
                if (ri >= rows.Count) break;
                DbgVar v = rows[ri];
                float ry = y0 + i * rh;
                bool hover = mx >= x && mx < x + w && my >= ry && my < ry + rh;
                if (hover) r.RoundRect(x + 6, ry, w - 12, rh, 6, Theme.Hover);
                float ix = x + 14 + v.Depth * 16;
                if (v.Expandable) r.Text(r.Icons, ix, ry + 3, v.Expanded ? "▾" : "▸", Theme.TextSecondary);
                r.PushClip(x, ry, x + nameW - x, rh);
                r.Text(r.Code, ix + 14, ry + 2, v.Name, Theme.Text);
                r.PopClip();
                r.PushClip(x + nameW, ry, w - nameW - 8, rh);
                Color vc = v.Error ? Theme.TextTertiary : v.Changed ? Color.Hex(0xf07a6a) : v.Value.StartsWith("\"") ? Color.Hex(0xc3e88d) : Theme.Text;
                float vx = r.Text(r.Code, x + nameW + 8, ry + 2, v.Value, vc);
                if (v.Type.Length > 0 && vx + 40 < x + w) r.Text(r.UiSmall, vx + 14, ry + 4, v.Type, Theme.TextTertiary);
                r.PopClip();
                if (watch && v.Depth == 0 && hover) r.Text(r.Icons, x + w - 26, ry + 3, "×", Theme.TextSecondary);
            }
        }

        func Hint() -> string => !Active ? L.T("Start debugging (F5) and stop at a breakpoint to see the values.")
                         : Running ? L.T("The program is running…") : "";

        public func DrawVariables(r: Renderer, x: float, y: float, w: float, h: float, mx: float, my: float)
        {
            r.PushClip(x, y, w, h);
            float y0 = y + 4;
            if (StopMessage.Length > 0 && Stopped)
            {
                r.RoundRect(x + 8, y0, w - 16, RowHeight(r) + 4, 6, Color.Hex(0xf04f4f, 0.18f));
                r.Text(r.Ui, x + 18, y0 + 4, StopMessage, Color.Hex(0xff8a80));
                y0 += RowHeight(r) + 10;
            }
            varRows.Clear();
            Flatten(Variables, varRows);
            if (VarsScroll > Math.Max(0, varRows.Count - 1)) VarsScroll = Math.Max(0, varRows.Count - 1);
            string hint = Hint();
            if (hint.Length > 0) r.Text(r.Ui, x + 16, y0 + 4, hint, Theme.TextTertiary);
            else if (varRows.Count == 0) r.Text(r.Ui, x + 16, y0 + 4, L.T("No local variables in this frame."), Theme.TextTertiary);
            else DrawRows(r, varRows, VarsScroll, x, y0, w, h - (y0 - y), mx, my, false);
            varsTop = y0;
            r.PopClip();
        }
        var varsTop: float;
        var watchTop: float;

        public func DrawStack(r: Renderer, x: float, y: float, w: float, h: float, mx: float, my: float)
        {
            r.PushClip(x, y, w, h);
            float y0 = y + 4;
            float rh = RowHeight(r);
            string hint = Hint();
            if (hint.Length > 0) r.Text(r.Ui, x + 16, y0 + 4, hint, Theme.TextTertiary);
            if (StackScroll > Math.Max(0, Frames.Count - 1)) StackScroll = Math.Max(0, Frames.Count - 1);
            int visible = (int)(h / rh) + 1;
            for (int i = 0; i < visible && Stopped; i++)
            {
                int fi = StackScroll + i;
                if (fi >= Frames.Count) break;
                DbgFrame f = Frames[fi];
                float ry = y0 + i * rh;
                bool hover = mx >= x && mx < x + w && my >= ry && my < ry + rh;
                if (fi == SelectedFrame) r.RoundRect(x + 6, ry, w - 12, rh, 6, Theme.Active);
                else if (hover) r.RoundRect(x + 6, ry, w - 12, rh, 6, Theme.Hover);
                if (fi == TopFrame) r.Text(r.Icons, x + 14, ry + 3, "▶", Color.Hex(0xf2c94c));
                else if (fi == SelectedFrame) r.Text(r.Icons, x + 14, ry + 3, "▶", Color.Hex(0x7cc47c));
                float fx = r.Text(r.Code, x + 32, ry + 2, f.Func, f.IsUser ? Theme.Text : Theme.TextTertiary);
                StringBuilder where = new StringBuilder();
                if (f.Path.Length > 0) where.Append(Path.GetFileName(f.Path)).Append(":").Append((long)(f.Line + 1));
                else where.Append(L.T("no source"));
                r.Text(r.UiSmall, fx + 14, ry + 4, where.View(), Theme.TextTertiary);
                delete where;
            }
            r.PopClip();
        }

        public func DrawWatch(r: Renderer, x: float, y: float, w: float, h: float, mx: float, my: float)
        {
            r.PushClip(x, y, w, h);
            float y0 = y + 4;
            watchRows.Clear();
            Flatten(Watches, watchRows);
            if (WatchScroll > Math.Max(0, watchRows.Count)) WatchScroll = Math.Max(0, watchRows.Count);
            DrawRows(r, watchRows, WatchScroll, x, y0, w, h, mx, my, true);
            float rh = RowHeight(r);
            float ay = y0 + (watchRows.Count - WatchScroll) * rh;
            bool hover = mx >= x && mx < x + w && my >= ay && my < ay + rh;
            if (hover) r.RoundRect(x + 6, ay, w - 12, rh, 6, Theme.Hover);
            r.Text(r.Ui, x + 16, ay + 3, L.T("+ Add watch expression"), Theme.TextSecondary);
            watchTop = y0;
            r.PopClip();
        }

        // Clic en el panel de variables: expande o contrae la fila.
        public func ClickVariables(r: Renderer, y: float) -> bool
        {
            int row = VarsScroll + (int)Math.Floor((y - varsTop) / RowHeight(r));
            if (y < varsTop || row < 0 || row >= varRows.Count) return false;
            Toggle(varRows[row]);
            return true;
        }

        // Fila de la pila bajo el ratón (-1 si ninguna).
        public func StackRowAt(r: Renderer, panelTop: float, y: float) -> int
        {
            int row = StackScroll + (int)Math.Floor((y - panelTop - 4) / RowHeight(r));
            return row >= 0 && row < Frames.Count && Stopped ? row : -1;
        }

        // Clic en el panel de inspección: 1 = añadir, 2 = expandido o quitado, 0 = nada.
        public func ClickWatch(r: Renderer, x: float, w: float, px: float, y: float) -> int
        {
            int row = WatchScroll + (int)Math.Floor((y - watchTop) / RowHeight(r));
            if (y < watchTop || row < 0) return 0;
            if (row == watchRows.Count) return 1;
            if (row > watchRows.Count) return 0;
            DbgVar v = watchRows[row];
            if (v.Depth == 0 && px > x + w - 34)
            {
                for (int i = 0; i < Watches.Count; i++)
                    if (Watches[i] == v) RemoveWatch(i);
                return 2;
            }
            Toggle(v);
            return 2;
        }

        // Primer valor (para los guiones de pruebas): "nombre = valor" de la fila con ese nombre.
        public func FindVar(path: string) -> DbgVar
        {
            List<DbgVar> rows = new List<DbgVar>();
            Flatten(Variables, rows);
            Flatten(Watches, rows);
            for (int i = 0; i < rows.Count; i++)
                if (rows[i].Path == path || rows[i].Name == path) return rows[i];
            return null;
        }
    }
}
