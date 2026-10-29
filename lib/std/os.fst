// =============================================================================
//  std.os  —  procesos y sistema operativo.
// =============================================================================
using std.text;

namespace std.os
{
    static extern int faset_system(string command);
    static extern long faset_proc_start(string command, string workingDir);
    static extern int faset_proc_read(long handle, byte* buffer, int capacity);
    static extern int faset_proc_status(long handle);
    static extern void faset_proc_kill(long handle);
    static extern void faset_proc_close(long handle);
    static extern bool faset_wait_fd(int fd, int milliseconds);

    // Proceso hijo con su salida (stdout + stderr) leída sin bloquear.
    //   auto p = new ChildProcess();
    //   p.Start("faset build", "");
    //   while (!p.HasExited) { p.ReadAvailable(sb); ... }
    public class ChildProcess
    {
        long handle;
        bool finished;
        int exitCode = -1;

        ~ChildProcess() { if (handle > 0) faset_proc_close(handle); }

        public bool Start(string command, string workingDir)
        {
            if (handle > 0) faset_proc_close(handle);
            handle = faset_proc_start(command, workingDir);
            finished = false;
            exitCode = -1;
            return handle > 0;
        }

        public bool IsRunning => handle > 0 && !finished;

        // Añade a 'output' lo que el proceso haya escrito; devuelve true si añadió algo.
        public bool ReadAvailable(StringBuilder output)
        {
            if (handle <= 0) return false;
            byte* buf = (byte*)Memory.Alloc(4096);
            bool any = false;
            for (;;)
            {
                int n = faset_proc_read(handle, buf, 4096);
                if (n <= 0)
                {
                    if (n < 0 && !finished)
                    {
                        int code = faset_proc_status(handle);
                        if (code >= 0)
                        {
                            finished = true;
                            exitCode = code;
                        }
                    }
                    break;
                }
                output.Append(String.FromBytes(buf, n));
                any = true;
            }
            Memory.Free(buf);
            return any;
        }

        public bool HasExited
        {
            get
            {
                if (handle <= 0 || finished) return true;
                int code = faset_proc_status(handle);
                if (code < 0) return false;
                finished = true;
                exitCode = code;
                return true;
            }
        }

        public int ExitCode => exitCode;

        public void Kill() { if (handle > 0) faset_proc_kill(handle); }
    }

    public static class EventWait
    {
        // Espera hasta 'milliseconds' a que el descriptor 'fd' tenga datos.
        public static bool WaitFd(int fd, int milliseconds) => faset_wait_fd(fd, milliseconds);
    }

    public static class Process
    {
        // Ejecuta un comando del sistema y devuelve su código de salida.
        public static int Run(string command) => faset_system(command);

        // Ejecuta un comando, espera a que termine y devuelve su salida (copia: libérala con String.Free).
        public static int Capture(string command, out string output)
        {
            ChildProcess p = new ChildProcess();
            StringBuilder sb = new StringBuilder();
            if (!p.Start(command, ""))
            {
                output = String.Copy("");
                delete sb;
                delete p;
                return -1;
            }
            for (;;)
            {
                p.ReadAvailable(sb);
                if (p.HasExited && !p.ReadAvailable(sb)) break;
                faset_wait_fd(-1, 5);
            }
            output = sb.ToString();
            int code = p.ExitCode;
            delete sb;
            delete p;
            return code;
        }
    }

    public static class OS
    {
        public static Platform Current => Environment.CurrentPlatform();
        public static bool IsWindows => Environment.CurrentPlatform() == Platform.Windows;
        public static bool IsLinux => Environment.CurrentPlatform() == Platform.Linux;
        public static bool IsAndroid => Environment.CurrentPlatform() == Platform.Android;

        public static string Name()
        {
            switch (Environment.CurrentPlatform())
            {
                case Platform.Linux: return "Linux";
                case Platform.Windows: return "Windows";
                case Platform.Android: return "Android";
                case Platform.MacOS: return "macOS";
                default: return "Desconocido";
            }
        }

        // Copia del valor de una variable de entorno ("" si no existe; libérala con String.Free).
        public static string GetEnv(string name) => Environment.GetVariable(name);
    }
}
