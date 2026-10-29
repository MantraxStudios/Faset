// =============================================================================
//  Diseñador visual de interfaces (.fstui).
//
//  El XML del documento es la única fuente de verdad: el diseñador lo analiza en un
//  árbol de UiNode, lo modifica con el ratón y el panel de propiedades y lo vuelve a
//  escribir en el TextBuffer (así 'Guardar', la vista de código y el análisis ven lo
//  mismo). Cada cambio completo es un paso de deshacer.
// =============================================================================
using std.collections;
using std.text;
using std.io;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    // Un elemento del .fstui con sus atributos en el orden original.
    public class UiNode
    {
        public string Kind;                       // copia propia
        public List<string> Keys = new List<string>();
        public List<string> Values = new List<string>();
        public List<UiNode> Children = new List<UiNode>();
        public UiNode Parent;
        // Rectángulo en pantalla del último dibujo (para el ratón).
        public float SX;
        public float SY;
        public float SW;
        public float SH;

        public UiNode(string kind) { Kind = String.Copy(kind); }

        ~UiNode()
        {
            String.Free(Kind);
            for (int i = 0; i < Keys.Count; i++)
            {
                String.Free(Keys[i]);
                String.Free(Values[i]);
            }
            delete Keys;
            delete Values;
            for (int i = 0; i < Children.Count; i++) delete Children[i];
            delete Children;
        }

        public bool IsContainer => Kind == "Window" || Kind == "Panel";

        int IndexOfKey(string key)
        {
            for (int i = 0; i < Keys.Count; i++)
                if (Keys[i] == key) return i;
            return -1;
        }

        public bool Has(string key) => IndexOfKey(key) >= 0;

        // Valor del atributo (vista) o "" si no está.
        public string Get(string key)
        {
            int i = IndexOfKey(key);
            return i < 0 ? "" : Values[i];
        }

        public void Set(string key, string value)
        {
            int i = IndexOfKey(key);
            if (i >= 0)
            {
                string old = Values[i];
                Values[i] = String.Copy(value);
                String.Free(old);
                return;
            }
            Keys.Add(String.Copy(key));
            Values.Add(String.Copy(value));
        }

        public void SetInt(string key, int v)
        {
            string s = Convert.ToString(v);
            Set(key, s);
            String.Free(s);
        }

        public void Remove(string key)
        {
            int i = IndexOfKey(key);
            if (i < 0) return;
            String.Free(Keys[i]);
            String.Free(Values[i]);
            Keys.RemoveAt(i);
            Values.RemoveAt(i);
        }

        public int Int(string key, int def)
        {
            long v = 0;
            string s = Get(key);
            if (s.Length == 0 || !Convert.TryToInt64(s, out v)) return def;
            return (int)v;
        }

        public float Num(string key, float def)
        {
            double v = 0;
            string s = Get(key);
            if (s.Length == 0 || !Convert.TryToDouble(s, out v)) return def;
            return (float)v;
        }

        public bool Bool(string key, bool def)
        {
            string s = Get(key);
            if (s.Length == 0) return def;
            return s.ToLower() == "true";
        }

        public UiNode Clone()
        {
            UiNode n = new UiNode(Kind);
            for (int i = 0; i < Keys.Count; i++) n.Set(Keys[i], Values[i]);
            for (int i = 0; i < Children.Count; i++)
            {
                UiNode c = Children[i].Clone();
                c.Parent = n;
                n.Children.Add(c);
            }
            return n;
        }

        public bool IsAncestorOf(UiNode n)
        {
            for (UiNode p = n; p != null; p = p.Parent)
                if (p == this) return true;
            return false;
        }

        public UiNode FindByName(string name)
        {
            if (Get("Name") == name) return this;
            for (int i = 0; i < Children.Count; i++)
            {
                UiNode r = Children[i].FindByName(name);
                if (r != null) return r;
            }
            return null;
        }
    }

    // Lectura y escritura del XML de los .fstui.
    public static class UiXml
    {
        static bool IsSpace(byte c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';
        static bool IsNameChar(byte c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == ':' || c == '.';

        // Analiza el documento; null y 'error' (copia) si no es válido.
        public static UiNode Parse(string s, out string error)
        {
            error = String.Copy("");
            int i = 0;
            UiNode root = null;
            UiNode current = null;
            while (i < s.Length)
            {
                if (s[i] != '<')
                {
                    i++;
                    continue;
                }
                if (s.Substring(i).StartsWith("<!--"))
                {
                    int end = s.IndexOf("-->", i + 4);
                    if (end < 0) return Fail(out error, "unterminated comment", root);
                    i = end + 3;
                    continue;
                }
                if (i + 1 < s.Length && (s[i + 1] == '?' || s[i + 1] == '!'))
                {
                    int end = s.IndexOf(">", i);
                    if (end < 0) return Fail(out error, "unterminated declaration", root);
                    i = end + 1;
                    continue;
                }
                if (i + 1 < s.Length && s[i + 1] == '/')
                {
                    int end = s.IndexOf(">", i);
                    if (end < 0 || current == null) return Fail(out error, "unexpected closing tag", root);
                    string name = s.Substring(i + 2, end - i - 2).Trim();
                    if (name != current.Kind) return Fail(out error, "closing tag does not match", root);
                    current = current.Parent;
                    i = end + 1;
                    continue;
                }
                i++;
                int ns = i;
                while (i < s.Length && IsNameChar(s[i])) i++;
                if (i == ns) return Fail(out error, "expected an element name", root);
                UiNode node = new UiNode(s.Substring(ns, i - ns));
                if (current != null)
                {
                    node.Parent = current;
                    current.Children.Add(node);
                }
                else if (root == null) root = node;
                else
                {
                    delete node;
                    return Fail(out error, "only one root element is allowed", root);
                }
                bool selfClosing = false;
                for (;;)
                {
                    while (i < s.Length && IsSpace(s[i])) i++;
                    if (i >= s.Length) return Fail(out error, "unterminated element", root);
                    if (s[i] == '/' && i + 1 < s.Length && s[i + 1] == '>')
                    {
                        selfClosing = true;
                        i += 2;
                        break;
                    }
                    if (s[i] == '>')
                    {
                        i++;
                        break;
                    }
                    int ks = i;
                    while (i < s.Length && IsNameChar(s[i])) i++;
                    if (i == ks) return Fail(out error, "invalid attribute", root);
                    string key = s.Substring(ks, i - ks);
                    while (i < s.Length && IsSpace(s[i])) i++;
                    if (i >= s.Length || s[i] != '=') return Fail(out error, "expected '=' after attribute", root);
                    i++;
                    while (i < s.Length && IsSpace(s[i])) i++;
                    if (i >= s.Length || (s[i] != '"' && s[i] != '\'')) return Fail(out error, "expected a quoted value", root);
                    byte q = s[i];
                    i++;
                    int vs = i;
                    while (i < s.Length && s[i] != q) i++;
                    if (i >= s.Length) return Fail(out error, "unterminated attribute value", root);
                    string value = Decode(s.Substring(vs, i - vs));
                    node.Set(key, value);
                    String.Free(value);
                    i++;
                }
                if (!selfClosing) current = node;
            }
            if (root == null) return Fail(out error, "the document is empty", root);
            if (current != null) return Fail(out error, "missing closing tag", root);
            return root;
        }

        static UiNode Fail(out string error, string message, UiNode root)
        {
            error = String.Copy(message);
            if (root != null) delete root;
            return null;
        }

        static string Decode(string v)
        {
            StringBuilder sb = new StringBuilder();
            int i = 0;
            while (i < v.Length)
            {
                if (v[i] == '&')
                {
                    string rest = v.Substring(i);
                    if (rest.StartsWith("&amp;")) { sb.Append('&'); i += 5; continue; }
                    if (rest.StartsWith("&lt;")) { sb.Append('<'); i += 4; continue; }
                    if (rest.StartsWith("&gt;")) { sb.Append('>'); i += 4; continue; }
                    if (rest.StartsWith("&quot;")) { sb.Append('"'); i += 6; continue; }
                    if (rest.StartsWith("&apos;")) { sb.Append('\''); i += 6; continue; }
                    if (rest.StartsWith("&#10;")) { sb.Append('\n'); i += 5; continue; }
                }
                sb.Append(String.FromBytes(v.Ptr + i, 1));
                i++;
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        static void Escape(StringBuilder sb, string v)
        {
            for (int i = 0; i < v.Length; i++)
            {
                byte c = v[i];
                if (c == '&') sb.Append("&amp;");
                else if (c == '<') sb.Append("&lt;");
                else if (c == '>') sb.Append("&gt;");
                else if (c == '"') sb.Append("&quot;");
                else if (c == '\n') sb.Append("&#10;");
                else sb.Append(String.FromBytes(v.Ptr + i, 1));
            }
        }

        public static string Write(UiNode root)
        {
            StringBuilder sb = new StringBuilder();
            WriteNode(sb, root, 0);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        static void WriteNode(StringBuilder sb, UiNode n, int depth)
        {
            for (int i = 0; i < depth; i++) sb.Append("  ");
            sb.Append("<").Append(n.Kind);
            for (int i = 0; i < n.Keys.Count; i++)
            {
                sb.Append(" ").Append(n.Keys[i]).Append("=\"");
                Escape(sb, n.Values[i]);
                sb.Append("\"");
            }
            if (n.Children.Count == 0)
            {
                sb.Append(" />\n");
                return;
            }
            sb.Append(">\n");
            for (int i = 0; i < n.Children.Count; i++) WriteNode(sb, n.Children[i], depth + 1);
            for (int i = 0; i < depth; i++) sb.Append("  ");
            sb.Append("</").Append(n.Kind).Append(">\n");
        }
    }

    // Definición de una propiedad editable.
    struct PropDef
    {
        public string Key;
        public int Type;        // 0 texto, 1 entero, 2 número, 3 booleano, 4 opciones, 5 anclaje, 6 evento, 7 identificador
        public string Options;  // separadas por '|'
        public string Default;
        public string Section;
    }

    struct PropRow
    {
        public string Key;
        public int Type;
        public float Y;
        public float VX;   // inicio del control
        public float VW;
        public string Options;
    }

    public class Designer
    {
        public const float ToolboxWidth = 196;
        public const float PropsWidth = 330;
        public const float RowHeight = 36;
        const float TitleBar = 34;
        const float ToolRow = 36;      // alto de cada herramienta
        const float OutlineRow = 28;   // alto de cada fila del esquema
        const float ArrangeTop = 46;   // barra de alinear / orden (relativa a Y)
        const float Margin = 48;
        const int Grid = 8;

        public Document Doc;
        public float X;
        public float Y;
        public float W;
        public float H;

        UiNode root;
        string error = String.Copy("");
        int syncedVersion = -1;
        UiNode selected;
        List<string> undo = new List<string>();
        List<string> redo = new List<string>();

        // Arrastre: 0 nada, 1 mover, 2 redimensionar, 3 nuevo desde la caja de herramientas, 4 tamaño de la ventana
        int dragMode;
        int handle;
        float pressX;
        float pressY;
        float mouseX;
        float mouseY;
        int origX;
        int origY;
        int origW;
        int origH;
        bool dragMoved;
        string newKind = String.Copy("");
        UiNode dropTarget;
        List<float> guidesX = new List<float>();
        List<float> guidesY = new List<float>();

        float scrollX;
        float scrollY;
        float propsScroll;
        float originX;   // esquina del contenido de la ventana diseñada en pantalla
        float originY;

        List<PropRow> rows = new List<PropRow>();
        TextField field = new TextField();
        string editingKey = String.Copy("");
        int toolHover = -1;
        int leftTab;                  // 0 herramientas, 1 esquema
        float outlineScroll;
        List<UiNode> outline = new List<UiNode>();
        List<int> outlineDepth = new List<int>();
        int arrangeHover = -1;

        // Portapapeles de controles (XML), compartido entre diseñadores.
        static string clipboard = "";
        static bool clipboardOwned;

        public string RequestHandler = String.Copy("");   // método que la aplicación debe abrir en el código (copia)
        public string Status = "";           // mensaje para la barra de estado (vista de literal)
        public bool SwitchToCode;            // pide pasar a la vista de código

        static string kinds = "Label|Button|TextBox|CheckBox|RadioButton|ComboBox|ListBox|Slider|ProgressBar|Panel";
        const int KindCount = 10;

        public Designer(Document doc) { Doc = doc; }

        ~Designer()
        {
            if (root != null) delete root;
            String.Free(error);
            FreeAll(undo);
            FreeAll(redo);
            delete undo;
            delete redo;
            delete guidesX;
            delete guidesY;
            delete rows;
            delete outline;
            delete outlineDepth;
            delete field;
            String.Free(editingKey);
            String.Free(RequestHandler);
        }

        static void FreeAll(List<string> l)
        {
            for (int i = 0; i < l.Count; i++) String.Free(l[i]);
            l.Clear();
        }

        public bool Editing => editingKey.Length > 0;
        public string ClassName => root != null ? root.Get("Class") : "";
        public string NamespaceName => root != null ? root.Get("Namespace") : "";
        public bool HasError => root == null;

        // ------------------------------------------------------------------ sincronización

        // Vuelve a leer el XML si el texto cambió fuera del diseñador.
        public void Sync()
        {
            if (Doc.Buffer.Version == syncedVersion) return;
            syncedVersion = Doc.Buffer.Version;
            string keepName = selected != null ? String.Copy(selected.Get("Name")) : String.Copy("");
            bool wasRoot = selected != null && selected == root;
            string text = Doc.Buffer.GetAll();
            string err;
            UiNode parsed = UiXml.Parse(text, out err);
            String.Free(text);
            if (root != null) delete root;
            root = parsed;
            String.Free(error);
            error = err;
            selected = null;
            if (root != null && root.Kind != "Window")
            {
                delete root;
                root = null;
                String.Free(error);
                error = String.Copy("the root element must be <Window>");
            }
            if (root != null)
            {
                if (keepName.Length > 0) selected = root.FindByName(keepName);
                if (selected == null && wasRoot) selected = root;
            }
            String.Free(keepName);
            CancelEdit();
        }

        // Escribe el árbol en el documento (un paso de deshacer).
        void Commit(string before)
        {
            string xml = UiXml.Write(root);
            if (before == xml)
            {
                String.Free(xml);
                String.Free(before);
                return;
            }
            undo.Add(before);
            FreeAll(redo);
            WriteBuffer(xml);
            String.Free(xml);
        }

        void WriteBuffer(string xml)
        {
            TextBuffer b = Doc.Buffer;
            b.NewGroup();
            b.Delete(new TextPos(0, 0), b.End, new TextPos(0, 0));
            b.Insert(new TextPos(0, 0), xml, new TextPos(0, 0));
            b.NewGroup();
            syncedVersion = b.Version;
        }

        string Snapshot() => UiXml.Write(root);

        void Restore(List<string> from, List<string> to)
        {
            if (from.Count == 0 || root == null) return;
            string keep = selected != null ? String.Copy(selected.Get("Name")) : String.Copy("");
            to.Add(Snapshot());
            string xml = from.Last();
            from.RemoveAt(from.Count - 1);
            WriteBuffer(xml);
            syncedVersion = -1;
            Sync();
            if (root != null && keep.Length > 0) selected = root.FindByName(keep);
            String.Free(keep);
            String.Free(xml);
        }

        // ------------------------------------------------------------------ geometría

        float CanvasX => X + ToolboxWidth;
        float CanvasW => W - ToolboxWidth - PropsWidth;
        float PropsX => X + W - PropsWidth;

        float ContentX(UiNode n)
        {
            float x = originX;
            for (UiNode p = n; p != null && p != root; p = p.Parent) x += p.Int("X", 0);
            return x;
        }

        float ContentY(UiNode n)
        {
            float y = originY;
            for (UiNode p = n; p != null && p != root; p = p.Parent) y += p.Int("Y", 0);
            return y;
        }

        void Layout()
        {
            originX = CanvasX + Margin - scrollX;
            originY = Y + Margin + TitleBar - scrollY;
        }

        // Nodo más interno bajo el punto (sin contar la ventana).
        UiNode HitTest(UiNode n, float px, float py)
        {
            for (int i = n.Children.Count - 1; i >= 0; i--)
            {
                UiNode c = n.Children[i];
                if (px >= c.SX && py >= c.SY && px < c.SX + c.SW && py < c.SY + c.SH)
                {
                    UiNode inner = HitTest(c, px, py);
                    return inner != null ? inner : c;
                }
            }
            return null;
        }

        // Panel (o la ventana) que recibiría un control soltado en el punto.
        UiNode ContainerAt(float px, float py, UiNode exclude)
        {
            UiNode best = root;
            FindContainer(root, px, py, exclude, ref best);
            return best;
        }

        void FindContainer(UiNode n, float px, float py, UiNode exclude, ref UiNode best)
        {
            for (int i = 0; i < n.Children.Count; i++)
            {
                UiNode c = n.Children[i];
                if (c == exclude || c.Kind != "Panel") continue;
                if (px >= c.SX && py >= c.SY && px < c.SX + c.SW && py < c.SY + c.SH)
                {
                    best = c;
                    FindContainer(c, px, py, exclude, ref best);
                }
            }
        }

        // Asa de redimensión bajo el punto (0..7 desde arriba-izquierda en sentido horario) o -1.
        int HandleAt(float px, float py)
        {
            if (selected == null || selected == root) return -1;
            for (int i = 0; i < 8; i++)
            {
                float hx = 0, hy = 0;
                HandlePos(selected, i, out hx, out hy);
                if (Math.Abs(px - hx) <= 6 && Math.Abs(py - hy) <= 6) return i;
            }
            return -1;
        }

        static void HandlePos(UiNode n, int i, out float hx, out float hy)
        {
            float l = n.SX, t = n.SY, r = n.SX + n.SW, b = n.SY + n.SH;
            float cx = (l + r) / 2, cy = (t + b) / 2;
            hx = i == 0 || i == 6 || i == 7 ? l : (i == 1 || i == 5 ? cx : r);
            hy = i <= 2 ? t : (i == 3 || i == 7 ? cy : b);
        }

        bool OverWindowCorner(float px, float py)
        {
            if (root == null) return false;
            float rx = originX + root.Int("Width", 800), ry = originY + root.Int("Height", 600);
            return px >= rx - 4 && px <= rx + 12 && py >= ry - 4 && py <= ry + 12;
        }

        // Cursor para la posición del ratón (CursorKind).
        public CursorKind CursorAt(float px, float py)
        {
            if (root == null) return CursorKind.Arrow;
            if (dragMode == 1) return CursorKind.Arrow;
            if (px >= PropsX)
            {
                if (ArrangeAt(px, py) >= 0) return CursorKind.Hand;
                for (int i = 0; i < rows.Count; i++)
                    if (py >= rows[i].Y && py < rows[i].Y + RowHeight && px >= rows[i].VX)
                        return rows[i].Type <= 2 || rows[i].Type == 7 ? CursorKind.Text : CursorKind.Hand;
                return CursorKind.Arrow;
            }
            if (px < CanvasX) return ToolAt(px, py) >= 0 || OutlineAt(px, py) >= 0 || TabAt(px, py) >= 0 ? CursorKind.Hand : CursorKind.Arrow;
            int h = HandleAt(px, py);
            if (h == 3 || h == 7) return CursorKind.ResizeHorizontal;
            if (h == 1 || h == 5) return CursorKind.ResizeVertical;
            if (h >= 0 || OverWindowCorner(px, py)) return CursorKind.ResizeHorizontal;
            return CursorKind.Arrow;
        }

        int ToolAt(float px, float py)
        {
            if (leftTab != 0 || px < X + 10 || px >= X + ToolboxWidth - 10) return -1;
            int i = (int)Math.Floor((py - (Y + 52)) / ToolRow);
            return py >= Y + 52 && i >= 0 && i < KindCount ? i : -1;
        }

        // Pestaña (0 herramientas, 1 esquema) bajo el punto, o -1.
        int TabAt(float px, float py)
        {
            if (py < Y + 10 || py >= Y + 38 || px < X + 10 || px >= X + ToolboxWidth - 10) return -1;
            return px < X + ToolboxWidth / 2 ? 0 : 1;
        }

        // Fila del esquema bajo el punto, o -1.
        int OutlineAt(float px, float py)
        {
            if (leftTab != 1 || px < X + 6 || px >= X + ToolboxWidth - 6 || py < Y + 52) return -1;
            int i = (int)Math.Floor((py - (Y + 52) + outlineScroll) / OutlineRow);
            return i >= 0 && i < outline.Count ? i : -1;
        }

        void BuildOutline(UiNode n, int depth)
        {
            outline.Add(n);
            outlineDepth.Add(depth);
            for (int i = 0; i < n.Children.Count; i++) BuildOutline(n.Children[i], depth + 1);
        }

        static string KindAt(int i)
        {
            auto parts = Text.Split(kinds, "|");
            string k = parts[i];
            delete parts;
            return k;
        }

        // ------------------------------------------------------------------ edición

        static int Snap(int v) => (int)Math.Round(v / (double)Grid) * Grid;

        void Select(UiNode n)
        {
            if (selected != n) CommitEdit();
            selected = n;
        }

        string UniqueName(string kind)
        {
            string prefix = kind == "Label" ? "label" : kind == "Button" ? "button" : kind == "TextBox" ? "textBox"
                          : kind == "CheckBox" ? "checkBox" : kind == "Slider" ? "slider" : kind == "ProgressBar" ? "progressBar"
                          : kind == "RadioButton" ? "radioButton" : kind == "ComboBox" ? "comboBox" : kind == "ListBox" ? "listBox" : "panel";
            for (int i = 1; ; i++)
            {
                string num = Convert.ToString(i);
                string name = String.Concat(prefix, num);
                String.Free(num);
                if (root.FindByName(name) == null) return name;
                String.Free(name);
            }
        }

        UiNode CreateNode(string kind)
        {
            UiNode n = new UiNode(kind);
            string name = UniqueName(kind);
            n.Set("Name", name);
            String.Free(name);
            n.Set("X", "0");
            n.Set("Y", "0");
            int w = 120, h = 24;
            if (kind == "Label") n.Set("Text", "Label");
            else if (kind == "Button")
            {
                w = 112;
                h = 36;
                n.Set("Text", "Button");
            }
            else if (kind == "TextBox")
            {
                w = 240;
                h = 36;
                n.Set("Placeholder", "");
            }
            else if (kind == "CheckBox")
            {
                w = 160;
                n.Set("Text", "Check box");
            }
            else if (kind == "RadioButton")
            {
                w = 160;
                n.Set("Text", "Option");
                n.Set("Group", "group1");
            }
            else if (kind == "ComboBox")
            {
                w = 200;
                h = 36;
                n.Set("Items", "Option 1;Option 2;Option 3");
                n.Set("SelectedIndex", "0");
            }
            else if (kind == "ListBox")
            {
                w = 200;
                h = 160;
                n.Set("Items", "Item 1;Item 2;Item 3;Item 4");
            }
            else if (kind == "Slider")
            {
                w = 240;
                n.Set("Value", "50");
            }
            else if (kind == "ProgressBar")
            {
                w = 240;
                h = 8;
                n.Set("Value", "50");
            }
            else if (kind == "Panel")
            {
                w = 280;
                h = 160;
            }
            n.SetInt("Width", w);
            n.SetInt("Height", h);
            return n;
        }

        void AddNode(string kind, UiNode parent, int x, int y)
        {
            string before = Snapshot();
            UiNode n = CreateNode(kind);
            n.SetInt("X", x);
            n.SetInt("Y", y);
            n.Parent = parent;
            parent.Children.Add(n);
            selected = n;
            Commit(before);
        }

        void DeleteSelected()
        {
            if (selected == null || selected == root) return;
            string before = Snapshot();
            UiNode p = selected.Parent;
            p.Children.Remove(selected);
            delete selected;
            selected = p;
            Commit(before);
        }

        void DuplicateSelected()
        {
            if (selected == null || selected == root) return;
            string before = Snapshot();
            UiNode c = selected.Clone();
            RenameTree(c);
            c.SetInt("X", selected.Int("X", 0) + 16);
            c.SetInt("Y", selected.Int("Y", 0) + 16);
            c.Parent = selected.Parent;
            selected.Parent.Children.Add(c);
            selected = c;
            Commit(before);
        }

        void RenameTree(UiNode n)
        {
            if (n.Has("Name"))
            {
                string name = UniqueName(n.Kind);
                n.Set("Name", name);
                String.Free(name);
            }
            for (int i = 0; i < n.Children.Count; i++) RenameTree(n.Children[i]);
        }

        void Nudge(int dx, int dy)
        {
            if (selected == null || selected == root) return;
            string before = Snapshot();
            selected.SetInt("X", selected.Int("X", 0) + dx);
            selected.SetInt("Y", selected.Int("Y", 0) + dy);
            Commit(before);
        }

        void CopySelected()
        {
            if (selected == null || selected == root) return;
            if (clipboardOwned) String.Free(clipboard);
            clipboard = UiXml.Write(selected);
            clipboardOwned = true;
            Status = "Copied";
        }

        // Pega dentro del panel seleccionado o junto al control seleccionado.
        void Paste()
        {
            if (clipboard.Length == 0) return;
            string err;
            UiNode n = UiXml.Parse(clipboard, out err);
            String.Free(err);
            if (n == null) return;
            if (n.Kind == "Window")
            {
                delete n;
                return;
            }
            UiNode parent = root;
            if (selected != null && selected.Kind == "Panel") parent = selected;
            else if (selected != null && selected != root) parent = selected.Parent;
            string before = Snapshot();
            RenameConflicts(n);
            // Si ocupa el mismo sitio que un hermano, se desplaza en cascada.
            for (int guard = 0; guard < 64; guard++)
            {
                bool clash = false;
                for (int i = 0; i < parent.Children.Count; i++)
                    if (parent.Children[i].Int("X", 0) == n.Int("X", 0) && parent.Children[i].Int("Y", 0) == n.Int("Y", 0)) clash = true;
                if (!clash) break;
                n.SetInt("X", n.Int("X", 0) + 16);
                n.SetInt("Y", n.Int("Y", 0) + 16);
            }
            n.Parent = parent;
            parent.Children.Add(n);
            selected = n;
            Commit(before);
        }

        void RenameConflicts(UiNode n)
        {
            if (n.Has("Name") && root.FindByName(n.Get("Name")) != null)
            {
                string name = UniqueName(n.Kind);
                n.Set("Name", name);
                String.Free(name);
            }
            for (int i = 0; i < n.Children.Count; i++) RenameConflicts(n.Children[i]);
        }

        // 0..5: alinear a la izquierda, centro, derecha, arriba, medio, abajo del contenedor;
        // 6: traer al frente; 7: enviar al fondo.
        void Arrange(int what)
        {
            if (selected == null || selected == root) return;
            UiNode p = selected.Parent;
            int pw = p.Int("Width", p == root ? 800 : 100), ph = p.Int("Height", p == root ? 600 : 32);
            int w = selected.Int("Width", 100), h = selected.Int("Height", 32);
            int margin = p == root ? 24 : 16;
            string before = Snapshot();
            if (what == 0) selected.SetInt("X", margin);
            else if (what == 1) selected.SetInt("X", (pw - w) / 2);
            else if (what == 2) selected.SetInt("X", pw - w - margin);
            else if (what == 3) selected.SetInt("Y", margin);
            else if (what == 4) selected.SetInt("Y", (ph - h) / 2);
            else if (what == 5) selected.SetInt("Y", ph - h - margin);
            else if (what == 6 || what == 7)
            {
                p.Children.Remove(selected);
                if (what == 6) p.Children.Add(selected);
                else p.Children.Insert(0, selected);
            }
            Commit(before);
        }

        static string ArrangeTip(int i) =>
            i == 0 ? "Align left" : i == 1 ? "Center horizontally" : i == 2 ? "Align right" : i == 3 ? "Align top"
            : i == 4 ? "Center vertically" : i == 5 ? "Align bottom" : i == 6 ? "Bring to front" : "Send to back";

        float ArrangeButtonWidth => (PropsWidth - 36) / 8;

        int ArrangeAt(float px, float py)
        {
            if (selected == null || selected == root) return -1;
            float ty = Y + ArrangeTop;
            if (py < ty || py >= ty + 30 || px < PropsX + 18) return -1;
            int i = (int)Math.Floor((px - (PropsX + 18)) / ArrangeButtonWidth);
            return i >= 0 && i < 8 ? i : -1;
        }

        // Selecciona el siguiente (o anterior) control en el orden del esquema.
        void SelectNext(bool back)
        {
            outline.Clear();
            outlineDepth.Clear();
            BuildOutline(root, 0);
            int i = outline.IndexOf(selected);
            int n = outline.Count;
            if (n <= 1) return;
            i = back ? (i <= 1 ? n - 1 : i - 1) : (i < 0 || i >= n - 1 ? 1 : i + 1);
            Select(outline[i]);
        }

        // Nombre del método para un evento: btnSave + Click -> OnSaveClick.
        string HandlerName(UiNode n, string ev)
        {
            string name = n.Get("Name");
            string bare = name;
            string pre = "btn|txt|lbl|chk|sld|prg|pnl|rad|rdo|cmb|cbo|lst|button|textBox|label|checkBox|slider|progressBar|panel|radioButton|comboBox|listBox";
            auto parts = Text.Split(pre, "|");
            for (int i = 0; i < parts.Count; i++)
                if (name.StartsWith(parts[i]) && name.Length > parts[i].Length && Char.IsUpper((char)name[parts[i].Length]))
                {
                    bare = name.Substring(parts[i].Length);
                    break;
                }
            delete parts;
            StringBuilder sb = new StringBuilder();
            sb.Append("On");
            if (bare.Length > 0)
            {
                sb.Append(Char.ToUpper((char)bare[0]));
                sb.Append(bare.Substring(1));
            }
            sb.Append(ev);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Pide abrir (o crear) el manejador del evento principal del control.
        void OpenEvent(UiNode n, string ev)
        {
            if (n == null || n == root) return;
            string method = String.Copy(n.Get(ev));
            if (method.Length == 0)
            {
                String.Free(method);
                method = HandlerName(n, ev);
                string before = Snapshot();
                n.Set(ev, method);
                Commit(before);
            }
            String.Free(RequestHandler);
            RequestHandler = method;
        }

        static string MainEvent(string kind) =>
            kind == "TextBox" || kind == "Slider" || kind == "ComboBox" || kind == "ListBox" || kind == "RadioButton" ? "Changed" : "Click";

        // ------------------------------------------------------------------ propiedades

        void Def(List<PropDef> l, string key, int type, string options, string def, string section)
        {
            PropDef d = new PropDef();
            d.Key = key;
            d.Type = type;
            d.Options = options;
            d.Default = def;
            d.Section = section;
            l.Add(d);
        }

        List<PropDef> PropsFor(UiNode n)
        {
            auto l = new List<PropDef>();
            string k = n.Kind;
            if (k == "Window")
            {
                Def(l, "Title", 0, "", "", "Window");
                Def(l, "Class", 7, "", "", "Window");
                Def(l, "Namespace", 0, "", "", "Window");
                Def(l, "Theme", 4, "Dark|Light", "Dark", "Window");
                Def(l, "Width", 1, "", "800", "Size");
                Def(l, "Height", 1, "", "600", "Size");
                Def(l, "MinWidth", 1, "", "200", "Size");
                Def(l, "MinHeight", 1, "", "120", "Size");
                Def(l, "Resizable", 3, "", "true", "Size");
                return l;
            }
            Def(l, "Name", 7, "", "", "Control");
            if (k == "Label" || k == "Button" || k == "CheckBox" || k == "TextBox" || k == "RadioButton") Def(l, "Text", 0, "", "", "Control");
            if (k == "TextBox" || k == "ComboBox") Def(l, "Placeholder", 0, "", "", "Control");
            if (k == "ComboBox" || k == "ListBox")
            {
                Def(l, "Items", 0, "", "", "Control");
                Def(l, "SelectedIndex", 1, "", "-1", "Control");
            }
            Def(l, "X", 1, "", "0", "Layout");
            Def(l, "Y", 1, "", "0", "Layout");
            Def(l, "Width", 1, "", "100", "Layout");
            Def(l, "Height", 1, "", "32", "Layout");
            Def(l, "Anchor", 5, "", "Left,Top", "Layout");
            if (k == "Label" || k == "Button" || k == "CheckBox" || k == "TextBox" || k == "RadioButton" || k == "ComboBox" || k == "ListBox")
            {
                Def(l, "FontSize", 1, "", "14", "Appearance");
                Def(l, "Bold", 3, "", "false", "Appearance");
            }
            if (k == "Button") Def(l, "Style", 4, "Default|Primary|Subtle|Danger", "Default", "Appearance");
            if (k == "Label")
            {
                Def(l, "Style", 4, "Default|Subtle|Danger", "Default", "Appearance");
                Def(l, "TextAlign", 4, "Left|Center|Right", "Left", "Appearance");
            }
            if (k == "Panel") Def(l, "Style", 4, "Default|Subtle", "Default", "Appearance");
            if (k == "Button" || k == "Panel" || k == "TextBox" || k == "ProgressBar" || k == "ComboBox" || k == "ListBox")
                Def(l, "CornerRadius", 1, "", "", "Appearance");
            if (k == "CheckBox" || k == "RadioButton") Def(l, "Checked", 3, "", "false", "Behavior");
            if (k == "RadioButton") Def(l, "Group", 0, "", "", "Behavior");
            if (k == "Slider" || k == "ProgressBar")
            {
                Def(l, "Value", 2, "", k == "Slider" ? "50" : "0", "Behavior");
                Def(l, "Min", 2, "", "0", "Behavior");
                Def(l, "Max", 2, "", "100", "Behavior");
            }
            Def(l, "Enabled", 3, "", "true", "Behavior");
            Def(l, "Visible", 3, "", "true", "Behavior");
            if (k == "Button" || k == "CheckBox" || k == "TextBox" || k == "RadioButton") Def(l, "Click", 6, "", "", "Events");
            if (k == "TextBox" || k == "CheckBox" || k == "Slider" || k == "RadioButton" || k == "ComboBox" || k == "ListBox")
                Def(l, "Changed", 6, "", "", "Events");
            return l;
        }

        PropDef FindDef(string key)
        {
            PropDef found = new PropDef();
            auto defs = PropsFor(selected);
            for (int i = 0; i < defs.Count; i++)
                if (defs[i].Key == key) found = defs[i];
            delete defs;
            return found;
        }

        void BeginEdit(PropRow row)
        {
            CommitEdit();
            String.Free(editingKey);
            editingKey = String.Copy(row.Key);
            field.Set(selected.Get(row.Key));
            field.Focused = true;
        }

        void CancelEdit()
        {
            String.Free(editingKey);
            editingKey = String.Copy("");
            field.Focused = false;
        }

        static bool IsIdentifier(string s)
        {
            if (s.Length == 0 || !(Char.IsLetter((char)s[0]) || s[0] == '_')) return false;
            for (int i = 0; i < s.Length; i++)
                if (!(Char.IsLetterOrDigit((char)s[i]) || s[i] == '_')) return false;
            return true;
        }

        // Aplica el valor del campo en edición.
        void CommitEdit()
        {
            if (!Editing || selected == null)
            {
                CancelEdit();
                return;
            }
            string key = String.Copy(editingKey);
            string v = String.Copy(field.Text.Trim());
            CancelEdit();
            PropDef d = FindDef(key);
            bool ok = true;
            long iv = 0;
            double dv = 0;
            if (d.Type == 1 && v.Length > 0 && !Convert.TryToInt64(v, out iv)) ok = false;
            if (d.Type == 2 && v.Length > 0 && !Convert.TryToDouble(v, out dv)) ok = false;
            if ((d.Type == 7 || d.Type == 6) && v.Length > 0 && !IsIdentifier(v)) ok = false;
            if (key == "Name" && v.Length > 0 && v != selected.Get("Name") && root.FindByName(v) != null) ok = false;
            if (!ok) Status = "Invalid value";
            else if (v != selected.Get(key))
            {
                string before = Snapshot();
                if (v.Length == 0 && key != "Text" && key != "Placeholder" && key != "Items") selected.Remove(key);
                else selected.Set(key, v);
                Commit(before);
            }
            String.Free(key);
            String.Free(v);
        }

        void SetProp(string key, string value)
        {
            string before = Snapshot();
            selected.Set(key, value);
            Commit(before);
        }

        void ToggleAnchor(string flag)
        {
            string cur = selected.Has("Anchor") ? selected.Get("Anchor") : "Left,Top";
            bool l = cur.Contains("Left"), t = cur.Contains("Top"), r = cur.Contains("Right"), b = cur.Contains("Bottom");
            if (flag == "Left") l = !l;
            if (flag == "Top") t = !t;
            if (flag == "Right") r = !r;
            if (flag == "Bottom") b = !b;
            StringBuilder sb = new StringBuilder();
            if (l) sb.Append("Left,");
            if (t) sb.Append("Top,");
            if (r) sb.Append("Right,");
            if (b) sb.Append("Bottom,");
            string s = sb.ToString();
            delete sb;
            string v = s.Length > 0 ? s.Substring(0, s.Length - 1) : "None";
            string before = Snapshot();
            if (v == "Left,Top") selected.Remove("Anchor");
            else selected.Set("Anchor", v);
            Commit(before);
            String.Free(s);
        }

        // ------------------------------------------------------------------ ratón y teclado

        public void MouseDown(float px, float py, int clicks, bool shift, bool ctrl)
        {
            mouseX = px;
            mouseY = py;
            if (root == null)
            {
                SwitchToCode = true;
                return;
            }
            if (px >= PropsX)
            {
                PropsMouse(px, py);
                return;
            }
            CommitEdit();
            if (px < CanvasX)
            {
                int tab = TabAt(px, py);
                if (tab >= 0)
                {
                    leftTab = tab;
                    return;
                }
                int o = OutlineAt(px, py);
                if (o >= 0)
                {
                    Select(outline[o]);
                    if (clicks >= 2 && outline[o] != root) OpenEvent(outline[o], MainEvent(outline[o].Kind));
                    return;
                }
                int t = ToolAt(px, py);
                if (t >= 0)
                {
                    String.Free(newKind);
                    newKind = String.Copy(KindAt(t));
                    dragMode = 3;
                    dragMoved = false;
                    pressX = px;
                    pressY = py;
                }
                return;
            }
            pressX = px;
            pressY = py;
            dragMoved = false;
            int h = HandleAt(px, py);
            if (h >= 0)
            {
                dragMode = 2;
                handle = h;
                SaveOrig(selected);
                String.Free(undoBefore);
                undoBefore = Snapshot();
                return;
            }
            if (OverWindowCorner(px, py))
            {
                dragMode = 4;
                origW = root.Int("Width", 800);
                origH = root.Int("Height", 600);
                String.Free(undoBefore);
                undoBefore = Snapshot();
                return;
            }
            UiNode hit = HitTest(root, px, py);
            float rw = root.Int("Width", 800), rh = root.Int("Height", 600);
            bool inWindow = px >= originX && py >= originY - TitleBar && px < originX + rw && py < originY + rh;
            if (hit == null)
            {
                Select(inWindow ? root : null);
                return;
            }
            Select(hit);
            if (clicks >= 2)
            {
                OpenEvent(hit, MainEvent(hit.Kind));
                return;
            }
            dragMode = 1;
            SaveOrig(hit);
            String.Free(undoBefore);
            undoBefore = Snapshot();
        }

        string undoBefore = String.Copy("");

        void SaveOrig(UiNode n)
        {
            origX = n.Int("X", 0);
            origY = n.Int("Y", 0);
            origW = n.Int("Width", 100);
            origH = n.Int("Height", 32);
        }

        public void MouseMove(float px, float py, bool down, bool ctrl)
        {
            mouseX = px;
            mouseY = py;
            if (!down || dragMode == 0)
            {
                toolHover = px < CanvasX ? ToolAt(px, py) : -1;
                arrangeHover = ArrangeAt(px, py);
                return;
            }
            float dx = px - pressX, dy = py - pressY;
            if (!dragMoved && Math.Abs(dx) + Math.Abs(dy) < 3) return;
            dragMoved = true;
            guidesX.Clear();
            guidesY.Clear();
            if (dragMode == 3)
            {
                dropTarget = px >= CanvasX && px < PropsX ? ContainerAt(px, py, null) : null;
                return;
            }
            if (dragMode == 4)
            {
                root.SetInt("Width", Math.Max(160, ctrl ? origW + (int)dx : Snap(origW + (int)dx)));
                root.SetInt("Height", Math.Max(100, ctrl ? origH + (int)dy : Snap(origH + (int)dy)));
                return;
            }
            UiNode n = selected;
            if (n == null || n == root) return;
            int x = origX, y = origY, w = origW, h = origH;
            if (dragMode == 1)
            {
                x = origX + (int)dx;
                y = origY + (int)dy;
                if (!ctrl)
                {
                    x = SnapAxis(n, x, w, true);
                    y = SnapAxis(n, y, h, false);
                }
                dropTarget = ContainerAt(px, py, n);
            }
            else
            {
                int idx = handle;
                bool left = idx == 0 || idx == 6 || idx == 7, right = idx == 2 || idx == 3 || idx == 4;
                bool top = idx <= 2, bottom = idx >= 4 && idx <= 6;
                if (right) w = Math.Max(8, ctrl ? origW + (int)dx : SnapEdge(n, origX + origW + (int)dx, true) - origX);
                if (bottom) h = Math.Max(4, ctrl ? origH + (int)dy : SnapEdge(n, origY + origH + (int)dy, false) - origY);
                if (left)
                {
                    int nx = ctrl ? origX + (int)dx : SnapEdge(n, origX + (int)dx, true);
                    nx = Math.Min(nx, origX + origW - 8);
                    w = origW + (origX - nx);
                    x = nx;
                }
                if (top)
                {
                    int ny = ctrl ? origY + (int)dy : SnapEdge(n, origY + (int)dy, false);
                    ny = Math.Min(ny, origY + origH - 4);
                    h = origH + (origY - ny);
                    y = ny;
                }
            }
            n.SetInt("X", x);
            n.SetInt("Y", y);
            n.SetInt("Width", w);
            n.SetInt("Height", h);
        }

        // Ajusta una posición a los bordes y centros de los vecinos y del contenedor (guías
        // inteligentes); si no hay ninguno cerca, a la cuadrícula.
        int SnapAxis(UiNode n, int pos, int size, bool horizontal)
        {
            UiNode parent = n.Parent;
            int best = 7, result = Snap(pos);
            float guide = -1;
            float origin = horizontal ? ContentX(parent) : ContentY(parent);
            for (int pass = 0; pass < 3; pass++)
            {
                int mine = pass == 0 ? pos : (pass == 1 ? pos + size / 2 : pos + size);
                for (int i = -1; i < parent.Children.Count; i++)
                {
                    UiNode o = i < 0 ? parent : parent.Children[i];
                    if (o == n) continue;
                    int os = i < 0 ? 0 : (horizontal ? o.Int("X", 0) : o.Int("Y", 0));
                    int ol = horizontal ? o.Int("Width", 100) : o.Int("Height", 32);
                    if (i < 0) ol = horizontal ? parent.Int("Width", 800) : parent.Int("Height", 600);
                    for (int k = 0; k < 3; k++)
                    {
                        int theirs = k == 0 ? os : (k == 1 ? os + ol / 2 : os + ol);
                        if (i < 0 && k != 1)
                        {
                            // Márgenes del contenedor: 16 / 24 píxeles desde el borde.
                            theirs = k == 0 ? 24 : ol - 24;
                        }
                        int d = Math.Abs(mine - theirs);
                        if (d < best)
                        {
                            best = d;
                            result = pos + (theirs - mine);
                            guide = origin + theirs;
                        }
                    }
                }
            }
            if (guide >= 0)
            {
                if (horizontal) guidesX.Add(guide);
                else guidesY.Add(guide);
            }
            return result;
        }

        int SnapEdge(UiNode n, int edge, bool horizontal)
        {
            UiNode parent = n.Parent;
            int best = 7, result = Snap(edge);
            float guide = -1;
            float origin = horizontal ? ContentX(parent) : ContentY(parent);
            for (int i = 0; i < parent.Children.Count; i++)
            {
                UiNode o = parent.Children[i];
                if (o == n) continue;
                int os = horizontal ? o.Int("X", 0) : o.Int("Y", 0);
                int ol = horizontal ? o.Int("Width", 100) : o.Int("Height", 32);
                for (int k = 0; k < 2; k++)
                {
                    int theirs = k == 0 ? os : os + ol;
                    int d = Math.Abs(edge - theirs);
                    if (d < best)
                    {
                        best = d;
                        result = theirs;
                        guide = origin + theirs;
                    }
                }
            }
            if (guide >= 0)
            {
                if (horizontal) guidesX.Add(guide);
                else guidesY.Add(guide);
            }
            return result;
        }

        public void MouseUp(float px, float py)
        {
            int mode = dragMode;
            dragMode = 0;
            guidesX.Clear();
            guidesY.Clear();
            if (mode == 3)
            {
                UiNode target = dropTarget;
                dropTarget = null;
                if (root == null) return;
                if (!dragMoved)
                {
                    // Clic: añadir dentro del panel seleccionado o de la ventana, en cascada.
                    UiNode parent = selected != null && selected.Kind == "Panel" ? selected : root;
                    int offset = (parent.Children.Count % 8) * 16;
                    AddNode(newKind, parent, 24 + offset, 24 + offset);
                    return;
                }
                if (target == null) return;
                UiNode tmp = CreateNode(newKind);
                int x = Snap((int)(px - ContentX(target)) - tmp.Int("Width", 100) / 2);
                int y = Snap((int)(py - ContentY(target)) - tmp.Int("Height", 32) / 2);
                delete tmp;
                AddNode(newKind, target, Math.Max(0, x), Math.Max(0, y));
                return;
            }
            if (mode == 1 && dragMoved && selected != null && selected != root)
            {
                // Soltar sobre otro panel: cambiar de contenedor conservando la posición en pantalla.
                UiNode target = dropTarget;
                dropTarget = null;
                if (target != null && target != selected.Parent && !selected.IsAncestorOf(target))
                {
                    float ax = ContentX(selected.Parent) + selected.Int("X", 0);
                    float ay = ContentY(selected.Parent) + selected.Int("Y", 0);
                    selected.Parent.Children.Remove(selected);
                    selected.Parent = target;
                    target.Children.Add(selected);
                    selected.SetInt("X", Snap((int)(ax - ContentX(target))));
                    selected.SetInt("Y", Snap((int)(ay - ContentY(target))));
                }
            }
            if ((mode == 1 || mode == 2 || mode == 4) && dragMoved)
            {
                string before = undoBefore;
                undoBefore = String.Copy("");
                Commit(before);
            }
            else if (mode == 1 || mode == 2 || mode == 4)
            {
                String.Free(undoBefore);
                undoBefore = String.Copy("");
            }
        }

        public void Scroll(float px, int lines, bool shift)
        {
            if (px < CanvasX)
            {
                if (leftTab == 1) outlineScroll = (float)Math.Max(0.0, (double)(outlineScroll + lines * 24));
                return;
            }
            if (px >= PropsX)
            {
                propsScroll = (float)Math.Max(0.0, (double)(propsScroll + lines * 24));
                return;
            }
            if (shift) scrollX = (float)Math.Max(0.0, (double)(scrollX + lines * 24));
            else scrollY = (float)Math.Max(0.0, (double)(scrollY + lines * 24));
        }

        void PropsMouse(float px, float py)
        {
            if (selected == null) return;
            int a = ArrangeAt(px, py);
            if (a >= 0)
            {
                CommitEdit();
                Arrange(a);
                return;
            }
            for (int i = 0; i < rows.Count; i++)
            {
                PropRow row = rows[i];
                if (py < row.Y || py >= row.Y + RowHeight) continue;
                if (px < row.VX)
                {
                    CommitEdit();
                    return;
                }
                if (row.Type <= 2 || row.Type == 7)
                {
                    if (editingKey != row.Key) BeginEdit(row);
                    return;
                }
                CommitEdit();
                if (row.Type == 3)
                {
                    PropDef d = FindDef(row.Key);
                    bool cur = selected.Bool(row.Key, d.Default == "true");
                    SetProp(row.Key, cur ? "false" : "true");
                }
                else if (row.Type == 4)
                {
                    auto opts = Text.Split(row.Options, "|");
                    int idx = (int)Math.Floor((px - row.VX) / (row.VW / opts.Count));
                    if (idx >= 0 && idx < opts.Count) SetProp(row.Key, opts[idx]);
                    delete opts;
                }
                else if (row.Type == 5)
                {
                    int idx = (int)Math.Floor((px - row.VX) / (row.VW / 4));
                    if (idx == 0) ToggleAnchor("Left");
                    else if (idx == 1) ToggleAnchor("Top");
                    else if (idx == 2) ToggleAnchor("Right");
                    else if (idx == 3) ToggleAnchor("Bottom");
                }
                else if (row.Type == 6)
                {
                    if (px >= row.VX + row.VW - 34) OpenEvent(selected, row.Key);
                    else if (editingKey != row.Key) BeginEdit(row);
                }
                return;
            }
            CommitEdit();
        }

        // Devuelve true si el diseñador usó la tecla.
        public bool Key(Event e)
        {
            if (root == null) return false;
            uint k = e.Key;
            if (Editing)
            {
                if (k == Keys.Return || k == Keys.KeypadEnter || k == Keys.Tab) CommitEdit();
                else if (k == Keys.Escape) CancelEdit();
                else field.Key(e);
                return true;
            }
            if (e.Ctrl && k == 'z' && !e.Shift)
            {
                Restore(undo, redo);
                return true;
            }
            if (e.Ctrl && (k == 'y' || (k == 'z' && e.Shift)))
            {
                Restore(redo, undo);
                return true;
            }
            if (e.Ctrl && k == 'd')
            {
                DuplicateSelected();
                return true;
            }
            if (e.Ctrl && (k == 'c' || k == 'x'))
            {
                CopySelected();
                if (k == 'x') DeleteSelected();
                return true;
            }
            if (e.Ctrl && k == 'v')
            {
                Paste();
                return true;
            }
            if (e.Ctrl && (k == Keys.Up || k == Keys.Down))
            {
                Arrange(k == Keys.Up ? 6 : 7);
                return true;
            }
            if (k == Keys.Tab)
            {
                SelectNext(e.Shift);
                return true;
            }
            if (k == Keys.Delete || k == Keys.BackSpace)
            {
                DeleteSelected();
                return true;
            }
            int step = e.Shift ? Grid : 1;
            if (k == Keys.Left) Nudge(-step, 0);
            else if (k == Keys.Right) Nudge(step, 0);
            else if (k == Keys.Up) Nudge(0, -step);
            else if (k == Keys.Down) Nudge(0, step);
            else if (k == Keys.Escape)
            {
                if (selected != null && selected != root) selected = selected.Parent;
            }
            else if ((k == Keys.Return || k == Keys.KeypadEnter) && selected != null && selected != root)
                OpenEvent(selected, MainEvent(selected.Kind));
            else return false;
            return true;
        }

        // ------------------------------------------------------------------ dibujo

        // Paleta de std.ui (debe coincidir con lib/std/ui.fst).
        Color Pal(int which)
        {
            bool light = root != null && root.Get("Theme").ToLower() == "light";
            switch (which)
            {
                case 0: return Color.Hex(light ? (uint)0xf5f5f6 : (uint)0x0f0f11);  // fondo
                case 1: return Color.Hex(light ? (uint)0xffffff : (uint)0x18181b);  // superficie
                case 2: return Color.Hex(light ? (uint)0xdedee2 : (uint)0x2a2a2f);  // borde
                case 3: return Color.Hex(light ? (uint)0xc4c4ca : (uint)0x3a3a41);  // borde fuerte
                case 4: return Color.Hex(light ? (uint)0xffffff : (uint)0x0b0b0d);  // entrada
                case 5: return Color.Hex(light ? (uint)0x18181b : (uint)0xececee);  // texto
                case 6: return Color.Hex(light ? (uint)0x71717a : (uint)0x8e8e96);  // texto tenue
                case 7: return Color.Hex(light ? (uint)0x18181b : (uint)0xf4f4f5);  // primario
                case 8: return Color.Hex(light ? (uint)0xffffff : (uint)0x0b0b0c);  // texto primario
                case 9: return Color.Hex(light ? (uint)0xdc3c3c : (uint)0xe5484d);  // peligro
                default: return Color.Hex(light ? (uint)0xe4e4e7 : (uint)0x2c2c31); // pista
            }
        }

        static Color Accent => Color.Hex(0x4c8dff);

        public void Draw(Renderer r)
        {
            Sync();
            r.PushClip(X, Y, W, H);
            if (root == null)
            {
                DrawError(r);
                r.PopClip();
                return;
            }
            Layout();
            // Lienzo
            r.Rect(CanvasX, Y, CanvasW, H, Theme.Base);
            r.PushClip(CanvasX, Y, CanvasW, H);
            DrawDots(r);
            DrawWindow(r);
            r.PopClip();
            DrawToolbox(r);
            DrawProps(r);
            if (dragMode == 3 && dragMoved) DrawGhost(r);
            r.PopClip();
        }

        void DrawError(Renderer r)
        {
            r.Rect(X, Y, W, H, Theme.Base);
            float cx = X + W / 2;
            string title = L.T("This interface cannot be shown in the designer");
            r.Text(r.UiBold, cx - r.TextWidth(r.UiBold, title) / 2, Y + H / 2 - 40, title, Theme.Text);
            r.Text(r.Ui, cx - r.TextWidth(r.Ui, error) / 2, Y + H / 2 - 14, error, Theme.Error);
            string hint = L.T("Click to open the XML code");
            r.Text(r.Ui, cx - r.TextWidth(r.Ui, hint) / 2, Y + H / 2 + 12, hint, Theme.TextTertiary);
        }

        void DrawDots(Renderer r)
        {
            Color dot = Color.Hex(0xffffff, 0.05f);
            float step = 16;
            float sx = CanvasX + step - (scrollX - (float)Math.Floor(scrollX / step) * step);
            float sy = Y + step - (scrollY - (float)Math.Floor(scrollY / step) * step);
            for (float y = sy; y < Y + H; y += step)
                for (float x = sx; x < CanvasX + CanvasW; x += step) r.Rect(x, y, 1.5f, 1.5f, dot);
        }

        void DrawWindow(Renderer r)
        {
            float w = root.Int("Width", 800), h = root.Int("Height", 600);
            float fx = originX, fy = originY - TitleBar;
            bool light = root.Get("Theme").ToLower() == "light";
            r.Shadow(fx, fy, w, h + TitleBar, 12, 28, Color.Hex(0x000000, 0.6f));
            r.RoundRect(fx - 1, fy - 1, w + 2, h + TitleBar + 2, 11, Color.Hex(0x3a3a40));
            r.RoundRect(fx, fy, w, h + TitleBar, 10, light ? Color.Hex(0xe9e9ec) : Color.Hex(0x1c1c20));
            string title = root.Has("Title") ? root.Get("Title") : root.Get("Class");
            r.Text(r.UiBold, fx + (w - r.TextWidth(r.UiBold, title)) / 2, fy + 9, title, light ? Color.Hex(0x2a2a2e) : Theme.TextSecondary);
            for (int i = 0; i < 3; i++)
                r.RoundRect(fx + w - 22 - i * 20, fy + 12, 10, 10, 5, light ? Color.Hex(0xc8c8cc) : Color.Hex(0x3a3a40));
            r.PushClip(fx, originY, w, h);
            r.Rect(fx, originY, w, h, Pal(0));
            // Cuadrícula fina dentro de la ventana
            Color line = Color.Hex(light ? (uint)0x000000 : (uint)0xffffff, 0.035f);
            for (float gx = Grid * 2; gx < w; gx += Grid * 2) r.Rect(fx + gx, originY, 1, h, line);
            for (float gy = Grid * 2; gy < h; gy += Grid * 2) r.Rect(fx, originY + gy, w, 1, line);
            root.SX = fx;
            root.SY = originY;
            root.SW = w;
            root.SH = h;
            for (int i = 0; i < root.Children.Count; i++) DrawNode(r, root.Children[i], originX, originY);
            r.PopClip();
            // Guías inteligentes
            for (int i = 0; i < guidesX.Count; i++) r.Rect(guidesX[i], originY, 1, h, Color.Hex(0xff5fa2));
            for (int i = 0; i < guidesY.Count; i++) r.Rect(fx, guidesY[i], w, 1, Color.Hex(0xff5fa2));
            // Contenedor de destino al arrastrar
            if (dropTarget != null && dragMoved && (dragMode == 3 || (dragMode == 1 && dropTarget != selected.Parent)))
                r.RoundBorder(dropTarget.SX - 2, dropTarget.SY - 2, dropTarget.SW + 4, dropTarget.SH + 4, 8, 2, Accent);
            // Selección
            if (selected != null && selected != root)
            {
                r.RectOutline(selected.SX - 1, selected.SY - 1, selected.SW + 2, selected.SH + 2, 1.5f, Accent);
                for (int i = 0; i < 8; i++)
                {
                    float hx = 0, hy = 0;
                    HandlePos(selected, i, out hx, out hy);
                    r.RoundRect(hx - 4, hy - 4, 8, 8, 2, Color.Hex(0xffffff));
                    r.RoundBorder(hx - 4, hy - 4, 8, 8, 2, 1, Accent);
                }
                if (dragMode == 1 || dragMode == 2)
                {
                    string info = dragMode == 1 ? Pair(selected.Int("X", 0), ", ", selected.Int("Y", 0))
                                                : Pair(selected.Int("Width", 0), " × ", selected.Int("Height", 0));
                    float tw = r.TextWidth(r.UiSmall, info) + 14;
                    float iy = selected.SY + selected.SH + 8;
                    r.RoundRect(selected.SX, iy, tw, 20, 6, Accent);
                    r.Text(r.UiSmall, selected.SX + 7, iy + 3, info, Color.Hex(0xffffff));
                    String.Free(info);
                }
                string name = selected.Get("Name");
                if (name.Length > 0 && dragMode == 0)
                {
                    float tw = r.TextWidth(r.UiSmall, name) + 12;
                    r.RoundRect(selected.SX, selected.SY - 22, tw, 18, 5, Accent);
                    r.Text(r.UiSmall, selected.SX + 6, selected.SY - 21, name, Color.Hex(0xffffff));
                }
            }
            else if (selected == root)
                r.RoundBorder(fx - 3, fy - 3, w + 6, h + TitleBar + 6, 12, 1.5f, Accent);
            // Asa de tamaño de la ventana
            float cx = originX + w, cy = originY + h;
            r.RoundRect(cx - 2, cy - 2, 10, 10, 3, OverWindowCorner(mouseX, mouseY) || dragMode == 4 ? Accent : Color.Hex(0x5a5a62));
            if (dragMode == 4)
            {
                string info = Pair((int)w, " × ", (int)h);
                r.RoundRect(cx + 12, cy + 8, r.TextWidth(r.UiSmall, info) + 14, 20, 6, Accent);
                r.Text(r.UiSmall, cx + 19, cy + 11, info, Color.Hex(0xffffff));
                String.Free(info);
            }
        }

        static string Pair(int a, string sep, int b)
        {
            string sa = Convert.ToString(a), sb = Convert.ToString(b);
            string r = String.Concat(sa, sep, sb);
            String.Free(sa);
            String.Free(sb);
            return r;
        }

        // Elemento i de una lista "a;b;c" (copia; "" si no existe).
        static string ItemAt(string list, int i)
        {
            if (i < 0 || list.Length == 0) return String.Copy("");
            auto parts = Text.Split(list, ";");
            string r = i < parts.Count ? String.Copy(parts[i].Trim()) : String.Copy("");
            delete parts;
            return r;
        }

        void CenteredText(Renderer r, Font f, string s, float x, float y, float w, float h, int align, Color c)
        {
            float tw = r.TextWidth(f, s);
            float tx = align == 1 ? x + (w - tw) / 2 : (align == 2 ? x + w - tw : x);
            r.Text(f, tx, y + (h - (f.Ascent + f.Descent)) / 2 - 1, s, c);
        }

        void DrawNode(Renderer r, UiNode n, float ox, float oy)
        {
            float x = ox + n.Int("X", 0), y = oy + n.Int("Y", 0);
            float w = n.Int("Width", 100), h = n.Int("Height", 32);
            n.SX = x;
            n.SY = y;
            n.SW = w;
            n.SH = h;
            bool visible = n.Bool("Visible", true);
            bool enabled = n.Bool("Enabled", true);
            string k = n.Kind;
            string style = n.Get("Style");
            int fs = n.Int("FontSize", 14);
            Font f = r.Sans(fs, n.Bool("Bold", false) || (k == "Button" && style == "Primary"));
            string text = n.Get("Text");
            Color fg = enabled ? Pal(5) : Pal(6);
            if (!visible)
            {
                r.RoundBorder(x, y, w, h, 4, 1, Color.Hex(0x808080, 0.5f));
                CenteredText(r, r.UiSmall, n.Get("Name"), x, y, w, h, 1, Pal(6));
                return;
            }
            if (k == "Panel")
            {
                float rad = n.Int("CornerRadius", 10);
                if (style != "Subtle")
                {
                    r.RoundRect(x, y, w, h, rad, Pal(1));
                    r.RoundBorder(x, y, w, h, rad, 1, Pal(2));
                }
                else r.RoundBorder(x, y, w, h, rad, 1, Color.Hex(0x808080, 0.35f));
                r.PushClip(x, y, w, h);
                for (int i = 0; i < n.Children.Count; i++) DrawNode(r, n.Children[i], x, y);
                r.PopClip();
            }
            else if (k == "Label")
            {
                Color c = style == "Subtle" ? Pal(6) : (style == "Danger" ? Pal(9) : fg);
                string al = n.Get("TextAlign");
                CenteredText(r, f, text, x, y, w, h, al == "Center" ? 1 : (al == "Right" ? 2 : 0), c);
            }
            else if (k == "Button")
            {
                float rad = n.Int("CornerRadius", 8);
                Color bg = Pal(1), tc = fg;
                bool border = true;
                if (style == "Primary")
                {
                    bg = Pal(7);
                    tc = Pal(8);
                    border = false;
                }
                else if (style == "Danger")
                {
                    bg = Pal(9);
                    tc = Color.Hex(0xffffff);
                    border = false;
                }
                else if (style == "Subtle") border = false;
                if (style != "Subtle") r.RoundRect(x, y, w, h, rad, bg);
                if (border) r.RoundBorder(x, y, w, h, rad, 1, Pal(2));
                CenteredText(r, f, text, x, y, w, h, 1, tc);
            }
            else if (k == "TextBox")
            {
                float rad = n.Int("CornerRadius", 8);
                r.RoundRect(x, y, w, h, rad, Pal(4));
                r.RoundBorder(x, y, w, h, rad, 1, Pal(2));
                r.PushClip(x + 10, y, w - 20, h);
                if (text.Length > 0) CenteredText(r, f, text, x + 10, y, w - 20, h, 0, fg);
                else CenteredText(r, f, n.Get("Placeholder"), x + 10, y, w - 20, h, 0, Pal(6));
                r.PopClip();
            }
            else if (k == "CheckBox")
            {
                float by = y + (h - 18) / 2;
                if (n.Bool("Checked", false))
                {
                    r.RoundRect(x, by, 18, 18, 5, Pal(7));
                    r.Text(r.Icons, x + 3, by + 1, "✓", Pal(8));
                }
                else
                {
                    r.RoundRect(x, by, 18, 18, 5, Pal(4));
                    r.RoundBorder(x, by, 18, 18, 5, 1.2f, Pal(3));
                }
                CenteredText(r, f, text, x + 28, y, w - 28, h, 0, fg);
            }
            else if (k == "RadioButton")
            {
                float cy = y + h / 2;
                if (n.Bool("Checked", false))
                {
                    r.RoundRect(x, cy - 9, 18, 18, 9, Pal(7));
                    r.RoundRect(x + 5.5f, cy - 3.5f, 7, 7, 3.5f, Pal(8));
                }
                else
                {
                    r.RoundRect(x, cy - 9, 18, 18, 9, Pal(4));
                    r.RoundBorder(x, cy - 9, 18, 18, 9, 1.2f, Pal(3));
                }
                CenteredText(r, f, text, x + 28, y, w - 28, h, 0, fg);
            }
            else if (k == "ComboBox")
            {
                float rad = n.Int("CornerRadius", 8);
                r.RoundRect(x, y, w, h, rad, Pal(1));
                r.RoundBorder(x, y, w, h, rad, 1, Pal(2));
                string item = ItemAt(n.Get("Items"), n.Int("SelectedIndex", -1));
                r.PushClip(x + 10, y, w - 44, h);
                if (item.Length > 0) CenteredText(r, f, item, x + 12, y, w - 44, h, 0, fg);
                else CenteredText(r, f, n.Get("Placeholder"), x + 12, y, w - 44, h, 0, Pal(6));
                r.PopClip();
                String.Free(item);
                r.Text(r.Icons, x + w - 24, y + (h - (r.Icons.Ascent + r.Icons.Descent)) / 2 - 1, "▾", Pal(6));
            }
            else if (k == "ListBox")
            {
                float rad = n.Int("CornerRadius", 8);
                r.RoundRect(x, y, w, h, rad, Pal(4));
                r.RoundBorder(x, y, w, h, rad, 1, Pal(2));
                auto items = Text.Split(n.Get("Items"), ";");
                int sel = n.Int("SelectedIndex", -1);
                float rh = (float)Math.Ceiling(f.Ascent + f.Descent) + 14;
                r.PushClip(x + 1, y + 1, w - 2, h - 2);
                for (int i = 0; i < items.Count && 4 + i * rh < h; i++)
                {
                    float ry = y + 4 + i * rh;
                    if (i == sel)
                    {
                        Color hl = Pal(5);
                        hl.A = 0.16f;
                        r.RoundRect(x + 4, ry, w - 8, rh, 6, hl);
                    }
                    CenteredText(r, f, items[i].Trim(), x + 14, ry, w - 28, rh, 0, fg);
                }
                r.PopClip();
                delete items;
            }
            else if (k == "Slider" || k == "ProgressBar")
            {
                float min = n.Num("Min", 0), max = n.Num("Max", 100);
                float v = n.Num("Value", k == "Slider" ? 50 : 0);
                float t = max > min ? (v - min) / (max - min) : 0;
                if (t < 0) t = 0;
                if (t > 1) t = 1;
                if (k == "Slider")
                {
                    float cy = y + h / 2;
                    float pos = x + 8 + (w - 16) * t;
                    r.RoundRect(x, cy - 2, w, 4, 2, Pal(10));
                    r.RoundRect(x, cy - 2, pos - x, 4, 2, Pal(7));
                    r.RoundRect(pos - 8, cy - 8, 16, 16, 8, Pal(7));
                    r.RoundRect(pos - 3, cy - 3, 6, 6, 3, Pal(0));
                }
                else
                {
                    float rad = n.Has("CornerRadius") ? n.Int("CornerRadius", 0) : h / 2;
                    r.RoundRect(x, y, w, h, rad, Pal(10));
                    if (t > 0) r.RoundRect(x, y, w * t > h ? w * t : h, h, rad, Pal(7));
                }
            }
        }

        void DrawToolbox(Renderer r)
        {
            r.Rect(X, Y, ToolboxWidth, H, Theme.Surface);
            r.Rect(X + ToolboxWidth - 1, Y, 1, H, Theme.Border);
            // Pestañas: herramientas | esquema
            float tw = (ToolboxWidth - 20) / 2;
            r.RoundRect(X + 10, Y + 10, ToolboxWidth - 20, 28, 8, Theme.Base);
            for (int t = 0; t < 2; t++)
            {
                string label = L.T(t == 0 ? "TOOLBOX" : "OUTLINE");
                float lx = X + 10 + t * tw;
                if (leftTab == t) r.RoundRect(lx + 2, Y + 12, tw - 4, 24, 6, Theme.Active);
                r.Text(r.UiSmall, lx + (tw - r.TextWidth(r.UiSmall, label)) / 2, Y + 16, label, leftTab == t ? Theme.White : Theme.TextTertiary);
            }
            r.PushClip(X, Y + 46, ToolboxWidth, H - 46);
            if (leftTab == 1) DrawOutline(r);
            else
            {
                auto parts = Text.Split(kinds, "|");
                for (int i = 0; i < parts.Count; i++)
                {
                    float iy = Y + 52 + i * ToolRow;
                    bool hot = toolHover == i || (dragMode == 3 && newKind == parts[i]);
                    if (hot) r.RoundRect(X + 10, iy, ToolboxWidth - 20, ToolRow - 2, 8, Theme.Hover);
                    DrawToolIcon(r, parts[i], X + 20, iy + 6);
                    r.Text(r.Ui, X + 54, iy + 8, L.T(parts[i]), hot ? Theme.White : Theme.Text);
                }
                delete parts;
                float hy = Y + 52 + KindCount * ToolRow + 12;
                r.Rect(X + 16, hy, ToolboxWidth - 32, 1, Theme.Border);
                r.Text(r.UiSmall, X + 16, hy + 14, L.T("Drag a control onto the window"), Theme.TextTertiary);
                r.Text(r.UiSmall, X + 16, hy + 32, L.T("Double-click: go to its event"), Theme.TextTertiary);
                r.Text(r.UiSmall, X + 16, hy + 50, L.T("Ctrl while dragging: no snapping"), Theme.TextTertiary);
                r.Text(r.UiSmall, X + 16, hy + 68, L.T("Ctrl+D duplicate · Del delete"), Theme.TextTertiary);
                r.Text(r.UiSmall, X + 16, hy + 86, L.T("Ctrl+C / Ctrl+V copy and paste"), Theme.TextTertiary);
                r.Text(r.UiSmall, X + 16, hy + 104, L.T("Tab: next control"), Theme.TextTertiary);
            }
            r.PopClip();
        }

        // Árbol de controles: clic para seleccionar, doble clic para ir al evento.
        void DrawOutline(Renderer r)
        {
            outline.Clear();
            outlineDepth.Clear();
            BuildOutline(root, 0);
            float total = outline.Count * OutlineRow;
            float room = H - 60;
            if (outlineScroll > total - room) outlineScroll = (float)Math.Max(0.0, (double)(total - room));
            int hover = OutlineAt(mouseX, mouseY);
            for (int i = 0; i < outline.Count; i++)
            {
                UiNode n = outline[i];
                float iy = Y + 52 + i * OutlineRow - outlineScroll;
                if (iy + OutlineRow < Y + 46 || iy > Y + H) continue;
                bool sel = n == selected;
                if (sel) r.RoundRect(X + 6, iy, ToolboxWidth - 12, OutlineRow - 2, 6, Theme.Active);
                else if (i == hover) r.RoundRect(X + 6, iy, ToolboxWidth - 12, OutlineRow - 2, 6, Theme.Hover);
                float ix = X + 14 + outlineDepth[i] * 14;
                for (int d = 1; d <= outlineDepth[i]; d++) r.Rect(X + 14 + d * 14 - 8, iy, 1, OutlineRow - 2, Theme.Border);
                bool named = n.Get("Name").Length > 0;
                string label = n == root ? (root.Has("Class") ? root.Get("Class") : "Window") : (named ? n.Get("Name") : L.T(n.Kind));
                if (n == root) r.Text(r.UiBold, ix, iy + 5, label, sel ? Theme.White : Theme.Text);
                else
                {
                    float lw = r.TextWidth(r.Ui, label);
                    r.Text(r.Ui, ix, iy + 5, label, sel ? Theme.White : (named ? Theme.Text : Theme.TextSecondary));
                    string kind = L.T(n.Kind);
                    if (ix + lw + 8 + r.TextWidth(r.UiSmall, kind) < X + ToolboxWidth - 12)
                        r.Text(r.UiSmall, ix + lw + 8, iy + 7, kind, Theme.TextTertiary);
                }
            }
        }

        void DrawToolIcon(Renderer r, string kind, float x, float y)
        {
            Color c = Theme.TextSecondary;
            Color dim = Theme.BorderStrong;
            if (kind == "Label")
            {
                r.Text(r.UiBold, x + 2, y, "Aa", c);
            }
            else if (kind == "Button")
            {
                r.RoundRect(x, y + 4, 22, 13, 4, c);
            }
            else if (kind == "TextBox")
            {
                r.RoundBorder(x, y + 3, 22, 15, 4, 1.2f, c);
                r.Rect(x + 5, y + 6, 1.5f, 9, c);
            }
            else if (kind == "CheckBox")
            {
                r.RoundRect(x + 3, y + 3, 15, 15, 4, c);
                r.Text(r.Icons, x + 4, y + 1, "✓", Theme.Surface);
            }
            else if (kind == "Slider")
            {
                r.RoundRect(x, y + 9, 22, 3, 1.5f, dim);
                r.RoundRect(x, y + 9, 12, 3, 1.5f, c);
                r.RoundRect(x + 8, y + 5, 11, 11, 5.5f, c);
            }
            else if (kind == "ProgressBar")
            {
                r.RoundRect(x, y + 8, 22, 5, 2.5f, dim);
                r.RoundRect(x, y + 8, 14, 5, 2.5f, c);
            }
            else if (kind == "RadioButton")
            {
                r.RoundRect(x + 3, y + 3, 16, 16, 8, c);
                r.RoundRect(x + 8, y + 8, 6, 6, 3, Theme.Surface);
            }
            else if (kind == "ComboBox")
            {
                r.RoundBorder(x, y + 3, 22, 15, 4, 1.2f, c);
                r.Text(r.Icons, x + 11, y + 2, "▾", c);
            }
            else if (kind == "ListBox")
            {
                r.RoundBorder(x, y + 1, 22, 19, 4, 1.2f, c);
                r.Rect(x + 4, y + 6, 14, 1.5f, c);
                r.RoundRect(x + 3, y + 9, 16, 4, 1.5f, dim);
                r.Rect(x + 4, y + 15, 10, 1.5f, c);
            }
            else
            {
                r.RoundBorder(x, y + 1, 22, 19, 4, 1.2f, c);
                r.Rect(x + 4, y + 6, 10, 1.5f, c);
            }
        }

        void DrawGhost(Renderer r)
        {
            UiNode tmp = CreateNode(newKind);
            float w = tmp.Int("Width", 100), h = tmp.Int("Height", 32);
            delete tmp;
            float gx = mouseX - w / 2, gy = mouseY - h / 2;
            r.RoundRect(gx, gy, w, h, 6, Color.Hex(0x4c8dff, 0.18f));
            r.RoundBorder(gx, gy, w, h, 6, 1.5f, Accent);
            CenteredText(r, r.UiSmall, L.T(newKind), gx, gy, w, h, 1, Color.Hex(0xffffff));
        }

        void DrawProps(Renderer r)
        {
            float px = PropsX;
            r.Rect(px, Y, PropsWidth, H, Theme.Surface);
            r.Rect(px, Y, 1, H, Theme.Border);
            rows.Clear();
            if (selected == null)
            {
                r.Text(r.UiSmall, px + 18, Y + 18, L.T("PROPERTIES"), Theme.TextTertiary);
                r.Text(r.Ui, px + 18, Y + 52, L.T("Select a control to edit it"), Theme.TextTertiary);
                return;
            }
            r.Text(r.UiSmall, px + 18, Y + 18, L.T("PROPERTIES"), Theme.TextTertiary);
            string kindLabel = L.T(selected.Kind);
            float kw = r.TextWidth(r.UiSmall, kindLabel) + 14;
            r.RoundRect(px + PropsWidth - 18 - kw, Y + 14, kw, 20, 6, Theme.Elevated);
            r.Text(r.UiSmall, px + PropsWidth - 11 - kw, Y + 16, kindLabel, Theme.TextSecondary);
            float top = Y + 44;
            if (selected != root)
            {
                DrawArrangeBar(r, px + 18, Y + ArrangeTop);
                top = Y + ArrangeTop + 38;
            }
            r.PushClip(px, top, PropsWidth, H - (top - Y));
            auto defs = PropsFor(selected);
            float y = top + 4 - propsScroll;
            string section = "";
            float lx = px + 18, vx = px + 112, vw = PropsWidth - 112 - 16;
            for (int i = 0; i < defs.Count; i++)
            {
                PropDef d = defs[i];
                if (d.Section != section)
                {
                    section = d.Section;
                    y += 10;
                    r.Text(r.UiBold, lx, y, L.T(section), Theme.Text);
                    y += 26;
                }
                PropRow row = new PropRow();
                row.Key = d.Key;
                row.Type = d.Type;
                row.Y = y;
                row.VX = vx;
                row.VW = vw;
                row.Options = d.Options;
                rows.Add(row);
                r.Text(r.Ui, lx, y + 9, d.Key, Theme.TextSecondary);
                bool has = selected.Has(d.Key);
                string val = has ? selected.Get(d.Key) : d.Default;
                if (d.Type <= 2 || d.Type == 7 || d.Type == 6)
                {
                    float fw = d.Type == 6 ? vw - 38 : vw;
                    if (editingKey == d.Key)
                    {
                        field.Draw(r, vx, y + 1, fw, "");
                    }
                    else
                    {
                        r.RoundRect(vx, y + 1, fw, 34, 8, Theme.Base);
                        r.RoundBorder(vx, y + 1, fw, 34, 8, 1, Theme.Border);
                        r.PushClip(vx + 8, y, fw - 16, 36);
                        r.Text(r.Ui, vx + 12, y + 9, val, has ? Theme.Text : Theme.TextTertiary);
                        r.PopClip();
                    }
                    if (d.Type == 6)
                    {
                        float bx = vx + vw - 34;
                        r.RoundRect(bx, y + 1, 34, 34, 8, Theme.Elevated);
                        r.Text(r.Icons, bx + 11, y + 9, "→", Theme.Text);
                    }
                }
                else if (d.Type == 3)
                {
                    bool on = val.ToLower() == "true";
                    r.RoundRect(vx, y + 7, 38, 22, 11, on ? Theme.White : Theme.Active);
                    r.RoundRect(on ? vx + 19 : vx + 3, y + 10, 16, 16, 8, on ? Theme.Black : Theme.TextTertiary);
                }
                else if (d.Type == 4)
                {
                    auto opts = Text.Split(d.Options, "|");
                    float ow = vw / opts.Count;
                    r.RoundRect(vx, y + 1, vw, 34, 8, Theme.Base);
                    for (int o = 0; o < opts.Count; o++)
                    {
                        bool sel = val.ToLower() == opts[o].ToLower();
                        if (sel) r.RoundRect(vx + o * ow + 3, y + 4, ow - 6, 28, 6, Theme.Active);
                        Font of = r.UiSmall;
                        float tw = r.TextWidth(of, opts[o]);
                        r.Text(of, vx + o * ow + (ow - tw) / 2, y + 11, opts[o], sel ? Theme.White : Theme.TextTertiary);
                    }
                    delete opts;
                }
                else if (d.Type == 5)
                {
                    string a = has ? val : "Left,Top";
                    float ow = vw / 4;
                    for (int o = 0; o < 4; o++)
                    {
                        string flag = o == 0 ? "Left" : (o == 1 ? "Top" : (o == 2 ? "Right" : "Bottom"));
                        bool on = a.Contains(flag);
                        r.RoundRect(vx + o * ow + 2, y + 3, ow - 4, 30, 6, on ? Theme.Active : Theme.Base);
                        if (!on) r.RoundBorder(vx + o * ow + 2, y + 3, ow - 4, 30, 6, 1, Theme.Border);
                        // Flecha hacia el borde anclado
                        float cx = vx + o * ow + ow / 2, cy = y + 18;
                        Color ac = on ? Theme.White : Theme.TextTertiary;
                        if (o == 0 || o == 2) r.Rect(cx - 7, cy - 0.75f, 14, 1.5f, ac);
                        else r.Rect(cx - 0.75f, cy - 7, 1.5f, 14, ac);
                        if (o == 0) r.Rect(cx - 8, cy - 5, 1.5f, 10, ac);
                        if (o == 2) r.Rect(cx + 7, cy - 5, 1.5f, 10, ac);
                        if (o == 1) r.Rect(cx - 5, cy - 8, 10, 1.5f, ac);
                        if (o == 3) r.Rect(cx - 5, cy + 7, 10, 1.5f, ac);
                    }
                }
                y += RowHeight + 4;
            }
            delete defs;
            float total = y + propsScroll - Y;
            if (propsScroll > 0 && total < H) propsScroll = (float)Math.Max(0.0, (double)(propsScroll - (H - total)));
            r.PopClip();
            if (arrangeHover >= 0 && selected != root) DrawTip(r, L.T(ArrangeTip(arrangeHover)), px + 18 + arrangeHover * ArrangeButtonWidth, Y + ArrangeTop + 34);
        }

        void DrawTip(Renderer r, string tip, float x, float y)
        {
            float tw = r.TextWidth(r.UiSmall, tip) + 16;
            if (x + tw > X + W - 8) x = X + W - 8 - tw;
            r.Shadow(x, y, tw, 24, 6, 10, Color.Hex(0x000000, 0.5f));
            r.RoundRect(x, y, tw, 24, 6, Theme.Elevated);
            r.RoundBorder(x, y, tw, 24, 6, 1, Theme.BorderStrong);
            r.Text(r.UiSmall, x + 8, y + 5, tip, Theme.Text);
        }

        // Alinear en el contenedor (izq., centro, der., arriba, medio, abajo) y orden (frente, fondo).
        void DrawArrangeBar(Renderer r, float x, float y)
        {
            float bw = ArrangeButtonWidth;
            r.RoundRect(x, y, bw * 8, 30, 8, Theme.Base);
            r.Rect(x + bw * 6, y + 6, 1, 18, Theme.Border);
            for (int i = 0; i < 8; i++)
            {
                float bx = x + i * bw;
                bool hot = arrangeHover == i;
                if (hot) r.RoundRect(bx + 2, y + 2, bw - 4, 26, 6, Theme.Hover);
                Color c = hot ? Theme.White : Theme.TextSecondary;
                float cx = bx + bw / 2, cy = y + 15;
                if (i <= 2)
                {
                    // Barras horizontales alineadas a una guía vertical
                    float gx = i == 0 ? cx - 7 : (i == 1 ? cx : cx + 7);
                    r.Rect(gx - 0.75f, cy - 8, 1.5f, 16, c);
                    float a = i == 0 ? gx + 2 : (i == 1 ? cx - 6 : gx - 2 - 12);
                    float b = i == 0 ? gx + 2 : (i == 1 ? cx - 4 : gx - 2 - 8);
                    r.RoundRect(a, cy - 6, 12, 4, 1.5f, c);
                    r.RoundRect(b, cy + 2, 8, 4, 1.5f, c);
                }
                else if (i <= 5)
                {
                    float gy = i == 3 ? cy - 7 : (i == 4 ? cy : cy + 7);
                    r.Rect(cx - 8, gy - 0.75f, 16, 1.5f, c);
                    float a = i == 3 ? gy + 2 : (i == 4 ? cy - 6 : gy - 2 - 12);
                    float b = i == 3 ? gy + 2 : (i == 4 ? cy - 4 : gy - 2 - 8);
                    r.RoundRect(cx - 6, a, 4, 12, 1.5f, c);
                    r.RoundRect(cx + 2, b, 4, 8, 1.5f, c);
                }
                else
                {
                    // Dos cuadrados superpuestos; el relleno indica cuál queda delante
                    bool front = i == 6;
                    r.RoundBorder(cx - 7, cy - 7, 10, 10, 2, 1.3f, c);
                    if (front) r.RoundRect(cx - 3, cy - 3, 10, 10, 2, c);
                    else
                    {
                        r.RoundRect(cx - 3, cy - 3, 10, 10, 2, Theme.Base);
                        r.RoundBorder(cx - 3, cy - 3, 10, 10, 2, 1.3f, c);
                        r.RoundRect(cx - 7, cy - 7, 10, 10, 2, c);
                    }
                }
            }
        }
    }
}
