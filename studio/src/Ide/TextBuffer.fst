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
        public var Line: int;
        public var Col: int;

        public init(line: int, col: int) { Line = line; Col = col; }

        public operator ==(a: TextPos, b: TextPos) -> bool => a.Line == b.Line && a.Col == b.Col;
        public operator <(a: TextPos, b: TextPos) -> bool => a.Line < b.Line || (a.Line == b.Line && a.Col < b.Col);
        public operator <=(a: TextPos, b: TextPos) -> bool => a < b || a == b;
        public static func Min(a: TextPos, b: TextPos) -> TextPos => a < b ? a : b;
        public static func Max(a: TextPos, b: TextPos) -> TextPos => a < b ? b : a;
    }

    public memory_unsafe class Line
    {
        public var Data: byte*;
        public var Length: int;
        var capacity: int;

        deinit { Memory.Free(Data); }

        public prop View: string => String.FromBytes(Data, Length);

        func Reserve(n: int)
        {
            if (n <= capacity) return;
            int c = capacity < 16 ? 16 : capacity;
            while (c < n) c *= 2;
            Data = (byte*)Memory.Realloc(Data, c);
            capacity = c;
        }

        public func Insert(at: int, s: string)
        {
            if (s.Length == 0) return;
            Reserve(Length + s.Length);
            Memory.Copy(Data + at + s.Length, Data + at, Length - at);
            Memory.Copy(Data + at, s.Ptr, s.Length);
            Length += s.Length;
        }

        public func Delete(at: int, count: int)
        {
            if (count <= 0) return;
            Memory.Copy(Data + at, Data + at + count, Length - at - count);
            Length -= count;
        }

        public func Append(s: string) { Insert(Length, s); }
        public func Truncate(n: int) { if (n < Length) Length = n; }
    }

    // Una operación de edición, para deshacer.
    class EditRecord
    {
        public var IsInsert: bool;
        public var Start: TextPos;
        public var Text: string;  // copia propia
        public var CursorBefore: TextPos;
        public var CursorAfter: TextPos;
        public var Group: int;

        deinit { String.Free(Text); }
    }

    public memory_unsafe class TextBuffer
    {
        public var Lines: List<Line> = new List<Line>();
        var undo: List<EditRecord> = new List<EditRecord>();
        var redo: List<EditRecord> = new List<EditRecord>();
        var group: int;
        var recording: bool = true;

        public var Version: int;        // cambia con cada edición
        public var SavedVersion: int;   // versión guardada en disco

        public init() { Lines.Add(new Line()); }

        deinit
        {
            for (int i = 0; i < Lines.Count; i++) delete Lines[i];
            delete Lines;
            ClearHistory();
            delete undo;
            delete redo;
        }

        public prop LineCount: int => Lines.Count;
        public prop Modified: bool => Version != SavedVersion;
        public func LineText(i: int) -> string => Lines[i].View;
        public func LineLength(i: int) -> int => Lines[i].Length;

        public func ClearHistory()
        {
            for (int i = 0; i < undo.Count; i++) delete undo[i];
            for (int i = 0; i < redo.Count; i++) delete redo[i];
            undo.Clear();
            redo.Clear();
        }

        // Cada acción del usuario es un grupo: se deshace de una vez.
        public func NewGroup() { group++; }
        public prop CurrentGroup: int => group;

        public func Clamp(p: TextPos) -> TextPos
        {
            if (p.Line < 0) return new TextPos(0, 0);
            if (p.Line >= Lines.Count) return new TextPos(Lines.Count - 1, Lines.Last().Length);
            if (p.Col < 0) p.Col = 0;
            if (p.Col > Lines[p.Line].Length) p.Col = Lines[p.Line].Length;
            return p;
        }

        public prop End: TextPos => new TextPos(Lines.Count - 1, Lines.Last().Length);

        // Inserta texto (puede tener saltos de línea) y devuelve la posición final.
        public func Insert(p: TextPos, text: string, cursorBefore: TextPos) -> TextPos
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

        public func Delete(a: TextPos, b: TextPos, cursorBefore: TextPos)
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
        public func GetText(a: TextPos, b: TextPos) -> string
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

        public func GetAll() -> string => GetText(new TextPos(0, 0), End);

        // Reemplaza todo el contenido sin registrar en el historial.
        public func SetAll(text: string)
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

        func Record(isInsert: bool, start: TextPos, text: string, before: TextPos, after: TextPos)
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
        public func CanMergeTyping(at: TextPos) -> bool
        {
            if (undo.Count == 0) return false;
            EditRecord last = undo.Last();
            return last.IsInsert && last.Group == group && last.CursorAfter == at && last.Text.Length < 64 &&
                   !last.Text.Contains("\n");
        }

        func Apply(r: EditRecord, forward: bool)
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

        func Advance(p: TextPos, text: string) -> TextPos
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

        public func Undo(out cursor: TextPos) -> bool
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

        public func Redo(out cursor: TextPos) -> bool
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
