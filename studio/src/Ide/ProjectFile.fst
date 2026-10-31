// =============================================================================
//  Lectura y escritura de proyectos .fstproj para el editor de propiedades.
// =============================================================================
using std.collections;
using std.io;
using std.json;
using std.text;

namespace FasetStudio.Ide
{
    // Un <PackageReference> del proyecto, con la versión que dice paquetes.lock.
    public class PackageItem
    {
        public var Name: string = "";      // copias propias
        public var Wanted: string = "";    // "^1.2", "rama main", "commit a1b2c3d" o ""
        public var Origin: string = "";    // URL git, ruta o "índice"
        public var Resolved: string = "";  // versión o commit de paquetes.lock ("" = sin restaurar)
    }

    public class ProjectFile
    {
        public var Path: string = "";            // copia propia
        public var AssemblyName: string = "";    // todas las cadenas: copias propias
        public var OutputType: string = "Exe";
        public var TargetPlatform: string = "native";
        public var TargetArch: string = "";
        public var Configuration: string = "Debug";
        public var StaticLink: bool;
        public var References: List<string> = new List<string>();
        public var NativeLibraries: List<string> = new List<string>();
        public var CompileRemove: List<string> = new List<string>();
        public var CompileInclude: List<string> = new List<string>();
        public var LibraryPaths: List<string> = new List<string>();
        // Lo que este diálogo no edita (Asset, PackageReference, propiedades de Android y de
        // paquetes...): se conserva tal cual al guardar.
        public var ExtraProperties: List<string> = new List<string>();
        public var ExtraItems: List<string> = new List<string>();

        deinit
        {
            FreeList(References);
            FreeList(NativeLibraries);
            FreeList(CompileRemove);
            FreeList(CompileInclude);
            FreeList(LibraryPaths);
            FreeList(ExtraProperties);
            FreeList(ExtraItems);
        }

        static func FreeList(l: List<string>)
        {
            for (int i = 0; i < l.Count; i++) String.Free(l[i]);
            delete l;
        }

        // Valor de <Tag>valor</Tag> (vista) o "".
        static func TagValue(xml: string, tag: string) -> string
        {
            string open = String.Concat("<", tag, ">");
            string close = String.Concat("</", tag, ">");
            int a = xml.IndexOf(open);
            string r = "";
            if (a >= 0)
            {
                int start = a + open.Length;
                int b = xml.IndexOf(close, start);
                if (b > start) r = xml.Substring(start, b - start).Trim();
            }
            String.Free(open);
            String.Free(close);
            return r;
        }

        // Atributos Include/Remove de todos los <Element .../>.
        static func Items(xml: string, element: string, attribute: string, output: List<string>)
        {
            string open = String.Concat("<", element, " ");
            string attr = String.Concat(attribute, "=\"");
            int pos = xml.IndexOf(open);
            while (pos >= 0)
            {
                int end = xml.IndexOf(">", pos);
                if (end < 0) break;
                string tag = xml.Substring(pos, end - pos);
                int a = tag.IndexOf(attr);
                if (a >= 0)
                {
                    int start = a + attr.Length;
                    int b = tag.IndexOf("\"", start);
                    if (b > start)
                    {
                        // Varios valores separados por ';'
                        List<string> parts = Text.Split(tag.Substring(start, b - start), ";");
                        for (int i = 0; i < parts.Count; i++)
                            if (parts[i].Trim().Length > 0) output.Add(String.Copy(parts[i].Trim()));
                        delete parts;
                    }
                }
                pos = xml.IndexOf(open, end);
            }
            String.Free(open);
            String.Free(attr);
        }

        // Copia del XML sin los comentarios <!-- ... -->.
        static func StripComments(xml: string) -> string
        {
            StringBuilder sb = new StringBuilder();
            int pos = 0;
            int start = xml.IndexOf("<!--", 0);
            while (start >= 0)
            {
                sb.Append(xml.Substring(pos, start - pos));
                int end = xml.IndexOf("-->", start + 4);
                pos = end < 0 ? xml.Length : end + 3;
                start = end < 0 ? -1 : xml.IndexOf("<!--", pos);
            }
            sb.Append(xml.Substring(pos));
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Valor del atributo 'name' en una etiqueta (vista; "" si no está).
        public static func Attr(tag: string, name: string) -> string
        {
            string key = String.Concat(" ", name, "=\"");
            int a = tag.IndexOf(key);
            string r = "";
            if (a >= 0)
            {
                int start = a + key.Length;
                int b = tag.IndexOf("\"", start);
                if (b >= start) r = tag.Substring(start, b - start);
            }
            String.Free(key);
            return r;
        }

        static func IsSpace(c: byte) -> bool => c == ' ' || c == '\t' || c == '\r' || c == '\n';

        // Nombre del elemento que empieza en 'pos' ('<' incluido).
        static func ElementName(xml: string, pos: int) -> string
        {
            int e = pos + 1;
            while (e < xml.Length && !IsSpace(xml[e]) && xml[e] != '>' && xml[e] != '/') e++;
            return xml.Substring(pos + 1, e - pos - 1);
        }

        // Fin (exclusivo) del elemento que empieza en 'pos': '/>' o su etiqueta de cierre.
        static func ElementEnd(xml: string, pos: int) -> int
        {
            int gt = xml.IndexOf(">", pos);
            if (gt < 0) return xml.Length;
            if (xml[gt - 1] == '/') return gt + 1;
            string close = String.Concat("</", ElementName(xml, pos), ">");
            int c = xml.IndexOf(close, gt);
            int end = c < 0 ? gt + 1 : c + close.Length;
            String.Free(close);
            return end;
        }

        // Hijos directos de cada <group> que no están en 'known' ("|A|B|"): texto original.
        static func ExtraChildren(xml: string, group: string, known: string, output: List<string>)
        {
            string open = String.Concat("<", group, ">");
            string close = String.Concat("</", group, ">");
            int g = xml.IndexOf(open);
            while (g >= 0)
            {
                int start = g + open.Length;
                int stop = xml.IndexOf(close, start);
                if (stop < 0) break;
                int pos = xml.IndexOf("<", start);
                while (pos >= 0 && pos < stop)
                {
                    int end = ElementEnd(xml, pos);
                    string name = String.Concat("|", ElementName(xml, pos), "|");
                    if (!known.Contains(name)) output.Add(String.Copy(xml.Substring(pos, end - pos)));
                    String.Free(name);
                    pos = xml.IndexOf("<", end);
                }
                g = xml.IndexOf(open, stop);
            }
            String.Free(open);
            String.Free(close);
        }

        // <PackageReference> del proyecto y su estado en paquetes.lock (junto al .fstproj).
        public static func LoadPackages(projectPath: string) -> List<PackageItem>
        {
            List<PackageItem> list = new List<PackageItem>();
            string raw;
            if (!File.TryReadAllText(projectPath, out raw)) return list;
            string xml = StripComments(raw);
            JsonValue lockJson = null;
            string lockText;
            string lockPath = std.io.Path.Combine(std.io.Path.GetDirectoryName(projectPath), "paquetes.lock");
            if (File.TryReadAllText(lockPath, out lockText)) lockJson = Json.Parse(lockText);
            JsonValue locked = lockJson != null ? lockJson.Get("paquetes") : null;
            int pos = xml.IndexOf("<PackageReference ");
            while (pos >= 0)
            {
                int end = xml.IndexOf(">", pos);
                if (end < 0) break;
                string tag = xml.Substring(pos, end - pos);
                PackageItem it = new PackageItem();
                it.Name = String.Copy(Attr(tag, "Include"));
                string v = Attr(tag, "Version"), b = Attr(tag, "Branch"), c = Attr(tag, "Commit");
                it.Wanted = b.Length > 0 ? String.Concat("rama ", b) : (c.Length > 0 ? String.Concat("commit ", c) : String.Copy(v));
                string g = Attr(tag, "Git"), p = Attr(tag, "Path");
                it.Origin = String.Copy(g.Length > 0 ? g : (p.Length > 0 ? p : "índice"));
                for (int i = 0; locked != null && i < locked.Count; i++)
                {
                    JsonValue e = locked.At(i);
                    if (!e.GetString("nombre").EqualsIgnoreCase(it.Name)) continue;
                    string ver = e.GetString("version"), commit = e.GetString("commit");
                    if (ver.Length > 0) it.Resolved = String.Copy(ver);
                    else if (commit.Length >= 7) it.Resolved = String.Concat("@", commit.Substring(0, 7));
                    else it.Resolved = String.Copy("ruta");
                }
                list.Add(it);
                pos = xml.IndexOf("<PackageReference ", end);
            }
            delete lockJson;
            String.Free(raw);
            String.Free(xml);
            return list;
        }

        public static func Load(path: string) -> ProjectFile
        {
            string raw;
            if (!File.TryReadAllText(path, out raw)) return null;
            string xml = StripComments(raw);
            String.Free(raw);
            ProjectFile p = new ProjectFile();
            p.Path = String.Copy(path);
            string name = TagValue(xml, "AssemblyName");
            p.AssemblyName = String.Copy(name.Length > 0 ? name : std.io.Path.GetFileNameWithoutExtension(path));
            string ot = TagValue(xml, "OutputType");
            if (ot.Length > 0) p.OutputType = String.Copy(ot);
            string tp = TagValue(xml, "TargetPlatform");
            if (tp.Length > 0) p.TargetPlatform = String.Copy(tp);
            p.TargetArch = String.Copy(TagValue(xml, "TargetArch"));
            string cfg = TagValue(xml, "Configuration");
            if (cfg.Length > 0) p.Configuration = String.Copy(cfg);
            p.StaticLink = TagValue(xml, "StaticLink").ToLower() == "true";
            Items(xml, "ProjectReference", "Include", p.References);
            Items(xml, "NativeLibrary", "Include", p.NativeLibraries);
            Items(xml, "Compile", "Remove", p.CompileRemove);
            Items(xml, "Compile", "Include", p.CompileInclude);
            Items(xml, "LibraryPath", "Include", p.LibraryPaths);
            ExtraChildren(xml, "PropertyGroup", "|OutputType|AssemblyName|RootNamespace|TargetPlatform|TargetArch|Configuration|StaticLink|", p.ExtraProperties);
            ExtraChildren(xml, "ItemGroup", "|Compile|ProjectReference|NativeLibrary|LibraryPath|", p.ExtraItems);
            String.Free(xml);
            return p;
        }

        static func Item(sb: StringBuilder, element: string, attribute: string, value: string)
        {
            sb.Append("    <").Append(element).Append(" ").Append(attribute).Append("=\"").Append(value).Append("\" />\n");
        }

        public func Save() -> bool
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("<Project>\n  <PropertyGroup>\n");
            sb.Append("    <OutputType>").Append(OutputType).Append("</OutputType>\n");
            sb.Append("    <AssemblyName>").Append(AssemblyName).Append("</AssemblyName>\n");
            sb.Append("    <RootNamespace>").Append(AssemblyName).Append("</RootNamespace>\n");
            sb.Append("    <TargetPlatform>").Append(TargetPlatform).Append("</TargetPlatform>\n");
            if (TargetArch.Length > 0) sb.Append("    <TargetArch>").Append(TargetArch).Append("</TargetArch>\n");
            sb.Append("    <Configuration>").Append(Configuration).Append("</Configuration>\n");
            if (StaticLink) sb.Append("    <StaticLink>true</StaticLink>\n");
            for (int i = 0; i < ExtraProperties.Count; i++) sb.Append("    ").Append(ExtraProperties[i]).Append("\n");
            sb.Append("  </PropertyGroup>\n");
            // Los <PackageReference> se leen otra vez del disco: 'faset add/remove' puede haberlos
            // cambiado mientras el diálogo estaba abierto.
            List<string> extra = new List<string>();
            string current;
            if (File.TryReadAllText(Path, out current))
            {
                string xml = StripComments(current);
                ExtraChildren(xml, "ItemGroup", "|Compile|ProjectReference|NativeLibrary|LibraryPath|", extra);
                String.Free(xml);
                String.Free(current);
            }
            else
            {
                for (int i = 0; i < ExtraItems.Count; i++) extra.Add(String.Copy(ExtraItems[i]));
            }
            int items = References.Count + NativeLibraries.Count + CompileRemove.Count + CompileInclude.Count + LibraryPaths.Count + extra.Count;
            if (items > 0)
            {
                sb.Append("\n  <ItemGroup>\n");
                for (int i = 0; i < CompileInclude.Count; i++) Item(sb, "Compile", "Include", CompileInclude[i]);
                for (int i = 0; i < CompileRemove.Count; i++) Item(sb, "Compile", "Remove", CompileRemove[i]);
                for (int i = 0; i < References.Count; i++) Item(sb, "ProjectReference", "Include", References[i]);
                for (int i = 0; i < NativeLibraries.Count; i++) Item(sb, "NativeLibrary", "Include", NativeLibraries[i]);
                for (int i = 0; i < LibraryPaths.Count; i++) Item(sb, "LibraryPath", "Include", LibraryPaths[i]);
                for (int i = 0; i < extra.Count; i++) sb.Append("    ").Append(extra[i]).Append("\n");
                sb.Append("  </ItemGroup>\n");
            }
            FreeList(extra);
            sb.Append("</Project>\n");
            bool ok = File.WriteAllText(Path, sb.View());
            delete sb;
            return ok;
        }
    }
}
