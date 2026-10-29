// =============================================================================
//  Bandeja de componentes no visuales del diseñador (.fstui).
//
//  <Sound> y <Music> (std.audio) no tienen posición en la ventana: el diseñador los
//  muestra como fichas en una fila bajo el lienzo (a la izquierda de la barra de zoom),
//  con botones para añadir otros. Al seleccionar una ficha, el panel de propiedades
//  edita Name, Source, Volume, Pan, Speed, Loop y AutoPlay.
// =============================================================================
using std.collections;
using std.io;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    public static class UiComponents
    {
        // Elementos del .fstui sin geometría (no se dibujan ni se mueven en el lienzo).
        public static bool IsComponent(string kind) => kind == "Sound" || kind == "Music";
    }

    public partial class Designer
    {
        const float TrayH = 30;
        const float AddW = 84;
        // Botones de añadir (calculados al dibujar; X < 0 = sin dibujar).
        float addSoundX = -1;
        float addMusicX = -1;

        float TrayY => Y + H - 12 - TrayH;   // misma fila que la barra de zoom
        float TrayRight => BarX - 10;

        // El control seleccionado tiene posición y tamaño (ni la ventana ni un componente).
        bool Placeable => selected != null && selected != root && !UiComponents.IsComponent(selected.Kind);

        void CollectComponents(UiNode n, List<UiNode> found)
        {
            for (int i = 0; i < n.Children.Count; i++)
            {
                UiNode c = n.Children[i];
                if (UiComponents.IsComponent(c.Kind)) found.Add(c);
                else CollectComponents(c, found);
            }
        }

        string UniqueComponentName(string kind)
        {
            string prefix = kind == "Music" ? "music" : "sound";
            for (int i = 1; ; i++)
            {
                string name = prefix + Convert.ToString(i);
                if (root.FindByName(name) == null) return name;
            }
        }

        // Primer archivo de audio junto al .fstui con esa extensión preferida (o "").
        string GuessSource(bool music)
        {
            string dir = Path.GetDirectoryName(Doc.FullPath);
            List<string> files = Directory.GetFiles(dir);
            string best = "";
            for (int pass = 0; pass < 2 && best.Length == 0; pass++)
                for (int i = 0; i < files.Count && best.Length == 0; i++)
                {
                    string f = files[i].ToLower();
                    bool preferred = music ? (f.EndsWith(".ogg") || f.EndsWith(".mp3")) : f.EndsWith(".wav");
                    bool audio = f.EndsWith(".ogg") || f.EndsWith(".mp3") || f.EndsWith(".wav");
                    if (pass == 0 ? preferred : audio) best = Path.GetFileName(files[i]);
                }
            return best.Length > 0 ? best : (music ? "musica.ogg" : "sonido.wav");
        }

        void AddComponent(string kind)
        {
            string before = Snapshot();
            UiNode n = new UiNode(kind);
            n.Set("Name", UniqueComponentName(kind));
            n.Set("Source", GuessSource(kind == "Music"));
            if (kind == "Music") n.Set("Loop", "true");
            n.Parent = root;
            root.Children.Add(n);
            selected = n;
            Commit(before);
        }

        // Quita la geometría que hayan podido recibir (pegar, duplicar) los componentes.
        static void StripGeometry(UiNode n)
        {
            if (UiComponents.IsComponent(n.Kind))
            {
                n.Remove("X");
                n.Remove("Y");
                n.Remove("Width");
                n.Remove("Height");
            }
            for (int i = 0; i < n.Children.Count; i++) StripGeometry(n.Children[i]);
        }

        List<PropDef> ComponentProps(List<PropDef> l, string kind)
        {
            Def(l, "Name", 7, "", "", "Control");
            Def(l, "Source", 0, "", "", "Audio");
            Def(l, "Volume", 2, "", "1", "Audio");
            Def(l, "Pan", 2, "", "0", "Audio");
            Def(l, "Speed", 2, "", "1", "Audio");
            Def(l, "Loop", 3, "", kind == "Music" ? "true" : "false", "Behavior");
            Def(l, "AutoPlay", 3, "", "false", "Behavior");
            return l;
        }

        // ¿El ratón está en la bandeja? Selecciona una ficha o añade un componente.
        bool TrayMouse(float px, float py, int clicks)
        {
            if (py < TrayY || py >= TrayY + TrayH || px < CanvasX || px >= TrayRight) return false;
            if (addSoundX >= 0 && px >= addSoundX && px < addSoundX + AddW)
            {
                AddComponent("Sound");
                return true;
            }
            if (addMusicX >= 0 && px >= addMusicX && px < addMusicX + AddW)
            {
                AddComponent("Music");
                return true;
            }
            List<UiNode> items = new List<UiNode>();
            CollectComponents(root, items);
            for (int i = 0; i < items.Count; i++)
            {
                UiNode n = items[i];
                if (n.SW > 0 && px >= n.SX && px < n.SX + n.SW)
                {
                    Select(n);
                    return true;
                }
            }
            return false;   // hueco de la bandeja: el lienzo lo trata como un clic normal
        }

        // Altavoz (Sound) o nota (Music).
        void DrawComponentIcon(Renderer r, string kind, float x, float cy, Color c)
        {
            if (kind == "Music")
            {
                r.RoundRect(x, cy + 1, 7, 6, 3, c);
                r.Rect(x + 5.5f, cy - 7, 1.5f, 11, c);
                r.Rect(x + 5.5f, cy - 7, 5, 1.5f, c);
                r.Rect(x + 9, cy - 7, 1.5f, 4, c);
                return;
            }
            r.Rect(x, cy - 2.5f, 3, 5, c);
            for (int k = 0; k < 4; k++) r.Rect(x + 3 + k, cy - 3 - k, 1, 6 + 2 * k, c);
            r.Rect(x + 9, cy - 2, 1.2f, 4, c);
            r.Rect(x + 11.5f, cy - 4, 1.2f, 8, c);
        }

        void DrawTray(Renderer r)
        {
            addSoundX = -1;
            addMusicX = -1;
            List<UiNode> items = new List<UiNode>();
            CollectComponents(root, items);
            float x = CanvasX + 12, y = TrayY, right = TrayRight;
            UiNode hoverNode = null;
            for (int i = 0; i < items.Count; i++)
            {
                UiNode n = items[i];
                string name = n.Get("Name");
                float w = r.TextWidth(r.UiSmall, name) + 40;
                n.SW = 0;
                if (x + w > right - 2 * (AddW + 6)) continue;   // no cabe: sigue en el esquema
                bool sel = n == selected;
                bool hot = mouseY >= y && mouseY < y + TrayH && mouseX >= x && mouseX < x + w;
                if (hot) hoverNode = n;
                r.Shadow(x, y, w, TrayH, 8, 10, Color.Hex(0x000000, 0.4f));
                r.RoundRect(x, y, w, TrayH, 8, hot ? Theme.Hover : Theme.Elevated);
                r.RoundBorder(x, y, w, TrayH, 8, sel ? 1.5f : 1, sel ? Accent : Theme.BorderStrong);
                Color ic = sel ? Accent : Theme.TextSecondary;
                DrawComponentIcon(r, n.Kind, x + 10, y + TrayH / 2, ic);
                r.Text(r.UiSmall, x + 28, y + (TrayH - 16) / 2, name, sel || hot ? Theme.White : Theme.Text);
                n.SX = x;
                n.SY = y;
                n.SW = w;
                n.SH = TrayH;
                x += w + 6;
            }
            // Botones para añadir
            for (int k = 0; k < 2; k++)
            {
                if (x + AddW > right) break;
                bool hot = mouseY >= y && mouseY < y + TrayH && mouseX >= x && mouseX < x + AddW;
                r.RoundRect(x, y, AddW, TrayH, 8, hot ? Theme.Hover : Color.Hex(0x000000, 0.25f));
                r.RoundBorder(x, y, AddW, TrayH, 8, 1, hot ? Theme.TextSecondary : Theme.Border);
                Color c = hot ? Theme.White : Theme.TextTertiary;
                r.Rect(x + 10, y + TrayH / 2 - 0.75f, 9, 1.5f, c);
                r.Rect(x + 13.75f, y + TrayH / 2 - 4.5f, 1.5f, 9, c);
                string label = L.T(k == 0 ? "Sound" : "Music");
                r.Text(r.UiSmall, x + 25, y + (TrayH - 16) / 2, label, c);
                if (hot)
                {
                    string tip = L.T(k == 0 ? "Add a sound (std.audio)" : "Add music (std.audio)");
                    DrawTrayTip(r, x, y, tip);
                }
                if (k == 0) addSoundX = x;
                else addMusicX = x;
                x += AddW + 6;
            }
            if (hoverNode != null)
            {
                string src = hoverNode.Get("Source");
                DrawTrayTip(r, hoverNode.SX, y, L.T(hoverNode.Kind) + " · " + (src.Length > 0 ? src : "?"));
            }
        }

        void DrawTrayTip(Renderer r, float x, float y, string tip)
        {
            float tw = r.TextWidth(r.UiSmall, tip) + 16;
            r.RoundRect(x, y - 30, tw, 24, 6, Theme.Elevated);
            r.RoundBorder(x, y - 30, tw, 24, 6, 1, Theme.BorderStrong);
            r.Text(r.UiSmall, x + 8, y - 25, tip, Theme.Text);
        }
    }
}
