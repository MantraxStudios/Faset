// =============================================================================
//  Bandeja de componentes no visuales del diseñador (.fstui).
//
//  <Sound> y <Music> (std.audio), <Timer> y <ContextMenu> no tienen posición en la ventana:
//  el diseñador los muestra como fichas en la bandeja bajo la ventana (DrawTray) y se
//  añaden desde la caja de herramientas. Aquí están las utilidades de Sound y Music.
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
        public static bool IsComponent(string kind) => kind == "Sound" || kind == "Music" || kind == "Timer" || kind == "ContextMenu";
    }

    public partial class Designer
    {
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
    }
}
