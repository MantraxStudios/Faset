using FasetStudio.Gfx;

int main()
{
    Renderer r = new Renderer();
    if (!r.InitOffscreen(640, 200))
    {
        println(r.Error);
        return 1;
    }
    println(r.DeviceName);
    r.BeginFrame(Color.Hex(0x1e1e1e));
    r.Rect(10, 10, 200, 40, Color.Hex(0x007acc));
    r.Text(r.Ui, 20, 20, "FasetStudio con Vulkan ñ áé", Color.Hex(0xffffff));
    r.Text(r.Code, 20, 70, "int main() { return 42; } // código", Color.Hex(0xd4d4d4));
    r.PushClip(20, 110, 120, 30);
    r.Rect(0, 0, 640, 200, Color.Hex(0x3a3d41, 0.8f));
    r.Text(r.Code, 20, 112, "texto recortado por el clip", Color.Hex(0xce9178));
    r.PopClip();
    r.RectOutline(300, 100, 200, 60, 2, Color.Hex(0x4ec9b0));
    r.EndFrame();
    println(r.SaveScreenshot("/tmp/claude-1000/-home-rh-Escritorio-Faset/1773ab58-9059-4e5b-8468-0ad764b76c0e/scratchpad/render.ppm"));
    r.Shutdown();
    return 0;
}
