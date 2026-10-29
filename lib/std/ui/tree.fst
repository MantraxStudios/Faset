// =============================================================================
//  std.ui — TreeView: árbol de nodos que se expanden y contraen.
//
//      TreeNode docs = tvArchivos.AddNode("Documentos");
//      docs.Add("carta.txt").Tag = "/home/ana/carta.txt";
//      docs.Expanded = true;
//
//  Eventos: SelectedChanged (cambia SelectedNode) y NodeActivated (doble clic o
//  Enter). Teclado: ↑/↓, Inicio/Fin, → expande (o baja al primer hijo), ← contrae
//  (o sube al padre), Espacio expande/contrae y Enter activa.
// =============================================================================
using std.collections;

namespace std.ui
{
    public memory_unsafe class TreeNode
    {
        string text = "";
        bool expanded;
        public List<TreeNode> Nodes = new List<TreeNode>();
        public TreeNode Parent;
        public string Tag = "";          // dato libre del programa (ruta, id...)
        internal Widget view;

        public TreeNode(string text) { this.text = String.Copy(text); }

        public string Text
        {
            get => text;
            set
            {
                text = String.Copy(value);
                Changed();
            }
        }

        public bool Expanded
        {
            get => expanded;
            set
            {
                expanded = value;
                Changed();
            }
        }

        // TreeView al que pertenece (null si aún no está en ninguno).
        public Widget TreeView => view;

        public int Level
        {
            get
            {
                int n = 0;
                for (TreeNode p = Parent; p != null; p = p.Parent) n++;
                return n;
            }
        }

        // Textos desde la raíz separados por '/'.
        public string FullPath => Parent == null ? String.Copy(text) : Parent.FullPath + "/" + text;

        public TreeNode Add(string text)
        {
            TreeNode n = new TreeNode(text);
            n.Parent = this;
            n.view = view;
            Nodes.Add(n);
            Changed();
            return n;
        }

        public void Remove(TreeNode node)
        {
            Nodes.Remove(node);
            if (view != null) view.NodeRemoved(node);
            Changed();
        }

        public void Clear()
        {
            Nodes.Clear();
            if (view != null) view.NodeRemoved(this);
            Changed();
        }

        public void Expand() { Expanded = true; }
        public void Collapse() { Expanded = false; }
        public void Toggle() { Expanded = !expanded; }

        public void ExpandAll()
        {
            expanded = true;
            for (int i = 0; i < Nodes.Count; i++) Nodes[i].ExpandAll();
            Changed();
        }

        public void CollapseAll()
        {
            expanded = false;
            for (int i = 0; i < Nodes.Count; i++) Nodes[i].CollapseAll();
            Changed();
        }

        void Changed()
        {
            if (view != null) view.Invalidate();
        }
    }

    public memory_unsafe partial class Widget
    {
        List<TreeNode> treeNodes;
        TreeNode selectedNode;
        int treeScroll;   // primera fila visible

        // TreeView: nodos de primer nivel.
        public List<TreeNode> Nodes
        {
            get
            {
                if (treeNodes == null) treeNodes = new List<TreeNode>();
                return treeNodes;
            }
        }

        public TreeNode AddNode(string text)
        {
            TreeNode n = new TreeNode(text);
            n.view = this;
            Nodes.Add(n);
            Invalidate();
            return n;
        }

        public void RemoveNode(TreeNode node)
        {
            Nodes.Remove(node);
            NodeRemoved(node);
            Invalidate();
        }

        public void ClearNodes()
        {
            Nodes.Clear();
            selectedNode = null;
            treeScroll = 0;
            Invalidate();
        }

        public void ExpandAll()
        {
            for (int i = 0; i < Nodes.Count; i++) Nodes[i].ExpandAll();
        }

        public void CollapseAll()
        {
            for (int i = 0; i < Nodes.Count; i++) Nodes[i].CollapseAll();
        }

        // Nodo elegido (null = ninguno). Asignarlo expande sus padres y no lanza SelectedChanged.
        public TreeNode SelectedNode
        {
            get => selectedNode;
            set
            {
                selectedNode = value;
                for (TreeNode p = value != null ? value.Parent : null; p != null; p = p.Parent) p.Expanded = true;
                EnsureNodeVisible();
                Invalidate();
            }
        }

        // Si se quita el nodo elegido (o uno de sus padres), deja de estar elegido.
        internal void NodeRemoved(TreeNode node)
        {
            for (TreeNode p = selectedNode; p != null; p = p.Parent)
                if (p == node)
                {
                    selectedNode = null;
                    return;
                }
        }

        internal int TreeRowHeight => (int)UiFont.Get(FontSize, Bold).LineHeight + 12;

        int TreeVisibleRows
        {
            get
            {
                int h = ActualHeight > 0 ? ActualHeight : height;
                int n = (h - 8) / TreeRowHeight;
                return n < 1 ? 1 : n;
            }
        }

        // Filas visibles (nodos de las ramas expandidas) en orden, con su profundidad.
        void Flatten(List<TreeNode> nodes, TreeNode parent, int depth, List<TreeNode> rows, List<int> depths)
        {
            for (int i = 0; i < nodes.Count; i++)
            {
                TreeNode n = nodes[i];
                n.Parent = parent;  // por si se añadieron con Nodes.Add directamente
                n.view = this;
                rows.Add(n);
                depths.Add(depth);
                if (n.Expanded) Flatten(n.Nodes, n, depth + 1, rows, depths);
            }
        }

        List<TreeNode> VisibleNodes(List<int> depths)
        {
            auto rows = new List<TreeNode>();
            Flatten(Nodes, null, 0, rows, depths);
            return rows;
        }

        void ClampTree(int count)
        {
            int most = count - TreeVisibleRows;
            if (treeScroll > most) treeScroll = most;
            if (treeScroll < 0) treeScroll = 0;
        }

        internal void ScrollTree(int rows)
        {
            treeScroll += rows;
            auto depths = new List<int>();
            ClampTree(VisibleNodes(depths).Count);
            Invalidate();
        }

        void EnsureNodeVisible()
        {
            if (selectedNode == null) return;
            auto depths = new List<int>();
            auto rows = VisibleNodes(depths);
            int i = rows.IndexOf(selectedNode);
            if (i < 0) return;
            if (i < treeScroll) treeScroll = i;
            int vis = TreeVisibleRows;
            if (i >= treeScroll + vis) treeScroll = i - vis + 1;
            ClampTree(rows.Count);
        }

        // Fila (índice en VisibleNodes) bajo la coordenada y de la ventana, o -1.
        int TreeRowAt(int py, int count)
        {
            int local = py - ScreenY - 4;
            if (local < 0) return -1;
            int i = treeScroll + local / TreeRowHeight;
            return i < count ? i : -1;
        }

        void ChooseNode(TreeNode n)
        {
            if (n == selectedNode) return;
            selectedNode = n;
            EnsureNodeVisible();
            Invalidate();
            RaiseChanged();
        }

        internal void TreeSelectAt(int py)
        {
            auto depths = new List<int>();
            auto rows = VisibleNodes(depths);
            int i = TreeRowAt(py, rows.Count);
            if (i >= 0) ChooseNode(rows[i]);
        }

        internal void TreeMouseDown(int px, int py, int clicks)
        {
            auto depths = new List<int>();
            auto rows = VisibleNodes(depths);
            int i = TreeRowAt(py, rows.Count);
            if (i < 0) return;
            TreeNode n = rows[i];
            float arrowX = ScreenX + 8 + depths[i] * 18;
            if (n.Nodes.Count > 0 && px >= arrowX - 2 && px < arrowX + 18)
            {
                n.Expanded = !n.Expanded;  // el triángulo solo expande o contrae
                ClampTree(VisibleNodes(depths).Count);
                return;
            }
            ChooseNode(n);
            if (clicks == 2)
            {
                if (n.Nodes.Count > 0) n.Expanded = !n.Expanded;
                RaiseEvent(activatedEvent);
            }
        }

        internal void TreeKey(UiEvent e)
        {
            auto depths = new List<int>();
            auto rows = VisibleNodes(depths);
            if (rows.Count == 0) return;
            int i = rows.IndexOf(selectedNode);
            TreeNode n = selectedNode;
            switch (e.Key)
            {
                case KeyCode.Down:
                    ChooseNode(rows[i < 0 ? 0 : Math.Min(i + 1, rows.Count - 1)]);
                    break;
                case KeyCode.Up:
                    ChooseNode(rows[i <= 0 ? 0 : i - 1]);
                    break;
                case KeyCode.Home:
                    ChooseNode(rows[0]);
                    break;
                case KeyCode.End:
                    ChooseNode(rows[rows.Count - 1]);
                    break;
                case KeyCode.PageDown:
                    ChooseNode(rows[Math.Min(Math.Max(i, 0) + TreeVisibleRows - 1, rows.Count - 1)]);
                    break;
                case KeyCode.PageUp:
                    ChooseNode(rows[Math.Max(i - TreeVisibleRows + 1, 0)]);
                    break;
                case KeyCode.Right:
                    if (n == null) ChooseNode(rows[0]);
                    else if (n.Nodes.Count > 0 && !n.Expanded) n.Expanded = true;
                    else if (n.Nodes.Count > 0) ChooseNode(n.Nodes[0]);
                    break;
                case KeyCode.Left:
                    if (n == null) ChooseNode(rows[0]);
                    else if (n.Nodes.Count > 0 && n.Expanded) n.Expanded = false;
                    else if (n.Parent != null) ChooseNode(n.Parent);
                    break;
                case KeyCode.Space:
                    if (n != null && n.Nodes.Count > 0) n.Expanded = !n.Expanded;
                    break;
                case KeyCode.Enter:
                    if (n != null) RaiseEvent(activatedEvent);
                    break;
                default:
                    break;
            }
            ClampTree(VisibleNodes(depths).Count);
        }

        void DrawTreeView(Canvas c, Palette p, Window w, UiFont font, float fx, float fy, float fw, float fh, bool focused,
                          uint textColor, uint accent)
        {
            float r = CornerRadius >= 0 ? CornerRadius : 8;
            if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, 0);
            else c.FillRoundRect(fx, fy, fw, fh, r, p.Input);
            c.StrokeRoundRect(fx, fy, fw, fh, r, focused ? 1.5f : 1, focused ? p.Focus : (BorderColor != 0 ? BorderColor : p.Border));
            auto depths = new List<int>();
            auto rows = VisibleNodes(depths);
            ClampTree(rows.Count);
            int rh = TreeRowHeight, vis = TreeVisibleRows;
            bool bar = rows.Count > vis;
            float inner = fw - 8 - (bar ? 8 : 0);
            int hotRow = w.Hot == this ? TreeRowAt(w.MouseY, rows.Count) : -1;
            c.Clip(ScreenX + 1, ScreenY + 1, ActualWidth - 2, ActualHeight - 2);
            for (int i = treeScroll; i < rows.Count && i <= treeScroll + vis; i++)
            {
                TreeNode n = rows[i];
                float ry = fy + 4 + (i - treeScroll) * rh;
                if (n == selectedNode) c.FillRoundRect(fx + 4, ry, inner, rh, 6, focused ? p.Selection : p.SurfacePressed);
                else if (i == hotRow) c.FillRoundRect(fx + 4, ry, inner, rh, 6, p.SurfaceHover);
                float ax = fx + 8 + depths[i] * 18, cy = ry + rh / 2.0f;
                if (n.Nodes.Count > 0)
                {
                    float mx = ax + 8;
                    uint ac = n == selectedNode ? textColor : p.TextMuted;
                    if (n.Expanded)
                    {
                        c.Line(mx - 4, cy - 2, mx, cy + 2, 1.6f, ac);
                        c.Line(mx, cy + 2, mx + 4, cy - 2, 1.6f, ac);
                    }
                    else
                    {
                        c.Line(mx - 2, cy - 4, mx + 2, cy, 1.6f, ac);
                        c.Line(mx + 2, cy, mx - 2, cy + 4, 1.6f, ac);
                    }
                }
                c.Text(font, n.Text, ax + 20, ry + (rh - font.LineHeight) / 2 + font.Ascent, Enabled ? textColor : p.TextMuted);
            }
            if (bar)
            {
                float track = fh - 8;
                float th = track * vis / rows.Count;
                if (th < 24) th = 24;
                float ty = fy + 4 + (track - th) * treeScroll / (rows.Count - vis);
                c.FillRoundRect(fx + fw - 9, ty, 4, th, 2, p.BorderStrong);
            }
            c.ResetClip();
        }
    }
}
