// =============================================================================
//  Ventana nativa con Win32: creación, eventos de teclado/ratón, portapapeles,
//  cursores, título UTF-8, icono y escalado por monitor (DPI).
//  Misma API que X11.fst; las teclas se traducen a los keysym de X11 (Events.fst).
//  Las estructuras de Win32 se leen por desplazamientos (Windows de 64 bits).
// =============================================================================
#if WINDOWS
using std.text;
using std.os;
using std.collections;

namespace FasetStudio.Platform
{
    public memory_unsafe static class User32
    {
        public static extern void* GetModuleHandleW(ushort* name);
        public static extern ushort RegisterClassExW(byte* wc);
        public static extern void* CreateWindowExW(uint exStyle, ushort* cls, ushort* title, uint style, int x, int y, int w, int h,
                                                   void* parent, void* menu, void* instance, void* param);
        public static extern long DefWindowProcW(void* hwnd, uint msg, ulong wp, long lp);
        public static extern int ShowWindow(void* hwnd, int cmd);
        public static extern int UpdateWindow(void* hwnd);
        public static extern int DestroyWindow(void* hwnd);
        public static extern int PeekMessageW(byte* msg, void* hwnd, uint min, uint max, uint remove);
        public static extern int TranslateMessage(byte* msg);
        public static extern long DispatchMessageW(byte* msg);
        public static extern void* LoadCursorW(void* instance, void* name);
        public static extern void* SetCursor(void* cursor);
        public static extern int SetWindowTextW(void* hwnd, ushort* text);
        public static extern int AdjustWindowRectEx(int* rect, uint style, int menu, uint exStyle);
        public static extern void* BeginPaint(void* hwnd, byte* ps);
        public static extern int EndPaint(void* hwnd, byte* ps);
        public static extern void* SetCapture(void* hwnd);
        public static extern int ReleaseCapture();
        public static extern short GetKeyState(int key);
        public static extern uint MapVirtualKeyW(uint code, uint mapType);
        public static extern uint GetDoubleClickTime();
        public static extern int ScreenToClient(void* hwnd, int* point);
        public static extern int SetWindowPos(void* hwnd, void* after, int x, int y, int w, int h, uint flags);
        public static extern long SendMessageW(void* hwnd, uint msg, ulong wp, long lp);
        public static extern int GetClientRect(void* hwnd, int* rect);
        public static extern void* GetDC(void* hwnd);
        public static extern int ReleaseDC(void* hwnd, void* dc);
        public static extern void* CreateIconIndirect(byte* info);
        public static extern int SetProcessDPIAware();
        public static extern int MessageBoxW(void* hwnd, ushort* text, ushort* caption, uint type);
        public static extern int OpenClipboard(void* hwnd);
        public static extern int CloseClipboard();
        public static extern int EmptyClipboard();
        public static extern void* GetClipboardData(uint format);
        public static extern void* SetClipboardData(uint format, void* mem);
        public static extern void* GlobalAlloc(uint flags, ulong bytes);
        public static extern void* GlobalLock(void* mem);
        public static extern int GlobalUnlock(void* mem);
        public static extern void* GlobalFree(void* mem);
        public static extern void* LoadLibraryW(ushort* name);
        public static extern void* GetProcAddress(void* module, byte* name);
        public static extern void* CreateDIBSection(void* dc, byte* info, uint usage, void** bits, void* section, uint offset);
        public static extern void* CreateBitmap(int w, int h, uint planes, uint bitCount, void* bits);
        public static extern int DeleteObject(void* obj);
    }

    // Espera mensajes de la ventana o el despertar de otro hilo (runtime de Faset, RuntimeAsync.cpp).
    static extern void faset_loop_wait_msgs(int ms);

    public memory_unsafe class Window
    {
        static var current: Window;   // la ventana a la que llegan los mensajes (solo hay una)

        var hwnd: void*;
        var msg: byte*;               // MSG (48 bytes)
        var peek: byte*;              // MSG auxiliar para recoger WM_CHAR
        var width: int;
        var height: int;
        var minimized: bool;
        var style: uint;
        var cursors: void**;          // uno por CursorKind
        var currentCursor: CursorKind = CursorKind.Text;
        var icon: void*;
        var queue: List<Event> = new List<Event>();
        var lastClickMs: long;
        var clickCount: int;
        var lastClickX: int;
        var lastClickY: int;
        var wheelAccum: int;          // restos de la rueda (ratones de alta resolución)
        var buttonsDown: int;         // botones pulsados (para SetCapture / ReleaseCapture)
        var pendingHigh: uint;        // primera mitad de un par suplente UTF-16 a la espera de la segunda

        public var IsOpen: bool;

        public prop Display: void* => null;
        public prop Hwnd: void* => hwnd;
        public prop Width: int => width;
        public prop Height: int => height;
        public prop ClickCount: int => clickCount;

        public func Create(title: string, w: int, h: int) -> bool
        {
            current = this;
            EnableDpiAwareness();
            void* instance = User32.GetModuleHandleW(null);
            ushort* cls = Utf16.Encode("FasetStudioWindow");
            byte* wc = (byte*)Memory.AllocZeroed(80);   // WNDCLASSEXW
            *(uint*)wc = 80;
            *(delegate*<void*, uint, ulong, long, long>*)(wc + 8) = &WndProc;
            *(void**)(wc + 24) = instance;
            *(void**)(wc + 40) = User32.LoadCursorW(null, (void*)32512);
            *(ushort**)(wc + 64) = cls;
            User32.RegisterClassExW(wc);
            Memory.Free(wc);
            // IDC_ARROW, IDC_IBEAM, IDC_HAND, IDC_SIZEWE, IDC_SIZENS (mismo orden que CursorKind).
            cursors = (void**)Memory.AllocZeroed(5 * 8);
            cursors[0] = User32.LoadCursorW(null, (void*)32512);
            cursors[1] = User32.LoadCursorW(null, (void*)32513);
            cursors[2] = User32.LoadCursorW(null, (void*)32649);
            cursors[3] = User32.LoadCursorW(null, (void*)32644);
            cursors[4] = User32.LoadCursorW(null, (void*)32645);
            style = 0x00CF0000;  // WS_OVERLAPPEDWINDOW
            int* rect = (int*)Memory.AllocZeroed(16);
            rect[2] = w;
            rect[3] = h;
            User32.AdjustWindowRectEx(rect, style, 0, 0);
            ushort* t = Utf16.Encode(title);
            hwnd = User32.CreateWindowExW(0, cls, t, style, (int)0x80000000, (int)0x80000000, rect[2] - rect[0], rect[3] - rect[1],
                                          null, null, instance, null);
            Memory.Free(t);
            Memory.Free(cls);
            Memory.Free(rect);
            if (hwnd == null) return false;
            msg = (byte*)Memory.AllocZeroed(48);
            peek = (byte*)Memory.AllocZeroed(48);
            width = w;
            height = h;
            SetCursor(CursorKind.Arrow);
            User32.ShowWindow(hwnd, 5);   // SW_SHOW
            User32.UpdateWindow(hwnd);
            // Tamaño real del área de cliente (puede ser menor que el pedido si no cabe en la pantalla).
            int* cr = (int*)Memory.AllocZeroed(16);
            if (User32.GetClientRect(hwnd, cr) != 0 && cr[2] > 0 && cr[3] > 0)
            {
                width = cr[2];
                height = cr[3];
            }
            Memory.Free(cr);
            IsOpen = true;
            return true;
        }

        deinit
        {
            if (hwnd != null) User32.DestroyWindow(hwnd);
            if (icon != null) User32.DeleteObject(icon);
            Memory.Free(msg);
            Memory.Free(peek);
            Memory.Free(cursors);
            delete queue;
            if (current == this) current = null;
        }

        // Escalado por monitor: la ventana trabaja en píxeles reales (sin el estirado borroso de
        // Windows). SetProcessDpiAwarenessContext existe desde Windows 10 1703; si no, el modo de sistema.
        static func EnableDpiAwareness()
        {
            ushort* name = Utf16.Encode("user32.dll");
            void* user32 = User32.LoadLibraryW(name);
            Memory.Free(name);
            void* fn = user32 != null ? User32.GetProcAddress(user32, "SetProcessDpiAwarenessContext".Ptr) : null;
            if (fn != null)
            {
                delegate*<long, int> setContext = (delegate*<long, int>)fn;
                if (setContext(-4) != 0) return;   // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
                if (setContext(-3) != 0) return;   // PER_MONITOR_AWARE
            }
            User32.SetProcessDPIAware();
        }

        // Muestra un error fatal en un cuadro de diálogo (una aplicación de ventana no tiene consola).
        public static func ShowError(message: string)
        {
            ushort* text = Utf16.Encode(message);
            ushort* caption = Utf16.Encode("FasetStudio");
            User32.MessageBoxW(null, text, caption, 0x10);   // MB_OK | MB_ICONERROR
            Memory.Free(text);
            Memory.Free(caption);
        }

        public func SetTitle(title: string)
        {
            ushort* t = Utf16.Encode(title);
            User32.SetWindowTextW(hwnd, t);
            Memory.Free(t);
        }

        // Icono de la ventana: píxeles ARGB de w x h (en memoria, BGRA: el formato de un DIB de 32 bits).
        public func SetIcon(argb: uint*, w: int, h: int)
        {
            byte* bmi = (byte*)Memory.AllocZeroed(124);   // BITMAPV5HEADER
            *(uint*)bmi = 124;
            *(int*)(bmi + 4) = w;
            *(int*)(bmi + 8) = -h;                       // de arriba abajo
            *(ushort*)(bmi + 12) = 1;
            *(ushort*)(bmi + 14) = 32;
            *(uint*)(bmi + 16) = 3;                      // BI_BITFIELDS
            *(uint*)(bmi + 40) = 0x00FF0000;
            *(uint*)(bmi + 44) = 0x0000FF00;
            *(uint*)(bmi + 48) = 0x000000FF;
            *(uint*)(bmi + 52) = 0xFF000000;
            void* dc = User32.GetDC(null);
            void* bits = null;
            void* color = User32.CreateDIBSection(dc, bmi, 0, &bits, null, 0);
            User32.ReleaseDC(null, dc);
            Memory.Free(bmi);
            if (color == null || bits == null) return;
            uint* dst = (uint*)bits;
            for (long i = 0; i < (long)w * h; i++) dst[i] = argb[i];
            void* mask = User32.CreateBitmap(w, h, 1, 1, null);
            byte* info = (byte*)Memory.AllocZeroed(32);  // ICONINFO
            *(int*)info = 1;                             // fIcon
            *(void**)(info + 16) = mask;
            *(void**)(info + 24) = color;
            void* hicon = User32.CreateIconIndirect(info);
            Memory.Free(info);
            User32.DeleteObject(mask);
            User32.DeleteObject(color);
            if (hicon == null) return;
            User32.SendMessageW(hwnd, 0x0080, 1, (long)hicon);   // WM_SETICON, ICON_BIG
            User32.SendMessageW(hwnd, 0x0080, 0, (long)hicon);   // ICON_SMALL
            icon = hicon;
        }

        // Cambia la forma del puntero (solo si es distinta de la actual).
        public func SetCursor(kind: CursorKind)
        {
            if (kind == currentCursor || cursors == null) return;
            currentCursor = kind;
            User32.SetCursor(cursors[(int)kind]);
        }

        // Espera hasta 'ms' milisegundos a que haya mensajes (o a que otro hilo despierte el bucle).
        public func Wait(ms: int)
        {
            if (queue.Count > 0) return;
            if (User32.PeekMessageW(msg, null, 0, 0, 0) != 0) return;   // PM_NOREMOVE
            faset_loop_wait_msgs(ms < 0 ? 0x7fffffff : ms);
        }

        // Devuelve el siguiente evento útil (false si no hay más por ahora).
        public func Poll(out e: Event) -> bool
        {
            while (queue.Count == 0 && User32.PeekMessageW(msg, null, 0, 0, 1) != 0)   // PM_REMOVE
            {
                uint m = *(uint*)(msg + 8);
                if (m == 0x0100 || m == 0x0104) KeyDown(m == 0x0104);   // WM_KEYDOWN / WM_SYSKEYDOWN
                else
                {
                    User32.TranslateMessage(msg);
                    User32.DispatchMessageW(msg);
                }
            }
            if (queue.Count == 0)
            {
                e = new Event();
                return false;
            }
            e = queue[0];
            queue.RemoveAt(0);
            return true;
        }

        // ---------------------------------------------------------- teclado

        static func Down(vk: int) -> bool => User32.GetKeyState(vk) < 0;

        // Tecla virtual sin carácter -> keysym de X11 (0 si escribe un carácter).
        static func SpecialKey(vk: uint, extended: bool) -> uint
        {
            if (vk == 0x08) return Keys.BackSpace;
            if (vk == 0x09) return Keys.Tab;
            if (vk == 0x0D) return extended ? Keys.KeypadEnter : Keys.Return;
            if (vk == 0x1B) return Keys.Escape;
            if (vk == 0x2E) return Keys.Delete;
            if (vk == 0x24) return Keys.Home;
            if (vk == 0x25) return Keys.Left;
            if (vk == 0x26) return Keys.Up;
            if (vk == 0x27) return Keys.Right;
            if (vk == 0x28) return Keys.Down;
            if (vk == 0x21) return Keys.PageUp;
            if (vk == 0x22) return Keys.PageDown;
            if (vk == 0x23) return Keys.End;
            if (vk == 0x2D) return 0xff63;                       // Insert
            if (vk >= 0x70 && vk <= 0x7B) return 0xffbe + (vk - 0x70);   // F1..F12
            return 0;
        }

        static func IsModifier(vk: uint) -> bool =>
            vk == 0x10 || vk == 0x11 || vk == 0x12 || vk == 0x14 || vk == 0x5B || vk == 0x5C || vk == 0x5D ||
            vk == 0x90 || vk == 0x91 || (vk >= 0xA0 && vk <= 0xA5);

        // WM_KEYDOWN / WM_SYSKEYDOWN: un único evento con la tecla y el carácter que escribe
        // (como XLookupString). Se gestiona aquí, sin DispatchMessage, para que Alt y F10 no
        // activen el menú del sistema.
        func KeyDown(sys: bool)
        {
            uint vk = (uint)*(ulong*)(msg + 16);
            long lp = *(long*)(msg + 24);
            if (sys && vk == 0x73 && Down(0x12))   // Alt+F4: cierre normal de Windows
            {
                User32.DispatchMessageW(msg);
                return;
            }
            if (IsModifier(vk)) return;
            Event e = new Event();
            e.Kind = EventKind.KeyDown;
            e.Shift = Down(0x10);
            e.Ctrl = Down(0x11);
            e.Alt = Down(0x12);
            uint special = SpecialKey(vk, (lp & 0x01000000) != 0);
            if (special != 0)
            {
                e.Key = special;
                queue.Add(e);
                return;
            }
            // Tecla de carácter: TranslateMessage deja en la cola el WM_CHAR (o WM_DEADCHAR) que produce.
            User32.TranslateMessage(msg);
            uint ch = 0;
            bool dead = false;
            if (User32.PeekMessageW(peek, hwnd, 0x0102, 0x0103, 1) != 0 || User32.PeekMessageW(peek, hwnd, 0x0106, 0x0107, 1) != 0)
            {
                uint pm = *(uint*)(peek + 8);
                dead = pm == 0x0103 || pm == 0x0107;   // tecla muerta (acentos): el carácter llega con la siguiente
                ch = (uint)*(ulong*)(peek + 16);
                if (ch >= 0xD800 && ch < 0xDC00 && User32.PeekMessageW(peek, hwnd, 0x0102, 0x0102, 1) != 0)
                {
                    uint low = (uint)*(ulong*)(peek + 16);
                    if (low >= 0xDC00 && low < 0xE000) ch = 0x10000 + ((ch - 0xD800) << 10) + (low - 0xDC00);
                }
            }
            if (dead) return;
            // Carácter fuera del plano básico en dos mensajes (SendInput, IME): se junta el par suplente.
            if (ch >= 0xD800 && ch < 0xDC00)
            {
                pendingHigh = ch;
                return;
            }
            if (ch >= 0xDC00 && ch < 0xE000)
            {
                if (pendingHigh == 0) return;
                ch = 0x10000 + ((pendingHigh - 0xD800) << 10) + (ch - 0xDC00);
            }
            pendingHigh = 0;
            bool printable = ch >= 0x20 && ch != 0x7f && (ch < 0xD800 || ch >= 0xE000);
            // AltGr llega como Ctrl+Alt: si escribe un carácter ('@', '#', '\'...) no es un atajo.
            if (printable && e.Ctrl && e.Alt)
            {
                e.Ctrl = false;
                e.Alt = false;
            }
            uint key;
            if (vk >= 'A' && vk <= 'Z') key = vk + 32;
            else if (printable && !e.Ctrl && !e.Alt) key = ch;
            else key = User32.MapVirtualKeyW(vk, 2) & 0x7fffffff;   // MAPVK_VK_TO_CHAR: carácter base de la tecla
            if (key >= 'A' && key <= 'Z') key = key + 32;
            e.Key = key;
            if (printable) e.Char = (char)ch;
            queue.Add(e);
        }

        // ---------------------------------------------------------- mensajes

        static func LoWord(lp: long) -> int => (int)(short)(lp & 0xffff);
        static func HiWord(lp: long) -> int => (int)(short)((lp >> 16) & 0xffff);

        func MouseButton(m: uint, wp: ulong, lp: long)
        {
            // WM_LBUTTONDOWN/UP 0x201/0x202, WM_RBUTTONDOWN/UP 0x204/0x205, WM_MBUTTONDOWN/UP 0x207/0x208.
            bool down = m == 0x0201 || m == 0x0204 || m == 0x0207;
            int button = m <= 0x0202 ? 1 : (m <= 0x0205 ? 3 : 2);
            Event e = new Event();
            e.Kind = down ? EventKind.MouseDown : EventKind.MouseUp;
            e.Button = button;
            e.X = LoWord(lp);
            e.Y = HiWord(lp);
            e.Shift = (wp & 4) != 0;
            e.Ctrl = (wp & 8) != 0;
            if (down)
            {
                if (buttonsDown == 0) User32.SetCapture(hwnd);
                buttonsDown |= 1 << button;
            }
            else
            {
                buttonsDown &= ~(1 << button);
                if (buttonsDown == 0) User32.ReleaseCapture();
            }
            if (down && button == 1)
            {
                long now = Environment.TickCount64();
                bool near = Math.Abs(e.X - lastClickX) < 4 && Math.Abs(e.Y - lastClickY) < 4;
                clickCount = now - lastClickMs < (long)User32.GetDoubleClickTime() && near ? clickCount + 1 : 1;
                lastClickMs = now;
                lastClickX = e.X;
                lastClickY = e.Y;
            }
            queue.Add(e);
        }

        static func WndProc(hwnd: void*, m: uint, wp: ulong, lp: long) -> long
        {
            Window w = current;
            if (w == null || (w.hwnd != null && w.hwnd != hwnd)) return User32.DefWindowProcW(hwnd, m, wp, lp);
            Event e = new Event();
            switch (m)
            {
                case 0x0010:  // WM_CLOSE: la aplicación decide (puede preguntar por los cambios sin guardar)
                    e.Kind = EventKind.Close;
                    w.IsOpen = false;
                    w.queue.Add(e);
                    return 0;
                case 0x0005:  // WM_SIZE
                {
                    if (wp == 1)   // SIZE_MINIMIZED: la cadena de intercambio se rehace al restaurar
                    {
                        w.minimized = true;
                        return 0;
                    }
                    int nw = LoWord(lp) & 0xffff, nh = HiWord(lp) & 0xffff;
                    if (nw <= 0 || nh <= 0) return 0;
                    if (nw == w.width && nh == w.height && !w.minimized) return 0;
                    w.minimized = false;
                    w.width = nw;
                    w.height = nh;
                    e.Kind = EventKind.Resize;
                    e.Width = nw;
                    e.Height = nh;
                    w.queue.Add(e);
                    return 0;
                }
                case 0x0014:  // WM_ERASEBKGND: lo pinta Vulkan
                    return 1;
                case 0x000F:  // WM_PAINT
                {
                    byte* ps = (byte*)Memory.AllocZeroed(72);
                    User32.BeginPaint(hwnd, ps);
                    User32.EndPaint(hwnd, ps);
                    Memory.Free(ps);
                    e.Kind = EventKind.Expose;
                    w.queue.Add(e);
                    return 0;
                }
                case 0x0020:  // WM_SETCURSOR
                    if ((lp & 0xffff) == 1 && w.cursors != null)   // HTCLIENT
                    {
                        User32.SetCursor(w.cursors[(int)w.currentCursor]);
                        return 1;
                    }
                    break;
                case 0x0200:  // WM_MOUSEMOVE
                    e.Kind = EventKind.MouseMove;
                    e.X = LoWord(lp);
                    e.Y = HiWord(lp);
                    e.Button = (wp & 1) != 0 ? 1 : 0;
                    w.queue.Add(e);
                    return 0;
                case 0x0201:
                case 0x0202:
                case 0x0204:
                case 0x0205:
                case 0x0207:
                case 0x0208:
                    w.MouseButton(m, wp, lp);
                    return 0;
                case 0x0215:  // WM_CAPTURECHANGED: otra ventana se quedó el ratón
                    w.buttonsDown = 0;
                    break;
                case 0x020A:  // WM_MOUSEWHEEL: 120 = una muesca = 3 líneas (como en X11)
                {
                    w.wheelAccum += (int)(short)((wp >> 16) & 0xffff);
                    int lines = w.wheelAccum / 40;
                    if (lines == 0) return 0;
                    w.wheelAccum -= lines * 40;
                    int* pt = (int*)Memory.AllocZeroed(8);
                    pt[0] = LoWord(lp);
                    pt[1] = HiWord(lp);
                    User32.ScreenToClient(hwnd, pt);   // la rueda llega en coordenadas de pantalla
                    e.Kind = EventKind.Scroll;
                    e.X = pt[0];
                    e.Y = pt[1];
                    Memory.Free(pt);
                    e.ScrollLines = -lines;
                    e.Shift = (wp & 4) != 0;
                    e.Ctrl = (wp & 8) != 0;
                    w.queue.Add(e);
                    return 0;
                }
                case 0x0102:  // WM_CHAR sin WM_KEYDOWN previo (IME...)
                {
                    uint ch = (uint)wp;
                    if (ch >= 0xD800 && ch < 0xDC00)
                    {
                        w.pendingHigh = ch;
                        return 0;
                    }
                    if (ch >= 0xDC00 && ch < 0xE000)
                    {
                        if (w.pendingHigh == 0) return 0;
                        ch = 0x10000 + ((w.pendingHigh - 0xD800) << 10) + (ch - 0xDC00);
                    }
                    w.pendingHigh = 0;
                    if (ch >= 0x20 && ch != 0x7f)
                    {
                        e.Kind = EventKind.KeyDown;
                        e.Char = (char)ch;
                        e.Key = ch;
                        w.queue.Add(e);
                    }
                    return 0;
                }
                case 0x0105:  // WM_SYSKEYUP: sin activar el menú con Alt o F10
                case 0x0106:  // WM_SYSCHAR: sin el pitido de "atajo desconocido"
                    return 0;
                case 0x0112:  // WM_SYSCOMMAND
                    if ((wp & 0xFFF0) == 0xF100 && lp == 0) return 0;   // SC_KEYMENU por Alt suelta
                    break;
                case 0x0008:  // WM_KILLFOCUS
                    e.Kind = EventKind.FocusLost;
                    w.queue.Add(e);
                    w.buttonsDown = 0;
                    break;
                case 0x02E0:  // WM_DPICHANGED: tamaño propuesto por Windows para el nuevo monitor
                {
                    int* r = (int*)lp;
                    User32.SetWindowPos(hwnd, null, r[0], r[1], r[2] - r[0], r[3] - r[1], 0x0014);   // SWP_NOZORDER | SWP_NOACTIVATE
                    return 0;
                }
            }
            return User32.DefWindowProcW(hwnd, m, wp, lp);
        }

        // ---------------------------------------------------------- portapapeles (CF_UNICODETEXT)

        public func SetClipboard(text: string)
        {
            if (User32.OpenClipboard(hwnd) == 0) return;
            User32.EmptyClipboard();
            // Saltos de línea de Windows (\r\n) para el resto de programas.
            string crlf = Text.Replace(text, "\n", "\r\n");
            int n;
            ushort* w = Utf16.Encode(crlf, out n);
            String.Free(crlf);
            void* mem = User32.GlobalAlloc(2, (ulong)(n + 1) * 2);   // GMEM_MOVEABLE
            ushort* dst = mem != null ? (ushort*)User32.GlobalLock(mem) : null;
            if (dst != null)
            {
                for (int i = 0; i <= n; i++) dst[i] = w[i];
                User32.GlobalUnlock(mem);
                if (User32.SetClipboardData(13, mem) == null) User32.GlobalFree(mem);   // si falla, la memoria sigue siendo nuestra
            }
            else if (mem != null) User32.GlobalFree(mem);
            Memory.Free(w);
            User32.CloseClipboard();
        }

        // Texto del portapapeles del sistema (copia: libérala con String.Free).
        public func GetClipboard() -> string
        {
            if (User32.OpenClipboard(hwnd) == 0) return String.Copy("");
            string r = String.Copy("");
            void* mem = User32.GetClipboardData(13);
            ushort* src = mem != null ? (ushort*)User32.GlobalLock(mem) : null;
            if (src != null)
            {
                string s = Utf16.Decode(src);
                User32.GlobalUnlock(mem);
                String.Free(r);
                r = Text.Replace(s, "\r\n", "\n");
                String.Free(s);
            }
            User32.CloseClipboard();
            return r;
        }
    }
}
#endif
