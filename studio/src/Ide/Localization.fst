// =============================================================================
//  Traducciones de la interfaz.
//
//  Los textos se escriben en inglés en el código: L.T("Save").
//  Cada idioma es un archivo lang/<código>.txt con líneas "English = Traducción";
//  para añadir un idioma basta con crear un archivo nuevo.
// =============================================================================
using std.collections;
using std.io;
using std.text;

namespace FasetStudio.Ide
{
    public static class L
    {
        static Dictionary<string, string> table = new Dictionary<string, string>();
        static string content = "";      // texto del archivo cargado (las claves son vistas)
        static string current = "en";
        static string currentName = "English";
        static string folder = "";

        public static string Code => current;
        public static string Name => currentName;

        // Traducción de un texto en inglés (o el propio texto si no hay traducción).
        public static string T(string english)
        {
            string t;
            if (table.TryGetValue(english, out t)) return t;
            return english;
        }

        // Traduce y sustituye {0} y {1}. Devuelve una copia: libérala con String.Free.
        public static string F(string english, string a, string b)
        {
            string r1 = Text.Replace(T(english), "{0}", a);
            string r2 = Text.Replace(r1, "{1}", b);
            String.Free(r1);
            return r2;
        }

        public static void Init(string langFolder) { folder = String.Copy(langFolder); }

        // Idiomas disponibles: "en" más un archivo por idioma en la carpeta lang/.
        public static List<string> Available()
        {
            List<string> codes = new List<string>();
            codes.Add(String.Copy("en"));
            if (folder.Length == 0) return codes;
            List<DirEntry> entries = Directory.GetEntries(folder);
            for (int i = 0; i < entries.Count; i++)
                if (!entries[i].IsDirectory && entries[i].Name.EndsWith(".txt"))
                    codes.Add(String.Copy(Path.GetFileNameWithoutExtension(entries[i].Name)));
            Directory.FreeEntries(entries);
            return codes;
        }

        public static bool Load(string code)
        {
            table.Clear();
            if (content.Length > 0) String.Free(content);
            content = "";
            current = String.Copy(code);
            currentName = "English";
            if (code == "en" || folder.Length == 0) return true;
            string file = Path.Combine(folder, code);
            string path = String.Concat(file, ".txt");
            String.Free(file);
            bool ok = File.TryReadAllText(path, out content);
            String.Free(path);
            if (!ok)
            {
                current = "en";
                return false;
            }
            List<string> lines = Text.Split(content, "\n");
            for (int i = 0; i < lines.Count; i++)
            {
                string line = lines[i].Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                int eq = line.IndexOf(" = ");
                if (eq <= 0) continue;
                string key = line.Substring(0, eq).Trim();
                string value = line.Substring(eq + 3).Trim();
                if (key == "@name") currentName = value;
                else table.Set(key, value);
            }
            delete lines;
            return true;
        }

        // Siguiente idioma disponible (para el selector de la barra de estado).
        public static string NextCode()
        {
            List<string> codes = Available();
            int idx = 0;
            for (int i = 0; i < codes.Count; i++)
                if (codes[i] == current) idx = i;
            string next = String.Copy(codes[(idx + 1) % codes.Count]);
            for (int i = 0; i < codes.Count; i++) String.Free(codes[i]);
            delete codes;
            return next;
        }
    }

    // Preferencias del usuario en ~/.config/fasetstudio/settings.ini (clave=valor).
    public static class Settings
    {
        static Dictionary<string, string> values = new Dictionary<string, string>();
        static string path = "";

        public static void Load()
        {
            string home = Environment.GetVariable("HOME");
            if (home.IsEmpty())
            {
                String.Free(home);
                home = Environment.GetVariable("USERPROFILE");
            }
            if (home.IsEmpty()) return;
            string config = Path.Combine(home, ".config");
            Directory.Create(config);
            string dir = Path.Combine(config, "fasetstudio");
            Directory.Create(dir);
            path = Path.Combine(dir, "settings.ini");
            String.Free(dir);
            String.Free(config);
            String.Free(home);
            string text;
            if (!File.TryReadAllText(path, out text)) return;
            List<string> lines = Text.Split(text, "\n");
            for (int i = 0; i < lines.Count; i++)
            {
                int eq = lines[i].IndexOf("=");
                if (eq <= 0) continue;
                values.Set(String.Copy(lines[i].Substring(0, eq).Trim()), String.Copy(lines[i].Substring(eq + 1).Trim()));
            }
            delete lines;
        }

        public static string Get(string key, string fallback) => values.GetOrDefault(key, fallback);

        public static void Set(string key, string value)
        {
            values.Set(String.Copy(key), String.Copy(value));
            if (path.Length == 0) return;
            StringBuilder sb = new StringBuilder();
            List<string> keys = values.Keys();
            for (int i = 0; i < keys.Count; i++) sb.Append(keys[i]).Append("=").Append(values.Get(keys[i])).Append("\n");
            File.WriteAllText(path, sb.View());
            delete keys;
            delete sb;
        }
    }
}
