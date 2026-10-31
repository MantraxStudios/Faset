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
        static var table: Dictionary<string, string> = new Dictionary<string, string>();
        static var content: string = "";      // texto del archivo cargado (las claves son vistas)
        static var current: string = "en";
        static var currentName: string = "English";
        static var folder: string = "";

        public static prop Code: string => current;
        public static prop Name: string => currentName;

        // Traducción de un texto en inglés (o el propio texto si no hay traducción).
        public static func T(english: string) -> string
        {
            string t;
            if (table.TryGetValue(english, out t)) return t;
            return english;
        }

        // Traduce y sustituye {0} y {1}. Devuelve una copia: libérala con String.Free.
        public static func F(english: string, a: string, b: string) -> string
        {
            string r1 = Text.Replace(T(english), "{0}", a);
            string r2 = Text.Replace(r1, "{1}", b);
            String.Free(r1);
            return r2;
        }

        public static func Init(langFolder: string) { folder = String.Copy(langFolder); }

        // Idiomas disponibles: "en" más un archivo por idioma en la carpeta lang/.
        public static func Available() -> List<string>
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

        public static func Load(code: string) -> bool
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
        public static func NextCode() -> string
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

    // Preferencias del usuario (clave=valor): ~/.config/fasetstudio/settings.ini en Linux y
    // %APPDATA%\FasetStudio\settings.ini en Windows.
    public static class Settings
    {
        static var values: Dictionary<string, string> = new Dictionary<string, string>();
        static var path: string = "";

        // Carpeta personal del usuario: HOME o, en Windows, USERPROFILE (copia; "" si no hay).
        public static func HomeFolder() -> string
        {
            string home = Environment.GetVariable("HOME");
            if (home.IsEmpty())
            {
                String.Free(home);
                home = Environment.GetVariable("USERPROFILE");
            }
            return home;
        }

        public static func Load()
        {
#if WINDOWS
            string appData = Environment.GetVariable("APPDATA");
            if (appData.IsEmpty())
            {
                String.Free(appData);
                string profile = HomeFolder();
                if (profile.IsEmpty()) return;
                appData = Path.Combine(profile, "AppData/Roaming");
                String.Free(profile);
            }
            string dir = Path.Combine(appData, "FasetStudio");
            Directory.Create(dir);
            path = Path.Combine(dir, "settings.ini");
            String.Free(dir);
            String.Free(appData);
#else
            string home = HomeFolder();
            if (home.IsEmpty()) return;
            string config = Path.Combine(home, ".config");
            Directory.Create(config);
            string dir = Path.Combine(config, "fasetstudio");
            Directory.Create(dir);
            path = Path.Combine(dir, "settings.ini");
            String.Free(dir);
            String.Free(config);
            String.Free(home);
#endif
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

        public static func Get(key: string, fallback: string) -> string => values.GetOrDefault(key, fallback);

        public static func Set(key: string, value: string)
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
