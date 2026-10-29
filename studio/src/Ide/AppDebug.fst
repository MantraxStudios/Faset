// =============================================================================
//  FasetStudio: integración del depurador (Debugger.fst) en la aplicación.
//
//  F5 compila con -g y arranca gdb, F9 / clic en el margen ponen puntos de
//  interrupción, F10 / F11 / Shift+F11 avanzan, la barra de depuración sustituye al
//  buscador y los paneles 4-6 (Variables, Pila de llamadas, Inspección) se acoplan
//  como Salida y Problemas. App.fst solo llama a estos métodos.
// =============================================================================
using std.collections;
using std.io;
using std.os;
using std.text;
using std.time;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    public partial class App
    {
        // Depurador (Debugger.fst): gdb por MI. Paneles 4 Variables, 5 Pila de llamadas y 6 Inspección.
        Debugger dbg = new Debugger();
        string debugExe = "";        // ejecutable que se depura al terminar la compilación ("" = ninguno)
        string debugCwd = "";
        string extraBuildArgs = "";  // opciones añadidas a 'faset build' (al compilar para depurar: -g -o ...)
        bool stoppedOnce;            // primera parada de la sesión: se muestran los paneles del depurador
        string bpRoot = "";          // carpeta cuyos puntos de interrupción están cargados
        int contextBreakpoint = -1;  // punto de interrupción del menú del margen

        // F5: compila con información de depuración (-g) y arranca gdb; si ya está detenido, continúa.
        void StartDebugging()
        {
            if (dbg.Active)
            {
                if (dbg.Stopped) dbg.Continue();
                return;
            }
            if (process != null && process.IsRunning)
            {
                SetStatus(L.T("A build is already running"));
                return;
            }
            if (!analyzer.Available)
            {
                SetStatus(L.T("Compiler 'faset' not found"));
                return;
            }
            if (buildTarget == "android")
            {
                SetStatus(L.T("The debugger works with programs for this computer (Android debugging is not supported)"));
                return;
            }
            if (dbg.DebuggerPath().Length == 0)
            {
                output.Clear();
                ShowTool(1);
                output.Append(L.T("gdb was not found: install it (e.g. sudo apt install gdb) to debug")).Append("\n");
                SetStatus(L.T("gdb was not found: install it (e.g. sudo apt install gdb) to debug"));
                return;
            }
            // El ejecutable de depuración va a obj/debug/ (en una solución, -o es el del proyecto de inicio).
            string name = projectName;
            if (name.Length == 0 && Editor != null) name = Path.GetFileNameWithoutExtension(Editor.Doc.FullPath);
            if (name.Length == 0) name = "programa";
            string dir = Path.Combine(rootFolder, "obj/debug");
            Directory.Create(dir);
            debugExe = Path.Combine(dir, name);
            debugCwd = projectFile.Length > 0 ? String.Copy(Path.GetDirectoryName(projectFile)) : String.Copy(rootFolder);
            string q = Analyzer.Quote(debugExe);
            extraBuildArgs = String.Concat(" -g -o ", q);
            StartProcessFor(false, solutionFile);
            extraBuildArgs = "";
            if (process == null || !process.IsRunning) debugExe = "";
            else SetStatus(L.T("Building for debugging…"));
        }

        // Al terminar la compilación para depurar.
        void LaunchDebugger(bool built)
        {
            string exe = debugExe;
            debugExe = "";
            if (!built || !File.Exists(exe))
            {
                SetStatus(L.T("Build failed: fix the errors to debug"));
                return;
            }
            dbg.Output = output;
            dbg.JustMyCode = Settings.Get("debug.justmycode", "1") != "0";
            output.Append("\n> gdb ").Append(Path.GetFileName(exe)).Append("\n");
            stoppedOnce = false;
            if (dbg.Start(exe, debugCwd))
            {
                ShowTool(4);
                SetStatus(L.T("Debugging…"));
            }
            needsRedraw = true;
        }

        // Puntos de interrupción del proyecto: se cargan al abrirlo y se guardan al cambiar.
        void SyncBreakpoints()
        {
            if (dbg.BreakpointsChanged)
            {
                dbg.BreakpointsChanged = false;
                if (bpRoot.Length > 0) Settings.Set(String.Concat("breakpoints.", bpRoot), dbg.Serialize(bpRoot));
            }
            if (rootFolder != bpRoot)
            {
                bpRoot = String.Copy(rootFolder);
                dbg.Deserialize(bpRoot, bpRoot.Length > 0 ? Settings.Get(String.Concat("breakpoints.", bpRoot), "") : "");
            }
        }

        // Atiende al depurador; true si hay que redibujar.
        bool UpdateDebugger()
        {
            SyncBreakpoints();
            if (!dbg.Active && !dbg.Ended) return false;
            bool changed = dbg.Update();
            if (dbg.Status.Length > 0)
            {
                SetStatus(L.T(dbg.Status));
                dbg.Status = "";
            }
            if (dbg.StopChanged)
            {
                dbg.StopChanged = false;
                if (!stoppedOnce)
                {
                    ShowTool(5);
                    ShowTool(4);
                }
                stoppedOnce = true;
                ShowStopLocation();
                if (dbg.StopMessage.Length == 0)
                {
                    string where = String.Concat(Path.GetFileName(dbg.StopPath), ":", String.FromInt(dbg.StopLine + 1));
                    SetStatus(L.F("Stopped at {0}", where, ""));
                }
                changed = true;
            }
            if (dbg.Ended)
            {
                dbg.Ended = false;
                changed = true;
            }
            return changed;
        }

        // Abre el archivo del marco seleccionado y muestra su línea (sin mover el cursor si ya se ve).
        void ShowStopLocation()
        {
            if (dbg.StopPath.Length == 0 || dbg.StopLine < 0 || !File.Exists(dbg.StopPath)) return;
            EditorView v = OpenFile(dbg.StopPath);
            if (v == null) return;
            int visible = v.H > 0 ? v.VisibleLines(r) : 30;
            if (dbg.StopLine < v.ScrollLine + 1 || dbg.StopLine >= v.ScrollLine + visible - 2)
                v.ScrollLine = Math.Max(0, dbg.StopLine - visible / 2);
            needsRedraw = true;
        }

        void DebugAction(int id)
        {
            needsRedraw = true;
            SyncBreakpoints();
            if (id == 700) StartDebugging();
            else if (id == 701) StartProcess(true);
            else if (id == 702)
            {
                if (dbg.Active) dbg.Stop();
                else
                {
                    debugExe = "";
                    StopProcess();
                }
            }
            else if (id == 703) dbg.StepOver();
            else if (id == 704) dbg.StepInto();
            else if (id == 705) dbg.StepOut();
            else if (id == 706) dbg.Pause();
            else if (id == 707)
            {
                EditorView v = Editor;
                if (v != null && v.Doc.FullPath.EndsWith(".fst")) dbg.ToggleBreakpoint(v.Doc.FullPath, v.Cursor.Line);
            }
            else if (id == 708)
            {
                while (dbg.Breakpoints.Count > 0) dbg.RemoveBreakpoint(dbg.Breakpoints.Count - 1);
            }
            else if (id == 709) OpenOverlay(Overlay.AddWatch);
            else if (id == 710 && contextBreakpoint >= 0 && contextBreakpoint < dbg.Breakpoints.Count)
            {
                OpenOverlay(Overlay.BreakCondition);
                overlayInput.Append(dbg.Breakpoints[contextBreakpoint].Condition);
            }
            else if (id == 711) dbg.RemoveBreakpoint(contextBreakpoint);
            else if (id == 712)
            {
                dbg.Stop();
                StartDebugging();
            }
            else if (id == 713)
            {
                EditorView v = Editor;
                if (v == null) return;
                string e = v.HasSelection ? v.SelectedText() : ExpressionAt(v, v.Cursor);
                if (e.Trim().Length == 0) OpenOverlay(Overlay.AddWatch);
                else
                {
                    dbg.AddWatch(e);
                    ShowTool(6);
                }
            }
            else if (id == 714)
            {
                bool on = Settings.Get("debug.justmycode", "1") == "0";
                Settings.Set("debug.justmycode", on ? "1" : "0");
                SetStatus(on ? L.T("Just my code: on (takes effect in the next session)") : L.T("Just my code: off (takes effect in the next session)"));
            }
            else if (id >= 720 && id <= 722) ToggleTool(id - 716);
        }

        // Clic en el margen del editor: punto de interrupción (izquierdo) o su menú (derecho).
        bool GutterMouse(EditorView v, Event e, float x, float y)
        {
            if (v.Designer != null && v.DesignMode) return false;
            if (x >= v.X + v.GutterWidth(r) - r.Code.CharWidth || !v.Doc.FullPath.EndsWith(".fst")) return false;
            SyncBreakpoints();
            int line = v.ScrollLine + (int)Math.Floor((y - v.Y) / r.Code.LineHeight);
            if (line < 0 || line >= v.Doc.Buffer.LineCount) return false;
            if (e.Button == 1)
            {
                dbg.ToggleBreakpoint(v.Doc.FullPath, line);
                return true;
            }
            if (e.Button == 3)
            {
                int bi = dbg.BreakpointAt(v.Doc.FullPath, line);
                if (bi < 0)
                {
                    dbg.AddBreakpoint(v.Doc.FullPath, line, "");
                    bi = dbg.BreakpointAt(v.Doc.FullPath, line);
                }
                contextBreakpoint = bi;
                Menu m = new Menu();
                m.Add(L.T("Condition…"), "", 710, true);
                m.Add(L.T("Delete breakpoint"), "F9", 711, true);
                ShowMenu(m, x, y, -1);
                return true;
            }
            return false;
        }

        // Clics en Variables, Pila de llamadas e Inspección.
        bool DebugPanelMouse(Event e, float x, float y)
        {
            if (InTool(4, x, y) && y >= toolRect[17] + PanelHeaderHeight)
            {
                dbg.ClickVariables(r, y);
                return true;
            }
            if (InTool(5, x, y) && y >= toolRect[21] + PanelHeaderHeight)
            {
                int row = dbg.StackRowAt(r, toolRect[21] + PanelHeaderHeight, y);
                if (row >= 0)
                {
                    dbg.SelectFrame(row);
                    ShowStopLocation();
                }
                return true;
            }
            if (InTool(6, x, y) && y >= toolRect[25] + PanelHeaderHeight)
            {
                if (dbg.ClickWatch(r, toolRect[24], toolRect[26], x, y) == 1) OpenOverlay(Overlay.AddWatch);
                return true;
            }
            return false;
        }

        // Expresión bajo el cursor: el identificador y los miembros que lo preceden (jugador.Vida).
        string ExpressionAt(EditorView v, TextPos p)
        {
            string line = v.Doc.Buffer.LineText(p.Line);
            int a = Math.Min(p.Col, line.Length), b = a;
            while (b < line.Length && IdentByte(line[b])) b++;
            while (a > 0 && IdentByte(line[a - 1])) a--;
            if (b <= a || Char.IsDigit((char)line[a])) return "";
            while (a > 1 && line[a - 1] == '.' && IdentByte(line[a - 2]))
            {
                a -= 2;
                while (a > 0 && IdentByte(line[a - 1])) a--;
            }
            return String.Copy(line.Substring(a, b - a));
        }

        static bool IdentByte(byte c) => Char.IsLetterOrDigit((char)c) || c == '_' || c >= 0x80;

        // Valor para el texto emergente mientras el programa está detenido ("" si no aplica).
        string DebugHover(EditorView v, TextPos p)
        {
            if (!dbg.Stopped || !v.Doc.FullPath.EndsWith(".fst")) return "";
            string e = ExpressionAt(v, p);
            if (e.Length == 0 || IsKeyword(e)) return "";
            return dbg.HoverValue(e);
        }

        static bool IsKeyword(string w) => w == "int" || w == "string" || w == "bool" || w == "var" || w == "new" || w == "return" ||
                                           w == "if" || w == "for" || w == "while" || w == "class" || w == "public" || w == "static" ||
                                           w == "void" || w == "using" || w == "namespace" || w == "else" || w == "float" || w == "double";

        // Barra de depuración (en el lugar del buscador): continuar, pausa, detener, reiniciar y pasos.
        void DrawDebugToolbar(float sx, float sw)
        {
            float bw = 32, n = 7;
            float tw = bw * n + 8;
            float x = sx;
            r.RoundRect(x, 10, tw, 28, 14, Theme.Elevated);
            r.RoundBorder(x, 10, tw, 28, 14, 1, Theme.BorderStrong);
            float bx = x + 4;
            for (int i = 0; i < 7; i++)
            {
                int id = i == 0 ? 700 : i == 1 ? 706 : i == 2 ? 702 : i == 3 ? 712 : i == 4 ? 703 : i == 5 ? 704 : 705;
                bool enabled = id == 700 || id == 703 || id == 704 || id == 705 ? dbg.Stopped : id == 706 ? dbg.Running : true;
                bool hover = hoverButton == id && enabled;
                if (hover) r.RoundRect(bx, 12, bw, 24, 12, Theme.Active);
                Color c = !enabled ? Theme.TextDisabled : Theme.Text;
                float cx = bx + bw / 2, cy = 24;
                if (id == 700) r.Text(r.Icons, cx - 5, cy - 8, "▶", enabled ? Color.Hex(0x6fcf7f) : c);
                else if (id == 706)
                {
                    r.Rect(cx - 5, cy - 6, 3.5f, 12, c);
                    r.Rect(cx + 1.5f, cy - 6, 3.5f, 12, c);
                }
                else if (id == 702) r.RoundRect(cx - 5.5f, cy - 5.5f, 11, 11, 2, Color.Hex(0xe5484d));
                else if (id == 712) r.Text(r.Code, cx - r.Code.CharWidth / 2, cy - 10, "↻", c);
                else
                {
                    string glyph = id == 703 ? "↷" : id == 704 ? "↓" : "↑";
                    r.Text(r.Code, cx - r.Code.CharWidth / 2, cy - 12, glyph, c);
                    r.RoundRect(cx - 2, cy + 6, 4, 4, 2, c);   // la sentencia
                }
                AddHit(bx, 10, bw, 28, id, -1, false);
                bx += bw;
            }
            // Consejo con el nombre y el atajo del botón bajo el ratón.
            if (hoverButton >= 700 && hoverButton <= 712)
            {
                string tip = hoverButton == 700 ? L.T("Continue (F5)") : hoverButton == 706 ? L.T("Pause")
                           : hoverButton == 702 ? L.T("Stop debugging (Shift+F5)") : hoverButton == 712 ? L.T("Restart")
                           : hoverButton == 703 ? L.T("Step over (F10)") : hoverButton == 704 ? L.T("Step into (F11)")
                           : L.T("Step out (Shift+F11)");
                float tipW = r.TextWidth(r.UiSmall, tip) + 16;
                r.RoundRect(x + tw / 2 - tipW / 2, 42, tipW, 20, 8, Theme.Active);
                r.Text(r.UiSmall, x + tw / 2 - tipW / 2 + 8, 44, tip, Theme.Text);
            }
            // Estado a la derecha de la barra
            string state = dbg.Stopped ? (dbg.StopMessage.Length > 0 ? L.T("Stopped (exception)") : L.T("Stopped")) : L.T("Running…");
            float stx = x + tw + 10;
            if (stx + r.TextWidth(r.UiSmall, state) < sx + sw)
                r.Text(r.UiSmall, stx, 17, state, dbg.Stopped ? Color.Hex(0xf2c94c) : Theme.TextTertiary);
        }

        // Guion: espera a que el programa depurado se detenga o termine (atiende la compilación previa).
        void WaitDebugger(int ms)
        {
            long until = Environment.TickCount64() + ms;
            while (Environment.TickCount64() < until)
            {
                Update();
                bool building = debugExe.Length > 0 || (process != null && process.IsRunning);
                if (!building && (!dbg.Active || dbg.Stopped)) break;
                EventWait.WaitFd(-1, 20);
            }
            Update();
        }

        // Verbos de depuración del modo de prueba (--script). true si 'verb' era uno de ellos.
        bool DebugCommand(string verb, string arg)
        {
            if (verb == "debug" || verb == "continue" || verb == "next" || verb == "step" || verb == "stepout" || verb == "restart")
            {
                // debug: compila y arranca; next / step / stepout / continue: avanzan. Todos esperan a que
                // el programa se detenga o termine (máx. 60 s).
                if (verb == "debug") StartDebugging();
                else if (verb == "continue") dbg.Continue();
                else if (verb == "next") dbg.StepOver();
                else if (verb == "step") dbg.StepInto();
                else if (verb == "stepout") dbg.StepOut();
                else DebugAction(712);
                WaitDebugger(60000);
            }
            else if (verb == "waitstop") WaitDebugger(arg.Length > 0 ? arg.ToInt() : 30000);
            else if (verb == "stopdebug") dbg.Stop();
            else if (verb == "pause")
            {
                dbg.Pause();
                WaitDebugger(10000);
            }
            else if (verb == "bp")
            {
                // bp <archivo> <línea> [condición]: alterna un punto de interrupción (ruta relativa a la carpeta)
                UpdateDebugger();
                List<string> p = Text.Split(arg, " ");
                if (p.Count >= 2)
                {
                    string file = p[0].StartsWith("/") ? String.Copy(p[0]) : Path.Combine(rootFolder, p[0]);
                    int line = p[1].ToInt() - 1;
                    StringBuilder cond = new StringBuilder();
                    for (int i = 2; i < p.Count; i++) cond.Append(i > 2 ? " " : "").Append(p[i]);
                    if (cond.Length > 0) dbg.AddBreakpoint(file, line, cond.View());
                    else dbg.ToggleBreakpoint(file, line);
                    delete cond;
                }
                delete p;
                UpdateDebugger();
            }
            else if (verb == "watch")
            {
                dbg.AddWatch(arg);
                ShowTool(6);
            }
            else if (verb == "expand")
            {
                DbgVar dv = dbg.FindVar(arg);
                if (dv != null && !dv.Expanded) dbg.Toggle(dv);
            }
            else if (verb == "frame")
            {
                dbg.SelectFrame(arg.ToInt());
                ShowStopLocation();
            }
            else if (verb == "print")
            {
                // print <ruta>: escribe en stdout el valor de una variable (para los tests)
                DbgVar dv = dbg.FindVar(arg);
                Console.WriteLine("print " + arg + " = " + (dv != null ? dv.Value : "<no existe>"));
            }
            else if (verb == "debugstate")
            {
                StringBuilder sb = new StringBuilder();
                sb.Append("debug active=").Append(dbg.Active).Append(" stopped=").Append(dbg.Stopped).Append(" at ")
                  .Append(Path.GetFileName(dbg.StopPath)).Append(":").Append((long)(dbg.StopLine + 1));
                if (dbg.Frames.Count > 0) sb.Append(" in ").Append(dbg.Frames[dbg.SelectedFrame].Func);
                if (dbg.StopMessage.Length > 0) sb.Append(" [").Append(dbg.StopMessage).Append("]");
                Console.WriteLine(sb.View());
                delete sb;
            }
            else return false;
            return true;
        }
    }
}
