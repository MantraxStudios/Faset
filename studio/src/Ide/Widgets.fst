// =============================================================================
//  Componentes de interfaz reutilizables: menús desplegables y campos de texto.
// =============================================================================
using std.collections;
using std.text;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    public struct MenuItem
    {
        public var Label: string;      // vista (texto ya traducido)
        public var Shortcut: string;   // vista ("" si no hay)
        public var Action: int;        // 0 = separador
        public var Enabled: bool;
        public var Danger: bool;       // acción destructiva (se muestra en rojo)
    }

    // Menú desplegable (barra de menús o menú contextual).
    public class Menu
    {
        public var Items: List<MenuItem> = new List<MenuItem>();
        public var X: float;
        public var Y: float;
        public var W: float;
        public var Hover: int = -1;
        public var Owner: int = -1;   // índice del menú de la barra que lo abrió (-1: contextual)

        const float ItemHeight = 28;
        const float SeparatorHeight = 9;

        deinit { delete Items; }

        public func Add(label: string, shortcut: string, action: int, enabled: bool)
        {
            MenuItem m = new MenuItem();
            m.Label = label;
            m.Shortcut = shortcut;
            m.Action = action;
            m.Enabled = enabled;
            Items.Add(m);
        }

        public func AddDanger(label: string, shortcut: string, action: int)
        {
            Add(label, shortcut, action, true);
            MenuItem m = Items.Pop();
            m.Danger = true;
            Items.Add(m);
        }

        public func Separator() { Add("", "", 0, false); }

        func ItemY(i: int) -> float
        {
            float y = Y + 6;
            for (int k = 0; k < i; k++) y += Items[k].Action == 0 ? SeparatorHeight : ItemHeight;
            return y;
        }

        public prop Height: float => ItemY(Items.Count) - Y + 6;

        public func Layout(r: Renderer, screenW: float, screenH: float)
        {
            float w = 220;
            for (int i = 0; i < Items.Count; i++)
            {
                MenuItem m = Items[i];
                float need = r.TextWidth(r.Ui, m.Label) + r.TextWidth(r.UiSmall, m.Shortcut) + 70;
                if (need > w) w = need;
            }
            W = w;
            if (X + W > screenW - 6) X = screenW - 6 - W;
            if (Y + Height > screenH - 6) Y = (float)Math.Max(6.0, screenH - 6 - Height);
        }

        public func ItemAt(px: float, py: float) -> int
        {
            if (px < X || px >= X + W) return -1;
            for (int i = 0; i < Items.Count; i++)
            {
                float y = ItemY(i);
                float h = Items[i].Action == 0 ? SeparatorHeight : ItemHeight;
                if (py >= y && py < y + h) return Items[i].Action != 0 && Items[i].Enabled ? i : -1;
            }
            return -1;
        }

        public func Contains(px: float, py: float) -> bool => px >= X && px < X + W && py >= Y && py < Y + Height;

        public func Move(delta: int)
        {
            if (Items.Count == 0) return;
            int i = Hover;
            for (int n = 0; n < Items.Count; n++)
            {
                i = (i + delta + Items.Count) % Items.Count;
                if (Items[i].Action != 0 && Items[i].Enabled)
                {
                    Hover = i;
                    return;
                }
            }
        }

        public func Draw(r: Renderer)
        {
            float h = Height;
            r.Shadow(X, Y, W, h, 10, 20, Theme.Shadow);
            r.RoundRect(X, Y, W, h, 10, Theme.Elevated);
            r.RoundBorder(X, Y, W, h, 10, 1, Theme.BorderStrong);
            for (int i = 0; i < Items.Count; i++)
            {
                MenuItem m = Items[i];
                float y = ItemY(i);
                if (m.Action == 0)
                {
                    r.Rect(X + 10, y + 4, W - 20, 1, Theme.Border);
                    continue;
                }
                if (i == Hover) r.RoundRect(X + 5, y, W - 10, ItemHeight, 6, m.Danger ? Color.Hex(0xf04f4f, 0.16f) : Theme.Active);
                Color fg = !m.Enabled ? Theme.TextDisabled : (m.Danger ? Theme.Error : (i == Hover ? Theme.White : Theme.Text));
                r.Text(r.Ui, X + 16, y + 5, m.Label, fg);
                if (m.Shortcut.Length > 0)
                {
                    float sw = r.TextWidth(r.UiSmall, m.Shortcut);
                    r.Text(r.UiSmall, X + W - 16 - sw, y + 7, m.Shortcut, Theme.TextTertiary);
                }
            }
        }
    }

    // Campo de texto de una línea (el cursor siempre al final).
    public class TextField
    {
        public var Value: StringBuilder = new StringBuilder();
        public var Focused: bool;
        public var X: float;
        public var Y: float;
        public var W: float;
        public const float Height = 34;

        deinit { delete Value; }

        public prop Text: string => Value.View();

        public func Set(text: string)
        {
            string copy = String.Copy(text);
            Value.Clear();
            Value.Append(copy);
            String.Free(copy);
        }

        public func Contains(px: float, py: float) -> bool => px >= X && px < X + W && py >= Y && py < Y + Height;

        // Teclas de edición; devuelve true si cambió el texto.
        public func Key(e: Event) -> bool
        {
            if (e.Key == Keys.BackSpace)
            {
                string v = Value.View();
                if (v.Length == 0) return false;
                int cut = v.Length - 1;
                while (cut > 0 && (v[cut] & 0xC0) == 0x80) cut--;
                string keep = String.Copy(v.Substring(0, cut));
                Value.Clear();
                Value.Append(keep);
                String.Free(keep);
                return true;
            }
            if (e.Char >= 0x20 && !e.Ctrl)
            {
                Value.Append(e.Char);
                return true;
            }
            return false;
        }

        public func Draw(r: Renderer, x: float, y: float, w: float, placeholder: string)
        {
            X = x;
            Y = y;
            W = w;
            r.RoundRect(x, y, w, Height, 8, Theme.Base);
            r.RoundBorder(x, y, w, Height, 8, 1, Focused ? Theme.TextSecondary : Theme.BorderStrong);
            r.PushClip(x + 8, y, w - 16, Height);
            string v = Value.View();
            float tw = r.TextWidth(r.Ui, v);
            float tx = x + 12;
            if (tw > w - 30) tx = x + w - 18 - tw;  // mantener visible el final
            if (v.Length == 0 && !Focused) r.Text(r.Ui, x + 12, y + 8, placeholder, Theme.TextTertiary);
            float end = r.Text(r.Ui, tx, y + 8, v, Theme.White);
            if (Focused && ((Environment.TickCount64() / 530) % 2) == 0) r.RoundRect(end + 1, y + 8, 2, 18, 1, Theme.Caret);
            r.PopClip();
        }
    }
}
