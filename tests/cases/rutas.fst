// std.io: Path (sin tocar el disco), patrones, UTF-16 y FileWatcher.
using std.collections;
using std.io;

void Show(string s)
{
    print("[");
    print(s);
    println("]");
}

void ShowFree(string s)
{
    Show(s);
    String.Free(s);
}

void Check(string label, bool ok)
{
    print(label);
    println(ok ? ": ok" : ": FALLO");
}

bool SeeChange(FileWatcher watcher, WatcherChangeKind kind, string path)
{
    List<FileChange> changes = new List<FileChange>();
    bool seen = false;
    for (int i = 0; i < 50 && !seen; i++)
    {
        watcher.WaitForChanges(changes, 100);
        for (int k = 0; k < changes.Count; k++)
            if (changes[k].Kind == kind && changes[k].Path == path) seen = true;
        FileWatcher.FreeChanges(changes);
    }
    delete changes;
    return seen;
}

void WatchTest(bool polling)
{
    string dir = Directory.CreateTemp("faset-watch-");
    string sub = Path.Combine(dir, "sub");
    Directory.Create(sub);
    FileWatcher watcher = new FileWatcher(dir, true, polling);
    watcher.PollIntervalMs = 20;
    Check(polling ? "Sondeo" : "Nativo", watcher.IsNative == !polling);
    std.time.Time.Sleep(30);
    string f = Path.Combine(sub, "nuevo.txt");
    File.WriteAllText(f, "1");
    Check("  creado", SeeChange(watcher, WatcherChangeKind.Created, f));
    std.time.Time.Sleep(30);
    File.WriteAllText(f, "12");
    Check("  modificado", SeeChange(watcher, WatcherChangeKind.Changed, f));
    File.Delete(f);
    Check("  borrado", SeeChange(watcher, WatcherChangeKind.Deleted, f));
    delete watcher;
    Check("  limpieza", Directory.Delete(dir));
    String.Free(f);
    String.Free(sub);
    String.Free(dir);
}

int main()
{
    // ---- partes de una ruta (vistas)
    Show(Path.GetFileName("/a/b/c.tar.gz"));
    Show(Path.GetExtension("/a/b/c.tar.gz"));
    Show(Path.GetFileNameWithoutExtension("/a/b/c.tar.gz"));
    Show(Path.GetDirectoryName("/a/b/c.tar.gz"));
    Show(Path.GetDirectoryName("/c"));
    Show(Path.GetDirectoryName("/"));
    Show(Path.GetDirectoryName("c"));
    Show(Path.GetExtension(".bashrc"));
    Show(Path.GetPathRoot("/x/y"));
    Check("HasExtension", Path.HasExtension("a.b") && !Path.HasExtension("a.") && !Path.HasExtension("ab"));
    Check("IsRooted", Path.IsRooted("/x") && !Path.IsRooted("x/y") && !Path.IsPathRooted(""));

    // ---- copias
    ShowFree(Path.ChangeExtension("/a/b.txt", "md"));
    ShowFree(Path.ChangeExtension("/a/b.txt", ".fst"));
    ShowFree(Path.ChangeExtension("/a.d/b", "c"));
    ShowFree(Path.ChangeExtension("x.txt", ""));
    ShowFree(Path.Combine("a", "b"));
    ShowFree(Path.Combine("a/", "b"));
    ShowFree(Path.Combine("a", "/abs"));
    ShowFree(Path.Combine("a", "b", "c.txt"));
    ShowFree(Path.Normalize("/a//b/./c/../d/"));
    ShowFree(Path.Normalize("../x/../../y"));
    ShowFree(Path.Normalize("/../a"));
    ShowFree(Path.Normalize(""));
    ShowFree(Path.NormalizeSeparators("a/b"));
    ShowFree(Path.GetRelativePath("/a/b/c", "/a/d/e.txt"));
    ShowFree(Path.GetRelativePath("/a/b", "/a/b"));
    ShowFree(Path.GetRelativePath("/a", "/a/b/c"));
    ShowFree(Path.GetFullPath("/no/existe/../de/verdad"));
    string full = Path.GetFullPath("relativa");
    Check("GetFullPath relativa", Path.IsRooted(full) && full.EndsWith("/relativa"));
    String.Free(full);

    // ---- patrones
    Check("*.fst", Path.MatchesPattern("main.fst", "*.fst") && !Path.MatchesPattern("main.fs", "*.fst"));
    Check("?", Path.MatchesPattern("añb", "a?b") && !Path.MatchesPattern("ab", "a?b"));
    Check("*a*b", Path.MatchesPattern("xxaxxb", "*a*b") && !Path.MatchesPattern("xxaxxbc", "*a*b"));
    Check("*.*", Path.MatchesPattern("sin-punto", "*.*"));
    Check("Mayúsculas", !Path.MatchesPattern("A.FST", "*.fst"));

    // ---- temporales
    string tf = Path.GetTempFileName();
    Check("GetTempFileName", tf.Length > 0 && File.Exists(tf) && File.GetSize(tf) == 0);
    File.Delete(tf);
    String.Free(tf);
    string rnd = Path.GetRandomFileName();
    Check("GetRandomFileName", rnd.Length == 12 && rnd[8] == '.');
    String.Free(rnd);

    // ---- UTF-16
    memory_unsafe  // Utf16 trabaja con búferes ushort*
    {
        int n;
        ushort* w = Utf16.Encode("ñ€😀", out n);
        println(n);
        println((long)w[2]);
        string back = Utf16.Decode(w);
        Show(back);
        String.Free(back);
        Memory.Free(w);
        ushort* bad = Memory.New<ushort>(2);
        bad[0] = 0xD800;   // sustituto suelto
        string fixedText = Utf16.Decode(bad, 1);
        Check("U+FFFD", fixedText == "�");
        String.Free(fixedText);
        Memory.Free(bad);
    }

    // ---- FileWatcher (inotify y sondeo)
    WatchTest(false);
    WatchTest(true);
    return 0;
}
