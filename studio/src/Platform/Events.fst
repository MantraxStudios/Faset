// =============================================================================
//  Tipos comunes de la capa de ventana (X11.fst en Linux, Win32.fst en Windows).
//  Las teclas usan los códigos keysym de X11; Win32.fst traduce a ellos las teclas virtuales.
// =============================================================================
namespace FasetStudio.Platform
{
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
        public const uint F6 = 0xffc3;
        public const uint F9 = 0xffc6;
        public const uint F10 = 0xffc7;
        public const uint F11 = 0xffc8;
        public const uint F12 = 0xffc9;
    }

    public struct Event
    {
        public var Kind: EventKind;
        public var X: int;
        public var Y: int;
        public var Button: int;      // 1 izquierdo, 2 central, 3 derecho
        public var Key: uint;        // keysym (letras en minúscula)
        public var Char: char;       // carácter escrito (0 si no hay)
        public var Ctrl: bool;
        public var Shift: bool;
        public var Alt: bool;
        public var Width: int;
        public var Height: int;
        public var ScrollLines: int; // positivo = hacia abajo
    }
}
