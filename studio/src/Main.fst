// =============================================================================
//  FasetStudio — entorno de desarrollo para Faset, escrito en Faset.
//
//    FasetStudio [carpeta | proyecto.fstproj | archivo.fst]
//
//  Opciones de prueba (sin ventana, renderizado fuera de pantalla con Vulkan):
//    --screenshot salida.ppm   --size 1400x860   --script "orden | orden | ..."
// =============================================================================
using std.collections;
using std.io;
using std.os;
using std.text;
using FasetStudio.Gfx;
using FasetStudio.Ide;
using FasetStudio.Platform;

namespace FasetStudio
{
    static extern long readlink(byte* path, byte* buf, ulong size);

    public memory_unsafe static class Program
    {
        // Ruta real del ejecutable: argv[0] no sirve si se lanzó desde el PATH o con un enlace.
        static string ExecutablePath()
        {
            if (!OS.IsWindows)
            {
                byte* buf = (byte*)Memory.AllocZeroed(4096);
                long n = readlink("/proc/self/exe".Ptr, buf, 4095);
                string path = n > 0 ? String.Copy(String.FromBytes(buf, n)) : "";  // FromBytes es una vista de 'buf'
                Memory.Free(buf);
                if (n > 0) return path;
            }
            return Path.GetFullPath(Environment.GetArg(0));
        }

        // Busca el compilador 'faset': variable FASET, carpetas superiores al ejecutable o PATH.
        static string FindCompiler()
        {
            string env = Environment.GetVariable("FASET");
            if (env.Length > 0 && File.Exists(env)) return env;
            String.Free(env);
            string dir = ExecutablePath();
            for (int level = 0; level < 8; level++)
            {
                string parent = String.Copy(Path.GetDirectoryName(dir));
                String.Free(dir);
                dir = parent;
                if (dir.Length == 0) break;
                string candidate = Path.Combine(dir, "faset");
                if (File.Exists(candidate)) return candidate;
                String.Free(candidate);
            }
            String.Free(dir);
            string found;
            if (Process.Capture("command -v faset", out found) == 0) return String.Copy(found.Trim());
            return String.Copy("");
        }

        // Icono: logotipo blanco sobre un cuadrado negro redondeado.
        static uint* MakeIcon(int size)
        {
            uint* px = new uint[size * size];
            float radius = size * 0.22f;
            int inner = (int)(size * 0.62f);
            int offset = (size - inner) / 2;
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    // Cobertura del cuadrado redondeado (distancia a la esquina).
                    float dx = (float)Math.Max(0.0, Math.Max(radius - (x + 0.5f), (x + 0.5f) - (size - radius)));
                    float dy = (float)Math.Max(0.0, Math.Max(radius - (y + 0.5f), (y + 0.5f) - (size - radius)));
                    double d = Math.Sqrt(dx * dx + dy * dy) - radius;
                    double bg = Math.Clamp(0.5 - d, 0.0, 1.0);
                    uint white = 0;
                    if (x >= offset && x < offset + inner && y >= offset && y < offset + inner)
                        white = LogoShape.Coverage(x - offset, y - offset, inner);
                    uint alpha = (uint)(bg * 255);
                    uint v = (uint)((white * alpha) / 255);
                    px[y * size + x] = (alpha << 24) | (v << 16) | (v << 8) | v;
                }
            return px;
        }

        // Carpeta de traducciones: junto al ejecutable o en studio/lang subiendo carpetas.
        static string FindLangFolder()
        {
            string dir = ExecutablePath();
            for (int level = 0; level < 8; level++)
            {
                string parent = String.Copy(Path.GetDirectoryName(dir));
                String.Free(dir);
                dir = parent;
                if (dir.Length == 0) break;
                string a = Path.Combine(dir, "lang");
                if (Directory.Exists(a)) return a;
                String.Free(a);
                string studio = Path.Combine(dir, "studio");
                string b = Path.Combine(studio, "lang");
                String.Free(studio);
                if (Directory.Exists(b)) return b;
                String.Free(b);
            }
            return String.Copy("");
        }

        public static int Main()
        {
            Settings.Load();
            L.Init(FindLangFolder());
            string target = "";
            string screenshot = "";
            string script = "";
            int width = 1400, height = 860;
            for (int i = 1; i < Environment.ArgCount(); i++)
            {
                string a = Environment.GetArg(i);
                if (a == "--screenshot" && i + 1 < Environment.ArgCount()) screenshot = Environment.GetArg(++i);
                else if (a == "--script" && i + 1 < Environment.ArgCount()) script = Environment.GetArg(++i);
                else if (a == "--size" && i + 1 < Environment.ArgCount())
                {
                    List<string> wh = Text.Split(Environment.GetArg(++i), "x");
                    if (wh.Count == 2)
                    {
                        width = wh[0].ToInt();
                        height = wh[1].ToInt();
                    }
                    delete wh;
                }
                else target = a;
            }


            string lang = Environment.GetVariable("FASET_STUDIO_LANG");
            L.Load(lang.Length > 0 ? lang : Settings.Get("language", "en"));
            string compiler = FindCompiler();
            Renderer renderer = new Renderer();
            Window window = null;
            bool offscreen = screenshot.Length > 0;
            if (offscreen)
            {
                if (!renderer.InitOffscreen(width, height))
                {
                    Console.ErrorLine(renderer.Error);
                    return 1;
                }
            }
            else
            {
                window = new Window();
                if (!window.Create("FasetStudio", width, height))
                {
                    Console.ErrorLine(L.T("FasetStudio: could not open the window (is an X server or XWayland running?)"));
                    return 1;
                }
                uint* icon = MakeIcon(64);
                window.SetIcon(icon, 64, 64);
                delete[] icon;
                if (!renderer.InitWindow(window))
                {
                    Console.ErrorLine(renderer.Error);
                    return 1;
                }
            }

            App app = new App();
            app.Init(renderer, window, compiler);
            if (target.Length > 0) app.OpenWorkspace(target);
            else app.ShowHub();

            if (offscreen)
            {
                app.Draw();  // primer dibujado: calcula la disposición de los paneles
                List<string> commands = Text.Split(script, "|");
                for (int i = 0; i < commands.Count; i++)
                    if (commands[i].Trim().Length > 0) app.RunCommand(commands[i]);
                delete commands;
                app.Update();
                app.Draw();
                bool ok = renderer.SaveScreenshot(screenshot);
                app.Shutdown();
                renderer.Shutdown();
                return ok ? 0 : 1;
            }

            while (!app.QuitRequested)
            {
                Event e;
                while (window.Poll(out e)) app.HandleEvent(e);
                if (app.QuitRequested) break;
                if (app.Update()) app.Draw();
                window.Wait(app.IdleWaitMs);
            }
            app.Shutdown();
            renderer.Shutdown();
            return 0;
        }
    }
}
