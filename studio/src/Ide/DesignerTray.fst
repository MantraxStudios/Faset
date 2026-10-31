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
        public static func IsComponent(kind: string) -> bool => kind == "Sound" || kind == "Music" || kind == "Timer" || kind == "ContextMenu";
    }

    public partial class Designer
    {
        // El control seleccionado tiene posición y tamaño (ni la ventana ni un componente).
        prop Placeable: bool => selected != null && selected != root && !UiComponents.IsComponent(selected.Kind);

        func CollectComponents(n: UiNode, found: List<UiNode>)
        {
            for (int i = 0; i < n.Children.Count; i++)
            {
                UiNode c = n.Children[i];
                if (UiComponents.IsComponent(c.Kind)) found.Add(c);
                else CollectComponents(c, found);
            }
        }

        func UniqueComponentName(kind: string) -> string
        {
            string prefix = kind == "Music" ? "music" : "sound";
            for (int i = 1; ; i++)
            {
                string name = prefix + Convert.ToString(i);
                if (root.FindByName(name) == null) return name;
            }
        }

        // Primer archivo de audio junto al .fstui con esa extensión preferida (o "").
        func GuessSource(music: bool) -> string
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

        func AddComponent(kind: string)
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
        static func StripGeometry(n: UiNode)
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

        func ComponentProps(l: List<PropDef>, kind: string) -> List<PropDef>
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
        func DrawComponentIcon(r: Renderer, kind: string, x: float, cy: float, c: Color)
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
