// std.io: archivos, flujos, carpetas, rutas y metadatos (solo dentro de una carpeta temporal).
using std.collections;
using std.text;
using std.io;

void Check(string label, bool ok)
{
    print(label);
    println(ok ? ": ok" : ": FALLO");
}

void PrintList(string base, List<string> items)
{
    for (int i = 0; i < items.Count; i++)
    {
        string rel = Path.GetRelativePath(base, items[i]);
        println(rel);
        String.Free(rel);
    }
}

int main()
{
    string tmp = Directory.CreateTemp("faset-io-");
    Check("CreateTemp", tmp.Length > 0 && Directory.Exists(tmp));

    // ---- texto, bytes y líneas
    string a = Path.Combine(tmp, "a.txt");
    Check("WriteAllText", File.WriteAllText(a, "hola\r\nmundo\n"));
    Check("AppendAllText", File.AppendAllText(a, "fin"));
    Check("Exists", File.Exists(a) && !Directory.Exists(a));
    println(File.GetSize(a));
    List<string> lines = File.ReadAllLines(a);
    println(lines.Count);
    for (int i = 0; i < lines.Count; i++) println(lines[i]);
    File.FreeLines(lines);

    string b = Path.Combine(tmp, "b.bin");
    memory_unsafe  // las API de bytes usan punteros
    {
        byte* data;
        long len;
        Check("TryReadAllBytes", File.TryReadAllBytes(a, out data, out len) && len == 15 && data[0] == 'h');
        Memory.Free(data);
        byte* raw = (byte*)Memory.Alloc(256);
        for (int i = 0; i < 256; i++) raw[i] = (byte)i;
        Check("WriteAllBytes", File.WriteAllBytes(b, raw, 256));
        Memory.Free(raw);
        Check("ReadAllBytes", File.TryReadAllBytes(b, out data, out len) && len == 256 && data[255] == 255);
        Memory.Free(data);
    }

    // ---- copiar, mover, borrar
    string c = Path.Combine(tmp, "c.txt");
    Check("Copy", File.Copy(a, c));
    Check("Copy sin sobrescribir falla", !File.Copy(b, c));
    Check("Copy con sobrescritura", File.Copy(b, c, true) && File.GetSize(c) == 256);
    string d = Path.Combine(tmp, "d.txt");
    Check("Move", File.Move(c, d) && !File.Exists(c) && File.Exists(d));
    Check("Move sin sobrescribir falla", !File.Move(a, d));
    Check("Move con sobrescritura", File.Move(d, a, true) && File.GetSize(a) == 256);
    Check("Delete", File.Delete(a) && !File.Exists(a));
    Check("Delete inexistente", !File.Delete(a));

    // ---- FileStream
    string s = Path.Combine(tmp, "flujo.txt");
    FileStream w = File.OpenWrite(s);
    Check("OpenWrite", w != null);
    for (int i = 0; i < 3000; i++)
    {
        w.Write("línea ");
        StringBuilder sb = new StringBuilder();
        sb.Append((long)i);
        w.WriteLine(sb.View());
        delete sb;
    }
    println(w.Position);
    delete w;
    FileStream r = File.OpenRead(s);
    string line;
    int count = 0;
    string last = String.Copy("");
    while (r.ReadLine(out line))
    {
        count++;
        String.Free(last);
        last = line;
    }
    println(count);
    println(last);
    String.Free(last);
    Check("EndOfStream", r.EndOfStream);
    r.Seek(7, SeekOrigin.Begin);
    Check("Seek + ReadByte", r.ReadByte() == '0' && r.Position == 8);
    println(r.Length);
    delete r;

    FileStream rw = File.Open(s, FileMode.Open, FileAccess.ReadWrite);
    rw.Seek(-5, SeekOrigin.End);
    rw.Write("XY");
    rw.Seek(0, SeekOrigin.Begin);
    Check("ReadWrite", rw.ReadByte() == 'l');
    rw.SetLength(10);
    string all = rw.ReadToEnd();
    println(all.Length);
    String.Free(all);
    println(rw.Length);
    delete rw;
    FileStream ap = File.OpenAppend(s);
    ap.Write("++");
    delete ap;
    string content = File.ReadAllText(s);
    println(content);
    String.Free(content);
    Check("CreateNew existente falla", File.Open(s, FileMode.CreateNew, FileAccess.Write) == null);
    Check("OpenRead inexistente", File.OpenRead("/no/existe/x") == null);

    // ---- metadatos
    FileInfo info = File.GetInfo(s);
    Check("FileInfo", info.Exists && info.IsFile && !info.IsDirectory && info.Length == 12 && info.LastWriteTimeMs > 0);
    Check("SetLastWriteTime", File.SetLastWriteTime(s, 1000000000000) && File.GetLastWriteTime(s) == 1000000000000);
    Check("SetUnixMode", File.SetUnixMode(s, 0x1A0) && File.GetUnixMode(s) == 0x1A0);
    Check("SetReadOnly", File.SetReadOnly(s, true) && (File.GetUnixMode(s) & 0x92) == 0);
    File.SetReadOnly(s, false);
    Check("No existe", !FileInfo.Get("/no/existe/x").Exists && File.GetSize("/no/existe/x") == -1);

    // ---- carpetas
    string deep = Path.Combine(tmp, "x/y/z");
    Check("Create recursivo", Directory.Create(deep) && Directory.Exists(deep));
    Check("Create existente", Directory.Create(deep));
    string f1 = Path.Combine(tmp, "x/uno.fst");
    string f2 = Path.Combine(tmp, "x/y/dos.fst");
    string f3 = Path.Combine(tmp, "x/y/z/tres.txt");
    File.WriteAllText(f1, "1");
    File.WriteAllText(f2, "2");
    File.WriteAllText(f3, "3");
    string x = Path.Combine(tmp, "x");
    List<string> fst = Directory.GetFiles(x, "*.fst", true);
    PrintList(x, fst);
    Directory.FreeList(fst);
    List<string> top = Directory.GetFiles(x);
    PrintList(x, top);
    Directory.FreeList(top);
    List<string> dirs = Directory.GetDirectories(x, "*", true);
    PrintList(x, dirs);
    Directory.FreeList(dirs);
    List<string> every = Directory.GetFileSystemEntries(x, "?r*", true);
    PrintList(x, every);
    Directory.FreeList(every);
    Check("Delete no recursivo falla", !Directory.Delete(x, false));
    string moved = Path.Combine(tmp, "movida");
    Check("Directory.Move", Directory.Move(x, moved) && Directory.Exists(moved) && !Directory.Exists(x));

    string cwd = Directory.GetCurrent();
    Check("SetCurrent", Directory.SetCurrent(moved));
    Check("Ruta relativa", File.Exists("uno.fst"));
    Directory.SetCurrent(cwd);
    String.Free(cwd);

    // ---- borrado recursivo
    Check("Delete recursivo", Directory.Delete(tmp) && !Directory.Exists(tmp));

    String.Free(a);
    String.Free(b);
    String.Free(c);
    String.Free(d);
    String.Free(s);
    String.Free(deep);
    String.Free(f1);
    String.Free(f2);
    String.Free(f3);
    String.Free(x);
    String.Free(moved);
    String.Free(tmp);
    return 0;
}
