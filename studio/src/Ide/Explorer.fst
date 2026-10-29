// =============================================================================
//  Explorador de soluciones: árbol de carpetas y archivos del proyecto.
// =============================================================================
using std.collections;
using std.io;
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

        public void Load(string folder)
        {
            delete root;
            root = new TreeNode();
            root.Path = Path.GetFullPath(folder);
            root.Name = String.Copy(Path.GetFileName(root.Path));
            root.IsDir = true;
            root.Expanded = true;
            RootPath = root.Path;
            LoadChildren(root);
            Rebuild();
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
                if (n.Name.EndsWith(".fst") || n.Name.EndsWith(".fstproj") || n.Name.EndsWith(".md") || n.Name.EndsWith(".txt"))
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
                if (node.IsDir)
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
                    if (fst)
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
