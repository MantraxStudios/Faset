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
        public var Line: int;        // 0..n-1
        public var Col: int;         // columna en bytes
        public var Severity: int;    // 1 error, 3 nota
        public var Message: string;  // copia propia
    }

    public struct SymbolRef
    {
        public var Line: int;
        public var Col: int;
        public var Length: int;
        public var Hover: string;    // copia propia
        public var DefPath: string;  // copia propia ("" si no hay)
        public var DefLine: int;
        public var DefCol: int;
    }

    public struct CompletionItem
    {
        public var Label: string;   // copia propia
        public var Detail: string;  // copia propia
        public var Kind: int;       // CompletionItemKind de LSP
        public var Insert: string;  // texto a insertar ("" = Label); "$0" marca el cursor (copia propia)
    }

    public class Document
    {
        public var FullPath: string;  // ruta absoluta (copia propia)
        public var Name: string;      // vista de FullPath
        public var Buffer: TextBuffer = new TextBuffer();
        public var Diagnostics: List<Diagnostic> = new List<Diagnostic>();
        public var Refs: List<SymbolRef> = new List<SymbolRef>();
        public var AnalyzedVersion: int = -1;

        deinit
        {
            ClearDiagnostics();
            ClearRefs();
            delete Diagnostics;
            delete Refs;
            delete Buffer;
            String.Free(FullPath);
        }

        public static func Open(path: string) -> Document
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

        public func Save() -> bool
        {
            string text = Buffer.GetAll();
            bool ok = File.WriteAllText(FullPath, text);
            String.Free(text);
            if (ok) Buffer.SavedVersion = Buffer.Version;
            return ok;
        }

        public prop Modified: bool => Buffer.Modified;

        // .fstproj, .fstp y .fstui: el IntelliSense es el del esquema XML (elementos, atributos y valores).
        public prop IsXml: bool => FullPath.EndsWith(".fstproj") || FullPath.EndsWith(".fstp") || FullPath.EndsWith(".fstui");

        public func ClearDiagnostics()
        {
            for (int i = 0; i < Diagnostics.Count; i++) String.Free(Diagnostics[i].Message);
            Diagnostics.Clear();
        }

        public func ClearRefs()
        {
            for (int i = 0; i < Refs.Count; i++)
            {
                String.Free(Refs[i].Hover);
                String.Free(Refs[i].DefPath);
            }
            Refs.Clear();
        }

        public prop ErrorCount: int
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
        public func RefAt(line: int, col: int) -> int
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
        var faset: string;      // ruta del compilador
        var requestPath: string;
        var resultPath: string;
        public var Available: bool;
        public var LastDurationMs: long;
        public var LastFailed: bool;   // el último análisis no devolvió resultado (el compilador falló)
        // Solución abierta (.fstp, "" si no hay): el analizador elige con ella el proyecto de cada archivo.
        public var Solution: string = "";

        public prop Compiler: string => faset;

        public init(fasetPath: string)
        {
            faset = String.Copy(fasetPath);
            Available = fasetPath.Length > 0;
#if WINDOWS
            string tmp = Path.GetTempPath();   // %TEMP% del usuario
#else
            string tmp = Environment.GetVariable("TMPDIR");
            if (tmp.IsEmpty())
            {
                String.Free(tmp);
                tmp = String.Copy("/tmp");
            }
#endif
            string stamp = String.FromInt(Time.NowUnixMs() % 1000000000);
            requestPath = String.Concat(tmp, "/fasetstudio-", stamp);
            string reqName = String.Concat(requestPath, "-req.json");
            resultPath = String.Concat(requestPath, "-res.json");
            String.Free(requestPath);
            requestPath = reqName;
            String.Free(stamp);
            String.Free(tmp);
        }

        deinit
        {
            File.Delete(requestPath);
            File.Delete(resultPath);
            String.Free(faset);
            String.Free(requestPath);
            String.Free(resultPath);
        }

        // ChildProcess.ReadAvailable sin los '\r' de los finales de línea de Windows (en los
        // paneles se verían como un carácter desconocido). true si añadió algo.
        public static func ReadChild(p: ChildProcess, into: StringBuilder) -> bool
        {
#if WINDOWS
            StringBuilder tmp = new StringBuilder();
            bool any = p.ReadAvailable(tmp);
            if (any)
            {
                string clean = Text.Replace(tmp.View(), "\r", "");
                into.Append(clean);
                String.Free(clean);
            }
            delete tmp;
            return any;
#else
            return p.ReadAvailable(into);
#endif
        }

        // Entrecomilla un argumento para la línea de shell de Process.Capture / ChildProcess:
        // sh ('...') en Linux; en Windows, cmd.exe ("..." con las reglas de CommandLineToArgvW).
        public static func Quote(s: string) -> string
        {
#if WINDOWS
            return CommandLine.QuoteCmd(s);
#else
            StringBuilder sb = new StringBuilder();
            sb.Append("'").Append(Text.Replace(s, "'", "'\\''")).Append("'");
            string r = sb.ToString();
            delete sb;
            return r;
#endif
        }

        // Lanza el análisis. 'focusText' (opcional) reemplaza el texto del documento enfocado.
        // Devuelve el JSON de resultado (libéralo con delete) o null.
        public func Run(focus: Document, open: List<Document>, focusText: string, hasFocusText: bool) -> JsonValue
        {
            if (!Available) return null;
            StringBuilder req = new StringBuilder();
            req.Append("{\"focus\":");
            Json.WriteString(req, focus.FullPath);
            if (Solution.Length > 0)
            {
                req.Append(",\"solution\":");
                Json.WriteString(req, Solution);
            }
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
        public func Apply(result: JsonValue, open: List<Document>)
        {
            // Solo se renuevan los documentos analizados: en una solución, los de otros proyectos
            // conservan sus errores hasta que se analicen.
            JsonValue analyzed = result.Get("analyzed");
            for (int i = 0; i < open.Count; i++)
            {
                if (analyzed != null && !Listed(analyzed, open[i].FullPath)) continue;
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

        static func Listed(list: JsonValue, path: string) -> bool
        {
            for (int i = 0; i < list.Count; i++)
                if (list.At(i).AsString() == path) return true;
            return false;
        }

        // Diagnósticos sin documento abierto (por ejemplo de otros archivos del proyecto).
        public static func Find(docs: List<Document>, path: string) -> Document
        {
            for (int i = 0; i < docs.Count; i++)
                if (docs[i].FullPath == path) return docs[i];
            return null;
        }

        public static func Completions(result: JsonValue) -> List<CompletionItem>
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

        public static func FreeCompletions(items: List<CompletionItem>)
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
