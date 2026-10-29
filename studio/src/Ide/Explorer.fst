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
        public string Name;   // copia propia
        public string Path;   // copia propia
        public bool IsDir;
        public bool Expanded;
        public bool Loaded;
        public int Depth;
        public List<TreeNode> Children = new List<TreeNode>();
        // Soluciones: 0 archivo o carpeta, 1 la solución, 2 carpeta de solución, 3 proyecto.
        public int Kind;
        public string Label = "";        // texto mostrado (solución y proyectos)
        public string Folder = "";       // carpeta de solución ("A/B")
        public string ProjectPath = "";  // .fstproj del proyecto
        public bool Startup;             // proyecto de inicio (en negrita)
        public bool Missing;             // el .fstproj no existe
        public int Count;                // la solución: número de proyectos

        ~TreeNode()
        {
            for (int i = 0; i < Children.Count; i++) delete Children[i];
            delete Children;
            String.Free(Name);
            String.Free(Path);
        }
    }

    public class Explorer
    {
        TreeNode root;
        List<TreeNode> rows = new List<TreeNode>();
        public int Scroll;
        public int HoverRow = -1;
        public string SelectedPath = "";   // copia propia (ver Select)
        bool selectedOwned;
        public string RootPath = "";

        public float X;
        public float Y;
        public float W;
        public float H;

        public const float RowHeight = 26;
        public const float HeaderHeight = 38;

        ~Explorer()
        {
            delete root;
            delete rows;
        }

        // Guarda una copia de la ruta: el documento original puede cerrarse.
        public void Select(string path)
        {
            if (path == SelectedPath) return;
            string copy = String.Copy(path);
            if (selectedOwned) String.Free(SelectedPath);
            SelectedPath = copy;
            selectedOwned = true;
        }

        public bool IsSolution;   // el árbol es el de una solución .fstp

        public void Load(string folder)
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
        public void LoadSolution(JsonValue info, string solutionPath)
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

        static bool Has(List<string> list, string key)
        {
            for (int i = 0; i < list.Count; i++)
                if (list[i] == key) return true;
            return false;
        }

        // Nodo de una carpeta de solución (o la raíz si no existe).
        TreeNode FolderNode(List<TreeNode> nodes, string folder)
        {
            for (int i = 0; i < nodes.Count; i++)
                if (nodes[i].Folder == folder) return nodes[i];
            return root;
        }

        static string ExpandKey(TreeNode n) => n.Kind == 2 ? String.Concat("f:", n.Folder) : n.Kind == 3 ? String.Concat("p:", n.ProjectPath) : String.Copy(n.Path);

        void CollectExpanded(TreeNode n, List<string> output)
        {
            if (!n.Expanded) return;
            output.Add(ExpandKey(n));
            for (int i = 0; i < n.Children.Count; i++) CollectExpanded(n.Children[i], output);
        }

        void ReExpand(TreeNode n, List<string> open)
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
        public void Refresh()
        {
            if (root == null) return;
            Reload(root);
            Rebuild();
        }

        void Reload(TreeNode n)
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

        static bool Hidden(string name) => name.StartsWith(".") || name == "bin" || name == "obj" || name == "node_modules";

        void LoadChildren(TreeNode n)
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

        void Rebuild()
        {
            rows.Clear();
            if (root != null) Flatten(root);
        }

        void Flatten(TreeNode n)
        {
            rows.Add(n);
            if (!n.IsDir || !n.Expanded) return;
            for (int i = 0; i < n.Children.Count; i++) Flatten(n.Children[i]);
        }

        public int DropTarget = -1;   // carpeta resaltada al arrastrar un archivo
        public int RowCount => rows.Count;
        public bool IsLoaded => root != null;

        // Datos de una fila (vistas válidas hasta el próximo Refresh).
        public string RowPath(int row) => rows[row].Path;
        public bool RowIsDir(int row) => rows[row].IsDir;
        public bool RowIsRoot(int row) => rows[row] == root;
        public int RowKind(int row) => rows[row].Kind;
        public string RowProject(int row) => rows[row].ProjectPath;
        public string RowSolutionFolder(int row) => rows[row].Folder;
        public bool RowIsStartup(int row) => rows[row].Startup;
        // Se puede arrastrar (archivos y carpetas normales) o soltar algo encima (carpetas y proyectos).
        public bool RowDraggable(int row) => rows[row] != root && rows[row].Kind == 0;
        public bool RowDropTarget(int row) => rows[row].IsDir && (rows[row].Kind == 0 || (rows[row].Kind == 3 && !rows[row].Missing));
        // Para los guiones de prueba: nombre o texto mostrado.
        public bool RowMatches(int row, string text) => rows[row].Name == text || rows[row].Label == text;

        // Carpeta asociada a una fila: la propia carpeta o la que contiene el archivo.
        public string RowFolder(int row)
        {
            TreeNode n = rows[row];
            return n.IsDir ? n.Path : Path.GetDirectoryName(n.Path);
        }

        public void Unload()
        {
            delete root;
            root = null;
            rows.Clear();
            Scroll = 0;
            HoverRow = -1;
            IsSolution = false;
        }

        // Abre o cierra una carpeta.
        public void Toggle(int row)
        {
            TreeNode n = rows[row];
            if (!n.IsDir) return;
            n.Expanded = !n.Expanded;
            if (n.Expanded) LoadChildren(n);
            Rebuild();
        }

        public int RowAt(float px, float py)
        {
            if (px < X || px >= X + W || py < Y + HeaderHeight) return -1;
            int row = Scroll + (int)((py - Y - HeaderHeight) / RowHeight);
            return row < rows.Count ? row : -1;
        }

        // Clic: abre/cierra carpetas; devuelve la ruta del archivo a abrir (vista) o "".
        public string Click(float px, float py)
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

        public void ScrollBy(int lines)
        {
            Scroll = Math.Clamp(Scroll + lines, 0, Math.Max(0, rows.Count - 3));
        }

        // Todos los archivos .fst y .fstproj (para "Abrir rápido").
        public void CollectFiles(List<string> output)
        {
            if (root != null) Collect(root, output);
        }

        void Collect(TreeNode n, List<string> output)
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

        public void Draw(Renderer r, string projectName)
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
