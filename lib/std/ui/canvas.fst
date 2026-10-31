// =============================================================================
//  std.ui — Canvas: control de dibujo libre (juegos, gráficos).
//
//      <Canvas Name="lienzo" X="0" Y="0" Width="400" Height="300" Paint="OnPaint" MouseDown="OnDown" />
//
//      void OnPaint(Widget sender, Graphics g)
//      {
//          g.Clear(Rgb.Of(0x101018));
//          g.FillCircle(x, y, 20, Rgb.Of(0x4c8dff));
//          g.DrawText("Puntos: 10", 12, 10, Rgb.Of(0xffffff));
//      }
//      void OnDown(Widget sender, MouseArgs e) { x = e.X; y = e.Y; sender.Invalidate(); }
//
//  Las coordenadas de Graphics son relativas al control y el dibujo queda
//  recortado a su rectángulo. Colores 0xAARRGGBB (Rgb.Of(0xRRGGBB) da uno opaco).
//  Invalidate() pide otro fotograma; con un Timer se consigue una animación.
// =============================================================================
namespace std.ui
{
    // Contexto de dibujo de un Canvas (lo recibe el evento Paint).
    public memory_unsafe class Graphics
    {
        var canvas: Canvas;
        var ox: float;
        var oy: float;
        var clipX: int;
        var clipY: int;
        var clipW: int;
        var clipH: int;
        public var Width: int;
        public var Height: int;

        public init(target: Canvas, x: int, y: int, width: int, height: int)
        {
            canvas = target;
            Begin(x, y, width, height);
        }

        internal func Begin(x: int, y: int, width: int, height: int)
        {
            ox = x;
            oy = y;
            clipX = x;
            clipY = y;
            clipW = width;
            clipH = height;
            Width = width;
            Height = height;
            ResetClip();
        }

        // El lienzo de la ventana (para dibujar con coordenadas absolutas).
        public prop Canvas: Canvas => canvas;

        public func Clear(color: uint) { canvas.FillRect((int)ox, (int)oy, Width, Height, color | 0xff000000); }

        public func FillRect(x: float, y: float, w: float, h: float, color: uint) { canvas.FillRoundRect(ox + x, oy + y, w, h, 0, color); }

        public func DrawRect(x: float, y: float, w: float, h: float, color: uint) { canvas.StrokeRoundRect(ox + x, oy + y, w, h, 0, 1, color); }

        public func DrawRect(x: float, y: float, w: float, h: float, color: uint, thickness: float)
        {
            canvas.StrokeRoundRect(ox + x, oy + y, w, h, 0, thickness, color);
        }

        public func FillRoundRect(x: float, y: float, w: float, h: float, radius: float, color: uint)
        {
            canvas.FillRoundRect(ox + x, oy + y, w, h, radius, color);
        }

        public func DrawRoundRect(x: float, y: float, w: float, h: float, radius: float, color: uint, thickness: float)
        {
            canvas.StrokeRoundRect(ox + x, oy + y, w, h, radius, thickness, color);
        }

        // Degradado lineal de 'from' a 'to' (vertical u horizontal).
        public func FillGradient(x: float, y: float, w: float, h: float, from: uint, to: uint, horizontal: bool)
        {
            canvas.FillRoundRectGradient(ox + x, oy + y, w, h, 0, from, to, horizontal);
        }

        public func FillRoundGradient(x: float, y: float, w: float, h: float, radius: float, from: uint, to: uint, horizontal: bool)
        {
            canvas.FillRoundRectGradient(ox + x, oy + y, w, h, radius, from, to, horizontal);
        }

        public func DrawLine(x1: float, y1: float, x2: float, y2: float, color: uint) { canvas.Line(ox + x1, oy + y1, ox + x2, oy + y2, 1, color); }

        public func DrawLine(x1: float, y1: float, x2: float, y2: float, color: uint, thickness: float)
        {
            canvas.Line(ox + x1, oy + y1, ox + x2, oy + y2, thickness, color);
        }

        public func FillCircle(cx: float, cy: float, radius: float, color: uint) { canvas.FillCircle(ox + cx, oy + cy, radius, color); }

        public func DrawCircle(cx: float, cy: float, radius: float, color: uint) { DrawCircle(cx, cy, radius, color, 1); }

        public func DrawCircle(cx: float, cy: float, radius: float, color: uint, thickness: float)
        {
            canvas.StrokeRoundRect(ox + cx - radius, oy + cy - radius, radius * 2, radius * 2, radius, thickness, color);
        }

        // Texto con la esquina superior izquierda en (x, y); devuelve el ancho dibujado.
        public func DrawText(s: string, x: float, y: float, color: uint) -> float => DrawText(s, x, y, color, 14, false);

        public func DrawText(s: string, x: float, y: float, color: uint, size: int) -> float => DrawText(s, x, y, color, size, false);

        public func DrawText(s: string, x: float, y: float, color: uint, size: int, bold: bool) -> float
        {
            UiFont font = UiFont.Get(size, bold);
            float end = canvas.Text(font, s, ox + x, oy + y + font.Ascent, color);
            return end - (ox + x);
        }

        public func MeasureText(s: string, size: int) -> float => UiFont.Get(size, false).Measure(s);

        public func MeasureText(s: string, size: int, bold: bool) -> float => UiFont.Get(size, bold).Measure(s);

        public func DrawImage(img: Image, x: float, y: float) { canvas.DrawImage(img, ox + x, oy + y); }

        public func DrawImage(img: Image, x: float, y: float, w: float, h: float) { canvas.DrawImage(img, ox + x, oy + y, w, h); }

        // Región (sx, sy, sw, sh) de la imagen en el rectángulo (x, y, w, h): hojas de sprites.
        public func DrawImage(img: Image, sx: float, sy: float, sw: float, sh: float, x: float, y: float, w: float, h: float)
        {
            canvas.DrawImage(img, sx, sy, sw, sh, ox + x, oy + y, w, h, 1);
        }

        public func DrawImage(img: Image, x: float, y: float, w: float, h: float, opacity: float)
        {
            if (img == null) return;
            canvas.DrawImage(img, 0, 0, img.Width, img.Height, ox + x, oy + y, w, h, opacity);
        }

        // Limita el dibujo siguiente al rectángulo (dentro del control).
        public func SetClip(x: float, y: float, w: float, h: float)
        {
            ResetClip();
            canvas.Clip((int)Math.Floor(ox + x), (int)Math.Floor(oy + y), (int)Math.Ceiling((double)w), (int)Math.Ceiling((double)h));
        }

        public func ResetClip()
        {
            canvas.ResetClip();
            canvas.Clip(clipX, clipY, clipW, clipH);
        }
    }

    public memory_unsafe partial class Widget
    {
        var graphics: Graphics;

        func DrawCanvasWidget(c: Canvas, p: Palette, fx: float, fy: float, fw: float, fh: float)
        {
            float r = CornerRadius >= 0 ? CornerRadius : 0;
            if (Background != 0) FillBackground(c, fx, fy, fw, fh, r, 0);
            if (paintEvent != 0 && eventFn != null)
            {
                if (graphics == null) graphics = new Graphics(c, ScreenX, ScreenY, ActualWidth, ActualHeight);
                else graphics.Begin(ScreenX, ScreenY, ActualWidth, ActualHeight);
                Graphics = graphics;
                RaiseEvent(paintEvent);
                c.ResetClip();
            }
            if (BorderColor != 0) c.StrokeRoundRect(fx, fy, fw, fh, r, 1, BorderColor);
        }
    }
}
