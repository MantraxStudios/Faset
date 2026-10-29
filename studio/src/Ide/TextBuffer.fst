// =============================================================================
//  Búfer de texto: líneas editables (UTF-8) con deshacer / rehacer agrupado.
//  Las posiciones son (línea, columna en bytes).
// =============================================================================
using std.collections;
using std.text;

namespace FasetStudio.Ide
{
    public struct TextPos
    {
        public int Line;
        public int Col;

        public TextPos(int line, int col) { Line = line; Col = col; }

        public static bool operator ==(TextPos a, TextPos b) => a.Line == b.Line && a.Col == b.Col;
        public static bool operator <(TextPos a, TextPos b) => a.Line < b.Line || (a.Line == b.Line && a.Col < b.Col);
        public static bool operator <=(TextPos a, TextPos b) => a < b || a == b;
        public static TextPos Min(TextPos a, TextPos b) => a < b ? a : b;
        public static TextPos Max(TextPos a, TextPos b) => a < b ? b : a;
    }

    public class Line
    {
        public byte* Data;
        public int Length;
        int capacity;

        ~Line() { Memory.Free(Data); }

        public string View => String.FromBytes(Data, Length);

        void Reserve(int n)
        {
            if (n <= capacity) return;
            int c = capacity < 16 ? 16 : capacity;
            while (c < n) c *= 2;
            Data = (byte*)Memory.Realloc(Data, c);
            capacity = c;
        }

        public void Insert(int at, string s)
        {
            if (s.Length == 0) return;
            Reserve(Length + s.Length);
            Memory.Copy(Data + at + s.Length, Data + at, Length - at);
            Memory.Copy(Data + at, s.Ptr, s.Length);
            Length += s.Length;
        }

        public void Delete(int at, int count)
        {
            if (count <= 0) return;
            Memory.Copy(Data + at, Data + at + count, Length - at - count);
            Length -= count;
        }

        public void Append(string s) { Insert(Length, s); }
        public void Truncate(int n) { if (n < Length) Length = n; }
    }

    // Una operación de edición, para deshacer.
    class EditRecord
    {
        public bool IsInsert;
        public TextPos Start;
        public string Text;  // copia propia
        public TextPos CursorBefore;
        public TextPos CursorAfter;
        public int Group;

        ~EditRecord() { String.Free(Text); }
    }

    public class TextBuffer
    {
        public List<Line> Lines = new List<Line>();
        List<EditRecord> undo = new List<EditRecord>();
        List<EditRecord> redo = new List<EditRecord>();
        int group;
        bool recording = true;

        public int Version;        // cambia con cada edición
        public int SavedVersion;   // versión guardada en disco

        public TextBuffer() { Lines.Add(new Line()); }

        ~TextBuffer()
        {
            for (int i = 0; i < Lines.Count; i++) delete Lines[i];
            delete Lines;
            ClearHistory();
            delete undo;
            delete redo;
        }

        public int LineCount => Lines.Count;
        public bool Modified => Version != SavedVersion;
        public string LineText(int i) => Lines[i].View;
        public int LineLength(int i) => Lines[i].Length;

        public void ClearHistory()
        {
            for (int i = 0; i < undo.Count; i++) delete undo[i];
            for (int i = 0; i < redo.Count; i++) delete redo[i];
            undo.Clear();
            redo.Clear();
        }

        // Cada acción del usuario es un grupo: se deshace de una vez.
        public void NewGroup() { group++; }
        public int CurrentGroup => group;

        public TextPos Clamp(TextPos p)
        {
            if (p.Line < 0) return new TextPos(0, 0);
            if (p.Line >= Lines.Count) return new TextPos(Lines.Count - 1, Lines.Last().Length);
            if (p.Col < 0) p.Col = 0;
            if (p.Col > Lines[p.Line].Length) p.Col = Lines[p.Line].Length;
            return p;
        }

        public TextPos End => new TextPos(Lines.Count - 1, Lines.Last().Length);

        // Inserta texto (puede tener saltos de línea) y devuelve la posición final.
        public TextPos Insert(TextPos p, string text, TextPos cursorBefore)
        {
            p = Clamp(p);
            TextPos start = p;
            Line line = Lines[p.Line];
            int segStart = 0;
            for (int i = 0; i <= text.Length; i++)
            {
                if (i < text.Length && text[i] != '\n') continue;
                int segEnd = i;
                if (segEnd > segStart && text[segEnd - 1] == '\r') segEnd--;  // \r\n -> \n
                string seg = text.Substring(segStart, segEnd - segStart);
                if (i == text.Length)
                {
                    line.Insert(p.Col, seg);
                    p.Col += seg.Length;
                }
                else
                {
                    // Partir la línea: lo que queda a la derecha pasa a una línea nueva.
                    Line next = new Line();
                    next.Append(String.FromBytes(line.Data + p.Col, line.Length - p.Col));
                    line.Truncate(p.Col);
                    line.Append(seg);
                    Lines.Insert(p.Line + 1, next);
                    p.Line++;
                    p.Col = 0;
                    line = next;
                }
                segStart = i + 1;
            }
            Version++;
            if (recording) Record(true, start, GetText(start, p), cursorBefore, p);
            return p;
        }

        public void Delete(TextPos a, TextPos b, TextPos cursorBefore)
        {
            a = Clamp(a);
            b = Clamp(b);
            if (b < a)
            {
                TextPos t = a;
                a = b;
                b = t;
            }
            if (a == b) return;
            if (recording) Record(false, a, GetText(a, b), cursorBefore, a);
            Line first = Lines[a.Line];
            if (a.Line == b.Line)
            {
                first.Delete(a.Col, b.Col - a.Col);
            }
            else
            {
                Line last = Lines[b.Line];
                first.Truncate(a.Col);
                first.Append(String.FromBytes(last.Data + b.Col, last.Length - b.Col));
                for (int i = a.Line + 1; i <= b.Line; i++) delete Lines[i];
                for (int k = 0; k < b.Line - a.Line; k++) Lines.RemoveAt(a.Line + 1);
            }
            Version++;
        }

        // Texto entre dos posiciones (copia: libérala con String.Free).
        public string GetText(TextPos a, TextPos b)
        {
            a = Clamp(a);
            b = Clamp(b);
            if (b < a)
            {
                TextPos t = a;
                a = b;
                b = t;
            }
            StringBuilder sb = new StringBuilder();
            for (int i = a.Line; i <= b.Line; i++)
            {
                Line l = Lines[i];
                int from = i == a.Line ? a.Col : 0;
                int to = i == b.Line ? b.Col : l.Length;
                sb.Append(String.FromBytes(l.Data + from, to - from));
                if (i < b.Line) sb.Append("\n");
            }
            string r = sb.ToString();
            delete sb;
            return r;
        }

        public string GetAll() => GetText(new TextPos(0, 0), End);

        // Reemplaza todo el contenido sin registrar en el historial.
        public void SetAll(string text)
        {
            for (int i = 0; i < Lines.Count; i++) delete Lines[i];
            Lines.Clear();
            Lines.Add(new Line());
            recording = false;
            Insert(new TextPos(0, 0), text, new TextPos(0, 0));
            recording = true;
            ClearHistory();
            Version++;
            SavedVersion = Version;
        }

        void Record(bool isInsert, TextPos start, string text, TextPos before, TextPos after)
        {
            EditRecord r = new EditRecord();
            r.IsInsert = isInsert;
            r.Start = start;
            r.Text = text;
            r.CursorBefore = before;
            r.CursorAfter = after;
            r.Group = group;
            undo.Add(r);
            for (int i = 0; i < redo.Count; i++) delete redo[i];
            redo.Clear();
        }

        // Fusiona la última inserción con un carácter escrito justo después (escritura continua).
        public bool CanMergeTyping(TextPos at)
        {
            if (undo.Count == 0) return false;
            EditRecord last = undo.Last();
            return last.IsInsert && last.Group == group && last.CursorAfter == at && last.Text.Length < 64 &&
                   !last.Text.Contains("\n");
        }

        void Apply(EditRecord r, bool forward)
        {
            recording = false;
            bool insert = r.IsInsert == forward;
            if (insert) Insert(r.Start, r.Text, r.Start);
            else
            {
                TextPos end = Advance(r.Start, r.Text);
                Delete(r.Start, end, r.Start);
            }
            recording = true;
        }

        TextPos Advance(TextPos p, string text)
        {
            for (int i = 0; i < text.Length; i++)
            {
                if (text[i] == '\n')
                {
                    p.Line++;
                    p.Col = 0;
                }
                else p.Col++;
            }
            return p;
        }

        public bool Undo(out TextPos cursor)
        {
            cursor = new TextPos(0, 0);
            if (undo.Count == 0) return false;
            int g = undo.Last().Group;
            while (undo.Count > 0 && undo.Last().Group == g)
            {
                EditRecord r = undo.Pop();
                Apply(r, false);
                cursor = r.CursorBefore;
                redo.Add(r);
            }
            return true;
        }

        public bool Redo(out TextPos cursor)
        {
            cursor = new TextPos(0, 0);
            if (redo.Count == 0) return false;
            int g = redo.Last().Group;
            while (redo.Count > 0 && redo.Last().Group == g)
            {
                EditRecord r = redo.Pop();
                Apply(r, true);
                cursor = r.CursorAfter;
                undo.Add(r);
            }
            return true;
        }
    }
}
