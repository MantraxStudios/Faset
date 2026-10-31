// =============================================================================
//  FasetStudio: panel "Pruebas" (panel 7) y "Formatear documento".
//
//  El panel lista las pruebas [Test] / [TestCase] del proyecto o de la solución
//  ('faset test --list --json'), agrupadas por archivo y clase, y las ejecuta en
//  segundo plano con 'faset test --report <json>': todas, las fallidas, las de una
//  clase o una sola (▶ al pasar el ratón, o clic en el ▶ del margen de un [Test]).
//  Un clic en una prueba abre su línea; en una fallida, la línea del fallo.
//
//  Formatear documento (Shift+Alt+F) pasa el texto por 'faset fmt'; con el ajuste
//  "editor.formatOnSave" = 1 también al guardar con Ctrl+S. App.fst solo llama a
//  estos métodos.
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
    // Una prueba del panel.
    public class TestEntry
    {
        public var Name: string = "";        // "Clase.Metodo(1, 2)" (copia propia)
        public var ClassName: string = "";   // copia propia
        public var File: string = "";        // ruta absoluta (copia propia)
        public var Line: int;                // 1..n
        public var Status: int;              // 0 sin ejecutar, 1 correcta, 2 fallida, 3 ignorada
        public var Message: string = "";     // fallo: mensaje, esperado y obtenido (copia propia)
        public var FailFile: string = "";    // copia propia ("" = la línea de la prueba)
        public var FailLine: int;
        public var Ms: double;
    }

    // Marca ▶ en el margen de las líneas [Test] / [TestCase] (EditorView la dibuja).
    public static class TestMarks
    {
        // ¿Es la línea un atributo de prueba? ([Test], [TestCase(...)], [Test, Ignore(...)])
        public static func IsTestLine(line: string) -> bool
        {
            string t = line.Trim();
            return t.StartsWith("[Test]") || t.StartsWith("[Test,") || t.StartsWith("[TestCase(") || t.StartsWith("[Test ");
        }

        public static func Gutter(r: Renderer, path: string, line: string, x: float, y: float, lh: float)
        {
            if (!path.EndsWith(".fst") || !IsTestLine(line)) return;
            float cw = r.Code.CharWidth;
            float size = (float)Math.Min((double)lh * 0.55, (double)cw * 1.3);
            Play(r, x + cw * 1.05f, y + lh / 2, size, Color.Hex(0x4cc38a));
        }

        // Triángulo ▶ (franjas verticales cada vez más cortas: la fuente puede no tener el símbolo).
        public static func Play(r: Renderer, cx: float, cy: float, size: float, c: Color)
        {
            for (int k = 0; k < 6; k++)
            {
                float h = size * (1 - k / 6.0f);
                r.Rect(cx - size * 0.4f + k * size / 7, cy - h / 2, size / 7 + 0.5f, h, c);
            }
        }
    }

    public partial class App
    {
        const int ActTestsAll = 80;      // botones del panel Pruebas
        const int ActTestsFailed = 81;
        const int ActTestsRefresh = 82;
        const int TestsTool = 7;

        var testEntries: List<TestEntry> = new List<TestEntry>();
        var testRowKind: List<int> = new List<int>();   // 0 archivo, 1 clase, 2 prueba
        var testRowItem: List<int> = new List<int>();   // prueba de la fila (la primera del grupo en 0 y 1)
        var testsScroll: int;
        var testProcess: ChildProcess;
        var testReport: string = "";   // informe JSON de la ejecución en marcha
        var testStart: long;
        var testsListed: bool;         // ya se pidió la lista al menos una vez

        // ------------------------------------------------------------------ lista

        // Lo que se pasa a 'faset test': la solución, el proyecto o el archivo actual ("" si nada).
        func TestTarget() -> string
        {
            if (solutionFile.Length > 0) return solutionFile;
            if (projectFile.Length > 0) return projectFile;
            EditorView v = Editor;
            if (v != null && v.Doc.FullPath.EndsWith(".fst")) return v.Doc.FullPath;
            return "";
        }

        // Archivo temporal propio de FasetStudio ('sufijo' distingue los usos).
        static func StudioTempFile(suffix: string) -> string
        {
#if WINDOWS
            string tmp = Path.GetTempPath();
#else
            string tmp = Environment.GetVariable("TMPDIR");
            if (tmp.IsEmpty()) tmp = "/tmp";
#endif
            StringBuilder sb = new StringBuilder();
            sb.Append(tmp).Append("/fasetstudio-").Append((long)Process.CurrentId).Append("-").Append(suffix);
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Pide la lista de pruebas ('faset test --list --json') y conserva el resultado de las que ya estaban.
        func RefreshTests()
        {
            testsListed = true;
            string target = TestTarget();
            if (target.Length == 0 || !analyzer.Available) return;
            StringBuilder cmd = new StringBuilder();
            string qf = Analyzer.Quote(analyzer.Compiler), qt = Analyzer.Quote(target);
            cmd.Append(qf).Append(" test ").Append(qt).Append(" --list --json");
            string listed;
            int code = Process.Capture(cmd.View(), out listed);
            delete cmd;
            List<TestEntry> old = testEntries;
            testEntries = new List<TestEntry>();
            // Una línea JSON por proyecto; lo demás (errores de las pruebas) va a Salida.
            List<string> lines = Text.Split(listed, "\n");
            for (int i = 0; i < lines.Count; i++)
            {
                string l = lines[i].Trim();
                if (!l.StartsWith("{"))
                {
                    if (l.Length > 0) output.Append(l).Append("\n");
                    continue;
                }
                JsonValue root = Json.Parse(l);
                if (root == null) continue;
                JsonValue tests = root.Get("tests");
                for (int k = 0; tests != null && k < tests.Count; k++)
                {
                    JsonValue t = tests.At(k);
                    TestEntry e = new TestEntry();
                    e.Name = String.Copy(t.GetString("name"));
                    e.ClassName = String.Copy(t.GetString("className"));
                    e.File = String.Copy(t.GetString("file"));
                    e.Line = t.GetInt("line");
                    e.Status = t.Has("ignored") ? 3 : 0;
                    TestEntry prev = FindTest(old, e.Name, e.File);
                    if (prev != null && prev.Status != 3 && e.Status != 3) CopyResult(prev, e);
                    testEntries.Add(e);
                }
                delete root;
            }
            delete lines;
            if (code != 0 && testEntries.Count == 0) SetStatus(L.T("Could not list the tests (see Output)"));
            for (int i = 0; i < old.Count; i++) delete old[i];
            delete old;
            RebuildTestRows();
        }

        static func FindTest(list: List<TestEntry>, name: string, file: string) -> TestEntry
        {
            for (int i = 0; i < list.Count; i++)
                if (list[i].Name == name && list[i].File == file) return list[i];
            return null;
        }

        static func CopyResult(from: TestEntry, to: TestEntry)
        {
            to.Status = from.Status;
            to.Message = String.Copy(from.Message);
            to.FailFile = String.Copy(from.FailFile);
            to.FailLine = from.FailLine;
            to.Ms = from.Ms;
        }

        // Filas del árbol: archivo > clase > prueba (en el orden en que las da el compilador).
        func RebuildTestRows()
        {
            testRowKind.Clear();
            testRowItem.Clear();
            for (int i = 0; i < testEntries.Count; i++)
            {
                TestEntry e = testEntries[i];
                bool newFile = i == 0 || testEntries[i - 1].File != e.File;
                if (newFile)
                {
                    testRowKind.Add(0);
                    testRowItem.Add(i);
                }
                if (newFile || testEntries[i - 1].ClassName != e.ClassName)
                {
                    testRowKind.Add(1);
                    testRowItem.Add(i);
                }
                testRowKind.Add(2);
                testRowItem.Add(i);
            }
            needsRedraw = true;
        }

        // Al cerrar el proyecto: se detiene la ejecución y se olvida la lista.
        func ResetTests()
        {
            if (TestsRunning) testProcess.Kill();
            for (int i = 0; i < testEntries.Count; i++) delete testEntries[i];
            testEntries.Clear();
            testsListed = false;
            testsScroll = 0;
            RebuildTestRows();
        }

        // ------------------------------------------------------------------ ejecución

        prop TestsRunning: bool => testProcess != null && testProcess.IsRunning;

        // Ejecuta las pruebas: 'filters' vacío = todas; 'exact' compara el nombre completo.
        func RunTests(filters: List<string>, exact: bool)
        {
            if (TestsRunning || (process != null && process.IsRunning))
            {
                SetStatus(L.T("A build is already running"));
                return;
            }
            if (!analyzer.Available)
            {
                SetStatus(L.T("Compiler 'faset' not found"));
                return;
            }
            string target = TestTarget();
            if (target.Length == 0) return;
            SaveAll();
            if (!testsListed) RefreshTests();
            output.Clear();
            outputScroll = 0;
            ShowTool(TestsTool);
            testReport = StudioTempFile("pruebas.json");
            File.Delete(testReport);
            StringBuilder cmd = new StringBuilder();
            string qf = Analyzer.Quote(analyzer.Compiler), qt = Analyzer.Quote(target), qr = Analyzer.Quote(testReport);
            cmd.Append(qf).Append(" test ").Append(qt).Append(" -c ").Append(configuration).Append(" --report ").Append(qr);
            for (int i = 0; i < filters.Count; i++)
            {
                string q = Analyzer.Quote(filters[i]);
                cmd.Append(" --filter ").Append(q);
            }
            if (exact) cmd.Append(" --exact");
            output.Append("> faset test ").Append(Path.GetFileName(target));
            if (filters.Count > 0) output.Append(" --filter …");
            output.Append("\n");
            if (testProcess == null) testProcess = new ChildProcess();
            if (!testProcess.Start(cmd.View(), rootFolder)) output.Append(L.T("Could not start the compiler.")).Append("\n");
            delete cmd;
            testStart = Environment.TickCount64();
            SetStatus(L.T("Running tests…"));
        }

        func RunAllTests()
        {
            List<string> none = new List<string>();
            RunTests(none, false);
            delete none;
        }

        func RunFailedTests()
        {
            List<string> failed = new List<string>();
            for (int i = 0; i < testEntries.Count; i++)
                if (testEntries[i].Status == 2) failed.Add(testEntries[i].Name);
            if (failed.Count == 0) SetStatus(L.T("No failed tests"));
            else RunTests(failed, true);
            delete failed;
        }

        // Una prueba (o todas las de una clase, con 'wholeClass').
        func RunOneTest(index: int, wholeClass: bool)
        {
            if (index < 0 || index >= testEntries.Count) return;
            List<string> f = new List<string>();
            TestEntry e = testEntries[index];
            if (wholeClass)
            {
                for (int i = 0; i < testEntries.Count; i++)
                    if (testEntries[i].ClassName == e.ClassName && testEntries[i].File == e.File) f.Add(testEntries[i].Name);
            }
            else f.Add(e.Name);
            RunTests(f, true);
            delete f;
        }

        // Atiende la ejecución en marcha; true si hay que redibujar.
        func UpdateTests() -> bool
        {
            if (testProcess == null || !testProcess.IsRunning) return false;
            bool redraw = Analyzer.ReadChild(testProcess, output);
            if (!testProcess.HasExited) return redraw;
            Analyzer.ReadChild(testProcess, output);
            int code = testProcess.ExitCode;
            int passed = 0, failed = 0;
            string text;
            if (File.TryReadAllText(testReport, out text))
            {
                JsonValue root = Json.Parse(text);
                if (root != null)
                {
                    ApplyTestReport(root);
                    passed = root.GetInt("passed");
                    failed = root.GetInt("failed");
                    delete root;
                }
                File.Delete(testReport);
            }
            string a = String.FromInt(passed), b = String.FromInt(failed);
            if (code == 0) SetStatus(L.F("Tests passed: {0}", a, ""));
            else if (failed > 0) SetStatus(L.F("Tests: {0} passed, {1} failed", a, b));
            else SetStatus(L.T("The tests could not be built (see Output)"));
            if (code != 0 && failed == 0) ShowTool(1);
            long ms = Environment.TickCount64() - testStart;
            string codeText = String.FromInt(code), msText = String.FromInt(ms);
            string summary = L.F("[tests finished with code {0} in {1} ms]", codeText, msText);
            output.Append("\n").Append(summary).Append("\n");
            return true;
        }

        // Resultados del informe (los de las pruebas que no se ejecutaron se conservan).
        func ApplyTestReport(root: JsonValue)
        {
            JsonValue projects = root.Get("projects");
            bool added = false;
            for (int p = 0; projects != null && p < projects.Count; p++)
            {
                JsonValue tests = projects.At(p).Get("tests");
                for (int k = 0; tests != null && k < tests.Count; k++)
                {
                    JsonValue t = tests.At(k);
                    TestEntry e = FindTest(testEntries, t.GetString("name"), t.GetString("file"));
                    if (e == null)
                    {
                        e = new TestEntry();
                        e.Name = String.Copy(t.GetString("name"));
                        e.ClassName = String.Copy(t.GetString("className"));
                        e.File = String.Copy(t.GetString("file"));
                        e.Line = t.GetInt("line");
                        testEntries.Add(e);
                        added = true;
                    }
                    string st = t.GetString("status");
                    e.Status = st == "passed" ? 1 : st == "failed" ? 2 : st == "skipped" ? 3 : 0;
                    JsonValue d = t.Get("durationMs");
                    e.Ms = d != null ? d.AsNumber() : 0;
                    e.Message = "";
                    e.FailFile = "";
                    e.FailLine = 0;
                    if (e.Status == 2)
                    {
                        StringBuilder m = new StringBuilder();
                        string type = t.GetString("exceptionType");
                        if (t.Get("panic") != null && t.Get("panic").AsBool()) m.Append("panic: ");
                        else if (type.Length > 0 && type != "AssertException") m.Append(type).Append(": ");
                        m.Append(t.GetString("message"));
                        if (t.Has("expected"))
                            m.Append("  (").Append(L.T("expected")).Append(" ").Append(t.GetString("expected")).Append(", ")
                             .Append(L.T("got")).Append(" ").Append(t.GetString("actual")).Append(")");
                        e.Message = m.ToString();
                        delete m;
                        e.FailFile = String.Copy(t.GetString("failureFile"));
                        e.FailLine = t.GetInt("failureLine");
                    }
                }
            }
            if (added) RebuildTestRows();
            needsRedraw = true;
        }

        // ------------------------------------------------------------------ dibujo y ratón

        prop TestRowHeight: float => r.Code.LineHeight + 6;
        const float TestsToolbarHeight = 38;

        func DrawTests(x: float, y: float, w: float, h: float)
        {
            if (!testsListed) RefreshTests();
            float ty = y + PanelHeaderHeight + 5;
            bool busy = TestsRunning;
            float px = x + 10;
            px += Pill(px, ty, L.T("Run all"), "", ActTestsAll, busy ? 2 : 0) + 6;
            px += Pill(px, ty, L.T("Run failed"), "", ActTestsFailed, 2) + 6;
            px += Pill(px, ty, L.T("Refresh"), "", ActTestsRefresh, 2) + 12;
            int passed = 0, failed = 0, skipped = 0;
            for (int i = 0; i < testEntries.Count; i++)
            {
                int s = testEntries[i].Status;
                if (s == 1) passed++;
                else if (s == 2) failed++;
                else if (s == 3) skipped++;
            }
            if (busy) r.Text(r.Ui, px, ty + 5, L.T("Running tests…"), Theme.TextSecondary);
            else
            {
                // Correctas, fallidas e ignoradas: punto de color y número.
                for (int k = 0; k < 3; k++)
                {
                    int n = k == 0 ? passed : k == 1 ? failed : skipped;
                    r.RoundRect(px, ty + 9, 10, 10, 5, k == 0 ? Color.Hex(0x4cc38a) : k == 1 ? Theme.Error : Theme.Warning);
                    px = r.Text(r.Ui, px + 15, ty + 5, String.FromInt(n), Theme.TextSecondary) + 14;
                }
            }

            float lh = TestRowHeight;
            float y0 = y + PanelHeaderHeight + TestsToolbarHeight;
            float listH = h - PanelHeaderHeight - TestsToolbarHeight - 6;
            int visible = (int)(listH / lh);
            if (testsScroll > Math.Max(0, testRowKind.Count - 1)) testsScroll = Math.Max(0, testRowKind.Count - 1);
            r.PushClip(x, y0, w, listH);
            if (testRowKind.Count == 0)
                r.Text(r.Ui, x + 16, y0 + 4, L.T("No tests found. Mark methods with [Test] (see 'faset test')."), Theme.TextTertiary);
            for (int i = 0; i < visible + 1; i++)
            {
                int row = testsScroll + i;
                if (row >= testRowKind.Count) break;
                int kind = testRowKind[row];
                TestEntry e = testEntries[testRowItem[row]];
                float ry = y0 + i * lh;
                bool hover = mouseX >= x && mouseX < x + w && mouseY >= ry && mouseY < ry + lh;
                if (hover) r.RoundRect(x + 6, ry, w - 12, lh, 6, Theme.Hover);
                float tx = x + 16 + kind * 16;
                if (kind == 0)
                {
                    r.Text(r.Ui, tx, ry + 4, Path.GetFileName(e.File), Theme.TextSecondary);
                    continue;
                }
                if (kind == 1)
                {
                    r.Text(r.Ui, tx, ry + 4, e.ClassName.Length > 0 ? e.ClassName : L.T("(functions)"), Theme.Text);
                    if (hover) TestMarks.Play(r, x + w - 24, ry + lh / 2, 11, Color.Hex(0x4cc38a));
                    continue;
                }
                Color dot = e.Status == 1 ? Color.Hex(0x4cc38a) : e.Status == 2 ? Theme.Error : e.Status == 3 ? Theme.Warning : Theme.TextDisabled;
                r.RoundRect(tx, ry + lh / 2 - 5, 10, 10, 5, dot);
                string shown = e.ClassName.Length > 0 && e.Name.StartsWith(e.ClassName) ? e.Name.Substring(e.ClassName.Length + 1) : e.Name;
                float mx = r.Text(r.Ui, tx + 18, ry + 4, shown, Theme.Text);
                if (e.Status == 2) r.Text(r.Ui, mx + 12, ry + 4, e.Message, Theme.Error);
                else if (e.Status == 1)
                {
                    string ms = e.Ms < 1 ? "< 1 ms" : String.Concat(String.FromInt((long)e.Ms), " ms");
                    r.Text(r.Ui, mx + 12, ry + 4, ms, Theme.TextTertiary);
                }
                else if (e.Status == 3) r.Text(r.Ui, mx + 12, ry + 4, L.T("ignored"), Theme.TextTertiary);
                if (hover) TestMarks.Play(r, x + w - 24, ry + lh / 2, 11, Color.Hex(0x4cc38a));
            }
            r.PopClip();
        }

        // Fila del panel bajo 'y' (-1 si ninguna).
        func TestRowAt(y: float) -> int
        {
            float y0 = toolRect[TestsTool * 4 + 1] + PanelHeaderHeight + TestsToolbarHeight;
            if (y < y0) return -1;
            int row = testsScroll + (int)Math.Floor((y - y0) / TestRowHeight);
            return row >= 0 && row < testRowKind.Count ? row : -1;
        }

        // Clic en el panel: ▶ ejecuta la prueba o la clase; en otro sitio abre la línea.
        func TestsMouseDown(x: float, y: float) -> bool
        {
            if (!InTool(TestsTool, x, y) || y < toolRect[TestsTool * 4 + 1] + PanelHeaderHeight + TestsToolbarHeight) return false;
            int row = TestRowAt(y);
            if (row < 0) return true;
            int kind = testRowKind[row], item = testRowItem[row];
            TestEntry e = testEntries[item];
            float right = toolRect[TestsTool * 4] + toolRect[TestsTool * 4 + 2];
            if (kind > 0 && x >= right - 40)
            {
                RunOneTest(item, kind == 1);
                return true;
            }
            bool atFailure = kind == 2 && e.Status == 2 && e.FailFile.Length > 0 && File.Exists(e.FailFile);
            string path = String.Copy(atFailure ? e.FailFile : e.File);
            int line = atFailure ? e.FailLine : (kind == 0 ? 1 : e.Line);
            EditorView v = OpenFile(path);
            if (v != null) v.GoToLine(Math.Max(0, line - 1), 0, r);
            return true;
        }

        // ▶ del margen: la prueba de esa línea ([TestCase] concreto o todas las del método).
        func TestGutterClick(v: EditorView, line: int) -> bool
        {
            if (line < 0 || line >= v.Doc.Buffer.LineCount || !TestMarks.IsTestLine(v.Doc.Buffer.LineText(line))) return false;
            RefreshTests();
            int best = -1;
            for (int i = 0; i < testEntries.Count; i++)
            {
                TestEntry e = testEntries[i];
                if (e.File != v.Doc.FullPath || e.Line < line + 1) continue;
                if (e.Line == line + 1) best = i;   // [TestCase] de esta línea
                else if (best < 0 || (testEntries[best].Line != line + 1 && e.Line < testEntries[best].Line)) best = i;
            }
            if (best < 0)
            {
                SetStatus(L.T("No test found on this line"));
                return true;
            }
            TestEntry t = testEntries[best];
            List<string> f = new List<string>();
            if (t.Line == line + 1) f.Add(t.Name);
            else
            {
                // [Test] del método: todas sus pruebas (los [TestCase] tienen la línea de su atributo).
                int paren = t.Name.IndexOf("(");
                f.Add(paren > 0 ? t.Name.Substring(0, paren) : t.Name);
            }
            RunTests(f, true);
            delete f;
            return true;
        }

        func TestsAction(id: int)
        {
            if (id == ActTestsAll) RunAllTests();
            else if (id == ActTestsFailed) RunFailedTests();
            else if (id == ActTestsRefresh) RefreshTests();
        }

        // ------------------------------------------------------------------ formato

        prop FormatOnSave: bool => Settings.Get("editor.formatOnSave", "0") == "1";

        // Formatea el documento con 'faset fmt' (un solo paso de deshacer; solo cambian las líneas distintas).
        func FormatDocument(v: EditorView, quiet: bool)
        {
            if (v == null || !v.Doc.FullPath.EndsWith(".fst") || !analyzer.Available) return;
            TextBuffer b = v.Doc.Buffer;
            string text = b.GetAll();
            string tmp = StudioTempFile("formato.fst");
            if (!File.WriteAllText(tmp, text)) return;
            string qf = Analyzer.Quote(analyzer.Compiler), qt = Analyzer.Quote(tmp);
            string fmtOut;
            int code = Process.Capture(String.Concat(qf, " fmt -q ", qt), out fmtOut);
            string formatted;
            bool read = code == 0 && File.TryReadAllText(tmp, out formatted);
            File.Delete(tmp);
            if (!read)
            {
                // "ruta: línea N: motivo" -> "línea N: motivo"
                string why = fmtOut.Trim();
                int colon = why.IndexOf(": ");
                if (colon > 0 && why.StartsWith(tmp)) why = why.Substring(colon + 2);
                SetStatus(String.Concat(L.T("Could not format the document"), ": ", why));
                return;
            }
            if (formatted == text)
            {
                if (!quiet) SetStatus(L.T("The document is already formatted"));
                return;
            }
            List<string> a = Text.Split(text, "\n"), c = Text.Split(formatted, "\n");
            int p = 0;
            while (p + 1 < a.Count && p + 1 < c.Count && a[p] == c[p]) p++;
            int s = 0;
            while (s + 1 < a.Count - p && s + 1 < c.Count - p && a[a.Count - 1 - s] == c[c.Count - 1 - s]) s++;
            StringBuilder ins = new StringBuilder();
            TextPos end;
            if (s > 0)
            {
                end = new TextPos(a.Count - s, 0);
                for (int i = p; i < c.Count - s; i++) ins.Append(c[i]).Append("\n");
            }
            else
            {
                end = b.End;
                for (int i = p; i < c.Count; i++)
                {
                    if (i > p) ins.Append("\n");
                    ins.Append(c[i]);
                }
            }
            TextPos cursor = v.Cursor;
            b.NewGroup();
            b.Delete(new TextPos(p, 0), end, cursor);
            b.Insert(new TextPos(p, 0), ins.View(), cursor);
            b.NewGroup();
            delete ins;
            delete a;
            delete c;
            v.SetCursor(b.Clamp(cursor), false);
            v.EnsureCursorVisible(r);
            MarkEdited();
            if (!quiet) SetStatus(L.T("Document formatted"));
        }
    }
}
