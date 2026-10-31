// =============================================================================
//  std.os  —  procesos y sistema operativo.
//
//    Process            lanza programas con argumentos (sin shell), redirige stdin/stdout/stderr,
//                       espera con tiempo límite, código de salida, Kill; Run/Capture con shell
//    ProcessStartInfo   programa, argumentos, carpeta, entorno y redirecciones
//    ChildProcess       comando de shell con la salida combinada leída sin bloquear (IDE)
//    CommandLine        comillas para la línea de órdenes de Windows y para sh
//    Environment        (amplía std.Environment) variables, usuario, máquina, CPUs, pid
//    OS                 nombre, versión y arquitectura del sistema
//
//  Los argumentos nunca pasan por un shell: en POSIX se usa fork + execvp con un argv;
//  en Windows, CreateProcessW con cada argumento entrecomillado según las reglas de
//  CommandLineToArgvW. Solo Process.Run, Process.Capture, ChildProcess y UseShell
//  interpretan una línea de shell (sh -c / cmd.exe /C).
// =============================================================================
using std.collections;
using std.text;
using std.io;

namespace std.os
{
    static extern int faset_system(string command);
    static extern bool faset_wait_fd(int fd, int milliseconds);

    // ======================================================================= ProcessStartInfo

    // Cómo lanzar un proceso. Guarda copias de las cadenas.
    //   ProcessStartInfo si = new ProcessStartInfo("git");
    //   si.AddArgument("status").AddArgument("--short");
    //   si.RedirectStandardOutput = true;
    //   Process p = Process.Start(si);
    public memory_unsafe class ProcessStartInfo
    {
        var fileName: string
        var workingDirectory: string
        var arguments: List<string> = new List<string>();
        var envNames: List<string> = new List<string>();
        var envValues: List<string> = new List<string>();   // Ptr == null: quitar la variable

        public var RedirectStandardInput: bool
        public var RedirectStandardOutput: bool
        public var RedirectStandardError: bool
        // Envía stderr al mismo flujo que stdout (Process.Output).
        public var MergeStandardError: bool
        // Windows: sin ventana de consola nueva.
        public var CreateNoWindow: bool
        // Grupo de procesos propio (POSIX) o Job (Windows): Kill termina también a los nietos.
        public var NewProcessGroup: bool
        // FileName es una línea de shell (sh -c en POSIX, cmd.exe /C en Windows); se ignoran los argumentos.
        public var UseShell: bool

        public init(program: string)
        {
            fileName = String.Copy(program);
            workingDirectory = String.Copy("");
        }

        deinit
        {
            String.Free(fileName);
            String.Free(workingDirectory);
            File.FreeLines(arguments);
            File.FreeLines(envNames);
            File.FreeLines(envValues);
        }

        public prop FileName: string
        {
            get => fileName;
            set
            {
                String.Free(fileName);
                fileName = String.Copy(value);
            }
        }

        // "" = la carpeta actual.
        public prop WorkingDirectory: string
        {
            get => workingDirectory;
            set
            {
                String.Free(workingDirectory);
                workingDirectory = String.Copy(value);
            }
        }

        // Argumentos (sin el programa). Añádelos con AddArgument.
        public prop Arguments: List<string> => arguments;

        public func AddArgument(argument: string) -> ProcessStartInfo
        {
            arguments.Add(String.Copy(argument));
            return this;
        }

        public func AddArguments(list: List<string>) -> ProcessStartInfo
        {
            for (int i = 0; i < list.Count; i++) arguments.Add(String.Copy(list[i]));
            return this;
        }

        // Variable de entorno para el hijo (el resto se hereda).
        public func SetEnvironment(name: string, value: string) { PutEnv(name, String.Copy(value)); }

        // El hijo no heredará esta variable.
        public func RemoveEnvironment(name: string) { PutEnv(name, String.FromBytes(null, 0)); }

        public prop HasEnvironmentChanges: bool => envNames.Count > 0;

        func PutEnv(name: string, ownedValue: string)
        {
            for (int i = 0; i < envNames.Count; i++)
                if (SameEnvName(envNames[i], name))
                {
                    String.Free(envValues[i]);
                    envValues[i] = ownedValue;
                    return;
                }
            envNames.Add(String.Copy(name));
            envValues.Add(ownedValue);
        }

        static func SameEnvName(a: string, b: string) -> bool => OS.IsWindows ? a.EqualsIgnoreCase(b) : a == b;

        // Entorno completo del hijo ("CLAVE=valor", copias) o null si se hereda sin cambios.
        public func BuildEnvironment() -> List<string>
        {
            if (envNames.Count == 0) return null;
            List<string> all = Environment.GetVariableList();
            for (int k = 0; k < envNames.Count; k++)
            {
                for (int i = all.Count - 1; i >= 0; i--)
                {
                    string entry = all[i];
                    int eq = entry.IndexOf("=", 1);
                    string key = eq < 0 ? entry : entry.Substring(0, eq);
                    if (SameEnvName(key, envNames[k]))
                    {
                        String.Free(entry);
                        all.RemoveAt(i);
                    }
                }
                if (envValues[k].Ptr != null) all.Add(String.Concat(envNames[k], "=", envValues[k]));
            }
            return all;
        }
    }

    // ======================================================================= CommandLine

    public memory_unsafe static class CommandLine
    {
        // Entrecomilla un argumento para la línea de órdenes de Windows (reglas de
        // CommandLineToArgvW / del CRT de MSVC). Copia.
        public static func QuoteWindows(arg: string) -> string
        {
            bool needs = arg.Length == 0;
            for (int i = 0; i < arg.Length && !needs; i++)
                if (arg[i] == ' ' || arg[i] == '\t' || arg[i] == '\n' || arg[i] == '\v' || arg[i] == '"') needs = true;
            if (!needs) return String.Copy(arg);
            StringBuilder sb = new StringBuilder(arg.Length + 2);
            sb.Append("\"");
            int i = 0;
            while (i < arg.Length)
            {
                int slashes = 0;
                while (i < arg.Length && arg[i] == '\\')
                {
                    slashes++;
                    i++;
                }
                if (i == arg.Length)
                {
                    sb.AppendRepeat("\\", slashes * 2);   // antes de la comilla final
                    break;
                }
                if (arg[i] == '"') sb.AppendRepeat("\\", slashes * 2 + 1).Append("\"");
                else
                {
                    sb.AppendRepeat("\\", slashes);
                    sb.Append(String.FromBytes(arg.Ptr + i, 1));
                }
                i++;
            }
            sb.Append("\"");
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Entrecomilla SIEMPRE para una línea de cmd.exe (Process.Run / Capture / ChildProcess en
        // Windows): dentro de comillas cmd no interpreta & | < > ^ ( ), y el programa recibe el
        // argumento según las reglas de CommandLineToArgvW. Limitación de cmd: '%VAR%' se expande
        // incluso entre comillas. Copia.
        public static func QuoteCmd(arg: string) -> string
        {
            if (arg.Length == 0) return String.Copy("\"\"");
            bool needs = false;
            for (int i = 0; i < arg.Length && !needs; i++)
                if (arg[i] == ' ' || arg[i] == '\t' || arg[i] == '"') needs = true;
            if (needs) return QuoteWindows(arg);
            // Sin espacios QuoteWindows no pone comillas: se añaden (y las '\' finales se duplican).
            int slashes = 0;
            while (slashes < arg.Length && arg[arg.Length - 1 - slashes] == '\\') slashes++;
            StringBuilder sb = new StringBuilder(arg.Length + slashes + 2);
            sb.Append("\"").Append(arg).AppendRepeat("\\", slashes).Append("\"");
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Une argumentos en una línea de órdenes de Windows. Copia.
        public static func JoinWindows(args: List<string>) -> string
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < args.Count; i++)
            {
                if (i > 0) sb.Append(" ");
                string q = QuoteWindows(args[i]);
                sb.Append(q);
                String.Free(q);
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Entrecomilla para sh ('...'), seguro para pasar a Process.Run en POSIX. Copia.
        public static func QuoteShell(arg: string) -> string
        {
            bool plain = arg.Length > 0;
            for (int i = 0; i < arg.Length && plain; i++)
            {
                char c = (char)arg[i];
                if (!(Char.IsLetterOrDigit(c) && c < 0x80) && c != '-' && c != '_' && c != '.' && c != '/' && c != '=' && c != ':' && c != ',' && c != '+')
                    plain = false;
            }
            if (plain) return String.Copy(arg);
            string inner = Text.Replace(arg, "'", "'\\''");
            string r = String.Concat("'", inner, "'");
            String.Free(inner);
            return r;
        }
    }

    // ======================================================================= capa nativa

#if WINDOWS
    memory_unsafe struct WinSecurityAttributes
    {
        public var nLength: uint
        public var lpSecurityDescriptor: void*
        public var bInheritHandle: int
    }

    memory_unsafe struct WinStartupInfo
    {
        public var cb: uint
        public var lpReserved: ushort*
        public var lpDesktop: ushort*
        public var lpTitle: ushort*
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public var wShowWindow: ushort
        public var cbReserved2: ushort
        public var lpReserved2: byte*
        public var hStdInput: void*
        public var hStdOutput: void*
        public var hStdError: void*
    }

    memory_unsafe struct WinProcessInformation
    {
        public var hProcess: void*
        public var hThread: void*
        public var dwProcessId: uint
        public var dwThreadId: uint
    }

    static class Kernel32
    {
        public static extern int CreatePipe(void** readPipe, void** writePipe, WinSecurityAttributes* security, uint size);
        public static extern int SetHandleInformation(void* h, uint mask, uint flags);
        public static extern int CreateProcessW(ushort* application, ushort* commandLine, void* processSecurity, void* threadSecurity,
                                                int inheritHandles, uint flags, void* environment, ushort* currentDirectory,
                                                WinStartupInfo* startup, WinProcessInformation* info);
        public static extern void* GetStdHandle(uint which);
        public static extern int PeekNamedPipe(void* h, void* buffer, uint size, uint* read, uint* available, uint* left);
        public static extern int ReadFile(void* h, void* buffer, uint count, uint* done, void* overlapped);
        public static extern int WriteFile(void* h, void* buffer, uint count, uint* done, void* overlapped);
        public static extern int CloseHandle(void* h);
        public static extern uint WaitForSingleObject(void* h, uint milliseconds);
        public static extern int GetExitCodeProcess(void* h, uint* code);
        public static extern int TerminateProcess(void* h, uint code);
        public static extern uint ResumeThread(void* thread);
        public static extern void* CreateJobObjectW(void* security, ushort* name);
        public static extern int AssignProcessToJobObject(void* job, void* process);
        public static extern int TerminateJobObject(void* job, uint code);
        public static extern uint GetCurrentProcessId();
        public static extern void Sleep(uint milliseconds);
    }
#else
    static class Posix
    {
        public static extern int faset_px_spawn(string* argv, int argc, string* env, int envc, string cwd, int flags, int* result);
        public static extern int faset_px_wait(int pid, bool block);
        public static extern bool faset_px_kill(int pid, bool group);
        public static extern int faset_px_read_nb(int fd, byte* buffer, int capacity);
        public static extern int faset_px_write_nb(int fd, byte* data, int count);
        public static extern bool faset_px_poll(int* fds, int count, int writeFd, int milliseconds);
        public static extern void faset_px_close(long fd);
        public static extern int faset_px_getpid();
    }
#endif

    // ======================================================================= Process

    // Proceso hijo. Con salida redirigida, la salida se acumula en Output / Error mientras
    // se espera (WaitForExit) o al leerla (ReadOutput), así el hijo nunca se bloquea por
    // tener la tubería llena. delete cierra los manejadores pero no mata al proceso.
    public memory_unsafe class Process
    {
        var handle: long = -1;        // POSIX: pid; Windows: HANDLE del proceso
        var job: long = -1;           // Windows: Job para Kill del árbol
        var inPipe: long = -1;
        var outPipe: long = -1;
        var errPipe: long = -1;
        var pid: int
        var group: bool
        var exited: bool
        var exitCode: int = -1;
        var outBuf: StringBuilder = new StringBuilder();
        var errBuf: StringBuilder = new StringBuilder();

        deinit
        {
            CloseStream(ref inPipe);
            CloseStream(ref outPipe);
            CloseStream(ref errPipe);
#if WINDOWS
            if (job != -1) Kernel32.CloseHandle((void*)job);
            if (handle != -1) Kernel32.CloseHandle((void*)handle);
#else
            if (!exited && handle > 0) Posix.faset_px_wait(pid, false);
#endif
            delete outBuf;
            delete errBuf;
        }

        // ---------------------------------------------------------------- estáticos

        // Ejecuta una línea de shell heredando la consola y devuelve el estado de system.
        public static func Run(command: string) -> int => faset_system(command);

        // Ejecuta una línea de shell, espera a que termine y devuelve su código de salida;
        // 'output' recibe stdout + stderr (copia). -1 si no arranca.
        public static func Capture(command: string, out output: string) -> int
        {
            ProcessStartInfo si = new ProcessStartInfo(command);
            si.UseShell = true;
            si.RedirectStandardOutput = true;
            si.MergeStandardError = true;
            si.CreateNoWindow = true;
            Process p = Start(si);
            delete si;
            if (p == null)
            {
                output = String.Copy("");
                return -1;
            }
            p.WaitForExit();
            output = String.Copy(p.Output);
            int code = p.ExitCode;
            delete p;
            return code;
        }

        // Lanza un proceso. Devuelve null si no se pudo (programa inexistente, carpeta no válida...).
        public static func Start(info: ProcessStartInfo) -> Process
        {
            Process p = new Process();
            if (!p.Launch(info))
            {
                delete p;
                return null;
            }
            return p;
        }

        // Lanza 'fileName' (se busca en el PATH) con argumentos, heredando la consola.
        public static func Start(fileName: string, args: List<string>) -> Process
        {
            ProcessStartInfo si = new ProcessStartInfo(fileName);
            si.AddArguments(args);
            Process p = Start(si);
            delete si;
            return p;
        }

        // Ejecuta un programa con argumentos (sin shell), espera y captura stdout y stderr
        // por separado (copias). Devuelve el código de salida o -1 si no arranca.
        public static func Execute(fileName: string, args: List<string>, out stdout: string, out stderr: string) -> int
        {
            ProcessStartInfo si = new ProcessStartInfo(fileName);
            si.AddArguments(args);
            si.RedirectStandardOutput = true;
            si.RedirectStandardError = true;
            si.CreateNoWindow = true;
            Process p = Start(si);
            delete si;
            if (p == null)
            {
                stdout = String.Copy("");
                stderr = String.Copy("");
                return -1;
            }
            p.WaitForExit();
            stdout = String.Copy(p.Output);
            stderr = String.Copy(p.Error);
            int code = p.ExitCode;
            delete p;
            return code;
        }

        // Identificador del proceso actual.
        public static prop CurrentId: int
        {
            get
            {
#if WINDOWS
                return (int)Kernel32.GetCurrentProcessId();
#else
                return Posix.faset_px_getpid();
#endif
            }
        }

        // ---------------------------------------------------------------- estado

        public prop Id: int => pid;

        public prop HasExited: bool
        {
            get
            {
                if (!exited) CheckExit(false);
                return exited;
            }
        }

        // Código de salida (-1 mientras siga en ejecución). En POSIX, 128 + señal si lo mató una señal.
        public prop ExitCode: int
        {
            get
            {
                if (!exited) CheckExit(false);
                return exitCode;
            }
        }

        // Espera a que termine (leyendo la salida redirigida mientras tanto).
        public func WaitForExit() { WaitForExit(-1); }

        // Espera hasta 'milliseconds' (-1 = sin límite). true si terminó.
        public func WaitForExit(milliseconds: int) -> bool
        {
            long start = Environment.TickCount64();
            for (;;)
            {
                Pump();
                if (CheckExit(false))
                {
                    Pump();   // lo que quedó en las tuberías
                    return true;
                }
                long left = milliseconds < 0 ? 10 : milliseconds - (Environment.TickCount64() - start);
                if (left <= 0) return false;
                Idle(left < 10 ? (int)left : 10);
            }
        }

        // Termina el proceso (y su grupo/Job si se creó con NewProcessGroup).
        public func Kill() -> bool
        {
            if (handle == -1 || HasExited) return false;
#if WINDOWS
            if (job != -1 && Kernel32.TerminateJobObject((void*)job, 1) != 0) return true;
            return Kernel32.TerminateProcess((void*)handle, 1) != 0;
#else
            return Posix.faset_px_kill(pid, group);
#endif
        }

        // ---------------------------------------------------------------- salida

        // Salida acumulada aún no retirada con ReadOutput (vista válida hasta la próxima lectura).
        public prop Output: string => outBuf.View();
        public prop Error: string => errBuf.View();

        // Lee lo disponible sin bloquear y lo mueve a 'destination'. true si añadió algo.
        public func ReadOutput(destination: StringBuilder) -> bool => Take(outBuf, destination);
        public func ReadError(destination: StringBuilder) -> bool => Take(errBuf, destination);

        // true cuando la salida estándar llegó al final (o no está redirigida).
        public prop OutputEnded: bool => outPipe == -1;

        // Espera hasta 'milliseconds' a que el hijo escriba algo (sin consumir su CPU) y lo
        // acumula en Output / Error. true si hay salida pendiente de leer. Pensado para un
        // hilo lector: vuelve en cuanto llegan datos, no al vencer el plazo.
        public func WaitForOutput(milliseconds: int) -> bool
        {
            Pump();
            if (outBuf.Length > 0 || errBuf.Length > 0) return true;
            if (outPipe == -1 && errPipe == -1) return false;
#if WINDOWS
            // Una tubería anónima no se puede esperar: se sondea a intervalos cortos.
            long start = Environment.TickCount64();
            while (Environment.TickCount64() - start < milliseconds)
            {
                Kernel32.Sleep(1);
                Pump();
                if (outBuf.Length > 0 || errBuf.Length > 0 || (outPipe == -1 && errPipe == -1)) break;
            }
#else
            Idle(milliseconds);
            Pump();
#endif
            return outBuf.Length > 0 || errBuf.Length > 0;
        }

        // Descarta lo acumulado en Output / Error (p. ej. tras procesarlo con la vista Output,
        // sin copiarlo con ReadOutput). No lee de las tuberías.
        public func ClearOutput() { outBuf.Clear(); }
        public func ClearError() { errBuf.Clear(); }

        func Take(from: StringBuilder, destination: StringBuilder) -> bool
        {
            Pump();
            if (from.Length == 0) return false;
            destination.Append(from.View());
            from.Clear();
            return true;
        }

        // ---------------------------------------------------------------- entrada

        // Escribe en la entrada estándar del hijo (RedirectStandardInput). false si se cerró.
        public func WriteInput(text: string) -> bool => WriteInput(text.Ptr, text.Length);

        public func WriteInput(data: byte*, count: int) -> bool
        {
            if (inPipe == -1) return false;
            int done = 0;
            while (done < count)
            {
#if WINDOWS
                uint wrote = 0;
                uint chunk = count - done > 4096 ? (uint)4096 : (uint)(count - done);
                if (Kernel32.WriteFile((void*)inPipe, data + done, chunk, &wrote, null) == 0) return false;
                done += (int)wrote;
                Pump();
#else
                int n = Posix.faset_px_write_nb((int)inPipe, data + done, count - done);
                if (n < 0) return false;
                done += n;
                if (n == 0)
                {
                    // Tubería llena: vacía la salida del hijo para que pueda seguir leyendo.
                    Pump();
                    if (CheckExit(false)) return false;
                    int* fds = Memory.New<int>(2);
                    fds[0] = (int)outPipe;
                    fds[1] = (int)errPipe;
                    Posix.faset_px_poll(fds, 2, (int)inPipe, 20);
                    Memory.Free(fds);
                }
#endif
            }
            return true;
        }

        // Cierra la entrada estándar del hijo (le envía fin de archivo).
        public func CloseInput() { CloseStream(ref inPipe); }

        // ---------------------------------------------------------------- interno

        static func CloseStream(ref h: long)
        {
            if (h == -1) return;
#if WINDOWS
            Kernel32.CloseHandle((void*)h);
#else
            Posix.faset_px_close(h);
#endif
            h = -1;
        }

        // Mueve a los búferes lo que haya en las tuberías, sin bloquear.
        func Pump()
        {
            if (outPipe == -1 && errPipe == -1) return;
            byte* buf = (byte*)Memory.Alloc(8192);
            Drain(ref outPipe, outBuf, buf);
            Drain(ref errPipe, errBuf, buf);
            Memory.Free(buf);
        }

        static func Drain(ref pipe: long, into: StringBuilder, buf: byte*)
        {
            while (pipe != -1)
            {
                int n = ReadPipe(pipe, buf, 8192);
                if (n < 0) CloseStream(ref pipe);
                if (n <= 0) break;
                into.Append(String.FromBytes(buf, n));
            }
        }

        // Bytes leídos (>0), 0 si no hay datos ahora, -1 al final.
        static func ReadPipe(pipe: long, buf: byte*, cap: int) -> int
        {
#if WINDOWS
            uint avail = 0;
            if (Kernel32.PeekNamedPipe((void*)pipe, null, 0, null, &avail, null) == 0) return -1;
            if (avail == 0) return 0;
            uint got = 0;
            if (Kernel32.ReadFile((void*)pipe, buf, avail < (uint)cap ? avail : (uint)cap, &got, null) == 0) return -1;
            return (int)got;
#else
            return Posix.faset_px_read_nb((int)pipe, buf, cap);
#endif
        }

        func CheckExit(block: bool) -> bool
        {
            if (exited) return true;
            if (handle == -1) return false;
#if WINDOWS
            if (Kernel32.WaitForSingleObject((void*)handle, block ? 0xFFFFFFFF : (uint)0) != 0) return false;
            uint code = 0;
            Kernel32.GetExitCodeProcess((void*)handle, &code);
            exitCode = (int)code;
#else
            int r = Posix.faset_px_wait(pid, block);
            if (r == -1) return false;
            exitCode = r == -2 ? -1 : r;
#endif
            exited = true;
            return true;
        }

        // Espera hasta 'ms' a que haya salida o a que el proceso termine.
        func Idle(ms: int)
        {
#if WINDOWS
            Kernel32.WaitForSingleObject((void*)handle, (uint)ms);
#else
            int* fds = Memory.New<int>(2);
            fds[0] = (int)outPipe;
            fds[1] = (int)errPipe;
            Posix.faset_px_poll(fds, 2, -1, ms);
            Memory.Free(fds);
#endif
        }

        func Launch(info: ProcessStartInfo) -> bool
        {
            group = info.NewProcessGroup;
            List<string> env = info.BuildEnvironment();
            bool ok;
#if WINDOWS
            ok = LaunchWindows(info, env);
#else
            ok = LaunchPosix(info, env);
#endif
            if (env != null) File.FreeLines(env);
            return ok;
        }

#if WINDOWS
        func LaunchWindows(info: ProcessStartInfo, env: List<string>) -> bool
        {
            string cmd;
            ushort* app = null;
            if (info.UseShell)
            {
                string comspec = Environment.GetVariable("ComSpec");
                if (comspec.Length == 0)
                {
                    String.Free(comspec);
                    comspec = String.Copy("C:\\Windows\\System32\\cmd.exe");
                }
                app = Utf16.Encode(comspec);
                String.Free(comspec);
                cmd = String.Concat("cmd.exe /D /S /C \"", info.FileName, "\"");
            }
            else
            {
                // CreateProcess ejecutaría un .bat/.cmd con cmd.exe y sus reglas de comillas:
                // se rechaza para no permitir inyección (usa UseShell si lo necesitas).
                string ext = Path.GetExtension(info.FileName);
                if (ext.EqualsIgnoreCase(".bat") || ext.EqualsIgnoreCase(".cmd") || info.FileName.Contains("\"")) return false;
                StringBuilder sb = new StringBuilder();
                bool spaced = info.FileName.Contains(" ") || info.FileName.Contains("\t") || info.FileName.Length == 0;
                if (spaced) sb.Append("\"").Append(info.FileName).Append("\"");
                else sb.Append(info.FileName);
                if (info.Arguments.Count > 0)
                {
                    string rest = CommandLine.JoinWindows(info.Arguments);
                    sb.Append(" ").Append(rest);
                    String.Free(rest);
                }
                cmd = sb.ToString();
                delete sb;
            }

            WinSecurityAttributes sa = new WinSecurityAttributes();
            sa.nLength = (uint)sizeof(WinSecurityAttributes);
            sa.bInheritHandle = 1;
            void* inRd = null;
            void* inWr = null;
            void* outRd = null;
            void* outWr = null;
            void* errRd = null;
            void* errWr = null;
            bool pipesOk = true;
            if (info.RedirectStandardInput && Kernel32.CreatePipe(&inRd, &inWr, &sa, 65536) == 0) pipesOk = false;
            if (info.RedirectStandardOutput && Kernel32.CreatePipe(&outRd, &outWr, &sa, 65536) == 0) pipesOk = false;
            if (info.RedirectStandardError && !info.MergeStandardError && Kernel32.CreatePipe(&errRd, &errWr, &sa, 65536) == 0) pipesOk = false;
            // Los extremos del padre no se heredan.
            if (inWr != null) Kernel32.SetHandleInformation(inWr, 1, 0);
            if (outRd != null) Kernel32.SetHandleInformation(outRd, 1, 0);
            if (errRd != null) Kernel32.SetHandleInformation(errRd, 1, 0);

            WinStartupInfo si = new WinStartupInfo();
            si.cb = (uint)sizeof(WinStartupInfo);
            si.dwFlags = 0x100;   // STARTF_USESTDHANDLES
            si.hStdInput = inRd != null ? inRd : Kernel32.GetStdHandle(0xFFFFFFF6);
            si.hStdOutput = outWr != null ? outWr : Kernel32.GetStdHandle(0xFFFFFFF5);
            si.hStdError = info.MergeStandardError ? si.hStdOutput : errWr != null ? errWr : Kernel32.GetStdHandle(0xFFFFFFF4);

            ushort* block = null;
            if (env != null)
            {
                // Bloque UTF-16 "A=1\0B=2\0\0".
                StringBuilder eb = new StringBuilder();
                for (int i = 0; i < env.Count; i++) eb.Append(env[i]).Append((char)0);
                eb.Append((char)0);
                block = Utf16.Encode(eb.View());
                delete eb;
            }
            uint flags = 0x400;                            // CREATE_UNICODE_ENVIRONMENT
            if (info.CreateNoWindow) flags |= 0x08000000;  // CREATE_NO_WINDOW
            if (info.NewProcessGroup) flags |= 0x200 | 0x4; // CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED
            ushort* wcmd = Utf16.Encode(cmd);
            ushort* wdir = info.WorkingDirectory.Length > 0 ? Utf16.Encode(info.WorkingDirectory) : null;
            WinProcessInformation pi = new WinProcessInformation();
            bool ok = pipesOk && Kernel32.CreateProcessW(app, wcmd, null, null, 1, flags, block, wdir, &si, &pi) != 0;
            Memory.Free(wcmd);
            Memory.Free(wdir);
            Memory.Free(block);
            Memory.Free(app);
            String.Free(cmd);

            // Los extremos del hijo ya no hacen falta en el padre.
            if (inRd != null) Kernel32.CloseHandle(inRd);
            if (outWr != null) Kernel32.CloseHandle(outWr);
            if (errWr != null) Kernel32.CloseHandle(errWr);
            if (!ok)
            {
                if (inWr != null) Kernel32.CloseHandle(inWr);
                if (outRd != null) Kernel32.CloseHandle(outRd);
                if (errRd != null) Kernel32.CloseHandle(errRd);
                return false;
            }
            if (info.NewProcessGroup)
            {
                void* j = Kernel32.CreateJobObjectW(null, null);
                if (j != null && Kernel32.AssignProcessToJobObject(j, pi.hProcess) != 0) job = (long)j;
                else if (j != null) Kernel32.CloseHandle(j);
                Kernel32.ResumeThread(pi.hThread);
            }
            Kernel32.CloseHandle(pi.hThread);
            handle = (long)pi.hProcess;
            pid = (int)pi.dwProcessId;
            inPipe = inWr != null ? (long)inWr : -1;
            outPipe = outRd != null ? (long)outRd : -1;
            errPipe = errRd != null ? (long)errRd : -1;
            return true;
        }
#else
        func LaunchPosix(info: ProcessStartInfo, env: List<string>) -> bool
        {
            List<string> argv = new List<string>();
            if (info.UseShell)
            {
#if ANDROID
                argv.Add("/system/bin/sh");
#else
                argv.Add("/bin/sh");
#endif
                argv.Add("-c");
                argv.Add(info.FileName);
            }
            else
            {
                argv.Add(info.FileName);
                argv.AddRange(info.Arguments);
            }
            int flags = 0;
            if (info.RedirectStandardInput) flags |= 1;
            if (info.RedirectStandardOutput) flags |= 2;
            if (info.RedirectStandardError) flags |= 4;
            if (info.MergeStandardError) flags |= 8;
            if (info.NewProcessGroup) flags |= 16;
            if (env != null) flags |= 32;
            int* result = Memory.New<int>(4);
            int err = Posix.faset_px_spawn(argv.Data, argv.Count, env != null ? env.Data : null, env != null ? env.Count : 0,
                                           info.WorkingDirectory, flags, result);
            delete argv;
            if (err == 0)
            {
                pid = result[0];
                handle = pid;
                inPipe = result[1];
                outPipe = result[2];
                errPipe = result[3];
            }
            Memory.Free(result);
            return err == 0;
        }
#endif
    }

    // ======================================================================= ChildProcess

    // Comando de shell con stdout + stderr combinados, leídos sin bloquear (lo usa FasetStudio):
    //   auto p = new ChildProcess;
    //   p.Start("faset build", "");
    //   while (!p.HasExited) { p.ReadAvailable(sb); ... }
    // Kill termina también los procesos que lance el comando (grupo / Job).
    public class ChildProcess
    {
        var proc: Process
        var finished: bool

        deinit { if (proc != null) delete proc; }

        public func Start(command: string, workingDir: string) -> bool
        {
            if (proc != null) delete proc;
            ProcessStartInfo si = new ProcessStartInfo(command);
            si.UseShell = true;
            si.WorkingDirectory = workingDir;
            si.RedirectStandardOutput = true;
            si.MergeStandardError = true;
            si.NewProcessGroup = true;
            si.CreateNoWindow = true;
            proc = Process.Start(si);
            delete si;
            finished = false;
            return proc != null;
        }

        public prop IsRunning: bool => proc != null && !finished;

        // Añade a 'output' lo que el proceso haya escrito; devuelve true si añadió algo.
        public func ReadAvailable(output: StringBuilder) -> bool
        {
            if (proc == null) return false;
            bool any = proc.ReadOutput(output);
            if (!any && !finished && proc.OutputEnded && proc.HasExited) finished = true;
            return any;
        }

        public prop HasExited: bool
        {
            get
            {
                if (proc == null || finished) return true;
                if (!proc.HasExited) return false;
                finished = true;
                return true;
            }
        }

        public prop ExitCode: int => proc != null ? proc.ExitCode : -1;
        public prop Id: int => proc != null ? proc.Id : 0;

        public func Kill() { if (proc != null) proc.Kill(); }
    }

    public memory_unsafe static class EventWait
    {
        // Espera hasta 'milliseconds' a que el descriptor 'fd' tenga datos.
        public static func WaitFd(fd: int, milliseconds: int) -> bool => faset_wait_fd(fd, milliseconds);
    }

    // ======================================================================= OS

    public static class OS
    {
        public static prop Current: Platform => Environment.CurrentPlatform();
        public static prop IsWindows: bool => Environment.CurrentPlatform() == Platform.Windows;
        public static prop IsLinux: bool => Environment.CurrentPlatform() == Platform.Linux;
        public static prop IsAndroid: bool => Environment.CurrentPlatform() == Platform.Android;

        public static func Name() -> string
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

        // Versión del sistema: "10.0.22631" en Windows, la del núcleo en POSIX (copia).
        public static func Version() -> string => Environment.GetOSVersion();

        // Arquitectura de la máquina: "x86_64", "aarch64", "AMD64", "ARM64"... (copia).
        public static func Architecture() -> string => Environment.GetArchitecture();

        // Copia del valor de una variable de entorno ("" si no existe).
        public static func GetEnv(name: string) -> string => Environment.GetVariable(name);
    }
}

// ======================================================================= Environment
//  Amplía std.Environment (core.fst) cuando se importa std.os.
namespace std
{
    public memory_unsafe static partial class Environment
    {
#if WINDOWS
        static extern int SetEnvironmentVariableW(ushort* name, ushort* value);
        static extern ushort* GetEnvironmentStringsW();
        static extern int FreeEnvironmentStringsW(ushort* block);
        static extern int GetComputerNameW(ushort* buffer, uint* size);
        static extern int GetUserNameW(ushort* buffer, uint* size);
        static extern uint GetActiveProcessorCount(ushort group);
        static extern uint GetCurrentProcessId();
        static extern void* GetModuleHandleW(ushort* name);
        static extern void* GetProcAddress(void* module, byte* name);
#else
        static extern bool faset_px_setenv(string name, string value);
        static extern bool faset_px_unsetenv(string name);
        static extern string faset_px_environ();
        static extern string faset_px_sysinfo(int what);
        static extern int faset_px_nprocs();
        static extern int faset_px_getpid();
#endif

        // Crea o cambia una variable del proceso actual (la heredan los hijos).
        public static func SetVariable(name: string, value: string) -> bool
        {
            if (name.Length == 0 || name.Contains("=")) return false;
#if WINDOWS
            ushort* n = Utf16.Encode(name);
            ushort* v = Utf16.Encode(value);
            bool ok = SetEnvironmentVariableW(n, v) != 0;
            Memory.Free(n);
            Memory.Free(v);
            return ok;
#else
            return faset_px_setenv(name, value);
#endif
        }

        // Quita una variable del proceso actual.
        public static func UnsetVariable(name: string) -> bool
        {
            if (name.Length == 0 || name.Contains("=")) return false;
#if WINDOWS
            ushort* n = Utf16.Encode(name);
            bool ok = SetEnvironmentVariableW(n, null) != 0 || GetLastError() == 203;
            Memory.Free(n);
            return ok;
#else
            return faset_px_unsetenv(name);
#endif
        }

        // Todas las variables como "CLAVE=valor" (copias).
        public static func GetVariableList() -> List<string>
        {
            List<string> list = new List<string>();
#if WINDOWS
            ushort* block = GetEnvironmentStringsW();
            if (block != null)
            {
                ushort* p = block;
                while (*p != 0)
                {
                    int n = 0;
                    while (p[n] != 0) n++;
                    list.Add(Utf16.Decode(p, n));
                    p += n + 1;
                }
                FreeEnvironmentStringsW(block);
            }
#else
            string raw = faset_px_environ();
            int start = 0;
            for (int i = 0; i < raw.Length; i++)
            {
                if (raw[i] != 0) continue;
                if (i > start) list.Add(String.Copy(raw.Substring(start, i - start)));
                start = i + 1;
            }
            String.Free(raw);
#endif
            return list;
        }

        // Todas las variables (claves y valores copiados).
        public static func GetVariables() -> Dictionary<string, string>
        {
            Dictionary<string, string> map = new Dictionary<string, string>();
            List<string> list = GetVariableList();
            for (int i = 0; i < list.Count; i++)
            {
                string e = list[i];
                int eq = e.IndexOf("=", 1);   // en Windows hay claves como "=C:"
                if (eq > 0)
                {
                    string key = e.Substring(0, eq);
                    if (!map.ContainsKey(key)) map.Set(String.Copy(key), String.Copy(e.Substring(eq + 1)));
                }
                String.Free(e);
            }
            delete list;
            return map;
        }

        public static func FreeVariables(map: Dictionary<string, string>)
        {
            // Primero se recogen claves y valores: liberar una clave rompería las búsquedas.
            List<string> keys = map.Keys();
            List<string> values = map.Values();
            delete map;
            File.FreeLines(keys);
            File.FreeLines(values);
        }

        // Nombre de la máquina (copia).
        public static func GetMachineName() -> string
        {
#if WINDOWS
            ushort* buf = Memory.New<ushort>(256);
            uint n = 256;
            string s = GetComputerNameW(buf, &n) != 0 ? Utf16.Decode(buf, (int)n) : String.Copy("");
            Memory.Free(buf);
            return s;
#else
            return faset_px_sysinfo(0);
#endif
        }

        // Usuario actual (copia).
        public static func GetUserName() -> string
        {
#if WINDOWS
            ushort* buf = Memory.New<ushort>(257);
            uint n = 257;
            string s = GetUserNameW(buf, &n) != 0 ? Utf16.Decode(buf) : GetVariable("USERNAME");
            Memory.Free(buf);
            return s;
#else
            return faset_px_sysinfo(1);
#endif
        }

        // Carpeta personal: $HOME o %USERPROFILE% (copia).
        public static func GetHomeDirectory() -> string
        {
#if WINDOWS
            return GetVariable("USERPROFILE");
#else
            return faset_px_sysinfo(2);
#endif
        }

        // Versión del sistema operativo (copia).
        public static func GetOSVersion() -> string
        {
#if WINDOWS
            // RtlGetVersion no miente según el manifiesto (a diferencia de GetVersionEx).
            ushort* ntdll = Utf16.Encode("ntdll.dll");
            void* module = GetModuleHandleW(ntdll);
            Memory.Free(ntdll);
            if (module == null) return String.Copy("");
            void* fn = GetProcAddress(module, "RtlGetVersion".Ptr);
            if (fn == null) return String.Copy("");
            delegate*<byte*, int> rtlGetVersion = (delegate*<byte*, int>)fn;
            byte* info = (byte*)Memory.AllocZeroed(284);   // RTL_OSVERSIONINFOW
            info[0] = (byte)20;   // dwOSVersionInfoSize = 276
            info[1] = (byte)1;
            rtlGetVersion(info);
            uint* v = (uint*)info;
            StringBuilder sb = new StringBuilder();
            sb.Append((ulong)v[1]).Append(".").Append((ulong)v[2]).Append(".").Append((ulong)v[3]);
            Memory.Free(info);
            string s = sb.ToString();
            delete sb;
            return s;
#else
            return faset_px_sysinfo(3);
#endif
        }

        // Arquitectura de la máquina (copia).
        public static func GetArchitecture() -> string
        {
#if WINDOWS
            return GetVariable("PROCESSOR_ARCHITECTURE");
#else
            return faset_px_sysinfo(4);
#endif
        }

        // Procesadores lógicos disponibles.
        public static prop ProcessorCount: int
        {
            get
            {
#if WINDOWS
                return (int)GetActiveProcessorCount(0xFFFF);
#else
                return faset_px_nprocs();
#endif
            }
        }

        // Identificador del proceso actual.
        public static prop ProcessId: int
        {
            get
            {
#if WINDOWS
                return (int)GetCurrentProcessId();
#else
                return faset_px_getpid();
#endif
            }
        }

        // Nombre del sistema operativo ("Linux", "Windows"...).
        public static prop OSName: string => std.os.OS.Name();

        // Salto de línea del sistema.
        public static prop NewLine: string => Platform.Windows == CurrentPlatform() ? "\r\n" : "\n";
    }
}
