// std.os: procesos con argv (sin shell), redirecciones, tiempo límite, Kill y entorno.
using std.collections;
using std.text;
using std.io;
using std.os;

void Check(string label, bool ok)
{
    print(label);
    println(ok ? ": ok" : ": FALLO");
}

int main()
{
    // ---- argumentos sin shell: los metacaracteres llegan tal cual
    List<string> args = new List<string>();
    args.Add("-c");
    args.Add("printf '%s|' \"$@\"; echo; echo err >&2; exit 3");
    args.Add("sh");
    args.Add("a b");
    args.Add("$(echo inyectado)");
    args.Add("; rm -rf /");
    args.Add("");
    string outText, errText;
    int code = Process.Execute("sh", args, out outText, out errText);
    println(code);
    print(outText);
    print(errText);
    String.Free(outText);
    String.Free(errText);
    delete args;

    // ---- stdin -> stdout (cat), con más datos que el búfer de la tubería
    ProcessStartInfo si = new ProcessStartInfo("cat");
    si.RedirectStandardInput = true;
    si.RedirectStandardOutput = true;
    Process cat = Process.Start(si);
    delete si;
    Check("Start cat", cat != null && cat.Id > 0);
    StringBuilder big = new StringBuilder();
    for (int i = 0; i < 20000; i++) big.Append("0123456789");
    Check("WriteInput", cat.WriteInput(big.View()));
    cat.CloseInput();
    Check("WaitForExit", cat.WaitForExit(10000) && cat.ExitCode == 0);
    Check("Salida completa", cat.Output == big.View());
    delete big;
    delete cat;

    // ---- tiempo límite y Kill
    List<string> sleepArgs = new List<string>();
    sleepArgs.Add("30");
    Process slow = Process.Start("sleep", sleepArgs);
    delete sleepArgs;
    Check("Timeout", !slow.WaitForExit(50) && !slow.HasExited);
    Check("Kill", slow.Kill());
    Check("Tras Kill", slow.WaitForExit(5000) && slow.ExitCode == 137);
    delete slow;

    // ---- programa inexistente y carpeta de trabajo
    List<string> none = new List<string>();
    Check("No existe", Process.Start("/no/existe/programa", none) == null);
    string tmp = Directory.CreateTemp("faset-proc-");
    ProcessStartInfo pw = new ProcessStartInfo("pwd");
    pw.WorkingDirectory = tmp;
    pw.RedirectStandardOutput = true;
    Process pwd = Process.Start(pw);
    delete pw;
    pwd.WaitForExit();
    string real = Path.GetFullPath(tmp);
    Check("WorkingDirectory", pwd.Output.Trim() == real);
    String.Free(real);
    delete pwd;
    Directory.Delete(tmp);
    String.Free(tmp);
    delete none;

    // ---- entorno del hijo
    Check("SetVariable", Environment.SetVariable("FASET_PRUEBA", "valor 1"));
    string v = Environment.GetVariable("FASET_PRUEBA");
    println(v);
    String.Free(v);
    ProcessStartInfo es = new ProcessStartInfo("sh");
    es.AddArgument("-c").AddArgument("echo \"$FASET_PRUEBA|$FASET_OTRA|${HOME:+home}\"");
    es.SetEnvironment("FASET_OTRA", "x=y");
    es.RemoveEnvironment("FASET_PRUEBA");
    es.RedirectStandardOutput = true;
    Process ep = Process.Start(es);
    delete es;
    ep.WaitForExit();
    print(ep.Output);
    delete ep;
    Dictionary<string, string> vars = Environment.GetVariables();
    Check("GetVariables", vars.ContainsKey("FASET_PRUEBA") && vars.Get("FASET_PRUEBA") == "valor 1");
    Environment.FreeVariables(vars);
    Check("UnsetVariable", Environment.UnsetVariable("FASET_PRUEBA"));
    string gone;
    Check("Ya no existe", !Environment.TryGetVariable("FASET_PRUEBA", out gone));
    String.Free(gone);

    // ---- información del sistema
    string machine = Environment.GetMachineName();
    string user = Environment.GetUserName();
    string home = Environment.GetHomeDirectory();
    string ver = OS.Version();
    string arch = OS.Architecture();
    Check("Sistema", machine.Length > 0 && user.Length > 0 && home.Length > 0 && ver.Length > 0 && arch.Length > 0);
    Check("CPUs y pid", Environment.ProcessorCount > 0 && Environment.ProcessId == Process.CurrentId && Process.CurrentId > 0);
    println(Environment.OSName);
    String.Free(machine);
    String.Free(user);
    String.Free(home);
    String.Free(ver);
    String.Free(arch);

    // ---- compatibilidad: Capture y ChildProcess (shell)
    string captured;
    int c2 = Process.Capture("echo uno; echo dos >&2; exit 4", out captured);
    println(c2);
    print(captured);
    String.Free(captured);
    ChildProcess child = new ChildProcess();
    Check("ChildProcess.Start", child.Start("echo hijo", ""));
    StringBuilder sb = new StringBuilder();
    while (child.IsRunning)
    {
        child.ReadAvailable(sb);
        if (child.HasExited) child.ReadAvailable(sb);
        EventWait.WaitFd(-1, 5);
    }
    print(sb.View());
    println(child.ExitCode);
    delete sb;
    delete child;

    // ---- comillas
    List<string> q = new List<string>();
    q.Add("simple");
    q.Add("con espacio");
    q.Add("comilla\"dentro");
    q.Add("barra\\final\\");
    q.Add("");
    string line = CommandLine.JoinWindows(q);
    println(line);
    String.Free(line);
    delete q;
    string sh = CommandLine.QuoteShell("it's $HOME");
    println(sh);
    String.Free(sh);
    return 0;
}
