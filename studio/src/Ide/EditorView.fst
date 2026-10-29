// =============================================================================
//  Vista de edición de un documento: dibujo con resaltado, selección, cursor,
//  números de línea, subrayado de errores, edición y navegación con teclado/ratón.
//  Varias vistas pueden mostrar el mismo documento (vista dividida).
// =============================================================================
using std.collections;
using std.text;
using FasetStudio.Gfx;
using FasetStudio.Platform;

namespace FasetStudio.Ide
{
    public memory_unsafe class EditorView
    {
        public Document Doc;
        public Designer Designer;   // solo para .fstui
        public bool DesignMode;     // mostrando el diseñador (true) o el XML (false)
        public TextPos Cursor;
        public TextPos Anchor;
        public int ScrollLine;
        public float ScrollX;
        public float X;
        public float Y;
        public float W;
        public float H;
        public bool Focused;
        public long CaretTime;

        int preferredCol = -1;
        bool dragging;
        bool draggingScrollbar;
        bool lastWasTyping;
        // Estado de comentario /* */ al inicio de cada línea (caché por versión).
        bool* commentState;
        int commentStateCount;
        int commentStateVersion = -1;
        byte* kinds;
        int kindsCapacity;

        public const int TabSize = 4;

        public EditorView(Document doc) { Doc = doc; }

        ~EditorView()
        {
            if (Designer != null) delete Designer;
            Memory.Free(commentState);
            Memory.Free(kinds);
        }

        TextBuffer Buf => Doc.Buffer;

        // ------------------------------------------------------------------ geometría

        public static float LineHeight(Renderer r) => r.Code.LineHeight;

        public float GutterWidth(Renderer r)
        {
            int digits = 1;
            for (int n = Buf.LineCount; n >= 10; n /= 10) digits++;
            if (digits < 3) digits = 3;
            return (digits + 4) * r.Code.CharWidth;
        }

        public int VisibleLines(Renderer r) => (int)(H / LineHeight(r));

        public bool HasSelection => !(Cursor == Anchor);
        public TextPos SelStart => TextPos.Min(Cursor, Anchor);
        public TextPos SelEnd => TextPos.Max(Cursor, Anchor);

        static bool IsCont(byte b) => (b & 0xC0) == 0x80;

        // Columna visual (en caracteres, tabuladores expandidos) de una columna en bytes.
        public int VisualCol(int line, int byteCol)
        {
            string s = Buf.LineText(line);
            int v = 0;
            for (int i = 0; i < byteCol && i < s.Length; i++)
            {
                byte b = s[i];
                if (IsCont(b)) continue;
                if (b == '\t') v = (v / TabSize + 1) * TabSize;
                else v++;
            }
            return v;
        }

        public int ByteColFromVisual(int line, int visual)
        {
            string s = Buf.LineText(line);
            int v = 0;
            int i = 0;
            while (i < s.Length)
            {
                byte b = s[i];
                int next = b == '\t' ? (v / TabSize + 1) * TabSize : v + 1;
                if (next > visual)
                {
                    // Más cerca del inicio o del final del carácter.
                    if (visual - v > next - visual) i = NextCharIndex(s, i);
                    return i;
                }
                v = next;
                i = NextCharIndex(s, i);
            }
            return s.Length;
        }

        static int NextCharIndex(string s, int i)
        {
            i++;
            while (i < s.Length && IsCont(s[i])) i++;
            return i;
        }

        static int PrevCharIndex(string s, int i)
        {
            i--;
            while (i > 0 && IsCont(s[i])) i--;
            return i < 0 ? 0 : i;
        }

        public TextPos PosFromPoint(Renderer r, float px, float py)
        {
            float lh = LineHeight(r);
            int line = ScrollLine + (int)Math.Floor((py - Y) / lh);
            if (line < 0) line = 0;
            if (line >= Buf.LineCount) return Buf.End;
            float textX = X + GutterWidth(r) - ScrollX;
            int visual = (int)Math.Floor((px - textX) / r.Code.CharWidth + 0.5);
            if (visual < 0) visual = 0;
            return new TextPos(line, ByteColFromVisual(line, visual));
        }

        public float CaretX(Renderer r) => X + GutterWidth(r) - ScrollX + VisualCol(Cursor.Line, Cursor.Col) * r.Code.CharWidth;
        public float CaretY(Renderer r) => Y + (Cursor.Line - ScrollLine) * LineHeight(r);

        public void EnsureCursorVisible(Renderer r)
        {
            if (W <= 0 || H <= 0)
            {
                // Aún sin tamaño (antes del primer dibujado): dejar la línea a la vista con margen.
                if (Cursor.Line < ScrollLine || Cursor.Line > ScrollLine + 20) ScrollLine = Math.Max(0, Cursor.Line - 10);
                return;
            }
            int visible = VisibleLines(r);
            if (Cursor.Line < ScrollLine) ScrollLine = Cursor.Line;
            if (visible > 0 && Cursor.Line >= ScrollLine + visible) ScrollLine = Cursor.Line - visible + 1;
            float cw = r.Code.CharWidth;
            float textW = W - GutterWidth(r) - 14;
            float cx = VisualCol(Cursor.Line, Cursor.Col) * cw;
            if (cx < ScrollX) ScrollX = (float)Math.Max(0.0, cx - cw * 4);
            if (cx > ScrollX + textW - cw) ScrollX = (float)(cx - textW + cw * 4);
        }

        public void ClampScroll()
        {
            int maxLine = Buf.LineCount - 1;
            if (ScrollLine > maxLine) ScrollLine = maxLine;
            if (ScrollLine < 0) ScrollLine = 0;
        }

        // ------------------------------------------------------------------ dibujo

        void UpdateCommentStates()
        {
            if (commentStateVersion == Buf.Version && commentStateCount == Buf.LineCount) return;
            if (commentStateCount < Buf.LineCount + 1)
            {
                Memory.Free(commentState);
                commentState = Memory.New<bool>(Buf.LineCount + 64);
            }
            commentStateCount = Buf.LineCount;
            bool state = false;
            for (int i = 0; i < Buf.LineCount; i++)
            {
                commentState[i] = state;
                string s = Buf.LineText(i);
                // Recorrido rápido: solo importa abrir/cerrar comentarios fuera de cadenas y de //.
                int j = 0;
                while (j < s.Length)
                {
                    byte c = s[j];
                    if (state)
                    {
                        if (c == '*' && j + 1 < s.Length && s[j + 1] == '/')
                        {
                            state = false;
                            j += 2;
                            continue;
                        }
                        j++;
                        continue;
                    }
                    if (c == '/' && j + 1 < s.Length && s[j + 1] == '/') break;
                    if (c == '/' && j + 1 < s.Length && s[j + 1] == '*')
                    {
                        state = true;
                        j += 2;
                        continue;
                    }
                    if (c == '"' || c == '\'')
                    {
                        j++;
                        while (j < s.Length && s[j] != c)
                        {
                            if (s[j] == '\\') j++;
                            j++;
                        }
                    }
                    j++;
                }
            }
            commentStateVersion = Buf.Version;
        }

        public void Draw(Renderer r, Highlighter hl, bool showCaret)
        {
            float lh = LineHeight(r);
            float cw = r.Code.CharWidth;
            float gutter = GutterWidth(r);
            float textTop = (lh - r.Code.Ascent - r.Code.Descent) / 2 - 1;
            r.PushClip(X, Y, W, H);
            UpdateCommentStates();
            int visible = VisibleLines(r) + 1;
            TextPos s0 = SelStart, s1 = SelEnd;
            float textX = X + gutter - ScrollX;

            for (int n = 0; n < visible; n++)
            {
                int i = ScrollLine + n;
                if (i >= Buf.LineCount) break;
                float ly = Y + n * lh;
                string line = Buf.LineText(i);
                bool current = i == Cursor.Line && Focused;
                if (current && !HasSelection) r.Rect(X, ly, W, lh, Theme.CurrentLine);
                DebugMarks.Background(r, Doc.FullPath, i, X, ly, W, lh);   // línea donde está detenido el depurador

                // Selección (rectángulos redondeados por línea)
                if (HasSelection && i >= s0.Line && i <= s1.Line)
                {
                    int a = i == s0.Line ? VisualCol(i, s0.Col) : 0;
                    int b = i == s1.Line ? VisualCol(i, s1.Col) : VisualCol(i, line.Length) + 1;
                    r.PushClip(X + gutter - 4, Y, W - gutter + 4, H);
                    r.RoundRect(textX + a * cw - 2, ly, (b - a) * cw + 4, lh, 4, Focused ? Theme.Selection : Theme.SelectionInactive);
                    r.PopClip();
                }

                // Número de línea
                string num = String.FromInt(i + 1);
                float numW = r.TextWidth(r.Code, num);
                r.Text(r.Code, X + gutter - numW - cw * 2, ly + textTop, num, i == Cursor.Line ? Theme.LineNumberActive : Theme.LineNumber);
                String.Free(num);
                DebugMarks.Gutter(r, Doc.FullPath, i, X, ly, lh);   // punto de interrupción y flecha de la línea actual

                // Texto con resaltado
                if (line.Length > kindsCapacity)
                {
                    Memory.Free(kinds);
                    kindsCapacity = line.Length + 256;
                    kinds = (byte*)Memory.Alloc(kindsCapacity);
                }
                Memory.Set(kinds, 0, line.Length);
                hl.Colorize(line, kinds, commentState[i]);
                r.PushClip(X + gutter - 2, Y, W - gutter - 8, H);
                int col = 0;
                int k = 0;
                float firstVisible = ScrollX / cw - 1;
                float lastVisible = (ScrollX + W) / cw + 1;
                while (k < line.Length)
                {
                    int start = k;
                    char ch = Renderer.NextChar(line, ref k);
                    if (ch == '\t')
                    {
                        col = (col / TabSize + 1) * TabSize;
                        continue;
                    }
                    if (col >= firstVisible && col <= lastVisible && ch != ' ')
                    {
                        byte kind = kinds[start];
                        int style = Theme.SyntaxStyle(kind);
                        Font f = style == 1 ? r.CodeBold : (style == 2 ? r.CodeItalic : r.Code);
                        r.Char(f, textX + col * cw, ly + textTop, ch, Theme.Syntax(kind));
                    }
                    col++;
                }

                // Diagnósticos: subrayado ondulado
                for (int d = 0; d < Doc.Diagnostics.Count; d++)
                {
                    Diagnostic g = Doc.Diagnostics[d];
                    if (g.Line != i) continue;
                    int dc = g.Col < line.Length ? g.Col : line.Length;
                    int de = dc;
                    while (de < line.Length && (Char.IsLetterOrDigit((char)line[de]) || line[de] == '_')) de++;
                    float x0 = textX + VisualCol(i, dc) * cw, x1 = textX + VisualCol(i, de) * cw;
                    if (de == dc) x1 = x0 + cw;
                    Color color = g.Severity == 1 ? Theme.Error : Theme.Info;
                    for (float x = x0; x < x1; x += 4)
                    {
                        r.Rect(x, ly + lh - 4, 2, 1, color);
                        r.Rect(x + 2, ly + lh - 3, 2, 1, color);
                    }
                }
                r.PopClip();
            }

            // Cursor
            if (showCaret && Focused && Cursor.Line >= ScrollLine && Cursor.Line < ScrollLine + visible)
            {
                float cx = CaretX(r);
                if (cx >= X + gutter - 3) r.RoundRect(cx - 1, CaretY(r) + 2, 2, lh - 4, 1, Theme.Caret);
            }

            // Barra de desplazamiento fina con marcas de errores
            int total = Buf.LineCount + VisibleLines(r) - 1;
            if (Buf.LineCount > VisibleLines(r) / 2)
            {
                float trackX = X + W - 10;
                float thumbH = (float)Math.Max(28.0, H * VisibleLines(r) / total);
                float thumbY = Y + 4 + (H - thumbH - 8) * ScrollLine / Math.Max(1, Buf.LineCount - 1);
                r.RoundRect(trackX + 2, thumbY, 5, thumbH, 3, Theme.ScrollThumb);
            }
            for (int d = 0; d < Doc.Diagnostics.Count; d++)
            {
                Diagnostic g = Doc.Diagnostics[d];
                float my = Y + 4 + (H - 8) * g.Line / Math.Max(1, Buf.LineCount);
                r.RoundRect(X + W - 9, my, 6, 3, 1, g.Severity == 1 ? Theme.Error : Theme.Info);
            }
            r.PopClip();
        }

        // ------------------------------------------------------------------ edición

        public void SetCursor(TextPos p, bool extend)
        {
            Cursor = Buf.Clamp(p);
            if (!extend) Anchor = Cursor;
            preferredCol = -1;
            lastWasTyping = false;
        }

        public void SelectAll()
        {
            Anchor = new TextPos(0, 0);
            Cursor = Buf.End;
        }

        // Texto seleccionado (copia) o "" si no hay selección.
        public string SelectedText() => HasSelection ? Buf.GetText(SelStart, SelEnd) : String.Copy("");

        void DeleteSelection()
        {
            if (!HasSelection) return;
            TextPos a = SelStart;
            Buf.Delete(a, SelEnd, Cursor);
            Cursor = a;
            Anchor = a;
        }

        // Inserta texto en lugar de la selección. 'typing' agrupa la escritura continua para deshacer.
        public void InsertText(string text, bool typing)
        {
            if (!(typing && lastWasTyping && !HasSelection && Buf.CanMergeTyping(Cursor))) Buf.NewGroup();
            DeleteSelection();
            Cursor = Buf.Insert(Cursor, text, Cursor);
            Anchor = Cursor;
            preferredCol = -1;
            lastWasTyping = typing;
        }

        string LineIndent(int line)
        {
            string s = Buf.LineText(line);
            int n = 0;
            while (n < s.Length && (s[n] == ' ' || s[n] == '\t')) n++;
            return s.Substring(0, n);
        }

        byte CharBefore()
        {
            string s = Buf.LineText(Cursor.Line);
            return Cursor.Col > 0 ? s[Cursor.Col - 1] : (byte)0;
        }

        byte CharAfter()
        {
            string s = Buf.LineText(Cursor.Line);
            return Cursor.Col < s.Length ? s[Cursor.Col] : (byte)0;
        }

        public void TypeChar(char c)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append(c);
            string text = sb.ToString();
            delete sb;
            byte after = CharAfter();
            // Saltar sobre el cierre que ya existe.
            if ((c == ')' || c == ']' || c == '"' || c == '\'' || c == '}') && !HasSelection && after == (byte)c)
            {
                SetCursor(new TextPos(Cursor.Line, Cursor.Col + 1), false);
                String.Free(text);
                return;
            }
            // '}' en una línea vacía: quitar un nivel de sangría.
            if (c == '}' && !HasSelection)
            {
                string before = Buf.LineText(Cursor.Line).Substring(0, Cursor.Col);
                if (before.Length >= TabSize && before.Trim().Length == 0)
                {
                    Buf.NewGroup();
                    Buf.Delete(new TextPos(Cursor.Line, Cursor.Col - TabSize), Cursor, Cursor);
                    Cursor.Col -= TabSize;
                    Anchor = Cursor;
                }
            }
            bool closeable = c == '(' || c == '[' || c == '"' || c == '\'';
            bool afterIsWord = after != 0 && (Char.IsLetterOrDigit((char)after) || after == '_');
            if (closeable && !afterIsWord && !HasSelection)
            {
                string pair = c == '(' ? "()" : c == '[' ? "[]" : c == '"' ? "\"\"" : "''";
                InsertText(pair, false);
                SetCursor(new TextPos(Cursor.Line, Cursor.Col - 1), false);
            }
            else
            {
                InsertText(text, true);
            }
            String.Free(text);
        }

        public void NewLine()
        {
            string indent = LineIndent(Cursor.Line);
            byte before = CharBefore(), after = CharAfter();
            StringBuilder sb = new StringBuilder();
            sb.Append("\n").Append(indent);
            if (before == '{')
            {
                sb.AppendRepeat(" ", TabSize);
                if (after == '}')
                {
                    string inner = sb.ToString();
                    sb.Append("\n").Append(indent);
                    InsertText(sb.View(), false);
                    TextPos p = new TextPos(Cursor.Line - 1, inner.Length - 1);
                    SetCursor(p, false);
                    String.Free(inner);
                    delete sb;
                    return;
                }
            }
            InsertText(sb.View(), false);
            delete sb;
        }

        public void Backspace()
        {
            if (HasSelection)
            {
                Buf.NewGroup();
                DeleteSelection();
                return;
            }
            if (Cursor.Col == 0 && Cursor.Line == 0) return;
            Buf.NewGroup();
            string s = Buf.LineText(Cursor.Line);
            TextPos from;
            if (Cursor.Col == 0)
            {
                from = new TextPos(Cursor.Line - 1, Buf.LineLength(Cursor.Line - 1));
            }
            else if (s.Substring(0, Cursor.Col).Trim().Length == 0 && Cursor.Col % TabSize == 0)
            {
                from = new TextPos(Cursor.Line, Cursor.Col - TabSize);  // borrar un nivel de sangría
            }
            else
            {
                from = new TextPos(Cursor.Line, PrevCharIndex(s, Cursor.Col));
                // Borrar también el cierre automático vacío: ( | )
                byte open = s[from.Col];
                byte close = Cursor.Col < s.Length ? s[Cursor.Col] : (byte)0;
                if ((open == '(' && close == ')') || (open == '[' && close == ']') || (open == '"' && close == '"'))
                {
                    Buf.Delete(from, new TextPos(Cursor.Line, Cursor.Col + 1), Cursor);
                    Cursor = from;
                    Anchor = from;
                    return;
                }
            }
            Buf.Delete(from, Cursor, Cursor);
            Cursor = from;
            Anchor = from;
            preferredCol = -1;
        }

        public void DeleteForward()
        {
            Buf.NewGroup();
            if (HasSelection)
            {
                DeleteSelection();
                return;
            }
            string s = Buf.LineText(Cursor.Line);
            TextPos to = Cursor.Col < s.Length ? new TextPos(Cursor.Line, NextCharIndex(s, Cursor.Col))
                                               : new TextPos(Cursor.Line + 1, 0);
            Buf.Delete(Cursor, to, Cursor);
        }

        // Aplica una función a las líneas seleccionadas (sangría, comentarios).
        void SelectedLines(out int first, out int last)
        {
            first = SelStart.Line;
            last = SelEnd.Line;
            if (HasSelection && SelEnd.Col == 0 && last > first) last--;
        }

        public void Indent(bool outdent)
        {
            if (!HasSelection && !outdent)
            {
                int v = VisualCol(Cursor.Line, Cursor.Col);
                int spaces = TabSize - v % TabSize;
                StringBuilder sb = new StringBuilder();
                sb.AppendRepeat(" ", spaces);
                InsertText(sb.View(), false);
                delete sb;
                return;
            }
            int first, last;
            SelectedLines(out first, out last);
            Buf.NewGroup();
            for (int i = first; i <= last; i++)
            {
                if (outdent)
                {
                    string s = Buf.LineText(i);
                    int n = 0;
                    while (n < TabSize && n < s.Length && s[n] == ' ') n++;
                    if (n > 0) Buf.Delete(new TextPos(i, 0), new TextPos(i, n), Cursor);
                    if (i == Cursor.Line) Cursor.Col = Math.Max(0, Cursor.Col - n);
                    if (i == Anchor.Line) Anchor.Col = Math.Max(0, Anchor.Col - n);
                }
                else if (Buf.LineLength(i) > 0)
                {
                    Buf.Insert(new TextPos(i, 0), "    ", Cursor);
                    if (i == Cursor.Line) Cursor.Col += TabSize;
                    if (i == Anchor.Line) Anchor.Col += TabSize;
                }
            }
        }

        public void ToggleComment()
        {
            int first, last;
            SelectedLines(out first, out last);
            bool allCommented = true;
            for (int i = first; i <= last; i++)
            {
                string t = Buf.LineText(i).Trim();
                if (t.Length > 0 && !t.StartsWith("//")) allCommented = false;
            }
            Buf.NewGroup();
            for (int i = first; i <= last; i++)
            {
                string s = Buf.LineText(i);
                int n = 0;
                while (n < s.Length && s[n] == ' ') n++;
                if (allCommented)
                {
                    if (s.Substring(n).StartsWith("//"))
                    {
                        int len = s.Substring(n).StartsWith("// ") ? 3 : 2;
                        Buf.Delete(new TextPos(i, n), new TextPos(i, n + len), Cursor);
                        if (i == Cursor.Line && Cursor.Col > n) Cursor.Col = Math.Max(n, Cursor.Col - len);
                        if (i == Anchor.Line && Anchor.Col > n) Anchor.Col = Math.Max(n, Anchor.Col - len);
                    }
                }
                else if (s.Trim().Length > 0)
                {
                    Buf.Insert(new TextPos(i, n), "// ", Cursor);
                    if (i == Cursor.Line && Cursor.Col >= n) Cursor.Col += 3;
                    if (i == Anchor.Line && Anchor.Col >= n) Anchor.Col += 3;
                }
            }
        }

        public void DuplicateLine()
        {
            string s = Buf.LineText(Cursor.Line);
            string copy = String.Concat("\n", s);
            Buf.NewGroup();
            Buf.Insert(new TextPos(Cursor.Line, s.Length), copy, Cursor);
            String.Free(copy);
            SetCursor(new TextPos(Cursor.Line + 1, Cursor.Col), false);
        }

        // Alt+↑/↓: sube o baja las líneas seleccionadas, intercambiándolas con la vecina.
        public void MoveLines(int dir)
        {
            int first = 0, last = 0;
            SelectedLines(out first, out last);
            if ((dir < 0 && first == 0) || (dir > 0 && last + 1 >= Buf.LineCount)) return;
            int other = dir < 0 ? first - 1 : last + 1;
            int a = dir < 0 ? other : first, b = dir < 0 ? last : other;
            string moving = Buf.GetText(new TextPos(first, 0), new TextPos(last, Buf.LineLength(last)));
            string neighbour = String.Copy(Buf.LineText(other));
            string joined = dir < 0 ? String.Concat(moving, "\n", neighbour) : String.Concat(neighbour, "\n", moving);
            TextPos cursor = Cursor, anchor = Anchor;
            Buf.NewGroup();
            Buf.Delete(new TextPos(a, 0), new TextPos(b, Buf.LineLength(b)), Cursor);
            Buf.Insert(new TextPos(a, 0), joined, Cursor);
            Buf.NewGroup();
            Anchor = Buf.Clamp(new TextPos(anchor.Line + dir, anchor.Col));
            Cursor = Buf.Clamp(new TextPos(cursor.Line + dir, cursor.Col));
            preferredCol = -1;
            String.Free(moving);
            String.Free(neighbour);
            String.Free(joined);
        }

        // Alt+Shift+↑/↓: duplica las líneas seleccionadas encima o debajo.
        public void DuplicateLines(int dir)
        {
            int first = 0, last = 0;
            SelectedLines(out first, out last);
            string text = Buf.GetText(new TextPos(first, 0), new TextPos(last, Buf.LineLength(last)));
            string copy = String.Concat("\n", text);
            Buf.NewGroup();
            Buf.Insert(new TextPos(last, Buf.LineLength(last)), copy, Cursor);
            Buf.NewGroup();
            if (dir > 0)
            {
                int n = last - first + 1;
                Anchor = new TextPos(Anchor.Line + n, Anchor.Col);
                Cursor = new TextPos(Cursor.Line + n, Cursor.Col);
            }
            String.Free(text);
            String.Free(copy);
        }

        bool IsBlankLine(int line) => Buf.LineText(line).Trim().Length == 0;

        // Ctrl+↑/↓: salta al bloque anterior o siguiente (la próxima línea en blanco).
        void ParagraphJump(int dir, bool extend)
        {
            int n = Buf.LineCount, l = Cursor.Line + dir;
            while (l > 0 && l < n - 1 && IsBlankLine(l)) l += dir;
            while (l > 0 && l < n - 1 && !IsBlankLine(l)) l += dir;
            l = Math.Clamp(l, 0, n - 1);
            SetCursor(new TextPos(l, dir > 0 && l == n - 1 ? Buf.LineLength(l) : 0), extend);
        }

        // Ctrl+Retroceso / Ctrl+Supr: borra la palabra anterior o siguiente.
        void DeleteWord(int dir)
        {
            if (HasSelection)
            {
                Backspace();
                return;
            }
            TextPos target = dir < 0 ? WordLeft(Cursor) : WordRight(Cursor);
            if (target == Cursor) return;
            Buf.NewGroup();
            Buf.Delete(TextPos.Min(target, Cursor), TextPos.Max(target, Cursor), Cursor);
            Buf.NewGroup();
            SetCursor(TextPos.Min(target, Cursor), false);
        }

        // Ctrl+L: selecciona la línea; repetido, amplía la selección a la siguiente.
        void SelectLine()
        {
            int line = Cursor.Line;
            bool extending = HasSelection && Cursor.Col == 0 && Cursor.Line > Anchor.Line;
            if (!extending) Anchor = new TextPos(line, 0);
            else line = Cursor.Line;
            Cursor = (extending ? line : line + 1) < Buf.LineCount ? new TextPos(extending ? line + 1 : line + 1, 0)
                                                                    : new TextPos(Buf.LineCount - 1, Buf.LineLength(Buf.LineCount - 1));
            if (Cursor.Line >= Buf.LineCount) Cursor = Buf.End;
            preferredCol = -1;
        }

        // Ctrl+Intro: línea nueva debajo; Ctrl+Shift+Intro: encima (con la sangría de la actual).
        void InsertLine(bool above)
        {
            int line = Cursor.Line;
            if (!above)
            {
                SetCursor(new TextPos(line, Buf.LineLength(line)), false);
                NewLine();
                return;
            }
            string indent = String.Copy(LineIndent(line));
            string text = String.Concat(indent, "\n");
            Buf.NewGroup();
            Buf.Insert(new TextPos(line, 0), text, Cursor);
            Buf.NewGroup();
            SetCursor(new TextPos(line, indent.Length), false);
            String.Free(text);
            String.Free(indent);
        }

        public void DeleteLine()
        {
            Buf.NewGroup();
            int line = Cursor.Line;
            if (Buf.LineCount == 1) Buf.Delete(new TextPos(0, 0), Buf.End, Cursor);
            else if (line + 1 < Buf.LineCount) Buf.Delete(new TextPos(line, 0), new TextPos(line + 1, 0), Cursor);
            else Buf.Delete(new TextPos(line - 1, Buf.LineLength(line - 1)), new TextPos(line, Buf.LineLength(line)), Cursor);
            SetCursor(new TextPos(Math.Min(line, Buf.LineCount - 1), 0), false);
        }

        public void Undo()
        {
            TextPos p;
            if (Buf.Undo(out p)) SetCursor(p, false);
        }

        public void Redo()
        {
            TextPos p;
            if (Buf.Redo(out p)) SetCursor(p, false);
        }

        // ------------------------------------------------------------------ navegación

        static bool IsWordChar(byte b) => Char.IsLetterOrDigit((char)b) || b == '_' || b >= 0x80;

        public TextPos WordStart(TextPos p)
        {
            p = Buf.Clamp(p);
            string s = Buf.LineText(p.Line);
            int i = p.Col;
            while (i > 0 && IsWordChar(s[i - 1])) i--;
            return new TextPos(p.Line, i);
        }

        public TextPos WordEnd(TextPos p)
        {
            p = Buf.Clamp(p);
            string s = Buf.LineText(p.Line);
            int i = p.Col;
            while (i < s.Length && IsWordChar(s[i])) i++;
            return new TextPos(p.Line, i);
        }

        // Palabra (identificador) bajo una posición, como vista.
        public string WordAt(TextPos p)
        {
            TextPos a = WordStart(p), b = WordEnd(p);
            return Buf.LineText(p.Line).Substring(a.Col, b.Col - a.Col);
        }

        TextPos WordLeft(TextPos p)
        {
            string s = Buf.LineText(p.Line);
            if (p.Col == 0) return p.Line > 0 ? new TextPos(p.Line - 1, Buf.LineLength(p.Line - 1)) : p;
            int i = p.Col;
            while (i > 0 && s[i - 1] == ' ') i--;
            if (i > 0 && IsWordChar(s[i - 1])) while (i > 0 && IsWordChar(s[i - 1])) i--;
            else if (i > 0) i--;
            return new TextPos(p.Line, i);
        }

        TextPos WordRight(TextPos p)
        {
            string s = Buf.LineText(p.Line);
            if (p.Col >= s.Length) return p.Line + 1 < Buf.LineCount ? new TextPos(p.Line + 1, 0) : p;
            int i = p.Col;
            if (IsWordChar(s[i])) while (i < s.Length && IsWordChar(s[i])) i++;
            else i++;
            while (i < s.Length && s[i] == ' ') i++;
            return new TextPos(p.Line, i);
        }

        void MoveVertical(int lines, bool extend)
        {
            if (preferredCol < 0) preferredCol = VisualCol(Cursor.Line, Cursor.Col);
            int target = Math.Clamp(Cursor.Line + lines, 0, Buf.LineCount - 1);
            int keep = preferredCol;
            if (target == Cursor.Line && lines != 0)
            {
                SetCursor(lines < 0 ? new TextPos(0, 0) : Buf.End, extend);
                return;
            }
            Cursor = new TextPos(target, ByteColFromVisual(target, keep));
            if (!extend) Anchor = Cursor;
            preferredCol = keep;
            lastWasTyping = false;
        }

        // Teclas de navegación y edición. Devuelve true si la tecla se procesó.
        public bool HandleKey(Event e, Renderer r)
        {
            bool shift = e.Shift;
            uint k = e.Key;
            CaretTime = Environment.TickCount64();
            if (e.Alt && (k == Keys.Up || k == Keys.Down))
            {
                if (shift) DuplicateLines(k == Keys.Up ? -1 : 1);
                else MoveLines(k == Keys.Up ? -1 : 1);
                EnsureCursorVisible(r);
                return true;
            }
            if (e.Ctrl && (k == Keys.Up || k == Keys.Down)) ParagraphJump(k == Keys.Up ? -1 : 1, shift);
            else if (e.Ctrl && k == Keys.BackSpace) DeleteWord(-1);
            else if (e.Ctrl && k == Keys.Delete) DeleteWord(1);
            else if (e.Ctrl && (k == Keys.Return || k == Keys.KeypadEnter)) InsertLine(shift);
            else if (e.Ctrl && k == 'l') SelectLine();
            else if (k == Keys.Left)
            {
                if (HasSelection && !shift) SetCursor(SelStart, false);
                else if (e.Ctrl) SetCursor(WordLeft(Cursor), shift);
                else if (Cursor.Col > 0) SetCursor(new TextPos(Cursor.Line, PrevCharIndex(Buf.LineText(Cursor.Line), Cursor.Col)), shift);
                else if (Cursor.Line > 0) SetCursor(new TextPos(Cursor.Line - 1, Buf.LineLength(Cursor.Line - 1)), shift);
            }
            else if (k == Keys.Right)
            {
                if (HasSelection && !shift) SetCursor(SelEnd, false);
                else if (e.Ctrl) SetCursor(WordRight(Cursor), shift);
                else if (Cursor.Col < Buf.LineLength(Cursor.Line)) SetCursor(new TextPos(Cursor.Line, NextCharIndex(Buf.LineText(Cursor.Line), Cursor.Col)), shift);
                else if (Cursor.Line + 1 < Buf.LineCount) SetCursor(new TextPos(Cursor.Line + 1, 0), shift);
            }
            else if (k == Keys.Up) MoveVertical(-1, shift);
            else if (k == Keys.Down) MoveVertical(1, shift);
            else if (k == Keys.PageUp) MoveVertical(-VisibleLines(r), shift);
            else if (k == Keys.PageDown) MoveVertical(VisibleLines(r), shift);
            else if (k == Keys.Home)
            {
                if (e.Ctrl) SetCursor(new TextPos(0, 0), shift);
                else
                {
                    int indent = LineIndent(Cursor.Line).Length;
                    SetCursor(new TextPos(Cursor.Line, Cursor.Col == indent ? 0 : indent), shift);
                }
            }
            else if (k == Keys.End) SetCursor(e.Ctrl ? Buf.End : new TextPos(Cursor.Line, Buf.LineLength(Cursor.Line)), shift);
            else if (k == Keys.BackSpace) Backspace();
            else if (k == Keys.Delete) DeleteForward();
            else if (k == Keys.Return || k == Keys.KeypadEnter) NewLine();
            else if (k == Keys.Tab && !shift) Indent(false);
            else if (k == Keys.ShiftTab || (k == Keys.Tab && shift)) Indent(true);
            else if (e.Ctrl && k == 'a') SelectAll();
            else if (e.Ctrl && k == 'z' && !shift) Undo();
            else if (e.Ctrl && (k == 'y' || (k == 'z' && shift))) Redo();
            else if (e.Ctrl && k == '/') ToggleComment();
            else if (e.Ctrl && k == 'd') DuplicateLine();
            else if (e.Ctrl && shift && k == 'k') DeleteLine();
            else if (!e.Ctrl && !e.Alt && e.Char >= 0x20) TypeChar(e.Char);
            else return false;
            EnsureCursorVisible(r);
            return true;
        }

        // ------------------------------------------------------------------ ratón

        public bool OverScrollbar(float px) => px >= X + W - 10;

        public void MouseDown(Renderer r, float px, float py, int clicks, bool shift)
        {
            Focused = true;
            CaretTime = Environment.TickCount64();
            if (OverScrollbar(px))
            {
                draggingScrollbar = true;
                ScrollToY(r, py);
                return;
            }
            TextPos p = PosFromPoint(r, px, py);
            if (clicks == 2)
            {
                Anchor = WordStart(p);
                Cursor = WordEnd(p);
            }
            else if (clicks >= 3)
            {
                Anchor = new TextPos(p.Line, 0);
                Cursor = p.Line + 1 < Buf.LineCount ? new TextPos(p.Line + 1, 0) : new TextPos(p.Line, Buf.LineLength(p.Line));
            }
            else
            {
                SetCursor(p, shift);
                dragging = true;
            }
            preferredCol = -1;
        }

        void ScrollToY(Renderer r, float py)
        {
            float ratio = (float)((py - Y) / Math.Max(1.0, H));
            ScrollLine = (int)(ratio * Buf.LineCount);
            ClampScroll();
        }

        public bool MouseMove(Renderer r, float px, float py)
        {
            if (draggingScrollbar)
            {
                ScrollToY(r, py);
                return true;
            }
            if (!dragging) return false;
            // Desplazamiento automático al arrastrar fuera del área.
            if (py < Y && ScrollLine > 0) ScrollLine--;
            if (py > Y + H && ScrollLine < Buf.LineCount - 1) ScrollLine++;
            Cursor = PosFromPoint(r, px, (float)Math.Clamp(py, Y, Y + H - 1));
            return true;
        }

        public void MouseUp()
        {
            dragging = false;
            draggingScrollbar = false;
        }

        public void Scroll(int lines)
        {
            ScrollLine += lines;
            ClampScroll();
        }

        // ------------------------------------------------------------------ búsqueda

        // Busca 'text' desde el cursor (con vuelta al principio) y lo selecciona.
        public bool FindNext(string text, Renderer r)
        {
            if (text.Length == 0) return false;
            int lines = Buf.LineCount;
            TextPos from = HasSelection ? SelEnd : Cursor;
            for (int n = 0; n <= lines; n++)
            {
                int line = (from.Line + n) % lines;
                string s = Buf.LineText(line);
                int start = n == 0 ? from.Col : 0;
                int idx = s.IndexOf(text, start);
                if (idx >= 0)
                {
                    Anchor = new TextPos(line, idx);
                    Cursor = new TextPos(line, idx + text.Length);
                    EnsureCursorVisible(r);
                    return true;
                }
            }
            return false;
        }

        public void GoToLine(int line, int col, Renderer r)
        {
            SetCursor(new TextPos(line, col), false);
            // Centrar la línea en la vista.
            int visible = H > 0 ? VisibleLines(r) : 30;
            ScrollLine = Math.Max(0, Cursor.Line - visible / 2);
            EnsureCursorVisible(r);
        }
    }
}
