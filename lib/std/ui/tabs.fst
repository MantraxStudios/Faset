// =============================================================================
//  std.ui — TabControl: páginas con pestañas. Cada TabPage es un contenedor que
//  ocupa el área bajo las pestañas; solo se ve la página elegida.
//
//      <TabControl Name="tabs" X="16" Y="16" Width="400" Height="300" SelectedChanged="OnTab">
//        <TabPage Text="General"> ...controles... </TabPage>
//        <TabPage Text="Avanzado"> ... </TabPage>
//      </TabControl>
//
//  SelectedIndex / SelectedPage eligen la página (asignarlos no lanza el evento);
//  el usuario cambia con un clic, con ←/→ si el control tiene el foco o con
//  Ctrl+Tab / Ctrl+Shift+Tab desde cualquier control de la página.
// =============================================================================
namespace std.ui
{
    public memory_unsafe partial class Widget
    {
        public const int TabHeaderHeight = 36;

        // TabControl: número de páginas, página i y página elegida.
        public prop PageCount: int
        {
            get
            {
                int n = 0;
                for (int i = 0; i < Children.Count; i++)
                    if (Children[i].Kind == WidgetKind.TabPage) n++;
                return n;
            }
        }

        public func Page(index: int) -> Widget
        {
            int n = 0;
            for (int i = 0; i < Children.Count; i++)
                if (Children[i].Kind == WidgetKind.TabPage)
                {
                    if (n == index) return Children[i];
                    n++;
                }
            return null;
        }

        public prop SelectedPage: Widget
        {
            get => Page(selectedIndex);
            set
            {
                int n = 0;
                for (int i = 0; i < Children.Count; i++)
                    if (Children[i].Kind == WidgetKind.TabPage)
                    {
                        if (Children[i] == value) SelectedIndex = n;
                        n++;
                    }
            }
        }

        // TabControl: añade una página con ese título y la devuelve.
        public func AddPage(title: string) -> Widget
        {
            Widget page = Widget.Create(WidgetKind.TabPage, "", 0, 0, width, height - TabHeaderHeight);
            page.Text = title;
            Add(page);
            if (selectedIndex < 0) selectedIndex = 0;
            return page;
        }

        // Cambia de página por interacción del usuario (lanza SelectedChanged si cambia).
        internal func SelectTab(index: int, wrap: bool)
        {
            int n = PageCount;
            if (n == 0) return;
            if (wrap) index = (index % n + n) % n;
            if (index < 0 || index >= n || index == selectedIndex) return;
            Widget page = Page(index);
            if (!page.Enabled) return;
            selectedIndex = index;
            // Si el foco estaba en la página que se oculta, pasa a las pestañas.
            if (Owner != null && Owner.Focused != null && Owner.Focused != this && IsAncestorOf(Owner.Focused)) Owner.Focus(this);
            Invalidate();
            RaiseChanged();
        }

        internal func IsAncestorOf(w: Widget) -> bool
        {
            for (Widget p = w; p != null; p = p.Parent)
                if (p == this) return true;
            return false;
        }

        // Las páginas ocupan el área bajo las pestañas y solo se ve la elegida.
        func LayoutPages()
        {
            int n = PageCount;
            if (selectedIndex < 0 && n > 0) selectedIndex = 0;
            if (selectedIndex >= n) selectedIndex = n - 1;
            int k = 0;
            for (int i = 0; i < Children.Count; i++)
            {
                Widget c = Children[i];
                if (c.Kind == WidgetKind.TabPage)
                {
                    c.x = 1;
                    c.y = TabHeaderHeight;
                    c.width = width - 2;
                    c.height = height - TabHeaderHeight - 1;
                    c.Anchor = Anchor.Left | Anchor.Top | Anchor.Right | Anchor.Bottom;
                    c.Visible = k == selectedIndex;
                    k++;
                }
                c.Layout(ScreenX, ScreenY, ActualWidth - width, ActualHeight - height);
            }
        }

        // Posición x (relativa) y ancho de la pestaña i.
        func TabRect(index: int, out tx: float, out tw: float)
        {
            UiFont font = UiFont.Get(FontSize, Bold);
            float x = 6;
            tx = 0;
            tw = 0;
            int n = 0;
            for (int i = 0; i < Children.Count; i++)
            {
                Widget c = Children[i];
                if (c.Kind != WidgetKind.TabPage) continue;
                float w = font.Measure(c.Text) + 28;
                if (w < 56) w = 56;
                if (n == index)
                {
                    tx = x;
                    tw = w;
                    return;
                }
                x += w + 2;
                n++;
            }
        }

        // Pestaña bajo el punto (coordenadas de la ventana) o -1.
        public func TabAt(px: int, py: int) -> int
        {
            if (py < ScreenY || py >= ScreenY + TabHeaderHeight || px < ScreenX || px >= ScreenX + ActualWidth) return -1;
            int n = PageCount;
            for (int i = 0; i < n; i++)
            {
                float tx = 0, tw = 0;
                TabRect(i, out tx, out tw);
                if (px >= ScreenX + tx && px < ScreenX + tx + tw) return i;
            }
            return -1;
        }

        internal func TabMouseDown(px: int, py: int)
        {
            int i = TabAt(px, py);
            if (i >= 0) SelectTab(i, false);
        }

        func DrawTabControl(c: Canvas, p: Palette, w: Window, font: UiFont, fx: float, fy: float, fw: float, fh: float, focused: bool,
                            textColor: uint, accent: uint)
        {
            float r = CornerRadius >= 0 ? CornerRadius : 10;
            uint border = BorderColor != 0 ? BorderColor : p.Border;
            if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, 0);
            else c.FillRoundRect(fx, fy, fw, fh, r, p.Surface);
            c.StrokeRoundRect(fx, fy, fw, fh, r, 1, border);
            c.FillRect(ScreenX + 1, ScreenY + TabHeaderHeight - 1, ActualWidth - 2, 1, border);
            int hotTab = w.Hot == this ? TabAt(w.MouseX, w.MouseY) : -1;
            c.Clip(ScreenX + 1, ScreenY, ActualWidth - 2, TabHeaderHeight);
            int n = PageCount;
            for (int i = 0; i < n; i++)
            {
                Widget page = Page(i);
                float tx = 0, tw = 0;
                TabRect(i, out tx, out tw);
                float x = fx + tx;
                bool sel = i == selectedIndex;
                if (!sel && i == hotTab && page.Enabled) c.FillRoundRect(x + 2, fy + 6, tw - 4, TabHeaderHeight - 13, 6, p.SurfaceHover);
                uint color = !page.Enabled || !Enabled ? Rgb.Alpha(p.TextMuted & 0xffffff, 0.6f) : (sel ? textColor : p.TextMuted);
                float baseline = fy + (TabHeaderHeight - font.LineHeight) / 2 + font.Ascent - 1;
                c.Text(font, page.Text, x + (tw - font.Measure(page.Text)) / 2, baseline, color);
                if (sel)
                {
                    c.FillRoundRect(x + 10, fy + TabHeaderHeight - 3, tw - 20, 3, 1.5f, Enabled ? accent : p.TextMuted);
                    if (focused && w.FocusVisible) c.StrokeRoundRect(x + 2, fy + 5, tw - 4, TabHeaderHeight - 11, 6, 2, p.Focus);
                }
            }
            c.ResetClip();
        }
    }

    public partial class Window
    {
        // Ctrl+Tab: siguiente página del TabControl que contiene el foco (o del primero de la ventana).
        func CycleTabs(back: bool)
        {
            Widget tabs = null;
            for (Widget p = Focused; p != null && tabs == null; p = p.Parent)
                if (p.Kind == WidgetKind.TabControl) tabs = p;
            if (tabs == null)
                for (int i = 0; i < Children.Count && tabs == null; i++) tabs = FirstOfKind(Children[i], WidgetKind.TabControl);
            if (tabs == null) return;
            tabs.SelectTab(tabs.SelectedIndex + (back ? -1 : 1), true);
        }

        static func FirstOfKind(w: Widget, kind: WidgetKind) -> Widget
        {
            if (!w.Visible) return null;
            if (w.Kind == kind) return w;
            for (int i = 0; i < w.Children.Count; i++)
            {
                Widget r = FirstOfKind(w.Children[i], kind);
                if (r != null) return r;
            }
            return null;
        }
    }
}
