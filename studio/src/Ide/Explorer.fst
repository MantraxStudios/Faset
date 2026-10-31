// =============================================================================
//  Explorador de soluciones: árbol de carpetas y archivos del proyecto, o de una
//  solución .fstp (solución > carpetas de solución > proyectos > archivos).
// =============================================================================
using std.collections;
using std.io;
using std.json;
using FasetStudio.Gfx;

namespace FasetStudio.Ide
{
    class TreeNode
    {
        public var Name: string;   // copia propia
        public var Path: string;   // copia propia
        public var IsDir: bool;
        public var Expanded: bool;
        public var Loaded: bool;
        public var Depth: int;
        public var Children: List<TreeNode> = new List<TreeNode>();
        // Soluciones: 0 archivo o carpeta, 1 la solución, 2 carpeta de solución, 3 proyecto.
        public var Kind: int;
        public var Label: string = "";        // texto mostrado (solución y proyectos)
        public var Folder: string = "";       // carpeta de solución ("A/B")
        public var ProjectPath: string = "";  // .fstproj del proyecto
        public var Startup: bool;             // proyecto de inicio (en negrita)
        public var Missing: bool;             // el .fstproj no existe
        public var Count: int;                // la solución: número de proyectos

        deinit
        {
            for (int i = 0; i < Children.Count; i++) delete Children[i];
            delete Children;
            String.Free(Name);
            String.Free(Path);
        }
    }

    public class Explorer
    {
        var root: TreeNode;
        var rows: List<TreeNode> = new List<TreeNode>();
        public var Scroll: int;
        public var HoverRow: int = -1;
        public var SelectedPath: string = "";   // copia propia (ver Select)
        var selectedOwned: bool;
        public var RootPath: string = "";

        public var X: float;
        public var Y: float;
        public var W: float;
        public var H: float;

        public const float RowHeight = 26;
        public const float HeaderHeight = 38;

        deinit
        {
            delete root;
            delete rows;
        }

        // Guarda una copia de la ruta: el documento original puede cerrarse.
        public func Select(path: string)
        {
            if (path == SelectedPath) return;
            string copy = String.Copy(path);
            if (selectedOwned) String.Free(SelectedPath);
            SelectedPath = copy;
            selectedOwned = true;
        }

        public var IsSolution: bool;   // el árbol es el de una solución .fstp

        public func Load(folder: string)
        {
            delete root;
            IsSolution = false;
            root = new TreeNode();
            root.Path = Path.GetFullPath(folder);
            root.Name = String.Copy(Path.GetFileName(root.Path));
            root.IsDir = true;
            root.Expanded = true;
            RootPath = root.Path;
            LoadChildren(root);
            Rebuild();
        }

        // Árbol de una solución a partir de 'faset sln list --json'. Conserva lo que estaba abierto;
        // la primera vez se abren las carpetas de solución y el proyecto de inicio.
        public func LoadSolution(info: JsonValue, solutionPath: string)
        {
            List<string> open = new List<string>();
            bool first = root == null || !IsSolution;
            if (!first) CollectExpanded(root, open);
            delete root;
            IsSolution = true;
            string dir = info.GetString("dir");
            root = new TreeNode();
            root.Kind = 1;
            root.Path = String.Copy(dir);
            root.Name = String.Copy(Path.GetFileName(solutionPath));
            root.IsDir = true;
            root.Expanded = true;
            root.Loaded = true;
            RootPath = root.Path;
            JsonValue projects = info.Get("projects");
            int count = projects != null ? projects.Count : 0;
            root.Label = String.Copy(info.GetString("name"));
            root.Count = count;
            List<TreeNode> folderNodes = new List<TreeNode>();
            JsonValue folders = info.Get("folders");
            for (int i = 0; folders != null && i < folders.Count; i++)
            {
                string f = folders.At(i).AsString();
                int slash = f.LastIndexOf("/");
                TreeNode parent = slash < 0 ? root : FolderNode(folderNodes, f.Substring(0, slash));
                TreeNode n = new TreeNode();
                n.Kind = 2;
                n.IsDir = true;
                n.Loaded = true;
                n.Folder = String.Copy(f);
                n.Name = String.Copy(slash < 0 ? f : f.Substring(slash + 1));
                n.Path = String.Copy(dir);
                n.Depth = parent.Depth + 1;
                n.Expanded = first || Has(open, String.Concat("f:", f));
                parent.Children.Add(n);
                folderNodes.Add(n);
            }
            for (int i = 0; i < count; i++)
            {
                JsonValue p = projects.At(i);
                string folder = p.GetString("folder");
                TreeNode parent = folder.Length == 0 ? root : FolderNode(folderNodes, folder);
                TreeNode n = new TreeNode();
                n.Kind = 3;
                n.IsDir = true;
                n.ProjectPath = String.Copy(p.GetString("path"));
                n.Path = String.Copy(Path.GetDirectoryName(n.ProjectPath));
                n.Name = String.Copy(Path.GetFileName(n.Path));
                n.Label = String.Copy(p.GetString("name"));
                n.Startup = p.Get("startup") != null && p.Get("startup").AsBool();
                n.Missing = p.Get("exists") != null && !p.Get("exists").AsBool();
                n.Folder = String.Copy(folder);
                n.Depth = parent.Depth + 1;
                n.Loaded = n.Missing;
                parent.Children.Add(n);
                if (!n.Missing && ((first && n.Startup) || Has(open, String.Concat("p:", n.ProjectPath))))
                {
                    n.Expanded = true;
                    LoadChildren(n);
                    ReExpand(n, open);
                }
            }
            delete folderNodes;
            delete open;
            Rebuild();
        }

        static func Has(list: List<string>, key: string) -> bool
        {
            for (int i = 0; i < list.Count; i++)
                if (list[i] == key) return true;
            return false;
        }

        // Nodo de una carpeta de solución (o la raíz si no existe).
        func FolderNode(nodes: List<TreeNode>, folder: string) -> TreeNode
        {
            for (int i = 0; i < nodes.Count; i++)
                if (nodes[i].Folder == folder) return nodes[i];
            return root;
        }

        static func ExpandKey(n: TreeNode) -> string => n.Kind == 2 ? String.Concat("f:", n.Folder) : n.Kind == 3 ? String.Concat("p:", n.ProjectPath) : String.Copy(n.Path);

        func CollectExpanded(n: TreeNode, output: List<string>)
        {
            if (!n.Expanded) return;
            output.Add(ExpandKey(n));
            for (int i = 0; i < n.Children.Count; i++) CollectExpanded(n.Children[i], output);
        }

        func ReExpand(n: TreeNode, open: List<string>)
        {
            for (int i = 0; i < n.Children.Count; i++)
            {
                TreeNode c = n.Children[i];
                if (c.IsDir && Has(open, c.Path))
                {
                    c.Expanded = true;
                    LoadChildren(c);
                    ReExpand(c, open);
                }
            }
        }

        // Vuelve a leer las carpetas abiertas (tras crear archivos o compilar).
        public func Refresh()
        {
            if (root == null) return;
            Reload(root);
            Rebuild();
        }

        func Reload(n: TreeNode)
        {
            if (!n.IsDir || !n.Loaded) return;
            if (n.Kind == 1 || n.Kind == 2 || n.Missing)
            {
                // Nodos de la solución: sus hijos no son el contenido de una carpeta.
                for (int i = 0; i < n.Children.Count; i++) Reload(n.Children[i]);
                return;
            }
            // Conservar qué subcarpetas estaban abiertas.
            List<string> open = new List<string>();
            for (int i = 0; i < n.Children.Count; i++)
                if (n.Children[i].Expanded) open.Add(String.Copy(n.Children[i].Path));
            for (int i = 0; i < n.Children.Count; i++) delete n.Children[i];
            n.Children.Clear();
            n.Loaded = false;
            LoadChildren(n);
            for (int i = 0; i < n.Children.Count; i++)
            {
                TreeNode c = n.Children[i];
                for (int k = 0; k < open.Count; k++)
                    if (open[k] == c.Path)
                    {
                        c.Expanded = true;
                        LoadChildren(c);
                        Reload(c);
                    }
            }
            for (int k = 0; k < open.Count; k++) String.Free(open[k]);
            delete open;
        }

        static func Hidden(name: string) -> bool => name.StartsWith(".") || name == "bin" || name == "obj" || name == "node_modules";

        func LoadChildren(n: TreeNode)
        {
            if (n.Loaded) return;
            n.Loaded = true;
            List<DirEntry> entries = Directory.GetEntries(n.Path);
            for (int i = 0; i < entries.Count; i++)
            {
                DirEntry e = entries[i];
                if (Hidden(e.Name)) continue;
                TreeNode c = new TreeNode();
                c.Name = String.Copy(e.Name);
                c.Path = Path.Combine(n.Path, e.Name);
                c.IsDir = e.IsDirectory;
                c.Depth = n.Depth + 1;
                n.Children.Add(c);
            }
            Directory.FreeEntries(entries);
        }

        func Rebuild()
        {
            rows.Clear();
            if (root != null) Flatten(root);
        }

        func Flatten(n: TreeNode)
        {
            rows.Add(n);
            if (!n.IsDir || !n.Expanded) return;
            for (int i = 0; i < n.Children.Count; i++) Flatten(n.Children[i]);
        }

        public var DropTarget: int = -1;   // carpeta resaltada al arrastrar un archivo
        public prop RowCount: int => rows.Count;
        public prop IsLoaded: bool => root != null;

        // Datos de una fila (vistas válidas hasta el próximo Refresh).
        public func RowPath(row: int) -> string => rows[row].Path;
        public func RowIsDir(row: int) -> bool => rows[row].IsDir;
        public func RowIsRoot(row: int) -> bool => rows[row] == root;
        public func RowKind(row: int) -> int => rows[row].Kind;
        public func RowProject(row: int) -> string => rows[row].ProjectPath;
        public func RowSolutionFolder(row: int) -> string => rows[row].Folder;
        public func RowIsStartup(row: int) -> bool => rows[row].Startup;
        // Se puede arrastrar (archivos y carpetas normales) o soltar algo encima (carpetas y proyectos).
        public func RowDraggable(row: int) -> bool => rows[row] != root && rows[row].Kind == 0;
        public func RowDropTarget(row: int) -> bool => rows[row].IsDir && (rows[row].Kind == 0 || (rows[row].Kind == 3 && !rows[row].Missing));
        // Para los guiones de prueba: nombre o texto mostrado.
        public func RowMatches(row: int, text: string) -> bool => rows[row].Name == text || rows[row].Label == text;

        // Carpeta asociada a una fila: la propia carpeta o la que contiene el archivo.
        public func RowFolder(row: int) -> string
        {
            TreeNode n = rows[row];
            return n.IsDir ? n.Path : Path.GetDirectoryName(n.Path);
        }

        public func Unload()
        {
            delete root;
            root = null;
            rows.Clear();
            Scroll = 0;
            HoverRow = -1;
            IsSolution = false;
        }

        // Abre o cierra una carpeta.
        public func Toggle(row: int)
        {
            TreeNode n = rows[row];
            if (!n.IsDir) return;
            n.Expanded = !n.Expanded;
            if (n.Expanded) LoadChildren(n);
            Rebuild();
        }

        public func RowAt(px: float, py: float) -> int
        {
            if (px < X || px >= X + W || py < Y + HeaderHeight) return -1;
            int row = Scroll + (int)((py - Y - HeaderHeight) / RowHeight);
            return row < rows.Count ? row : -1;
        }

        // Clic: abre/cierra carpetas; devuelve la ruta del archivo a abrir (vista) o "".
        public func Click(px: float, py: float) -> string
        {
            int row = RowAt(px, py);
            if (row < 0) return "";
            TreeNode n = rows[row];
            if (n.IsDir)
            {
                n.Expanded = !n.Expanded;
                if (n.Expanded) LoadChildren(n);
                Rebuild();
                return "";
            }
            Select(n.Path);
            return SelectedPath;
        }

        public func ScrollBy(lines: int)
        {
            Scroll = Math.Clamp(Scroll + lines, 0, Math.Max(0, rows.Count - 3));
        }

        // Todos los archivos .fst y .fstproj (para "Abrir rápido").
        public func CollectFiles(output: List<string>)
        {
            if (root != null) Collect(root, output);
        }

        func Collect(n: TreeNode, output: List<string>)
        {
            if (!n.IsDir)
            {
                if (n.Name.EndsWith(".fst") || n.Name.EndsWith(".fstproj") || n.Name.EndsWith(".fstp") || n.Name.EndsWith(".md") || n.Name.EndsWith(".txt"))
                    output.Add(n.Path);
                return;
            }
            LoadChildren(n);
            for (int i = 0; i < n.Children.Count; i++) Collect(n.Children[i], output);
        }

        public func Draw(r: Renderer, projectName: string)
        {
            r.PushClip(X, Y + HeaderHeight, W, H - HeaderHeight - 4);
            int visible = (int)((H - HeaderHeight) / RowHeight) + 1;
            for (int n = 0; n < visible; n++)
            {
                int i = Scroll + n;
                if (i >= rows.Count) break;
                TreeNode node = rows[i];
                float ry = Y + HeaderHeight + n * RowHeight;
                bool selected = !node.IsDir && node.Path == SelectedPath;
                if (i == DropTarget) r.RoundBorder(X + 6, ry, W - 12, RowHeight, 6, 1.5f, Theme.Text);
                if (selected) r.RoundRect(X + 6, ry, W - 12, RowHeight, 6, Theme.Active);
                else if (i == HoverRow) r.RoundRect(X + 6, ry, W - 12, RowHeight, 6, Theme.Hover);
                float ix = X + 14 + node.Depth * 14;
                float cy = ry + RowHeight / 2;
                if (node.Kind == 1)
                {
                    // La solución: logotipo y "Solución 'X' (N proyectos)".
                    r.Text(r.Icons, ix, ry + 4, node.Expanded ? "▾" : "▸", Theme.TextTertiary);
                    r.RoundRect(ix + 14, cy - 8, 16, 16, 4, Theme.Text);
                    r.Logo(ix + 16, cy - 6, 12, Theme.Black);
                    string countText = String.FromInt(node.Count);
                    string title = node.Count == 1 ? L.F("Solution '{0}' (1 project)", node.Label, "")
                                                   : L.F("Solution '{0}' ({1} projects)", node.Label, countText);
                    r.Text(r.UiBold, ix + 36, ry + 4, title, Theme.White);
                }
                else if (node.Kind == 2)
                {
                    // Carpeta de solución: contorno (no es una carpeta del disco).
                    r.Text(r.Icons, ix, ry + 4, node.Expanded ? "▾" : "▸", Theme.TextTertiary);
                    r.RoundBorder(ix + 14, cy - 5, 14, 10, 2, 1.3f, Theme.TextSecondary);
                    r.RoundRect(ix + 14, cy - 7, 6, 3, 1, Theme.TextSecondary);
                    r.Text(r.Ui, ix + 34, ry + 4, node.Name, Theme.Text);
                }
                else if (node.Kind == 3)
                {
                    // Proyecto: el de inicio va en negrita.
                    if (!node.Missing) r.Text(r.Icons, ix, ry + 4, node.Expanded ? "▾" : "▸", Theme.TextTertiary);
                    r.RoundRect(ix + 15, cy - 7, 13, 14, 3, node.Missing ? Theme.TextTertiary : Theme.TextSecondary);
                    r.Text(r.UiSmall, ix + 18, cy - 8, "P", Theme.Black);
                    float lx = r.Text(node.Startup ? r.UiBold : r.Ui, ix + 34, ry + 4, node.Label, node.Missing ? Theme.TextTertiary : Theme.White);
                    if (node.Missing) r.Text(r.UiSmall, lx + 8, ry + 6, L.T("(unavailable)"), Theme.Error);
                }
                else if (node.IsDir)
                {
                    r.Text(r.Icons, ix, ry + 4, node.Expanded ? "▾" : "▸", Theme.TextTertiary);
                    Color folder = node.Depth == 0 ? Theme.Text : Theme.TextSecondary;
                    r.RoundRect(ix + 14, cy - 5, 14, 10, 2, folder);
                    r.RoundRect(ix + 14, cy - 7, 6, 4, 1, folder);
                    string label = node.Depth == 0 && projectName.Length > 0 ? projectName : node.Name;
                    r.Text(node.Depth == 0 ? r.UiBold : r.Ui, ix + 34, ry + 4, label, node.Depth == 0 ? Theme.White : Theme.Text);
                }
                else
                {
                    bool fst = node.Name.EndsWith(".fst");
                    bool proj = node.Name.EndsWith(".fstproj");
                    bool sln = node.Name.EndsWith(".fstp");
                    if (sln)
                    {
                        r.RoundBorder(ix + 15, cy - 7, 12, 14, 3, 1.5f, Theme.Text);
                        r.Text(r.UiSmall, ix + 18, cy - 8, "S", Theme.Text);
                    }
                    else if (fst)
                    {
                        r.RoundRect(ix + 15, cy - 7, 12, 14, 3, Theme.Text);
                        r.Text(r.UiSmall, ix + 18, cy - 8, "F", Theme.Black);
                    }
                    else if (proj)
                    {
                        r.RoundBorder(ix + 15, cy - 7, 12, 14, 3, 1.5f, Theme.Text);
                        r.Text(r.UiSmall, ix + 18, cy - 8, "P", Theme.Text);
                    }
                    else
                    {
                        r.RoundBorder(ix + 15, cy - 7, 12, 14, 3, 1.2f, Theme.TextTertiary);
                    }
                    r.Text(r.Ui, ix + 34, ry + 4, node.Name, selected ? Theme.White : Theme.TextSecondary);
                }
            }
            r.PopClip();
        }
    }
}
