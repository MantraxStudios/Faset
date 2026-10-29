// =============================================================================
//  Documentos abiertos y cliente de IntelliSense.
//
//  El análisis lo hace el propio compilador: 'faset __analyze <petición> <resultado>'
//  (el mismo motor que usa el servidor de lenguaje para VS Code). Así los errores,
//  el autocompletado y la información de símbolos coinciden con 'faset build'.
// =============================================================================
using std.collections;
using std.io;
using std.json;
using std.os;
using std.text;
using std.time;

namespace FasetStudio.Ide
{
    public struct Diagnostic
    {
        public int Line;        // 0..n-1
        public int Col;         // columna en bytes
        public int Severity;    // 1 error, 3 nota
        public string Message;  // copia propia
    }

    public struct SymbolRef
    {
        public int Line;
        public int Col;
        public int Length;
        public string Hover;    // copia propia
        public string DefPath;  // copia propia ("" si no hay)
        public int DefLine;
        public int DefCol;
    }

    public struct CompletionItem
    {
        public string Label;   // copia propia
        public string Detail;  // copia propia
        public int Kind;       // CompletionItemKind de LSP
        public string Insert;  // texto a insertar ("" = Label); "$0" marca el cursor (copia propia)
    }

    public class Document
    {
        public string FullPath;  // ruta absoluta (copia propia)
        public string Name;      // vista de FullPath
        public TextBuffer Buffer = new TextBuffer();
        public List<Diagnostic> Diagnostics = new List<Diagnostic>();
        public List<SymbolRef> Refs = new List<SymbolRef>();
        public int AnalyzedVersion = -1;

        ~Document()
        {
            ClearDiagnostics();
            ClearRefs();
            delete Diagnostics;
            delete Refs;
            delete Buffer;
            String.Free(FullPath);
        }

        public static Document Open(string path)
        {
            string content;
            if (!File.TryReadAllText(path, out content)) return null;
            Document d = new Document();
            d.FullPath = Path.GetFullPath(path);
            d.Name = Path.GetFileName(d.FullPath);
            d.Buffer.SetAll(content);
            String.Free(content);
            return d;
        }

        public bool Save()
        {
            string text = Buffer.GetAll();
            bool ok = File.WriteAllText(FullPath, text);
            String.Free(text);
            if (ok) Buffer.SavedVersion = Buffer.Version;
            return ok;
        }

        public bool Modified => Buffer.Modified;

        // .fstproj y .fstui: el IntelliSense es el del esquema XML (elementos, atributos y valores).
        public bool IsXml => FullPath.EndsWith(".fstproj") || FullPath.EndsWith(".fstui");

        public void ClearDiagnostics()
        {
            for (int i = 0; i < Diagnostics.Count; i++) String.Free(Diagnostics[i].Message);
            Diagnostics.Clear();
        }

        public void ClearRefs()
        {
            for (int i = 0; i < Refs.Count; i++)
            {
                String.Free(Refs[i].Hover);
                String.Free(Refs[i].DefPath);
            }
            Refs.Clear();
        }

        public int ErrorCount
        {
            get
            {
                int n = 0;
                for (int i = 0; i < Diagnostics.Count; i++)
                    if (Diagnostics[i].Severity == 1) n++;
                return n;
            }
        }

        // Último símbolo registrado que cubre (línea, columna).
        public int RefAt(int line, int col)
        {
            int found = -1;
            for (int i = 0; i < Refs.Count; i++)
            {
                SymbolRef r = Refs[i];
                if (r.Line == line && col >= r.Col && col <= r.Col + r.Length) found = i;
            }
            return found;
        }
    }

    public class Analyzer
    {
        string faset;      // ruta del compilador
        string requestPath;
        string resultPath;
        public bool Available;
        public long LastDurationMs;
        public bool LastFailed;   // el último análisis no devolvió resultado (el compilador falló)

        public string Compiler => faset;

        public Analyzer(string fasetPath)
        {
            faset = String.Copy(fasetPath);
            Available = fasetPath.Length > 0;
            string tmp = Environment.GetVariable("TMPDIR");
            if (tmp.IsEmpty())
            {
                String.Free(tmp);
                tmp = String.Copy(OS.IsWindows ? "C:/Windows/Temp" : "/tmp");
            }
            string stamp = String.FromInt(Time.NowUnixMs() % 1000000000);
            requestPath = String.Concat(tmp, "/fasetstudio-", stamp);
            string reqName = String.Concat(requestPath, "-req.json");
            resultPath = String.Concat(requestPath, "-res.json");
            String.Free(requestPath);
            requestPath = reqName;
            String.Free(stamp);
            String.Free(tmp);
        }

        ~Analyzer()
        {
            File.Delete(requestPath);
            File.Delete(resultPath);
            String.Free(faset);
            String.Free(requestPath);
            String.Free(resultPath);
        }

        public static string Quote(string s)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("'").Append(Text.Replace(s, "'", "'\\''")).Append("'");
            string r = sb.ToString();
            delete sb;
            return r;
        }

        // Lanza el análisis. 'focusText' (opcional) reemplaza el texto del documento enfocado.
        // Devuelve el JSON de resultado (libéralo con delete) o null.
        public JsonValue Run(Document focus, List<Document> open, string focusText, bool hasFocusText)
        {
            if (!Available) return null;
            StringBuilder req = new StringBuilder();
            req.Append("{\"focus\":");
            Json.WriteString(req, focus.FullPath);
            req.Append(",\"overrides\":{");
            bool first = true;
            for (int i = 0; i < open.Count; i++)
            {
                Document d = open[i];
                if (!first) req.Append(",");
                first = false;
                Json.WriteString(req, d.FullPath);
                req.Append(":");
                if (d == focus && hasFocusText)
                {
                    Json.WriteString(req, focusText);
                }
                else
                {
                    string text = d.Buffer.GetAll();
                    Json.WriteString(req, text);
                    String.Free(text);
                }
            }
            req.Append("},\"interest\":[");
            for (int i = 0; i < open.Count; i++)
            {
                if (i > 0) req.Append(",");
                Json.WriteString(req, open[i].FullPath);
            }
            req.Append("]}");
            File.WriteAllText(requestPath, req.View());
            delete req;

            long start = Time.TickMs();
            string qf = Quote(faset), qreq = Quote(requestPath), qres = Quote(resultPath);
            string cmd = String.Concat(qf, " __analyze ", String.Concat(qreq, " ", qres));
            string output;
            int code = Process.Capture(cmd, out output);
            String.Free(output);
            String.Free(cmd);
            String.Free(qf);
            String.Free(qreq);
            String.Free(qres);
            LastDurationMs = Time.TickMs() - start;
            LastFailed = true;
            if (code != 0) return null;
            string text;
            if (!File.TryReadAllText(resultPath, out text)) return null;
            JsonValue result = Json.Parse(text);
            String.Free(text);
            LastFailed = result == null;
            return result;
        }

        // Aplica diagnósticos y referencias de un resultado a los documentos abiertos.
        public void Apply(JsonValue result, List<Document> open)
        {
            for (int i = 0; i < open.Count; i++)
            {
                open[i].ClearDiagnostics();
                open[i].ClearRefs();
            }
            JsonValue diags = result.Get("diagnostics");
            for (int i = 0; diags != null && i < diags.Count; i++)
            {
                JsonValue d = diags.At(i);
                Document doc = Find(open, d.GetString("path"));
                if (doc == null) continue;
                Diagnostic g = new Diagnostic();
                g.Line = d.GetInt("line") - 1;
                g.Col = d.GetInt("col") - 1;
                g.Severity = d.GetInt("severity");
                g.Message = String.Copy(d.GetString("message"));
                doc.Diagnostics.Add(g);
            }
            JsonValue refs = result.Get("refs");
            for (int i = 0; refs != null && i < refs.Count; i++)
            {
                JsonValue r = refs.At(i);
                Document doc = Find(open, r.GetString("path"));
                if (doc == null) continue;
                SymbolRef s = new SymbolRef();
                s.Line = r.GetInt("line") - 1;
                s.Col = r.GetInt("col") - 1;
                s.Length = r.GetInt("len");
                s.Hover = String.Copy(r.GetString("hover"));
                s.DefPath = String.Copy(r.GetString("defPath"));
                s.DefLine = r.GetInt("defLine") - 1;
                s.DefCol = r.GetInt("defCol") - 1;
                doc.Refs.Add(s);
            }
            for (int i = 0; i < open.Count; i++) open[i].AnalyzedVersion = open[i].Buffer.Version;
        }

        // Diagnósticos sin documento abierto (por ejemplo de otros archivos del proyecto).
        public static Document Find(List<Document> docs, string path)
        {
            for (int i = 0; i < docs.Count; i++)
                if (docs[i].FullPath == path) return docs[i];
            return null;
        }

        public static List<CompletionItem> Completions(JsonValue result)
        {
            List<CompletionItem> items = new List<CompletionItem>();
            JsonValue list = result.Get("completions");
            for (int i = 0; list != null && i < list.Count; i++)
            {
                JsonValue c = list.At(i);
                CompletionItem item = new CompletionItem();
                item.Label = String.Copy(c.GetString("label"));
                item.Detail = String.Copy(c.GetString("detail"));
                item.Kind = c.GetInt("kind");
                item.Insert = String.Copy(c.GetString("insert"));
                items.Add(item);
            }
            return items;
        }

        public static void FreeCompletions(List<CompletionItem> items)
        {
            for (int i = 0; i < items.Count; i++)
            {
                String.Free(items[i].Label);
                String.Free(items[i].Detail);
                String.Free(items[i].Insert);
            }
            delete items;
        }
    }
}
