// =============================================================================
//  std.io  —  archivos, carpetas y rutas.
// =============================================================================
using std.collections;

namespace std.io
{
    static extern string faset_dir_list(string path);
    static extern string faset_get_cwd();
    static extern string faset_full_path(string path);
    static extern bool faset_path_move(string from, string to);
    static extern bool faset_path_delete(string path);

    public struct DirEntry
    {
        public string Name;       // copia propia (se libera con FreeEntries)
        public bool IsDirectory;
    }

    static extern string faset_file_read_all(string path, bool* ok);
    static extern bool faset_file_write(string path, string data, bool append);
    static extern bool faset_file_exists(string path);
    static extern bool faset_file_delete(string path);
    static extern bool faset_dir_exists(string path);
    static extern bool faset_dir_create(string path);

    public memory_unsafe static class File
    {
        // Lee todo el archivo. Devuelve una cadena nueva (libérala con String.Free).
        public static bool TryReadAllText(string path, out string content)
        {
            bool ok = false;
            content = faset_file_read_all(path, &ok);
            return ok;
        }

        // Como TryReadAllText, pero termina el programa si no se puede leer.
        public static string ReadAllText(string path)
        {
            bool ok = false;
            string s = faset_file_read_all(path, &ok);
            if (!ok) panic("File.ReadAllText: no se puede leer el archivo");
            return s;
        }

        public static bool WriteAllText(string path, string text) => faset_file_write(path, text, false);
        public static bool AppendAllText(string path, string text) => faset_file_write(path, text, true);
        public static bool Exists(string path) => faset_file_exists(path);
        public static bool Delete(string path) => faset_file_delete(path);

        // Mueve o renombra un archivo.
        public static bool Move(string from, string to) => faset_path_move(from, to);

        public static bool Copy(string from, string to)
        {
            string content;
            if (!TryReadAllText(from, out content)) return false;
            bool ok = WriteAllText(to, content);
            String.Free(content);
            return ok;
        }
    }

    public memory_unsafe static class Directory
    {
        public static bool Exists(string path) => faset_dir_exists(path);
        public static bool Create(string path) => faset_dir_create(path);

        // Mueve o renombra una carpeta.
        public static bool Move(string from, string to) => faset_path_move(from, to);

        // Borra una carpeta con todo su contenido.
        public static bool Delete(string path) => faset_path_delete(path);

        // Carpeta de trabajo actual (copia: libérala con String.Free).
        public static string GetCurrent() => faset_get_cwd();

        // Contenido de una carpeta: primero subcarpetas y luego archivos, por nombre.
        // Libera el resultado con Directory.FreeEntries.
        public static List<DirEntry> GetEntries(string path)
        {
            List<DirEntry> dirs = new List<DirEntry>();
            List<DirEntry> files = new List<DirEntry>();
            string raw = faset_dir_list(path);
            int start = 0;
            for (int i = 0; i < raw.Length; i++)
            {
                if (raw[i] != '\n') continue;
                if (i - start > 2)
                {
                    DirEntry e;
                    e.IsDirectory = raw[start] == 'd';
                    e.Name = String.Copy(raw.Substring(start + 2, i - start - 2));
                    if (e.IsDirectory) dirs.Add(e);
                    else files.Add(e);
                }
                start = i + 1;
            }
            String.Free(raw);
            dirs.Sort(&CompareEntries);
            files.Sort(&CompareEntries);
            dirs.AddRange(files);
            delete files;
            return dirs;
        }

        public static void FreeEntries(List<DirEntry> entries)
        {
            for (int i = 0; i < entries.Count; i++) String.Free(entries[i].Name);
            delete entries;
        }

        static int CompareEntries(DirEntry a, DirEntry b)
        {
            string x = a.Name.ToLower(), y = b.Name.ToLower();
            int c = x.CompareTo(y);
            String.Free(x);
            String.Free(y);
            return c;
        }
    }

    // Las funciones de Path devuelven vistas de la ruta original, salvo Combine.
    public memory_unsafe static class Path
    {
        static int LastSeparator(string path)
        {
            for (int i = path.Length - 1; i >= 0; i--)
                if (path[i] == '/' || path[i] == '\\') return i;
            return -1;
        }

        public static string GetFileName(string path) => path.Substring(LastSeparator(path) + 1);

        public static string GetDirectoryName(string path)
        {
            int i = LastSeparator(path);
            return i < 0 ? "" : path.Substring(0, i);
        }

        public static string GetExtension(string path)
        {
            string name = GetFileName(path);
            int dot = name.LastIndexOf(".");
            return dot <= 0 ? "" : name.Substring(dot);
        }

        public static string GetFileNameWithoutExtension(string path)
        {
            string name = GetFileName(path);
            int dot = name.LastIndexOf(".");
            return dot <= 0 ? name : name.Substring(0, dot);
        }

        // Ruta absoluta y canónica (sin '..' ni enlaces simbólicos). Copia: libérala con String.Free.
        public static string GetFullPath(string path) => faset_full_path(path);

        // Une dos partes con '/' (copia nueva: libérala con String.Free).
        public static string Combine(string a, string b)
        {
            if (a.Length == 0) return String.Copy(b);
            if (a.EndsWith("/") || a.EndsWith("\\")) return String.Concat(a, b);
            return String.Concat(a, "/", b);
        }
    }
}
