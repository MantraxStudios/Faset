// =============================================================================
//  FasetStudio: la aplicación. Disposición de paneles, pestañas, vista dividida,
//  barra de herramientas, compilación/ejecución, lista de errores e IntelliSense.
// =============================================================================
using std.collections;
using std.io;
using std.json;
using std.os;
using std.text;
using std.time;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    class EditorGroup
    {
        public List<EditorView> Tabs = new List<EditorView>();
        public int Active = -1;
        public float X;
        public float Y;
        public float W;
        public float H;

        public EditorView Current => Active >= 0 && Active < Tabs.Count ? Tabs[Active] : null;

        ~EditorGroup()
        {
            for (int i = 0; i < Tabs.Count; i++) delete Tabs[i];
            delete Tabs;
        }
    }

    struct HitBox
    {
        public float X;
        public float Y;
        public float W;
        public float H;
        public int Id;     // acción o índice
        public int Group;  // grupo de pestañas (pestañas) o -1
        public bool Close; // botón de cerrar pestaña

        public bool Contains(float px, float py) => px >= X && px < X + W && py >= Y && py < Y + H;
    }

    struct Problem
    {
        public string Path;     // copia propia
        public string File;     // vista (nombre)
        public int Line;
        public int Col;
        public int Severity;
        public string Message;  // copia propia
    }

    public enum Overlay
    {
        None, QuickOpen, Find, GoToLine, NewFile, NewFolder, Rename, ConfirmQuit, ConfirmCloseTab,
        ConfirmDelete, ConfirmCloseProject, ConfirmDeleteProject, NewProject, OpenFolder, ProjectProperties, About
    }

    public class App
    {
        // Acciones de la barra de herramientas
        const int ActSave = 1;
        const int ActBuild = 2;
        const int ActRun = 3;
        const int ActStop = 4;
        const int ActSplit = 5;
        const int ActQuickOpen = 6;
        const int ActNewFile = 7;
        const int ActConfig = 8;
        const int ActPanelOutput = 20;
        const int ActPanelErrors = 21;
        const int ActConfirmA = 30;
        const int ActConfirmB = 31;
        const int ActConfirmC = 32;

        const int ActConfigDebug = 9;
        const int ActConfigRelease = 10;
        const int ActClearOutput = 22;
        const int ActLanguage = 40;

        const float TitleHeight = 48;
        const float TabHeight = 42;
        const float StatusHeight = 30;
        const float PanelHeaderHeight = 38;
        const float Gap = 6;
        const float CardRadius = 10;

        Renderer r;
        Window win;
        int forcedClicks;   // clics simulados (--script)
        Highlighter hl = new Highlighter();
        Analyzer analyzer;
        Explorer explorer = new Explorer();
        List<Document> docs = new List<Document>();
        List<EditorGroup> groups = new List<EditorGroup>();
        int activeGroup;
        List<HitBox> hits = new List<HitBox>();

        // Paneles acoplables: Explorador (0), Salida (1), Problemas (2) y Dispositivo (3). Cada uno está en un lado
        // (0 izquierda, 1 derecha, 2 abajo); los del mismo lado se muestran como pestañas.
        const int ActTool = 50;   // 50..53: pestañas de los paneles
        const int ToolCount = 4;
        const int ActTarget = 41; // selector de destino (este equipo / Android)

        // Android: dispositivos, emulador y vista del dispositivo (panel 3).
        AndroidTools android = new AndroidTools();
        string buildTarget = "native";   // "native" o "android" (vista literal)
        List<int> toolSide = new List<int>();
        List<bool> toolShown = new List<bool>();
        List<int> sideActive = new List<int>();     // panel visible en cada lado (-1: lado vacío)
        List<float> toolRect = new List<float>();   // x, y, w, h de cada panel en el último dibujo (w = 0: no se ve)
        float leftWidth = 270;
        float rightWidth = 320;
        float bottomHeight = 210;
        float splitRatio = 0.5f;
        int dragSplitter;  // 1 lado izquierdo, 2 lado inferior, 3 división de editores, 4 lado derecho
        int outputScroll;
        int problemsScroll;
        float editorsX;
        float editorsW;
        float editorsBottom;
        float bottomX;
        float bottomW;
        float splitLeftX;
        float splitRightX;
        float splitBottomY;
        float splitGroupsX;
        // Arrastre de una pestaña de panel para acoplarlo en otro lado.
        int dockTool = -1;
        bool dockDragging;
        float dockPressX;
        float dockPressY;
        int dockTarget = -1;
        int contextTool = -1;
        float overlayInputX;
        float overlayInputY;
        float overlayInputW;

        // Gestión de proyectos y archivos
        public bool HubMode;
        Menu menu;
        string targetPath = "";     // archivo o carpeta sobre el que actúa un diálogo (copia propia)
        string targetFolder = "";   // carpeta donde crear archivos (copia propia)
        bool targetIsDir;
        TextField fieldName = new TextField();
        TextField fieldLocation = new TextField();
        TextField fieldExtra = new TextField();
        TextField fieldExtra2 = new TextField();
        int projectTemplate;
        string browsePath = "";
        List<DirEntry> browseEntries;
        int browseScroll;
        ProjectFile props;
        int pressRow = -1;          // fila del explorador pulsada (clic o arrastre)
        float pressX;
        float pressY;
        bool draggingFile;
        const int ActNewProject = 50;
        const int ActDesignView = 60;   // + índice del grupo
        const int ActCodeView = 70;     // + índice del grupo
        const int ActOpenFolder = 51;
        StringBuilder output = new StringBuilder();
        List<Problem> problems = new List<Problem>();

        // Procesos (compilar / ejecutar)
        ChildProcess process;
        bool processIsRun;
        long processStart;

        // IntelliSense
        bool completionOpen;
        List<CompletionItem> completions;
        List<int> filtered = new List<int>();
        int completionSel;
        TextPos completionStart;
        long lastEditMs;
        bool analysisPending;
        float mouseX;
        float mouseY;
        long mouseMoveMs;
        string hoverText = "";
        bool hoverOwned;
        float hoverX;
        float hoverY;

        // Diálogos
        Overlay overlay = Overlay.None;
        StringBuilder overlayInput = new StringBuilder();
        List<string> quickFiles = new List<string>();
        List<int> quickFiltered = new List<int>();
        int overlaySel;
        string findText = "";
        int pendingCloseGroup = -1;
        int pendingCloseTab = -1;

        string status = "";
        long statusMs;
        string projectFile = "";   // ruta del .fstproj ("" si no hay)
        string projectName = "";
        string rootFolder = "";
        string configuration = "Debug";
        bool needsRedraw = true;
        long lastBlink;
        int hoverButton = -1;
        public bool QuitRequested;

        // ------------------------------------------------------------------ arranque

        public bool Init(Renderer renderer, Window window, string fasetPath)
        {
            r = renderer;
            win = window;
            analyzer = new Analyzer(fasetPath);
            groups.Add(new EditorGroup());
            LoadLayout();
            android.Compiler = analyzer.Compiler;
            SetStatus(analyzer.Available ? L.T("Ready") : L.T("Compiler 'faset' not found: IntelliSense and builds are disabled"));
            return true;
        }

        // Libera recursos externos (archivos temporales del análisis, proceso en marcha).
        public void Shutdown()
        {
            if (process != null && process.IsRunning) process.Kill();
            delete analyzer;
            analyzer = null;
        }

        // Abre una carpeta, un .fstproj o un archivo .fst.
        public void OpenWorkspace(string target)
        {
            if (explorer.IsLoaded) CloseWorkspaceNow();
            HubMode = false;
            projectFile = "";
            projectName = "";
            string full = Path.GetFullPath(target);
            string folder = full;
            string fileToOpen = "";
            if (File.Exists(full))
            {
                folder = String.Copy(Path.GetDirectoryName(full));
                if (!full.EndsWith(".fstproj")) fileToOpen = full;
            }
            // Buscar el proyecto en la carpeta.
            List<DirEntry> entries = Directory.GetEntries(folder);
            for (int i = 0; i < entries.Count; i++)
                if (!entries[i].IsDirectory && entries[i].Name.EndsWith(".fstproj"))
                {
                    projectFile = Path.Combine(folder, entries[i].Name);
                    projectName = String.Copy(Path.GetFileNameWithoutExtension(entries[i].Name));
                    break;
                }
            Directory.FreeEntries(entries);
            rootFolder = folder;
            explorer.Load(folder);
            if (fileToOpen.Length > 0) OpenFile(fileToOpen);
            else if (projectFile.Length > 0)
            {
                // Abrir el primer .fst del proyecto (Program.fst / Main.fst si existe).
                List<string> files = new List<string>();
                explorer.CollectFiles(files);
                string pick = "";
                for (int i = 0; i < files.Count && pick.Length == 0; i++)
                    if (files[i].EndsWith("Program.fst") || files[i].EndsWith("Main.fst")) pick = files[i];
                for (int i = 0; i < files.Count && pick.Length == 0; i++)
                    if (files[i].EndsWith(".fst")) pick = files[i];
                if (pick.Length > 0) OpenFile(pick);
                delete files;
            }
            // Los proyectos con <TargetPlatform>android</TargetPlatform> se compilan para Android.
            buildTarget = "native";
            string projText;
            if (projectFile.Length > 0 && File.TryReadAllText(projectFile, out projText))
            {
                if (projText.Contains("<TargetPlatform>android</TargetPlatform>")) SetBuildTarget("android");
                String.Free(projText);
            }
            AddRecent(folder);
            UpdateTitle();
            SetStatus(analyzer.Available ? L.T("Ready") : L.T("Compiler 'faset' not found: IntelliSense and builds are disabled"));
        }

        void SetStatus(string text)
        {
            if (status.Length > 0) String.Free(status);
            status = String.Copy(text);
            statusMs = Environment.TickCount64();
            needsRedraw = true;
        }

        EditorGroup Group => groups[activeGroup];
        EditorView Editor => groups[activeGroup].Current;

        // ------------------------------------------------------------------ documentos

        Document FindDoc(string path)
        {
            for (int i = 0; i < docs.Count; i++)
                if (docs[i].FullPath == path) return docs[i];
            return null;
        }

        public EditorView OpenFile(string path)
        {
            string full = Path.GetFullPath(path);
            Document doc = FindDoc(full);
            if (doc == null)
            {
                doc = Document.Open(full);
                if (doc == null)
                {
                    SetStatus(L.T("Could not open the file"));
                    String.Free(full);
                    return null;
                }
                docs.Add(doc);
                analysisPending = true;
                lastEditMs = 0;
            }
            String.Free(full);
            EditorGroup g = Group;
            for (int i = 0; i < g.Tabs.Count; i++)
                if (g.Tabs[i].Doc == doc)
                {
                    ActivateTab(activeGroup, i);
                    return g.Tabs[i];
                }
            EditorView view = new EditorView(doc);
            if (doc.FullPath.EndsWith(".fstui"))
            {
                view.Designer = new Designer(doc);
                view.DesignMode = true;
            }
            g.Tabs.Add(view);
            ActivateTab(activeGroup, g.Tabs.Count - 1);
            explorer.Select(doc.FullPath);
            return view;
        }

        void ActivateTab(int group, int index)
        {
            for (int k = 0; k < groups.Count; k++)
                for (int i = 0; i < groups[k].Tabs.Count; i++) groups[k].Tabs[i].Focused = false;
            activeGroup = group;
            groups[group].Active = index;
            EditorView v = groups[group].Current;
            if (v != null)
            {
                v.Focused = true;
                v.CaretTime = Environment.TickCount64();
                explorer.Select(v.Doc.FullPath);
            }
            CloseCompletion();
        }

        void CloseTab(int group, int index, bool force)
        {
            EditorGroup g = groups[group];
            EditorView v = g.Tabs[index];
            if (!force && v.Doc.Modified && CountViews(v.Doc) == 1)
            {
                pendingCloseGroup = group;
                pendingCloseTab = index;
                OpenOverlay(Overlay.ConfirmCloseTab);
                return;
            }
            Document doc = v.Doc;
            g.Tabs.RemoveAt(index);
            delete v;
            if (CountViews(doc) == 0)
            {
                docs.Remove(doc);
                delete doc;
            }
            if (g.Active >= g.Tabs.Count) g.Active = g.Tabs.Count - 1;
            // Cerrar el grupo derecho si se queda vacío.
            if (g.Tabs.Count == 0 && groups.Count > 1)
            {
                groups.RemoveAt(group);
                delete g;
                activeGroup = 0;
            }
            ActivateTab(activeGroup, groups[activeGroup].Active);
        }

        int CountViews(Document doc)
        {
            int n = 0;
            for (int k = 0; k < groups.Count; k++)
                for (int i = 0; i < groups[k].Tabs.Count; i++)
                    if (groups[k].Tabs[i].Doc == doc) n++;
            return n;
        }

        void SaveCurrent()
        {
            EditorView v = Editor;
            if (v == null) return;
            if (v.Doc.Save()) SetStatus(L.T("Saved"));
            else SetStatus(L.T("Could not save the file"));
        }

        int SaveAll()
        {
            int saved = 0;
            for (int i = 0; i < docs.Count; i++)
                if (docs[i].Modified && docs[i].Save()) saved++;
            return saved;
        }

        bool AnyModified()
        {
            for (int i = 0; i < docs.Count; i++)
                if (docs[i].Modified) return true;
            return false;
        }

        void ToggleSplit()
        {
            if (groups.Count == 2)
            {
                // Unir: mover las pestañas del grupo derecho al izquierdo.
                EditorGroup right = groups[1];
                for (int i = 0; i < right.Tabs.Count; i++)
                {
                    EditorView v = right.Tabs[i];
                    bool dup = false;
                    for (int k = 0; k < groups[0].Tabs.Count; k++)
                        if (groups[0].Tabs[k].Doc == v.Doc) dup = true;
                    if (dup) delete v;
                    else groups[0].Tabs.Add(v);
                }
                right.Tabs.Clear();
                groups.RemoveAt(1);
                delete right;
                ActivateTab(0, groups[0].Active < 0 ? 0 : groups[0].Active);
                return;
            }
            EditorView cur = Editor;
            EditorGroup g = new EditorGroup();
            groups.Add(g);
            if (cur != null)
            {
                EditorView copy = new EditorView(cur.Doc);
                copy.Cursor = cur.Cursor;
                copy.Anchor = cur.Cursor;
                copy.ScrollLine = cur.ScrollLine;
                g.Tabs.Add(copy);
                ActivateTab(1, 0);
            }
        }

        // ------------------------------------------------------------------ IntelliSense

        void RunAnalysis()
        {
            analysisPending = false;
            EditorView v = Editor;
            if (v == null || !analyzer.Available) return;
            JsonValue result = analyzer.Run(v.Doc, docs, "", false);
            if (result == null)
            {
                SetStatus(L.T("Analysis failed"));
                return;
            }
            analyzer.Apply(result, docs);
            // Lista de errores: todos los diagnósticos, también de archivos no abiertos.
            ClearProblems();
            JsonValue diags = result.Get("diagnostics");
            for (int i = 0; diags != null && i < diags.Count; i++)
            {
                JsonValue d = diags.At(i);
                Problem p = new Problem();
                p.Path = String.Copy(d.GetString("path"));
                p.File = Path.GetFileName(p.Path);
                p.Line = d.GetInt("line") - 1;
                p.Col = d.GetInt("col") - 1;
                p.Severity = d.GetInt("severity");
                p.Message = String.Copy(d.GetString("message"));
                problems.Add(p);
            }
            delete result;
            needsRedraw = true;
        }

        void ClearProblems()
        {
            for (int i = 0; i < problems.Count; i++)
            {
                String.Free(problems[i].Path);
                String.Free(problems[i].Message);
            }
            problems.Clear();
        }

        int ErrorCount()
        {
            int n = 0;
            for (int i = 0; i < problems.Count; i++)
                if (problems[i].Severity == 1) n++;
            return n;
        }

        void RequestCompletion()
        {
            EditorView v = Editor;
            if (v == null || !analyzer.Available) return;
            TextPos start = v.WordStart(v.Cursor);
            TextPos end = v.WordEnd(v.Cursor);
            string before = v.Doc.Buffer.GetText(new TextPos(0, 0), start);
            string after = v.Doc.Buffer.GetText(end, v.Doc.Buffer.End);
            string text = String.Concat(before, "__faset_completar__", after);
            String.Free(before);
            String.Free(after);
            JsonValue result = analyzer.Run(v.Doc, docs, text, true);
            String.Free(text);
            if (result == null) return;
            if (completions != null) Analyzer.FreeCompletions(completions);
            completions = Analyzer.Completions(result);
            delete result;
            completionStart = start;
            completionOpen = true;
            completionSel = 0;
            FilterCompletions();
        }

        static bool StartsWithIgnoreCase(string s, string prefix)
        {
            if (prefix.Length > s.Length) return false;
            for (int i = 0; i < prefix.Length; i++)
                if (Char.ToLower((char)s[i]) != Char.ToLower((char)prefix[i])) return false;
            return true;
        }

        void FilterCompletions()
        {
            filtered.Clear();
            EditorView v = Editor;
            if (v == null || completions == null) return;
            if (v.Cursor.Line != completionStart.Line || v.Cursor.Col < completionStart.Col)
            {
                CloseCompletion();
                return;
            }
            string prefix = v.Doc.Buffer.LineText(v.Cursor.Line).Substring(completionStart.Col, v.Cursor.Col - completionStart.Col);
            // Primero los que coinciden exactamente en mayúsculas; las palabras clave al final.
            for (int pass = 0; pass < 3; pass++)
                for (int i = 0; i < completions.Count; i++)
                {
                    CompletionItem c = completions[i];
                    bool keyword = c.Kind == 14;
                    bool exact = c.Label.StartsWith(prefix);
                    bool loose = StartsWithIgnoreCase(c.Label, prefix);
                    if ((pass == 0 && exact && !keyword) || (pass == 1 && !exact && loose && !keyword) || (pass == 2 && loose && keyword))
                        filtered.Add(i);
                }
            // Orden alfabético dentro de cada bloque ya viene del servidor; si no hay nada, cerrar.
            if (filtered.Count == 0 || (filtered.Count == 1 && completions[filtered[0]].Label == prefix)) CloseCompletion();
            if (completionSel >= filtered.Count) completionSel = 0;
        }

        void AcceptCompletion()
        {
            EditorView v = Editor;
            if (v == null || !completionOpen || filtered.Count == 0) return;
            CompletionItem c = completions[filtered[completionSel]];
            TextPos start = completionStart;
            v.Anchor = start;
            v.Cursor = v.WordEnd(v.Cursor);
            if (c.Insert.Length == 0) v.InsertText(c.Label, false);
            else
            {
                // Fragmento de .fstproj/.fstui: "$0" marca dónde queda el cursor (p. ej. Anchor="$0").
                int mark = c.Insert.IndexOf("$0");
                string text = mark < 0 ? String.Copy(c.Insert) : String.Concat(c.Insert.Substring(0, mark), c.Insert.Substring(mark + 2));
                v.InsertText(text, false);
                if (mark >= 0)
                {
                    int line = start.Line, col = start.Col;
                    for (int i = 0; i < mark; i++)
                    {
                        if (text[i] == '\n') { line++; col = 0; }
                        else col++;
                    }
                    v.SetCursor(new TextPos(line, col), false);
                }
                String.Free(text);
            }
            bool valueNext = c.Insert.Contains("\"$0\"") || c.Insert.Contains(">$0</");
            CloseCompletion();
            lastEditMs = Environment.TickCount64();
            analysisPending = true;
            // Tras insertar un atributo o una propiedad, sus valores posibles (Anchor, Style, OutputType...).
            if (valueNext) RequestCompletion();
        }

        void CloseCompletion()
        {
            completionOpen = false;
            filtered.Clear();
        }

        void GoToDefinition()
        {
            EditorView v = Editor;
            if (v == null) return;
            if (v.Doc.AnalyzedVersion != v.Doc.Buffer.Version) RunAnalysis();
            int idx = v.Doc.RefAt(v.Cursor.Line, v.Cursor.Col);
            if (idx < 0)
            {
                SetStatus(L.T("No definition found under the cursor"));
                return;
            }
            SymbolRef s = v.Doc.Refs[idx];
            if (s.DefPath.Length == 0)
            {
                SetStatus(L.T("This symbol has no source definition"));
                return;
            }
            int line = s.DefLine, col = s.DefCol;
            string path = String.Copy(s.DefPath);
            EditorView target = OpenFile(path);
            String.Free(path);
            if (target != null && target.Designer != null) target.DesignMode = false;  // control de un .fstui: su XML
            if (target != null) target.GoToLine(line, col, r);
        }

        void ClearHover()
        {
            if (hoverOwned) String.Free(hoverText);
            hoverText = "";
            hoverOwned = false;
        }

        // Texto emergente para la posición del ratón (diagnóstico o símbolo).
        void UpdateHover()
        {
            ClearHover();
            for (int k = 0; k < groups.Count; k++)
            {
                EditorView v = groups[k].Current;
                if (v == null || mouseX < v.X + v.GutterWidth(r) || mouseX >= v.X + v.W - 12 || mouseY < v.Y || mouseY >= v.Y + v.H)
                    continue;
                TextPos p = v.PosFromPoint(r, mouseX, mouseY);
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < v.Doc.Diagnostics.Count; i++)
                {
                    Diagnostic d = v.Doc.Diagnostics[i];
                    TextPos end = v.WordEnd(new TextPos(d.Line, d.Col));
                    if (d.Line == p.Line && p.Col >= d.Col && p.Col <= Math.Max(end.Col, d.Col + 1))
                    {
                        if (sb.Length > 0) sb.Append("\n");
                        sb.Append(d.Severity == 1 ? "error: " : d.Severity == 2 ? "warning: " : "note: ").Append(d.Message);
                    }
                }
                if (v.Doc.AnalyzedVersion == v.Doc.Buffer.Version)
                {
                    int idx = v.Doc.RefAt(p.Line, p.Col);
                    if (idx >= 0)
                    {
                        if (sb.Length > 0) sb.Append("\n\n");
                        sb.Append(v.Doc.Refs[idx].Hover);
                    }
                }
                if (sb.Length > 0)
                {
                    hoverText = sb.ToString();
                    hoverOwned = true;
                    hoverX = mouseX;
                    hoverY = mouseY;
                }
                delete sb;
                return;
            }
        }

        // ------------------------------------------------------------------ compilar / ejecutar

        void StartProcess(bool run)
        {
            if (process != null && process.IsRunning)
            {
                SetStatus(L.T("A build is already running"));
                return;
            }
            if (!analyzer.Available)
            {
                SetStatus(L.T("Compiler 'faset' not found"));
                return;
            }
            SaveAll();
            output.Clear();
            ShowTool(1);
            outputScroll = 0;
            string faset = Analyzer.Quote(analyzer.Compiler);
            StringBuilder cmd = new StringBuilder();
            cmd.Append(faset).Append(run ? " run" : " build");
            string cwd = rootFolder;
            if (projectFile.Length == 0)
            {
                EditorView v = Editor;
                if (v == null)
                {
                    String.Free(faset);
                    delete cmd;
                    return;
                }
                string q = Analyzer.Quote(v.Doc.FullPath);
                cmd.Append(" ").Append(q);
                String.Free(q);
            }
            cmd.Append(" -c ").Append(configuration).Append(" --target ").Append(buildTarget);
            if (buildTarget == "android" && android.Device.Length > 0)
            {
                string qd = Analyzer.Quote(android.Device);
                cmd.Append(" --device ").Append(qd);
                String.Free(qd);
            }
            output.Append("> ").Append(run ? "faset run" : "faset build").Append(" -c ").Append(configuration).Append(" --target ").Append(buildTarget).Append("\n");
            if (process == null) process = new ChildProcess();
            if (!process.Start(cmd.View(), cwd)) output.Append(L.T("Could not start the compiler.")).Append("\n");
            processIsRun = run;
            processStart = Environment.TickCount64();
            SetStatus(run ? L.T("Building and running…") : L.T("Building…"));
            String.Free(faset);
            delete cmd;
        }

        void StopProcess()
        {
            if (process != null && process.IsRunning)
            {
                process.Kill();
                // En Android 'faset run' solo sigue el log: también hay que cerrar la app del dispositivo.
                if (processIsRun && buildTarget == "android" && projectFile.Length > 0)
                {
                    string qf = Analyzer.Quote(analyzer.Compiler), qr = Analyzer.Quote(rootFolder);
                    StringBuilder stop = new StringBuilder();
                    stop.Append("cd ").Append(qr).Append(" && ").Append(qf).Append(" android stop");
                    String.Free(qr);
                    if (android.Device.Length > 0)
                    {
                        string qd = Analyzer.Quote(android.Device);
                        stop.Append(" --device ").Append(qd);
                        String.Free(qd);
                    }
                    string ignored;
                    Process.Capture(stop.View(), out ignored);
                    String.Free(ignored);
                    delete stop;
                    String.Free(qf);
                }
                output.Append("\n[").Append(L.T("process stopped")).Append("]\n");
            }
        }

        // Abre la ubicación de una línea de salida 'ruta:línea:col: ...'.
        void OpenLocation(string line)
        {
            int c1 = line.IndexOf(":");
            if (c1 <= 0) return;
            int c2 = line.IndexOf(":", c1 + 1);
            int c3 = c2 > 0 ? line.IndexOf(":", c2 + 1) : -1;
            if (c2 < 0 || c3 < 0) return;
            int ln = 0, col = 0;
            if (!Convert.TryToInt32(line.Substring(c1 + 1, c2 - c1 - 1), out ln)) return;
            if (!Convert.TryToInt32(line.Substring(c2 + 1, c3 - c2 - 1), out col)) return;
            string file = line.Substring(0, c1);
            string full = file.StartsWith("/") ? String.Copy(file) : Path.Combine(rootFolder, file);
            if (File.Exists(full))
            {
                EditorView v = OpenFile(full);
                if (v != null) v.GoToLine(ln - 1, col - 1, r);
            }
            String.Free(full);
        }

        // ------------------------------------------------------------------ diálogos

        void OpenOverlay(Overlay o)
        {
            overlay = o;
            overlayInput.Clear();
            overlaySel = 0;
            CloseCompletion();
            if (o == Overlay.QuickOpen)
            {
                for (int i = 0; i < quickFiles.Count; i++) String.Free(quickFiles[i]);
                quickFiles.Clear();
                explorer.CollectFiles(quickFiles);
                for (int i = 0; i < quickFiles.Count; i++) quickFiles[i] = String.Copy(quickFiles[i]);
                FilterQuickOpen();
            }
            if (o == Overlay.Find && findText.Length > 0) overlayInput.Append(findText);
        }

        void FilterQuickOpen()
        {
            quickFiltered.Clear();
            string q = overlayInput.View().ToLower();
            for (int i = 0; i < quickFiles.Count; i++)
            {
                string name = Path.GetFileName(quickFiles[i]).ToLower();
                if (q.Length == 0 || name.Contains(q)) quickFiltered.Add(i);
                String.Free(name);
            }
            String.Free(q);
            if (overlaySel >= quickFiltered.Count) overlaySel = 0;
        }

        void OverlayAccept()
        {
            Overlay o = overlay;
            overlay = Overlay.None;
            string input = overlayInput.View();
            if (o == Overlay.QuickOpen && quickFiltered.Count > 0)
            {
                OpenFile(quickFiles[quickFiltered[overlaySel]]);
            }
            else if (o == Overlay.Find)
            {
                if (findText.Length > 0) String.Free(findText);
                findText = String.Copy(input);
                FindNext();
            }
            else if (o == Overlay.GoToLine)
            {
                int line = 0;
                if (Editor != null && Convert.TryToInt32(input, out line)) Editor.GoToLine(line - 1, 0, r);
            }
            else if (o == Overlay.NewFile && input.Trim().Length > 0)
            {
                string name = input.Trim();
                string path = Path.Combine(targetFolder.Length > 0 ? targetFolder : rootFolder, name);
                if (!path.EndsWith(".fst") && !path.Contains("."))
                {
                    string withExt = String.Concat(path, ".fst");
                    String.Free(path);
                    path = withExt;
                }
                if (File.Exists(path)) SetStatus(L.T("That file already exists"));
                else
                {
                    StringBuilder template = new StringBuilder();
                    string ns = projectName.Length > 0 ? projectName : "App";
                    string cls = Path.GetFileNameWithoutExtension(path);
                    template.Append("namespace ").Append(ns).Append("\n{\n    public class ").Append(cls).Append("\n    {\n    }\n}\n");
                    File.WriteAllText(path, template.View());
                    delete template;
                    explorer.Refresh();
                    OpenFile(path);
                    SetStatus(L.T("File created"));
                }
                String.Free(path);
            }
            else if (o == Overlay.NewFolder && input.Trim().Length > 0)
            {
                string path = Path.Combine(targetFolder.Length > 0 ? targetFolder : rootFolder, input.Trim());
                if (Directory.Exists(path)) SetStatus(L.T("That folder already exists"));
                else if (Directory.Create(path))
                {
                    explorer.Refresh();
                    SetStatus(L.T("Folder created"));
                }
                String.Free(path);
            }
            else if (o == Overlay.Rename && input.Trim().Length > 0) RenamePath(targetPath, input.Trim());
        }

        void FindNext()
        {
            if (Editor == null || findText.Length == 0) return;
            if (!Editor.FindNext(findText, r)) SetStatus(L.T("Text not found"));
        }

        void ConfirmChoice(int choice)
        {
            Overlay o = overlay;
            overlay = Overlay.None;
            if (o == Overlay.ConfirmQuit)
            {
                if (choice == 0)
                {
                    SaveAll();
                    QuitRequested = true;
                }
                else if (choice == 1) QuitRequested = true;
            }
            else if (o == Overlay.ConfirmCloseTab && pendingCloseGroup >= 0)
            {
                if (choice == 0) groups[pendingCloseGroup].Tabs[pendingCloseTab].Doc.Save();
                if (choice != 2) CloseTab(pendingCloseGroup, pendingCloseTab, true);
                pendingCloseGroup = -1;
            }
            else if (o == Overlay.ConfirmCloseProject)
            {
                if (choice == 0) SaveAll();
                if (choice != 2) ShowHub();
            }
            else if (o == Overlay.ConfirmDelete && choice == 0) DeletePath(targetPath);
            else if (o == Overlay.ConfirmDeleteProject && choice == 0)
            {
                if (Directory.Delete(targetPath)) SetStatus(L.T("Project deleted"));
                else SetStatus(L.T("Could not delete the project"));
                RemoveRecent(targetPath);
            }
        }

        public void RequestQuit()
        {
            if (AnyModified()) OpenOverlay(Overlay.ConfirmQuit);
            else QuitRequested = true;
            needsRedraw = true;
        }

        bool OverlayKey(Event e)
        {
            if (overlay == Overlay.None) return false;
            if (e.Key == Keys.Escape)
            {
                overlay = Overlay.None;
                return true;
            }
            if (IsConfirm(overlay))
            {
                if (e.Key == Keys.Return) ConfirmChoice(0);
                return true;
            }
            if (overlay == Overlay.About)
            {
                if (e.Key == Keys.Return) overlay = Overlay.None;
                return true;
            }
            if (overlay == Overlay.NewProject || overlay == Overlay.OpenFolder || overlay == Overlay.ProjectProperties)
            {
                DialogKey(e);
                return true;
            }
            if (e.Key == Keys.Return || e.Key == Keys.KeypadEnter) OverlayAccept();
            else if (e.Key == Keys.Down) overlaySel++;
            else if (e.Key == Keys.Up && overlaySel > 0) overlaySel--;
            else if (e.Key == Keys.BackSpace)
            {
                string v = overlayInput.View();
                if (v.Length > 0)
                {
                    int cut = v.Length - 1;
                    while (cut > 0 && (v[cut] & 0xC0) == 0x80) cut--;
                    string keep = String.Copy(v.Substring(0, cut));
                    overlayInput.Clear();
                    overlayInput.Append(keep);
                    String.Free(keep);
                }
            }
            else if (e.Char >= 0x20 && !e.Ctrl) overlayInput.Append(e.Char);
            if (overlay == Overlay.QuickOpen)
            {
                FilterQuickOpen();
                if (overlaySel >= quickFiltered.Count) overlaySel = Math.Max(0, quickFiltered.Count - 1);
            }
            return true;
        }

        // ------------------------------------------------------------------ eventos

        public void HandleEvent(Event e)
        {
            needsRedraw = true;
            if (e.Kind == EventKind.Resize)
            {
                r.Resize(e.Width, e.Height);
                return;
            }
            if (e.Kind == EventKind.Close)
            {
                RequestQuit();
                return;
            }
            if (e.Kind == EventKind.KeyDown) HandleKey(e);
            else if (e.Kind == EventKind.MouseDown) MouseDown(e);
            else if (e.Kind == EventKind.MouseUp) MouseUp(e);
            else if (e.Kind == EventKind.MouseMove) MouseMove(e);
            else if (e.Kind == EventKind.Scroll) MouseScroll(e);
        }

        void HandleKey(Event e)
        {
            ClearHover();
            if (menu != null)
            {
                if (e.Key == Keys.Escape) CloseMenu();
                else if (e.Key == Keys.Down) menu.Move(1);
                else if (e.Key == Keys.Up) menu.Move(-1);
                else if ((e.Key == Keys.Return || e.Key == Keys.KeypadEnter) && menu.Hover >= 0)
                {
                    int action = menu.Items[menu.Hover].Action;
                    CloseMenu();
                    ExecuteAction(action);
                }
                return;
            }
            if (OverlayKey(e)) return;
            if (e.Ctrl && e.Shift && e.Key == 'n') { ExecuteAction(100); return; }
            if (e.Ctrl && e.Key == 'o') { ExecuteAction(101); return; }
            if (HubMode)
            {
                if (e.Ctrl && e.Key == 'q') RequestQuit();
                return;
            }
            uint k = e.Key;
            EditorView v = Editor;

            // Autocompletado abierto
            if (completionOpen)
            {
                if (k == Keys.Escape)
                {
                    CloseCompletion();
                    return;
                }
                if (k == Keys.Down)
                {
                    completionSel = (completionSel + 1) % Math.Max(1, filtered.Count);
                    return;
                }
                if (k == Keys.Up)
                {
                    completionSel = (completionSel + filtered.Count - 1) % Math.Max(1, filtered.Count);
                    return;
                }
                if (k == Keys.Return || k == Keys.Tab || k == Keys.KeypadEnter)
                {
                    AcceptCompletion();
                    return;
                }
            }

            // Atajos globales
            if (e.Ctrl && k == 's')
            {
                if (e.Shift)
                {
                    SaveAll();
                    SetStatus(L.T("All files saved"));
                }
                else SaveCurrent();
                return;
            }
            if (e.Ctrl && k == 'b') { StartProcess(false); return; }
            if (k == Keys.F5)
            {
                if (e.Shift) StopProcess();
                else StartProcess(true);
                return;
            }
            if (e.Ctrl && k == 'p') { OpenOverlay(Overlay.QuickOpen); return; }
            if (e.Ctrl && k == 'n') { OpenOverlay(Overlay.NewFile); return; }
            if (e.Ctrl && k == 'f') { OpenOverlay(Overlay.Find); return; }
            if (e.Ctrl && k == 'g') { OpenOverlay(Overlay.GoToLine); return; }
            if (k == 0xffc0) { FindNext(); return; }  // F3
            if (e.Ctrl && k == '\\') { ToggleSplit(); return; }
            if (e.Ctrl && k == 'q') { RequestQuit(); return; }
            if (e.Ctrl && k == '1') { if (groups[0].Current != null) ActivateTab(0, groups[0].Active); return; }
            if (e.Ctrl && k == '2') { if (groups.Count > 1 && groups[1].Current != null) ActivateTab(1, groups[1].Active); return; }
            if (k == Keys.F12) { GoToDefinition(); return; }
            if (k == 0xffbf && explorer.SelectedPath.Length > 0)  // F2: renombrar el archivo seleccionado
            {
                SetTarget(explorer.SelectedPath, false);
                OpenOverlay(Overlay.Rename);
                overlayInput.Append(Path.GetFileName(targetPath));
                return;
            }
            if (e.Ctrl && k == 'w')
            {
                if (v != null) CloseTab(activeGroup, Group.Active, false);
                return;
            }
            if (e.Ctrl && k == Keys.Tab)
            {
                EditorGroup g = Group;
                if (g.Tabs.Count > 0) ActivateTab(activeGroup, (g.Active + (e.Shift ? g.Tabs.Count - 1 : 1)) % g.Tabs.Count);
                return;
            }
            if (android.Focused && android.Key(e))
            {
                needsRedraw = true;
                return;
            }
            if (v != null && v.Designer != null && v.DesignMode)
            {
                v.Designer.Key(e);
                AfterDesigner(v);
                return;
            }
            if (k == Keys.Escape)
            {
                if (v != null) v.SetCursor(v.Cursor, false);
                return;
            }
            if (v == null) return;

            // Portapapeles
            if (e.Ctrl && (k == 'c' || k == 'x'))
            {
                if (!v.HasSelection)
                {
                    // Sin selección: copia/corta la línea entera, como Visual Studio.
                    v.Anchor = new TextPos(v.Cursor.Line, 0);
                    v.Cursor = v.Cursor.Line + 1 < v.Doc.Buffer.LineCount ? new TextPos(v.Cursor.Line + 1, 0)
                                                                          : new TextPos(v.Cursor.Line, v.Doc.Buffer.LineLength(v.Cursor.Line));
                }
                string text = v.SelectedText();
                if (win != null) win.SetClipboard(text);
                String.Free(text);
                if (k == 'x') v.Backspace();
                else v.SetCursor(v.Cursor, false);
                MarkEdited();
                return;
            }
            if (e.Ctrl && k == 'v')
            {
                if (win != null)
                {
                    string text = win.GetClipboard();
                    v.Doc.Buffer.NewGroup();
                    v.InsertText(text, false);
                    String.Free(text);
                    v.EnsureCursorVisible(r);
                    MarkEdited();
                }
                return;
            }
            if (e.Ctrl && k == ' ')
            {
                RequestCompletion();
                return;
            }

            int version = v.Doc.Buffer.Version;
            if (!v.HandleKey(e, r)) return;
            if (v.Doc.Buffer.Version != version) MarkEdited();

            // Disparar o actualizar el autocompletado
            if (e.Char != 0 && !e.Ctrl)
            {
                string line = v.Doc.Buffer.LineText(v.Cursor.Line);
                byte prev = v.Cursor.Col >= 2 ? line[v.Cursor.Col - 2] : (byte)0;
                bool member = v.Doc.IsXml ? XmlTrigger(line, v.Cursor.Col, e.Char, prev)
                                          : e.Char == '.' || (e.Char == ':' && prev == ':') || (e.Char == '>' && prev == '-');
                bool identChar = Char.IsLetterOrDigit(e.Char) || e.Char == '_';
                if (member) RequestCompletion();
                else if (completionOpen && identChar) FilterCompletions();
                else if (!completionOpen && identChar && !Char.IsDigit(e.Char) && v.Cursor.Col - v.WordStart(v.Cursor).Col == 1)
                {
                    // Primera letra de una palabra fuera de comentarios y cadenas: sugerir.
                    if (!line.Trim().StartsWith("//")) RequestCompletion();
                }
                else if (completionOpen) CloseCompletion();
            }
            else if (completionOpen)
            {
                if (k == Keys.BackSpace) FilterCompletions();
                else CloseCompletion();
            }
        }

        // .fstproj / .fstui: '<' abre la lista de elementos, '="' la de valores, ',' la siguiente opción
        // de una lista (Anchor) y el espacio dentro de una etiqueta la de atributos.
        static bool XmlTrigger(string line, int col, char ch, byte prev)
        {
            int quotes = 0, lt = -1, gt = -1;
            for (int i = 0; i < col && i < line.Length; i++)
            {
                if (line[i] == '"') quotes++;
                else if (line[i] == '<') lt = i;
                else if (line[i] == '>') gt = i;
            }
            bool inValue = quotes % 2 == 1;
            if (ch == '<') return !inValue;
            if (ch == '"') return prev == '=';
            if (ch == ',') return inValue;
            if (ch == ' ') return !inValue && lt > gt && prev != ' ' && prev != '<';
            return false;
        }

        void MarkEdited()
        {
            lastEditMs = Environment.TickCount64();
            analysisPending = true;
        }

        void MouseDown(Event e)
        {
            float x = e.X, y = e.Y;
            ClearHover();
            if (menu != null)
            {
                int item = menu.ItemAt(x, y);
                if (item >= 0)
                {
                    int action = menu.Items[item].Action;
                    CloseMenu();
                    ExecuteAction(action);
                    return;
                }
                int owner = menu.Owner;
                CloseMenu();
                // Clic en el mismo título de la barra: solo cerrar.
                for (int i = 0; i < hits.Count; i++)
                    if (hits[i].Group == -4 && hits[i].Contains(x, y) && hits[i].Id == owner) return;
                if (!(y < TitleHeight)) return;
            }
            // Barra de menús
            for (int i = 0; i < hits.Count && overlay == Overlay.None; i++)
                if (hits[i].Group == -4 && hits[i].Contains(x, y))
                {
                    OpenBarMenu(hits[i].Id, hits[i].X, hits[i].Y + hits[i].H + 4);
                    return;
                }
            // Controles de los diálogos (proyectos, carpetas, propiedades)
            if (overlay == Overlay.NewProject || overlay == Overlay.OpenFolder || overlay == Overlay.ProjectProperties || overlay == Overlay.About)
            {
                DialogMouse(x, y);
                return;
            }
            if (HubMode && overlay == Overlay.None)
            {
                HubMouse(x, y, e.Button);
                return;
            }
            if (overlay != Overlay.None)
            {
                for (int i = 0; i < hits.Count; i++)
                {
                    HitBox h = hits[i];
                    if (!h.Contains(x, y)) continue;
                    if (h.Group == -1 && h.Id >= ActConfirmA && h.Id <= ActConfirmC)
                    {
                        ConfirmChoice(h.Id - ActConfirmA);
                        return;
                    }
                    if (h.Group == -3)
                    {
                        overlaySel = h.Id;
                        OverlayAccept();
                        return;
                    }
                }
                bool insidePalette = x >= overlayInputX - 12 && x < overlayInputX + overlayInputW + 12 && y >= TitleHeight && y < overlayInputY + 60;
                if (insidePalette) return;
                if (overlay == Overlay.QuickOpen || overlay == Overlay.Find || overlay == Overlay.GoToLine || overlay == Overlay.NewFile)
                    overlay = Overlay.None;
                return;
            }
            // Autocompletado: clic en un elemento
            if (completionOpen)
            {
                for (int i = 0; i < hits.Count; i++)
                {
                    HitBox h = hits[i];
                    if (h.Group == -2 && h.Contains(x, y))
                    {
                        completionSel = h.Id;
                        AcceptCompletion();
                        return;
                    }
                }
                CloseCompletion();
            }
            // Vista del dispositivo Android: toques y botones; un clic fuera le quita el teclado.
            if (e.Button == 1 && InTool(3, x, y) && y >= toolRect[13] + PanelHeaderHeight && android.MouseDown(x, y))
            {
                needsRedraw = true;
                return;
            }
            android.Focused = false;
            // Separadores
            int split = SplitterAt(x, y);
            if (split != 0)
            {
                dragSplitter = split;
                UpdateCursor();
                return;
            }
            // Botones, pestañas y paneles
            for (int i = 0; i < hits.Count; i++)
            {
                HitBox h = hits[i];
                if (!h.Contains(x, y)) continue;
                if (h.Group >= 0)
                {
                    if (h.Close || e.Button == 2) CloseTab(h.Group, h.Id, false);
                    else ActivateTab(h.Group, h.Id);
                    return;
                }
                if (h.Group == -1 && h.Id >= ActTool && h.Id < ActTool + ToolCount)
                {
                    // Pestaña de panel: clic la activa, arrastrar la acopla en otro lado, botón derecho abre su menú.
                    int t = h.Id - ActTool;
                    sideActive[toolSide[t]] = t;
                    if (e.Button == 3)
                    {
                        contextTool = t;
                        OpenToolMenu(x, y);
                        return;
                    }
                    dockTool = t;
                    dockDragging = false;
                    dockPressX = x;
                    dockPressY = y;
                    return;
                }
                if (h.Group == -1)
                {
                    DoAction(h.Id);
                    return;
                }
                if (h.Group == -2) return;
            }
            // Explorador: el clic se resuelve al soltar (para poder arrastrar)
            if (InTool(0, x, y))
            {
                int row = explorer.RowAt(x, y);
                if (e.Button == 3)
                {
                    OpenContextMenu(row, x, y);
                    return;
                }
                pressRow = row;
                pressX = x;
                pressY = y;
                draggingFile = false;
                return;
            }
            // Editores
            for (int k = 0; k < groups.Count; k++)
            {
                EditorView v = groups[k].Current;
                if (v != null && x >= v.X && x < v.X + v.W && y >= v.Y && y < v.Y + v.H)
                {
                    if (k != activeGroup || groups[k].Active >= 0) ActivateTab(k, groups[k].Active);
                    if (v.Designer != null && v.DesignMode)
                    {
                        if (e.Button == 1) v.Designer.MouseDown(x, y, forcedClicks > 0 ? forcedClicks : (win != null ? win.ClickCount : 1), e.Shift, e.Ctrl);
                        else if (e.Button == 2) v.Designer.PanStart(x, y);
                        AfterDesigner(v);
                        return;
                    }
                    if (e.Button == 3)
                    {
                        if (!v.HasSelection) v.SetCursor(v.PosFromPoint(r, x, y), false);
                        OpenEditorMenu(x, y);
                        return;
                    }
                    v.MouseDown(r, x, y, win != null ? win.ClickCount : 1, e.Shift);
                    if (e.Ctrl) GoToDefinitionAt(v, x, y);
                    return;
                }
            }
            // Paneles de salida y de problemas
            if (InTool(2, x, y) && y >= toolRect[9] + PanelHeaderHeight)
            {
                int row = ProblemRowAt(y);
                if (row >= 0)
                {
                    Problem p = problems[row];
                    string path = String.Copy(p.Path);
                    int line = p.Line, col = p.Col;
                    EditorView v = OpenFile(path);
                    String.Free(path);
                    if (v != null) v.GoToLine(line, col, r);
                }
            }
            else if (InTool(1, x, y) && y >= toolRect[5] + PanelHeaderHeight)
            {
                int row = outputScroll + (int)Math.Floor((y - toolRect[5] - PanelHeaderHeight - 4) / r.Code.LineHeight);
                List<string> lines = Text.Split(output.View(), "\n");
                if (row >= 0 && row < lines.Count) OpenLocation(lines[row]);
                delete lines;
            }
        }

        // ------------------------------------------------------------------ diseñador (.fstui)

        // Atiende lo que el diseñador pidió tras un evento.
        void AfterDesigner(EditorView v)
        {
            Designer d = v.Designer;
            if (d.Doc.Buffer.Version != d.Doc.AnalyzedVersion) MarkEdited();
            if (d.Status.Length > 0)
            {
                SetStatus(L.T(d.Status));
                d.Status = "";
            }
            if (d.SwitchToCode)
            {
                d.SwitchToCode = false;
                v.DesignMode = false;
            }
            if (d.RequestHandler.Length > 0)
            {
                string method = d.RequestHandler;
                d.RequestHandler = String.Copy("");
                OpenHandler(v, method);
                String.Free(method);
            }
        }

        // Abre el código de la ventana (Nombre.fst junto a Nombre.fstui) en el manejador 'method',
        // creándolo (y creando el archivo) si no existe.
        void OpenHandler(EditorView designView, string method)
        {
            string uiPath = designView.Doc.FullPath;
            string codePath = String.Copy(uiPath.Substring(0, uiPath.Length - 2));
            string cls = String.Copy(designView.Designer.ClassName);
            string ns = String.Copy(designView.Designer.NamespaceName);
            if (!File.Exists(codePath))
            {
                StringBuilder sb = new StringBuilder();
                string ind = ns.Length > 0 ? "    " : "";
                sb.Append("using std.ui;\n\n");
                if (ns.Length > 0) sb.Append("namespace ").Append(ns).Append("\n{\n");
                sb.Append(ind).Append("public partial class ").Append(cls).Append("\n").Append(ind).Append("{\n");
                sb.Append(ind).Append("    public ").Append(cls).Append("() { InitializeComponent(); }\n");
                sb.Append(ind).Append("}\n");
                if (ns.Length > 0) sb.Append("}\n");
                File.WriteAllText(codePath, sb.View());
                delete sb;
                explorer.Refresh();
            }
            EditorView v = OpenFile(codePath);
            String.Free(codePath);
            if (v != null)
            {
                TextBuffer b = v.Doc.Buffer;
                int found = -1, foundCol = 0, classLine = -1;
                string needle = String.Concat(" ", method, "(");
                string classNeedle = String.Concat("class ", cls);
                for (int l = 0; l < b.LineCount; l++)
                {
                    string t = b.LineText(l);
                    int at = t.IndexOf(needle);
                    if (found < 0 && at >= 0 && t.Contains("void"))
                    {
                        found = l;
                        foundCol = at + 1;
                    }
                    if (classLine < 0 && t.Contains(classNeedle)) classLine = l;
                }
                String.Free(needle);
                String.Free(classNeedle);
                if (found >= 0) v.GoToLine(found, foundCol, r);
                else if (classLine < 0) SetStatus(L.T("Could not find the window class in the code file"));
                else
                {
                    // Llave de cierre de la clase
                    int depth = 0, closeLine = -1;
                    bool started = false;
                    for (int l = classLine; l < b.LineCount && closeLine < 0; l++)
                    {
                        string t = b.LineText(l);
                        for (int i = 0; i < t.Length; i++)
                        {
                            if (t[i] == '/' && i + 1 < t.Length && t[i + 1] == '/') break;
                            if (t[i] == '{')
                            {
                                depth++;
                                started = true;
                            }
                            else if (t[i] == '}' && started && --depth == 0)
                            {
                                closeLine = l;
                                break;
                            }
                        }
                    }
                    if (closeLine < 0) SetStatus(L.T("Could not find the window class in the code file"));
                    else
                    {
                        string closing = b.LineText(closeLine);
                        int ws = 0;
                        while (ws < closing.Length && (closing[ws] == ' ' || closing[ws] == '\t')) ws++;
                        string indent = String.Concat(closing.Substring(0, ws), "    ");
                        StringBuilder stub = new StringBuilder();
                        bool blank = closeLine > 0 && b.LineText(closeLine - 1).Trim().Length > 0 && b.LineText(closeLine - 1).Trim() != "{";
                        if (blank) stub.Append("\n");
                        stub.Append(indent).Append("void ").Append(method).Append("(Widget sender)\n");
                        stub.Append(indent).Append("{\n").Append(indent).Append("    \n").Append(indent).Append("}\n");
                        b.NewGroup();
                        b.Insert(new TextPos(closeLine, 0), stub.View(), v.Cursor);
                        b.NewGroup();
                        delete stub;
                        v.GoToLine(closeLine + (blank ? 3 : 2), indent.Length + 4, r);
                        String.Free(indent);
                        MarkEdited();
                        SetStatus(L.T("Event handler created"));
                    }
                }
            }
            String.Free(cls);
            String.Free(ns);
        }

        void GoToDefinitionAt(EditorView v, float x, float y)
        {
            v.SetCursor(v.PosFromPoint(r, x, y), false);
            GoToDefinition();
        }

        void DoAction(int id)
        {
            if (id == ActTarget)
            {
                for (int i = 0; i < hits.Count; i++)
                    if (hits[i].Id == ActTarget && hits[i].Group == -1) OpenTargetMenu(hits[i].X, hits[i].Y + hits[i].H + 4);
                return;
            }
            if (id == ActSave) SaveCurrent();
            else if (id == ActBuild) StartProcess(false);
            else if (id == ActRun) StartProcess(true);
            else if (id == ActStop) StopProcess();
            else if (id == ActSplit) ToggleSplit();
            else if (id == ActQuickOpen) OpenOverlay(Overlay.QuickOpen);
            else if (id == ActNewFile) OpenOverlay(Overlay.NewFile);
            else if (id == ActConfig) configuration = configuration == "Debug" ? "Release" : "Debug";
            else if (id == ActConfigDebug) configuration = "Debug";
            else if (id == ActConfigRelease) configuration = "Release";
            else if (id == ActClearOutput) output.Clear();
            else if (id == ActLanguage)
            {
                string code = L.NextCode();
                L.Load(code);
                Settings.Set("language", code);
                String.Free(code);
                SetStatus(L.T("Language changed"));
            }
            else if (id >= ActDesignView && id < ActCodeView + 10)
            {
                int gi = id >= ActCodeView ? id - ActCodeView : id - ActDesignView;
                EditorView v = gi < groups.Count ? groups[gi].Current : null;
                if (v != null && v.Designer != null) v.DesignMode = id < ActCodeView;
                if (gi < groups.Count && groups[gi].Active >= 0) ActivateTab(gi, groups[gi].Active);
            }
        }

        void MouseUp(Event e)
        {
            android.MouseUp(e.X, e.Y);
            if (dockTool >= 0)
            {
                if (dockDragging && dockTarget >= 0) DockTool(dockTool, dockTarget);
                dockTool = -1;
                dockDragging = false;
                dockTarget = -1;
                needsRedraw = true;
            }
            if (dragSplitter != 0) SaveLayout();
            if (pressRow >= 0)
            {
                int row = pressRow;
                pressRow = -1;
                if (draggingFile)
                {
                    int target = explorer.DropTarget;
                    explorer.DropTarget = -1;
                    draggingFile = false;
                    if (target >= 0 && row < explorer.RowCount)
                    {
                        string source = String.Copy(explorer.RowPath(row));
                        string folder = String.Copy(explorer.RowPath(target));
                        MovePath(source, folder);
                        String.Free(source);
                        String.Free(folder);
                    }
                }
                else if (row >= 0 && row < explorer.RowCount)
                {
                    if (explorer.RowIsDir(row)) explorer.Toggle(row);
                    else
                    {
                        string path = String.Copy(explorer.RowPath(row));
                        OpenFile(path);
                        String.Free(path);
                    }
                }
            }
            dragSplitter = 0;
            UpdateCursor();
            for (int k = 0; k < groups.Count; k++)
            {
                EditorView v = groups[k].Current;
                if (v == null) continue;
                if (v.Designer != null && v.DesignMode)
                {
                    v.Designer.MouseUp(e.X, e.Y);
                    AfterDesigner(v);
                }
                else v.MouseUp();
            }
        }

        void MouseMove(Event e)
        {
            mouseX = e.X;
            mouseY = e.Y;
            if (menu != null)
            {
                menu.Hover = menu.ItemAt(mouseX, mouseY);
                // Pasar de un menú de la barra a otro al mover el ratón.
                if (menu.Owner >= 0)
                    for (int i = 0; i < hits.Count; i++)
                        if (hits[i].Group == -4 && hits[i].Contains(mouseX, mouseY) && hits[i].Id != menu.Owner)
                            OpenBarMenu(hits[i].Id, hits[i].X, hits[i].Y + hits[i].H + 4);
                needsRedraw = true;
                UpdateCursor();
                return;
            }
            // Arrastrar archivos del explorador a otra carpeta
            if (pressRow >= 0 && e.Button == 1)
            {
                if (!draggingFile && Math.Abs(mouseX - pressX) + Math.Abs(mouseY - pressY) > 6 && pressRow < explorer.RowCount &&
                    !explorer.RowIsRoot(pressRow))
                    draggingFile = true;
                if (draggingFile)
                {
                    int over = explorer.RowAt(mouseX, mouseY);
                    explorer.DropTarget = over >= 0 && explorer.RowIsDir(over) && over != pressRow ? over : -1;
                }
            }
            if (dockTool >= 0 && e.Button == 1)
            {
                if (!dockDragging && Math.Abs(mouseX - dockPressX) + Math.Abs(mouseY - dockPressY) > 8) dockDragging = true;
                if (dockDragging)
                {
                    dockTarget = DockTargetAt(mouseX, mouseY);
                    needsRedraw = true;
                    UpdateCursor();
                    return;
                }
            }
            mouseMoveMs = Environment.TickCount64();
            if (hoverText.Length > 0 && (Math.Abs(mouseX - hoverX) > 8 || Math.Abs(mouseY - hoverY) > 8)) ClearHover();
            if (dragSplitter == 1) leftWidth = (float)Math.Clamp(mouseX - Gap - Gap / 2, 160.0, r.Width * 0.45);
            else if (dragSplitter == 4) rightWidth = (float)Math.Clamp(r.Width - Gap - Gap / 2 - mouseX, 160.0, r.Width * 0.45);
            else if (dragSplitter == 2) bottomHeight = (float)Math.Clamp(r.Height - StatusHeight - mouseY - Gap / 2, 90.0, r.Height * 0.7);
            else if (dragSplitter == 3)
            {
                float left = editorsX;
                float total = editorsW - Gap;
                splitRatio = (float)Math.Clamp((mouseX - left - Gap / 2) / total, 0.15, 0.85);
            }
            for (int k = 0; k < groups.Count; k++)
            {
                EditorView v = groups[k].Current;
                if (v == null) continue;
                if (v.Designer != null && v.DesignMode) v.Designer.MouseMove(mouseX, mouseY, e.Button == 1, e.Ctrl);
                else if (v.MouseMove(r, mouseX, mouseY)) needsRedraw = true;
            }
            explorer.HoverRow = overlay == Overlay.None ? explorer.RowAt(mouseX, mouseY) : -1;
            hoverButton = -1;
            for (int i = 0; i < hits.Count; i++)
                if (hits[i].Group == -1 && hits[i].Contains(mouseX, mouseY)) hoverButton = hits[i].Id;
            UpdateCursor();
            needsRedraw = true;
        }

        void MouseScroll(Event e)
        {
            ClearHover();
            float x = e.X, y = e.Y;
            if (InTool(0, x, y)) explorer.ScrollBy(e.ScrollLines);
            else if (InTool(1, x, y)) outputScroll = Math.Max(0, outputScroll + e.ScrollLines);
            else if (InTool(2, x, y)) problemsScroll = Math.Max(0, problemsScroll + e.ScrollLines);
            else if (InTool(3, x, y)) android.Scroll(x, y, e.ScrollLines);
            else
            {
                for (int k = 0; k < groups.Count; k++)
                {
                    EditorView v = groups[k].Current;
                    if (v != null && x >= v.X && x < v.X + v.W)
                    {
                        if (v.Designer != null && v.DesignMode) v.Designer.Scroll(x, y, e.ScrollLines, e.Shift, e.Ctrl);
                        else v.Scroll(e.ScrollLines);
                    }
                }
            }
        }

        // ------------------------------------------------------------------ actualización periódica

        // Devuelve true si hay que redibujar.
        public bool Update()
        {
            long now = Environment.TickCount64();
            bool redraw = needsRedraw;
            needsRedraw = false;

            if (process != null && process.IsRunning)
            {
                if (process.ReadAvailable(output)) redraw = true;
                if (process.HasExited)
                {
                    process.ReadAvailable(output);
                    int code = process.ExitCode;
                    long ms = now - processStart;
                    string codeText = String.FromInt(code), msText = String.FromInt(ms);
                    string summary = L.F(processIsRun ? "[program exited with code {0} in {1} ms]" : "[build finished with code {0} in {1} ms]", codeText, msText);
                    output.Append("\n").Append(summary).Append("\n");
                    String.Free(summary);
                    String.Free(codeText);
                    String.Free(msText);
                    if (processIsRun) SetStatus(code == 0 ? L.T("Program finished successfully") : L.T("Program exited with errors"));
                    else SetStatus(code == 0 ? L.T("Build succeeded") : L.T("Build failed"));
                    explorer.Refresh();
                    analysisPending = true;
                    redraw = true;
                }
            }
            if (android.Update(r, buildTarget == "android" && ToolVisible(3))) redraw = true;
            if (android.Status.Length > 0)
            {
                SetStatus(L.T(android.Status));
                android.Status = "";
            }
            if (analysisPending && now - lastEditMs > 350)
            {
                RunAnalysis();
                redraw = true;
            }
            if (hoverText.Length == 0 && now - mouseMoveMs > 550 && now - mouseMoveMs < 2000 && overlay == Overlay.None && !completionOpen)
            {
                UpdateHover();
                mouseMoveMs = 0;
                if (hoverText.Length > 0) redraw = true;
            }
            if (now - lastBlink > 530)
            {
                lastBlink = now;
                redraw = true;
            }
            return redraw;
        }

        // ------------------------------------------------------------------ proyectos y archivos

        static bool IsConfirm(Overlay o) => o == Overlay.ConfirmQuit || o == Overlay.ConfirmCloseTab || o == Overlay.ConfirmDelete ||
                                            o == Overlay.ConfirmCloseProject || o == Overlay.ConfirmDeleteProject;

        void SetTarget(string path, bool isDir)
        {
            string copy = String.Copy(path);
            if (targetPath.Length > 0) String.Free(targetPath);
            targetPath = copy;
            targetIsDir = isDir;
        }

        void SetTargetFolder(string folder)
        {
            string copy = String.Copy(folder);
            if (targetFolder.Length > 0) String.Free(targetFolder);
            targetFolder = copy;
        }

        void UpdateTitle()
        {
            if (win == null) return;
            if (projectName.Length > 0)
            {
                string t = String.Concat(projectName, " — FasetStudio");
                win.SetTitle(t);
                String.Free(t);
            }
            else win.SetTitle("FasetStudio");
        }

        // Proyectos recientes: carpetas separadas por '|' en la configuración.
        List<string> RecentProjects()
        {
            List<string> result = new List<string>();
            List<string> parts = Text.Split(Settings.Get("recent", ""), "|");
            for (int i = 0; i < parts.Count; i++)
                if (parts[i].Trim().Length > 0 && Directory.Exists(parts[i])) result.Add(String.Copy(parts[i]));
            delete parts;
            return result;
        }

        void SaveRecent(List<string> list)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < list.Count && i < 12; i++)
            {
                if (i > 0) sb.Append("|");
                sb.Append(list[i]);
            }
            Settings.Set("recent", sb.View());
            delete sb;
        }

        static void FreeStrings(List<string> l)
        {
            for (int i = 0; i < l.Count; i++) String.Free(l[i]);
            delete l;
        }

        void AddRecent(string folder)
        {
            List<string> old = RecentProjects();
            List<string> list = new List<string>();
            list.Add(folder);
            for (int i = 0; i < old.Count; i++)
                if (old[i] != folder) list.Add(old[i]);
            SaveRecent(list);
            delete list;
            FreeStrings(old);
        }

        void RemoveRecent(string folder)
        {
            List<string> old = RecentProjects();
            List<string> list = new List<string>();
            for (int i = 0; i < old.Count; i++)
                if (old[i] != folder) list.Add(old[i]);
            SaveRecent(list);
            delete list;
            FreeStrings(old);
        }

        // Cierra todos los documentos y el proyecto (sin preguntar).
        void CloseWorkspaceNow()
        {
            for (int k = 0; k < groups.Count; k++) delete groups[k];
            groups.Clear();
            groups.Add(new EditorGroup());
            activeGroup = 0;
            for (int i = 0; i < docs.Count; i++) delete docs[i];
            docs.Clear();
            ClearProblems();
            output.Clear();
            explorer.Unload();
            CloseCompletion();
            ClearHover();
            analysisPending = false;
            projectFile = "";
            projectName = "";
            rootFolder = "";
        }

        public void ShowHub()
        {
            CloseWorkspaceNow();
            HubMode = true;
            UpdateTitle();
            SetStatus(L.T("Ready"));
        }

        void RequestCloseWorkspace()
        {
            if (AnyModified()) OpenOverlay(Overlay.ConfirmCloseProject);
            else ShowHub();
        }

        // Cierra los documentos abiertos dentro de 'path' (archivo o carpeta).
        void CloseDocsUnder(string path)
        {
            for (int k = 0; k < groups.Count; k++)
                for (int i = groups[k].Tabs.Count - 1; i >= 0; i--)
                {
                    string p = groups[k].Tabs[i].Doc.FullPath;
                    if (p == path || p.StartsWith(path) && p.Length > path.Length && p[path.Length] == '/')
                        CloseTab(k, i, true);
                    if (k >= groups.Count) return;
                }
        }

        // Actualiza las rutas de los documentos abiertos tras mover o renombrar.
        void RetargetDocs(string oldPath, string newPath)
        {
            for (int i = 0; i < docs.Count; i++)
            {
                Document d = docs[i];
                string p = d.FullPath;
                if (p == oldPath || (p.StartsWith(oldPath) && p.Length > oldPath.Length && p[oldPath.Length] == '/'))
                {
                    string updated = String.Concat(newPath, p.Substring(oldPath.Length));
                    String.Free(d.FullPath);
                    d.FullPath = updated;
                    d.Name = Path.GetFileName(updated);
                }
            }
        }

        void RenamePath(string path, string newName)
        {
            if (newName.Contains("/"))
            {
                SetStatus(L.T("The name cannot contain '/'"));
                return;
            }
            string dir = String.Copy(Path.GetDirectoryName(path));
            string dest = Path.Combine(dir, newName);
            bool isDir = Directory.Exists(path);
            if (File.Exists(dest) || Directory.Exists(dest)) SetStatus(L.T("That name is already in use"));
            else if (isDir ? Directory.Move(path, dest) : File.Move(path, dest))
            {
                RetargetDocs(path, dest);
                explorer.Refresh();
                SetStatus(L.T("Renamed"));
            }
            else SetStatus(L.T("Could not rename"));
            String.Free(dest);
            String.Free(dir);
        }

        void MovePath(string path, string folder)
        {
            string dest = Path.Combine(folder, Path.GetFileName(path));
            bool isDir = Directory.Exists(path);
            if (dest == path || folder.StartsWith(path) && isDir) SetStatus(L.T("Cannot move it there"));
            else if (File.Exists(dest) || Directory.Exists(dest)) SetStatus(L.T("That name is already in use"));
            else if (isDir ? Directory.Move(path, dest) : File.Move(path, dest))
            {
                RetargetDocs(path, dest);
                explorer.Refresh();
                analysisPending = true;
                SetStatus(L.T("Moved"));
            }
            else SetStatus(L.T("Could not move"));
            String.Free(dest);
        }

        void DeletePath(string path)
        {
            CloseDocsUnder(path);
            bool ok = Directory.Exists(path) ? Directory.Delete(path) : File.Delete(path);
            explorer.Refresh();
            analysisPending = true;
            SetStatus(ok ? L.T("Deleted") : L.T("Could not delete"));
        }

        void DuplicateFile(string path)
        {
            string dir = String.Copy(Path.GetDirectoryName(path));
            string stem = String.Copy(Path.GetFileNameWithoutExtension(path));
            string ext = String.Copy(Path.GetExtension(path));
            string dest = "";
            for (int n = 2; n < 100; n++)
            {
                StringBuilder sb = new StringBuilder();
                sb.Append(stem).Append("_copy");
                if (n > 2) sb.Append((long)(n - 1));
                sb.Append(ext);
                string candidate = Path.Combine(dir, sb.View());
                delete sb;
                if (!File.Exists(candidate))
                {
                    dest = candidate;
                    break;
                }
                String.Free(candidate);
            }
            if (dest.Length > 0 && File.Copy(path, dest))
            {
                explorer.Refresh();
                OpenFile(dest);
                SetStatus(L.T("File duplicated"));
            }
            String.Free(dest);
            String.Free(dir);
            String.Free(stem);
            String.Free(ext);
        }

        string DefaultProjectsFolder()
        {
            string saved = Settings.Get("projects.location", "");
            if (saved.Length > 0) return String.Copy(saved);
            string home = Environment.GetVariable("HOME");
            string folder = Path.Combine(home, "FasetProjects");
            String.Free(home);
            return folder;
        }

        void OpenNewProjectDialog()
        {
            CloseMenu();
            OpenOverlay(Overlay.NewProject);
            projectTemplate = 0;
            fieldName.Set("MiProyecto");
            string folder = DefaultProjectsFolder();
            fieldLocation.Set(folder);
            String.Free(folder);
            fieldExtra.Set("");
            FocusField(fieldName);
        }

        void CreateProject()
        {
            string name = fieldName.Text.Trim();
            string location = fieldLocation.Text.Trim();
            if (name.Length == 0 || location.Length == 0) return;
            for (int i = 0; i < name.Length; i++)
            {
                byte c = name[i];
                if (!(Char.IsLetterOrDigit((char)c) || c == '_' || c == '-' || c == '.'))
                {
                    SetStatus(L.T("Use only letters, digits, '-', '_' or '.' in the project name"));
                    return;
                }
            }
            Directory.Create(location);
            string dest = Path.Combine(location, name);
            if (Directory.Exists(dest))
            {
                SetStatus(L.T("A folder with that name already exists"));
                String.Free(dest);
                return;
            }
            string kind = projectTemplate == 1 ? " --lib" : (projectTemplate == 2 ? " --winexe" : (projectTemplate == 3 ? " --ui" : (projectTemplate == 4 ? " --android" : "")));
            string qf = Analyzer.Quote(analyzer.Compiler), qloc = Analyzer.Quote(location), qname = Analyzer.Quote(name);
            StringBuilder cmd = new StringBuilder();
            cmd.Append("cd ").Append(qloc).Append(" && ").Append(qf).Append(" new ").Append(qname).Append(kind);
            string outText;
            int code = Process.Capture(cmd.View(), out outText);
            String.Free(outText);
            String.Free(qf);
            String.Free(qloc);
            String.Free(qname);
            delete cmd;
            overlay = Overlay.None;
            if (code == 0 && Directory.Exists(dest))
            {
                Settings.Set("projects.location", location);
                OpenWorkspace(dest);
                if (projectTemplate == 3 || projectTemplate == 4)
                {
                    string ui = Path.Combine(dest, "MainWindow.fstui");
                    OpenFile(ui);
                    String.Free(ui);
                }
                SetStatus(L.T("Project created"));
            }
            else SetStatus(L.T("Could not create the project"));
            String.Free(dest);
        }

        void BrowseTo(string folder)
        {
            if (!Directory.Exists(folder)) return;
            string full = Path.GetFullPath(folder);
            if (browsePath.Length > 0) String.Free(browsePath);
            browsePath = full;
            if (browseEntries != null) Directory.FreeEntries(browseEntries);
            browseEntries = Directory.GetEntries(browsePath);
            browseScroll = 0;
            fieldExtra.Set(browsePath);
        }

        void OpenFolderDialog()
        {
            CloseMenu();
            OpenOverlay(Overlay.OpenFolder);
            string start = rootFolder.Length > 0 ? String.Copy(Path.GetDirectoryName(rootFolder)) : DefaultProjectsFolder();
            if (!Directory.Exists(start))
            {
                String.Free(start);
                start = Environment.GetVariable("HOME");
            }
            BrowseTo(start);
            String.Free(start);
            fieldExtra.Focused = true;
        }

        void OpenPropertiesDialog()
        {
            CloseMenu();
            if (projectFile.Length == 0)
            {
                SetStatus(L.T("This folder has no .fstproj project"));
                return;
            }
            delete props;
            props = ProjectFile.Load(projectFile);
            if (props == null)
            {
                SetStatus(L.T("Could not read the project file"));
                return;
            }
            OpenOverlay(Overlay.ProjectProperties);
            fieldName.Set(props.AssemblyName);
            fieldName.Focused = true;
            fieldExtra.Set("");
            fieldExtra2.Set("");
            fieldExtra.Focused = false;
            fieldExtra2.Focused = false;
        }

        void SaveProperties()
        {
            if (props == null) return;
            string name = fieldName.Text.Trim();
            if (name.Length > 0) props.AssemblyName = String.Copy(name);
            if (props.Save())
            {
                projectName = String.Copy(props.AssemblyName);
                UpdateTitle();
                explorer.Refresh();
                analysisPending = true;
                SetStatus(L.T("Project properties saved"));
            }
            else SetStatus(L.T("Could not save the project file"));
            overlay = Overlay.None;
        }

        // ------------------------------------------------------------------ menús

        void CloseMenu()
        {
            delete menu;
            menu = null;
        }

        void ShowMenu(Menu m, float x, float y, int owner)
        {
            CloseMenu();
            CloseCompletion();
            menu = m;
            menu.X = x;
            menu.Y = y;
            menu.Owner = owner;
            menu.Layout(r, r.Width, r.Height);
            needsRedraw = true;
        }

        void OpenBarMenu(int index, float x, float y)
        {
            bool ws = !HubMode;
            bool ed = ws && Editor != null;
            bool running = process != null && process.IsRunning;
            Menu m = new Menu();
            if (index == 0)
            {
                m.Add(L.T("New project…"), "Ctrl+Shift+N", 100, true);
                m.Add(L.T("Open project or folder…"), "Ctrl+O", 101, true);
                m.Separator();
                m.Add(L.T("New file"), "Ctrl+N", 102, ws);
                m.Add(L.T("Save"), "Ctrl+S", 103, ed);
                m.Add(L.T("Save all"), "Ctrl+Shift+S", 104, ws);
                m.Separator();
                m.Add(L.T("Close project"), "", 105, ws);
                m.Add(L.T("Start window"), "", 107, true);
                m.Separator();
                m.Add(L.T("Exit"), "Ctrl+Q", 106, true);
            }
            else if (index == 1)
            {
                m.Add(L.T("Undo"), "Ctrl+Z", 110, ed);
                m.Add(L.T("Redo"), "Ctrl+Y", 111, ed);
                m.Separator();
                m.Add(L.T("Cut"), "Ctrl+X", 112, ed);
                m.Add(L.T("Copy"), "Ctrl+C", 113, ed);
                m.Add(L.T("Paste"), "Ctrl+V", 114, ed);
                m.Add(L.T("Select all"), "Ctrl+A", 115, ed);
                m.Separator();
                m.Add(L.T("Find"), "Ctrl+F", 116, ed);
                m.Add(L.T("Go to line"), "Ctrl+G", 117, ed);
                m.Add(L.T("Toggle comment"), "Ctrl+/", 118, ed);
                m.Add(L.T("Duplicate line"), "Ctrl+D", 119, ed);
            }
            else if (index == 2)
            {
                m.Add(L.T("Quick open"), "Ctrl+P", 6, ws);
                m.Add(groups.Count == 2 ? L.T("Join views") : L.T("Split view"), "Ctrl+\\", 122, ws);
                m.Separator();
                m.Add(L.T("Explorer"), ToolVisible(0) ? "✓" : "", 126, ws);
                m.Add(L.T("Output"), ToolVisible(1) ? "✓" : "", 123, ws);
                m.Add(L.T("Problems"), ToolVisible(2) ? "✓" : "", 124, ws);
                m.Add(L.T("Device"), ToolVisible(3) ? "✓" : "", 128, ws);
                m.Add(L.T("Reset layout"), "", 127, ws);
                m.Separator();
                m.Add(L.T("Change language"), "", 125, true);
            }
            else if (index == 3)
            {
                m.Add(L.T("Build"), "Ctrl+B", 130, ws && !running);
                m.Add(L.T("Run"), "F5", 131, ws && !running);
                m.Add(L.T("Stop"), "Shift+F5", 132, running);
                m.Add(L.T("Clean"), "", 133, ws && !running && projectFile.Length > 0);
                m.Separator();
                m.Add("Debug", configuration == "Debug" ? "✓" : "", 135, ws);
                m.Add("Release", configuration == "Release" ? "✓" : "", 136, ws);
            }
            else if (index == 4)
            {
                m.Add(L.T("Properties…"), "", 140, ws && projectFile.Length > 0);
                m.Separator();
                m.Add(L.T("Add new file…"), "", 141, ws);
                m.Add(L.T("Add new folder…"), "", 142, ws);
                m.Add(L.T("Reload project"), "", 144, ws);
            }
            else
            {
                m.Add(L.T("Keyboard shortcuts"), "", 150, true);
                m.Add(L.T("About FasetStudio"), "", 151, true);
            }
            ShowMenu(m, x, y, index);
        }

        void OpenContextMenu(int row, float x, float y)
        {
            Menu m = new Menu();
            if (row < 0)
            {
                SetTargetFolder(rootFolder);
                m.Add(L.T("New file…"), "", 165, true);
                m.Add(L.T("New folder…"), "", 166, true);
                m.Separator();
                m.Add(L.T("Reload project"), "", 144, true);
                ShowMenu(m, x, y, -1);
                return;
            }
            bool isDir = explorer.RowIsDir(row), isRoot = explorer.RowIsRoot(row);
            SetTarget(explorer.RowPath(row), isDir);
            SetTargetFolder(explorer.RowFolder(row));
            if (isRoot)
            {
                m.Add(L.T("Build"), "Ctrl+B", 130, true);
                m.Add(L.T("Run"), "F5", 131, true);
                m.Add(L.T("Clean"), "", 133, projectFile.Length > 0);
                m.Separator();
                m.Add(L.T("New file…"), "", 165, true);
                m.Add(L.T("New folder…"), "", 166, true);
                m.Separator();
                m.Add(L.T("Copy path"), "", 164, true);
                m.Add(L.T("Properties…"), "", 140, projectFile.Length > 0);
                m.Add(L.T("Close project"), "", 105, true);
            }
            else if (isDir)
            {
                m.Add(L.T("New file…"), "", 165, true);
                m.Add(L.T("New folder…"), "", 166, true);
                m.Separator();
                m.Add(L.T("Rename…"), "F2", 161, true);
                m.Add(L.T("Copy path"), "", 164, true);
                m.Separator();
                m.AddDanger(L.T("Delete"), "", 162);
            }
            else
            {
                m.Add(L.T("Open"), "", 160, true);
                m.Separator();
                m.Add(L.T("Rename…"), "F2", 161, true);
                m.Add(L.T("Duplicate"), "", 163, true);
                m.Add(L.T("Copy path"), "", 164, true);
                m.Separator();
                m.AddDanger(L.T("Delete"), "", 162);
            }
            ShowMenu(m, x, y, -1);
        }

        void OpenEditorMenu(float x, float y)
        {
            Menu m = new Menu();
            m.Add(L.T("Go to definition"), "F12", 167, true);
            m.Separator();
            m.Add(L.T("Cut"), "Ctrl+X", 112, true);
            m.Add(L.T("Copy"), "Ctrl+C", 113, true);
            m.Add(L.T("Paste"), "Ctrl+V", 114, true);
            m.Separator();
            m.Add(L.T("Toggle comment"), "Ctrl+/", 118, true);
            m.Add(L.T("Duplicate line"), "Ctrl+D", 119, true);
            ShowMenu(m, x, y, -1);
        }

        // Simula un atajo de teclado sobre el editor activo.
        void EditorShortcut(uint key, bool shift)
        {
            Event e = new Event();
            e.Kind = EventKind.KeyDown;
            e.Ctrl = true;
            e.Shift = shift;
            e.Key = key;
            HandleKey(e);
        }

        void ExecuteAction(int id)
        {
            needsRedraw = true;
            if (id == 100) OpenNewProjectDialog();
            else if (id == 101) OpenFolderDialog();
            else if (id == 102 || id == 141)
            {
                SetTargetFolder(rootFolder);
                OpenOverlay(Overlay.NewFile);
            }
            else if (id == 103) SaveCurrent();
            else if (id == 104)
            {
                SaveAll();
                SetStatus(L.T("All files saved"));
            }
            else if (id == 105) RequestCloseWorkspace();
            else if (id == 106) RequestQuit();
            else if (id == 107)
            {
                if (HubMode) return;
                RequestCloseWorkspace();
            }
            else if (id == 110) EditorShortcut('z', false);
            else if (id == 111) EditorShortcut('y', false);
            else if (id == 112) EditorShortcut('x', false);
            else if (id == 113) EditorShortcut('c', false);
            else if (id == 114) EditorShortcut('v', false);
            else if (id == 115) EditorShortcut('a', false);
            else if (id == 116) OpenOverlay(Overlay.Find);
            else if (id == 117) OpenOverlay(Overlay.GoToLine);
            else if (id == 118) EditorShortcut('/', false);
            else if (id == 119) EditorShortcut('d', false);
            else if (id == 122) ToggleSplit();
            else if (id == 123) ToggleTool(1);
            else if (id == 124) ToggleTool(2);
            else if (id == 126) ToggleTool(0);
            else if (id == 128) ToggleTool(3);
            else if (id == 180) SetBuildTarget("native");
            else if (id == 198) android.Refresh();
            else if (id >= 181 && id < 181 + android.Serials.Count)
            {
                android.Select(android.Serials[id - 181]);
                SetBuildTarget("android");
            }
            else if (id >= 200 && id < 200 + android.Avds.Count)
            {
                android.StartEmulator(android.Avds[id - 200]);
                SetBuildTarget("android");
            }
            else if (id == 127) ResetLayout();
            else if (id >= 170 && id <= 172 && contextTool >= 0) DockTool(contextTool, id - 170);
            else if (id == 173 && contextTool >= 0) HideTool(contextTool);
            else if (id == 125) DoAction(ActLanguage);
            else if (id == 130) StartProcess(false);
            else if (id == 131) StartProcess(true);
            else if (id == 132) StopProcess();
            else if (id == 133) RunClean();
            else if (id == 135) configuration = "Debug";
            else if (id == 136) configuration = "Release";
            else if (id == 140) OpenPropertiesDialog();
            else if (id == 142)
            {
                SetTargetFolder(rootFolder);
                OpenOverlay(Overlay.NewFolder);
            }
            else if (id == 144) explorer.Refresh();
            else if (id == 150)
            {
                // La pantalla de bienvenida muestra los atajos: cerrar las pestañas del grupo no es necesario,
                // basta con indicarlo en la barra de estado.
                SetStatus(L.T("Ctrl+P open · Ctrl+B build · F5 run · F12 definition · Ctrl+\\ split"));
            }
            else if (id == 151) OpenOverlay(Overlay.About);
            else if (id == 160) OpenFile(targetPath);
            else if (id == 161)
            {
                OpenOverlay(Overlay.Rename);
                overlayInput.Append(Path.GetFileName(targetPath));
            }
            else if (id == 162) OpenOverlay(Overlay.ConfirmDelete);
            else if (id == 163) DuplicateFile(targetPath);
            else if (id == 164)
            {
                if (win != null) win.SetClipboard(targetPath);
                SetStatus(L.T("Path copied"));
            }
            else if (id == 165) OpenOverlay(Overlay.NewFile);
            else if (id == 166) OpenOverlay(Overlay.NewFolder);
            else if (id == 167) GoToDefinition();
            else DoAction(id);
        }

        void RunClean()
        {
            if (projectFile.Length == 0) return;
            string qf = Analyzer.Quote(analyzer.Compiler);
            StringBuilder cmd = new StringBuilder();
            cmd.Append(qf).Append(" clean");
            output.Clear();
            ShowTool(1);
            if (process == null) process = new ChildProcess();
            process.Start(cmd.View(), rootFolder);
            processIsRun = false;
            processStart = Environment.TickCount64();
            SetStatus(L.T("Cleaning…"));
            String.Free(qf);
            delete cmd;
        }

        // ------------------------------------------------------------------ diálogos con controles

        TextField FocusedField()
        {
            if (fieldName.Focused) return fieldName;
            if (fieldLocation.Focused) return fieldLocation;
            if (fieldExtra.Focused) return fieldExtra;
            if (fieldExtra2.Focused) return fieldExtra2;
            return null;
        }

        void FocusField(TextField f)
        {
            fieldName.Focused = f == fieldName;
            fieldLocation.Focused = f == fieldLocation;
            fieldExtra.Focused = f == fieldExtra;
            fieldExtra2.Focused = f == fieldExtra2;
        }

        void DialogKey(Event e)
        {
            TextField f = FocusedField();
            bool enter = e.Key == Keys.Return || e.Key == Keys.KeypadEnter;
            if (overlay == Overlay.NewProject)
            {
                if (e.Key == Keys.Tab) FocusField(fieldExtra.Focused ? fieldName : (fieldName.Focused ? fieldLocation : fieldExtra));
                else if (e.Key == Keys.Up) StepTemplate(-1);
                else if (e.Key == Keys.Down) StepTemplate(1);
                else if (enter) CreateProject();
                else if (f != null) f.Key(e);
            }
            else if (overlay == Overlay.OpenFolder)
            {
                if (enter)
                {
                    string typed = String.Copy(fieldExtra.Text.Trim());
                    if (Directory.Exists(typed)) BrowseTo(typed);
                    String.Free(typed);
                }
                else if (f != null) f.Key(e);
            }
            else if (overlay == Overlay.ProjectProperties)
            {
                if (enter && fieldExtra.Focused) DialogAction(150);
                else if (enter && fieldExtra2.Focused) DialogAction(151);
                else if (enter) SaveProperties();
                else if (e.Key == Keys.Tab) FocusField(fieldName.Focused ? fieldExtra : (fieldExtra.Focused ? fieldExtra2 : fieldName));
                else if (f != null) f.Key(e);
            }
        }

        void DialogMouse(float x, float y)
        {
            if (fieldName.Contains(x, y) && (overlay == Overlay.NewProject || overlay == Overlay.ProjectProperties)) FocusField(fieldName);
            else if (fieldLocation.Contains(x, y) && overlay == Overlay.NewProject) FocusField(fieldLocation);
            else if (fieldExtra.Contains(x, y) && (overlay == Overlay.OpenFolder || overlay == Overlay.ProjectProperties || overlay == Overlay.NewProject)) FocusField(fieldExtra);
            else if (fieldExtra2.Contains(x, y) && overlay == Overlay.ProjectProperties) FocusField(fieldExtra2);
            for (int i = 0; i < hits.Count; i++)
            {
                HitBox h = hits[i];
                if (h.Group == -5 && h.Contains(x, y))
                {
                    DialogAction(h.Id);
                    return;
                }
            }
        }

        void DialogAction(int id)
        {
            needsRedraw = true;
            if (overlay == Overlay.About)
            {
                if (id == 1) overlay = Overlay.None;
                return;
            }
            if (overlay == Overlay.NewProject)
            {
                if (id >= 10 && id <= 14) projectTemplate = id - 10;
                else if (id == 20) overlay = Overlay.None;
                else if (id == 21) CreateProject();
                return;
            }
            if (overlay == Overlay.OpenFolder)
            {
                if (id == 30) overlay = Overlay.None;
                else if (id == 31)
                {
                    string folder = String.Copy(browsePath);
                    overlay = Overlay.None;
                    OpenWorkspace(folder);
                    String.Free(folder);
                }
                else if (id == 32)
                {
                    string parent = String.Copy(Path.GetDirectoryName(browsePath));
                    if (parent.Length > 0) BrowseTo(parent);
                    String.Free(parent);
                }
                else if (id >= 1000 && browseEntries != null && id - 1000 < browseEntries.Count)
                {
                    DirEntry e = browseEntries[id - 1000];
                    string path = Path.Combine(browsePath, e.Name);
                    if (e.IsDirectory) BrowseTo(path);
                    else if (e.Name.EndsWith(".fstproj"))
                    {
                        overlay = Overlay.None;
                        OpenWorkspace(path);
                    }
                    String.Free(path);
                }
                return;
            }
            if (overlay == Overlay.ProjectProperties && props != null)
            {
                if (id >= 100 && id <= 102) props.OutputType = id == 100 ? "Exe" : (id == 101 ? "WinExe" : "Library");
                else if (id >= 110 && id <= 113) props.TargetPlatform = id == 110 ? "native" : (id == 111 ? "linux" : (id == 112 ? "windows" : "android"));
                else if (id >= 120 && id <= 124) props.TargetArch = id == 120 ? "" : (id == 121 ? "x86_64" : (id == 122 ? "arm64" : (id == 123 ? "x86" : "armv7")));
                else if (id == 130 || id == 131) props.Configuration = id == 130 ? "Debug" : "Release";
                else if (id == 140) props.StaticLink = !props.StaticLink;
                else if (id == 150 && fieldExtra.Text.Trim().Length > 0)
                {
                    props.References.Add(String.Copy(fieldExtra.Text.Trim()));
                    fieldExtra.Set("");
                }
                else if (id == 151 && fieldExtra2.Text.Trim().Length > 0)
                {
                    props.NativeLibraries.Add(String.Copy(fieldExtra2.Text.Trim()));
                    fieldExtra2.Set("");
                }
                else if (id == 160) overlay = Overlay.None;
                else if (id == 161) SaveProperties();
                else if (id >= 200 && id < 300 && id - 200 < props.References.Count) props.References.RemoveAt(id - 200);
                else if (id >= 300 && id < 400 && id - 300 < props.NativeLibraries.Count) props.NativeLibraries.RemoveAt(id - 300);
            }
        }

        // ------------------------------------------------------------------ Hub (ventana de inicio)

        void HubMouse(float x, float y, int button)
        {
            for (int i = 0; i < hits.Count; i++)
            {
                HitBox h = hits[i];
                if (!h.Contains(x, y)) continue;
                if (h.Group == -1)
                {
                    if (h.Id == ActNewProject) OpenNewProjectDialog();
                    else if (h.Id == ActOpenFolder) OpenFolderDialog();
                    else DoAction(h.Id);
                    return;
                }
                if (h.Group == -6 || h.Group == -7 || h.Group == -8)
                {
                    List<string> recent = RecentProjects();
                    if (h.Id < recent.Count)
                    {
                        string path = String.Copy(recent[h.Id]);
                        if (h.Group == -6) OpenWorkspace(path);
                        else if (h.Group == -7) RemoveRecent(path);
                        else
                        {
                            SetTarget(path, true);
                            OpenOverlay(Overlay.ConfirmDeleteProject);
                        }
                        String.Free(path);
                    }
                    FreeStrings(recent);
                    return;
                }
            }
        }

        // ------------------------------------------------------------------ dibujo

        void AddHit(float x, float y, float w, float h, int id, int group, bool close)
        {
            HitBox b = new HitBox();
            b.X = x;
            b.Y = y;
            b.W = w;
            b.H = h;
            b.Id = id;
            b.Group = group;
            b.Close = close;
            hits.Add(b);
        }

        float PillWidth(string label, string icon)
        {
            float iconW = icon.Length > 0 ? r.TextWidth(r.Icons, icon) + (label.Length > 0 ? 7 : 0) : 0;
            return r.TextWidth(r.Ui, label) + iconW + 26;
        }

        // Botón redondeado. style: 0 secundario, 1 principal (blanco), 2 fantasma.
        float Pill(float x, float y, string label, string icon, int id, int style)
        {
            float w = PillWidth(label, icon);
            float h = 28;
            bool hover = hoverButton == id;
            Color fg = style == 1 ? Theme.Black : (style == 2 && !hover ? Theme.TextSecondary : Theme.Text);
            if (style == 3) fg = Theme.White;
            if (style == 1) r.RoundRect(x, y, w, h, h / 2, hover ? Color.Hex(0xdcdce0) : Theme.White);
            else if (style == 3) r.RoundRect(x, y, w, h, h / 2, hover ? Color.Hex(0xd93c3c) : Theme.Error);
            else if (style == 0)
            {
                r.RoundRect(x, y, w, h, h / 2, hover ? Theme.Hover : Theme.Elevated);
                r.RoundBorder(x, y, w, h, h / 2, 1, Theme.BorderStrong);
            }
            else if (hover) r.RoundRect(x, y, w, h, h / 2, Theme.Hover);
            float tx = x + 13;
            if (icon.Length > 0)
            {
                r.Text(r.Icons, tx, y + 7, icon, fg);
                tx += r.TextWidth(r.Icons, icon) + 7;
            }
            r.Text(r.Ui, tx, y + 6, label, fg);
            AddHit(x, y, w, h, id, -1, false);
            return w;
        }

        void KeyChip(float x, float y, string key)
        {
            float w = r.TextWidth(r.UiSmall, key) + 12;
            r.RoundRect(x, y, w, 18, 5, Theme.Active);
            r.Text(r.UiSmall, x + 6, y + 2, key, Theme.TextSecondary);
        }

        void Card(float x, float y, float w, float h, Color c)
        {
            r.RoundRect(x, y, w, h, CardRadius, c);
        }

        public void Draw()
        {
            hits.Clear();
            float W = r.Width, H = r.Height;
            r.BeginFrame(Theme.Base);
            DrawTitleBar(W);
            if (HubMode)
            {
                DrawHub(W, H);
                if (overlay != Overlay.None) DrawOverlay();
                if (menu != null) menu.Draw(r);
                r.EndFrame();
                return;
            }

            float top = TitleHeight;
            float bottom = H - StatusHeight;
            bool hasL = sideActive[0] >= 0, hasR = sideActive[1] >= 0, hasB = sideActive[2] >= 0;
            for (int i = 0; i < ToolCount * 4; i++) toolRect[i] = 0;
            explorer.W = 0;
            leftWidth = (float)Math.Clamp(leftWidth, 160.0, W * 0.45);
            rightWidth = (float)Math.Clamp(rightWidth, 160.0, W * 0.45);
            bottomHeight = (float)Math.Clamp(bottomHeight, 90.0, H * 0.7);
            editorsX = Gap + (hasL ? leftWidth + Gap : 0);
            editorsW = W - Gap - (hasR ? rightWidth + Gap : 0) - editorsX;
            editorsBottom = hasB ? bottom - bottomHeight - Gap : bottom;
            bottomX = editorsX;
            bottomW = editorsW;
            splitLeftX = hasL ? Gap + leftWidth + Gap / 2 : -100;
            splitRightX = hasR ? W - Gap - rightWidth - Gap / 2 : -100;
            splitBottomY = hasB ? bottom - bottomHeight - Gap / 2 : -100;
            if (hasL) DrawSide(0, Gap, top, leftWidth, bottom - top);
            if (hasR) DrawSide(1, W - Gap - rightWidth, top, rightWidth, bottom - top);
            if (hasB) DrawSide(2, bottomX, bottom - bottomHeight, bottomW, bottomHeight);

            // Grupos de editores
            float edX = editorsX, edW = editorsW;
            float edH = editorsBottom - top;
            for (int k = 0; k < groups.Count; k++)
            {
                EditorGroup g = groups[k];
                float gx = edX, gw = edW;
                if (groups.Count == 2)
                {
                    float leftW = (float)Math.Floor((edW - Gap) * splitRatio);
                    gx = k == 0 ? edX : edX + leftW + Gap;
                    gw = k == 0 ? leftW : edW - leftW - Gap;
                    if (k == 1) splitGroupsX = gx - Gap / 2;
                }
                g.X = gx;
                g.Y = top;
                g.W = gw;
                g.H = edH;
                DrawGroup(g, k);
            }

            DrawStatus(W, H);
            if (dockDragging) DrawDockGuides();

            if (completionOpen) DrawCompletion();
            if (hoverText.Length > 0) DrawTooltip(hoverText, hoverX + 14, hoverY + 20);
            if (overlay != Overlay.None) DrawOverlay();
            if (draggingFile && pressRow >= 0 && pressRow < explorer.RowCount)
            {
                string name = Path.GetFileName(explorer.RowPath(pressRow));
                float w = r.TextWidth(r.Ui, name) + 24;
                r.Shadow(mouseX + 12, mouseY + 8, w, 26, 8, 12, Theme.Shadow);
                r.RoundRect(mouseX + 12, mouseY + 8, w, 26, 8, Theme.Elevated);
                r.Text(r.Ui, mouseX + 24, mouseY + 12, name, Theme.White);
            }
            if (menu != null) menu.Draw(r);
            r.EndFrame();
        }

        void DrawTitleBar(float W)
        {
            // Logotipo y nombre
            r.Logo(Gap + 8, 12, 24, Theme.White);
            float x = r.Text(r.UiBold, Gap + 42, 15, "FasetStudio", Theme.White) + 14;
            float menuEnd = DrawMenuBar(x);

            if (HubMode)
            {
                string lang = L.Code.ToUpper();
                float lw = r.TextWidth(r.UiSmall, lang) + 16;
                float lx = W - Gap - 12 - lw;
                r.RoundRect(lx, 15, lw, 18, 9, hoverButton == ActLanguage ? Theme.Active : Theme.Elevated);
                r.Text(r.UiSmall, lx + 8, 16, lang, Theme.Text);
                AddHit(lx, 15, lw, 18, ActLanguage, -1, false);
                String.Free(lang);
                return;
            }
            // Buscador central (abre "Abrir rápido")
            float sw = (float)Math.Clamp(W * 0.3, 220.0, 480.0);
            float sx = (W - sw) / 2;
            if (sx < menuEnd + 16)
            {
                sw -= menuEnd + 16 - sx;
                sx = menuEnd + 16;
            }
            // Que no pise los controles de la derecha (ejecutar, compilar, destino, configuración, dividir).
            string runL = L.T("Run"), buildL = L.T("Build");
            string targetL = TargetLabel();
            float rightW = PillWidth(runL, "▶") + PillWidth(buildL, "") + 8 + r.TextWidth(r.Ui, targetL) + 62 +
                           r.TextWidth(r.Ui, "Debug") + r.TextWidth(r.Ui, "Release") + 60 + 40 + 16;
            String.Free(targetL);
            float limit = W - Gap - 8 - rightW;
            if (sx + sw > limit) sw = (float)Math.Max(120.0, (double)(limit - sx));
            bool searchHover = hoverButton == ActQuickOpen;
            r.RoundRect(sx, 10, sw, 28, 14, searchHover ? Theme.Hover : Theme.Elevated);
            r.RoundBorder(sx, 10, sw, 28, 14, 1, Theme.Border);
            r.RoundBorder(sx + 14, 18, 10, 10, 5, 1.5f, Theme.TextTertiary);
            r.RoundRect(sx + 23, 27, 4, 2, 1, Theme.TextTertiary);
            r.Text(r.Ui, sx + 34, 15, L.T("Search files"), Theme.TextTertiary);
            KeyChip(sx + sw - 62, 15, "Ctrl P");
            AddHit(sx, 10, sw, 28, ActQuickOpen, -1, false);

            // Acciones a la derecha
            bool running = process != null && process.IsRunning;
            string runLabel = running ? L.T("Stop") : L.T("Run");
            string runIcon = running ? "■" : "▶";
            float rx = W - Gap - 8 - PillWidth(runLabel, runIcon);
            Pill(rx, 10, runLabel, runIcon, running ? ActStop : ActRun, 1);
            string buildLabel = L.T("Build");
            rx -= PillWidth(buildLabel, "") + 8;
            Pill(rx, 10, buildLabel, "", ActBuild, 0);

            // Destino: este equipo o un dispositivo Android
            string tlabel = TargetLabel();
            float tw = r.TextWidth(r.Ui, tlabel) + 52;
            rx -= tw + 10;
            bool thot = hoverButton == ActTarget;
            r.RoundRect(rx, 10, tw, 28, 14, thot ? Theme.Hover : Theme.Elevated);
            Color tc = thot ? Theme.White : Theme.TextSecondary;
            if (buildTarget == "android")
            {
                r.RoundBorder(rx + 13, 15, 10, 17, 3, 1.4f, tc);       // móvil
                r.Rect(rx + 16.5f, 28.5f, 3, 1.4f, tc);
            }
            else
            {
                r.RoundBorder(rx + 11, 16, 15, 11, 2, 1.4f, tc);       // monitor
                r.Rect(rx + 15, 29.5f, 7, 1.4f, tc);
            }
            r.Text(r.Ui, rx + 32, 15, tlabel, Theme.Text);
            r.Text(r.Icons, rx + tw - 17, 16, "▾", Theme.TextTertiary);
            AddHit(rx, 10, tw, 28, ActTarget, -1, false);
            String.Free(tlabel);

            // Selector Debug / Release
            float dw = r.TextWidth(r.Ui, "Debug") + 22, rw = r.TextWidth(r.Ui, "Release") + 22;
            rx -= dw + rw + 4 + 12;
            r.RoundRect(rx, 10, dw + rw + 4, 28, 14, Theme.Elevated);
            bool debug = configuration == "Debug";
            r.RoundRect(debug ? rx + 2 : rx + 2 + dw, 12, debug ? dw : rw, 24, 12, Theme.Active);
            r.Text(r.Ui, rx + 13, 15, "Debug", debug ? Theme.White : Theme.TextTertiary);
            r.Text(r.Ui, rx + 2 + dw + 11, 15, "Release", debug ? Theme.TextTertiary : Theme.White);
            AddHit(rx, 10, dw + 2, 28, ActConfigDebug, -1, false);
            AddHit(rx + 2 + dw, 10, rw + 2, 28, ActConfigRelease, -1, false);

            // Dividir vista (icono)
            rx -= 40;
            bool splitHover = hoverButton == ActSplit;
            if (splitHover || groups.Count == 2) r.RoundRect(rx, 10, 28, 28, 8, groups.Count == 2 ? Theme.Active : Theme.Hover);
            Color ic = groups.Count == 2 || splitHover ? Theme.White : Theme.TextSecondary;
            r.RoundBorder(rx + 7, 17, 14, 14, 3, 1.4f, ic);
            r.Rect(rx + 13.5f, 18, 1.4f, 12, ic);
            AddHit(rx, 10, 28, 28, ActSplit, -1, false);
        }

        void DrawGroup(EditorGroup g, int index)
        {
            Card(g.X, g.Y, g.W, g.H, Theme.Editor);
            bool focusedGroup = index == activeGroup;
            // Pestañas
            r.PushClip(g.X + 4, g.Y, g.W - 8, TabHeight);
            float x = g.X + 8;
            for (int i = 0; i < g.Tabs.Count; i++)
            {
                EditorView v = g.Tabs[i];
                bool active = i == g.Active;
                string name = v.Doc.Name;
                float w = r.TextWidth(r.Ui, name) + 50;
                float ty = g.Y + 7;
                bool hover = mouseY >= ty && mouseY < ty + 28 && mouseX >= x && mouseX < x + w;
                if (active) r.RoundRect(x, ty, w, 28, 8, focusedGroup ? Theme.Active : Theme.Elevated);
                else if (hover) r.RoundRect(x, ty, w, 28, 8, Theme.Hover);
                bool errors = v.Doc.ErrorCount > 0;
                Color fc = active ? Theme.White : Theme.TextTertiary;
                if (errors) r.RoundRect(x + 11, ty + 12, 5, 5, 2.5f, Theme.Error);
                r.Text(r.Ui, x + (errors ? 22 : 14), ty + 6, name, fc);
                float cx = x + w - 25;
                if (v.Doc.Modified && !(hover && !active)) r.RoundRect(cx + 6, ty + 11, 7, 7, 3.5f, active ? Theme.Text : Theme.TextTertiary);
                else if (active || hover) r.Text(r.Icons, cx + 5, ty + 6, "×", Theme.TextSecondary);
                AddHit(x, ty, w - 26, 28, i, index, false);
                AddHit(cx, ty, 22, 28, i, index, true);
                x += w + 4;
            }
            r.PopClip();
            r.Rect(g.X, g.Y + TabHeight, g.W, 1, Theme.Border);

            EditorView cur = g.Current;
            float ey = g.Y + TabHeight + 1;
            float eh = g.H - TabHeight - 1 - 6;
            if (cur == null)
            {
                DrawWelcome(g.X, ey, g.W, eh);
                return;
            }
            cur.X = g.X;
            cur.Y = ey;
            cur.W = g.W - 2;
            cur.H = eh;
            if (cur.Designer != null)
            {
                // Selector Diseño | Código a la derecha de las pestañas
                string design = L.T("Design"), code = L.T("Code");
                float w1 = r.TextWidth(r.Ui, design) + 24, w2 = r.TextWidth(r.Ui, code) + 24;
                float sx = g.X + g.W - w1 - w2 - 16, sy = g.Y + 7;
                r.RoundRect(sx - 3, sy - 1, w1 + w2 + 6, 30, 9, Theme.Base);
                r.RoundRect(cur.DesignMode ? sx : sx + w1, sy + 2, cur.DesignMode ? w1 : w2, 24, 7, Theme.Active);
                r.Text(r.Ui, sx + 12, sy + 5, design, cur.DesignMode ? Theme.White : Theme.TextTertiary);
                r.Text(r.Ui, sx + w1 + 12, sy + 5, code, cur.DesignMode ? Theme.TextTertiary : Theme.White);
                AddHit(sx, sy, w1, 28, ActDesignView + index, -1, false);
                AddHit(sx + w1, sy, w2, 28, ActCodeView + index, -1, false);
                if (cur.DesignMode)
                {
                    Designer d = cur.Designer;
                    d.X = cur.X;
                    d.Y = cur.Y;
                    d.W = cur.W;
                    d.H = cur.H;
                    d.Draw(r);
                    return;
                }
            }
            cur.ClampScroll();
            long now = Environment.TickCount64();
            bool caretOn = ((now - cur.CaretTime) / 530) % 2 == 0;
            cur.Draw(r, hl, caretOn && overlay == Overlay.None);
        }

        void DrawWelcome(float x, float y, float w, float h)
        {
            float cx = x + w / 2;
            float cy = y + h / 2 - 110;
            if (h < 300) cy = y + 20;
            r.Logo(cx - 32, cy - 4, 64, Theme.White);
            float tw = r.TextWidth(r.Title, "FasetStudio");
            r.Text(r.Title, cx - tw / 2, cy + 72, "FasetStudio", Theme.White);
            string sub = L.T("Native code with the elegance of C# and the power of C++");
            float sw = r.TextWidth(r.Ui, sub);
            r.Text(r.Ui, cx - sw / 2, cy + 104, sub, Theme.TextTertiary);
            float ry = cy + 146;
            float colW = 300;
            float lx = cx - colW / 2;
            DrawShortcut(lx, ry, colW, L.T("Open file"), "Ctrl P");
            DrawShortcut(lx, ry + 30, colW, L.T("New file"), "Ctrl N");
            DrawShortcut(lx, ry + 60, colW, L.T("Build project"), "Ctrl B");
            DrawShortcut(lx, ry + 90, colW, L.T("Run"), "F5");
            DrawShortcut(lx, ry + 120, colW, L.T("Split view"), "Ctrl \\");
            DrawShortcut(lx, ry + 150, colW, L.T("Go to definition"), "F12");
        }

        void DrawShortcut(float x, float y, float w, string label, string key)
        {
            r.Text(r.Ui, x, y + 2, label, Theme.TextSecondary);
            float kw = r.TextWidth(r.UiSmall, key) + 12;
            KeyChip(x + w - kw, y + 1, key);
        }

        float PanelTab(float x, float y, string label, int count, int id, bool active)
        {
            float w = r.TextWidth(r.Ui, label) + 26;
            string num = "";
            if (count > 0)
            {
                num = String.FromInt(count);
                w += r.TextWidth(r.UiSmall, num) + 18;
            }
            bool hover = hoverButton == id;
            if (active) r.RoundRect(x, y, w, 26, 13, Theme.Active);
            else if (hover) r.RoundRect(x, y, w, 26, 13, Theme.Hover);
            float tx = r.Text(r.Ui, x + 13, y + 5, label, active ? Theme.White : Theme.TextTertiary);
            if (count > 0)
            {
                float bw = r.TextWidth(r.UiSmall, num) + 12;
                r.RoundRect(tx + 7, y + 5, bw, 16, 8, Theme.Error);
                r.Text(r.UiSmall, tx + 13, y + 6, num, Theme.White);
                String.Free(num);
            }
            AddHit(x, y, w, 26, id, -1, false);
            return w;
        }

        // ------------------------------------------------------------------ paneles acoplables

        // ------------------------------------------------------------------ Android

        // Texto del selector de destino (copia).
        string TargetLabel()
        {
            if (buildTarget != "android") return String.Copy(L.T(OS.Name() == "windows" ? "Windows" : "Linux"));
            if (android.StartingAvd.Length > 0) return String.Copy(L.T("Starting emulator…"));
            if (android.Device.Length == 0) return String.Copy("Android");
            string model = android.ModelOf(android.Device);
            return String.Copy(model.Length > 0 ? model : android.Device);
        }

        void SetBuildTarget(string target)
        {
            buildTarget = target == "android" ? "android" : "native";
            if (buildTarget == "android")
            {
                if (!toolShown[3]) ShowTool(3);
                if (!android.Listed) android.Refresh();
            }
            needsRedraw = true;
        }

        void OpenTargetMenu(float x, float y)
        {
            android.Refresh();
            Menu m = new Menu();
            m.Add(L.T("This computer"), buildTarget == "native" ? "✓" : "", 180, true);
            m.Separator();
            if (!android.AdbFound) m.Add(L.T("Android SDK not found"), "", 0, false);
            for (int i = 0; i < android.Serials.Count && i < 15; i++)
            {
                string model = android.Models[i];
                bool sel = buildTarget == "android" && android.Device == android.Serials[i];
                m.Add(model.Length > 0 ? model : android.Serials[i], sel ? "✓" : android.Serials[i], 181 + i, true);
            }
            for (int i = 0; i < android.Avds.Count && i < 15; i++)
                m.Add(android.Avds[i], L.T("start emulator"), 200 + i, !android.Busy);
            if (android.AdbFound && android.Serials.Count == 0 && android.Avds.Count == 0)
                m.Add(android.Listed ? L.T("No Android devices or emulators") : L.T("Looking for devices…"), "", 0, false);
            m.Separator();
            m.Add(L.T("Refresh devices"), "", 198, android.AdbFound);
            m.Add(L.T("Device panel"), ToolVisible(3) ? "✓" : "", 128, true);
            ShowMenu(m, x, y, -1);
        }

        void InitLayout()
        {
            toolSide.Clear();
            toolShown.Clear();
            sideActive.Clear();
            toolRect.Clear();
            for (int t = 0; t < ToolCount; t++)
            {
                toolSide.Add(t == 0 ? 0 : (t == 3 ? 1 : 2));
                toolShown.Add(t != 3);   // el panel del dispositivo aparece al elegir Android
            }
            for (int s = 0; s < 3; s++) sideActive.Add(s == 0 ? 0 : (s == 2 ? 1 : -1));
            for (int i = 0; i < ToolCount * 4; i++) toolRect.Add(0);
            leftWidth = 270;
            rightWidth = 320;
            bottomHeight = 210;
        }

        // Disposición guardada: "lado:visible" por panel y los tamaños de los lados.
        void LoadLayout()
        {
            InitLayout();
            List<string> parts = Text.Split(Settings.Get("layout.tools", ""), ",");
            if (parts.Count >= 3)
                for (int t = 0; t < parts.Count && t < ToolCount; t++)
                {
                    string p = parts[t];
                    if (p.Length == 3 && p[0] >= '0' && p[0] <= '2')
                    {
                        toolSide[t] = (int)p[0] - 48;
                        toolShown[t] = p[2] == '1';
                    }
                }
            delete parts;
            List<string> sizes = Text.Split(Settings.Get("layout.sizes", ""), ",");
            if (sizes.Count == 3)
            {
                leftWidth = (float)Math.Clamp((double)sizes[0].ToInt(), 160.0, 1200.0);
                rightWidth = (float)Math.Clamp((double)sizes[1].ToInt(), 160.0, 1200.0);
                bottomHeight = (float)Math.Clamp((double)sizes[2].ToInt(), 90.0, 1200.0);
            }
            delete sizes;
            for (int s = 0; s < 3; s++) sideActive[s] = -1;
            NormalizeSides();
        }

        void SaveLayout()
        {
            StringBuilder sb = new StringBuilder();
            for (int t = 0; t < ToolCount; t++)
            {
                if (t > 0) sb.Append(",");
                sb.Append((long)toolSide[t]).Append(":").Append(toolShown[t] ? "1" : "0");
            }
            Settings.Set("layout.tools", sb.View());
            sb.Clear();
            sb.Append((long)leftWidth).Append(",").Append((long)rightWidth).Append(",").Append((long)bottomHeight);
            Settings.Set("layout.sizes", sb.View());
            delete sb;
        }

        void ResetLayout()
        {
            InitLayout();
            SaveLayout();
        }

        // Cada lado muestra uno de sus paneles visibles (o ninguno).
        void NormalizeSides()
        {
            for (int s = 0; s < 3; s++)
            {
                int a = sideActive[s];
                if (a >= 0 && toolShown[a] && toolSide[a] == s) continue;
                sideActive[s] = -1;
                for (int t = 0; t < ToolCount; t++)
                    if (sideActive[s] < 0 && toolShown[t] && toolSide[t] == s) sideActive[s] = t;
            }
        }

        bool ToolVisible(int t) => toolShown[t] && sideActive[toolSide[t]] == t;

        void ShowTool(int t)
        {
            if (t < 0 || t >= ToolCount) return;
            toolShown[t] = true;
            sideActive[toolSide[t]] = t;
            NormalizeSides();
            SaveLayout();
        }

        void HideTool(int t)
        {
            toolShown[t] = false;
            NormalizeSides();
            SaveLayout();
        }

        void ToggleTool(int t)
        {
            if (ToolVisible(t)) HideTool(t);
            else ShowTool(t);
        }

        void DockTool(int t, int side)
        {
            if (t < 0 || t >= ToolCount || side < 0 || side > 2) return;
            toolSide[t] = side;
            toolShown[t] = true;
            sideActive[side] = t;
            NormalizeSides();
            SaveLayout();
        }

        static string ToolName(int t) => t == 0 ? "Explorer" : (t == 1 ? "Output" : (t == 2 ? "Problems" : "Device"));

        bool InTool(int t, float x, float y)
        {
            float w = toolRect[t * 4 + 2];
            return w > 0 && x >= toolRect[t * 4] && x < toolRect[t * 4] + w && y >= toolRect[t * 4 + 1] && y < toolRect[t * 4 + 1] + toolRect[t * 4 + 3];
        }

        void OpenToolMenu(float x, float y)
        {
            Menu m = new Menu();
            int side = toolSide[contextTool];
            m.Add(L.T("Dock left"), side == 0 ? "✓" : "", 170, true);
            m.Add(L.T("Dock right"), side == 1 ? "✓" : "", 171, true);
            m.Add(L.T("Dock bottom"), side == 2 ? "✓" : "", 172, true);
            m.Separator();
            m.Add(L.T("Hide"), "", 173, true);
            m.Add(L.T("Reset layout"), "", 127, true);
            ShowMenu(m, x, y, -1);
        }

        // Lado en el que caería el panel arrastrado (cerca de un borde), o -1.
        int DockTargetAt(float x, float y)
        {
            float top = TitleHeight, bottom = r.Height - StatusHeight;
            if (y < top || y > bottom) return -1;
            if (x < r.Width * 0.2f) return 0;
            if (x > r.Width * 0.8f) return 1;
            if (y > top + (bottom - top) * 0.6f) return 2;
            return -1;
        }

        void DrawSide(int side, float x, float y, float w, float h)
        {
            Card(x, y, w, h, Theme.Surface);
            int active = sideActive[side];
            r.PushClip(x, y, w, PanelHeaderHeight);
            float tx = x + 8;
            for (int t = 0; t < ToolCount; t++)
            {
                if (!toolShown[t] || toolSide[t] != side) continue;
                tx += PanelTab(tx, y + 6, L.T(ToolName(t)), t == 2 ? ErrorCount() : 0, ActTool + t, t == active) + 4;
            }
            if (active == 1 && output.Length > 0)
            {
                string clear = L.T("Clear");
                Pill(x + w - PillWidth(clear, "") - 8, y + 5, clear, "", ActClearOutput, 2);
            }
            r.PopClip();
            r.Rect(x, y + PanelHeaderHeight, w, 1, Theme.Border);
            toolRect[active * 4] = x;
            toolRect[active * 4 + 1] = y;
            toolRect[active * 4 + 2] = w;
            toolRect[active * 4 + 3] = h;
            if (active == 0)
            {
                explorer.X = x;
                explorer.Y = y;
                explorer.W = w;
                explorer.H = h;
                explorer.Draw(r, projectName);
            }
            else if (active == 1) DrawOutput(x, y, w, h);
            else if (active == 2) DrawProblems(x, y, w, h);
            else android.Draw(r, x, y, w, h, mouseX, mouseY);
        }

        void DrawOutput(float x, float y, float w, float h)
        {
            float lh = r.Code.LineHeight;
            float y0 = y + PanelHeaderHeight + 4;
            int visible = (int)((h - PanelHeaderHeight - 10) / lh);
            r.PushClip(x, y0, w, h - PanelHeaderHeight - 8);
            List<string> lines = Text.Split(output.View(), "\n");
            if (process != null && process.IsRunning) outputScroll = Math.Max(0, lines.Count - visible);
            if (outputScroll > Math.Max(0, lines.Count - 1)) outputScroll = Math.Max(0, lines.Count - 1);
            if (output.Length == 0) r.Text(r.Ui, x + 16, y0 + 4, L.T("Build or run the project to see its output here."), Theme.TextTertiary);
            for (int i = 0; i < visible + 1; i++)
            {
                int li = outputScroll + i;
                if (li >= lines.Count) break;
                string line = lines[li];
                Color c = line.Contains(": error:") ? Theme.Error
                          : line.StartsWith(">") ? Theme.TextTertiary
                          : line.StartsWith("[") || line.StartsWith("Compilado") ? Theme.TextSecondary : Theme.Text;
                r.Text(r.Code, x + 16, y0 + i * lh + 2, line, c);
            }
            delete lines;
            r.PopClip();
        }

        void DrawProblems(float x, float y, float w, float h)
        {
            float lh = r.Code.LineHeight;
            float y0 = y + PanelHeaderHeight + 4;
            int visible = (int)((h - PanelHeaderHeight - 10) / lh);
            if (problemsScroll > Math.Max(0, problems.Count - 1)) problemsScroll = Math.Max(0, problems.Count - 1);
            r.PushClip(x, y0, w, h - PanelHeaderHeight - 8);
            if (problems.Count == 0) r.Text(r.Ui, x + 16, y0 + 4, L.T("No problems have been detected in the workspace."), Theme.TextTertiary);
            for (int i = 0; i < visible + 1; i++)
            {
                int pi = problemsScroll + i;
                if (pi >= problems.Count) break;
                Problem p = problems[pi];
                float ry = y0 + i * lh;
                bool hover = mouseX >= x && mouseX < x + w && mouseY >= ry && mouseY < ry + lh;
                if (hover) r.RoundRect(x + 6, ry, w - 12, lh, 6, Theme.Hover);
                r.RoundRect(x + 16, ry + lh / 2 - 4, 8, 8, 4, p.Severity == 1 ? Theme.Error : Theme.Info);
                float mx = r.Text(r.Ui, x + 34, ry + 3, p.Message, Theme.Text);
                StringBuilder where = new StringBuilder();
                where.Append(p.File).Append("  ").Append((long)(p.Line + 1)).Append(":").Append((long)(p.Col + 1));
                r.Text(r.Ui, mx + 12, ry + 3, where.View(), Theme.TextTertiary);
                delete where;
            }
            r.PopClip();
        }

        // Mientras se arrastra una pestaña: guías de los tres lados y vista previa del hueco.
        void DrawDockGuides()
        {
            float W = r.Width, top = TitleHeight, bottom = r.Height - StatusHeight;
            if (dockTarget >= 0)
            {
                float px = Gap, py = top, pw = leftWidth, ph = bottom - top;
                if (dockTarget == 1) px = W - Gap - rightWidth;
                if (dockTarget == 1) pw = rightWidth;
                if (dockTarget == 2)
                {
                    px = editorsX;
                    pw = editorsW;
                    py = bottom - bottomHeight;
                    ph = bottomHeight;
                }
                r.RoundRect(px, py, pw, ph, CardRadius, Color.Hex(0x4c8dff, 0.16f));
                r.RoundBorder(px, py, pw, ph, CardRadius, 2, Color.Hex(0x4c8dff));
            }
            DockGuide(Gap + 40, (top + bottom) / 2, 0);
            DockGuide(W - Gap - 40, (top + bottom) / 2, 1);
            DockGuide(W / 2, bottom - 40, 2);
            string name = L.T(ToolName(dockTool));
            float w = r.TextWidth(r.Ui, name) + 24;
            r.Shadow(mouseX + 12, mouseY + 8, w, 26, 8, 12, Theme.Shadow);
            r.RoundRect(mouseX + 12, mouseY + 8, w, 26, 8, Theme.Elevated);
            r.Text(r.Ui, mouseX + 24, mouseY + 12, name, Theme.White);
        }

        void DockGuide(float cx, float cy, int side)
        {
            bool on = dockTarget == side;
            r.Shadow(cx - 22, cy - 22, 44, 44, 10, 14, Theme.Shadow);
            r.RoundRect(cx - 22, cy - 22, 44, 44, 10, on ? Color.Hex(0x4c8dff) : Theme.Elevated);
            r.RoundBorder(cx - 22, cy - 22, 44, 44, 10, 1, on ? Color.Hex(0x4c8dff) : Theme.BorderStrong);
            r.RoundBorder(cx - 11, cy - 9, 22, 18, 3, 1.4f, Theme.White);
            if (side == 0) r.Rect(cx - 11, cy - 9, 7, 18, Theme.White);
            else if (side == 1) r.Rect(cx + 4, cy - 9, 7, 18, Theme.White);
            else r.Rect(cx - 11, cy + 3, 22, 6, Theme.White);
        }

        void DrawStatus(float W, float H)
        {
            bool running = process != null && process.IsRunning;
            float y = H - StatusHeight;
            float cy = y + StatusHeight / 2;
            // Indicador de estado
            Color dot = running ? Theme.Warning : Theme.TextSecondary;
            r.RoundRect(Gap + 10, cy - 3, 7, 7, 3.5f, dot);
            float x = r.Text(r.Ui, Gap + 24, y + 5, status, Theme.TextSecondary) + 18;
            int errors = ErrorCount();
            if (errors > 0)
            {
                string n = String.FromInt(errors);
                string label = L.F(errors == 1 ? "{0} error" : "{0} errors", n, "");
                float bw = r.TextWidth(r.UiSmall, label) + 16;
                r.RoundRect(x, cy - 9, bw, 18, 9, Color.Hex(0xf04f4f, 0.18f));
                r.Text(r.UiSmall, x + 8, cy - 8, label, Theme.Error);
                String.Free(label);
                String.Free(n);
            }

            // Derecha: posición, formato, IntelliSense, GPU, idioma
            StringBuilder sb = new StringBuilder();
            EditorView v = Editor;
            if (v != null)
            {
                string ln = String.FromInt(v.Cursor.Line + 1), col = String.FromInt(v.VisualCol(v.Cursor.Line, v.Cursor.Col) + 1);
                string pos = L.F("Ln {0}, Col {1}", ln, col);
                sb.Append(pos).Append("     ").Append(L.T("Spaces: 4")).Append("     UTF-8     Faset");
                String.Free(pos);
                String.Free(ln);
                String.Free(col);
                if (!analyzer.Available) sb.Append("     ").Append(L.T("IntelliSense unavailable (faset not found)"));
                else if (analyzer.LastFailed) sb.Append("     ").Append(L.T("IntelliSense failed"));
                else if (analyzer.LastDurationMs > 0) sb.Append("     IntelliSense ").Append(analyzer.LastDurationMs).Append(" ms");
                sb.Append("     ");
            }
            sb.Append(r.DeviceName);
            string lang = L.Code.ToUpper();
            float lw = r.TextWidth(r.UiSmall, lang) + 16;
            float lx = W - Gap - 8 - lw;
            bool langHover = hoverButton == ActLanguage;
            r.RoundRect(lx, cy - 9, lw, 18, 9, langHover ? Theme.Active : Theme.Elevated);
            r.Text(r.UiSmall, lx + 8, cy - 8, lang, Theme.Text);
            AddHit(lx, cy - 9, lw, 18, ActLanguage, -1, false);
            String.Free(lang);
            float w = r.TextWidth(r.Ui, sb.View());
            r.Text(r.Ui, lx - w - 16, y + 5, sb.View(), Theme.TextTertiary);
            delete sb;
        }

        string KindLabel(int kind)
        {
            switch (kind)
            {
                case 2: return "m";   // método
                case 3: return "f";   // función
                case 5: return "c";   // campo
                case 6: return "v";   // variable
                case 7: return "C";   // clase
                case 9: return "N";   // namespace
                case 10: return "p";  // propiedad
                case 13: return "E";  // enum
                case 14: return "k";  // palabra clave
                case 20: return "e";  // miembro de enum
                case 21: return "K";  // constante
                case 22: return "S";  // struct
                default: return "·";
            }
        }

        void Popup(float x, float y, float w, float h)
        {
            r.Shadow(x, y, w, h, 10, 18, Theme.Shadow);
            r.RoundRect(x, y, w, h, 10, Theme.Elevated);
            r.RoundBorder(x, y, w, h, 10, 1, Theme.BorderStrong);
        }

        void DrawCompletion()
        {
            EditorView v = Editor;
            if (v == null || filtered.Count == 0) return;
            float lh = 26;
            int visible = Math.Min(9, filtered.Count);
            int first = Math.Clamp(completionSel - visible + 1, 0, Math.Max(0, filtered.Count - visible));
            if (completionSel < first) first = completionSel;
            CompletionItem selected = completions[filtered[completionSel]];
            bool hasDetail = selected.Detail.Length > 0;
            float w = 440;
            float x = v.X + v.GutterWidth(r) - v.ScrollX + v.VisualCol(completionStart.Line, completionStart.Col) * r.Code.CharWidth - 34;
            float y = v.CaretY(r) + r.Code.LineHeight + 4;
            float h = visible * lh + 12 + (hasDetail ? 34 : 0);
            if (y + h > v.Y + v.H) y = v.CaretY(r) - h - 4;
            if (x + w > r.Width - Gap) x = r.Width - Gap - w;
            if (x < Gap) x = Gap;
            Popup(x, y, w, h);
            r.PushClip(x, y, w, h);
            for (int i = 0; i < visible; i++)
            {
                int fi = first + i;
                CompletionItem c = completions[filtered[fi]];
                float ry = y + 6 + i * lh;
                if (fi == completionSel) r.RoundRect(x + 6, ry, w - 12, lh, 6, Theme.Active);
                r.RoundRect(x + 14, ry + 5, 16, 16, 4, fi == completionSel ? Theme.BorderStrong : Theme.Active);
                string kl = KindLabel(c.Kind);
                r.Text(r.UiSmall, x + 22 - r.TextWidth(r.UiSmall, kl) / 2, ry + 6, kl, Theme.TextSecondary);
                r.Text(r.Code, x + 40, ry + 4, c.Label, fi == completionSel ? Theme.White : Theme.Text);
                AddHit(x, ry, w, lh, fi, -2, false);
            }
            if (hasDetail)
            {
                float dy = y + 12 + visible * lh;
                r.Rect(x + 1, dy - 4, w - 2, 1, Theme.Border);
                r.PushClip(x + 12, dy, w - 24, 26);
                r.Text(r.Code, x + 14, dy + 4, selected.Detail, Theme.TextSecondary);
                r.PopClip();
            }
            r.PopClip();
        }

        void DrawTooltip(string text, float x, float y)
        {
            List<string> lines = Text.Split(text, "\n");
            float w = 0;
            for (int i = 0; i < lines.Count; i++) w = (float)Math.Max(w, r.TextWidth(r.Code, lines[i]));
            float lh = r.Code.LineHeight;
            float h = lines.Count * lh + 16;
            w += 28;
            if (x + w > r.Width - Gap) x = r.Width - Gap - w;
            if (y + h > r.Height - StatusHeight) y = y - h - 34;
            Popup(x, y, w, h);
            for (int i = 0; i < lines.Count; i++)
            {
                string l = lines[i];
                bool err = l.StartsWith("error:");
                bool note = l.StartsWith("nota:") || l.StartsWith("note:") || l.StartsWith("warning:");
                float ly = y + 8 + i * lh;
                if (err || note) r.RoundRect(x + 12, ly + lh / 2 - 3, 6, 6, 3, err ? Theme.Error : Theme.Info);
                r.Text(r.Code, x + (err || note ? 24 : 14), ly + 2, l, err ? Theme.Error : Theme.Text);
            }
            delete lines;
        }

        void DrawOverlay()
        {
            float W = r.Width, H = r.Height;
            if (overlay == Overlay.NewProject)
            {
                DrawNewProjectDialog();
                return;
            }
            if (overlay == Overlay.OpenFolder)
            {
                DrawOpenFolderDialog();
                return;
            }
            if (overlay == Overlay.ProjectProperties)
            {
                DrawPropertiesDialog();
                return;
            }
            if (overlay == Overlay.About)
            {
                DrawAboutDialog();
                return;
            }
            if (overlay == Overlay.ConfirmDelete || overlay == Overlay.ConfirmDeleteProject)
            {
                float dw = 480, dh = 176, dx, dy;
                DialogFrame(dw, dh, out dx, out dy);
                string name = Path.GetFileName(targetPath);
                string title = L.F("Delete '{0}'?", name, "");
                r.Text(r.UiBold, dx + 24, dy + 24, title, Theme.White);
                String.Free(title);
                string msg = overlay == Overlay.ConfirmDeleteProject ? L.T("The project folder and all of its files will be deleted from disk.")
                           : targetIsDir ? L.T("The folder and all of its contents will be deleted from disk.")
                                         : L.T("The file will be deleted from disk. This cannot be undone.");
                r.Text(r.Ui, dx + 24, dy + 56, msg, Theme.TextSecondary);
                string del = L.T("Delete"), cancel = L.T("Cancel");
                float bx = dx + dw - 24 - PillWidth(del, "");
                Pill(bx, dy + dh - 50, del, "", ActConfirmA, 3);
                bx -= PillWidth(cancel, "") + 8;
                Pill(bx, dy + dh - 50, cancel, "", ActConfirmC, 2);
                return;
            }
            if (overlay == Overlay.ConfirmQuit || overlay == Overlay.ConfirmCloseTab || overlay == Overlay.ConfirmCloseProject)
            {
                r.Rect(0, 0, W, H, Color.Hex(0x000000, 0.55f));
                float w = 460, h = 168;
                float x = (W - w) / 2, y = H / 3.0f;
                r.Shadow(x, y, w, h, 14, 30, Theme.Shadow);
                r.RoundRect(x, y, w, h, 14, Theme.Elevated);
                r.RoundBorder(x, y, w, h, 14, 1, Theme.BorderStrong);
                r.Text(r.UiBold, x + 24, y + 24, L.T("Unsaved changes"), Theme.White);
                string msg = overlay == Overlay.ConfirmQuit ? L.T("Do you want to save your changes before quitting?")
                           : overlay == Overlay.ConfirmCloseProject ? L.T("Do you want to save your changes before closing the project?")
                                                                    : L.T("Do you want to save this file before closing it?");
                r.Text(r.Ui, x + 24, y + 54, msg, Theme.TextSecondary);
                string a = overlay == Overlay.ConfirmQuit ? L.T("Save all and quit")
                         : overlay == Overlay.ConfirmCloseProject ? L.T("Save all and close") : L.T("Save");
                string b = L.T("Don't save"), c = L.T("Cancel");
                float bx = x + w - 24 - PillWidth(a, "");
                Pill(bx, y + h - 50, a, "", ActConfirmA, 1);
                bx -= PillWidth(b, "") + 8;
                Pill(bx, y + h - 50, b, "", ActConfirmB, 0);
                bx -= PillWidth(c, "") + 8;
                Pill(bx, y + h - 50, c, "", ActConfirmC, 2);
                return;
            }
            r.Rect(0, 0, W, H, Color.Hex(0x000000, 0.35f));
            string title = overlay == Overlay.QuickOpen ? L.T("Open a project file")
                           : overlay == Overlay.Find ? L.T("Find in file  (Enter: next · F3: repeat)")
                           : overlay == Overlay.GoToLine ? L.T("Go to line")
                           : overlay == Overlay.NewFolder ? L.T("New folder name")
                           : overlay == Overlay.Rename ? L.T("New name")
                                                         : L.T("New file name (e.g. Player.fst or Models/Player.fst)");
            float w2 = (float)Math.Min(640.0, W - 40);
            float x2 = (W - w2) / 2, y2 = TitleHeight + 10;
            int rows = overlay == Overlay.QuickOpen ? Math.Min(10, quickFiltered.Count) : 0;
            float h2 = 84 + rows * 30 + (rows > 0 ? 8 : 0);
            Popup(x2, y2, w2, h2);
            r.Text(r.UiSmall, x2 + 18, y2 + 14, title, Theme.TextTertiary);
            r.RoundRect(x2 + 12, y2 + 36, w2 - 24, 34, 9, Theme.Base);
            r.RoundBorder(x2 + 12, y2 + 36, w2 - 24, 34, 9, 1, Theme.BorderStrong);
            overlayInputX = x2 + 12;
            overlayInputY = y2 + 36;
            overlayInputW = w2 - 24;
            float ex = r.Text(r.Code, x2 + 24, y2 + 44, overlayInput.View(), Theme.White);
            if (((Environment.TickCount64() / 530) % 2) == 0) r.RoundRect(ex + 1, y2 + 44, 2, 18, 1, Theme.Caret);
            if (overlay == Overlay.QuickOpen)
            {
                int first = Math.Clamp(overlaySel - rows + 1, 0, Math.Max(0, quickFiltered.Count - rows));
                for (int i = 0; i < rows; i++)
                {
                    int qi = first + i;
                    string path = quickFiles[quickFiltered[qi]];
                    float ry = y2 + 80 + i * 30;
                    bool hover = mouseX >= x2 && mouseX < x2 + w2 && mouseY >= ry && mouseY < ry + 30;
                    if (qi == overlaySel) r.RoundRect(x2 + 8, ry, w2 - 16, 30, 7, Theme.Active);
                    else if (hover) r.RoundRect(x2 + 8, ry, w2 - 16, 30, 7, Theme.Hover);
                    bool fst = path.EndsWith(".fst");
                    if (fst)
                    {
                        r.RoundRect(x2 + 20, ry + 8, 12, 14, 3, Theme.Text);
                        r.Text(r.UiSmall, x2 + 23, ry + 7, "F", Theme.Black);
                    }
                    else r.RoundBorder(x2 + 20, ry + 8, 12, 14, 3, 1.3f, Theme.TextSecondary);
                    float nx = r.Text(r.Ui, x2 + 42, ry + 6, Path.GetFileName(path), Theme.White);
                    string rel = path.StartsWith(rootFolder) ? path.Substring(Math.Min(path.Length, rootFolder.Length + 1)) : path;
                    r.Text(r.Ui, nx + 12, ry + 6, Path.GetDirectoryName(rel), Theme.TextTertiary);
                    AddHit(x2, ry, w2, 30, qi, -3, false);
                }
            }
        }

        float DrawMenuBar(float x)
        {
            for (int i = 0; i < 6; i++)
            {
                string title = i == 0 ? L.T("File") : i == 1 ? L.T("Edit") : i == 2 ? L.T("View") : i == 3 ? L.T("Build") : i == 4 ? L.T("Project") : L.T("Help");
                float w = r.TextWidth(r.Ui, title) + 20;
                bool open = menu != null && menu.Owner == i;
                bool hover = mouseY < TitleHeight && mouseX >= x && mouseX < x + w && mouseY >= 10 && mouseY < 38;
                if (open) r.RoundRect(x, 11, w, 26, 8, Theme.Active);
                else if (hover) r.RoundRect(x, 11, w, 26, 8, Theme.Hover);
                r.Text(r.Ui, x + 10, 15, title, open || hover ? Theme.White : Theme.TextSecondary);
                AddHit(x, 11, w, 26, i, -4, false);
                x += w + 2;
            }
            return x;
        }

        // Botón de diálogo (grupo -5).
        float DialogButton(float x, float y, string label, int id, int style)
        {
            float w = Pill(x, y, label, "", id, style);
            hits.Pop();
            AddHit(x, y, w, 28, id, -5, false);
            return w;
        }

        // Control segmentado: opciones separadas por '|'. Devuelve el ancho.
        float Segmented(float x, float y, string options, int selected, int baseId)
        {
            List<string> parts = Text.Split(options, "|");
            float total = 4;
            for (int i = 0; i < parts.Count; i++) total += r.TextWidth(r.Ui, parts[i]) + 24;
            r.RoundRect(x, y, total, 30, 15, Theme.Base);
            r.RoundBorder(x, y, total, 30, 15, 1, Theme.Border);
            float cx = x + 2;
            for (int i = 0; i < parts.Count; i++)
            {
                float w = r.TextWidth(r.Ui, parts[i]) + 24;
                bool hover = mouseX >= cx && mouseX < cx + w && mouseY >= y && mouseY < y + 30;
                if (i == selected) r.RoundRect(cx, y + 2, w, 26, 13, Theme.Active);
                else if (hover) r.RoundRect(cx, y + 2, w, 26, 13, Theme.Hover);
                r.Text(r.Ui, cx + 12, y + 6, parts[i], i == selected ? Theme.White : Theme.TextTertiary);
                AddHit(cx, y, w, 30, baseId + i, -5, false);
                cx += w;
            }
            delete parts;
            return total;
        }

        void Toggle(float x, float y, bool on, int id)
        {
            r.RoundRect(x, y, 40, 22, 11, on ? Theme.White : Theme.Active);
            r.RoundRect(on ? x + 20 : x + 2, y + 2, 18, 18, 9, on ? Theme.Black : Theme.TextSecondary);
            AddHit(x, y, 40, 22, id, -5, false);
        }

        // Fondo oscurecido y tarjeta del diálogo.
        void DialogFrame(float w, float h, out float x, out float y)
        {
            float W = r.Width, H = r.Height;
            r.Rect(0, 0, W, H, Color.Hex(0x000000, 0.55f));
            x = (float)Math.Floor((W - w) / 2);
            y = (float)Math.Max(TitleHeight + 10.0, Math.Floor((H - h) / 2.2));
            r.Shadow(x, y, w, h, 14, 32, Theme.Shadow);
            r.RoundRect(x, y, w, h, 14, Theme.Elevated);
            r.RoundBorder(x, y, w, h, 14, 1, Theme.BorderStrong);
        }

        void DrawHub(float W, float H)
        {
            float cw = (float)Math.Min(1080.0, W - 80);
            float x0 = (float)Math.Floor((W - cw) / 2);
            float y0 = TitleHeight + 48;
            r.Logo(x0, y0, 44, Theme.White);
            r.Text(r.Title, x0 + 62, y0 - 2, "FasetStudio", Theme.White);
            r.Text(r.Ui, x0 + 63, y0 + 30, L.T("Native code with the elegance of C# and the power of C++"), Theme.TextTertiary);

            float listW = cw - 420;
            float ly = y0 + 96;
            r.Text(r.UiBold, x0, ly, L.T("Open recent"), Theme.Text);
            List<string> recent = RecentProjects();
            float rowH = 58;
            float ry = ly + 34;
            if (recent.Count == 0)
            {
                r.RoundRect(x0, ry, listW, 120, 12, Theme.Surface);
                r.RoundBorder(x0, ry, listW, 120, 12, 1, Theme.Border);
                r.Text(r.Ui, x0 + 24, ry + 40, L.T("No recent projects yet."), Theme.TextSecondary);
                r.Text(r.Ui, x0 + 24, ry + 64, L.T("Create a new project or open an existing folder to get started."), Theme.TextTertiary);
            }
            int maxRows = (int)((H - StatusHeight - ry - 20) / (rowH + 6));
            for (int i = 0; i < recent.Count && i < maxRows; i++)
            {
                string path = recent[i];
                float y = ry + i * (rowH + 6);
                bool hover = mouseX >= x0 && mouseX < x0 + listW && mouseY >= y && mouseY < y + rowH && overlay == Overlay.None;
                r.RoundRect(x0, y, listW, rowH, 12, hover ? Theme.Elevated : Theme.Surface);
                if (hover) r.RoundBorder(x0, y, listW, rowH, 12, 1, Theme.BorderStrong);
                r.RoundRect(x0 + 14, y + 13, 32, 32, 9, Theme.Active);
                r.Logo(x0 + 20, y + 19, 20, Theme.White);
                r.Text(r.UiBold, x0 + 60, y + 10, Path.GetFileName(path), Theme.White);
                r.PushClip(x0 + 60, y, listW - 240, rowH);
                r.Text(r.UiSmall, x0 + 60, y + 32, path, Theme.TextTertiary);
                r.PopClip();
                AddHit(x0, y, listW - 170, rowH, i, -6, false);
                if (hover)
                {
                    string removeLabel = L.T("Remove from list"), deleteLabel = L.T("Delete");
                    float dw = PillWidth(deleteLabel, "");
                    float bx = x0 + listW - 14 - dw;
                    bool delHover = mouseX >= bx && mouseX < bx + dw && mouseY >= y + 15 && mouseY < y + 43;
                    if (delHover) r.RoundRect(bx, y + 15, dw, 28, 14, Color.Hex(0xf04f4f, 0.16f));
                    r.Text(r.Ui, bx + 13, y + 21, deleteLabel, Theme.Error);
                    AddHit(bx, y + 15, dw, 28, i, -8, false);
                    float rw = PillWidth(removeLabel, "");
                    bx -= rw + 4;
                    bool remHover = mouseX >= bx && mouseX < bx + rw && mouseY >= y + 15 && mouseY < y + 43;
                    if (remHover) r.RoundRect(bx, y + 15, rw, 28, 14, Theme.Active);
                    r.Text(r.Ui, bx + 13, y + 21, removeLabel, Theme.TextSecondary);
                    AddHit(bx, y + 15, rw, 28, i, -7, false);
                }
                else AddHit(x0 + listW - 170, y, 170, rowH, i, -6, false);
            }
            FreeStrings(recent);

            // Columna derecha: empezar
            float cx = x0 + listW + 40;
            float cardW = cw - listW - 40;
            r.Text(r.UiBold, cx, ly, L.T("Get started"), Theme.Text);
            HubCard(cx, ly + 34, cardW, L.T("Create a new project"), L.T("Console, library, desktop or Android app"), ActNewProject, 0);
            HubCard(cx, ly + 34 + 92, cardW, L.T("Open a project or folder"), L.T("Browse your folders for a .fstproj project"), ActOpenFolder, 1);
            r.PushClip(cx, ly + 230, cardW, 40);
            r.Text(r.UiSmall, cx, ly + 234, L.T("Tip: right-click files in the explorer to rename, move or delete them."), Theme.TextTertiary);
            r.PopClip();

            // Pie
            StringBuilder sb = new StringBuilder();
            sb.Append("FasetStudio 0.3   ·   Vulkan   ·   ").Append(r.DeviceName);
            r.Text(r.UiSmall, Gap + 14, H - StatusHeight + 7, sb.View(), Theme.TextTertiary);
            delete sb;
        }

        void HubCard(float x, float y, float w, string title, string subtitle, int id, int icon)
        {
            float h = 80;
            bool hover = hoverButton == id && overlay == Overlay.None;
            r.RoundRect(x, y, w, h, 12, hover ? Theme.Elevated : Theme.Surface);
            r.RoundBorder(x, y, w, h, 12, 1, hover ? Theme.TextTertiary : Theme.Border);
            r.RoundRect(x + 16, y + 20, 40, 40, 10, hover ? Theme.White : Theme.Active);
            Color ic = hover ? Theme.Black : Theme.White;
            if (icon == 0)
            {
                r.RoundRect(x + 35, y + 30, 2, 20, 1, ic);
                r.RoundRect(x + 26, y + 39, 20, 2, 1, ic);
            }
            else
            {
                r.RoundRect(x + 26, y + 34, 20, 15, 3, ic);
                r.RoundRect(x + 26, y + 31, 9, 5, 2, ic);
            }
            r.Text(r.UiBold, x + 72, y + 20, title, Theme.White);
            r.PushClip(x + 72, y, w - 84, h);
            r.Text(r.UiSmall, x + 72, y + 44, subtitle, Theme.TextTertiary);
            r.PopClip();
            AddHit(x, y, w, h, id, -1, false);
        }

        // Texto en varias líneas cortado por palabras.
        void WrapText(Font f, float x, float y, float maxW, string text, Color c)
        {
            List<string> words = Text.Split(text, " ");
            StringBuilder line = new StringBuilder();
            float ly = y;
            for (int i = 0; i < words.Count; i++)
            {
                int before = line.Length;
                if (before > 0) line.Append(" ");
                line.Append(words[i]);
                if (before > 0 && r.TextWidth(f, line.View()) > maxW)
                {
                    string keep = String.Copy(line.View().Substring(0, before));
                    r.Text(f, x, ly, keep, c);
                    String.Free(keep);
                    ly += f.LineHeight;
                    line.Clear();
                    line.Append(words[i]);
                }
            }
            if (line.Length > 0) r.Text(f, x, ly, line.View(), c);
            delete line;
            delete words;
        }

        const int TemplateCount = 5;

        string TemplateTitle(int i) => i == 0 ? L.T("Console app") : i == 1 ? L.T("Class library") : i == 2 ? L.T("Window app")
                                     : i == 3 ? L.T("Desktop app (UI)") : L.T("Android app");

        string TemplateDescription(int i) => i == 0 ? L.T("A program that runs in the terminal") : i == 1 ? L.T("Reusable code for other projects")
                                           : i == 2 ? L.T("A Windows app without a console") : i == 3 ? L.T("Windows and Linux, visual designer")
                                           : L.T("APK for phones and the emulator, visual designer");

        // Etiquetas separadas por ';' (se traducen una a una).
        string TemplateTags(int i) => i == 0 ? "Faset;Linux;Windows;Console" : i == 1 ? "Faset;Linux;Windows;Android;Library"
                                    : i == 2 ? "Faset;Windows;Desktop" : i == 3 ? "Faset;Linux;Windows;Desktop;UI" : "Faset;Android;Mobile;UI";

        string TemplateOutput(int i) => i == 0 ? "Exe" : i == 1 ? "Library" : i == 2 ? "WinExe" : i == 3 ? "Exe + .fstui" : "APK";

        static bool ContainsIgnoreCase(string text, string query)
        {
            if (query.Length == 0) return true;
            for (int i = 0; i + query.Length <= text.Length; i++)
                if (text.Substring(i, query.Length).EqualsIgnoreCase(query)) return true;
            return false;
        }

        bool TemplateVisible(int i)
        {
            string q = fieldExtra.Text.Trim();
            if (q.Length == 0) return true;
            if (ContainsIgnoreCase(TemplateTitle(i), q) || ContainsIgnoreCase(TemplateDescription(i), q)) return true;
            string tags = TemplateTags(i);
            int a = 0;
            for (int k = 0; k <= tags.Length; k++)
            {
                if (k < tags.Length && tags[k] != ';') continue;
                string tag = tags.Substring(a, k - a);
                if (ContainsIgnoreCase(tag, q) || ContainsIgnoreCase(L.T(tag), q)) return true;
                a = k + 1;
            }
            return false;
        }

        // Mueve la selección a la plantilla visible anterior (-1) o siguiente (+1).
        void StepTemplate(int dir)
        {
            for (int i = projectTemplate + dir; i >= 0 && i < TemplateCount; i += dir)
                if (TemplateVisible(i)) { projectTemplate = i; return; }
        }

        float DrawTags(float x, float y, string tags, float maxX)
        {
            int a = 0;
            for (int k = 0; k <= tags.Length; k++)
            {
                if (k < tags.Length && tags[k] != ';') continue;
                string tag = L.T(tags.Substring(a, k - a));
                a = k + 1;
                float tw = r.TextWidth(r.UiSmall, tag) + 14;
                if (x + tw > maxX) break;
                r.RoundRect(x, y, tw, 19, 5, Theme.Base);
                r.RoundBorder(x, y, tw, 19, 5, 1, Theme.Border);
                r.Text(r.UiSmall, x + 7, y + 1, tag, Theme.TextSecondary);
                x += tw + 6;
            }
            return x;
        }

        void DrawTemplateIcon(int i, float x, float y, float s, bool sel)
        {
            Color bg = sel ? Theme.White : Theme.Active, fg = sel ? Theme.Black : Theme.White;
            r.RoundRect(x, y, s, s, 9, bg);
            if (i == 0)
            {
                string t = ">_";
                r.Text(r.CodeBold, x + (s - r.TextWidth(r.CodeBold, t)) / 2, y + s / 2 - 9, t, fg);
            }
            else if (i == 1)
            {
                string t = "{ }";
                r.Text(r.CodeBold, x + (s - r.TextWidth(r.CodeBold, t)) / 2, y + s / 2 - 9, t, fg);
            }
            else if (i == 2 || i == 3)
            {
                r.RoundBorder(x + 9, y + 11, s - 18, s - 22, 3, 1.5f, fg);
                r.Rect(x + 9, y + 11, s - 18, 4, fg);
                if (i == 3)
                {
                    r.Rect(x + 13, y + 19, 8, 3, fg);
                    r.RoundRect(x + 13, y + 24, s - 26, 5, 2, fg);
                }
            }
            else
            {
                r.RoundBorder(x + 13, y + 7, s - 26, s - 14, 3, 1.5f, fg);
                r.Rect(x + s / 2 - 3, y + s - 12, 6, 2, fg);
            }
        }

        // Parte un texto sin espacios (una ruta) por caracteres, hasta maxLines líneas.
        void WrapPath(Font f, float x, float y, float maxW, string text, Color c, int maxLines)
        {
            int a = 0;
            for (int line = 0; line < maxLines && a < text.Length; line++)
            {
                int b = a + 1;
                while (b < text.Length && r.TextWidth(f, text.Substring(a, b + 1 - a)) <= maxW) b++;
                r.Text(f, x, y + line * 18, text.Substring(a, b - a), c);
                a = b;
            }
        }

        void DrawNewProjectDialog()
        {
            float w = 1000, h = 590, x, y;
            DialogFrame(w, h, out x, out y);
            r.Text(r.Title, x + 28, y + 24, L.T("Create a new project"), Theme.White);

            // Columna izquierda: buscador y lista de plantillas.
            float lx = x + 28, lw = 560;
            fieldExtra.Draw(r, lx, y + 70, lw, L.T("Search for templates"));
            float ly = y + 116, listH = h - 116 - 76;
            r.RoundRect(lx, ly, lw, listH, 10, Theme.Base);
            r.RoundBorder(lx, ly, lw, listH, 10, 1, Theme.Border);
            if (!TemplateVisible(projectTemplate))
                for (int i = 0; i < TemplateCount; i++)
                    if (TemplateVisible(i)) { projectTemplate = i; break; }
            r.PushClip(lx, ly + 4, lw, listH - 8);
            int shown = 0;
            for (int i = 0; i < TemplateCount; i++)
            {
                if (!TemplateVisible(i)) continue;
                float rx = lx + 6, ry = ly + 6 + shown * 76, rw = lw - 12;
                shown++;
                bool sel = projectTemplate == i;
                bool hover = mouseX >= rx && mouseX < rx + rw && mouseY >= ry && mouseY < ry + 72;
                if (sel || hover) r.RoundRect(rx, ry, rw, 72, 8, sel ? Theme.Active : Theme.Hover);
                if (sel) r.RoundRect(rx, ry + 14, 3, 44, 1.5f, Theme.White);
                DrawTemplateIcon(i, rx + 16, ry + 16, 40, sel);
                r.Text(r.UiBold, rx + 72, ry + 9, TemplateTitle(i), Theme.White);
                r.PushClip(rx + 72, ry + 28, rw - 84, 20);
                r.Text(r.UiSmall, rx + 72, ry + 30, TemplateDescription(i), Theme.TextSecondary);
                r.PopClip();
                DrawTags(rx + 72, ry + 48, TemplateTags(i), rx + rw - 12);
                AddHit(rx, ry, rw, 72, 10 + i, -5, false);
            }
            if (shown == 0) r.Text(r.Ui, lx + 20, ly + 18, L.T("No templates match your search."), Theme.TextTertiary);
            r.PopClip();

            // Columna derecha: configuración del proyecto.
            float cx = lx + lw + 28, cw = x + w - 28 - cx;
            r.Text(r.UiSmall, cx, y + 72, L.T("CONFIGURE YOUR NEW PROJECT"), Theme.TextTertiary);
            DrawTemplateIcon(projectTemplate, cx, y + 96, 34, true);
            r.PushClip(cx + 46, y + 96, cw - 46, 40);
            r.Text(r.UiBold, cx + 46, y + 97, TemplateTitle(projectTemplate), Theme.White);
            r.Text(r.UiSmall, cx + 46, y + 116, TemplateOutput(projectTemplate), Theme.TextTertiary);
            r.PopClip();
            WrapText(r.UiSmall, cx, y + 144, cw, TemplateDescription(projectTemplate), Theme.TextSecondary);
            DrawTags(cx, y + 186, TemplateTags(projectTemplate), cx + cw);

            float fy = y + 232;
            r.Text(r.UiSmall, cx, fy, L.T("PROJECT NAME"), Theme.TextTertiary);
            fieldName.Draw(r, cx, fy + 20, cw, "MiProyecto");
            r.Text(r.UiSmall, cx, fy + 70, L.T("LOCATION"), Theme.TextTertiary);
            fieldLocation.Draw(r, cx, fy + 90, cw, "~/FasetProjects");
            r.Text(r.UiSmall, cx, fy + 140, L.T("The project will be created in:"), Theme.TextTertiary);
            StringBuilder where = new StringBuilder();
            where.Append(fieldLocation.Text).Append("/").Append(fieldName.Text);
            WrapPath(r.UiSmall, cx, fy + 160, cw, where.View(), Theme.TextSecondary, 4);
            delete where;

            string create = L.T("Create"), cancel = L.T("Cancel");
            float bx = x + w - 28 - PillWidth(create, "");
            DialogButton(bx, y + h - 50, create, 21, 1);
            bx -= PillWidth(cancel, "") + 8;
            DialogButton(bx, y + h - 50, cancel, 20, 2);
        }

        void DrawOpenFolderDialog()
        {
            float w = 760, h = 540, x, y;
            DialogFrame(w, h, out x, out y);
            r.Text(r.Title, x + 28, y + 24, L.T("Open a project or folder"), Theme.White);
            float up = Pill(x + 28, y + 70, L.T("Up"), "▲", 32, 0);
            hits.Pop();
            AddHit(x + 28, y + 70, up, 28, 32, -5, false);
            fieldExtra.Draw(r, x + 28 + up + 10, y + 67, w - 56 - up - 10, "/home");
            float ly = y + 116;
            float listH = h - 116 - 70;
            r.RoundRect(x + 28, ly, w - 56, listH, 10, Theme.Base);
            r.PushClip(x + 28, ly + 4, w - 56, listH - 8);
            int rowsShown = 0;
            if (browseEntries != null)
            {
                for (int i = 0; i < browseEntries.Count; i++)
                {
                    DirEntry e = browseEntries[i];
                    bool proj = e.Name.EndsWith(".fstproj");
                    if ((!e.IsDirectory && !proj) || e.Name.StartsWith(".")) continue;
                    float ry = ly + 6 + rowsShown * 32;
                    rowsShown++;
                    if (ry > ly + listH) break;
                    bool hover = mouseX >= x + 28 && mouseX < x + w - 28 && mouseY >= ry && mouseY < ry + 30;
                    if (hover) r.RoundRect(x + 34, ry, w - 68, 30, 7, Theme.Hover);
                    if (proj)
                    {
                        r.RoundRect(x + 46, ry + 7, 16, 16, 4, Theme.White);
                        r.Logo(x + 48, ry + 9, 12, Theme.Black);
                        r.Text(r.UiBold, x + 72, ry + 6, e.Name, Theme.White);
                        r.Text(r.UiSmall, x + 80 + r.TextWidth(r.UiBold, e.Name), ry + 8, L.T("project"), Theme.TextTertiary);
                    }
                    else
                    {
                        r.RoundRect(x + 46, ry + 11, 16, 11, 2, Theme.TextSecondary);
                        r.RoundRect(x + 46, ry + 9, 7, 4, 1, Theme.TextSecondary);
                        r.Text(r.Ui, x + 72, ry + 6, e.Name, Theme.Text);
                    }
                    AddHit(x + 28, ry, w - 56, 30, 1000 + i, -5, false);
                }
            }
            if (rowsShown == 0) r.Text(r.Ui, x + 46, ly + 16, L.T("This folder is empty."), Theme.TextTertiary);
            r.PopClip();
            string open = L.T("Open this folder"), cancel = L.T("Cancel");
            float bx = x + w - 28 - PillWidth(open, "");
            DialogButton(bx, y + h - 50, open, 31, 1);
            bx -= PillWidth(cancel, "") + 8;
            DialogButton(bx, y + h - 50, cancel, 30, 2);
        }

        void DrawPropertiesDialog()
        {
            if (props == null) return;
            float w = 760, h = 640, x, y;
            DialogFrame(w, h, out x, out y);
            r.Text(r.Title, x + 28, y + 24, L.T("Project properties"), Theme.White);
            r.PushClip(x + 28, y + 56, w - 56, 20);
            r.Text(r.UiSmall, x + 28, y + 58, props.Path, Theme.TextTertiary);
            r.PopClip();
            float lx = x + 28, cx = x + 230, ry = y + 96;
            r.Text(r.Ui, lx, ry + 8, L.T("Assembly name"), Theme.TextSecondary);
            fieldName.Draw(r, cx, ry, w - 28 - (cx - x), "");
            ry += 50;
            r.Text(r.Ui, lx, ry + 6, L.T("Output type"), Theme.TextSecondary);
            int ot = props.OutputType == "WinExe" ? 1 : (props.OutputType == "Library" ? 2 : 0);
            string otLabels = String.Concat(L.T("Console app"), "|", String.Concat(L.T("Window app"), "|", L.T("Library")));
            Segmented(cx, ry, otLabels, ot, 100);
            ry += 46;
            r.Text(r.Ui, lx, ry + 6, L.T("Target platform"), Theme.TextSecondary);
            int tp = props.TargetPlatform == "linux" ? 1 : props.TargetPlatform == "windows" ? 2 : props.TargetPlatform == "android" ? 3 : 0;
            Segmented(cx, ry, "native|Linux|Windows|Android", tp, 110);
            ry += 46;
            r.Text(r.Ui, lx, ry + 6, L.T("Architecture"), Theme.TextSecondary);
            int ar = props.TargetArch == "x86_64" ? 1 : props.TargetArch == "arm64" ? 2 : props.TargetArch == "x86" ? 3 : props.TargetArch == "armv7" ? 4 : 0;
            Segmented(cx, ry, "auto|x86_64|arm64|x86|armv7", ar, 120);
            ry += 46;
            r.Text(r.Ui, lx, ry + 6, L.T("Configuration"), Theme.TextSecondary);
            Segmented(cx, ry, "Debug|Release", props.Configuration == "Release" ? 1 : 0, 130);
            ry += 46;
            r.Text(r.Ui, lx, ry + 3, L.T("Static linking"), Theme.TextSecondary);
            Toggle(cx, ry, props.StaticLink, 140);
            ry += 44;
            r.Rect(x + 28, ry, w - 56, 1, Theme.Border);
            ry += 16;
            ry = DrawEditableList(L.T("Project references"), props.References, fieldExtra, "../Library/Library.fstproj", 200, 150, lx, cx, ry, w - 28 - (cx - x));
            ry = DrawEditableList(L.T("Native libraries"), props.NativeLibraries, fieldExtra2, "user32", 300, 151, lx, cx, ry, w - 28 - (cx - x));
            string save = L.T("Save"), cancel = L.T("Cancel");
            float bx = x + w - 28 - PillWidth(save, "");
            DialogButton(bx, y + h - 50, save, 161, 1);
            bx -= PillWidth(cancel, "") + 8;
            DialogButton(bx, y + h - 50, cancel, 160, 2);
        }

        float DrawEditableList(string label, List<string> items, TextField field, string placeholder, int removeBase, int addId, float lx, float cx, float y, float w)
        {
            r.Text(r.Ui, lx, y + 8, label, Theme.TextSecondary);
            for (int i = 0; i < items.Count && i < 4; i++)
            {
                float ry = y + i * 30;
                r.RoundRect(cx, ry, w, 26, 8, Theme.Base);
                r.Text(r.Code, cx + 12, ry + 4, items[i], Theme.Text);
                bool hover = mouseX >= cx + w - 28 && mouseX < cx + w && mouseY >= ry && mouseY < ry + 26;
                r.Text(r.Icons, cx + w - 20, ry + 5, "×", hover ? Theme.White : Theme.TextTertiary);
                AddHit(cx + w - 28, ry, 28, 26, removeBase + i, -5, false);
            }
            float fy = y + Math.Min(items.Count, 4) * 30;
            string add = L.T("Add");
            float aw = PillWidth(add, "");
            field.Draw(r, cx, fy, w - aw - 8, placeholder);
            DialogButton(cx + w - aw, fy + 3, add, addId, 0);
            return fy + 50;
        }

        void DrawAboutDialog()
        {
            float w = 440, h = 300, x, y;
            DialogFrame(w, h, out x, out y);
            r.Logo(x + w / 2 - 28, y + 30, 56, Theme.White);
            string title = "FasetStudio";
            r.Text(r.Title, x + (w - r.TextWidth(r.Title, title)) / 2, y + 100, title, Theme.White);
            string version = L.T("Version 0.3 — written in Faset, rendered with Vulkan");
            r.Text(r.Ui, x + (w - r.TextWidth(r.Ui, version)) / 2, y + 140, version, Theme.TextSecondary);
            r.Text(r.UiSmall, x + (w - r.TextWidth(r.UiSmall, r.DeviceName)) / 2, y + 166, r.DeviceName, Theme.TextTertiary);
            string close = L.T("Close");
            DialogButton(x + (w - PillWidth(close, "")) / 2, y + h - 54, close, 1, 1);
        }

        // Forma del puntero según lo que hay bajo el ratón.
        void UpdateCursor()
        {
            if (win == null) return;
            CursorKind kind = CursorKind.Arrow;
            if (dragSplitter == 1 || dragSplitter == 3 || dragSplitter == 4) kind = CursorKind.ResizeHorizontal;
            else if (dragSplitter == 2) kind = CursorKind.ResizeVertical;
            else if (menu != null)
            {
                if (menu.ItemAt(mouseX, mouseY) >= 0) kind = CursorKind.Hand;
            }
            else if (overlay != Overlay.None)
            {
                bool dialog = overlay == Overlay.NewProject || overlay == Overlay.OpenFolder || overlay == Overlay.ProjectProperties;
                bool overInput = !dialog && mouseX >= overlayInputX && mouseX < overlayInputX + overlayInputW && mouseY >= overlayInputY && mouseY < overlayInputY + 34;
                if (overInput && !IsConfirm(overlay) && overlay != Overlay.About) kind = CursorKind.Text;
                if (dialog && (fieldName.Contains(mouseX, mouseY) || fieldLocation.Contains(mouseX, mouseY) ||
                               fieldExtra.Contains(mouseX, mouseY) || fieldExtra2.Contains(mouseX, mouseY)))
                    kind = CursorKind.Text;
                for (int i = 0; i < hits.Count; i++)
                    if (hits[i].Contains(mouseX, mouseY) && (hits[i].Group == -3 || hits[i].Group == -5 || (hits[i].Id >= ActConfirmA && hits[i].Id <= ActConfirmC)))
                        kind = CursorKind.Hand;
            }
            else if (HubMode)
            {
                for (int i = 0; i < hits.Count; i++)
                    if (hits[i].Contains(mouseX, mouseY)) kind = CursorKind.Hand;
            }
            else
            {
                int split = SplitterAt(mouseX, mouseY);
                if (split == 1 || split == 3 || split == 4) kind = CursorKind.ResizeHorizontal;
                else if (split == 2) kind = CursorKind.ResizeVertical;
                else
                {
                    bool overHit = false;
                    for (int i = 0; i < hits.Count; i++)
                        if (hits[i].Contains(mouseX, mouseY)) overHit = true;
                    if (overHit || explorer.RowAt(mouseX, mouseY) >= 0 || (InTool(3, mouseX, mouseY) && android.Contains(mouseX, mouseY))) kind = CursorKind.Hand;
                    else if (InTool(2, mouseX, mouseY) && mouseY >= toolRect[9] + PanelHeaderHeight && ProblemRowAt(mouseY) >= 0) kind = CursorKind.Hand;
                    else
                    {
                        for (int k = 0; k < groups.Count; k++)
                        {
                            EditorView v = groups[k].Current;
                            if (v != null && v.Designer != null && v.DesignMode)
                            {
                                if (mouseX >= v.X && mouseX < v.X + v.W && mouseY >= v.Y && mouseY < v.Y + v.H)
                                    kind = v.Designer.CursorAt(mouseX, mouseY);
                            }
                            else if (v != null && mouseX >= v.X + v.GutterWidth(r) - 4 && mouseX < v.X + v.W - 10 && mouseY >= v.Y && mouseY < v.Y + v.H)
                                kind = CursorKind.Text;
                        }
                    }
                }
            }
            win.SetCursor(kind);
        }

        // 1: lado izquierdo, 2: lado inferior, 3: entre los dos editores, 4: lado derecho, 0: ninguno.
        int SplitterAt(float x, float y)
        {
            float top = TitleHeight, bottom = r.Height - StatusHeight;
            if (y > top && y < bottom && sideActive[0] >= 0 && Math.Abs(x - splitLeftX) <= Gap / 2 + 2) return 1;
            if (y > top && y < bottom && sideActive[1] >= 0 && Math.Abs(x - splitRightX) <= Gap / 2 + 2) return 4;
            if (sideActive[2] >= 0 && x > bottomX && x < bottomX + bottomW && Math.Abs(y - splitBottomY) <= Gap / 2 + 2) return 2;
            if (groups.Count == 2 && y > top && y < editorsBottom && Math.Abs(x - splitGroupsX) <= Gap / 2 + 2) return 3;
            return 0;
        }

        int ProblemRowAt(float y)
        {
            float lh = r.Code.LineHeight;
            int row = problemsScroll + (int)Math.Floor((y - toolRect[9] - PanelHeaderHeight - 4) / lh);
            return row >= 0 && row < problems.Count ? row : -1;
        }

        // ------------------------------------------------------------------ guiones de prueba

        // Ejecuta una orden de prueba (modo --script): open, goto, type, key, hover, analyze,
        // split, build, run, panel, quickopen, find.
        public void RunCommand(string command)
        {
            string c = command.Trim();
            int sp = c.IndexOf(" ");
            string verb = sp < 0 ? c : c.Substring(0, sp);
            string arg = sp < 0 ? "" : c.Substring(sp + 1);
            needsRedraw = true;
            if (verb == "open") OpenFile(arg);
            else if (verb == "goto")
            {
                List<string> p = Text.Split(arg, " ");
                if (Editor != null && p.Count >= 2) Editor.GoToLine(p[0].ToInt() - 1, p[1].ToInt() - 1, r);
                delete p;
            }
            else if (verb == "type")
            {
                int i = 0;
                while (i < arg.Length)
                {
                    char ch = Renderer.NextChar(arg, ref i);
                    Event e = new Event();
                    e.Kind = EventKind.KeyDown;
                    e.Char = ch;
                    e.Key = ch;
                    HandleKey(e);
                }
            }
            else if (verb == "key")
            {
                Event e = new Event();
                e.Kind = EventKind.KeyDown;
                string k = arg;
                if (k.StartsWith("alt+")) { e.Alt = true; k = k.Substring(4); }
                if (k.StartsWith("ctrl+")) { e.Ctrl = true; k = k.Substring(5); }
                if (k.StartsWith("shift+")) { e.Shift = true; k = k.Substring(6); }
                if (k == "enter") e.Key = Keys.Return;
                else if (k == "tab") e.Key = Keys.Tab;
                else if (k == "escape") e.Key = Keys.Escape;
                else if (k == "down") e.Key = Keys.Down;
                else if (k == "up") e.Key = Keys.Up;
                else if (k == "left") e.Key = Keys.Left;
                else if (k == "right") e.Key = Keys.Right;
                else if (k == "end") e.Key = Keys.End;
                else if (k == "home") e.Key = Keys.Home;
                else if (k == "backspace") e.Key = Keys.BackSpace;
                else if (k == "delete") e.Key = Keys.Delete;
                else if (k == "f5") e.Key = Keys.F5;
                else if (k == "f12") e.Key = Keys.F12;
                else if (k == "space")
                {
                    e.Key = ' ';
                    if (!e.Ctrl) e.Char = ' ';  // un espacio escrito (dispara los atributos en XML)
                }
                else e.Key = (uint)k[0];
                HandleKey(e);
            }
            else if (verb == "hover")
            {
                Draw();  // posiciones de los paneles (una pestaña recién abierta aún no las tiene)
                List<string> p = Text.Split(arg, " ");
                EditorView v = Editor;
                if (v != null && p.Count >= 2)
                {
                    int line = p[0].ToInt() - 1, col = p[1].ToInt() - 1;
                    mouseX = v.X + v.GutterWidth(r) - v.ScrollX + v.VisualCol(line, col) * r.Code.CharWidth + 3;
                    mouseY = v.Y + (line - v.ScrollLine) * r.Code.LineHeight + 5;
                    if (v.Doc.AnalyzedVersion != v.Doc.Buffer.Version) RunAnalysis();
                    UpdateHover();
                }
                delete p;
            }
            else if (verb == "wheel")
            {
                // wheel X Y líneas
                List<string> p = Text.Split(arg, " ");
                if (p.Count >= 3)
                {
                    Event e = new Event();
                    e.Kind = EventKind.Scroll;
                    e.X = p[0].ToInt();
                    e.Y = p[1].ToInt();
                    e.ScrollLines = p[2].ToInt();
                    e.Ctrl = p.Count >= 4 && p[3] == "ctrl";
                    HandleEvent(e);
                }
                delete p;
            }
            else if (verb == "click" || verb == "dblclick" || verb == "drag" || verb == "rclick" || verb == "mdrag")
            {
                // Ratón simulado: click X Y | dblclick X Y | drag X1 Y1 X2 Y2 (pasos intermedios incluidos)
                Draw();
                List<string> p = Text.Split(arg, " ");
                if (p.Count >= 2)
                {
                    Event e = new Event();
                    e.X = p[0].ToInt();
                    e.Y = p[1].ToInt();
                    e.Button = verb == "rclick" ? 3 : 1;
                    e.Kind = EventKind.MouseMove;
                    e.Button = 0;
                    HandleEvent(e);
                    e.Button = verb == "rclick" ? 3 : (verb == "mdrag" ? 2 : 1);
                    e.Kind = EventKind.MouseDown;
                    HandleEvent(e);
                    if (verb == "dblclick")
                    {
                        e.Kind = EventKind.MouseUp;
                        HandleEvent(e);
                        forcedClicks = 2;
                        e.Kind = EventKind.MouseDown;
                        HandleEvent(e);
                    }
                    if ((verb == "drag" || verb == "mdrag") && p.Count >= 4)
                    {
                        int x2 = p[2].ToInt(), y2 = p[3].ToInt();
                        for (int s = 1; s <= 8; s++)
                        {
                            e.Kind = EventKind.MouseMove;
                            e.X = p[0].ToInt() + (x2 - p[0].ToInt()) * s / 8;
                            e.Y = p[1].ToInt() + (y2 - p[1].ToInt()) * s / 8;
                            HandleEvent(e);
                            Draw();
                        }
                    }
                    e.Kind = EventKind.MouseUp;
                    HandleEvent(e);
                    forcedClicks = 0;
                }
                delete p;
            }
            else if (verb == "analyze") RunAnalysis();
            else if (verb == "split") ToggleSplit();
            else if (verb == "panel") ShowTool(arg.ToInt() + 1);
            else if (verb == "target") SetBuildTarget(arg);
            else if (verb == "device")
            {
                android.Select(arg);
                SetBuildTarget("android");
            }
            else if (verb == "wait")
            {
                // wait <ms>: atiende procesos (capturas del dispositivo, compilación) mientras tanto
                long until = Environment.TickCount64() + arg.ToInt();
                while (Environment.TickCount64() < until)
                {
                    Update();
                    Time.Sleep(20);
                }
            }
            else if (verb == "dock")
            {
                // dock <panel 0..2> <lado 0..2>
                List<string> p = Text.Split(arg, " ");
                if (p.Count >= 2) DockTool(p[0].ToInt(), p[1].ToInt());
                delete p;
            }
            else if (verb == "quickopen")
            {
                OpenOverlay(Overlay.QuickOpen);
                overlayInput.Append(arg);
                FilterQuickOpen();
            }
            else if (verb == "find")
            {
                OpenOverlay(Overlay.Find);
                overlayInput.Append(arg);
                OverlayAccept();
            }
            else if (verb == "build" || verb == "run")
            {
                StartProcess(verb == "run");
                while (process != null && process.IsRunning)
                {
                    Update();
                    EventWait.WaitFd(-1, 20);
                }
                Update();
            }
            else if (verb == "start") StartProcess(arg != "build");   // sin esperar (p. ej. 'faset run' en Android sigue el log)
            else if (verb == "stop") StopProcess();
            else if (verb == "quit") RequestQuit();
            else if (verb == "hub") ShowHub();
            else if (verb == "menu") { Draw(); for (int i = 0; i < hits.Count; i++) if (hits[i].Group == -4 && hits[i].Id == arg.ToInt()) OpenBarMenu(hits[i].Id, hits[i].X, hits[i].Y + hits[i].H + 4); }
            else if (verb == "newproject") OpenNewProjectDialog();
            else if (verb == "openfolder") OpenFolderDialog();
            else if (verb == "properties") OpenPropertiesDialog();
            else if (verb == "about") OpenOverlay(Overlay.About);
            else if (verb == "action") ExecuteAction(arg.ToInt());
            else if (verb == "context")
            {
                Draw();
                for (int i = 0; i < explorer.RowCount; i++)
                    if (explorer.RowPath(i).EndsWith(arg))
                    {
                        OpenContextMenu(i, explorer.X + 80, explorer.Y + Explorer.HeaderHeight + (i - explorer.Scroll) * Explorer.RowHeight + 12);
                        break;
                    }
            }
            else if (verb == "field")
            {
                TextField f = FocusedField();
                if (f != null) f.Set(arg);
            }
            else if (verb == "template") projectTemplate = arg.ToInt();
            else if (verb == "create") CreateProject();
            else if (verb == "rename")
            {
                List<string> p = Text.Split(arg, " ");
                if (p.Count == 2)
                {
                    string target = Path.Combine(rootFolder, p[0]);
                    RenamePath(target, p[1]);
                    String.Free(target);
                }
                delete p;
            }
            else if (verb == "move")
            {
                List<string> p = Text.Split(arg, " ");
                if (p.Count == 2)
                {
                    string src = Path.Combine(rootFolder, p[0]), dst = Path.Combine(rootFolder, p[1]);
                    MovePath(src, dst);
                    String.Free(src);
                    String.Free(dst);
                }
                delete p;
            }
            if (analysisPending && verb != "type") RunAnalysis();
        }
    }
}
