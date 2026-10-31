// =============================================================================
//  std.ui — menús: MenuBar (barra arriba de la ventana con menús desplegables) y
//  ContextMenu (se abre con el botón derecho sobre el control que lo nombra en su
//  propiedad ContextMenu).
//
//      <MenuBar>
//        <Menu Text="Archivo">
//          <MenuItem Text="Abrir" Shortcut="Ctrl+O" Click="OnAbrir" />
//          <Separator />
//          <Menu Text="Recientes"> <MenuItem Text="notas.txt" /> </Menu>
//        </Menu>
//      </MenuBar>
//      <ContextMenu Name="menuLista"> <MenuItem Text="Borrar" Click="OnBorrar" /> </ContextMenu>
//      <ListBox ... ContextMenu="menuLista" />
//
//  Menu y MenuItem son el mismo tipo (WidgetKind.MenuItem): un elemento con hijos
//  abre un submenú. Un separador es un MenuItem con Text = "-". Cada elemento tiene
//  Text, Shortcut ("Ctrl+S", "Ctrl+Shift+N", "F5", "Supr"...: también funciona con
//  el teclado aunque el menú esté cerrado), Checked, Enabled, Visible, Icon y Click.
//  Teclado con un menú abierto: ↑/↓, ←/→ (menú vecino o submenú), Enter y Esc.
// =============================================================================
using std.collections;
using std.text;

namespace std.ui
{
    // Un menú desplegado (lista de los hijos visibles de 'Menu').
    class MenuPopup
    {
        public var Menu: Widget;
        public var Bar: Widget;     // MenuBar del que cuelga (solo el primero de la pila)
        public var X: float;
        public var Y: float;
        public var W: float;
        public var H: float;
        public var Hot: int = -1;   // índice (en Menu.Children) del elemento resaltado
    }

    // Atajos de teclado escritos como texto ("Ctrl+Shift+S").
    public static class Shortcuts
    {
        public static func KeyFromName(name: string) -> KeyCode
        {
            string n = name.ToLower();
            if (n == "tab") return KeyCode.Tab;
            if (n == "enter" || n == "intro" || n == "return") return KeyCode.Enter;
            if (n == "esc" || n == "escape") return KeyCode.Escape;
            if (n == "space" || n == "espacio") return KeyCode.Space;
            if (n == "del" || n == "delete" || n == "supr") return KeyCode.Delete;
            if (n == "ins" || n == "insert") return KeyCode.Insert;
            if (n == "backspace") return KeyCode.Backspace;
            if (n == "up" || n == "arriba") return KeyCode.Up;
            if (n == "down" || n == "abajo") return KeyCode.Down;
            if (n == "left" || n == "izquierda") return KeyCode.Left;
            if (n == "right" || n == "derecha") return KeyCode.Right;
            if (n == "home" || n == "inicio") return KeyCode.Home;
            if (n == "end" || n == "fin") return KeyCode.End;
            if (n == "pageup" || n == "repág" || n == "pgup") return KeyCode.PageUp;
            if (n == "pagedown" || n == "avpág" || n == "pgdn") return KeyCode.PageDown;
            if (n.Length >= 2 && n.Length <= 3 && n[0] == 'f')
            {
                long k = 0;
                if (Convert.TryToInt64(n.Substring(1), out k) && k >= 1 && k <= 12) return (KeyCode)((int)KeyCode.F1 + (int)k - 1);
            }
            return KeyCode.None;
        }

        // ¿La tecla pulsada corresponde al atajo?
        public static func Matches(shortcut: string, e: UiEvent) -> bool
        {
            if (shortcut.Length == 0 || e.Kind != UiEventKind.KeyDown) return false;
            var parts = Text.Split(shortcut, "+");
            bool ctrl = false, shift = false;
            string key = parts[parts.Count - 1].Trim();
            if (key.Length == 0 && parts.Count >= 2) key = "+";
            for (int i = 0; i + 1 < parts.Count; i++)
            {
                string m = parts[i].Trim().ToLower();
                if (m == "ctrl" || m == "control" || m == "cmd") ctrl = true;
                else if (m == "shift" || m == "mayús" || m == "mayus") shift = true;
                else if (m.Length > 0) return false;  // Alt y otros no se pueden detectar todavía
            }
            if (ctrl != e.Ctrl || shift != e.Shift) return false;
            if (key.Length == 1)
            {
                byte c = key[0];
                if (c >= 'a' && c <= 'z') c = (byte)(c - 32);
                return e.KeyChar == (char)c;
            }
            KeyCode code = KeyFromName(key);
            return code != KeyCode.None && e.Key == code;
        }

        // ¿Lo usaría un cuadro de texto? (Ctrl+C/V/X/A o una tecla de edición sin Ctrl)
        public static func IsTextEditing(shortcut: string) -> bool
        {
            string s = Text.Replace(shortcut.ToLower(), " ", "");
            if (s == "ctrl+c" || s == "ctrl+v" || s == "ctrl+x" || s == "ctrl+a") return true;
            if (s.Contains("ctrl+")) return false;
            return !(s.Length >= 2 && s[0] == 'f' && s[1] >= '1' && s[1] <= '9');
        }
    }

    public memory_unsafe partial class Widget
    {
        var shortcut: string = "";

        // MenuItem: atajo de teclado ("Ctrl+S"); se muestra a la derecha del texto.
        public prop Shortcut: string { get => shortcut; set { shortcut = String.Copy(value); } }

        public prop IsSeparator: bool => Kind == WidgetKind.MenuItem && text == "-";

        // MenuItem: ¿abre un submenú?
        public prop HasSubmenu: bool
        {
            get
            {
                for (int i = 0; i < Children.Count; i++)
                    if (Children[i].Kind == WidgetKind.MenuItem && Children[i].Visible) return true;
                return false;
            }
        }

        // MenuItem / ContextMenu: añade un elemento (o "-" para un separador).
        public func AddMenuItem(text: string) -> Widget
        {
            Widget item = Widget.Create(WidgetKind.MenuItem, "", 0, 0, 0, 0);
            item.Text = text;
            Add(item);
            return item;
        }

        // MenuBar: posición x (relativa) y ancho de la cabecera del menú i.
        internal func MenuHeaderRect(index: int, out hx: float, out hw: float)
        {
            UiFont font = UiFont.Get(FontSize, Bold);
            float x = 4;
            hx = 0;
            hw = 0;
            for (int i = 0; i < Children.Count; i++)
            {
                Widget c = Children[i];
                if (c.Kind != WidgetKind.MenuItem || !c.Visible) continue;
                float w = font.Measure(c.Text) + 22;
                if (i == index)
                {
                    hx = x;
                    hw = w;
                    return;
                }
                x += w;
            }
        }

        // MenuBar: índice (en Children) del menú bajo el punto, o -1.
        internal func MenuHeaderAt(px: int, py: int) -> int
        {
            if (py < ScreenY || py >= ScreenY + ActualHeight) return -1;
            for (int i = 0; i < Children.Count; i++)
            {
                Widget c = Children[i];
                if (c.Kind != WidgetKind.MenuItem || !c.Visible) continue;
                float hx = 0, hw = 0;
                MenuHeaderRect(i, out hx, out hw);
                if (px >= ScreenX + hx && px < ScreenX + hx + hw) return i;
            }
            return -1;
        }

        func DrawMenuBar(c: Canvas, p: Palette, w: Window, font: UiFont, fx: float, fy: float, fw: float, fh: float, textColor: uint)
        {
            if (Background != 0) FillBackground(c, fx, fy, fw, fh, 0, 0);
            else c.FillRect(ScreenX, ScreenY, ActualWidth, ActualHeight, p.Surface);
            c.FillRect(ScreenX, ScreenY + ActualHeight - 1, ActualWidth, 1, BorderColor != 0 ? BorderColor : p.Border);
            int open = w.OpenBarIndex(this);
            int hot = w.Hot == this ? MenuHeaderAt(w.MouseX, w.MouseY) : -1;
            for (int i = 0; i < Children.Count; i++)
            {
                Widget m = Children[i];
                if (m.Kind != WidgetKind.MenuItem || !m.Visible) continue;
                float hx = 0, hw = 0;
                MenuHeaderRect(i, out hx, out hw);
                if (i == open) c.FillRoundRect(fx + hx, fy + 3, hw, fh - 7, 6, p.SurfacePressed);
                else if (i == hot && m.Enabled) c.FillRoundRect(fx + hx, fy + 3, hw, fh - 7, 6, p.SurfaceHover);
                float baseline = fy + (fh - 1 - font.LineHeight) / 2 + font.Ascent;
                c.Text(font, m.Text, fx + hx + 11, baseline, m.Enabled && Enabled ? textColor : p.TextMuted);
            }
        }
    }

    public partial class Window
    {
        var popups: List<MenuPopup> = new List<MenuPopup>();
        const float MenuRow = 30;
        const float MenuSeparator = 9;
        const float MenuPad = 5;

        public prop MenuOpen: bool => popups.Count > 0;

        public func CloseMenus()
        {
            if (popups.Count == 0) return;
            popups.Clear();
            dirty = true;
        }

        // Índice del menú abierto de esa barra, o -1.
        internal func OpenBarIndex(bar: Widget) -> int
        {
            if (popups.Count == 0 || popups[0].Bar != bar) return -1;
            return bar.Children.IndexOf(popups[0].Menu);
        }

        static func Selectable(item: Widget) -> bool => item.Kind == WidgetKind.MenuItem && item.Visible && !item.IsSeparator && item.Enabled;

        func MakePopup(menu: Widget, x: float, y: float) -> MenuPopup
        {
            MenuPopup pop = new MenuPopup();
            pop.Menu = menu;
            UiFont font = UiFont.Get(menu.FontSize, false);
            float w = 180, h = MenuPad * 2;
            for (int i = 0; i < menu.Children.Count; i++)
            {
                Widget it = menu.Children[i];
                if (it.Kind != WidgetKind.MenuItem || !it.Visible) continue;
                if (it.IsSeparator)
                {
                    h += MenuSeparator;
                    continue;
                }
                h += MenuRow;
                float iw = 36 + font.Measure(it.Text) + 28 + (it.Shortcut.Length > 0 ? font.Measure(it.Shortcut) + 24 : 0) + 18;
                if (iw > w) w = iw;
            }
            if (h < MenuPad * 2 + MenuRow) h = MenuPad * 2 + MenuRow;
            if (x + w > width - 2) x = width - 2 - w;
            if (x < 2) x = 2;
            if (y + h > height - 2) y = (float)Math.Max(2.0, (double)(height - 2 - h));
            pop.X = x;
            pop.Y = y;
            pop.W = w;
            pop.H = h;
            return pop;
        }

        // Fila y de un elemento del menú (relativa al menú) o -1 si no está visible.
        func RowTop(pop: MenuPopup, index: int) -> float
        {
            float y = MenuPad;
            for (int i = 0; i < pop.Menu.Children.Count; i++)
            {
                Widget it = pop.Menu.Children[i];
                if (it.Kind != WidgetKind.MenuItem || !it.Visible) continue;
                if (i == index) return y;
                y += it.IsSeparator ? MenuSeparator : MenuRow;
            }
            return -1;
        }

        // Elemento (índice en Children) del menú bajo el punto, o -1 (también en separadores).
        func RowAt(pop: MenuPopup, px: float, py: float) -> int
        {
            if (px < pop.X || px >= pop.X + pop.W || py < pop.Y || py >= pop.Y + pop.H) return -1;
            float y = pop.Y + MenuPad;
            for (int i = 0; i < pop.Menu.Children.Count; i++)
            {
                Widget it = pop.Menu.Children[i];
                if (it.Kind != WidgetKind.MenuItem || !it.Visible) continue;
                float rh = it.IsSeparator ? MenuSeparator : MenuRow;
                if (py >= y && py < y + rh) return it.IsSeparator ? -1 : i;
                y += rh;
            }
            return -1;
        }

        func PopupAt(px: float, py: float) -> int
        {
            for (int i = popups.Count - 1; i >= 0; i--)
            {
                MenuPopup p = popups[i];
                if (px >= p.X && px < p.X + p.W && py >= p.Y && py < p.Y + p.H) return i;
            }
            return -1;
        }

        func OpenBarMenu(bar: Widget, index: int, selectFirst: bool)
        {
            popups.Clear();
            if (index < 0 || index >= bar.Children.Count) return;
            Widget menu = bar.Children[index];
            if (!menu.Enabled || !menu.Visible) return;
            float hx = 0, hw = 0;
            bar.MenuHeaderRect(index, out hx, out hw);
            MenuPopup pop = MakePopup(menu, bar.ScreenX + hx, bar.ScreenY + bar.ActualHeight - 1);
            pop.Bar = bar;
            if (selectFirst) pop.Hot = NextSelectable(pop, -1, 1);
            popups.Add(pop);
            if (DropDown != null) CloseDropDown();
            dirty = true;
        }

        func OpenContextMenu(menu: Widget, x: int, y: int)
        {
            popups.Clear();
            MenuPopup pop = MakePopup(menu, x, y);
            popups.Add(pop);
            dirty = true;
        }

        // Abre el submenú del elemento 'index' del menú 'level' (cierra los más profundos).
        func OpenSubmenu(level: int, index: int, selectFirst: bool)
        {
            while (popups.Count > level + 1) popups.RemoveAt(popups.Count - 1);
            MenuPopup parent = popups[level];
            Widget item = parent.Menu.Children[index];
            if (!item.HasSubmenu || !item.Enabled) return;
            float ry = RowTop(parent, index);
            MenuPopup pop = MakePopup(item, parent.X + parent.W - 4, parent.Y + ry - MenuPad);
            if (pop.X < parent.X + parent.W - 8) pop.X = (float)Math.Max(2.0, (double)(parent.X - pop.W + 4));  // no cabe a la derecha
            if (selectFirst) pop.Hot = NextSelectable(pop, -1, 1);
            popups.Add(pop);
            dirty = true;
        }

        func NextSelectable(pop: MenuPopup, from: int, dir: int) -> int
        {
            int n = pop.Menu.Children.Count;
            if (n == 0) return -1;
            int i = from;
            for (int k = 0; k < n; k++)
            {
                i = i + dir;
                if (i < 0) i = n - 1;
                if (i >= n) i = 0;
                if (Selectable(pop.Menu.Children[i])) return i;
            }
            return -1;
        }

        func ActivateMenuItem(item: Widget)
        {
            CloseMenus();
            if (item == null || !Selectable(item)) return;
            item.RaiseClick();
        }

        func MenuMouse(e: UiEvent)
        {
            MouseX = e.X;
            MouseY = e.Y;
            int level = PopupAt(e.X, e.Y);
            Widget bar = popups.Count > 0 ? popups[0].Bar : null;
            int header = bar != null ? bar.MenuHeaderAt(e.X, e.Y) : -1;
            if (e.Kind == UiEventKind.Scroll) return;
            if (e.Kind == UiEventKind.MouseMove)
            {
                if (level >= 0)
                {
                    MenuPopup pop = popups[level];
                    int row = RowAt(pop, e.X, e.Y);
                    if (row != pop.Hot)
                    {
                        pop.Hot = row >= 0 && Selectable(pop.Menu.Children[row]) ? row : -1;
                        dirty = true;
                    }
                    if (pop.Hot >= 0 && pop.Menu.Children[pop.Hot].HasSubmenu)
                    {
                        bool already = popups.Count > level + 1 && popups[level + 1].Menu == pop.Menu.Children[pop.Hot];
                        if (!already) OpenSubmenu(level, pop.Hot, false);
                    }
                    else if (pop.Hot >= 0 && popups.Count > level + 1)
                    {
                        while (popups.Count > level + 1) popups.RemoveAt(popups.Count - 1);
                        dirty = true;
                    }
                }
                else if (header >= 0 && header != OpenBarIndex(bar)) OpenBarMenu(bar, header, false);
                if (native != null) native.SetCursor(CursorShape.Arrow);
                return;
            }
            if (e.Kind == UiEventKind.MouseDown)
            {
                if (level >= 0) return;  // se activa al soltar
                if (header >= 0)
                {
                    if (header == OpenBarIndex(bar)) CloseMenus();
                    else OpenBarMenu(bar, header, false);
                    return;
                }
                CloseMenus();
                return;
            }
            if (e.Kind == UiEventKind.MouseUp && level >= 0)
            {
                MenuPopup pop = popups[level];
                int row = RowAt(pop, e.X, e.Y);
                if (row < 0) return;
                Widget item = pop.Menu.Children[row];
                if (!Selectable(item)) return;
                if (item.HasSubmenu) OpenSubmenu(level, row, true);
                else ActivateMenuItem(item);
            }
        }

        func MenuKey(e: UiEvent)
        {
            MenuPopup top = popups[popups.Count - 1];
            Widget bar = popups[0].Bar;
            switch (e.Key)
            {
                case KeyCode.Down:
                    top.Hot = NextSelectable(top, top.Hot, 1);
                    break;
                case KeyCode.Up:
                    top.Hot = NextSelectable(top, top.Hot < 0 ? 0 : top.Hot, -1);
                    break;
                case KeyCode.Right:
                    if (top.Hot >= 0 && top.Menu.Children[top.Hot].HasSubmenu) OpenSubmenu(popups.Count - 1, top.Hot, true);
                    else if (bar != null) OpenBarMenu(bar, NextHeader(bar, OpenBarIndex(bar), 1), true);
                    break;
                case KeyCode.Left:
                    if (popups.Count > 1) popups.RemoveAt(popups.Count - 1);
                    else if (bar != null) OpenBarMenu(bar, NextHeader(bar, OpenBarIndex(bar), -1), true);
                    break;
                case KeyCode.Enter:
                case KeyCode.Space:
                    if (top.Hot >= 0)
                    {
                        Widget item = top.Menu.Children[top.Hot];
                        if (item.HasSubmenu) OpenSubmenu(popups.Count - 1, top.Hot, true);
                        else ActivateMenuItem(item);
                    }
                    break;
                case KeyCode.Escape:
                    popups.RemoveAt(popups.Count - 1);
                    break;
                case KeyCode.Tab:
                    CloseMenus();
                    break;
                default:
                    RunShortcut(e);
                    break;
            }
        }

        func NextHeader(bar: Widget, from: int, dir: int) -> int
        {
            int n = bar.Children.Count;
            int i = from;
            for (int k = 0; k < n; k++)
            {
                i = (i + dir + n) % n;
                Widget m = bar.Children[i];
                if (m.Kind == WidgetKind.MenuItem && m.Visible && m.Enabled) return i;
            }
            return from;
        }

        // Busca un elemento de menú con ese atajo (en las barras y en los menús contextuales).
        func RunShortcut(e: UiEvent) -> bool
        {
            if (e.Kind != UiEventKind.KeyDown || (e.Key == KeyCode.Other && e.KeyChar == 0 && !e.Ctrl)) return false;
            bool editing = Focused != null && Focused.Kind == WidgetKind.TextBox;
            Widget found = null;
            for (int i = 0; i < Children.Count && found == null; i++) found = FindShortcut(Children[i], e, editing, false);
            for (int i = 0; i < Components.Count && found == null; i++) found = FindShortcut(Components[i], e, editing, true);
            if (found == null) return false;
            ActivateMenuItem(found);
            return true;
        }

        static func FindShortcut(w: Widget, e: UiEvent, editing: bool, inMenu: bool) -> Widget
        {
            if (!w.Visible || !w.Enabled) return null;
            bool menu = inMenu || w.Kind == WidgetKind.MenuBar || w.Kind == WidgetKind.ContextMenu;
            if (menu && w.Kind == WidgetKind.MenuItem && w.Shortcut.Length > 0 && Shortcuts.Matches(w.Shortcut, e) &&
                !(editing && Shortcuts.IsTextEditing(w.Shortcut)))
                return w;
            for (int i = 0; i < w.Children.Count; i++)
            {
                Widget r = FindShortcut(w.Children[i], e, editing, menu);
                if (r != null) return r;
            }
            return null;
        }

        // Menús abiertos (encima de todo).
        func DrawPopups()
        {
            for (int k = 0; k < popups.Count; k++)
            {
                MenuPopup pop = popups[k];
                Widget menu = pop.Menu;
                UiFont font = UiFont.Get(menu.FontSize, false);
                float x = pop.X, y = pop.Y, w = pop.W, h = pop.H;
                canvas.FillRoundRect(x - 2, y, w + 4, h + 6, 11, Rgb.Alpha(0x000000, 0.22f));
                canvas.FillRoundRect(x, y, w, h, 8, palette.Surface);
                canvas.StrokeRoundRect(x, y, w, h, 8, 1, palette.BorderStrong);
                float ry = y + MenuPad;
                for (int i = 0; i < menu.Children.Count; i++)
                {
                    Widget it = menu.Children[i];
                    if (it.Kind != WidgetKind.MenuItem || !it.Visible) continue;
                    if (it.IsSeparator)
                    {
                        canvas.FillRect((int)(x + 10), (int)(ry + MenuSeparator / 2), (int)(w - 20), 1, palette.Border);
                        ry += MenuSeparator;
                        continue;
                    }
                    bool open = k + 1 < popups.Count && popups[k + 1].Menu == it;
                    if (i == pop.Hot || open) canvas.FillRoundRect(x + 4, ry, w - 8, MenuRow, 6, palette.SurfaceHover);
                    uint color = it.Enabled ? palette.Text : Rgb.Alpha(palette.TextMuted & 0xffffff, 0.7f);
                    float baseline = ry + (MenuRow - font.LineHeight) / 2 + font.Ascent;
                    float cx = x + 20, cy = ry + MenuRow / 2;
                    if (it.Checked)
                    {
                        canvas.Line(cx - 5, cy, cx - 1.5f, cy + 3.5f, 1.8f, color);
                        canvas.Line(cx - 1.5f, cy + 3.5f, cx + 5, cy - 4, 1.8f, color);
                    }
                    else if (it.Icon != null)
                    {
                        float iw = 0, ih = 0;
                        Widget.IconSize(it.Icon, 18, out iw, out ih);
                        canvas.DrawImage(it.Icon, cx - iw / 2, cy - ih / 2, iw, ih);
                    }
                    canvas.Text(font, it.Text, x + 36, baseline, color);
                    if (it.Shortcut.Length > 0)
                    {
                        float sw = font.Measure(it.Shortcut);
                        canvas.Text(font, it.Shortcut, x + w - 30 - sw, baseline, palette.TextMuted);
                    }
                    if (it.HasSubmenu)
                    {
                        float ax = x + w - 16;
                        canvas.Line(ax - 2, cy - 4, ax + 2, cy, 1.6f, palette.TextMuted);
                        canvas.Line(ax + 2, cy, ax - 2, cy + 4, 1.6f, palette.TextMuted);
                    }
                    ry += MenuRow;
                }
            }
        }
    }
}
