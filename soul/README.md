# Soul

A Minecraft-style voxel game written in **Faset**, rendered with **Vulkan** — no
external runtime dependencies. The window and input use the Win32 API directly,
and Vulkan is loaded dynamically from `vulkan-1.dll` (no Vulkan loader library and
no SDK needed to *run* the game; the SDK is only needed at build time for `glslc`).

## Features

- **Infinite procedural world** — streamed chunk by chunk around the camera
  (sine-octave heightmap: hills, lakes, sand beaches).
- **Procedural textures** — a 64×64 atlas (grass, dirt, stone, sand, wood, leaves,
  water, foliage) generated entirely in code, no image files.
- **Directional sun lighting + shadow mapping** — a 2048² depth shadow map with
  3×3 PCF soft edges.
- **Trees and tall-grass foliage** (alpha-cutout cross-quads).
- **Translucent water** — a separate alpha-blended pass; you can see the bottom.
- **Build & break** blocks with a voxel raycast, with **particle VFX** bursts.

## Controls

| Input | Action |
|---|---|
| Mouse | Look around |
| `W` `A` `S` `D` | Move |
| `Space` / `Shift` | Up / down |
| Left click | Break the targeted block |
| Right click | Place a block against the targeted face |
| `1` `2` `3` `4` | Select grass / dirt / stone / sand |
| `Esc` | Quit |

## Build & run

Requires the [Vulkan SDK](https://vulkan.lunarg.com/) (for `glslc`) and the Faset
compiler (`build-cc/faset.exe`, built with `ninja -C build-cc` from the repo root).

```powershell
# from the repository root
powershell -ExecutionPolicy Bypass -File soul/build.ps1
soul/bin/Debug/windows-x86_64/Soul.exe
```

`build.ps1` compiles the GLSL shaders to SPIR-V with `glslc`, then builds the
project with Faset.

## How it works

```
src/
├── Main.fst               game loop: input, camera, streaming, edits, particles
├── Platform/Win32.fst     window, keyboard, mouse-look (Win32 FFI)
├── Math/
│   ├── MathTypes.fst      Vec3, column-major Mat4 (perspective/ortho/lookAt)
│   └── Camera.fst         yaw/pitch fly camera
├── Vulkan/
│   ├── Vk.fst             dynamic loader + typed command table + enums
│   ├── VkTypes.fst        Vulkan structs (exact C ABI layout)
│   ├── Renderer.fst       instance → swapchain → textures → shadow map → draw
│   └── Mesh.fst           GPU mesh + CPU MeshBuilder (pos+normal+colour+uv)
└── Game/
    ├── Textures.fst       procedural texture atlas generator
    ├── Voxels.fst         block types + per-face meshing (tiles, normals)
    ├── World.fst          procedural heightmap, water, trees, sparse edits
    ├── Chunk.fst          chunk meshing (opaque + water, air-facing faces)
    ├── ChunkManager.fst   streaming: load/unload chunks around the camera
    ├── Raycast.fst        ray march for break/place targeting
    └── Particles.fst      block-break particle VFX
```

Rendering is a two-pass forward renderer: a depth-only **shadow pass** fills the
sun's shadow map, then the **main pass** draws opaque geometry (with texture +
sun lighting + PCF shadows), particles, and finally translucent water. The
camera MVP and the light-space matrix are delivered as a 128-byte push constant.

The renderer talks to Vulkan entirely through Faset's C FFI: commands are stored as
`delegate*` function pointers resolved via `vkGetInstanceProcAddr` /
`vkGetDeviceProcAddr`, and every Vulkan struct is a `memory_unsafe struct` whose
field order matches the C ABI, so `&struct` can be passed straight to the driver.
The camera's MVP matrix is delivered through a push constant (no descriptor sets),
and chunk geometry is built in world space, so chunks need no model transform.

## Known limitations / next steps

- The swapchain is **not** recreated on window resize yet (resizing/maximizing will
  break rendering). Handle `VK_ERROR_OUT_OF_DATE_KHR` and rebuild the swapchain.
- Shadows use a single shadow map, not multi-cascade CSM — fine near the player,
  lower quality at distance. Cascades would be the next step.
- **Deferred rendering** is intentionally not implemented: a G-buffer adds cost and
  complexity with no benefit for a single-light forward voxel renderer.
- No gravity/collision (the camera flies freely); the sparse edit map grows while
  exploring.
