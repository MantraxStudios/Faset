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
        public var Kind: string;                       // copia propia
        public var Keys: List<string> = new List<string>();
        public var Values: List<string> = new List<string>();
        public var Children: List<UiNode> = new List<UiNode>();
        public var Parent: UiNode;
        // Rectángulo en pantalla del último dibujo (para el ratón).
        public var SX: float;
        public var SY: float;
        public var SW: float;
        public var SH: float;
        // TabControl: página que se ve en el diseñador (-1 = la de SelectedIndex). No se guarda.
        public var ShownPage: int = -1;

        public init(kind: string) { Kind = String.Copy(kind); }

        deinit
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

        public prop IsContainer: bool => Kind == "Window" || Kind == "Panel" || Kind == "TabPage";

        // Componentes no visuales (bandeja bajo la ventana). Para añadir otro, inclúyelo aquí.
        public static func IsComponentKind(k: string) -> bool => UiComponents.IsComponent(k);
        public prop IsComponent: bool => IsComponentKind(Kind);
        public prop IsMenuEntry: bool => Kind == "Menu" || Kind == "MenuItem" || Kind == "Separator";
        // Partes de otro control: su sitio lo decide el contenedor (no se mueven con el ratón).
        public prop IsPart: bool => Kind == "TabPage" || Kind == "TreeNode" || IsMenuEntry;
        public prop Movable: bool => !IsComponent && !IsPart && Kind != "Window" && Kind != "MenuBar";

        func IndexOfKey(key: string) -> int
        {
            for (int i = 0; i < Keys.Count; i++)
                if (Keys[i] == key) return i;
            return -1;
        }

        public func Has(key: string) -> bool => IndexOfKey(key) >= 0;

        // Valor del atributo (vista) o "" si no está.
        public func Get(key: string) -> string
        {
            int i = IndexOfKey(key);
            return i < 0 ? "" : Values[i];
        }

        public func Set(key: string, value: string)
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

        public func SetInt(key: string, v: int)
        {
            string s = Convert.ToString(v);
            Set(key, s);
            String.Free(s);
        }

        public func Remove(key: string)
        {
            int i = IndexOfKey(key);
            if (i < 0) return;
            String.Free(Keys[i]);
            String.Free(Values[i]);
            Keys.RemoveAt(i);
            Values.RemoveAt(i);
        }

        public func Int(key: string, def: int) -> int
        {
            long v = 0;
            string s = Get(key);
            if (s.Length == 0 || !Convert.TryToInt64(s, out v)) return def;
            return (int)v;
        }

        public func Num(key: string, def: float) -> float
        {
            double v = 0;
            string s = Get(key);
            if (s.Length == 0 || !Convert.TryToDouble(s, out v)) return def;
            return (float)v;
        }

        public func Bool(key: string, def: bool) -> bool
        {
            string s = Get(key);
            if (s.Length == 0) return def;
            return s.ToLower() == "true";
        }

        public func Clone() -> UiNode
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

        public func IsAncestorOf(n: UiNode) -> bool
        {
            for (UiNode p = n; p != null; p = p.Parent)
                if (p == this) return true;
            return false;
        }

        public func FindByName(name: string) -> UiNode
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
    public memory_unsafe static class UiXml
    {
        static func IsSpace(c: byte) -> bool => c == ' ' || c == '\t' || c == '\n' || c == '\r';
        static func IsNameChar(c: byte) -> bool => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == ':' || c == '.';

        // Analiza el documento; null y 'error' (copia) si no es válido.
        public static func Parse(s: string, out error: string) -> UiNode
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

        static func Fail(out error: string, message: string, root: UiNode) -> UiNode
        {
            error = String.Copy(message);
            if (root != null) delete root;
            return null;
        }

        static func Decode(v: string) -> string
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

        static func Escape(sb: StringBuilder, v: string)
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

        public static func Write(root: UiNode) -> string
        {
            StringBuilder sb = new StringBuilder();
            WriteNode(sb, root, 0);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        static func WriteNode(sb: StringBuilder, n: UiNode, depth: int)
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
        public var Key: string;
        public var Type: int;        // 0 texto, 1 entero, 2 número, 3 booleano, 4 opciones, 5 anclaje, 6 evento, 7 identificador
        public var Options: string;  // separadas por '|'
        public var Default: string;
        public var Section: string;
    }
    // Tipo 8: color "#RRGGBB" (muestra + código + paleta).

    struct PropRow
    {
        public var Key: string;
        public var Type: int;
        public var Y: float;
        public var VX: float;   // inicio del control
        public var VW: float;
        public var Options: string;
    }

    public partial class Designer
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

        public var Doc: Document;
        public var X: float;
        public var Y: float;
        public var W: float;
        public var H: float;

        var root: UiNode;
        var error: string = String.Copy("");
        var syncedVersion: int = -1;
        var selected: UiNode;
        var undo: List<string> = new List<string>();
        var redo: List<string> = new List<string>();

        // Arrastre: 0 nada, 1 mover, 2 redimensionar, 3 nuevo desde la caja de herramientas, 4 tamaño de la ventana
        var dragMode: int;
        var handle: int;
        var pressX: float;
        var pressY: float;
        var mouseX: float;
        var mouseY: float;
        var origX: int;
        var origY: int;
        var origW: int;
        var origH: int;
        var dragMoved: bool;
        var newKind: string = String.Copy("");
        var dropTarget: UiNode;
        var guidesX: List<float> = new List<float>();
        var guidesY: List<float> = new List<float>();

        var scrollX: float;
        var scrollY: float;
        // Arrastre con el botón central (rueda pulsada) para mover el lienzo.
        var panning: bool;
        // Zoom del lienzo (Ctrl+rueda) y cuadrícula (se recuerda entre sesiones).
        var zoom: float = 1;
        static var gridState: int = -1;   // -1: aún sin leer de los ajustes
        static prop showGrid: bool
        {
            get
            {
                if (gridState < 0) gridState = Settings.Get("designer.grid", "true") == "true" ? 1 : 0;
                return gridState == 1;
            }
            set { gridState = value ? 1 : 0; }
        }
        static var zoomSteps: string = "0.25|0.33|0.5|0.67|0.75|0.9|1|1.1|1.25|1.5|1.75|2|2.5|3|4";
        const float BarH = 30;           // barra de zoom y cuadrícula (abajo a la derecha del lienzo)
        var panX: float;
        var panY: float;
        var panScrollX: float;
        var panScrollY: float;
        var propsScroll: float;
        var originX: float;   // esquina del contenido de la ventana diseñada en pantalla
        var originY: float;

        var rows: List<PropRow> = new List<PropRow>();
        TextField field = new TextField();
        var editingKey: string = String.Copy("");
        var toolHover: int = -1;
        var leftTab: int;                  // 0 herramientas, 1 esquema
        var outlineScroll: float;
        var outline: List<UiNode> = new List<UiNode>();
        var outlineDepth: List<int> = new List<int>();
        var arrangeHover: int = -1;
        // Paleta de colores abierta para la propiedad 'colorKey' ("" = cerrada).
        var colorKey: string = String.Copy("");
        var colorPopX: float;
        var colorPopY: float;
        const float SwatchSize = 30;
        static var swatches: string = "#000000|#18181b|#27272a|#3f3f46|#71717a|#a1a1aa|#e4e4e7|#ffffff|" +
                                 "#ef4444|#f97316|#f59e0b|#eab308|#84cc16|#22c55e|#10b981|#14b8a6|" +
                                 "#06b6d4|#0ea5e9|#3b82f6|#6366f1|#8b5cf6|#a855f7|#d946ef|#ec4899|" +
                                 "#7f1d1d|#7c2d12|#78350f|#365314|#14532d|#134e4a|#1e3a8a|#4c1d95";

        // Portapapeles de controles (XML), compartido entre diseñadores.
        static var clipboard: string = "";
        static var clipboardOwned: bool;

        public var RequestHandler: string = String.Copy("");   // método que la aplicación debe abrir en el código (copia)
        public var Status: string = "";           // mensaje para la barra de estado (vista de literal)
        public var SwitchToCode: bool;            // pide pasar a la vista de código

        static var kinds: string = "Label|Button|TextBox|CheckBox|RadioButton|ComboBox|ListBox|Slider|ProgressBar|Panel|" +
                              "WebView|VideoPlayer|PictureBox|TabControl|TreeView|MenuBar|Canvas|Timer|ContextMenu|Sound|Music";
        const int KindCount = 21;
        var toolScroll: float;
        const float TrayH = 46;   // bandeja de componentes bajo la ventana
        public var RequestParams: string = "Widget sender";   // parámetros del manejador pedido

        public init(doc: Document) { Doc = doc; }

        deinit
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
            String.Free(colorKey);
            String.Free(RequestHandler);
        }

        static func FreeAll(l: List<string>)
        {
            for (int i = 0; i < l.Count; i++) String.Free(l[i]);
            l.Clear();
        }

        public prop Editing: bool => editingKey.Length > 0;
        public prop ClassName: string => root != null ? root.Get("Class") : "";
        public prop NamespaceName: string => root != null ? root.Get("Namespace") : "";
        public prop HasError: bool => root == null;

        // ------------------------------------------------------------------ sincronización

        // Vuelve a leer el XML si el texto cambió fuera del diseñador.
        public func Sync()
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
        func Commit(before: string)
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

        func WriteBuffer(xml: string)
        {
            TextBuffer b = Doc.Buffer;
            b.NewGroup();
            b.Delete(new TextPos(0, 0), b.End, new TextPos(0, 0));
            b.Insert(new TextPos(0, 0), xml, new TextPos(0, 0));
            b.NewGroup();
            syncedVersion = b.Version;
        }

        func Snapshot() -> string => UiXml.Write(root);

        func Restore(from: List<string>, to: List<string>)
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

        prop CanvasX: float => X + ToolboxWidth;
        prop CanvasW: float => W - ToolboxWidth - PropsWidth;
        prop PropsX: float => X + W - PropsWidth;

        const int TabHeader = 36;   // alto de las pestañas (igual que std.ui)

        func ContentX(n: UiNode) -> float
        {
            float x = originX;
            for (UiNode p = n; p != null && p != root; p = p.Parent) x += (p.Kind == "TabPage" ? 1 : p.Int("X", 0)) * zoom;
            return x;
        }

        func ContentY(n: UiNode) -> float
        {
            float y = originY;
            for (UiNode p = n; p != null && p != root; p = p.Parent) y += (p.Kind == "TabPage" ? TabHeader : p.Int("Y", 0)) * zoom;
            return y;
        }

        // Página de un TabControl que se ve en el diseñador.
        static func ShownIndex(tabs: UiNode) -> int
        {
            int n = tabs.Children.Count;
            int i = tabs.ShownPage >= 0 ? tabs.ShownPage : tabs.Int("SelectedIndex", 0);
            if (i >= n) i = n - 1;
            if (i < 0) i = 0;
            return i;
        }

        // Al elegir un control de una página oculta, esa página pasa a verse.
        static func RevealPages(n: UiNode)
        {
            for (UiNode p = n; p != null && p.Parent != null; p = p.Parent)
                if (p.Kind == "TabPage" && p.Parent.Kind == "TabControl") p.Parent.ShownPage = p.Parent.Children.IndexOf(p);
        }

        func Layout()
        {
            originX = CanvasX + Margin - scrollX;
            originY = Y + Margin + TitleBar * zoom - scrollY;
        }

        // Nodo más interno bajo el punto (sin contar la ventana).
        func HitTest(n: UiNode, px: float, py: float) -> UiNode
        {
            if (n == root)
            {
                UiNode pop = PopupHit(px, py);   // menús desplegados en el diseñador, encima de todo
                if (pop != null) return pop;
            }
            for (int i = n.Children.Count - 1; i >= 0; i--)
            {
                UiNode c = n.Children[i];
                if (c.IsMenuEntry && n.Kind != "MenuBar") continue;  // los elementos de un menú se ven en su lista
                if (px >= c.SX && py >= c.SY && px < c.SX + c.SW && py < c.SY + c.SH)
                {
                    // Los nodos de un árbol se eligen en el esquema; el árbol se mueve entero.
                    UiNode inner = c.Kind == "TreeView" ? null : HitTest(c, px, py);
                    return inner != null ? inner : c;
                }
            }
            return null;
        }

        // Panel (o la ventana) que recibiría un control soltado en el punto.
        func ContainerAt(px: float, py: float, exclude: UiNode) -> UiNode
        {
            UiNode best = root;
            FindContainer(root, px, py, exclude, ref best);
            return best;
        }

        func FindContainer(n: UiNode, px: float, py: float, exclude: UiNode, ref best: UiNode)
        {
            for (int i = 0; i < n.Children.Count; i++)
            {
                UiNode c = n.Children[i];
                if (c == exclude || (c.Kind != "Panel" && c.Kind != "TabPage" && c.Kind != "TabControl")) continue;
                if (px >= c.SX && py >= c.SY && px < c.SX + c.SW && py < c.SY + c.SH)
                {
                    if (c.Kind != "TabControl") best = c;   // en un TabControl, el destino es su página visible
                    FindContainer(c, px, py, exclude, ref best);
                }
            }
        }

        // Asa de redimensión bajo el punto (0..7 desde arriba-izquierda en sentido horario) o -1.
        func HandleAt(px: float, py: float) -> int
        {
            if (!Placeable || !selected.Movable) return -1;
            for (int i = 0; i < 8; i++)
            {
                float hx = 0, hy = 0;
                HandlePos(selected, i, out hx, out hy);
                if (Math.Abs(px - hx) <= 6 && Math.Abs(py - hy) <= 6) return i;
            }
            return -1;
        }

        static func HandlePos(n: UiNode, i: int, out hx: float, out hy: float)
        {
            float l = n.SX, t = n.SY, r = n.SX + n.SW, b = n.SY + n.SH;
            float cx = (l + r) / 2, cy = (t + b) / 2;
            hx = i == 0 || i == 6 || i == 7 ? l : (i == 1 || i == 5 ? cx : r);
            hy = i <= 2 ? t : (i == 3 || i == 7 ? cy : b);
        }

        func OverWindowCorner(px: float, py: float) -> bool
        {
            if (root == null) return false;
            float rx = originX + root.Int("Width", 800) * zoom, ry = originY + root.Int("Height", 600) * zoom;
            return px >= rx - 4 && px <= rx + 12 && py >= ry - 4 && py <= ry + 12;
        }

        // Cursor para la posición del ratón (CursorKind).
        public func CursorAt(px: float, py: float) -> CursorKind
        {
            if (root == null) return CursorKind.Arrow;
            if (dragMode == 1 || panning) return CursorKind.Arrow;
            if (px >= PropsX)
            {
                if (ArrangeAt(px, py) >= 0) return CursorKind.Hand;
                for (int i = 0; i < rows.Count; i++)
                    if (py >= rows[i].Y && py < rows[i].Y + RowHeight && px >= rows[i].VX)
                        return rows[i].Type <= 2 || rows[i].Type == 7 || (rows[i].Type == 8 && px >= rows[i].VX + 40) ? CursorKind.Text : CursorKind.Hand;
                return CursorKind.Arrow;
            }
            if (px < CanvasX) return ToolAt(px, py) >= 0 || OutlineAt(px, py) >= 0 || TabAt(px, py) >= 0 ? CursorKind.Hand : CursorKind.Arrow;
            int h = HandleAt(px, py);
            if (h == 3 || h == 7) return CursorKind.ResizeHorizontal;
            if (h == 1 || h == 5) return CursorKind.ResizeVertical;
            if (h >= 0 || OverWindowCorner(px, py)) return CursorKind.ResizeHorizontal;
            return CursorKind.Arrow;
        }

        func ToolAt(px: float, py: float) -> int
        {
            if (leftTab != 0 || px < X + 10 || px >= X + ToolboxWidth - 10) return -1;
            int i = (int)Math.Floor((py - (Y + 52) + toolScroll) / ToolRow);
            return py >= Y + 52 && i >= 0 && i < KindCount ? i : -1;
        }

        // Pestaña (0 herramientas, 1 esquema) bajo el punto, o -1.
        func TabAt(px: float, py: float) -> int
        {
            if (py < Y + 10 || py >= Y + 38 || px < X + 10 || px >= X + ToolboxWidth - 10) return -1;
            return px < X + ToolboxWidth / 2 ? 0 : 1;
        }

        // Fila del esquema bajo el punto, o -1.
        func OutlineAt(px: float, py: float) -> int
        {
            if (leftTab != 1 || px < X + 6 || px >= X + ToolboxWidth - 6 || py < Y + 52) return -1;
            int i = (int)Math.Floor((py - (Y + 52) + outlineScroll) / OutlineRow);
            return i >= 0 && i < outline.Count ? i : -1;
        }

        func BuildOutline(n: UiNode, depth: int)
        {
            outline.Add(n);
            outlineDepth.Add(depth);
            for (int i = 0; i < n.Children.Count; i++) BuildOutline(n.Children[i], depth + 1);
        }

        static func KindAt(i: int) -> string
        {
            var parts = Text.Split(kinds, "|");
            string k = parts[i];
            delete parts;
            return k;
        }

        // ------------------------------------------------------------------ edición

        static func Snap(v: int) -> int => showGrid ? (int)Math.Round(v / (double)Grid) * Grid : v;

        func Z(v: float) -> float => v * zoom;

        // Fuente de la vista previa a la escala del zoom.
        func ZFont(r: Renderer, size: int, bold: bool) -> Font => r.Sans((int)Math.Round(size * zoom), bold);

        // Cambia el zoom al paso siguiente (dir > 0) o anterior, manteniendo fijo el punto bajo el ratón.
        func ZoomStep(dir: int, px: float, py: float)
        {
            var steps = Text.Split(zoomSteps, "|");
            float next = zoom;
            if (dir > 0)
            {
                for (int i = 0; i < steps.Count; i++)
                {
                    double v = 0;
                    Convert.TryToDouble(steps[i], out v);
                    if (v > zoom + 0.001) { next = (float)v; break; }
                }
            }
            else
            {
                for (int i = steps.Count - 1; i >= 0; i--)
                {
                    double v = 0;
                    Convert.TryToDouble(steps[i], out v);
                    if (v < zoom - 0.001) { next = (float)v; break; }
                }
            }
            delete steps;
            SetZoom(next, px, py);
        }

        func SetZoom(next: float, px: float, py: float)
        {
            if (root == null || next == zoom) return;
            Layout();
            float dx = (px - originX) / zoom, dy = (py - originY) / zoom;
            zoom = next;
            // originX = CanvasX + Margin - scrollX; originY = Y + Margin + TitleBar*zoom - scrollY
            scrollX = CanvasX + Margin - (px - dx * zoom);
            scrollY = Y + Margin + TitleBar * zoom - (py - dy * zoom);
            ClampScroll();
            Layout();
        }

        func ToggleGrid()
        {
            showGrid = !showGrid;
            Settings.Set("designer.grid", showGrid ? "true" : "false");
        }

        // Barra del lienzo: 0 cuadrícula, 1 alejar, 2 porcentaje (100 %), 3 acercar; -1 fuera.
        prop BarX: float => CanvasX + CanvasW - 12 - 4 * 34;
        prop BarY: float => Y + H - 12 - BarH;

        func BarAt(px: float, py: float) -> int
        {
            if (py < BarY || py >= BarY + BarH || px < BarX || px >= BarX + 4 * 34) return -1;
            return (int)Math.Floor((px - BarX) / 34);
        }

        func BarClick(i: int)
        {
            float cx = CanvasX + CanvasW / 2, cy = Y + H / 2;
            if (i == 0) ToggleGrid();
            else if (i == 1) ZoomStep(-1, cx, cy);
            else if (i == 2) SetZoom(1, cx, cy);
            else if (i == 3) ZoomStep(1, cx, cy);
        }

        func DrawBar(r: Renderer)
        {
            float x = BarX, y = BarY;
            r.Shadow(x, y, 4 * 34, BarH, 8, 10, Color.Hex(0x000000, 0.4f));
            r.RoundRect(x, y, 4 * 34, BarH, 8, Theme.Elevated);
            r.RoundBorder(x, y, 4 * 34, BarH, 8, 1, Theme.BorderStrong);
            int hover = BarAt(mouseX, mouseY);
            for (int i = 0; i < 4; i++)
            {
                float bx = x + i * 34;
                if (i == hover) r.RoundRect(bx + 2, y + 2, 30, BarH - 4, 6, Theme.Hover);
                Color c = i == hover ? Theme.White : Theme.TextSecondary;
                float cx = bx + 17, cy = y + BarH / 2;
                if (i == 0)
                {
                    if (showGrid) r.RoundRect(bx + 4, y + 4, 26, BarH - 8, 5, Theme.Active);
                    Color gc = showGrid ? Theme.White : c;
                    for (int k = 0; k < 3; k++)
                    {
                        r.Rect(cx - 7 + k * 7, cy - 7, 1.2f, 14, gc);
                        r.Rect(cx - 7, cy - 7 + k * 7, 14, 1.2f, gc);
                    }
                }
                else if (i == 1) r.Rect(cx - 5, cy - 0.75f, 10, 1.5f, c);
                else if (i == 3)
                {
                    r.Rect(cx - 5, cy - 0.75f, 10, 1.5f, c);
                    r.Rect(cx - 0.75f, cy - 5, 1.5f, 10, c);
                }
                else
                {
                    string pct = Convert.ToString((int)Math.Round(zoom * 100));
                    string label = String.Concat(pct, "%");
                    r.Text(r.UiSmall, cx - r.TextWidth(r.UiSmall, label) / 2, cy - 8, label, c);
                    String.Free(label);
                    String.Free(pct);
                }
            }
            if (hover >= 0)
            {
                string tip = L.T(hover == 0 ? (showGrid ? "Hide grid (G)" : "Show grid (G)") : hover == 1 ? "Zoom out (Ctrl+wheel)"
                                 : hover == 2 ? "Reset zoom (Ctrl+0)" : "Zoom in (Ctrl+wheel)");
                float tw = r.TextWidth(r.UiSmall, tip) + 16;
                float tx = (float)Math.Min((double)(x + hover * 34), (double)(CanvasX + CanvasW - 8 - tw));
                r.RoundRect(tx, y - 30, tw, 24, 6, Theme.Elevated);
                r.RoundBorder(tx, y - 30, tw, 24, 6, 1, Theme.BorderStrong);
                r.Text(r.UiSmall, tx + 8, y - 25, tip, Theme.Text);
            }
        }

        func Select(n: UiNode)
        {
            if (selected != n) CommitEdit();
            selected = n;
            RevealPages(n);
        }

        func UniqueName(kind: string) -> string
        {
            if (kind == "Sound" || kind == "Music") return UniqueComponentName(kind);
            string prefix = kind == "Label" ? "label" : kind == "Button" ? "button" : kind == "TextBox" ? "textBox"
                          : kind == "CheckBox" ? "checkBox" : kind == "Slider" ? "slider" : kind == "ProgressBar" ? "progressBar"
                          : kind == "RadioButton" ? "radioButton" : kind == "ComboBox" ? "comboBox" : kind == "ListBox" ? "listBox"
                          : kind == "WebView" ? "webView" : kind == "VideoPlayer" ? "video" : kind == "PictureBox" ? "pictureBox" : kind == "TabControl" ? "tabControl" : kind == "TabPage" ? "tabPage"
                          : kind == "TreeView" ? "treeView" : kind == "TreeNode" ? "treeNode" : kind == "MenuBar" ? "menuBar"
                          : kind == "Menu" || kind == "MenuItem" ? "menuItem" : kind == "Separator" ? "separator"
                          : kind == "Canvas" ? "canvas" : kind == "Timer" ? "timer" : kind == "ContextMenu" ? "contextMenu" : "panel";
            for (int i = 1; ; i++)
            {
                string num = Convert.ToString(i);
                string name = String.Concat(prefix, num);
                String.Free(num);
                if (root.FindByName(name) == null) return name;
                String.Free(name);
            }
        }

        // Hijo sin nombre (página, nodo o elemento de menú) con un texto.
        static func Part(parent: UiNode, kind: string, text: string) -> UiNode
        {
            UiNode c = new UiNode(kind);
            if (text.Length > 0) c.Set("Text", text);
            c.Parent = parent;
            parent.Children.Add(c);
            return c;
        }

        func CreateNode(kind: string) -> UiNode
        {
            UiNode n = new UiNode(kind);
            if (kind == "TabPage" || kind == "TreeNode" || kind == "Menu" || kind == "MenuItem" || kind == "Separator")
                return n;   // partes: sin nombre ni posición
            string name = UniqueName(kind);
            n.Set("Name", name);
            String.Free(name);
            if (kind == "Timer")
            {
                n.Set("Interval", "1000");
                return n;
            }
            if (kind == "Sound" || kind == "Music")
            {
                n.Set("Source", GuessSource(kind == "Music"));
                if (kind == "Music") n.Set("Loop", "true");
                return n;
            }
            if (kind == "ContextMenu")
            {
                Part(n, "MenuItem", "Item 1");
                Part(n, "MenuItem", "Item 2");
                return n;
            }
            if (kind == "MenuBar")
            {
                // Sin Width: ocupa todo el ancho de la ventana (y lo sigue al redimensionarla).
                n.Set("Anchor", "Left,Top,Right");
                UiNode file = Part(n, "Menu", "File");
                Part(file, "MenuItem", "Open").Set("Shortcut", "Ctrl+O");
                Part(file, "MenuItem", "Save").Set("Shortcut", "Ctrl+S");
                Part(file, "Separator", "");
                Part(file, "MenuItem", "Exit");
                UiNode help = Part(n, "Menu", "Help");
                Part(help, "MenuItem", "About");
                return n;
            }
            n.Set("X", "0");
            n.Set("Y", "0");
            int w = 120, h = 24;
            if (kind == "PictureBox")
            {
                w = 200;
                h = 150;
                n.Set("SizeMode", "Zoom");
            }
            else if (kind == "TabControl")
            {
                w = 400;
                h = 260;
                Part(n, "TabPage", "Page 1");
                Part(n, "TabPage", "Page 2");
            }
            else if (kind == "TreeView")
            {
                w = 220;
                h = 260;
                UiNode a = Part(n, "TreeNode", "Node 1");
                a.Set("Expanded", "true");
                Part(a, "TreeNode", "Node 1.1");
                Part(a, "TreeNode", "Node 1.2");
                Part(n, "TreeNode", "Node 2");
            }
            else if (kind == "Canvas")
            {
                w = 320;
                h = 200;
            }
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
            else if (kind == "WebView")
            {
                w = 360;
                h = 240;
                n.Set("Source", "https://");
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
            else if (kind == "VideoPlayer")
            {
                w = 320;
                h = 180;
                n.Set("Source", "");
                n.Set("ShowControls", "true");
            }
            n.SetInt("Width", w);
            n.SetInt("Height", h);
            return n;
        }

        func AddNode(kind: string, parent: UiNode, x: int, y: int)
        {
            string before = Snapshot();
            UiNode n = CreateNode(kind);
            if (n.IsComponent || kind == "MenuBar")
            {
                parent = root;   // los componentes y la barra de menús van directamente en la ventana
                if (kind == "MenuBar") root.Children.Insert(0, n);
                else root.Children.Add(n);
            }
            else
            {
                n.SetInt("X", x);
                n.SetInt("Y", y);
                parent.Children.Add(n);
            }
            n.Parent = parent;
            selected = n;
            Commit(before);
        }

        // Acciones de los botones "Añadir..." del panel de propiedades.
        func RunAction(action: string)
        {
            if (selected == null) return;
            UiNode target = selected;
            string before = Snapshot();
            UiNode made = null;
            if (action == "Add page")
            {
                if (target.Kind == "TabPage") target = target.Parent;
                string num = Convert.ToString(target.Children.Count + 1);
                made = Part(target, "TabPage", "Page " + num);
                target.ShownPage = target.Children.Count - 1;
            }
            else if (action == "Add node") made = Part(target, "TreeNode", "Node");
            else if (action == "Add menu") made = Part(target, "Menu", "Menu");
            else if (action == "Add item") made = Part(target, "MenuItem", "Item");
            else if (action == "Add separator") made = Part(target, "Separator", "");
            else if (action == "Add submenu")
            {
                made = Part(target, "Menu", "Submenu");
                Part(made, "MenuItem", "Item");
            }
            if (made == null)
            {
                String.Free(before);
                return;
            }
            if (target.Kind == "TreeNode") target.Set("Expanded", "true");
            selected = made;
            Commit(before);
        }

        // Partes (páginas, nodos, elementos de menú): Ctrl+↑/↓ las cambia de orden.
        func MoveSibling(dir: int)
        {
            if (selected == null || selected.Parent == null) return;
            List<UiNode> list = selected.Parent.Children;
            int i = list.IndexOf(selected), j = i + dir;
            if (j < 0 || j >= list.Count) return;
            string before = Snapshot();
            list.RemoveAt(i);
            list.Insert(j, selected);
            if (selected.Kind == "TabPage") selected.Parent.ShownPage = j;
            Commit(before);
        }

        func DeleteSelected()
        {
            if (selected == null || selected == root) return;
            string before = Snapshot();
            UiNode p = selected.Parent;
            p.Children.Remove(selected);
            delete selected;
            selected = p;
            Commit(before);
        }

        func DuplicateSelected()
        {
            if (selected == null || selected == root) return;
            string before = Snapshot();
            UiNode c = selected.Clone();
            RenameTree(c);
            c.Parent = selected.Parent;
            if (selected.Movable)
            {
                c.SetInt("X", selected.Int("X", 0) + 16);
                c.SetInt("Y", selected.Int("Y", 0) + 16);
                selected.Parent.Children.Add(c);
            }
            else selected.Parent.Children.Insert(selected.Parent.Children.IndexOf(selected) + 1, c);
            selected = c;
            Commit(before);
        }

        func RenameTree(n: UiNode)
        {
            if (n.Has("Name"))
            {
                string name = UniqueName(n.Kind);
                n.Set("Name", name);
                String.Free(name);
            }
            for (int i = 0; i < n.Children.Count; i++) RenameTree(n.Children[i]);
        }

        func Nudge(dx: int, dy: int)
        {
            if (!Placeable || !selected.Movable) return;
            string before = Snapshot();
            selected.SetInt("X", selected.Int("X", 0) + dx);
            selected.SetInt("Y", selected.Int("Y", 0) + dy);
            Commit(before);
        }

        func CopySelected()
        {
            if (selected == null || selected == root) return;
            if (clipboardOwned) String.Free(clipboard);
            clipboard = UiXml.Write(selected);
            clipboardOwned = true;
            Status = "Copied";
        }

        // Pega dentro del panel seleccionado o junto al control seleccionado.
        func Paste()
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
            UiNode parent = DropParent(n);
            if (parent == null)
            {
                delete n;
                return;
            }
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
            StripGeometry(n);
            n.Parent = parent;
            parent.Children.Add(n);
            selected = n;
            Commit(before);
        }

        func RenameConflicts(n: UiNode)
        {
            if (n.Has("Name") && root.FindByName(n.Get("Name")) != null)
            {
                string name = UniqueName(n.Kind);
                n.Set("Name", name);
                String.Free(name);
            }
            for (int i = 0; i < n.Children.Count; i++) RenameConflicts(n.Children[i]);
        }

        // Dónde va un control pegado: en el contenedor elegido, junto al control elegido o en la ventana.
        // Las partes solo se pegan en un padre de su tipo (una página en un TabControl...).
        func DropParent(n: UiNode) -> UiNode
        {
            UiNode s = selected != null ? selected : root;
            if (n.IsComponent || n.Kind == "MenuBar") return root;
            if (n.Kind == "TabPage") return s.Kind == "TabControl" ? s : (s.Kind == "TabPage" ? s.Parent : null);
            if (n.Kind == "TreeNode") return s.Kind == "TreeView" || s.Kind == "TreeNode" ? s : null;
            if (n.IsMenuEntry)
                return s.Kind == "MenuBar" || s.Kind == "Menu" || s.Kind == "ContextMenu" ? s : (s.IsMenuEntry ? s.Parent : null);
            if (s.Kind == "Panel" || s.Kind == "TabPage") return s;
            if (s.Kind == "TabControl" && s.Children.Count > 0) return s.Children[ShownIndex(s)];
            UiNode p = s == root ? root : s.Parent;
            while (p != null && !p.IsContainer) p = p.Parent;
            return p != null ? p : root;
        }

        // 0..5: alinear a la izquierda, centro, derecha, arriba, medio, abajo del contenedor;
        // 6: traer al frente; 7: enviar al fondo.
        func Arrange(what: int)
        {
            if (!Placeable || !selected.Movable) return;
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

        static func ArrangeTip(i: int) -> string =>
            i == 0 ? "Align left" : i == 1 ? "Center horizontally" : i == 2 ? "Align right" : i == 3 ? "Align top"
            : i == 4 ? "Center vertically" : i == 5 ? "Align bottom" : i == 6 ? "Bring to front" : "Send to back";

        prop ArrangeButtonWidth: float => (PropsWidth - 36) / 8;

        func ArrangeAt(px: float, py: float) -> int
        {
            if (!Placeable || !selected.Movable) return -1;
            float ty = Y + ArrangeTop;
            if (py < ty || py >= ty + 30 || px < PropsX + 18) return -1;
            int i = (int)Math.Floor((px - (PropsX + 18)) / ArrangeButtonWidth);
            return i >= 0 && i < 8 ? i : -1;
        }

        // Selecciona el siguiente (o anterior) control en el orden del esquema.
        func SelectNext(back: bool)
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
        func HandlerName(n: UiNode, ev: string) -> string
        {
            string name = n.Get("Name");
            if (name.Length == 0) name = Identifier(n.Get("Text"));   // elementos de menú sin nombre: por su texto
            string bare = name;
            string pre = "btn|txt|lbl|chk|sld|prg|pnl|rad|rdo|cmb|cbo|lst|pic|img|tab|tv|tree|mnu|menu|tmr|cnv|ctx|" +
                         "button|textBox|label|checkBox|slider|progressBar|panel|radioButton|comboBox|listBox|pictureBox|tabControl|" +
                         "treeView|menuItem|menuBar|canvas|timer|contextMenu";
            var parts = Text.Split(pre, "|");
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

        // Letras y dígitos ASCII de un texto ("Guardar como..." -> "GuardarComo").
        static func Identifier(text: string) -> string
        {
            StringBuilder sb = new StringBuilder();
            bool upper = true;
            for (int i = 0; i < text.Length; i++)
            {
                byte c = text[i];
                // Vocales con tilde y eñe (UTF-8 C3 xx) -> letra sin tilde
                if (c == 0xC3 && i + 1 < text.Length)
                {
                    byte d = text[i + 1];
                    byte m = d == 0xA1 ? (byte)'a' : d == 0xA9 ? (byte)'e' : d == 0xAD ? (byte)'i' : d == 0xB3 ? (byte)'o' : d == 0xBA || d == 0xBC ? (byte)'u'
                           : d == 0xB1 ? (byte)'n' : d == 0x81 ? (byte)'A' : d == 0x89 ? (byte)'E' : d == 0x8D ? (byte)'I' : d == 0x93 ? (byte)'O'
                           : d == 0x9A ? (byte)'U' : d == 0x91 ? (byte)'N' : (byte)0;
                    if (m != 0)
                    {
                        c = m;
                        i++;
                    }
                }
                bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9' && sb.Length > 0);
                if (!ok)
                {
                    upper = true;
                    continue;
                }
                if (upper && c >= 'a' && c <= 'z') c = (byte)(c - 32);
                sb.Append((char)c);
                upper = false;
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Parámetros del manejador de cada evento.
        static func EventParams(ev: string) -> string =>
            ev == "MessageReceived" ? "Widget sender, string message" : ev == "Paint" ? "Widget sender, Graphics g" : (ev == "MouseDown" || ev == "MouseMove" || ev == "MouseUp" ? "Widget sender, MouseArgs e" : "Widget sender");

        // Pide abrir (o crear) el manejador del evento principal del control.
        func OpenEvent(n: UiNode, ev: string)
        {
            if (n == null || n == root || ev.Length == 0) return;
            RequestParams = EventParams(ev);
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

        static func MainEvent(kind: string) -> string =>
            kind == "WebView" ? "Navigated" : kind == "VideoPlayer" ? "Ended"
            : kind == "Sound" || kind == "Music" ? ""
            : kind == "TextBox" || kind == "Slider" || kind == "ComboBox" || kind == "ListBox" || kind == "RadioButton" ? "Changed"
            : kind == "TabControl" || kind == "TreeView" ? "SelectedChanged" : kind == "Timer" ? "Tick" : kind == "Canvas" ? "Paint"
            : kind == "TabPage" || kind == "TreeNode" || kind == "MenuBar" || kind == "ContextMenu" || kind == "Separator" ? "" : "Click";

        // ------------------------------------------------------------------ propiedades

        func Def(l: List<PropDef>, key: string, type: int, options: string, def: string, section: string)
        {
            PropDef d = new PropDef();
            d.Key = key;
            d.Type = type;
            d.Options = options;
            d.Default = def;
            d.Section = section;
            l.Add(d);
        }

        func PropsFor(n: UiNode) -> List<PropDef>
        {
            var l = new List<PropDef>();
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
                Def(l, "Background", 8, "", "", "Colors");
                Def(l, "Background2", 8, "", "", "Colors");
                Def(l, "GradientDirection", 4, "Vertical|Horizontal", "Vertical", "Colors");
                return l;
            }
            if (k == "Sound" || k == "Music") return ComponentProps(l, k);
            if (n.IsComponent || n.IsPart || k == "MenuBar")
            {
                PartProps(l, n);
                return l;
            }
            Def(l, "Name", 7, "", "", "Control");
            if (k == "VideoPlayer") return VideoProps(l);
            if (k == "Label" || k == "Button" || k == "CheckBox" || k == "TextBox" || k == "RadioButton") Def(l, "Text", 0, "", "", "Control");
            if (k == "PictureBox")
            {
                Def(l, "Source", 0, "", "", "Control");
                Def(l, "SizeMode", 4, "Normal|Stretch|Zoom|Center|Cover", "Normal", "Control");
            }
            if (k == "Button") Def(l, "Icon", 0, "", "", "Control");
            if (k == "TabControl")
            {
                Def(l, "SelectedIndex", 1, "", "0", "Control");
                Def(l, "Add page", 9, "Add page", "", "Control");
            }
            if (k == "TreeView") Def(l, "Add node", 9, "Add node", "", "Control");
            if (k == "TextBox" || k == "ComboBox") Def(l, "Placeholder", 0, "", "", "Control");
            if (k == "WebView")
            {
                Def(l, "Source", 0, "", "", "Control");
                Def(l, "Html", 0, "", "", "Control");
            }
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
            if (k == "Label" || k == "Button" || k == "CheckBox" || k == "TextBox" || k == "RadioButton" || k == "ComboBox" || k == "ListBox" ||
                k == "TabControl" || k == "TreeView")
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
            if (k == "Button" || k == "Panel" || k == "TextBox" || k == "ProgressBar" || k == "ComboBox" || k == "ListBox" || k == "PictureBox" || k == "WebView" ||
                k == "TabControl" || k == "TreeView" || k == "Canvas")
                Def(l, "CornerRadius", 1, "", "", "Appearance");
            if (k == "CheckBox" || k == "RadioButton") Def(l, "Checked", 3, "", "false", "Behavior");
            if (k == "RadioButton") Def(l, "Group", 0, "", "", "Behavior");
            if (k == "Slider" || k == "ProgressBar")
            {
                Def(l, "Value", 2, "", k == "Slider" ? "50" : "0", "Behavior");
                Def(l, "Min", 2, "", "0", "Behavior");
                Def(l, "Max", 2, "", "100", "Behavior");
            }
            bool box = k == "Panel" || k == "Button" || k == "TextBox" || k == "ComboBox" || k == "ListBox" || k == "Label" ||
                       k == "PictureBox" || k == "TabControl" || k == "TreeView" || k == "Canvas";
            if (box || k == "Slider" || k == "ProgressBar") Def(l, "Background", 8, "", "", "Colors");
            if (box)
            {
                Def(l, "Background2", 8, "", "", "Colors");
                Def(l, "GradientDirection", 4, "Vertical|Horizontal", "Vertical", "Colors");
            }
            if (k != "Panel" && k != "Slider" && k != "ProgressBar" && k != "PictureBox" && k != "Canvas") Def(l, "Foreground", 8, "", "", "Colors");
            if (box) Def(l, "BorderColor", 8, "", "", "Colors");
            if (k == "CheckBox" || k == "RadioButton" || k == "Slider" || k == "ProgressBar" || k == "TabControl") Def(l, "Accent", 8, "", "", "Colors");
            if (k != "PictureBox" && k != "WebView") Def(l, "Enabled", 3, "", "true", "Behavior");
            Def(l, "Visible", 3, "", "true", "Behavior");
            ContextMenuProp(l);
            if (k == "WebView")
            {
                Def(l, "Navigated", 6, "", "", "Events");
                Def(l, "TitleChanged", 6, "", "", "Events");
                Def(l, "MessageReceived", 6, "", "", "Events");
            }
            if (k == "Button" || k == "CheckBox" || k == "TextBox" || k == "RadioButton" || k == "PictureBox") Def(l, "Click", 6, "", "", "Events");
            if (k == "TextBox" || k == "CheckBox" || k == "Slider" || k == "RadioButton" || k == "ComboBox" || k == "ListBox")
                Def(l, "Changed", 6, "", "", "Events");
            if (k == "TabControl" || k == "TreeView") Def(l, "SelectedChanged", 6, "", "", "Events");
            if (k == "TreeView") Def(l, "NodeActivated", 6, "", "", "Events");
            if (k == "Canvas")
            {
                Def(l, "Paint", 6, "", "", "Events");
                Def(l, "MouseDown", 6, "", "", "Events");
                Def(l, "MouseMove", 6, "", "", "Events");
                Def(l, "MouseUp", 6, "", "", "Events");
            }
            return l;
        }

        // VideoPlayer: vídeo, disposición, colores y eventos propios (Opened, Ended, Failed).
        func VideoProps(l: List<PropDef>) -> List<PropDef>
        {
            Def(l, "Source", 0, "", "", "Video");
            Def(l, "AutoPlay", 3, "", "false", "Video");
            Def(l, "Loop", 3, "", "false", "Video");
            Def(l, "ShowControls", 3, "", "true", "Video");
            Def(l, "Volume", 2, "", "1", "Video");
            Def(l, "Stretch", 4, "Uniform|Fill|None", "Uniform", "Video");
            Def(l, "X", 1, "", "0", "Layout");
            Def(l, "Y", 1, "", "0", "Layout");
            Def(l, "Width", 1, "", "320", "Layout");
            Def(l, "Height", 1, "", "180", "Layout");
            Def(l, "Anchor", 5, "", "Left,Top", "Layout");
            Def(l, "Background", 8, "", "", "Colors");
            Def(l, "BorderColor", 8, "", "", "Colors");
            Def(l, "Accent", 8, "", "", "Colors");
            Def(l, "Visible", 3, "", "true", "Behavior");
            Def(l, "Opened", 6, "", "", "Events");
            Def(l, "Ended", 6, "", "", "Events");
            Def(l, "Failed", 6, "", "", "Events");
            return l;
        }

        // Propiedades de los componentes, de la barra de menús y de las partes (páginas, nodos, menús).
        func PartProps(l: List<PropDef>, n: UiNode)
        {
            string k = n.Kind;
            if (k != "Separator") Def(l, "Name", 7, "", "", "Control");
            if (k == "Timer")
            {
                Def(l, "Interval", 1, "", "100", "Behavior");
                Def(l, "Enabled", 3, "", "false", "Behavior");
                Def(l, "Tick", 6, "", "", "Events");
                return;
            }
            if (k == "ContextMenu" || k == "MenuBar")
            {
                Def(l, k == "MenuBar" ? "Add menu" : "Add item", 9, k == "MenuBar" ? "Add menu" : "Add item|Add separator|Add submenu", "", "Control");
                Def(l, "FontSize", 1, "", "14", "Appearance");
                if (k == "MenuBar")
                {
                    Def(l, "Height", 1, "", "30", "Layout");
                    Def(l, "Background", 8, "", "", "Colors");
                    Def(l, "Foreground", 8, "", "", "Colors");
                    Def(l, "BorderColor", 8, "", "", "Colors");
                    Def(l, "Visible", 3, "", "true", "Behavior");
                }
                return;
            }
            if (k == "Separator")
            {
                Def(l, "Visible", 3, "", "true", "Behavior");
                return;
            }
            Def(l, "Text", 0, "", "", "Control");
            if (k == "TabPage")
            {
                Def(l, "Add page", 9, "Add page", "", "Control");
                Def(l, "Background", 8, "", "", "Colors");
                Def(l, "Background2", 8, "", "", "Colors");
                Def(l, "GradientDirection", 4, "Vertical|Horizontal", "Vertical", "Colors");
                Def(l, "Enabled", 3, "", "true", "Behavior");
                return;
            }
            if (k == "TreeNode")
            {
                Def(l, "Tag", 0, "", "", "Control");
                Def(l, "Expanded", 3, "", "false", "Control");
                Def(l, "Add node", 9, "Add node", "", "Control");
                return;
            }
            // Menu / MenuItem
            Def(l, "Shortcut", 0, "", "", "Control");
            Def(l, "Icon", 0, "", "", "Control");
            Def(l, "Add item", 9, "Add item|Add separator|Add submenu", "", "Control");
            Def(l, "Checked", 3, "", "false", "Behavior");
            Def(l, "Enabled", 3, "", "true", "Behavior");
            Def(l, "Visible", 3, "", "true", "Behavior");
            Def(l, "Click", 6, "", "", "Events");
        }

        // ContextMenu de un control: opciones con los <ContextMenu> de la ventana.
        func ContextMenuProp(l: List<PropDef>)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("(none)");
            int count = 0;
            for (int i = 0; i < root.Children.Count; i++)
            {
                UiNode c = root.Children[i];
                if (c.Kind == "ContextMenu" && c.Get("Name").Length > 0)
                {
                    sb.Append("|").Append(c.Get("Name"));
                    count++;
                }
            }
            string opts = sb.ToString();
            delete sb;
            if (count > 0 && count <= 3) Def(l, "ContextMenu", 4, opts, "(none)", "Behavior");
            else if (count > 3) Def(l, "ContextMenu", 7, "", "", "Behavior");
        }

        func FindDef(key: string) -> PropDef
        {
            PropDef found = new PropDef();
            var defs = PropsFor(selected);
            for (int i = 0; i < defs.Count; i++)
                if (defs[i].Key == key) found = defs[i];
            delete defs;
            return found;
        }

        func BeginEdit(row: PropRow)
        {
            CommitEdit();
            String.Free(editingKey);
            editingKey = String.Copy(row.Key);
            field.Set(selected.Get(row.Key));
            field.Focused = true;
        }

        func CancelEdit()
        {
            String.Free(editingKey);
            editingKey = String.Copy("");
            field.Focused = false;
        }

        static func IsIdentifier(s: string) -> bool
        {
            if (s.Length == 0 || !(Char.IsLetter((char)s[0]) || s[0] == '_')) return false;
            for (int i = 0; i < s.Length; i++)
                if (!(Char.IsLetterOrDigit((char)s[i]) || s[i] == '_')) return false;
            return true;
        }

        // Aplica el valor del campo en edición.
        func CommitEdit()
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
            Color parsed = new Color(0, 0, 0, 0);
            if (d.Type == 8 && v.Length > 0 && !ParseColor(v, out parsed)) ok = false;
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

        func SetProp(key: string, value: string)
        {
            string before = Snapshot();
            if (value == "(none)") selected.Remove(key);
            else selected.Set(key, value);
            Commit(before);
        }

        // "#RGB", "#RRGGBB" o "#RRGGBBAA".
        public static func ParseColor(s: string, out c: Color) -> bool
        {
            c = new Color(0, 0, 0, 0);
            if (s.Length < 4 || s[0] != '#') return false;
            int digits = s.Length - 1;
            if (digits != 3 && digits != 6 && digits != 8) return false;
            uint v = 0;
            for (int i = 1; i < s.Length; i++)
            {
                byte ch = s[i];
                uint d = ch >= '0' && ch <= '9' ? (uint)(ch - '0') : (ch >= 'a' && ch <= 'f' ? (uint)(ch - 'a' + 10) : (ch >= 'A' && ch <= 'F' ? (uint)(ch - 'A' + 10) : 99));
                if (d == 99) return false;
                v = (v << 4) | d;
            }
            if (digits == 3) v = ((v >> 8) * 0x110000) | (((v >> 4) & 15) * 0x1100) | ((v & 15) * 0x11);
            float a = 1;
            if (digits == 8)
            {
                a = (v & 0xff) / 255.0f;
                v = v >> 8;
            }
            c = Color.Hex(v, a);
            return true;
        }

        // Color de una propiedad del nodo, o 'def' si no tiene.
        static func NodeColor(n: UiNode, key: string, def: Color) -> Color
        {
            Color c = def;
            if (n.Has(key) && !ParseColor(n.Get(key), out c)) c = def;
            return c;
        }

        // Fondo propio del nodo (sólido o degradado); false si usa el del tema.
        func FillNodeBackground(r: Renderer, n: UiNode, x: float, y: float, w: float, h: float, rad: float) -> bool
        {
            Color a = new Color(0, 0, 0, 0);
            if (!n.Has("Background") || !ParseColor(n.Get("Background"), out a)) return false;
            Color b = a;
            if (n.Has("Background2") && ParseColor(n.Get("Background2"), out b))
                r.GradientRoundRect(x, y, w, h, rad, a, b, n.Get("GradientDirection") == "Horizontal");
            else r.RoundRect(x, y, w, h, rad, a);
            return true;
        }

        func OpenColorPopup(row: PropRow)
        {
            String.Free(colorKey);
            colorKey = String.Copy(row.Key);
            float pw = 8 * (SwatchSize + 4) + 12, ph = 4 * (SwatchSize + 4) + 54;
            colorPopX = PropsX + PropsWidth - 16 - pw;
            colorPopY = row.Y + RowHeight + 2;
            if (colorPopY + ph > Y + H - 8) colorPopY = row.Y - ph - 2;
        }

        func CloseColorPopup()
        {
            String.Free(colorKey);
            colorKey = String.Copy("");
        }

        // Clic dentro de la paleta: true si la usó.
        func ColorPopupMouse(px: float, py: float) -> bool
        {
            float pw = 8 * (SwatchSize + 4) + 12, ph = 4 * (SwatchSize + 4) + 54;
            if (px < colorPopX || py < colorPopY || px >= colorPopX + pw || py >= colorPopY + ph) return false;
            string key = String.Copy(colorKey);
            // Fila "Ninguno" (color del tema)
            if (py >= colorPopY + ph - 40)
            {
                string before = Snapshot();
                selected.Remove(key);
                Commit(before);
                CloseColorPopup();
                String.Free(key);
                return true;
            }
            int col = (int)Math.Floor((px - colorPopX - 6) / (SwatchSize + 4));
            int rowI = (int)Math.Floor((py - colorPopY - 8) / (SwatchSize + 4));
            if (col >= 0 && col < 8 && rowI >= 0 && rowI < 4)
            {
                var parts = Text.Split(swatches, "|");
                SetProp(key, parts[rowI * 8 + col]);
                delete parts;
                CloseColorPopup();
            }
            String.Free(key);
            return true;
        }

        func DrawColorPopup(r: Renderer)
        {
            float pw = 8 * (SwatchSize + 4) + 12, ph = 4 * (SwatchSize + 4) + 54;
            float x = colorPopX, y = colorPopY;
            r.Shadow(x, y, pw, ph, 10, 18, Color.Hex(0x000000, 0.6f));
            r.RoundRect(x, y, pw, ph, 10, Theme.Elevated);
            r.RoundBorder(x, y, pw, ph, 10, 1, Theme.BorderStrong);
            var parts = Text.Split(swatches, "|");
            string cur = selected.Get(colorKey).ToLower();
            for (int i = 0; i < parts.Count; i++)
            {
                float sx = x + 6 + (i % 8) * (SwatchSize + 4), sy = y + 8 + (i / 8) * (SwatchSize + 4);
                Color c = new Color(0, 0, 0, 0);
                ParseColor(parts[i], out c);
                bool hot = mouseX >= sx && mouseY >= sy && mouseX < sx + SwatchSize && mouseY < sy + SwatchSize;
                r.RoundRect(sx, sy, SwatchSize, SwatchSize, 7, c);
                r.RoundBorder(sx, sy, SwatchSize, SwatchSize, 7, 1, Color.Hex(0xffffff, 0.12f));
                if (hot || cur == parts[i]) r.RoundBorder(sx - 2, sy - 2, SwatchSize + 4, SwatchSize + 4, 9, 2, Theme.White);
            }
            delete parts;
            float ny = y + ph - 40;
            bool noneHot = mouseX >= x && mouseX < x + pw && mouseY >= ny && mouseY < y + ph;
            r.Rect(x + 8, ny, pw - 16, 1, Theme.Border);
            if (noneHot) r.RoundRect(x + 6, ny + 5, pw - 12, 30, 7, Theme.Hover);
            DrawNoneSwatch(r, x + 12, ny + 11, 18);
            r.Text(r.Ui, x + 40, ny + 10, L.T("Theme default (no color)"), Theme.Text);
        }

        // Muestra vacía: cuadro con una diagonal.
        static func DrawNoneSwatch(r: Renderer, x: float, y: float, s: float)
        {
            r.RoundBorder(x, y, s, s, 4, 1.2f, Theme.TextTertiary);
            for (int i = 2; i < (int)s - 2; i++) r.Rect(x + s - 1 - i, y + i, 1.5f, 1.5f, Theme.Error);
        }

        func ToggleAnchor(flag: string)
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

        public func MouseDown(px: float, py: float, clicks: int, shift: bool, ctrl: bool)
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
            CloseColorPopup();
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
            int bar = BarAt(px, py);
            if (bar >= 0)
            {
                BarClick(bar);
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
            bool inWindow = px >= originX && py >= originY - TitleBar * zoom && px < originX + rw * zoom && py < originY + rh * zoom;
            if (hit == null)
            {
                Select(inWindow ? root : null);
                return;
            }
            // Pestañas de un TabControl: un clic cambia la página visible; '+' añade otra.
            if (hit.Kind == "TabControl" && py < hit.SY + TabHeader * zoom)
            {
                int tab = TabHeaderAt(hit, px);
                if (tab == -2)
                {
                    Select(hit);
                    RunAction("Add page");
                    return;
                }
                if (tab >= 0) hit.ShownPage = tab;
            }
            Select(hit);
            if (clicks >= 2)
            {
                OpenEvent(hit, MainEvent(hit.Kind));
                return;
            }
            if (!hit.Movable) return;   // componentes y partes: solo se eligen
            dragMode = 1;
            SaveOrig(hit);
            String.Free(undoBefore);
            undoBefore = Snapshot();
        }

        var undoBefore: string = String.Copy("");

        func SaveOrig(n: UiNode)
        {
            origX = n.Int("X", 0);
            origY = n.Int("Y", 0);
            origW = n.Int("Width", 100);
            origH = n.Int("Height", 32);
        }

        public func MouseMove(px: float, py: float, down: bool, ctrl: bool)
        {
            mouseX = px;
            mouseY = py;
            if (panning)
            {
                scrollX = panScrollX - (px - panX);
                scrollY = panScrollY - (py - panY);
                ClampScroll();
                return;
            }
            if (!down || dragMode == 0)
            {
                toolHover = px < CanvasX ? ToolAt(px, py) : -1;
                arrangeHover = ArrangeAt(px, py);
                return;
            }
            if (!dragMoved && Math.Abs(px - pressX) + Math.Abs(py - pressY) < 3) return;
            float dx = (px - pressX) / zoom, dy = (py - pressY) / zoom;   // en unidades de diseño
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
        func SnapAxis(n: UiNode, pos: int, size: int, horizontal: bool) -> int
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
                    if (o == n || UiComponents.IsComponent(o.Kind)) continue;
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
                            guide = origin + theirs * zoom;
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

        func SnapEdge(n: UiNode, edge: int, horizontal: bool) -> int
        {
            UiNode parent = n.Parent;
            int best = 7, result = Snap(edge);
            float guide = -1;
            float origin = horizontal ? ContentX(parent) : ContentY(parent);
            for (int i = 0; i < parent.Children.Count; i++)
            {
                UiNode o = parent.Children[i];
                if (o == n || UiComponents.IsComponent(o.Kind)) continue;
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
                        guide = origin + theirs * zoom;
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

        public func MouseUp(px: float, py: float)
        {
            if (panning)
            {
                panning = false;
                return;
            }
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
                    // Clic: añadir dentro del contenedor seleccionado (panel o página) o de la ventana, en cascada.
                    UiNode parent = root;
                    if (selected != null && (selected.Kind == "Panel" || selected.Kind == "TabPage")) parent = selected;
                    else if (selected != null && selected.Kind == "TabControl" && selected.Children.Count > 0)
                        parent = selected.Children[ShownIndex(selected)];
                    int offset = (parent.Children.Count % 8) * 16;
                    AddNode(newKind, parent, 24 + offset, 24 + offset);
                    return;
                }
                if (target == null) return;
                UiNode tmp = CreateNode(newKind);
                int x = Snap((int)((px - ContentX(target)) / zoom) - tmp.Int("Width", 100) / 2);
                int y = Snap((int)((py - ContentY(target)) / zoom) - tmp.Int("Height", 32) / 2);
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
                    float ax = ContentX(selected.Parent) + selected.Int("X", 0) * zoom;
                    float ay = ContentY(selected.Parent) + selected.Int("Y", 0) * zoom;
                    selected.Parent.Children.Remove(selected);
                    selected.Parent = target;
                    target.Children.Add(selected);
                    selected.SetInt("X", Snap((int)((ax - ContentX(target)) / zoom)));
                    selected.SetInt("Y", Snap((int)((ay - ContentY(target)) / zoom)));
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

        public func Scroll(px: float, py: float, lines: int, shift: bool, ctrl: bool)
        {
            if (ctrl && px >= CanvasX && px < PropsX)
            {
                ZoomStep(lines < 0 ? 1 : -1, px, py);
                return;
            }
            if (px < CanvasX)
            {
                if (leftTab == 1) outlineScroll = (float)Math.Max(0.0, (double)(outlineScroll + lines * 24));
                else toolScroll = (float)Math.Max(0.0, Math.Min((double)(toolScroll + lines * 24), (double)(KindCount * ToolRow - (H - 60))));
                return;
            }
            if (px >= PropsX)
            {
                propsScroll = (float)Math.Max(0.0, (double)(propsScroll + lines * 24));
                return;
            }
            if (shift) scrollX += lines * 40;
            else scrollY += lines * 40;
            ClampScroll();
        }

        // Botón central pulsado sobre el lienzo: empieza a mover la vista.
        public func PanStart(px: float, py: float)
        {
            if (root == null || px < CanvasX || px >= PropsX) return;
            panning = true;
            panX = px;
            panY = py;
            panScrollX = scrollX;
            panScrollY = scrollY;
        }

        public prop Panning: bool => panning;

        // La ventana diseñada puede moverse hasta media vista más allá de cada borde, sin perderse.
        func ClampScroll()
        {
            if (root == null) return;
            float cw = CanvasW, ch = H;
            float contentW = (root.Int("Width", 800) + Margin * 2) * zoom, contentH = (root.Int("Height", 600) + TitleBar + Margin * 2) * zoom + TrayH + 16;
            float minX = -cw / 2, maxX = (float)Math.Max(0.0, (double)(contentW - cw)) + cw / 2;
            float minY = -ch / 2, maxY = (float)Math.Max(0.0, (double)(contentH - ch)) + ch / 2;
            scrollX = (float)Math.Clamp((double)scrollX, (double)minX, (double)maxX);
            scrollY = (float)Math.Clamp((double)scrollY, (double)minY, (double)maxY);
        }

        func PropsMouse(px: float, py: float)
        {
            if (selected == null) return;
            if (colorKey.Length > 0)
            {
                bool used = ColorPopupMouse(px, py);
                CloseColorPopup();
                if (used) return;
            }
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
                if (px < row.VX && row.Type != 9)
                {
                    CommitEdit();
                    return;
                }
                if (row.Type <= 2 || row.Type == 7)
                {
                    if (editingKey != row.Key) BeginEdit(row);
                    return;
                }
                if (row.Type == 8)
                {
                    // La muestra abre la paleta; el código se edita como texto.
                    if (px < row.VX + 40)
                    {
                        CommitEdit();
                        OpenColorPopup(row);
                    }
                    else if (editingKey != row.Key) BeginEdit(row);
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
                    var opts = Text.Split(row.Options, "|");
                    int idx = (int)Math.Floor((px - row.VX) / (row.VW / opts.Count));
                    if (idx >= 0 && idx < opts.Count) SetProp(row.Key, opts[idx]);
                    delete opts;
                }
                else if (row.Type == 9)
                {
                    var opts = Text.Split(row.Options, "|");
                    int idx = (int)Math.Floor((px - (row.VX - 94)) / ((row.VW + 94) / opts.Count));
                    if (idx >= 0 && idx < opts.Count) RunAction(opts[idx]);
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
        public func Key(e: Event) -> bool
        {
            if (root == null) return false;
            uint k = e.Key;
            if (colorKey.Length > 0 && k == Keys.Escape)
            {
                CloseColorPopup();
                return true;
            }
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
                if (selected != null && selected.IsPart) MoveSibling(k == Keys.Up ? -1 : 1);
                else Arrange(k == Keys.Up ? 6 : 7);
                return true;
            }
            if (k == Keys.Tab)
            {
                SelectNext(e.Shift);
                return true;
            }
            float zx = CanvasX + CanvasW / 2, zy = Y + H / 2;
            if (e.Ctrl && k == '0')
            {
                SetZoom(1, zx, zy);
                return true;
            }
            if (e.Ctrl && (k == '+' || k == '=' || k == 0xffab))
            {
                ZoomStep(1, zx, zy);
                return true;
            }
            if (e.Ctrl && (k == '-' || k == 0xffad))
            {
                ZoomStep(-1, zx, zy);
                return true;
            }
            if (!e.Ctrl && (k == 'g' || k == 'G'))
            {
                ToggleGrid();
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
        func Pal(which: int) -> Color
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

        static prop Accent: Color => Color.Hex(0x4c8dff);

        public func Draw(r: Renderer)
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
            if (showGrid) DrawDots(r);
            DrawWindow(r);
            DrawBar(r);
            r.PopClip();
            DrawToolbox(r);
            DrawProps(r);
            if (dragMode == 3 && dragMoved) DrawGhost(r);
            r.PopClip();
        }

        func DrawError(r: Renderer)
        {
            r.Rect(X, Y, W, H, Theme.Base);
            float cx = X + W / 2;
            string title = L.T("This interface cannot be shown in the designer");
            r.Text(r.UiBold, cx - r.TextWidth(r.UiBold, title) / 2, Y + H / 2 - 40, title, Theme.Text);
            r.Text(r.Ui, cx - r.TextWidth(r.Ui, error) / 2, Y + H / 2 - 14, error, Theme.Error);
            string hint = L.T("Click to open the XML code");
            r.Text(r.Ui, cx - r.TextWidth(r.Ui, hint) / 2, Y + H / 2 + 12, hint, Theme.TextTertiary);
        }

        func DrawDots(r: Renderer)
        {
            Color dot = Color.Hex(0xffffff, 0.05f);
            float step = 16;
            float sx = CanvasX + step - (scrollX - (float)Math.Floor(scrollX / step) * step);
            float sy = Y + step - (scrollY - (float)Math.Floor(scrollY / step) * step);
            for (float y = sy; y < Y + H; y += step)
                for (float x = sx; x < CanvasX + CanvasW; x += step) r.Rect(x, y, 1.5f, 1.5f, dot);
        }

        func DrawWindow(r: Renderer)
        {
            float w = root.Int("Width", 800) * zoom, h = root.Int("Height", 600) * zoom;
            float tb = TitleBar * zoom;
            float fx = originX, fy = originY - tb;
            bool light = root.Get("Theme").ToLower() == "light";
            r.Shadow(fx, fy, w, h + tb, Z(12), 28, Color.Hex(0x000000, 0.6f));
            r.RoundRect(fx - 1, fy - 1, w + 2, h + tb + 2, Z(10) + 1, Color.Hex(0x3a3a40));
            r.RoundRect(fx, fy, w, h + tb, Z(10), light ? Color.Hex(0xe9e9ec) : Color.Hex(0x1c1c20));
            string title = root.Has("Title") ? root.Get("Title") : root.Get("Class");
            Font tf = ZFont(r, 13, true);
            r.Text(tf, fx + (w - r.TextWidth(tf, title)) / 2, fy + (tb - (tf.Ascent + tf.Descent)) / 2 - 1, title, light ? Color.Hex(0x2a2a2e) : Theme.TextSecondary);
            for (int i = 0; i < 3; i++)
                r.RoundRect(fx + w - Z(22 + i * 20), fy + Z(12), Z(10), Z(10), Z(5), light ? Color.Hex(0xc8c8cc) : Color.Hex(0x3a3a40));
            r.PushClip(fx, originY, w, h);
            r.Rect(fx, originY, w, h, Pal(0));
            FillNodeBackground(r, root, fx, originY, w, h, 0);
            // Cuadrícula fina dentro de la ventana (si está activada y no queda demasiado densa)
            float gstep = Grid * 2 * zoom;
            if (showGrid && gstep >= 6)
            {
                Color line = Color.Hex(light ? (uint)0x000000 : (uint)0xffffff, 0.035f);
                for (float gx = gstep; gx < w; gx += gstep) r.Rect(fx + gx, originY, 1, h, line);
                for (float gy = gstep; gy < h; gy += gstep) r.Rect(fx, originY + gy, w, 1, line);
            }
            tabNodes.Clear();
            tabIndex.Clear();
            tabX.Clear();
            tabW.Clear();
            root.SX = fx;
            root.SY = originY;
            root.SW = w;
            root.SH = h;
            for (int i = 0; i < root.Children.Count; i++) DrawNode(r, root.Children[i], originX, originY);
            DrawMenuPreview(r);
            r.PopClip();
            DrawTray(r, fx, originY + h + 14, w);
            // Guías inteligentes
            for (int i = 0; i < guidesX.Count; i++) r.Rect(guidesX[i], originY, 1, h, Color.Hex(0xff5fa2));
            for (int i = 0; i < guidesY.Count; i++) r.Rect(fx, guidesY[i], w, 1, Color.Hex(0xff5fa2));
            // Contenedor de destino al arrastrar
            if (dropTarget != null && dragMoved && (dragMode == 3 || (dragMode == 1 && dropTarget != selected.Parent)))
                r.RoundBorder(dropTarget.SX - 2, dropTarget.SY - 2, dropTarget.SW + 4, dropTarget.SH + 4, 8, 2, Accent);
            // Selección
            if (selected != null && selected != root && !selected.Movable)
            {
                // Componentes y partes: solo un marco (no se mueven ni cambian de tamaño).
                if (selected.SW > 0) r.RoundBorder(selected.SX - 2, selected.SY - 2, selected.SW + 4, selected.SH + 4, 6, 1.5f, Accent);
            }
            else if (selected != null && selected != root)
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
                r.RoundBorder(fx - 3, fy - 3, w + 6, h + tb + 6, Z(10) + 2, 1.5f, Accent);
            // Asa de tamaño de la ventana
            float cx = originX + w, cy = originY + h;
            r.RoundRect(cx - 2, cy - 2, 10, 10, 3, OverWindowCorner(mouseX, mouseY) || dragMode == 4 ? Accent : Color.Hex(0x5a5a62));
            if (dragMode == 4)
            {
                string info = Pair(root.Int("Width", 800), " × ", root.Int("Height", 600));
                r.RoundRect(cx + 12, cy + 8, r.TextWidth(r.UiSmall, info) + 14, 20, 6, Accent);
                r.Text(r.UiSmall, cx + 19, cy + 11, info, Color.Hex(0xffffff));
                String.Free(info);
            }
        }

        static func Pair(a: int, sep: string, b: int) -> string
        {
            string sa = Convert.ToString(a), sb = Convert.ToString(b);
            string r = String.Concat(sa, sep, sb);
            String.Free(sa);
            String.Free(sb);
            return r;
        }

        // Elemento i de una lista "a;b;c" (copia; "" si no existe).
        static func ItemAt(list: string, i: int) -> string
        {
            if (i < 0 || list.Length == 0) return String.Copy("");
            var parts = Text.Split(list, ";");
            string r = i < parts.Count ? String.Copy(parts[i].Trim()) : String.Copy("");
            delete parts;
            return r;
        }

        func CenteredText(r: Renderer, f: Font, s: string, x: float, y: float, w: float, h: float, align: int, c: Color)
        {
            float tw = r.TextWidth(f, s);
            float tx = align == 1 ? x + (w - tw) / 2 : (align == 2 ? x + w - tw : x);
            r.Text(f, tx, y + (h - (f.Ascent + f.Descent)) / 2 - 1, s, c);
        }

        func DrawNode(r: Renderer, n: UiNode, ox: float, oy: float)
        {
            if (n.IsComponent) return;   // se dibujan en la bandeja (DrawTray)
            float x = ox + n.Int("X", 0) * zoom, y = oy + n.Int("Y", 0) * zoom;
            float w = n.Int("Width", 100) * zoom, h = n.Int("Height", 32) * zoom;
            if (n.Kind == "MenuBar")
            {
                w = n.Int("Width", root.Int("Width", 800)) * zoom;
                h = n.Int("Height", 30) * zoom;
            }
            n.SX = x;
            n.SY = y;
            n.SW = w;
            n.SH = h;
            bool visible = n.Bool("Visible", true);
            bool enabled = n.Bool("Enabled", true);
            string k = n.Kind;
            string style = n.Get("Style");
            int fs = n.Int("FontSize", 14);
            Font f = ZFont(r, fs, n.Bool("Bold", false) || (k == "Button" && style == "Primary"));
            string text = n.Get("Text");
            Color fg = NodeColor(n, "Foreground", enabled ? Pal(5) : Pal(6));
            Color accent = NodeColor(n, "Accent", Pal(7));
            Color border2 = NodeColor(n, "BorderColor", Pal(2));
            float box = Z(18);
            if (!visible)
            {
                r.RoundBorder(x, y, w, h, 4, 1, Color.Hex(0x808080, 0.5f));
                CenteredText(r, r.UiSmall, n.Get("Name"), x, y, w, h, 1, Pal(6));
                return;
            }
            if (k == "VideoPlayer")
            {
                DrawVideoNode(r, n, x, y, w, h);
                return;
            }
            if (k == "PictureBox" || k == "TabControl" || k == "TreeView" || k == "MenuBar" || k == "Canvas")
            {
                DrawNewKind(r, n, x, y, w, h, f, fg, accent, border2);
                return;
            }
            if (k == "Panel")
            {
                float rad = Z(n.Int("CornerRadius", 10));
                bool custom = FillNodeBackground(r, n, x, y, w, h, rad);
                if (!custom && style != "Subtle") r.RoundRect(x, y, w, h, rad, Pal(1));
                if (n.Has("BorderColor") || (!custom && style != "Subtle")) r.RoundBorder(x, y, w, h, rad, 1, border2);
                else if (!custom) r.RoundBorder(x, y, w, h, rad, 1, Color.Hex(0x808080, 0.35f));
                r.PushClip(x, y, w, h);
                for (int i = 0; i < n.Children.Count; i++) DrawNode(r, n.Children[i], x, y);
                r.PopClip();
            }
            else if (k == "Label")
            {
                float rad = Z(n.Int("CornerRadius", 0));
                FillNodeBackground(r, n, x, y, w, h, rad);
                if (n.Has("BorderColor")) r.RoundBorder(x, y, w, h, rad, 1, border2);
                Color c = n.Has("Foreground") ? fg : (style == "Subtle" ? Pal(6) : (style == "Danger" ? Pal(9) : fg));
                string al = n.Get("TextAlign");
                CenteredText(r, f, text, x, y, w, h, al == "Center" ? 1 : (al == "Right" ? 2 : 0), c);
            }
            else if (k == "Button")
            {
                float rad = Z(n.Int("CornerRadius", 8));
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
                if (n.Has("Foreground")) tc = fg;
                bool custom = FillNodeBackground(r, n, x, y, w, h, rad);
                if (!custom && style != "Subtle") r.RoundRect(x, y, w, h, rad, bg);
                if (n.Has("BorderColor") || (border && !custom)) r.RoundBorder(x, y, w, h, rad, 1, border2);
                std.ui.Image icon = n.Has("Icon") ? Preview(n.Get("Icon")) : null;
                if (icon == null) CenteredText(r, f, text, x, y, w, h, 1, tc);
                else
                {
                    // Icono y texto centrados juntos (como Button.Icon en std.ui)
                    float ih = (float)Math.Min((double)icon.Height, (double)(n.Int("Height", 32) - 12)) * zoom;
                    float iw = icon.Width * ih / icon.Height;
                    float tw = text.Length > 0 ? r.TextWidth(f, text) : 0;
                    float gap = text.Length > 0 ? Z(8) : 0;
                    float left = x + (w - iw - gap - tw) / 2;
                    DrawPreviewImage(r, icon, 0, 0, icon.Width, icon.Height, left, y + (h - ih) / 2, iw, ih);
                    if (text.Length > 0) CenteredText(r, f, text, left + iw + gap, y, tw + 2, h, 0, tc);
                }
            }
            else if (k == "TextBox")
            {
                float rad = Z(n.Int("CornerRadius", 8));
                if (!FillNodeBackground(r, n, x, y, w, h, rad)) r.RoundRect(x, y, w, h, rad, Pal(4));
                r.RoundBorder(x, y, w, h, rad, 1, border2);
                r.PushClip(x + Z(10), y, w - Z(20), h);
                if (text.Length > 0) CenteredText(r, f, text, x + Z(10), y, w - Z(20), h, 0, fg);
                else CenteredText(r, f, n.Get("Placeholder"), x + Z(10), y, w - Z(20), h, 0, Pal(6));
                r.PopClip();
            }
            else if (k == "CheckBox")
            {
                float by = y + (h - box) / 2;
                if (n.Bool("Checked", false))
                {
                    r.RoundRect(x, by, box, box, Z(5), accent);
                    // Marca de verificación con trazos cortos (escala con el zoom)
                    float t = Z(1.8f);
                    for (int i = 0; i <= 3; i++) r.Rect(x + Z(4 + i), by + Z(8.5f + i), t, t, Pal(8));
                    for (int i = 0; i <= 6; i++) r.Rect(x + Z(7 + i), by + Z(11.5f - i * 1.1f), t, t, Pal(8));
                }
                else
                {
                    r.RoundRect(x, by, box, box, Z(5), Pal(4));
                    r.RoundBorder(x, by, box, box, Z(5), 1.2f, Pal(3));
                }
                CenteredText(r, f, text, x + Z(28), y, w - Z(28), h, 0, fg);
            }
            else if (k == "RadioButton")
            {
                float cy = y + h / 2;
                if (n.Bool("Checked", false))
                {
                    r.RoundRect(x, cy - box / 2, box, box, box / 2, accent);
                    r.RoundRect(x + Z(5.5f), cy - Z(3.5f), Z(7), Z(7), Z(3.5f), Pal(8));
                }
                else
                {
                    r.RoundRect(x, cy - box / 2, box, box, box / 2, Pal(4));
                    r.RoundBorder(x, cy - box / 2, box, box, box / 2, 1.2f, Pal(3));
                }
                CenteredText(r, f, text, x + Z(28), y, w - Z(28), h, 0, fg);
            }
            else if (k == "ComboBox")
            {
                float rad = Z(n.Int("CornerRadius", 8));
                if (!FillNodeBackground(r, n, x, y, w, h, rad)) r.RoundRect(x, y, w, h, rad, Pal(1));
                r.RoundBorder(x, y, w, h, rad, 1, border2);
                string item = ItemAt(n.Get("Items"), n.Int("SelectedIndex", -1));
                r.PushClip(x + Z(10), y, w - Z(44), h);
                if (item.Length > 0) CenteredText(r, f, item, x + Z(12), y, w - Z(44), h, 0, fg);
                else CenteredText(r, f, n.Get("Placeholder"), x + Z(12), y, w - Z(44), h, 0, Pal(6));
                r.PopClip();
                String.Free(item);
                // Flecha hacia abajo con dos trazos escalonados
                float ax = x + w - Z(18), ay = y + h / 2 - Z(2);
                for (int i = 0; i < 5; i++)
                {
                    r.Rect(ax - Z(4.5f) + Z(i), ay + Z(i), Z(1.6f), Z(1.6f), Pal(6));
                    r.Rect(ax + Z(4.5f) - Z(i) - Z(1.6f), ay + Z(i), Z(1.6f), Z(1.6f), Pal(6));
                }
            }
            else if (k == "ListBox")
            {
                float rad = Z(n.Int("CornerRadius", 8));
                if (!FillNodeBackground(r, n, x, y, w, h, rad)) r.RoundRect(x, y, w, h, rad, Pal(4));
                r.RoundBorder(x, y, w, h, rad, 1, border2);
                var items = Text.Split(n.Get("Items"), ";");
                int sel = n.Int("SelectedIndex", -1);
                float rh = ((float)Math.Ceiling(r.Sans(fs, false).Ascent + r.Sans(fs, false).Descent) + 14) * zoom;
                r.PushClip(x + 1, y + 1, w - 2, h - 2);
                for (int i = 0; i < items.Count && Z(4) + i * rh < h; i++)
                {
                    float ry = y + Z(4) + i * rh;
                    if (i == sel)
                    {
                        Color hl = Pal(5);
                        hl.A = 0.16f;
                        r.RoundRect(x + Z(4), ry, w - Z(8), rh, Z(6), hl);
                    }
                    CenteredText(r, f, items[i].Trim(), x + Z(14), ry, w - Z(28), rh, 0, fg);
                }
                r.PopClip();
                delete items;
            }
            else if (k == "WebView") DrawWebViewNode(r, n, x, y, w, h, border2);
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
                    float pos = x + Z(8) + (w - Z(16)) * t;
                    r.RoundRect(x, cy - Z(2), w, Z(4), Z(2), NodeColor(n, "Background", Pal(10)));
                    r.RoundRect(x, cy - Z(2), pos - x, Z(4), Z(2), accent);
                    r.RoundRect(pos - Z(8), cy - Z(8), Z(16), Z(16), Z(8), accent);
                    r.RoundRect(pos - Z(3), cy - Z(3), Z(6), Z(6), Z(3), Pal(0));
                }
                else
                {
                    float rad = n.Has("CornerRadius") ? Z(n.Int("CornerRadius", 0)) : h / 2;
                    r.RoundRect(x, y, w, h, rad, NodeColor(n, "Background", Pal(10)));
                    if (t > 0) r.RoundRect(x, y, w * t > h ? w * t : h, h, rad, accent);
                }
            }
        }

        // VideoPlayer en el diseñador: fondo oscuro, fotograma de película con "reproducir",
        // el nombre del archivo y una barra de controles de muestra (si ShowControls).
        func DrawVideoNode(r: Renderer, n: UiNode, x: float, y: float, w: float, h: float)
        {
            r.Rect(x, y, w, h, NodeColor(n, "Background", Color.Hex(0x000000)));
            if (n.Has("BorderColor")) r.RoundBorder(x, y, w, h, 0, 1, NodeColor(n, "BorderColor", Pal(2)));
            else r.RoundBorder(x, y, w, h, 0, 1, Color.Hex(0x808080, 0.35f));
            Color fg = Color.Hex(0xffffff, 0.55f);
            bool small = h < Z(90);
            float iw = small ? Z(30) : Z(44), ih = small ? Z(22) : Z(32);
            float cx = x + w / 2, cy = small ? y + h / 2 : y + h / 2 - Z(10);
            r.PushClip(x, y, w, h);
            r.RoundBorder(cx - iw / 2, cy - ih / 2, iw, ih, Z(4), 1.6f, fg);
            for (int k = 0; k < 4; k++)
            {
                float hx = cx - iw / 2 + Z(5) + k * (iw - Z(12)) / 3;
                r.RoundRect(hx, cy - ih / 2 + Z(3), Z(3), Z(3), Z(1), fg);
                r.RoundRect(hx, cy + ih / 2 - Z(6), Z(3), Z(3), Z(1), fg);
            }
            PlayGlyph(r, cx + Z(1), cy, ih * 0.22f, fg);
            if (!small)
            {
                string src = n.Get("Source");
                string label = src.Length > 0 ? Path.GetFileName(src) : "VideoPlayer";
                CenteredText(r, r.UiSmall, label, x + Z(4), cy + ih / 2 + Z(6), w - Z(8), Z(20), 1, Color.Hex(0xffffff, 0.7f));
            }
            if (n.Bool("ShowControls", true) && h >= Z(70))
            {
                float by = y + h - Z(22);
                Color accent = NodeColor(n, "Accent", Color.Hex(0xffffff));
                r.Rect(x, y + h - Z(44), w, Z(44), Color.Hex(0x000000, 0.35f));
                PlayGlyph(r, x + Z(25), by, Z(7), Color.Hex(0xffffff));
                float left = x + Z(48), right = x + w - Z(92);
                if (right > left)
                {
                    r.RoundRect(left, by - Z(2), right - left, Z(4), Z(2), Color.Hex(0xffffff, 0.28f));
                    r.RoundRect(left - Z(6), by - Z(6), Z(12), Z(12), Z(6), accent);
                }
                r.Text(r.UiSmall, x + w - Z(80), by - Z(8), "0:00 / 0:00", Color.Hex(0xffffff));
            }
            r.PopClip();
        }

        // Triángulo de "reproducir" con columnas de 1 px (el renderer no tiene polígonos).
        static func PlayGlyph(r: Renderer, cx: float, cy: float, s: float, c: Color)
        {
            float left = cx - s * 0.75f, len = s * 1.75f;
            for (float dx = 0; dx < len; dx += 1)
            {
                float half = s * (1 - dx / len);
                r.Rect(left + dx, cy - half, 1, half * 2, c);
            }
        }

        // ------------------------------------------------------------------ controles nuevos: vista previa

        static var previews: Dictionary<string, std.ui.Image> = new Dictionary<string, std.ui.Image>();
        // Pestañas dibujadas en el último fotograma (para el ratón): nodo, índice (-2 = '+'), x y ancho.
        var tabNodes: List<UiNode> = new List<UiNode>();
        var tabIndex: List<int> = new List<int>();
        var tabX: List<float> = new List<float>();
        var tabW: List<float> = new List<float>();
        // Elementos de los menús desplegados en el diseñador (para el ratón).
        var popupItems: List<UiNode> = new List<UiNode>();

        // Imagen de Source/Icon, relativa a la carpeta del .fstui o a una superior (la del proyecto).
        func Preview(rel: string) -> std.ui.Image
        {
            if (rel.Length == 0) return null;
            string dir = Path.GetDirectoryName(Doc.FullPath);
            for (int up = 0; up < 4 && dir.Length > 0; up++)
            {
                string full = Path.Combine(dir, rel);
                std.ui.Image img = null;
                if (previews.TryGetValue(full, out img))
                {
                    if (img != null) return img;
                }
                else if (File.Exists(full))
                {
                    img = std.ui.Image.Load(full);
                    previews.Set(String.Copy(full), img);
                    if (img != null) return img;
                }
                dir = Path.GetDirectoryName(dir);
            }
            return null;
        }

        // Dibuja la región (sx, sy, sw, sh) de la imagen en un rectángulo de la pantalla como una rejilla
        // de celdas de color (el renderizador solo tiene una textura de imagen: la del dispositivo Android).
        func DrawPreviewImage(r: Renderer, img: std.ui.Image, sx: float, sy: float, sw: float, sh: float, dx: float, dy: float, dw: float, dh: float)
        {
            if (img == null || dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return;
            int cols = (int)Math.Clamp((double)(dw / 3), 1.0, 110.0), rows = (int)Math.Clamp((double)(dh / 3), 1.0, 110.0);
            float cw = dw / cols, ch = dh / rows;
            for (int j = 0; j < rows; j++)
                for (int i = 0; i < cols; i++)
                {
                    uint a = 0, cr = 0, cg = 0, cb = 0;
                    for (int k = 0; k < 4; k++)
                    {
                        float u = sx + (i + 0.25f + (k % 2) * 0.5f) / cols * sw;
                        float v = sy + (j + 0.25f + (k / 2) * 0.5f) / rows * sh;
                        uint p = img.GetPixel((int)u, (int)v);
                        uint pa = p >> 24;
                        a += pa;
                        cr += ((p >> 16) & 255) * pa;
                        cg += ((p >> 8) & 255) * pa;
                        cb += (p & 255) * pa;
                    }
                    if (a == 0) continue;
                    uint rgb = ((cr / a) << 16) | ((cg / a) << 8) | (cb / a);
                    r.Rect(dx + i * cw, dy + j * ch, cw, ch, Color.Hex(rgb, a / 1020.0f));
                }
        }

        // Imagen de un PictureBox según su SizeMode (como Widget.DrawPictureBox de std.ui).
        func DrawPicture(r: Renderer, img: std.ui.Image, mode: string, x: float, y: float, w: float, h: float)
        {
            float iw = img.Width, ih = img.Height;
            if (mode == "Stretch") DrawPreviewImage(r, img, 0, 0, iw, ih, x, y, w, h);
            else if (mode == "Zoom")
            {
                float k = (float)Math.Min((double)(w / iw), (double)(h / ih));
                DrawPreviewImage(r, img, 0, 0, iw, ih, x + (w - iw * k) / 2, y + (h - ih * k) / 2, iw * k, ih * k);
            }
            else if (mode == "Cover")
            {
                float k = (float)Math.Max((double)(w / iw), (double)(h / ih));
                float sw = w / k, sh = h / k;
                DrawPreviewImage(r, img, (iw - sw) / 2, (ih - sh) / 2, sw, sh, x, y, w, h);
            }
            else
            {
                // Normal / Center: tamaño natural (con el zoom del diseñador); solo la parte visible.
                float ox = mode == "Center" ? x + (w - iw * zoom) / 2 : x, oy = mode == "Center" ? y + (h - ih * zoom) / 2 : y;
                float vx0 = (float)Math.Max(0.0, (double)((x - ox) / zoom)), vy0 = (float)Math.Max(0.0, (double)((y - oy) / zoom));
                float vx1 = (float)Math.Min((double)iw, (double)((x + w - ox) / zoom)), vy1 = (float)Math.Min((double)ih, (double)((y + h - oy) / zoom));
                if (vx1 > vx0 && vy1 > vy0)
                    DrawPreviewImage(r, img, vx0, vy0, vx1 - vx0, vy1 - vy0, ox + vx0 * zoom, oy + vy0 * zoom, (vx1 - vx0) * zoom, (vy1 - vy0) * zoom);
            }
        }

        // Pestaña de un TabControl bajo el punto (último fotograma): índice, -2 para '+', -1 nada.
        func TabHeaderAt(tabs: UiNode, px: float) -> int
        {
            for (int i = 0; i < tabNodes.Count; i++)
                if (tabNodes[i] == tabs && px >= tabX[i] && px < tabX[i] + tabW[i]) return tabIndex[i];
            return -1;
        }

        func DrawNewKind(r: Renderer, n: UiNode, x: float, y: float, w: float, h: float, f: Font, fg: Color, accent: Color, border2: Color)
        {
            string k = n.Kind;
            if (k == "PictureBox")
            {
                float rad = Z(n.Int("CornerRadius", 0));
                FillNodeBackground(r, n, x, y, w, h, rad);
                std.ui.Image img = Preview(n.Get("Source"));
                r.PushClip(x, y, w, h);
                if (img != null) DrawPicture(r, img, n.Get("SizeMode"), x, y, w, h);
                else
                {
                    // Sin imagen: marco discontinuo con el nombre del archivo (o del control).
                    Color dim = Color.Hex(0x808080, 0.45f);
                    for (float d = 0; d < w; d += Z(10)) r.Rect(x + d, y, Z(5), 1, dim);
                    for (float d = 0; d < w; d += Z(10)) r.Rect(x + d, y + h - 1, Z(5), 1, dim);
                    for (float d = 0; d < h; d += Z(10)) r.Rect(x, y + d, 1, Z(5), dim);
                    for (float d = 0; d < h; d += Z(10)) r.Rect(x + w - 1, y + d, 1, Z(5), dim);
                    string label = n.Has("Source") ? n.Get("Source") : n.Get("Name");
                    CenteredText(r, r.UiSmall, label, x, y, w, h, 1, Pal(6));
                }
                r.PopClip();
                if (n.Has("BorderColor")) r.RoundBorder(x, y, w, h, rad, 1, border2);
            }
            else if (k == "Canvas")
            {
                float rad = Z(n.Int("CornerRadius", 0));
                if (!FillNodeBackground(r, n, x, y, w, h, rad)) r.RoundRect(x, y, w, h, rad, Pal(4));
                r.RoundBorder(x, y, w, h, rad, 1, n.Has("BorderColor") ? border2 : Color.Hex(0x808080, 0.35f));
                // Ejes de ejemplo y el nombre del manejador Paint.
                Color dim = Color.Hex(0x808080, 0.25f);
                for (float gx = Z(24); gx < w; gx += Z(24)) r.Rect(x + gx, y + 1, 1, h - 2, dim);
                for (float gy = Z(24); gy < h; gy += Z(24)) r.Rect(x + 1, y + gy, w - 2, 1, dim);
                string label = n.Has("Paint") ? String.Concat("Canvas · Paint = ", n.Get("Paint")) : String.Copy("Canvas");
                CenteredText(r, r.UiSmall, label, x, y, w, h, 1, Pal(6));
                String.Free(label);
            }
            else if (k == "MenuBar")
            {
                if (!FillNodeBackground(r, n, x, y, w, h, 0)) r.Rect(x, y, w, h, Pal(1));
                r.Rect(x, y + h - 1, w, 1, border2);
                float hx = x + Z(4);
                for (int i = 0; i < n.Children.Count; i++)
                {
                    UiNode m = n.Children[i];
                    if (!m.IsMenuEntry || !m.Bool("Visible", true))
                    {
                        m.SW = 0;
                        continue;
                    }
                    string t = m.Get("Text");
                    float hw = r.TextWidth(f, t) + Z(22);
                    m.SX = hx;
                    m.SY = y;
                    m.SW = hw;
                    m.SH = h;
                    bool open = selected != null && m.IsAncestorOf(selected);
                    if (open) r.RoundRect(hx, y + Z(3), hw, h - Z(7), Z(6), Color.Hex(root.Get("Theme").ToLower() == "light" ? (uint)0xe6e6e9 : (uint)0x2b2b30));
                    CenteredText(r, f, t, hx + Z(11), y, hw, h - 1, 0, m.Bool("Enabled", true) ? fg : Pal(6));
                    hx += hw;
                }
            }
            else if (k == "TabControl")
            {
                float rad = Z(n.Int("CornerRadius", 10));
                if (!FillNodeBackground(r, n, x, y, w, h, rad)) r.RoundRect(x, y, w, h, rad, Pal(1));
                r.RoundBorder(x, y, w, h, rad, 1, border2);
                float th = Z(TabHeader);
                r.Rect(x + 1, y + th - 1, w - 2, 1, border2);
                int shown = ShownIndex(n);
                float tx = x + Z(6);
                r.PushClip(x, y, w, th);
                for (int i = 0; i < n.Children.Count; i++)
                {
                    UiNode page = n.Children[i];
                    string t = page.Get("Text");
                    float tw = (float)Math.Max((double)Z(56), (double)(r.TextWidth(f, t) + Z(28)));
                    tabNodes.Add(n);
                    tabIndex.Add(i);
                    tabX.Add(tx);
                    tabW.Add(tw);
                    bool sel = i == shown;
                    CenteredText(r, f, t, tx, y, tw, th, 1, sel ? fg : Pal(6));
                    if (sel) r.RoundRect(tx + Z(10), y + th - Z(3), tw - Z(20), Z(3), Z(1.5f), accent);
                    tx += tw + Z(2);
                }
                // '+': añade una página
                tabNodes.Add(n);
                tabIndex.Add(-2);
                tabX.Add(tx);
                tabW.Add(Z(28));
                bool plusHot = mouseX >= tx && mouseX < tx + Z(28) && mouseY >= y && mouseY < y + th;
                if (plusHot) r.RoundRect(tx + Z(2), y + Z(6), Z(24), th - Z(12), Z(6), Color.Hex(0x808080, 0.25f));
                r.Rect(tx + Z(9), y + th / 2 - 0.75f, Z(10), 1.5f, Pal(6));
                r.Rect(tx + Z(14) - 0.75f, y + th / 2 - Z(5), 1.5f, Z(10), Pal(6));
                r.PopClip();
                for (int i = 0; i < n.Children.Count; i++)
                {
                    UiNode page = n.Children[i];
                    if (i != shown)
                    {
                        page.SX = 0;
                        page.SY = 0;
                        page.SW = 0;
                        page.SH = 0;
                        continue;
                    }
                    page.SX = x + Z(1);
                    page.SY = y + th;
                    page.SW = w - Z(2);
                    page.SH = h - th - Z(1);
                    FillNodeBackground(r, page, page.SX, page.SY, page.SW, page.SH, 0);
                    r.PushClip(page.SX, page.SY, page.SW, page.SH);
                    for (int c = 0; c < page.Children.Count; c++) DrawNode(r, page.Children[c], page.SX, page.SY);
                    r.PopClip();
                }
            }
            else if (k == "TreeView")
            {
                float rad = Z(n.Int("CornerRadius", 8));
                if (!FillNodeBackground(r, n, x, y, w, h, rad)) r.RoundRect(x, y, w, h, rad, Pal(4));
                r.RoundBorder(x, y, w, h, rad, 1, border2);
                int fs = n.Int("FontSize", 14);
                float rh = ((float)Math.Ceiling(r.Sans(fs, false).Ascent + r.Sans(fs, false).Descent) + 12) * zoom;
                float ry = y + Z(4);
                r.PushClip(x + 1, y + 1, w - 2, h - 2);
                for (int i = 0; i < n.Children.Count; i++) DrawTreeRows(r, n.Children[i], 0, x, w, rh, f, fg, ref ry, y + h, true);
                r.PopClip();
            }
        }

        func DrawTreeRows(r: Renderer, t: UiNode, depth: int, x: float, w: float, rh: float, f: Font, fg: Color, ref ry: float, bottom: float, shown: bool)
        {
            if (t.Kind != "TreeNode") return;
            if (!shown || ry > bottom)
            {
                t.SW = 0;
                for (int i = 0; i < t.Children.Count; i++) DrawTreeRows(r, t.Children[i], depth + 1, x, w, rh, f, fg, ref ry, bottom, false);
                return;
            }
            t.SX = x + Z(4);
            t.SY = ry;
            t.SW = w - Z(8);
            t.SH = rh;
            float ax = x + Z(8) + depth * Z(18), cy = ry + rh / 2;
            bool expanded = t.Bool("Expanded", false);
            if (t.Children.Count > 0)
            {
                // Triángulo: hacia abajo si está expandido
                Color ac = Pal(6);
                for (int i = 0; i < 4; i++)
                {
                    if (expanded) r.Rect(ax + Z(4 + i), cy - Z(2) + Z(i), Z(1.6f), Z(1.6f), ac);
                    if (expanded) r.Rect(ax + Z(12 - i) - Z(1.6f), cy - Z(2) + Z(i), Z(1.6f), Z(1.6f), ac);
                    if (!expanded) r.Rect(ax + Z(6) + Z(i), cy - Z(4) + Z(i), Z(1.6f), Z(1.6f), ac);
                    if (!expanded) r.Rect(ax + Z(6) + Z(i), cy + Z(4) - Z(i) - Z(1.6f), Z(1.6f), Z(1.6f), ac);
                }
            }
            CenteredText(r, f, t.Get("Text"), ax + Z(20), ry, w, rh, 0, fg);
            ry += rh;
            for (int i = 0; i < t.Children.Count; i++) DrawTreeRows(r, t.Children[i], depth + 1, x, w, rh, f, fg, ref ry, bottom, expanded);
        }

        // Menús desplegados en el diseñador: los del elemento elegido (y sus menús padre).
        func DrawMenuPreview(r: Renderer)
        {
            popupItems.Clear();
            if (selected == null) return;
            var chain = new List<UiNode>();
            for (UiNode p = selected; p != null && p != root; p = p.Parent)
                if (p.Kind == "ContextMenu" || (p.IsMenuEntry && p.Kind != "Separator" && p.Children.Count > 0)) chain.Insert(0, p);
            float px = 0, py = 0, lastRight = 0;
            for (int c = 0; c < chain.Count; c++)
            {
                UiNode m = chain[c];
                if (c == 0)
                {
                    if (m.Kind == "ContextMenu")
                    {
                        // Encima de la bandeja, dentro de la ventana.
                        px = originX + Z(12);
                        py = originY + root.Int("Height", 600) * zoom - PopupHeight(m) - Z(8);
                    }
                    else if (m.Parent != null && m.Parent.Kind == "MenuBar")
                    {
                        px = m.SX;
                        py = m.SY + m.SH - 1;
                    }
                    else break;   // un menú suelto fuera de una barra: solo en el esquema
                }
                else
                {
                    px = lastRight - Z(4);   // a la derecha del menú padre, a la altura de la fila del submenú
                    py = m.SY - Z(5);
                }
                lastRight = DrawPopup(r, m, px, py);
            }
            delete chain;
        }

        func PopupHeight(m: UiNode) -> float
        {
            float h = Z(10);
            for (int i = 0; i < m.Children.Count; i++)
            {
                UiNode it = m.Children[i];
                if (!it.IsMenuEntry || !it.Bool("Visible", true)) continue;
                h += it.Kind == "Separator" ? Z(9) : Z(30);
            }
            return h < Z(40) ? Z(40) : h;
        }

        // Devuelve el borde derecho del menú dibujado.
        func DrawPopup(r: Renderer, m: UiNode, x: float, y: float) -> float
        {
            Font f = ZFont(r, m.Int("FontSize", 14), false);
            float w = Z(180);
            for (int i = 0; i < m.Children.Count; i++)
            {
                UiNode it = m.Children[i];
                float iw = Z(36) + r.TextWidth(f, it.Get("Text")) + Z(28) + (it.Has("Shortcut") ? r.TextWidth(f, it.Get("Shortcut")) + Z(24) : 0) + Z(18);
                if (iw > w) w = iw;
            }
            float h = PopupHeight(m);
            // Pegado al borde derecho de la ventana si no cabe.
            float right = originX + root.Int("Width", 800) * zoom;
            if (x + w > right - 2) x = right - 2 - w;
            r.Shadow(x, y, w, h, Z(8), 14, Color.Hex(0x000000, 0.45f));
            r.RoundRect(x, y, w, h, Z(8), Pal(1));
            r.RoundBorder(x, y, w, h, Z(8), 1, Pal(3));
            float ry = y + Z(5);
            bool light = root.Get("Theme").ToLower() == "light";
            for (int i = 0; i < m.Children.Count; i++)
            {
                UiNode it = m.Children[i];
                if (!it.IsMenuEntry || !it.Bool("Visible", true))
                {
                    it.SW = 0;
                    continue;
                }
                float rh = it.Kind == "Separator" ? Z(9) : Z(30);
                it.SX = x + Z(4);
                it.SY = ry;
                it.SW = w - Z(8);
                it.SH = rh;
                popupItems.Add(it);
                if (it.Kind == "Separator")
                {
                    r.Rect(x + Z(10), ry + rh / 2, w - Z(20), 1, Pal(2));
                    ry += rh;
                    continue;
                }
                if (it.IsAncestorOf(selected)) r.RoundRect(x + Z(4), ry, w - Z(8), rh, Z(6), Color.Hex(light ? (uint)0xf0f0f2 : (uint)0x222226));
                Color tc = it.Bool("Enabled", true) ? Pal(5) : Pal(6);
                float cx = x + Z(20), cy = ry + rh / 2;
                if (it.Bool("Checked", false))
                {
                    for (int k = 0; k <= 3; k++) r.Rect(cx - Z(5) + Z(k), cy + Z(k) - Z(1), Z(1.8f), Z(1.8f), tc);
                    for (int k = 0; k <= 6; k++) r.Rect(cx - Z(2) + Z(k), cy + Z(2) - Z(k * 1.1f), Z(1.8f), Z(1.8f), tc);
                }
                else if (it.Has("Icon"))
                {
                    std.ui.Image icon = Preview(it.Get("Icon"));
                    if (icon != null)
                    {
                        float ih = (float)Math.Min((double)icon.Height, 18.0) * zoom, iw = icon.Width * ih / icon.Height;
                        DrawPreviewImage(r, icon, 0, 0, icon.Width, icon.Height, cx - iw / 2, cy - ih / 2, iw, ih);
                    }
                }
                CenteredText(r, f, it.Get("Text"), x + Z(36), ry, w, rh, 0, tc);
                if (it.Has("Shortcut"))
                {
                    float sw = r.TextWidth(f, it.Get("Shortcut"));
                    CenteredText(r, f, it.Get("Shortcut"), x + w - Z(30) - sw, ry, sw + 4, rh, 0, Pal(6));
                }
                if (it.Children.Count > 0)
                {
                    float ax = x + w - Z(16);
                    for (int k = 0; k < 4; k++)
                    {
                        r.Rect(ax - Z(2) + Z(k), cy - Z(4) + Z(k), Z(1.6f), Z(1.6f), Pal(6));
                        r.Rect(ax - Z(2) + Z(k), cy + Z(4) - Z(k) - Z(1.6f), Z(1.6f), Z(1.6f), Pal(6));
                    }
                }
                ry += rh;
            }
            return x + w;
        }

        // Elemento de un menú desplegado bajo el punto (o null).
        func PopupHit(px: float, py: float) -> UiNode
        {
            for (int i = popupItems.Count - 1; i >= 0; i--)
            {
                UiNode it = popupItems[i];
                if (px >= it.SX && py >= it.SY && px < it.SX + it.SW && py < it.SY + it.SH) return it;
            }
            return null;
        }

        // Bandeja de componentes (Timer, ContextMenu...) bajo la ventana diseñada.
        func DrawTray(r: Renderer, x: float, y: float, w: float)
        {
            int count = 0;
            for (int i = 0; i < root.Children.Count; i++)
                if (root.Children[i].IsComponent) count++;
            if (count == 0) return;
            r.RoundRect(x, y, w, TrayH, 8, Theme.Surface);
            r.RoundBorder(x, y, w, TrayH, 8, 1, Theme.Border);
            string title = L.T("COMPONENTS");
            r.Text(r.UiSmall, x + 12, y + 15, title, Theme.TextTertiary);
            float cx = x + 24 + r.TextWidth(r.UiSmall, title);
            for (int i = 0; i < root.Children.Count; i++)
            {
                UiNode c = root.Children[i];
                if (!c.IsComponent) continue;
                string name = c.Has("Name") ? c.Get("Name") : L.T(c.Kind);
                float cw = r.TextWidth(r.Ui, name) + 46;
                c.SX = cx;
                c.SY = y + 7;
                c.SW = cw;
                c.SH = TrayH - 14;
                bool hot = mouseX >= c.SX && mouseX < c.SX + cw && mouseY >= c.SY && mouseY < c.SY + c.SH;
                r.RoundRect(c.SX, c.SY, cw, c.SH, 7, c == selected ? Theme.Active : (hot ? Theme.Hover : Theme.Elevated));
                DrawToolIcon(r, c.Kind, c.SX + 8, c.SY + 5);
                r.Text(r.Ui, c.SX + 36, c.SY + 7, name, Theme.Text);
                cx += cw + 8;
            }
        }

        func DrawToolbox(r: Renderer)
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
                var parts = Text.Split(kinds, "|");
                for (int i = 0; i < parts.Count; i++)
                {
                    float iy = Y + 52 + i * ToolRow - toolScroll;
                    if (i == 15)
                    {
                        // Separación: lo que sigue son componentes (van en la bandeja, no en la ventana).
                        r.Rect(X + 16, iy - 1, ToolboxWidth - 32, 1, Theme.Border);
                    }
                    bool hot = toolHover == i || (dragMode == 3 && newKind == parts[i]);
                    if (hot) r.RoundRect(X + 10, iy, ToolboxWidth - 20, ToolRow - 2, 8, Theme.Hover);
                    DrawToolIcon(r, parts[i], X + 20, iy + 6);
                    r.Text(r.Ui, X + 54, iy + 8, L.T(parts[i]), hot ? Theme.White : Theme.Text);
                }
                delete parts;
                float hy = Y + 52 + KindCount * ToolRow + 12 - toolScroll;
                if (hy + 30 < Y + H)
                {
                    r.Rect(X + 16, hy, ToolboxWidth - 32, 1, Theme.Border);
                    string hints = "Drag a control onto the window|Double-click: go to its event|Ctrl while dragging: no snapping|" +
                                   "Ctrl+D duplicate · Del delete|Ctrl+C / Ctrl+V copy and paste|Tab: next control|Wheel: scroll · middle button: pan|G: grid · Ctrl+wheel: zoom";
                    var lines = Text.Split(hints, "|");
                    for (int i = 0; i < lines.Count && hy + 14 + i * 18 + 16 <= Y + H; i++)
                        r.Text(r.UiSmall, X + 16, hy + 14 + i * 18, L.T(lines[i]), Theme.TextTertiary);
                    delete lines;
                }
            }
            r.PopClip();
        }

        // Árbol de controles: clic para seleccionar, doble clic para ir al evento.
        func DrawOutline(r: Renderer)
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
                string label = n == root ? (root.Has("Class") ? root.Get("Class") : "Window")
                             : (named ? n.Get("Name") : (n.Get("Text").Length > 0 ? "\"" + n.Get("Text") + "\"" : L.T(n.Kind)));
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

        // Vista previa del WebView: marco de navegador con la dirección (la página se ve al ejecutar).
        func DrawWebViewNode(r: Renderer, n: UiNode, x: float, y: float, w: float, h: float, border: Color)
        {
            float rad = Z(n.Int("CornerRadius", 8));
            r.RoundRect(x, y, w, h, rad, NodeColor(n, "Background", Pal(1)));
            r.RoundBorder(x, y, w, h, rad, 1, border);
            float bar = Z(34) < h ? Z(34) : h;
            r.PushClip(x + 1, y + 1, w - 2, h - 2);
            r.Rect(x, y + bar, w, 1, Pal(2));
            Color dim = Pal(6);
            float cy = y + bar / 2;
            r.Text(r.Icons, x + Z(10), cy - Z(9), "‹", dim);
            r.Text(r.Icons, x + Z(30), cy - Z(9), "›", dim);
            r.RoundBorder(x + Z(50), cy - Z(5), Z(10), Z(10), Z(5), 1.4f, dim);
            float ax = x + Z(70), aw = w - Z(80);
            if (aw > Z(20))
            {
                r.RoundRect(ax, y + Z(6), aw, bar - Z(12), (bar - Z(12)) / 2, Pal(4));
                r.RoundBorder(ax, y + Z(6), aw, bar - Z(12), (bar - Z(12)) / 2, 1, Pal(2));
                string src = n.Get("Source");
                string addr = n.Has("Html") && src.Length == 0 ? "(HTML)" : (src.Length > 0 ? src : "about:blank");
                r.PushClip(ax + Z(10), y, aw - Z(20), bar);
                CenteredText(r, ZFont(r, 12, false), addr, ax + Z(12), y, aw - Z(24), bar, 0, dim);
                r.PopClip();
            }
            float bodyH = h - bar;
            if (bodyH > Z(40))
            {
                float gx = x + w / 2, gy = y + bar + bodyH / 2 - Z(14);
                float gr = bodyH > Z(120) ? Z(20) : Z(11);
                r.RoundBorder(gx - gr, gy - gr, gr * 2, gr * 2, gr, 1.5f, dim);
                r.RoundBorder(gx - gr * 0.45f, gy - gr, gr * 0.9f, gr * 2, gr * 0.45f, 1.3f, dim);
                r.Rect(gx - gr, gy - 0.6f, gr * 2, 1.3f, dim);
                CenteredText(r, ZFont(r, 14, true), "WebView", x, gy + gr + Z(6), w, Z(22), 1, NodeColor(n, "Foreground", Pal(5)));
            }
            r.PopClip();
        }

        func DrawToolIcon(r: Renderer, kind: string, x: float, y: float)
        {
            Color c = Theme.TextSecondary;
            Color dim = Theme.BorderStrong;
            if (kind == "Sound" || kind == "Music")
            {
                DrawComponentIcon(r, kind, x + 4, y + 11, c);
                return;
            }
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
            else if (kind == "VideoPlayer")
            {
                r.RoundBorder(x, y + 3, 22, 15, 3, 1.2f, c);
                PlayGlyph(r, x + 11.5f, y + 10.5f, 4, c);
            }
            else if (kind == "ListBox")
            {
                r.RoundBorder(x, y + 1, 22, 19, 4, 1.2f, c);
                r.Rect(x + 4, y + 6, 14, 1.5f, c);
                r.RoundRect(x + 3, y + 9, 16, 4, 1.5f, dim);
                r.Rect(x + 4, y + 15, 10, 1.5f, c);
            }
            else if (kind == "WebView")
            {
                // Globo terráqueo
                r.RoundBorder(x + 2, y + 1, 19, 19, 9.5f, 1.2f, c);
                r.RoundBorder(x + 7.5f, y + 1, 8, 19, 4, 1.2f, c);
                r.Rect(x + 2, y + 10, 19, 1.2f, c);
            }
            else if (kind == "PictureBox")
            {
                r.RoundBorder(x, y + 2, 22, 17, 3, 1.2f, c);
                r.RoundRect(x + 14, y + 5, 4, 4, 2, c);
                for (int i = 0; i < 5; i++) r.Rect(x + 3 + i * 2, y + 15 - i * 1.6f, 2, 2 + i * 1.6f, c);
                for (int i = 0; i < 4; i++) r.Rect(x + 13 + i * 2, y + 12 + i * 0.8f, 2, 4 - i * 0.8f, c);
            }
            else if (kind == "TabControl")
            {
                r.RoundBorder(x, y + 5, 22, 15, 3, 1.2f, c);
                r.RoundRect(x, y + 1, 9, 6, 2, c);
                r.RoundBorder(x + 10, y + 2, 8, 5, 2, 1, dim);
            }
            else if (kind == "TreeView")
            {
                r.Rect(x + 3, y + 3, 6, 3, c);
                r.Rect(x + 5, y + 6, 1.2f, 11, dim);
                r.Rect(x + 5, y + 10, 5, 1.2f, dim);
                r.Rect(x + 5, y + 16, 5, 1.2f, dim);
                r.Rect(x + 11, y + 8.5f, 9, 3, c);
                r.Rect(x + 11, y + 14.5f, 9, 3, c);
            }
            else if (kind == "MenuBar")
            {
                r.RoundBorder(x, y + 2, 22, 17, 3, 1.2f, c);
                r.Rect(x + 1, y + 7, 20, 1.2f, c);
                r.Rect(x + 4, y + 4, 4, 1.5f, c);
                r.Rect(x + 10, y + 4, 4, 1.5f, c);
                r.Rect(x + 4, y + 11, 8, 1.5f, dim);
                r.Rect(x + 4, y + 15, 6, 1.5f, dim);
            }
            else if (kind == "Canvas")
            {
                r.RoundBorder(x, y + 2, 22, 17, 3, 1.2f, c);
                r.RoundRect(x + 4, y + 9, 6, 6, 3, c);
                r.Rect(x + 11, y + 6, 7, 7, dim);
            }
            else if (kind == "Timer")
            {
                r.RoundBorder(x + 2, y + 2, 18, 18, 9, 1.4f, c);
                r.Rect(x + 10.3f, y + 5, 1.4f, 6.5f, c);
                r.Rect(x + 10.3f, y + 10, 5, 1.4f, c);
            }
            else if (kind == "ContextMenu")
            {
                r.RoundBorder(x + 4, y + 2, 17, 18, 3, 1.2f, c);
                r.Rect(x + 7, y + 6, 10, 1.5f, c);
                r.Rect(x + 7, y + 10, 10, 1.5f, c);
                r.Rect(x + 7, y + 14, 7, 1.5f, dim);
                r.Rect(x + 1, y + 1, 1.5f, 6, c);
                r.Rect(x + 1, y + 1, 6, 1.5f, c);
            }
            else
            {
                r.RoundBorder(x, y + 1, 22, 19, 4, 1.2f, c);
                r.Rect(x + 4, y + 6, 10, 1.5f, c);
            }
        }

        func DrawGhost(r: Renderer)
        {
            UiNode tmp = CreateNode(newKind);
            float w = tmp.Int("Width", 100) * zoom, h = tmp.Int("Height", 32) * zoom;
            delete tmp;
            float gx = mouseX - w / 2, gy = mouseY - h / 2;
            r.RoundRect(gx, gy, w, h, 6, Color.Hex(0x4c8dff, 0.18f));
            r.RoundBorder(gx, gy, w, h, 6, 1.5f, Accent);
            CenteredText(r, r.UiSmall, L.T(newKind), gx, gy, w, h, 1, Color.Hex(0xffffff));
        }

        func DrawProps(r: Renderer)
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
            if (selected != root && selected.Movable)
            {
                DrawArrangeBar(r, px + 18, Y + ArrangeTop);
                top = Y + ArrangeTop + 38;
            }
            r.PushClip(px, top, PropsWidth, H - (top - Y));
            var defs = PropsFor(selected);
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
                if (d.Type == 9)
                {
                    // Botones de acción ("Añadir página"...): ocupan toda la fila.
                    var acts = Text.Split(d.Options, "|");
                    float aw = (vw + (vx - lx)) / acts.Count;
                    for (int o = 0; o < acts.Count; o++)
                    {
                        float bx = lx + o * aw;
                        bool hot = mouseY >= y && mouseY < y + RowHeight && mouseX >= bx && mouseX < bx + aw - 4;
                        r.RoundRect(bx, y + 1, aw - 4, 34, 8, hot ? Theme.Hover : Theme.Elevated);
                        string label = String.Concat("+ ", L.T(acts[o]));
                        r.Text(r.UiSmall, bx + (aw - 4 - r.TextWidth(r.UiSmall, label)) / 2, y + 11, label, Theme.Text);
                    }
                    delete acts;
                    y += RowHeight + 4;
                    continue;
                }
                r.Text(r.Ui, lx, y + 9, d.Key == "GradientDirection" ? L.T("Direction") : d.Key, Theme.TextSecondary);
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
                else if (d.Type == 8)
                {
                    Color c = new Color(0, 0, 0, 0);
                    bool valid = has && ParseColor(val, out c);
                    r.RoundRect(vx, y + 1, 34, 34, 8, Theme.Base);
                    if (valid)
                    {
                        r.RoundRect(vx + 4, y + 5, 26, 26, 6, c);
                        r.RoundBorder(vx + 4, y + 5, 26, 26, 6, 1, Color.Hex(0xffffff, 0.15f));
                    }
                    else DrawNoneSwatch(r, vx + 8, y + 9, 18);
                    if (colorKey == d.Key) r.RoundBorder(vx, y + 1, 34, 34, 8, 1.5f, Theme.White);
                    float fx2 = vx + 40, fw2 = vw - 40;
                    if (editingKey == d.Key) field.Draw(r, fx2, y + 1, fw2, "");
                    else
                    {
                        r.RoundRect(fx2, y + 1, fw2, 34, 8, Theme.Base);
                        r.RoundBorder(fx2, y + 1, fw2, 34, 8, 1, Theme.Border);
                        r.Text(r.Ui, fx2 + 12, y + 9, has ? val : L.T("Theme"), has ? Theme.Text : Theme.TextTertiary);
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
                    var opts = Text.Split(d.Options, "|");
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
            if (colorKey.Length > 0) DrawColorPopup(r);
            if (arrangeHover >= 0 && selected != root) DrawTip(r, L.T(ArrangeTip(arrangeHover)), px + 18 + arrangeHover * ArrangeButtonWidth, Y + ArrangeTop + 34);
        }

        func DrawTip(r: Renderer, tip: string, x: float, y: float)
        {
            float tw = r.TextWidth(r.UiSmall, tip) + 16;
            if (x + tw > X + W - 8) x = X + W - 8 - tw;
            r.Shadow(x, y, tw, 24, 6, 10, Color.Hex(0x000000, 0.5f));
            r.RoundRect(x, y, tw, 24, 6, Theme.Elevated);
            r.RoundBorder(x, y, tw, 24, 6, 1, Theme.BorderStrong);
            r.Text(r.UiSmall, x + 8, y + 5, tip, Theme.Text);
        }

        // Alinear en el contenedor (izq., centro, der., arriba, medio, abajo) y orden (frente, fondo).
        func DrawArrangeBar(r: Renderer, x: float, y: float)
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
