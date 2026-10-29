// =============================================================================
//  Ventana nativa con Xlib: creación, eventos de teclado/ratón y portapapeles.
//  Los eventos de Xlib (XEvent, 192 bytes) se leen por desplazamientos (Linux 64 bits).
// =============================================================================
using std.text;
using std.os;

namespace FasetStudio.Platform
{
    static extern void* XOpenDisplay(byte* name);
    static extern int XCloseDisplay(void* dpy);
    static extern int XDefaultScreen(void* dpy);
    static extern ulong XRootWindow(void* dpy, int screen);
    static extern ulong XCreateSimpleWindow(void* dpy, ulong parent, int x, int y, uint w, uint h, uint border, ulong borderColor, ulong background);
    static extern int XSelectInput(void* dpy, ulong w, long mask);
    static extern int XMapWindow(void* dpy, ulong w);
    static extern int XStoreName(void* dpy, ulong w, byte* name);
    static extern ulong XInternAtom(void* dpy, byte* name, int onlyIfExists);
    static extern int XSetWMProtocols(void* dpy, ulong w, ulong* atoms, int count);
    static extern int XPending(void* dpy);
    static extern int XNextEvent(void* dpy, void* ev);
    static extern int XConnectionNumber(void* dpy);
    static extern int XLookupString(void* keyEvent, byte* buf, int len, ulong* keysym, void* status);
    static extern int XFlush(void* dpy);
    static extern int XDestroyWindow(void* dpy, ulong w);
    static extern ulong XCreateFontCursor(void* dpy, uint shape);
    static extern int XDefineCursor(void* dpy, ulong w, ulong cursor);
    static extern int XSetSelectionOwner(void* dpy, ulong selection, ulong owner, ulong time);
    static extern ulong XGetSelectionOwner(void* dpy, ulong selection);
    static extern int XConvertSelection(void* dpy, ulong selection, ulong target, ulong property, ulong requestor, ulong time);
    static extern int XChangeProperty(void* dpy, ulong w, ulong property, ulong type, int format, int mode, byte* data, int count);
    static extern int XGetWindowProperty(void* dpy, ulong w, ulong property, long offset, long length, int del, ulong reqType,
                                         ulong* actualType, int* actualFormat, ulong* nitems, ulong* bytesAfter, byte** data);
    static extern int XSendEvent(void* dpy, ulong w, int propagate, long mask, void* ev);
    static extern int XFree(void* data);

    public enum EventKind { None, KeyDown, MouseDown, MouseUp, MouseMove, Scroll, Resize, Close, Expose, FocusLost }

    // Forma del puntero del ratón.
    public enum CursorKind { Arrow, Text, Hand, ResizeHorizontal, ResizeVertical }

    public static class Keys
    {
        public const uint BackSpace = 0xff08;
        public const uint Tab = 0xff09;
        public const uint ShiftTab = 0xfe20;
        public const uint Return = 0xff0d;
        public const uint KeypadEnter = 0xff8d;
        public const uint Escape = 0xff1b;
        public const uint Delete = 0xffff;
        public const uint Home = 0xff50;
        public const uint Left = 0xff51;
        public const uint Up = 0xff52;
        public const uint Right = 0xff53;
        public const uint Down = 0xff54;
        public const uint PageUp = 0xff55;
        public const uint PageDown = 0xff56;
        public const uint End = 0xff57;
        public const uint F1 = 0xffbe;
        public const uint F5 = 0xffc2;
        public const uint F12 = 0xffc9;
    }

    public struct Event
    {
        public EventKind Kind;
        public int X;
        public int Y;
        public int Button;      // 1 izquierdo, 2 central, 3 derecho
        public uint Key;        // keysym (letras en minúscula)
        public char Char;       // carácter escrito (0 si no hay)
        public bool Ctrl;
        public bool Shift;
        public bool Alt;
        public int Width;
        public int Height;
        public int ScrollLines; // positivo = hacia abajo
    }

    public class Window
    {
        void* display;
        ulong window;
        ulong wmDelete;
        ulong atomClipboard;
        ulong atomUtf8;
        ulong atomTargets;
        ulong atomPaste;
        byte* ev;
        int width;
        int height;
        string clipboard;   // copia propia del texto que ofrecemos
        ulong* cursors;          // uno por CursorKind
        CursorKind currentCursor = CursorKind.Text;
        long lastClickMs;
        int clickCount;
        int lastClickX;
        int lastClickY;

        public bool IsOpen;

        public void* Display => display;
        public ulong Handle => window;
        public int Width => width;
        public int Height => height;
        public int ClickCount => clickCount;

        public bool Create(string title, int w, int h)
        {
            display = XOpenDisplay(null);
            if (display == null) return false;
            int screen = XDefaultScreen(display);
            window = XCreateSimpleWindow(display, XRootWindow(display, screen), 0, 0, (uint)w, (uint)h, 0, 0, 0x1e1e1e);
            // Teclado, ratón, movimiento, exposición, cambios de tamaño y foco.
            XSelectInput(display, window, 1 | 4 | 8 | 64 | 32768 | 131072 | 2097152);
            string t = title.ToCString();
            XStoreName(display, window, t.Ptr);
            String.Free(t);
            wmDelete = XInternAtom(display, "WM_DELETE_WINDOW".Ptr, 0);
            XSetWMProtocols(display, window, &wmDelete, 1);
            atomClipboard = XInternAtom(display, "CLIPBOARD".Ptr, 0);
            atomUtf8 = XInternAtom(display, "UTF8_STRING".Ptr, 0);
            atomTargets = XInternAtom(display, "TARGETS".Ptr, 0);
            atomPaste = XInternAtom(display, "FASET_PASTE".Ptr, 0);
            // Cursores de la fuente estándar de X: left_ptr, xterm, hand2, sb_h_double_arrow, sb_v_double_arrow.
            cursors = new ulong[5];
            cursors[0] = XCreateFontCursor(display, 68);
            cursors[1] = XCreateFontCursor(display, 152);
            cursors[2] = XCreateFontCursor(display, 60);
            cursors[3] = XCreateFontCursor(display, 108);
            cursors[4] = XCreateFontCursor(display, 116);
            SetCursor(CursorKind.Arrow);
            XMapWindow(display, window);
            XFlush(display);
            ev = (byte*)Memory.AllocZeroed(192);
            width = w;
            height = h;
            IsOpen = true;
            return true;
        }

        ~Window()
        {
            Memory.Free(ev);
            String.Free(clipboard);
            if (display != null)
            {
                XDestroyWindow(display, window);
                XCloseDisplay(display);
            }
        }

        public void SetTitle(string title)
        {
            // Todas las propiedades del título en UTF-8: XStoreName las marca como Latin-1 y el
            // "—" de "Proyecto — FasetStudio" se veía como letras raras en la barra de título.
            ulong netName = XInternAtom(display, "_NET_WM_NAME".Ptr, 0);
            ulong netIcon = XInternAtom(display, "_NET_WM_ICON_NAME".Ptr, 0);
            XChangeProperty(display, window, netName, atomUtf8, 8, 0, title.Ptr, title.Length);
            XChangeProperty(display, window, netIcon, atomUtf8, 8, 0, title.Ptr, title.Length);
            XChangeProperty(display, window, 39, atomUtf8, 8, 0, title.Ptr, title.Length);   // WM_NAME
            XChangeProperty(display, window, 37, atomUtf8, 8, 0, title.Ptr, title.Length);   // WM_ICON_NAME
            XFlush(display);
        }

        // Icono de la ventana (_NET_WM_ICON): píxeles ARGB de w x h.
        public void SetIcon(uint* argb, int w, int h)
        {
            long count = 2 + (long)w * h;
            ulong* data = (ulong*)Memory.Alloc(count * 8);  // formato 32 de Xlib = 'long' de C
            data[0] = (ulong)w;
            data[1] = (ulong)h;
            for (long i = 0; i < (long)w * h; i++) data[2 + i] = argb[i];
            ulong atom = XInternAtom(display, "_NET_WM_ICON".Ptr, 0);
            XChangeProperty(display, window, atom, 6, 32, 0, (byte*)data, (int)count);  // XA_CARDINAL
            XFlush(display);
            Memory.Free(data);
        }

        // Cambia la forma del puntero (solo si es distinta de la actual).
        public void SetCursor(CursorKind kind)
        {
            if (kind == currentCursor || cursors == null) return;
            currentCursor = kind;
            XDefineCursor(display, window, cursors[(int)kind]);
            XFlush(display);
        }

        static int I32(byte* p, int off) => *(int*)(p + off);
        static uint U32(byte* p, int off) => *(uint*)(p + off);
        static ulong U64(byte* p, int off) => *(ulong*)(p + off);

        // Espera hasta 'ms' milisegundos a que haya eventos.
        public void Wait(int ms)
        {
            if (XPending(display) > 0) return;
            EventWait.WaitFd(XConnectionNumber(display), ms);
        }

        // Devuelve el siguiente evento útil (false si no hay más por ahora).
        public bool Poll(out Event e)
        {
            e = new Event();
            while (XPending(display) > 0)
            {
                XNextEvent(display, ev);
                int type = I32(ev, 0);
                if (type == 2)  // KeyPress
                {
                    uint state = U32(ev, 80);
                    ulong keysym = 0;
                    byte* buf = (byte*)Memory.AllocZeroed(16);
                    int n = XLookupString(ev, buf, 15, &keysym, null);
                    e.Kind = EventKind.KeyDown;
                    e.Key = (uint)keysym;
                    e.Shift = (state & 1) != 0;
                    e.Ctrl = (state & 4) != 0;
                    e.Alt = (state & 8) != 0;
                    if (n == 1 && buf[0] >= 0x20 && buf[0] != 0x7f) e.Char = (char)buf[0];   // Latin-1 = Unicode
                    else if (keysym >= 0x1000100 && keysym < 0x1110000) e.Char = (char)(keysym - 0x1000000);
                    if (e.Key >= 'A' && e.Key <= 'Z') e.Key = e.Key + 32;
                    Memory.Free(buf);
                    return true;
                }
                if (type == 4 || type == 5)  // ButtonPress / ButtonRelease
                {
                    int button = I32(ev, 84);
                    uint state = U32(ev, 80);
                    e.X = I32(ev, 64);
                    e.Y = I32(ev, 68);
                    e.Shift = (state & 1) != 0;
                    e.Ctrl = (state & 4) != 0;
                    if (button == 4 || button == 5)
                    {
                        if (type == 5) continue;
                        e.Kind = EventKind.Scroll;
                        e.ScrollLines = button == 4 ? -3 : 3;
                        return true;
                    }
                    e.Kind = type == 4 ? EventKind.MouseDown : EventKind.MouseUp;
                    e.Button = button == 3 ? 3 : (button == 2 ? 2 : 1);
                    if (type == 4 && button == 1)
                    {
                        long now = Environment.TickCount64();
                        bool near = Math.Abs(e.X - lastClickX) < 4 && Math.Abs(e.Y - lastClickY) < 4;
                        clickCount = now - lastClickMs < 400 && near ? clickCount + 1 : 1;
                        lastClickMs = now;
                        lastClickX = e.X;
                        lastClickY = e.Y;
                    }
                    return true;
                }
                if (type == 6)  // MotionNotify
                {
                    // Solo interesa el último movimiento pendiente.
                    e.Kind = EventKind.MouseMove;
                    e.X = I32(ev, 64);
                    e.Y = I32(ev, 68);
                    e.Button = (U32(ev, 80) & 256) != 0 ? 1 : 0;
                    return true;
                }
                if (type == 22)  // ConfigureNotify
                {
                    int w = I32(ev, 56), h = I32(ev, 60);
                    if (w == width && h == height) continue;
                    width = w;
                    height = h;
                    e.Kind = EventKind.Resize;
                    e.Width = w;
                    e.Height = h;
                    return true;
                }
                if (type == 12)  // Expose
                {
                    e.Kind = EventKind.Expose;
                    return true;
                }
                if (type == 10)  // FocusOut
                {
                    e.Kind = EventKind.FocusLost;
                    return true;
                }
                if (type == 33 && U64(ev, 56) == wmDelete)  // ClientMessage: cerrar
                {
                    e.Kind = EventKind.Close;
                    IsOpen = false;
                    return true;
                }
                if (type == 30) AnswerSelectionRequest();
            }
            return false;
        }

        // ---------------------------------------------------------- portapapeles

        public void SetClipboard(string text)
        {
            String.Free(clipboard);
            clipboard = String.Copy(text);
            XSetSelectionOwner(display, atomClipboard, window, 0);
            XFlush(display);
        }

        // Texto del portapapeles del sistema (copia: libérala con String.Free).
        public string GetClipboard()
        {
            if (XGetSelectionOwner(display, atomClipboard) == window) return String.Copy(clipboard);
            XConvertSelection(display, atomClipboard, atomUtf8, atomPaste, window, 0);
            XFlush(display);
            long deadline = Environment.TickCount64() + 300;
            while (Environment.TickCount64() < deadline)
            {
                if (XPending(display) == 0)
                {
                    EventWait.WaitFd(XConnectionNumber(display), 10);
                    continue;
                }
                XNextEvent(display, ev);
                int type = I32(ev, 0);
                if (type == 30)
                {
                    AnswerSelectionRequest();
                    continue;
                }
                if (type != 31) continue;  // SelectionNotify
                if (U64(ev, 56) == 0) break;  // sin datos
                ulong actualType = 0, nitems = 0, after = 0;
                int format = 0;
                byte* data = null;
                XGetWindowProperty(display, window, atomPaste, 0, 1 << 24, 1, 0, &actualType, &format, &nitems, &after, &data);
                string r = String.Copy(String.FromBytes(data, (long)nitems));
                if (data != null) XFree(data);
                return r;
            }
            return String.Copy("");
        }

        void AnswerSelectionRequest()
        {
            ulong requestor = U64(ev, 40);
            ulong selection = U64(ev, 48);
            ulong target = U64(ev, 56);
            ulong property = U64(ev, 64);
            ulong time = U64(ev, 72);
            if (property == 0) property = target;
            ulong result = property;
            if (target == atomTargets)
            {
                ulong* atoms = (ulong*)Memory.Alloc(16);
                atoms[0] = atomUtf8;
                atoms[1] = 31;  // XA_STRING
                XChangeProperty(display, requestor, property, 4, 32, 0, (byte*)atoms, 2);  // XA_ATOM
                Memory.Free(atoms);
            }
            else if (target == atomUtf8 || target == 31)
            {
                XChangeProperty(display, requestor, property, target, 8, 0, clipboard.Ptr, clipboard.Length);
            }
            else
            {
                result = 0;
            }
            byte* reply = (byte*)Memory.AllocZeroed(192);
            *(int*)reply = 31;  // SelectionNotify
            *(int*)(reply + 16) = 1;
            *(void**)(reply + 24) = display;
            *(ulong*)(reply + 32) = requestor;
            *(ulong*)(reply + 40) = selection;
            *(ulong*)(reply + 48) = target;
            *(ulong*)(reply + 56) = result;
            *(ulong*)(reply + 64) = time;
            XSendEvent(display, requestor, 0, 0, reply);
            XFlush(display);
            Memory.Free(reply);
        }
    }
}
