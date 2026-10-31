// =============================================================================
//  Soul - a Minecraft-style voxel game written in Faset, rendered with Vulkan.
//
//  An infinite, procedurally-generated, textured voxel world you can fly through
//  and edit. Chunks stream in around the camera.
//    Mouse        look            W A S D   move
//    Space/Shift  up / down       1 2 3 4   grass / dirt / stone / sand
//    Left click   break block     Right     place block            Esc  quit
//
//  Build:  powershell -ExecutionPolicy Bypass -File soul/build.ps1
// =============================================================================
using std;
using Soul.Platform;
using Soul.Vulkan;
using Soul.Math3;
using Soul.Game;

func main()
{
    Console.WriteLine("[Soul] starting");

    var window = new Window("Soul", 1280, 720);
    var renderer = new Renderer();
    renderer.Init(window);

    var cam = new Camera(new Vec3(100.0f, 46.0f, 100.0f));
    cam.Pitch = -0.33f;

    var chunks = new ChunkManager(renderer, 6);
    chunks.Update(cam.Position.x, cam.Position.z, 2000);   // pre-load around spawn
    Console.WriteLine("[Soul] world streaming");

    var particles = new ParticleSystem();
    var pmb = new MeshBuilder();

    window.EnableMouseLook();

    float speed = 0.5f;
    float sens  = 0.0022f;
    var worldUp = new Vec3(0.0f, 1.0f, 0.0f);

    byte held = Block.STONE;
    bool prevLeft = false;
    bool prevRight = false;

    while (!window.ShouldClose)
    {
        window.Pump();
        window.UpdateMouse();

        chunks.Update(cam.Position.x, cam.Position.z, 2);   // stream as we move

        cam.Yaw   += (float)window.MouseDX * sens;
        cam.Pitch -= (float)window.MouseDY * sens;
        if (cam.Pitch >  1.55f) cam.Pitch =  1.55f;
        if (cam.Pitch < -1.55f) cam.Pitch = -1.55f;

        var fwd   = cam.Forward();
        var right = cam.Right();
        if (Input.IsKeyDown(Win32.VK_W))     cam.Position = cam.Position + fwd * speed;
        if (Input.IsKeyDown(Win32.VK_S))     cam.Position = cam.Position - fwd * speed;
        if (Input.IsKeyDown(Win32.VK_D))     cam.Position = cam.Position + right * speed;
        if (Input.IsKeyDown(Win32.VK_A))     cam.Position = cam.Position - right * speed;
        if (Input.IsKeyDown(Win32.VK_SPACE)) cam.Position = cam.Position + worldUp * speed;
        if (Input.IsKeyDown(Win32.VK_SHIFT)) cam.Position = cam.Position - worldUp * speed;

        if (Input.IsKeyDown(Win32.VK_1)) held = Block.GRASS;
        if (Input.IsKeyDown(Win32.VK_2)) held = Block.DIRT;
        if (Input.IsKeyDown(Win32.VK_3)) held = Block.STONE;
        if (Input.IsKeyDown(Win32.VK_4)) held = Block.SAND;

        bool left   = Input.IsKeyDown(Win32.VK_LBUTTON);
        bool right2  = Input.IsKeyDown(Win32.VK_RBUTTON);

        if ((left && !prevLeft) || (right2 && !prevRight))
        {
            var hit = Raycast.Cast(cam.Position, cam.Forward(), 8.0f);
            if (hit.Hit)
            {
                if (left && !prevLeft && hit.Y >= 0 && hit.Y < 128)
                {
                    byte broken = World.BlockAt(hit.X, hit.Y, hit.Z);
                    World.SetBlock(hit.X, hit.Y, hit.Z, Block.AIR);
                    renderer.WaitIdle();
                    chunks.RebuildAround(hit.X, hit.Z);
                    particles.Spawn((float)hit.X + 0.5f, (float)hit.Y + 0.5f, (float)hit.Z + 0.5f, broken, 16);
                }
                if (right2 && !prevRight && hit.PY >= 0 && hit.PY < 128 && !World.IsSolid(hit.PX, hit.PY, hit.PZ))
                {
                    World.SetBlock(hit.PX, hit.PY, hit.PZ, held);
                    renderer.WaitIdle();
                    chunks.RebuildAround(hit.PX, hit.PZ);
                }
            }
        }
        prevLeft = left;
        prevRight = right2;

        particles.Update(0.016f);
        pmb.Reset();
        particles.BuildMesh(pmb);

        renderer.DrawFrame(cam.Position, cam.Target(), pmb);
    }

    renderer.WaitIdle();
    Console.WriteLine("[Soul] shutdown");
}
