// =============================================================================
//  std.ui — puntos de enlace de los controles nuevos con Widget y Window.
//
//  ui.fst llama a estos métodos desde Draw, Layout, HandleEvent y HandleKey; aquí
//  se reparte el trabajo según el tipo de control (cada uno vive en su archivo:
//  image.fst, tabs.fst, tree.fst, menu.fst, timer.fst y canvas.fst).
//
//  Eventos: además de Click y Changed, un control puede lanzar SelectedChanged
//  (= Changed), NodeActivated, Paint, MouseDown, MouseMove, MouseUp y Tick. El
//  código generado desde el .fstui los conecta con SetEvent.
// =============================================================================
using std.collections;
using std.text;

namespace std.ui
{
    public enum WidgetEvent { Click, Changed, SelectedChanged, NodeActivated, Paint, MouseDown, MouseMove, MouseUp, Tick }

    // Ratón en coordenadas del control (Canvas: MouseDown/MouseMove/MouseUp).
    public struct MouseArgs
    {
        public var X: int;
        public var Y: int;
        public var Button: int;   // 1 izquierdo, 2 central, 3 derecho (0 en MouseMove sin botón)
        public var Clicks: int;   // 2 en un doble clic
        public var Ctrl: bool;
        public var Shift: bool;
    }

    public memory_unsafe partial class Widget
    {
        internal var activatedEvent: int;
        internal var paintEvent: int;
        internal var mouseDownEvent: int;
        internal var mouseMoveEvent: int;
        internal var mouseUpEvent: int;
        internal var tickEvent: int;

        // Último evento de ratón (Canvas) y contexto de dibujo (válido durante Paint).
        public var Mouse: MouseArgs;
        public var Graphics: Graphics;

        // Menú contextual que se abre con el botón derecho sobre el control (o sus hijos).
        public var ContextMenu: Widget;
        // ContextMenu: control sobre el que se abrió por última vez.
        public var SourceControl: Widget;

        // Conecta un evento con su número (SetEvents debe haberse llamado antes con la función).
        public func SetEvent(which: WidgetEvent, id: int)
        {
            switch (which)
            {
                case WidgetEvent.Click: clickEvent = id; break;
                case WidgetEvent.Changed: changedEvent = id; break;
                case WidgetEvent.SelectedChanged: changedEvent = id; break;
                case WidgetEvent.NodeActivated: activatedEvent = id; break;
                case WidgetEvent.Paint: paintEvent = id; break;
                case WidgetEvent.MouseDown: mouseDownEvent = id; break;
                case WidgetEvent.MouseMove: mouseMoveEvent = id; break;
                case WidgetEvent.MouseUp: mouseUpEvent = id; break;
                case WidgetEvent.Tick: tickEvent = id; break;
            }
        }

        internal func RaiseEvent(id: int)
        {
            if (id != 0 && eventFn != null) eventFn(eventTarget, this, id);
        }

        // Valores iniciales según el tipo (lo llama Widget.Create).
        func InitKind()
        {
            if (Kind == WidgetKind.Timer)
            {
                Enabled = false;
                interval = 100;
            }
            if (Kind == WidgetKind.TabPage) Anchor = Anchor.Left | Anchor.Top | Anchor.Right | Anchor.Bottom;
            if (Kind == WidgetKind.MenuBar && height <= 0) height = 30;
        }

        // Número de opciones entre las que elige SelectedIndex.
        internal prop ChoiceCount: int => Kind == WidgetKind.TabControl ? PageCount : items.Count;

        internal prop FocusableKind: bool => Kind == WidgetKind.TabControl || Kind == WidgetKind.TreeView;

        // Se redibuja al mover el ratón por encima (resaltado de filas, pestañas o menús).
        internal prop TracksHover: bool => Kind == WidgetKind.ListBox || Kind == WidgetKind.TreeView || Kind == WidgetKind.TabControl ||
                                     Kind == WidgetKind.MenuBar;

        internal prop ArrowCursor: bool => Kind == WidgetKind.TreeView || Kind == WidgetKind.Canvas || Kind == WidgetKind.PictureBox ||
                                     Kind == WidgetKind.TabControl || Kind == WidgetKind.MenuBar;

        // Componentes sin representación en la ventana (Timer, ContextMenu...).
        public prop IsComponent: bool => Kind == WidgetKind.Timer || Kind == WidgetKind.ContextMenu;

        func LayoutChildren()
        {
            if (Kind == WidgetKind.TabControl)
            {
                LayoutPages();
                return;
            }
            for (int i = 0; i < Children.Count; i++)
                Children[i].Layout(ScreenX, ScreenY, ActualWidth - width, ActualHeight - height);
        }

        func DrawKind(c: Canvas, p: Palette, w: Window, font: UiFont, fx: float, fy: float, fw: float, fh: float, focused: bool, hot: bool,
                      textColor: uint, accent: uint)
        {
            switch (Kind)
            {
                case WidgetKind.PictureBox:
                    DrawPictureBox(c, p, fx, fy, fw, fh);
                    break;
                case WidgetKind.TabControl:
                    DrawTabControl(c, p, w, font, fx, fy, fw, fh, focused, textColor, accent);
                    break;
                case WidgetKind.TabPage:
                    if (Background != 0) FillBackground(c, fx, fy, fw, fh, CornerRadius >= 0 ? CornerRadius : 0, 0);
                    break;
                case WidgetKind.TreeView:
                    DrawTreeView(c, p, w, font, fx, fy, fw, fh, focused, textColor, accent);
                    break;
                case WidgetKind.MenuBar:
                    DrawMenuBar(c, p, w, font, fx, fy, fw, fh, textColor);
                    break;
                case WidgetKind.Canvas:
                    DrawCanvasWidget(c, p, fx, fy, fw, fh);
                    break;
                default:
                    break;  // MenuItem, ContextMenu y Timer no se dibujan en la ventana
            }
        }

        // Control visible más interno bajo el punto, contando también paneles y etiquetas.
        internal func DeepestAt(px: int, py: int) -> Widget
        {
            if (!Visible || !Contains(px, py) || IsComponent || Kind == WidgetKind.MenuItem) return null;
            for (int i = Children.Count - 1; i >= 0; i--)
            {
                Widget hit = Children[i].DeepestAt(px, py);
                if (hit != null) return hit;
            }
            return this;
        }

        internal func SetMouse(e: UiEvent, button: int, clicks: int)
        {
            Mouse = new MouseArgs();
            Mouse.X = e.X - ScreenX;
            Mouse.Y = e.Y - ScreenY;
            Mouse.Button = button;
            Mouse.Clicks = clicks;
            Mouse.Ctrl = e.Ctrl;
            Mouse.Shift = e.Shift;
        }
    }

    public partial class Window
    {
        // Componentes no visuales (Timer, ContextMenu...): no se dibujan ni reciben el ratón.
        public var Components: List<Widget> = new List<Widget>();

        // Doble clic: número de clics seguidos en el mismo sitio (1, 2...).
        public var ClickCount: int = 1;
        var lastClickTime: long = -1000;
        var lastClickX: int;
        var lastClickY: int;
        var lastClickWidget: Widget;

        public func AddComponent(w: Widget) -> Widget
        {
            w.Parent = null;
            w.SetOwner(this);
            Components.Add(w);
            return w;
        }

        // Busca un componente por su nombre.
        public func FindComponent(name: string) -> Widget
        {
            for (int i = 0; i < Components.Count; i++)
                if (Components[i].Name == name) return Components[i];
            return null;
        }

        func DeepestAt(x: int, y: int) -> Widget
        {
            for (int i = Children.Count - 1; i >= 0; i--)
            {
                Widget w = Children[i].DeepestAt(x, y);
                if (w != null) return w;
            }
            return null;
        }

        // Antes del tratamiento normal: menús abiertos, botón derecho y cuenta de clics.
        func HandleEventFirst(e: UiEvent) -> bool
        {
            if (e.Kind == UiEventKind.MouseDown && e.Button == 1)
            {
                long now = Environment.TickCount64();
                Widget hit = DeepestAt(e.X, e.Y);
                if (hit == lastClickWidget && now - lastClickTime < 450 && Math.Abs(e.X - lastClickX) < 5 && Math.Abs(e.Y - lastClickY) < 5)
                    ClickCount++;
                else ClickCount = 1;
                lastClickTime = now;
                lastClickX = e.X;
                lastClickY = e.Y;
                lastClickWidget = hit;
            }
            if (e.Kind == UiEventKind.KeyDown) lastClickWidget = null;  // una tecla entre dos clics: no es doble clic
            if (e.Kind == UiEventKind.FocusLost || e.Kind == UiEventKind.Resize) CloseMenus();
            if (popups.Count > 0)
            {
                if (e.Kind == UiEventKind.MouseDown || e.Kind == UiEventKind.MouseUp || e.Kind == UiEventKind.MouseMove ||
                    e.Kind == UiEventKind.Scroll)
                {
                    MenuMouse(e);
                    return true;
                }
                if (e.Kind == UiEventKind.Char) return true;
            }
            if (e.Kind == UiEventKind.MouseDown && e.Button == 3)
            {
                if (DropDown != null) CloseDropDown();
                RightClick(e);
                return true;
            }
            if (e.Kind == UiEventKind.MouseUp && e.Button == 3)
            {
                Widget hit = HitTest(e.X, e.Y);
                if (hit != null && hit.Kind == WidgetKind.Canvas)
                {
                    hit.SetMouse(e, 3, 1);
                    hit.RaiseEvent(hit.mouseUpEvent);
                }
                return true;
            }
            return false;
        }

        func RightClick(e: UiEvent)
        {
            Widget deep = DeepestAt(e.X, e.Y);
            for (Widget t = deep; t != null; t = t.Parent)
                if (t.ContextMenu != null && t.Enabled)
                {
                    if (t.Kind == WidgetKind.TreeView) t.TreeSelectAt(e.Y);
                    t.ContextMenu.SourceControl = t;
                    OpenContextMenu(t.ContextMenu, e.X, e.Y);
                    return;
                }
            Widget hit = HitTest(e.X, e.Y);
            if (hit != null && hit.Kind == WidgetKind.Canvas && hit.Enabled)
            {
                hit.SetMouse(e, 3, 1);
                hit.RaiseEvent(hit.mouseDownEvent);
                dirty = true;
            }
        }

        // Muestra un ContextMenu en el punto (coordenadas de la ventana).
        public func ShowContextMenu(menu: Widget, x: int, y: int)
        {
            if (menu == null) return;
            CloseMenus();
            OpenContextMenu(menu, x, y);
        }

        func MouseDownKind(hit: Widget, e: UiEvent)
        {
            switch (hit.Kind)
            {
                case WidgetKind.TabControl:
                    hit.TabMouseDown(e.X, e.Y);
                    break;
                case WidgetKind.TreeView:
                    hit.TreeMouseDown(e.X, e.Y, ClickCount);
                    break;
                case WidgetKind.MenuBar:
                {
                    int i = hit.MenuHeaderAt(e.X, e.Y);
                    if (i >= 0) OpenBarMenu(hit, i, false);
                    break;
                }
                case WidgetKind.Canvas:
                    hit.SetMouse(e, 1, ClickCount);
                    hit.RaiseEvent(hit.mouseDownEvent);
                    break;
                default:
                    break;
            }
        }

        func MouseUpKind(p: Widget, e: UiEvent)
        {
            if (p.Kind == WidgetKind.Canvas)
            {
                p.SetMouse(e, 1, ClickCount);
                p.RaiseEvent(p.mouseUpEvent);
            }
            else if (p.Kind == WidgetKind.PictureBox && p.Contains(e.X, e.Y)) p.RaiseClick();
        }

        func MouseMoveKind(e: UiEvent)
        {
            Widget target = Pressed != null && Pressed.Kind == WidgetKind.Canvas ? Pressed : HitTest(e.X, e.Y);
            if (target != null && target.Kind == WidgetKind.Canvas && target.Enabled && target.mouseMoveEvent != 0)
            {
                target.SetMouse(e, Pressed == target ? 1 : 0, 1);
                target.RaiseEvent(target.mouseMoveEvent);
            }
        }

        func ScrollKind(over: Widget, e: UiEvent)
        {
            if (over.Kind == WidgetKind.TreeView)
            {
                over.ScrollTree(e.Delta);
                dirty = true;
            }
        }

        func KeyKind(f: Widget, e: UiEvent)
        {
            if (f.Kind == WidgetKind.TabControl && (e.Key == KeyCode.Left || e.Key == KeyCode.Right))
            {
                FocusVisible = true;
                f.SelectTab(f.SelectedIndex + (e.Key == KeyCode.Right ? 1 : -1), true);
            }
            else if (f.Kind == WidgetKind.TreeView)
            {
                FocusVisible = true;
                f.TreeKey(e);
            }
        }

        // Antes del tratamiento normal del teclado: menús abiertos, atajos y Ctrl+Tab.
        func HandleKeyFirst(e: UiEvent) -> bool
        {
            if (popups.Count > 0)
            {
                MenuKey(e);
                dirty = true;
                return true;
            }
            if (e.Ctrl && e.Key == KeyCode.Tab)
            {
                CycleTabs(e.Shift);
                dirty = true;
                return true;
            }
            if (RunShortcut(e))
            {
                dirty = true;
                return true;
            }
            return false;
        }

        // ------------------------------------------------------------- pruebas

        // Teclas con modificadores en FASET_UI_SCRIPT: "ctrl+s", "ctrl+shift+tab", "f5", "pagedown".
        func ParseScriptKey(k: string, ref e: UiEvent)
        {
            var parts = Text.Split(k.ToLower(), "+");
            string key = parts.Count > 0 ? parts[parts.Count - 1] : "";
            for (int i = 0; i + 1 < parts.Count; i++)
            {
                if (parts[i] == "ctrl") e.Ctrl = true;
                if (parts[i] == "shift") e.Shift = true;
            }
            KeyCode code = Shortcuts.KeyFromName(key);
            if (code != KeyCode.None && code != KeyCode.Other) e.Key = code;
            if (key.Length == 1 && ((key[0] >= 'a' && key[0] <= 'z') || (key[0] >= '0' && key[0] <= '9')))
            {
                e.KeyChar = (char)(key[0] >= 'a' ? key[0] - 32 : key[0]);
                if (e.Key == KeyCode.None) e.Key = key == "a" ? KeyCode.A : key == "c" ? KeyCode.C : key == "v" ? KeyCode.V
                                                    : key == "x" ? KeyCode.X : KeyCode.Other;
            }
        }

        // Verbos extra del guion de pruebas.
        func ScriptVerb(op: string, parts: List<string>)
        {
            UiEvent e = new UiEvent();
            if ((op == "rclick" || op == "dblclick" || op == "down" || op == "up" || op == "drag") && parts.Count >= 3)
            {
                e.X = Convert.ToInt32(parts[1]);
                e.Y = Convert.ToInt32(parts[2]);
                e.Button = op == "rclick" ? 3 : 1;
                e.Kind = UiEventKind.MouseMove;
                HandleEvent(e);
                if (op == "drag") return;
                int times = op == "dblclick" ? 2 : 1;
                for (int t = 0; t < times; t++)
                {
                    if (op != "up")
                    {
                        e.Kind = UiEventKind.MouseDown;
                        HandleEvent(e);
                    }
                    if (op != "down")
                    {
                        e.Kind = UiEventKind.MouseUp;
                        HandleEvent(e);
                    }
                }
            }
            else if (op == "wait" && parts.Count >= 2)
            {
                // El reloj de los temporizadores avanza sin esperar de verdad.
                if (simTime < 0) simTime = 0;
                long target = simTime + Convert.ToInt32(parts[1]);
                for (;;)
                {
                    int until = UpdateComponents(simTime);  // dispara los vencidos; ms hasta el siguiente
                    if (simTime >= target) break;
                    long step = target - simTime;
                    if (until > 0 && until < step) step = until;
                    simTime += step;
                }
            }
        }
    }
}
