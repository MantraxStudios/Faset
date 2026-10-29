// =============================================================================
//  Lectura y escritura de proyectos .fstproj para el editor de propiedades.
// =============================================================================
using std.collections;
using std.io;
using std.text;

namespace FasetStudio.Ide
{
    public class ProjectFile
    {
        public string Path = "";            // copia propia
        public string AssemblyName = "";    // todas las cadenas: copias propias
        public string OutputType = "Exe";
        public string TargetPlatform = "native";
        public string TargetArch = "";
        public string Configuration = "Debug";
        public bool StaticLink;
        public List<string> References = new List<string>();
        public List<string> NativeLibraries = new List<string>();
        public List<string> CompileRemove = new List<string>();
        public List<string> CompileInclude = new List<string>();
        public List<string> LibraryPaths = new List<string>();

        ~ProjectFile()
        {
            FreeList(References);
            FreeList(NativeLibraries);
            FreeList(CompileRemove);
            FreeList(CompileInclude);
            FreeList(LibraryPaths);
        }

        static void FreeList(List<string> l)
        {
            for (int i = 0; i < l.Count; i++) String.Free(l[i]);
            delete l;
        }

        // Valor de <Tag>valor</Tag> (vista) o "".
        static string TagValue(string xml, string tag)
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
        static void Items(string xml, string element, string attribute, List<string> output)
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
        static string StripComments(string xml)
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

        public static ProjectFile Load(string path)
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
            String.Free(xml);
            return p;
        }

        static void Item(StringBuilder sb, string element, string attribute, string value)
        {
            sb.Append("    <").Append(element).Append(" ").Append(attribute).Append("=\"").Append(value).Append("\" />\n");
        }

        public bool Save()
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
            sb.Append("  </PropertyGroup>\n");
            int items = References.Count + NativeLibraries.Count + CompileRemove.Count + CompileInclude.Count + LibraryPaths.Count;
            if (items > 0)
            {
                sb.Append("\n  <ItemGroup>\n");
                for (int i = 0; i < CompileInclude.Count; i++) Item(sb, "Compile", "Include", CompileInclude[i]);
                for (int i = 0; i < CompileRemove.Count; i++) Item(sb, "Compile", "Remove", CompileRemove[i]);
                for (int i = 0; i < References.Count; i++) Item(sb, "ProjectReference", "Include", References[i]);
                for (int i = 0; i < NativeLibraries.Count; i++) Item(sb, "NativeLibrary", "Include", NativeLibraries[i]);
                for (int i = 0; i < LibraryPaths.Count; i++) Item(sb, "LibraryPath", "Include", LibraryPaths[i]);
                sb.Append("  </ItemGroup>\n");
            }
            sb.Append("</Project>\n");
            bool ok = File.WriteAllText(Path, sb.View());
            delete sb;
            return ok;
        }
    }
}
