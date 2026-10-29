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
        Canvas canvas;
        float ox;
        float oy;
        int clipX;
        int clipY;
        int clipW;
        int clipH;
        public int Width;
        public int Height;

        public Graphics(Canvas target, int x, int y, int width, int height)
        {
            canvas = target;
            Begin(x, y, width, height);
        }

        internal void Begin(int x, int y, int width, int height)
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
        public Canvas Canvas => canvas;

        public void Clear(uint color) { canvas.FillRect((int)ox, (int)oy, Width, Height, color | 0xff000000); }

        public void FillRect(float x, float y, float w, float h, uint color) { canvas.FillRoundRect(ox + x, oy + y, w, h, 0, color); }

        public void DrawRect(float x, float y, float w, float h, uint color) { canvas.StrokeRoundRect(ox + x, oy + y, w, h, 0, 1, color); }

        public void DrawRect(float x, float y, float w, float h, uint color, float thickness)
        {
            canvas.StrokeRoundRect(ox + x, oy + y, w, h, 0, thickness, color);
        }

        public void FillRoundRect(float x, float y, float w, float h, float radius, uint color)
        {
            canvas.FillRoundRect(ox + x, oy + y, w, h, radius, color);
        }

        public void DrawRoundRect(float x, float y, float w, float h, float radius, uint color, float thickness)
        {
            canvas.StrokeRoundRect(ox + x, oy + y, w, h, radius, thickness, color);
        }

        // Degradado lineal de 'from' a 'to' (vertical u horizontal).
        public void FillGradient(float x, float y, float w, float h, uint from, uint to, bool horizontal)
        {
            canvas.FillRoundRectGradient(ox + x, oy + y, w, h, 0, from, to, horizontal);
        }

        public void FillRoundGradient(float x, float y, float w, float h, float radius, uint from, uint to, bool horizontal)
        {
            canvas.FillRoundRectGradient(ox + x, oy + y, w, h, radius, from, to, horizontal);
        }

        public void DrawLine(float x1, float y1, float x2, float y2, uint color) { canvas.Line(ox + x1, oy + y1, ox + x2, oy + y2, 1, color); }

        public void DrawLine(float x1, float y1, float x2, float y2, uint color, float thickness)
        {
            canvas.Line(ox + x1, oy + y1, ox + x2, oy + y2, thickness, color);
        }

        public void FillCircle(float cx, float cy, float radius, uint color) { canvas.FillCircle(ox + cx, oy + cy, radius, color); }

        public void DrawCircle(float cx, float cy, float radius, uint color) { DrawCircle(cx, cy, radius, color, 1); }

        public void DrawCircle(float cx, float cy, float radius, uint color, float thickness)
        {
            canvas.StrokeRoundRect(ox + cx - radius, oy + cy - radius, radius * 2, radius * 2, radius, thickness, color);
        }

        // Texto con la esquina superior izquierda en (x, y); devuelve el ancho dibujado.
        public float DrawText(string s, float x, float y, uint color) => DrawText(s, x, y, color, 14, false);

        public float DrawText(string s, float x, float y, uint color, int size) => DrawText(s, x, y, color, size, false);

        public float DrawText(string s, float x, float y, uint color, int size, bool bold)
        {
            UiFont font = UiFont.Get(size, bold);
            float end = canvas.Text(font, s, ox + x, oy + y + font.Ascent, color);
            return end - (ox + x);
        }

        public float MeasureText(string s, int size) => UiFont.Get(size, false).Measure(s);

        public float MeasureText(string s, int size, bool bold) => UiFont.Get(size, bold).Measure(s);

        public void DrawImage(Image img, float x, float y) { canvas.DrawImage(img, ox + x, oy + y); }

        public void DrawImage(Image img, float x, float y, float w, float h) { canvas.DrawImage(img, ox + x, oy + y, w, h); }

        // Región (sx, sy, sw, sh) de la imagen en el rectángulo (x, y, w, h): hojas de sprites.
        public void DrawImage(Image img, float sx, float sy, float sw, float sh, float x, float y, float w, float h)
        {
            canvas.DrawImage(img, sx, sy, sw, sh, ox + x, oy + y, w, h, 1);
        }

        public void DrawImage(Image img, float x, float y, float w, float h, float opacity)
        {
            if (img == null) return;
            canvas.DrawImage(img, 0, 0, img.Width, img.Height, ox + x, oy + y, w, h, opacity);
        }

        // Limita el dibujo siguiente al rectángulo (dentro del control).
        public void SetClip(float x, float y, float w, float h)
        {
            ResetClip();
            canvas.Clip((int)Math.Floor(ox + x), (int)Math.Floor(oy + y), (int)Math.Ceiling((double)w), (int)Math.Ceiling((double)h));
        }

        public void ResetClip()
        {
            canvas.ResetClip();
            canvas.Clip(clipX, clipY, clipW, clipH);
        }
    }

    public memory_unsafe partial class Widget
    {
        Graphics graphics;

        void DrawCanvasWidget(Canvas c, Palette p, float fx, float fy, float fw, float fh)
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
