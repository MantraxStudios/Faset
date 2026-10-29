// =============================================================================
//  Integración con Android: dispositivos (adb), emuladores (AVD) y la vista del
//  dispositivo dentro del IDE.
//
//  La lista de dispositivos y el arranque del emulador usan el propio compilador
//  ('faset android devices | avds | emulator'). La vista refleja la pantalla con
//  'adb exec-out screencap' (RGBA sin comprimir) y reenvía toques, gestos y teclas
//  con 'adb shell input'. Todo corre en procesos hijos: el IDE nunca se bloquea.
// =============================================================================
using std.collections;
using std.text;
using std.io;
using std.os;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    public class AndroidTools
    {
        public const float ToolbarHeight = 44;

        public string Compiler = "";                          // ruta del compilador (vista)
        public List<string> Serials = new List<string>();     // dispositivos listos (copias)
        public List<string> Models = new List<string>();
        public List<string> Avds = new List<string>();        // emuladores instalados (copias)
        public string Device = String.Copy("");               // dispositivo elegido (copia)
        public string StartingAvd = String.Copy("");          // emulador arrancando ("" = ninguno)
        public string Status = "";                            // mensaje para la barra de estado (vista literal)
        public bool Focused;                                   // el teclado va al dispositivo
        public int ScreenW;                                    // tamaño real de la pantalla
        public int ScreenH;
        public bool HasFrame;
        public bool Listed;                                    // ya se consultó la lista al menos una vez

        string adb = String.Copy("");
        ChildProcess listProc;
        StringBuilder listOut = new StringBuilder();
        int listStage;                                         // 0 dispositivos, 1 AVD
        ChildProcess emuProc;
        StringBuilder emuOut = new StringBuilder();
        ChildProcess screenProc;
        string screenFile = String.Copy("");
        long lastShotMs;
        List<ChildProcess> inputs = new List<ChildProcess>();

        // Geometría del último dibujo (para el ratón).
        float imgX;
        float imgY;
        float imgW;
        float imgH;
        float barX;
        float barY;
        float barW;
        bool pressing;
        float pressX;
        float pressY;
        long pressMs;
        public int HoverButton = -1;

        public AndroidTools()
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

        ~AndroidTools()
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
            for (int i = 0; i < inputs.Count; i++) delete inputs[i];
            delete inputs;
            delete listOut;
            delete emuOut;
            File.Delete(screenFile);
            String.Free(screenFile);
            String.Free(Device);
            String.Free(StartingAvd);
            String.Free(adb);
        }

        static void FreeAll(List<string> l)
        {
            for (int i = 0; i < l.Count; i++) String.Free(l[i]);
            l.Clear();
        }

        public bool AdbFound => adb.Length > 0;
        public bool Busy => (listProc != null && listProc.IsRunning) || StartingAvd.Length > 0;

        // adb: $ANDROID_HOME, $ANDROID_SDK_ROOT o ~/Android/Sdk (platform-tools), o el PATH.
        void FindAdb()
        {
            string exe = OS.Name() == "windows" ? "adb.exe" : "adb";
            string home = Environment.GetVariable("HOME");
            if (home.Length == 0)
            {
                String.Free(home);
                home = Environment.GetVariable("USERPROFILE");
            }
            List<string> roots = new List<string>();
            roots.Add(Environment.GetVariable("ANDROID_HOME"));
            roots.Add(Environment.GetVariable("ANDROID_SDK_ROOT"));
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
            if (adb.Length == 0 && Process.Capture(OS.Name() == "windows" ? "where adb" : "command -v adb", out found) == 0)
            {
                String.Free(adb);
                adb = String.Copy(found.Trim());
            }
        }

        // ------------------------------------------------------------------ dispositivos

        // Vuelve a consultar dispositivos conectados y emuladores instalados (en segundo plano).
        public void Refresh()
        {
            if (Compiler.Length == 0 || (listProc != null && listProc.IsRunning)) return;
            listStage = 0;
            StartList("devices");
        }

        void StartList(string what)
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
        public void StartEmulator(string avd)
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

        public void Select(string serial)
        {
            String.Free(Device);
            Device = String.Copy(serial);
            HasFrame = false;
        }

        public string ModelOf(string serial)
        {
            for (int i = 0; i < Serials.Count; i++)
                if (Serials[i] == serial) return Models[i];
            return "";
        }

        public bool IsOnline(string serial)
        {
            for (int i = 0; i < Serials.Count; i++)
                if (Serials[i] == serial) return true;
            return false;
        }

        // ------------------------------------------------------------------ actualización

        // Atiende los procesos en marcha; 'showing' indica si el panel del dispositivo se ve.
        // Devuelve true si hay que redibujar.
        public bool Update(Renderer r, bool showing)
        {
            bool redraw = false;
            long now = Environment.TickCount64();
            if (listProc != null && listProc.IsRunning)
            {
                listProc.ReadAvailable(listOut);
                if (listProc.HasExited)
                {
                    listProc.ReadAvailable(listOut);
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
                emuProc.ReadAvailable(emuOut);
                if (emuProc.HasExited)
                {
                    emuProc.ReadAvailable(emuOut);
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
            // Pantalla: una captura a la vez, como mucho cada 120 ms.
            if (screenProc != null && screenProc.HasExited)
            {
                LoadFrame(r);
                delete screenProc;
                screenProc = null;
                redraw = true;
            }
            if (showing && screenProc == null && Device.Length > 0 && adb.Length > 0 && now - lastShotMs >= 120)
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

        void ParseDevices()
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

        void ParseAvds()
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
        void LoadFrame(Renderer r)
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
                }
            }
            Memory.Free(data);
        }

        // ------------------------------------------------------------------ entrada

        void Shell(string args)
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

        void KeyEvent(int code)
        {
            string n = Convert.ToString(code);
            string args = String.Concat("shell input keyevent ", n);
            Shell(args);
            String.Free(args);
            String.Free(n);
        }

        public void Rotate()
        {
            Shell("emu rotate");
        }

        // Punto de la ventana -> píxel del dispositivo.
        void ToDevice(float px, float py, out int dx, out int dy)
        {
            dx = (int)Math.Clamp((px - imgX) / imgW * ScreenW, 0.0, ScreenW - 1.0);
            dy = (int)Math.Clamp((py - imgY) / imgH * ScreenH, 0.0, ScreenH - 1.0);
        }

        bool InScreen(float px, float py) => HasFrame && px >= imgX && py >= imgY && px < imgX + imgW && py < imgY + imgH;

        // Botones bajo la pantalla: 0 atrás, 1 inicio, 2 recientes, 3 girar.
        int ButtonAt(float px, float py)
        {
            if (Device.Length == 0 || py < barY || py >= barY + 32 || px < barX || px >= barX + barW) return -1;
            return (int)Math.Floor((px - barX) / (barW / 4));
        }

        // Devuelve true si el panel usó el clic.
        public bool MouseDown(float px, float py)
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

        public void MouseUp(float px, float py)
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
                if (held > 500) sb.Append("shell input swipe ").Append((long)x0).Append(" ").Append((long)y0).Append(" ").Append((long)x0).Append(" ").Append((long)y0).Append(" ").Append(held);
                else sb.Append("shell input tap ").Append((long)x0).Append(" ").Append((long)y0);
            }
            else
            {
                long ms = Math.Max(80, Math.Min(1500, Environment.TickCount64() - pressMs));
                sb.Append("shell input swipe ").Append((long)x0).Append(" ").Append((long)y0).Append(" ")
                  .Append((long)x1).Append(" ").Append((long)y1).Append(" ").Append(ms);
            }
            Shell(sb.View());
            delete sb;
        }

        public void Scroll(float px, float py, int lines)
        {
            if (!InScreen(px, py)) return;
            int x = 0, y = 0;
            ToDevice(px, py, out x, out y);
            int dy = -lines * ScreenH / 12;
            int y2 = Math.Clamp(y + dy, 0, ScreenH - 1);
            StringBuilder sb = new StringBuilder();
            sb.Append("shell input swipe ").Append((long)x).Append(" ").Append((long)y).Append(" ").Append((long)x).Append(" ").Append((long)y2).Append(" 120");
            Shell(sb.View());
            delete sb;
        }

        // Teclado con el panel enfocado: se escribe en el dispositivo. Devuelve true si la usó.
        public bool Key(Event e)
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
                string q = Analyzer.Quote(t.View());
                string args = String.Concat("shell input text ", q);
                Shell(args);
                String.Free(args);
                String.Free(q);
                delete t;
            }
            else return false;
            return true;
        }

        // ------------------------------------------------------------------ dibujo

        public void Draw(Renderer r, float x, float y, float w, float h, float mouseX, float mouseY)
        {
            float top = y + 46, bottom = y + h - 8;
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
            float availW = w - 32, availH = bottom - top - ToolbarHeight - 16;
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
            string info = String.Concat(Device, "  ·  ", ModelOf(Device));
            r.Text(r.UiSmall, x + (w - r.TextWidth(r.UiSmall, info)) / 2, barY + 40, info, Theme.TextTertiary);
            String.Free(info);
            r.PopClip();
        }

        void Center(Renderer r, float x, float w, float y, string title, string hint)
        {
            r.Text(r.UiBold, x + (w - r.TextWidth(r.UiBold, title)) / 2, y, title, Theme.Text);
            r.Text(r.UiSmall, x + (w - r.TextWidth(r.UiSmall, hint)) / 2, y + 24, hint, Theme.TextTertiary);
        }

        public bool Contains(float px, float py) => InScreen(px, py) || ButtonAt(px, py) >= 0;
    }
}
