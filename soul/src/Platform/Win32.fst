// =============================================================================
//  Soul - Win32 platform layer.
//
//  Native window and input via user32/gdi32/kernel32, declared through Faset's
//  C FFI. Exposes the HWND and HINSTANCE that the Vulkan surface needs.
// =============================================================================
using std;

namespace Soul.Platform
{
    // -------------------------------------------------------------------------
    //  Raw Win32 bindings.
    // -------------------------------------------------------------------------
    public memory_unsafe static class Win32
    {
        public const uint CS_VREDRAW = 0x0001;
        public const uint CS_HREDRAW = 0x0002;

        public const uint WS_OVERLAPPEDWINDOW = 0x00CF0000;
        public const uint WS_VISIBLE          = 0x10000000;

        public const int  SW_SHOW = 5;

        public const uint WM_DESTROY = 0x0002;
        public const uint WM_CLOSE   = 0x0010;
        public const uint WM_QUIT    = 0x0012;
        public const uint WM_KEYDOWN = 0x0100;

        public const uint VK_ESCAPE = 0x1B;
        public const int VK_LBUTTON = 0x01;
        public const int VK_RBUTTON = 0x02;
        public const int VK_1 = 0x31;
        public const int VK_2 = 0x32;
        public const int VK_3 = 0x33;
        public const int VK_4 = 0x34;

        // movement keys (virtual-key codes)
        public const int VK_W = 0x57;
        public const int VK_A = 0x41;
        public const int VK_S = 0x53;
        public const int VK_D = 0x44;
        public const int VK_SPACE = 0x20;
        public const int VK_SHIFT = 0x10;

        public const int  BLACK_BRUSH = 4;

        public const uint PM_REMOVE = 0x0001;

        public static extern void* GetModuleHandleA(byte* moduleName);
        public static extern uint  GetModuleFileNameA(void* module, byte* buffer, uint size);

        public static extern ushort RegisterClassExA(void* wndClass);
        public static extern void*  CreateWindowExA(uint exStyle, byte* className, byte* windowName,
                                                    uint style, int x, int y, int width, int height,
                                                    void* parent, void* menu, void* instance, void* param);
        public static extern int    ShowWindow(void* hwnd, int cmdShow);
        public static extern int    UpdateWindow(void* hwnd);
        public static extern int    DestroyWindow(void* hwnd);
        public static extern int    PeekMessageA(void* msg, void* hwnd, uint filterMin, uint filterMax, uint remove);
        public static extern int    TranslateMessage(void* msg);
        public static extern long   DispatchMessageA(void* msg);
        public static extern void   PostQuitMessage(int exitCode);
        public static extern long   DefWindowProcA(void* hwnd, uint msg, ulong wParam, long lParam);

        public static extern void*  GetStockObject(int obj);

        // input
        public static extern short GetAsyncKeyState(int vKey);
        public static extern int   GetCursorPos(void* point);     // POINT { int x, y }
        public static extern int   SetCursorPos(int x, int y);
        public static extern int   ShowCursor(int show);
        public static extern int   GetWindowRect(void* hwnd, void* rect);  // RECT { int l,t,r,b }
    }

    // Keyboard polling (held-down state from the async key table).
    public memory_unsafe static class Input
    {
        public static func IsKeyDown(vk: int) -> bool => ((int)Win32.GetAsyncKeyState(vk) & 0x8000) != 0;
    }

    // Win32 MSG record (x86-64 layout, 48 bytes).
    public memory_unsafe struct MSG
    {
        var hwnd: void*
        var message: uint
        var wParam: ulong
        var lParam: long
        var time: uint
        var pt_x: int
        var pt_y: int
        var lPrivate: uint
    }
}

// The window procedure must be a free function so its address can be taken as a
// C callback. On x86-64 this maps directly to LRESULT CALLBACK(HWND,UINT,WPARAM,LPARAM).
memory_unsafe func SoulWndProc(hwnd: void*, msg: uint, wParam: ulong, lParam: long) -> long
{
    if (msg == Soul.Platform.Win32.WM_DESTROY)
    {
        Soul.Platform.Win32.PostQuitMessage(0);
        return 0;
    }
    if (msg == Soul.Platform.Win32.WM_CLOSE)
    {
        Soul.Platform.Win32.DestroyWindow(hwnd);
        return 0;
    }
    if (msg == Soul.Platform.Win32.WM_KEYDOWN && wParam == Soul.Platform.Win32.VK_ESCAPE)
    {
        Soul.Platform.Win32.DestroyWindow(hwnd);
        return 0;
    }
    return Soul.Platform.Win32.DefWindowProcA(hwnd, msg, wParam, lParam);
}

namespace Soul.Platform
{
    // -------------------------------------------------------------------------
    //  A single top-level window with a non-blocking message pump (game loop).
    // -------------------------------------------------------------------------
    public memory_unsafe class Window
    {
        public var Hwnd: void*
        public var Hinstance: void*
        public var ShouldClose: bool
        public var MouseDX: int
        public var MouseDY: int
        var msgBuf: void*
        var mouseLook: bool

        public init(title: string, width: int, height: int)
        {
            ShouldClose = false;
            msgBuf = Memory.Alloc(48);
            Hinstance = Win32.GetModuleHandleA(null);

            let className = "SoulWindow";

            // WNDCLASSEXA at exact field offsets (x86-64, 80 bytes).
            byte* wc = (byte*)Memory.Alloc(80);
            for (int i = 0; i < 80; i++) wc[i] = 0;
            *(uint*)(wc + 0)   = 80u;
            *(uint*)(wc + 4)   = Win32.CS_HREDRAW | Win32.CS_VREDRAW;
            *(void**)(wc + 8)  = (void*)&SoulWndProc;
            *(void**)(wc + 24) = Hinstance;
            *(void**)(wc + 48) = Win32.GetStockObject(Win32.BLACK_BRUSH);
            *(void**)(wc + 64) = className.Ptr;

            if (Win32.RegisterClassExA((void*)wc) == 0)
                panic("Window: RegisterClassExA failed");

            Hwnd = Win32.CreateWindowExA(
                0u, className.Ptr, title.Ptr,
                Win32.WS_OVERLAPPEDWINDOW | Win32.WS_VISIBLE,
                100, 100, width, height,
                null, null, Hinstance, null);

            if (Hwnd == null)
                panic("Window: CreateWindowExA failed");

            Win32.ShowWindow(Hwnd, Win32.SW_SHOW);
            Win32.UpdateWindow(Hwnd);
            Memory.Free((void*)wc);

            MouseDX = 0; MouseDY = 0;
            mouseLook = false;
        }

        // Center of the window in screen coordinates.
        func WindowCenter(cx: int*, cy: int*)
        {
            int* rect = (int*)Memory.Alloc(16);
            Win32.GetWindowRect(Hwnd, (void*)rect);
            *cx = (rect[0] + rect[2]) / 2;
            *cy = (rect[1] + rect[3]) / 2;
            Memory.Free((void*)rect);
        }

        // Hide the cursor and capture it for mouse-look. Idempotent.
        public func EnableMouseLook()
        {
            if (mouseLook) return;
            mouseLook = true;
            Win32.ShowCursor(0);
            int cx; int cy;
            WindowCenter(&cx, &cy);
            Win32.SetCursorPos(cx, cy);
            MouseDX = 0; MouseDY = 0;
        }

        // Read the mouse movement since the last call, then recenter the cursor.
        public func UpdateMouse()
        {
            if (!mouseLook) { MouseDX = 0; MouseDY = 0; return; }
            int cx; int cy;
            WindowCenter(&cx, &cy);

            int* pt = (int*)Memory.Alloc(8);
            Win32.GetCursorPos((void*)pt);
            MouseDX = pt[0] - cx;
            MouseDY = pt[1] - cy;
            Memory.Free((void*)pt);

            Win32.SetCursorPos(cx, cy);
        }

        // Drain all pending messages without blocking. Sets ShouldClose on WM_QUIT.
        public func Pump()
        {
            while (Win32.PeekMessageA(msgBuf, null, 0u, 0u, Win32.PM_REMOVE) != 0)
            {
                if (*(uint*)((byte*)msgBuf + 8) == Win32.WM_QUIT)
                    ShouldClose = true;
                Win32.TranslateMessage(msgBuf);
                Win32.DispatchMessageA(msgBuf);
            }
        }
    }
}
