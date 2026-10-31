// =============================================================================
//  Soul - Vulkan renderer (3D).
//
//  Brings up Vulkan and renders indexed, depth-tested 3D geometry. The camera's
//  model-view-projection matrix is delivered to the vertex shader through a
//  push-constant block (no descriptor sets needed). Command buffers are recorded
//  per frame so the camera can move. Geometry is supplied as Mesh objects built
//  with MeshBuilder (the test cube, then voxel chunks).
// =============================================================================
using std;
using std.io;
using std.collections;
using Soul.Platform;
using Soul.Math3;
using Soul.Game;

namespace Soul.Vulkan
{
    public memory_unsafe class Renderer
    {
        // device
        public var Instance: void*
        public var Surface: void*
        public var PhysicalDevice: void*
        public var Device: void*
        public var GraphicsQueue: void*
        public var QueueFamilyIndex: uint

        // swapchain
        var Swapchain: void*
        var ImageCount: int
        var Images: void*
        var ImageViews: void*
        var Framebuffers: void*
        var CommandBuffers: void*
        var CommandPool: void*
        var RenderPass: void*
        var PipelineLayout: void*
        var GraphicsPipeline: void*
        var WaterPipeline: void*
        var Format: uint
        var ExtentW: uint
        var ExtentH: uint

        // depth
        var DepthImage: void*
        var DepthMemory: void*
        var DepthView: void*
        var DepthFormat: uint

        // texture atlas
        var TextureImage: void*
        var TextureMemory: void*
        var TextureView: void*
        var Sampler: void*
        var DescriptorSetLayout: void*
        var DescriptorPool: void*
        var DescriptorSet: void*

        // shadow map (sun shadows)
        var ShadowSize: int
        var ShadowImage: void*
        var ShadowMemory: void*
        var ShadowView: void*
        var ShadowSampler: void*
        var ShadowRenderPass: void*
        var ShadowFramebuffer: void*
        var ShadowPipeline: void*
        var LightVP: float*
        var LightView: float*
        var LightProj: float*

        // sync (single frame in flight)
        var ImageAvailable: void*
        var RenderFinished: void*
        var InFlight: void*

        // scene
        var Meshes: List<Mesh>
        var FreeSlots: List<int>
        var WaterMeshes: List<Mesh>
        var WaterFreeSlots: List<int>

        // dynamic mesh (particles): persistent host-visible buffers updated per frame
        var DynVB: void*
        var DynVM: void*
        var DynIB: void*
        var DynIM: void*
        var DynCapV: int
        var DynCapI: int
        var DynIndexCount: int

        var ShaderDir: string
        var Proj: float*
        var View: float*
        var Mvp: float*
        var PushData: float*     // 20 floats: mvp(16) + sunDir(4)
        var SunX: float
        var SunY: float
        var SunZ: float

        var ClearR: float
        var ClearG: float
        var ClearB: float

        public func Init(window: Window)
        {
            ClearR = 0.55f; ClearG = 0.72f; ClearB = 0.97f;
            DepthFormat = Vk.FORMAT_D32_SFLOAT;
            Meshes = new List<Mesh>();
            FreeSlots = new List<int>();
            WaterMeshes = new List<Mesh>();
            WaterFreeSlots = new List<int>();

            if (!Vk.LoadLoader()) panic("Vulkan: could not load vulkan-1.dll (is a Vulkan GPU driver installed?)");
            CreateInstance();
            Vk.LoadInstance(Instance);
            CreateSurface(window);
            PickPhysicalDevice();
            CreateDevice();
            Vk.LoadDevice(Device);

            void* q = Memory.Alloc(8);
            Vk.vkGetDeviceQueue(Device, QueueFamilyIndex, 0u, q);
            GraphicsQueue = *(void**)q;
            Memory.Free(q);

            ShadowSize = 2048;
            ComputeShaderDir();
            CreateSwapchain(window);
            CreateCommandBuffers();
            CreateTexture();
            CreateShadowImage();
            CreateDescriptors();
            CreateDepthResources();
            CreateRenderPass();
            CreateGraphicsPipeline();
            CreateFramebuffers();
            CreateSyncObjects();

            Proj = (float*)Memory.Alloc(64);
            View = (float*)Memory.Alloc(64);
            Mvp  = (float*)Memory.Alloc(64);
            LightVP = (float*)Memory.Alloc(64);
            LightView = (float*)Memory.Alloc(64);
            LightProj = (float*)Memory.Alloc(64);
            PushData = (float*)Memory.Alloc(128);   // mvp(16) + lightVP(16) floats
            float aspect = (float)ExtentW / (float)ExtentH;
            Mat.Perspective(1.05f, aspect, 0.1f, 1000.0f, Proj);

            var sun = new Vec3(-0.5f, -0.55f, -0.4f).Normalized();
            SunX = sun.x; SunY = sun.y; SunZ = sun.z;

            // dynamic particle buffers
            DynCapV = 40000; DynCapI = 60000; DynIndexCount = 0;
            void* dvm; DynVB = CreateHostBuffer((ulong)((long)DynCapV * 44), Vk.BUFFER_USAGE_VERTEX_BUFFER, (void**)&dvm); DynVM = dvm;
            void* dim; DynIB = CreateHostBuffer((ulong)((long)DynCapI * 4),  Vk.BUFFER_USAGE_INDEX_BUFFER,  (void**)&dim); DynIM = dim;

            Console.WriteLine("[Soul] renderer ready (" + ImageCount + " images, " + ExtentW + "x" + ExtentH + ")");
        }

        public func AddMesh(mesh: Mesh) -> int
        {
            if (FreeSlots.Count > 0)
            {
                int idx = FreeSlots[FreeSlots.Count - 1];
                FreeSlots.RemoveAt(FreeSlots.Count - 1);
                Meshes[idx] = mesh;
                return idx;
            }
            Meshes.Add(mesh);
            return Meshes.Count - 1;
        }
        public func RemoveMesh(idx: int) { Meshes[idx] = null; FreeSlots.Add(idx); }
        public func GetMesh(i: int) -> Mesh => Meshes[i];
        public func ReplaceMesh(i: int, m: Mesh) { Meshes[i] = m; }

        public func AddWaterMesh(mesh: Mesh) -> int
        {
            if (WaterFreeSlots.Count > 0)
            {
                int idx = WaterFreeSlots[WaterFreeSlots.Count - 1];
                WaterFreeSlots.RemoveAt(WaterFreeSlots.Count - 1);
                WaterMeshes[idx] = mesh;
                return idx;
            }
            WaterMeshes.Add(mesh);
            return WaterMeshes.Count - 1;
        }
        public func RemoveWaterMesh(idx: int) { WaterMeshes[idx] = null; WaterFreeSlots.Add(idx); }
        public func GetWaterMesh(i: int) -> Mesh => WaterMeshes[i];
        public func ReplaceWaterMesh(i: int, m: Mesh) { WaterMeshes[i] = m; }

        func Check(res: int, what: string)
        {
            if (res != 0) panic("Vulkan: " + what + " failed (VkResult " + res + ")");
        }

        // --- instance -------------------------------------------------------
        func CreateInstance()
        {
            let e0 = "VK_KHR_surface";
            let e1 = "VK_KHR_win32_surface";
            byte* exts = (byte*)Memory.Alloc(16);
            *(void**)(exts + 0) = e0.Ptr;
            *(void**)(exts + 8) = e1.Ptr;

            VkInstanceCreateInfo ci;
            ci.sType = Vk.STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
            ci.pNext = null; ci.flags = 0u;
            ci.pApplicationInfo = null;
            ci.enabledLayerCount = 0u; ci.ppEnabledLayerNames = null;
            ci.enabledExtensionCount = 2u;
            ci.ppEnabledExtensionNames = (void*)exts;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateInstance((void*)&ci, null, p), "vkCreateInstance");
            Instance = *(void**)p;
            Memory.Free(p);
            Memory.Free((void*)exts);
        }

        // --- surface --------------------------------------------------------
        func CreateSurface(window: Window)
        {
            VkWin32SurfaceCreateInfoKHR ci;
            ci.sType = Vk.STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
            ci.pNext = null; ci.flags = 0u;
            ci.hinstance = window.Hinstance;
            ci.hwnd = window.Hwnd;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateWin32SurfaceKHR(Instance, (void*)&ci, null, p), "vkCreateWin32SurfaceKHR");
            Surface = *(void**)p;
            Memory.Free(p);
        }

        // --- physical device ------------------------------------------------
        func PickPhysicalDevice()
        {
            uint* count = (uint*)Memory.Alloc(4); *count = 0u;
            Check(Vk.vkEnumeratePhysicalDevices(Instance, (void*)count, null), "vkEnumeratePhysicalDevices");
            int n = (int)*count;
            if (n == 0) panic("Vulkan: no GPU with Vulkan support found");

            void** devs = (void**)Memory.Alloc(n * 8);
            Check(Vk.vkEnumeratePhysicalDevices(Instance, (void*)count, (void*)devs), "vkEnumeratePhysicalDevices");

            for (int i = 0; i < n; i++)
                if (FindQueueFamily(devs[i])) return;

            panic("Vulkan: no GPU with a graphics+present queue found");
        }

        func FindQueueFamily(phys: void*) -> bool
        {
            uint* count = (uint*)Memory.Alloc(4); *count = 0u;
            Vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, (void*)count, null);
            int n = (int)*count;
            if (n == 0) return false;

            VkQueueFamilyProperties* props = (VkQueueFamilyProperties*)Memory.Alloc(n * (int)sizeof(VkQueueFamilyProperties));
            Vk.vkGetPhysicalDeviceQueueFamilyProperties(phys, (void*)count, (void*)props);

            for (int i = 0; i < n; i++)
            {
                bool graphics = (props[i].queueFlags & Vk.QUEUE_GRAPHICS_BIT) != 0u;
                uint* sup = (uint*)Memory.Alloc(4); *sup = 0u;
                Vk.vkGetPhysicalDeviceSurfaceSupportKHR(phys, (uint)i, Surface, (void*)sup);
                bool present = *sup != 0u;
                if (graphics && present)
                {
                    PhysicalDevice = phys;
                    QueueFamilyIndex = (uint)i;
                    return true;
                }
            }
            return false;
        }

        // --- logical device -------------------------------------------------
        func CreateDevice()
        {
            float* prio = (float*)Memory.Alloc(4); *prio = 1.0f;

            VkDeviceQueueCreateInfo qci;
            qci.sType = Vk.STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
            qci.pNext = null; qci.flags = 0u;
            qci.queueFamilyIndex = QueueFamilyIndex;
            qci.queueCount = 1u;
            qci.pQueuePriorities = (void*)prio;

            let ext = "VK_KHR_swapchain";
            byte* exts = (byte*)Memory.Alloc(8);
            *(void**)exts = ext.Ptr;

            VkDeviceCreateInfo ci;
            ci.sType = Vk.STRUCTURE_TYPE_DEVICE_CREATE_INFO;
            ci.pNext = null; ci.flags = 0u;
            ci.queueCreateInfoCount = 1u;
            ci.pQueueCreateInfos = (void*)&qci;
            ci.enabledLayerCount = 0u; ci.ppEnabledLayerNames = null;
            ci.enabledExtensionCount = 1u;
            ci.ppEnabledExtensionNames = (void*)exts;
            ci.pEnabledFeatures = null;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateDevice(PhysicalDevice, (void*)&ci, null, p), "vkCreateDevice");
            Device = *(void**)p;
            Memory.Free(p);
        }

        // --- swapchain ------------------------------------------------------
        func CreateSwapchain(window: Window)
        {
            VkSurfaceCapabilitiesKHR caps;
            Check(Vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(PhysicalDevice, Surface, (void*)&caps),
                  "vkGetPhysicalDeviceSurfaceCapabilitiesKHR");

            ExtentW = caps.currentExtentWidth;
            ExtentH = caps.currentExtentHeight;

            uint* fcount = (uint*)Memory.Alloc(4); *fcount = 0u;
            Check(Vk.vkGetPhysicalDeviceSurfaceFormatsKHR(PhysicalDevice, Surface, (void*)fcount, null),
                  "vkGetPhysicalDeviceSurfaceFormatsKHR");
            int fn = (int)*fcount;
            VkSurfaceFormatKHR* formats = (VkSurfaceFormatKHR*)Memory.Alloc(fn * (int)sizeof(VkSurfaceFormatKHR));
            Vk.vkGetPhysicalDeviceSurfaceFormatsKHR(PhysicalDevice, Surface, (void*)fcount, (void*)formats);

            Format = formats[0].format;
            uint colorSpace = formats[0].colorSpace;
            for (int i = 0; i < fn; i++)
                if (formats[i].format == Vk.FORMAT_B8G8R8A8_SRGB && formats[i].colorSpace == Vk.COLOR_SPACE_SRGB_NONLINEAR)
                {
                    Format = formats[i].format;
                    colorSpace = formats[i].colorSpace;
                }

            uint desired = caps.minImageCount + 1u;
            if (caps.maxImageCount > 0u && desired > caps.maxImageCount) desired = caps.maxImageCount;

            VkSwapchainCreateInfoKHR ci;
            ci.sType = Vk.STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
            ci.pNext = null; ci.flags = 0u;
            ci.surface = Surface;
            ci.minImageCount = desired;
            ci.imageFormat = Format;
            ci.imageColorSpace = colorSpace;
            ci.imageExtentWidth = ExtentW;
            ci.imageExtentHeight = ExtentH;
            ci.imageArrayLayers = 1u;
            ci.imageUsage = Vk.IMAGE_USAGE_COLOR_ATTACHMENT;
            ci.imageSharingMode = Vk.SHARING_MODE_EXCLUSIVE;
            ci.queueFamilyIndexCount = 0u;
            ci.pQueueFamilyIndices = null;
            ci.preTransform = caps.currentTransform;
            ci.compositeAlpha = Vk.COMPOSITE_ALPHA_OPAQUE;
            ci.presentMode = Vk.PRESENT_MODE_FIFO;
            ci.clipped = 1u;
            ci.oldSwapchain = null;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateSwapchainKHR(Device, (void*)&ci, null, p), "vkCreateSwapchainKHR");
            Swapchain = *(void**)p;
            Memory.Free(p);

            uint* icount = (uint*)Memory.Alloc(4); *icount = 0u;
            Vk.vkGetSwapchainImagesKHR(Device, Swapchain, (void*)icount, null);
            ImageCount = (int)*icount;
            Images = Memory.Alloc(ImageCount * 8);
            Vk.vkGetSwapchainImagesKHR(Device, Swapchain, (void*)icount, Images);

            ImageViews = Memory.Alloc(ImageCount * 8);
            for (int i = 0; i < ImageCount; i++)
                ((void**)ImageViews)[i] = CreateImageView(((void**)Images)[i], Format, Vk.IMAGE_ASPECT_COLOR_BIT);
        }

        func CreateImageView(image: void*, format: uint, aspect: uint) -> void*
        {
            VkImageViewCreateInfo vi;
            vi.sType = Vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            vi.pNext = null; vi.flags = 0u;
            vi.image = image;
            vi.viewType = Vk.IMAGE_VIEW_TYPE_2D;
            vi.format = format;
            vi.componentsR = 0u; vi.componentsG = 0u; vi.componentsB = 0u; vi.componentsA = 0u;
            vi.aspectMask = aspect;
            vi.baseMipLevel = 0u; vi.levelCount = 1u;
            vi.baseArrayLayer = 0u; vi.layerCount = 1u;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateImageView(Device, (void*)&vi, null, p), "vkCreateImageView");
            void* v = *(void**)p;
            Memory.Free(p);
            return v;
        }

        // --- depth ----------------------------------------------------------
        func CreateDepthResources()
        {
            VkImageCreateInfo ci;
            ci.sType = Vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            ci.pNext = null; ci.flags = 0u;
            ci.imageType = Vk.IMAGE_TYPE_2D;
            ci.format = DepthFormat;
            ci.extentW = ExtentW; ci.extentH = ExtentH; ci.extentD = 1u;
            ci.mipLevels = 1u; ci.arrayLayers = 1u;
            ci.samples = Vk.SAMPLE_COUNT_1_BIT;
            ci.tiling = Vk.IMAGE_TILING_OPTIMAL;
            ci.usage = Vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT;
            ci.sharingMode = Vk.SHARING_MODE_EXCLUSIVE;
            ci.queueFamilyIndexCount = 0u; ci.pQueueFamilyIndices = null;
            ci.initialLayout = Vk.IMAGE_LAYOUT_UNDEFINED;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateImage(Device, (void*)&ci, null, p), "vkCreateImage(depth)");
            DepthImage = *(void**)p;
            Memory.Free(p);

            VkMemoryRequirements req;
            Vk.vkGetImageMemoryRequirements(Device, DepthImage, (void*)&req);

            VkMemoryAllocateInfo ai;
            ai.sType = Vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            ai.pNext = null;
            ai.allocationSize = req.size;
            ai.memoryTypeIndex = FindMemoryType(req.memoryTypeBits, Vk.MEMORY_PROPERTY_DEVICE_LOCAL);

            void* pm = Memory.Alloc(8);
            Check(Vk.vkAllocateMemory(Device, (void*)&ai, null, pm), "vkAllocateMemory(depth)");
            DepthMemory = *(void**)pm;
            Memory.Free(pm);

            Check(Vk.vkBindImageMemory(Device, DepthImage, DepthMemory, 0UL), "vkBindImageMemory(depth)");
            DepthView = CreateImageView(DepthImage, DepthFormat, Vk.IMAGE_ASPECT_DEPTH_BIT);
        }

        func FindMemoryType(typeBits: uint, props: uint) -> uint
        {
            byte* mp = (byte*)Memory.Alloc(520);
            Vk.vkGetPhysicalDeviceMemoryProperties(PhysicalDevice, (void*)mp);
            uint typeCount = *(uint*)(mp + 0);
            for (int i = 0; i < (int)typeCount; i++)
            {
                uint propFlags = *(uint*)(mp + 4 + i * 8);
                if ((typeBits & (1u << i)) != 0u && (propFlags & props) == props)
                {
                    Memory.Free((void*)mp);
                    return (uint)i;
                }
            }
            panic("Vulkan: no suitable memory type");
            return 0u;
        }

        // --- one-time command helpers --------------------------------------
        func BeginOneTime() -> void*
        {
            VkCommandBufferAllocateInfo ai;
            ai.sType = Vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO; ai.pNext = null;
            ai.commandPool = CommandPool; ai.level = Vk.COMMAND_BUFFER_LEVEL_PRIMARY; ai.commandBufferCount = 1u;
            void* pp = Memory.Alloc(8);
            Check(Vk.vkAllocateCommandBuffers(Device, (void*)&ai, pp), "vkAllocateCommandBuffers(oneTime)");
            void* cmd = *(void**)pp; Memory.Free(pp);

            VkCommandBufferBeginInfo bi;
            bi.sType = Vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO; bi.pNext = null;
            bi.flags = Vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT; bi.pInheritanceInfo = null;
            Check(Vk.vkBeginCommandBuffer(cmd, (void*)&bi), "vkBeginCommandBuffer(oneTime)");
            return cmd;
        }

        func EndOneTime(cmd: void*)
        {
            Check(Vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer(oneTime)");
            void* c = cmd;
            VkSubmitInfo si;
            Memory.Set((void*)&si, 0, (long)sizeof(VkSubmitInfo));
            si.sType = Vk.STRUCTURE_TYPE_SUBMIT_INFO;
            si.commandBufferCount = 1u; si.pCommandBuffers = (void*)&c;
            Check(Vk.vkQueueSubmit(GraphicsQueue, 1u, (void*)&si, null), "vkQueueSubmit(oneTime)");
            Vk.vkQueueWaitIdle(GraphicsQueue);
        }

        func Barrier(cmd: void*, image: void*, oldL: uint, newL: uint,
                     srcAccess: uint, dstAccess: uint, srcStage: uint, dstStage: uint)
        {
            VkImageMemoryBarrier b;
            b.sType = Vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER; b.pNext = null;
            b.srcAccessMask = srcAccess; b.dstAccessMask = dstAccess;
            b.oldLayout = oldL; b.newLayout = newL;
            b.srcQueueFamilyIndex = Vk.QUEUE_FAMILY_IGNORED; b.dstQueueFamilyIndex = Vk.QUEUE_FAMILY_IGNORED;
            b.image = image;
            b.aspectMask = Vk.IMAGE_ASPECT_COLOR_BIT;
            b.baseMipLevel = 0u; b.levelCount = 1u; b.baseArrayLayer = 0u; b.layerCount = 1u;
            Vk.vkCmdPipelineBarrier(cmd, srcStage, dstStage, 0u, 0u, null, 0u, null, 1u, (void*)&b);
        }

        // --- texture atlas --------------------------------------------------
        func CreateTexture()
        {
            int w = Tiles.SIZE; int h = Tiles.SIZE;
            long bytes = (long)w * h * 4;
            byte* pixels = TextureAtlas.Generate();

            void* stagingMem;
            void* staging = CreateHostBuffer((ulong)bytes, Vk.BUFFER_USAGE_TRANSFER_SRC_BIT, (void**)&stagingMem);
            UploadBytes(stagingMem, (void*)pixels, bytes);

            VkImageCreateInfo ci;
            ci.sType = Vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO; ci.pNext = null; ci.flags = 0u;
            ci.imageType = Vk.IMAGE_TYPE_2D; ci.format = Vk.FORMAT_R8G8B8A8_UNORM;
            ci.extentW = (uint)w; ci.extentH = (uint)h; ci.extentD = 1u;
            ci.mipLevels = 1u; ci.arrayLayers = 1u;
            ci.samples = Vk.SAMPLE_COUNT_1_BIT; ci.tiling = Vk.IMAGE_TILING_OPTIMAL;
            ci.usage = Vk.IMAGE_USAGE_TRANSFER_DST_BIT | Vk.IMAGE_USAGE_SAMPLED_BIT;
            ci.sharingMode = Vk.SHARING_MODE_EXCLUSIVE;
            ci.queueFamilyIndexCount = 0u; ci.pQueueFamilyIndices = null;
            ci.initialLayout = Vk.IMAGE_LAYOUT_UNDEFINED;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateImage(Device, (void*)&ci, null, p), "vkCreateImage(atlas)");
            TextureImage = *(void**)p; Memory.Free(p);

            VkMemoryRequirements req;
            Vk.vkGetImageMemoryRequirements(Device, TextureImage, (void*)&req);
            VkMemoryAllocateInfo ai;
            ai.sType = Vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO; ai.pNext = null;
            ai.allocationSize = req.size;
            ai.memoryTypeIndex = FindMemoryType(req.memoryTypeBits, Vk.MEMORY_PROPERTY_DEVICE_LOCAL);
            void* pm = Memory.Alloc(8);
            Check(Vk.vkAllocateMemory(Device, (void*)&ai, null, pm), "vkAllocateMemory(atlas)");
            TextureMemory = *(void**)pm; Memory.Free(pm);
            Check(Vk.vkBindImageMemory(Device, TextureImage, TextureMemory, 0UL), "vkBindImageMemory(atlas)");

            void* cmd = BeginOneTime();
            Barrier(cmd, TextureImage, Vk.IMAGE_LAYOUT_UNDEFINED, Vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    0u, Vk.ACCESS_TRANSFER_WRITE_BIT, Vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT, Vk.PIPELINE_STAGE_TRANSFER_BIT);

            VkBufferImageCopy c;
            c.bufferOffset = 0UL; c.bufferRowLength = 0u; c.bufferImageHeight = 0u;
            c.aspectMask = Vk.IMAGE_ASPECT_COLOR_BIT; c.mipLevel = 0u; c.baseArrayLayer = 0u; c.layerCount = 1u;
            c.offsetX = 0; c.offsetY = 0; c.offsetZ = 0;
            c.extentW = (uint)w; c.extentH = (uint)h; c.extentD = 1u;
            Vk.vkCmdCopyBufferToImage(cmd, staging, TextureImage, Vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1u, (void*)&c);

            Barrier(cmd, TextureImage, Vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, Vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    Vk.ACCESS_TRANSFER_WRITE_BIT, Vk.ACCESS_SHADER_READ_BIT,
                    Vk.PIPELINE_STAGE_TRANSFER_BIT, Vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
            EndOneTime(cmd);

            TextureView = CreateImageView(TextureImage, Vk.FORMAT_R8G8B8A8_UNORM, Vk.IMAGE_ASPECT_COLOR_BIT);

            VkSamplerCreateInfo sci;
            Memory.Set((void*)&sci, 0, (long)sizeof(VkSamplerCreateInfo));
            sci.sType = Vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            sci.magFilter = Vk.FILTER_NEAREST; sci.minFilter = Vk.FILTER_NEAREST;
            sci.mipmapMode = Vk.SAMPLER_MIPMAP_MODE_NEAREST;
            sci.addressModeU = Vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sci.addressModeV = Vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sci.addressModeW = Vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sci.maxLod = 0.0f;
            void* ps = Memory.Alloc(8);
            Check(Vk.vkCreateSampler(Device, (void*)&sci, null, ps), "vkCreateSampler");
            Sampler = *(void**)ps; Memory.Free(ps);

            Memory.Free((void*)pixels);
            Vk.vkDestroyBuffer(Device, staging, null);
            Vk.vkFreeMemory(Device, stagingMem, null);
        }

        // --- shadow map -----------------------------------------------------
        func CreateShadowImage()
        {
            VkImageCreateInfo ci;
            ci.sType = Vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO; ci.pNext = null; ci.flags = 0u;
            ci.imageType = Vk.IMAGE_TYPE_2D; ci.format = DepthFormat;
            ci.extentW = (uint)ShadowSize; ci.extentH = (uint)ShadowSize; ci.extentD = 1u;
            ci.mipLevels = 1u; ci.arrayLayers = 1u;
            ci.samples = Vk.SAMPLE_COUNT_1_BIT; ci.tiling = Vk.IMAGE_TILING_OPTIMAL;
            ci.usage = Vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT | Vk.IMAGE_USAGE_SAMPLED_BIT;
            ci.sharingMode = Vk.SHARING_MODE_EXCLUSIVE;
            ci.queueFamilyIndexCount = 0u; ci.pQueueFamilyIndices = null;
            ci.initialLayout = Vk.IMAGE_LAYOUT_UNDEFINED;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateImage(Device, (void*)&ci, null, p), "vkCreateImage(shadow)");
            ShadowImage = *(void**)p; Memory.Free(p);

            VkMemoryRequirements req;
            Vk.vkGetImageMemoryRequirements(Device, ShadowImage, (void*)&req);
            VkMemoryAllocateInfo ai;
            ai.sType = Vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO; ai.pNext = null;
            ai.allocationSize = req.size;
            ai.memoryTypeIndex = FindMemoryType(req.memoryTypeBits, Vk.MEMORY_PROPERTY_DEVICE_LOCAL);
            void* pm = Memory.Alloc(8);
            Check(Vk.vkAllocateMemory(Device, (void*)&ai, null, pm), "vkAllocateMemory(shadow)");
            ShadowMemory = *(void**)pm; Memory.Free(pm);
            Check(Vk.vkBindImageMemory(Device, ShadowImage, ShadowMemory, 0UL), "vkBindImageMemory(shadow)");

            ShadowView = CreateImageView(ShadowImage, DepthFormat, Vk.IMAGE_ASPECT_DEPTH_BIT);

            VkSamplerCreateInfo sci;
            Memory.Set((void*)&sci, 0, (long)sizeof(VkSamplerCreateInfo));
            sci.sType = Vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
            sci.magFilter = Vk.FILTER_NEAREST; sci.minFilter = Vk.FILTER_NEAREST;
            sci.mipmapMode = Vk.SAMPLER_MIPMAP_MODE_NEAREST;
            sci.addressModeU = Vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sci.addressModeV = Vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sci.addressModeW = Vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            sci.maxLod = 0.0f;
            void* ps = Memory.Alloc(8);
            Check(Vk.vkCreateSampler(Device, (void*)&sci, null, ps), "vkCreateSampler(shadow)");
            ShadowSampler = *(void**)ps; Memory.Free(ps);

            // depth-only render pass
            VkAttachmentDescription att;
            att.flags = 0u; att.format = DepthFormat; att.samples = Vk.SAMPLE_COUNT_1_BIT;
            att.loadOp = Vk.ATTACHMENT_LOAD_OP_CLEAR; att.storeOp = Vk.ATTACHMENT_STORE_OP_STORE;
            att.stencilLoadOp = Vk.ATTACHMENT_LOAD_OP_DONT_CARE; att.stencilStoreOp = Vk.ATTACHMENT_STORE_OP_DONT_CARE;
            att.initialLayout = Vk.IMAGE_LAYOUT_UNDEFINED;
            att.finalLayout = Vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

            VkAttachmentReference depthRef;
            depthRef.attachment = 0u; depthRef.layout = Vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            VkSubpassDescription sub;
            sub.flags = 0u; sub.pipelineBindPoint = Vk.PIPELINE_BIND_POINT_GRAPHICS;
            sub.inputAttachmentCount = 0u; sub.pInputAttachments = null;
            sub.colorAttachmentCount = 0u; sub.pColorAttachments = null;
            sub.pResolveAttachments = null; sub.pDepthStencilAttachment = (void*)&depthRef;
            sub.preserveAttachmentCount = 0u; sub.pPreserveAttachments = null;

            VkRenderPassCreateInfo rci;
            rci.sType = Vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO; rci.pNext = null; rci.flags = 0u;
            rci.attachmentCount = 1u; rci.pAttachments = (void*)&att;
            rci.subpassCount = 1u; rci.pSubpasses = (void*)&sub;
            rci.dependencyCount = 0u; rci.pDependencies = null;
            void* pr = Memory.Alloc(8);
            Check(Vk.vkCreateRenderPass(Device, (void*)&rci, null, pr), "vkCreateRenderPass(shadow)");
            ShadowRenderPass = *(void**)pr; Memory.Free(pr);

            void* sview = ShadowView;
            VkFramebufferCreateInfo fci;
            fci.sType = Vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO; fci.pNext = null; fci.flags = 0u;
            fci.renderPass = ShadowRenderPass; fci.attachmentCount = 1u; fci.pAttachments = (void*)&sview;
            fci.width = (uint)ShadowSize; fci.height = (uint)ShadowSize; fci.layers = 1u;
            void* pf = Memory.Alloc(8);
            Check(Vk.vkCreateFramebuffer(Device, (void*)&fci, null, pf), "vkCreateFramebuffer(shadow)");
            ShadowFramebuffer = *(void**)pf; Memory.Free(pf);
        }

        func CreateDescriptors()
        {
            VkDescriptorSetLayoutBinding* binds =
                (VkDescriptorSetLayoutBinding*)Memory.Alloc(2 * (int)sizeof(VkDescriptorSetLayoutBinding));
            binds[0].binding = 0u; binds[0].descriptorType = Vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            binds[0].descriptorCount = 1u; binds[0].stageFlags = Vk.SHADER_STAGE_FRAGMENT_BIT; binds[0].pImmutableSamplers = null;
            binds[1].binding = 1u; binds[1].descriptorType = Vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            binds[1].descriptorCount = 1u; binds[1].stageFlags = Vk.SHADER_STAGE_FRAGMENT_BIT; binds[1].pImmutableSamplers = null;

            VkDescriptorSetLayoutCreateInfo lci;
            lci.sType = Vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO; lci.pNext = null; lci.flags = 0u;
            lci.bindingCount = 2u; lci.pBindings = (void*)binds;
            void* pl = Memory.Alloc(8);
            Check(Vk.vkCreateDescriptorSetLayout(Device, (void*)&lci, null, pl), "vkCreateDescriptorSetLayout");
            DescriptorSetLayout = *(void**)pl; Memory.Free(pl);

            VkDescriptorPoolSize psz;
            psz.type = Vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; psz.descriptorCount = 2u;
            VkDescriptorPoolCreateInfo pci;
            pci.sType = Vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO; pci.pNext = null; pci.flags = 0u;
            pci.maxSets = 1u; pci.poolSizeCount = 1u; pci.pPoolSizes = (void*)&psz;
            void* pp = Memory.Alloc(8);
            Check(Vk.vkCreateDescriptorPool(Device, (void*)&pci, null, pp), "vkCreateDescriptorPool");
            DescriptorPool = *(void**)pp; Memory.Free(pp);

            void* dsl = DescriptorSetLayout;
            VkDescriptorSetAllocateInfo dai;
            dai.sType = Vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO; dai.pNext = null;
            dai.descriptorPool = DescriptorPool; dai.descriptorSetCount = 1u; dai.pSetLayouts = (void*)&dsl;
            void* pset = Memory.Alloc(8);
            Check(Vk.vkAllocateDescriptorSets(Device, (void*)&dai, pset), "vkAllocateDescriptorSets");
            DescriptorSet = *(void**)pset; Memory.Free(pset);

            VkDescriptorImageInfo iiAtlas;
            iiAtlas.sampler = Sampler; iiAtlas.imageView = TextureView;
            iiAtlas.imageLayout = Vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

            VkDescriptorImageInfo iiShadow;
            iiShadow.sampler = ShadowSampler; iiShadow.imageView = ShadowView;
            iiShadow.imageLayout = Vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

            VkWriteDescriptorSet* wr = (VkWriteDescriptorSet*)Memory.Alloc(2 * (int)sizeof(VkWriteDescriptorSet));
            Memory.Set((void*)wr, 0, 2 * (long)sizeof(VkWriteDescriptorSet));
            wr[0].sType = Vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            wr[0].dstSet = DescriptorSet; wr[0].dstBinding = 0u; wr[0].dstArrayElement = 0u;
            wr[0].descriptorCount = 1u; wr[0].descriptorType = Vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            wr[0].pImageInfo = (void*)&iiAtlas;
            wr[1].sType = Vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            wr[1].dstSet = DescriptorSet; wr[1].dstBinding = 1u; wr[1].dstArrayElement = 0u;
            wr[1].descriptorCount = 1u; wr[1].descriptorType = Vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
            wr[1].pImageInfo = (void*)&iiShadow;
            Vk.vkUpdateDescriptorSets(Device, 2u, (void*)wr, 0u, null);
            Memory.Free((void*)wr);
        }

        // --- render pass (colour + depth) ----------------------------------
        func CreateRenderPass()
        {
            VkAttachmentDescription* atts = (VkAttachmentDescription*)Memory.Alloc(2 * (int)sizeof(VkAttachmentDescription));
            // colour
            atts[0].flags = 0u;
            atts[0].format = Format;
            atts[0].samples = Vk.SAMPLE_COUNT_1_BIT;
            atts[0].loadOp = Vk.ATTACHMENT_LOAD_OP_CLEAR;
            atts[0].storeOp = Vk.ATTACHMENT_STORE_OP_STORE;
            atts[0].stencilLoadOp = Vk.ATTACHMENT_LOAD_OP_DONT_CARE;
            atts[0].stencilStoreOp = Vk.ATTACHMENT_STORE_OP_DONT_CARE;
            atts[0].initialLayout = Vk.IMAGE_LAYOUT_UNDEFINED;
            atts[0].finalLayout = Vk.IMAGE_LAYOUT_PRESENT_SRC_KHR;
            // depth
            atts[1].flags = 0u;
            atts[1].format = DepthFormat;
            atts[1].samples = Vk.SAMPLE_COUNT_1_BIT;
            atts[1].loadOp = Vk.ATTACHMENT_LOAD_OP_CLEAR;
            atts[1].storeOp = Vk.ATTACHMENT_STORE_OP_DONT_CARE;
            atts[1].stencilLoadOp = Vk.ATTACHMENT_LOAD_OP_DONT_CARE;
            atts[1].stencilStoreOp = Vk.ATTACHMENT_STORE_OP_DONT_CARE;
            atts[1].initialLayout = Vk.IMAGE_LAYOUT_UNDEFINED;
            atts[1].finalLayout = Vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            VkAttachmentReference colorRef;
            colorRef.attachment = 0u;
            colorRef.layout = Vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

            VkAttachmentReference depthRef;
            depthRef.attachment = 1u;
            depthRef.layout = Vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

            VkSubpassDescription sub;
            sub.flags = 0u;
            sub.pipelineBindPoint = Vk.PIPELINE_BIND_POINT_GRAPHICS;
            sub.inputAttachmentCount = 0u; sub.pInputAttachments = null;
            sub.colorAttachmentCount = 1u; sub.pColorAttachments = (void*)&colorRef;
            sub.pResolveAttachments = null;
            sub.pDepthStencilAttachment = (void*)&depthRef;
            sub.preserveAttachmentCount = 0u; sub.pPreserveAttachments = null;

            VkRenderPassCreateInfo ci;
            ci.sType = Vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
            ci.pNext = null; ci.flags = 0u;
            ci.attachmentCount = 2u; ci.pAttachments = (void*)atts;
            ci.subpassCount = 1u; ci.pSubpasses = (void*)&sub;
            ci.dependencyCount = 0u; ci.pDependencies = null;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateRenderPass(Device, (void*)&ci, null, p), "vkCreateRenderPass");
            RenderPass = *(void**)p;
            Memory.Free(p);
        }

        // --- graphics pipeline ---------------------------------------------
        // Shaders live next to the executable so the game runs regardless of the
        // working directory (e.g. double-clicked from Explorer).
        func ComputeShaderDir()
        {
            byte* buf = (byte*)Memory.Alloc(1024);
            uint n = Soul.Platform.Win32.GetModuleFileNameA(null, buf, 1024u);
            int len = (int)n;
            int cut = 0;
            for (int i = 0; i < len; i++)
                if (buf[i] == (byte)92) cut = i;      // last backslash
            ShaderDir = String.FromBytes(buf, (long)(cut + 1));
            Memory.Free((void*)buf);
        }

        func LoadShaderModule(path: string) -> void*
        {
            byte* data;
            long length;
            if (!File.TryReadAllBytes(path, out data, out length))
                panic("Vulkan: could not read shader '" + path + "' (run soul/build.ps1 to compile shaders)");

            VkShaderModuleCreateInfo ci;
            ci.sType = Vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
            ci.pNext = null; ci.flags = 0u;
            ci.codeSize = (ulong)length;
            ci.pCode = (void*)data;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateShaderModule(Device, (void*)&ci, null, p), "vkCreateShaderModule(" + path + ")");
            void* m = *(void**)p;
            Memory.Free(p);
            return m;
        }

        func CreateGraphicsPipeline()
        {
            // shared pipeline layout (descriptor set + push constant: mvp + lightVP)
            VkPushConstantRange pcr0;
            pcr0.stageFlags = Vk.SHADER_STAGE_VERTEX_BIT;
            pcr0.offset = 0u; pcr0.size = 128u;

            void* dsl0 = DescriptorSetLayout;
            VkPipelineLayoutCreateInfo plci;
            plci.sType = Vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO; plci.pNext = null; plci.flags = 0u;
            plci.setLayoutCount = 1u; plci.pSetLayouts = (void*)&dsl0;
            plci.pushConstantRangeCount = 1u; plci.pPushConstantRanges = (void*)&pcr0;
            void* pl0 = Memory.Alloc(8);
            Check(Vk.vkCreatePipelineLayout(Device, (void*)&plci, null, pl0), "vkCreatePipelineLayout");
            PipelineLayout = *(void**)pl0; Memory.Free(pl0);

            GraphicsPipeline = BuildPipeline(ShaderDir + "cube.frag.spv", false, true);
            WaterPipeline    = BuildPipeline(ShaderDir + "water.frag.spv", true, false);
            ShadowPipeline   = BuildShadowPipeline();
        }

        // Depth-only pipeline that renders the scene from the sun into the shadow map.
        func BuildShadowPipeline() -> void*
        {
            void* vert = LoadShaderModule(ShaderDir + "shadow.vert.spv");
            let entry = "main";

            VkPipelineShaderStageCreateInfo stage;
            stage.sType = Vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stage.pNext = null; stage.flags = 0u;
            stage.stage = Vk.SHADER_STAGE_VERTEX_BIT;
            stage.module = vert; stage.pName = entry.Ptr; stage.pSpecializationInfo = null;

            VkVertexInputBindingDescription binding;
            binding.binding = 0u; binding.stride = 44u; binding.inputRate = Vk.VERTEX_INPUT_RATE_VERTEX;
            VkVertexInputAttributeDescription attr;
            attr.location = 0u; attr.binding = 0u; attr.format = Vk.FORMAT_R32G32B32_SFLOAT; attr.offset = 0u;

            VkPipelineVertexInputStateCreateInfo vin;
            vin.sType = Vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO; vin.pNext = null; vin.flags = 0u;
            vin.vertexBindingDescriptionCount = 1u; vin.pVertexBindingDescriptions = (void*)&binding;
            vin.vertexAttributeDescriptionCount = 1u; vin.pVertexAttributeDescriptions = (void*)&attr;

            VkPipelineInputAssemblyStateCreateInfo ia;
            ia.sType = Vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO; ia.pNext = null; ia.flags = 0u;
            ia.topology = Vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST; ia.primitiveRestartEnable = 0u;

            VkViewport vp;
            vp.x = 0.0f; vp.y = 0.0f; vp.width = (float)ShadowSize; vp.height = (float)ShadowSize;
            vp.minDepth = 0.0f; vp.maxDepth = 1.0f;
            VkRect2D sc;
            sc.offsetX = 0; sc.offsetY = 0; sc.extentW = (uint)ShadowSize; sc.extentH = (uint)ShadowSize;
            VkPipelineViewportStateCreateInfo vps;
            vps.sType = Vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO; vps.pNext = null; vps.flags = 0u;
            vps.viewportCount = 1u; vps.pViewports = (void*)&vp; vps.scissorCount = 1u; vps.pScissors = (void*)&sc;

            VkPipelineRasterizationStateCreateInfo rs;
            rs.sType = Vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO; rs.pNext = null; rs.flags = 0u;
            rs.depthClampEnable = 0u; rs.rasterizerDiscardEnable = 0u;
            rs.polygonMode = Vk.POLYGON_MODE_FILL; rs.cullMode = Vk.CULL_MODE_NONE; rs.frontFace = Vk.FRONT_FACE_CLOCKWISE;
            rs.depthBiasEnable = 1u;                       // bias to fight shadow acne
            rs.depthBiasConstantFactor = 1.5f; rs.depthBiasClamp = 0.0f; rs.depthBiasSlopeFactor = 2.5f;
            rs.lineWidth = 1.0f;

            VkPipelineMultisampleStateCreateInfo ms;
            ms.sType = Vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO; ms.pNext = null; ms.flags = 0u;
            ms.rasterizationSamples = Vk.SAMPLE_COUNT_1_BIT; ms.sampleShadingEnable = 0u; ms.minSampleShading = 0.0f;
            ms.pSampleMask = null; ms.alphaToCoverageEnable = 0u; ms.alphaToOneEnable = 0u;

            VkPipelineDepthStencilStateCreateInfo ds;
            Memory.Set((void*)&ds, 0, (long)sizeof(VkPipelineDepthStencilStateCreateInfo));
            ds.sType = Vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
            ds.depthTestEnable = 1u; ds.depthWriteEnable = 1u; ds.depthCompareOp = Vk.COMPARE_OP_LESS;
            ds.depthBoundsTestEnable = 0u; ds.stencilTestEnable = 0u;
            ds.minDepthBounds = 0.0f; ds.maxDepthBounds = 1.0f;

            VkPipelineColorBlendStateCreateInfo cb;
            cb.sType = Vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO; cb.pNext = null; cb.flags = 0u;
            cb.logicOpEnable = 0u; cb.logicOp = 0u; cb.attachmentCount = 0u; cb.pAttachments = null;
            cb.blendConstant0 = 0.0f; cb.blendConstant1 = 0.0f; cb.blendConstant2 = 0.0f; cb.blendConstant3 = 0.0f;

            VkGraphicsPipelineCreateInfo gp;
            gp.sType = Vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO; gp.pNext = null; gp.flags = 0u;
            gp.stageCount = 1u; gp.pStages = (void*)&stage;
            gp.pVertexInputState = (void*)&vin; gp.pInputAssemblyState = (void*)&ia;
            gp.pTessellationState = null; gp.pViewportState = (void*)&vps;
            gp.pRasterizationState = (void*)&rs; gp.pMultisampleState = (void*)&ms;
            gp.pDepthStencilState = (void*)&ds; gp.pColorBlendState = (void*)&cb; gp.pDynamicState = null;
            gp.layout = PipelineLayout; gp.renderPass = ShadowRenderPass; gp.subpass = 0u;
            gp.basePipelineHandle = null; gp.basePipelineIndex = -1;

            void* pp = Memory.Alloc(8);
            Check(Vk.vkCreateGraphicsPipelines(Device, null, 1u, (void*)&gp, null, pp), "vkCreateGraphicsPipelines(shadow)");
            void* pipe = *(void**)pp; Memory.Free(pp);
            return pipe;
        }

        func BuildPipeline(fragPath: string, blend: bool, depthWrite: bool) -> void*
        {
            void* vert = LoadShaderModule(ShaderDir + "cube.vert.spv");
            void* frag = LoadShaderModule(fragPath);
            let entry = "main";

            VkPipelineShaderStageCreateInfo* stages =
                (VkPipelineShaderStageCreateInfo*)Memory.Alloc(2 * (int)sizeof(VkPipelineShaderStageCreateInfo));
            stages[0].sType = Vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[0].pNext = null; stages[0].flags = 0u;
            stages[0].stage = Vk.SHADER_STAGE_VERTEX_BIT;
            stages[0].module = vert; stages[0].pName = entry.Ptr; stages[0].pSpecializationInfo = null;
            stages[1].sType = Vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[1].pNext = null; stages[1].flags = 0u;
            stages[1].stage = Vk.SHADER_STAGE_FRAGMENT_BIT;
            stages[1].module = frag; stages[1].pName = entry.Ptr; stages[1].pSpecializationInfo = null;

            // vertex input: binding 0 = [pos vec3][color vec3], stride 24
            VkVertexInputBindingDescription binding;
            binding.binding = 0u; binding.stride = 44u; binding.inputRate = Vk.VERTEX_INPUT_RATE_VERTEX;

            VkVertexInputAttributeDescription* attrs =
                (VkVertexInputAttributeDescription*)Memory.Alloc(4 * (int)sizeof(VkVertexInputAttributeDescription));
            attrs[0].location = 0u; attrs[0].binding = 0u; attrs[0].format = Vk.FORMAT_R32G32B32_SFLOAT; attrs[0].offset = 0u;
            attrs[1].location = 1u; attrs[1].binding = 0u; attrs[1].format = Vk.FORMAT_R32G32B32_SFLOAT; attrs[1].offset = 12u;
            attrs[2].location = 2u; attrs[2].binding = 0u; attrs[2].format = Vk.FORMAT_R32G32B32_SFLOAT; attrs[2].offset = 24u;
            attrs[3].location = 3u; attrs[3].binding = 0u; attrs[3].format = Vk.FORMAT_R32G32_SFLOAT;    attrs[3].offset = 36u;

            VkPipelineVertexInputStateCreateInfo vin;
            vin.sType = Vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
            vin.pNext = null; vin.flags = 0u;
            vin.vertexBindingDescriptionCount = 1u; vin.pVertexBindingDescriptions = (void*)&binding;
            vin.vertexAttributeDescriptionCount = 4u; vin.pVertexAttributeDescriptions = (void*)attrs;

            VkPipelineInputAssemblyStateCreateInfo ia;
            ia.sType = Vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
            ia.pNext = null; ia.flags = 0u;
            ia.topology = Vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
            ia.primitiveRestartEnable = 0u;

            VkViewport vp;
            vp.x = 0.0f; vp.y = 0.0f;
            vp.width = (float)ExtentW; vp.height = (float)ExtentH;
            vp.minDepth = 0.0f; vp.maxDepth = 1.0f;

            VkRect2D sc;
            sc.offsetX = 0; sc.offsetY = 0; sc.extentW = ExtentW; sc.extentH = ExtentH;

            VkPipelineViewportStateCreateInfo vps;
            vps.sType = Vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
            vps.pNext = null; vps.flags = 0u;
            vps.viewportCount = 1u; vps.pViewports = (void*)&vp;
            vps.scissorCount = 1u; vps.pScissors = (void*)&sc;

            VkPipelineRasterizationStateCreateInfo rs;
            rs.sType = Vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
            rs.pNext = null; rs.flags = 0u;
            rs.depthClampEnable = 0u; rs.rasterizerDiscardEnable = 0u;
            rs.polygonMode = Vk.POLYGON_MODE_FILL;
            rs.cullMode = Vk.CULL_MODE_NONE;
            rs.frontFace = Vk.FRONT_FACE_CLOCKWISE;
            rs.depthBiasEnable = 0u;
            rs.depthBiasConstantFactor = 0.0f; rs.depthBiasClamp = 0.0f; rs.depthBiasSlopeFactor = 0.0f;
            rs.lineWidth = 1.0f;

            VkPipelineMultisampleStateCreateInfo ms;
            ms.sType = Vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
            ms.pNext = null; ms.flags = 0u;
            ms.rasterizationSamples = Vk.SAMPLE_COUNT_1_BIT;
            ms.sampleShadingEnable = 0u; ms.minSampleShading = 0.0f;
            ms.pSampleMask = null; ms.alphaToCoverageEnable = 0u; ms.alphaToOneEnable = 0u;

            VkPipelineDepthStencilStateCreateInfo ds;
            Memory.Set((void*)&ds, 0, (long)sizeof(VkPipelineDepthStencilStateCreateInfo));
            ds.sType = Vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
            ds.depthTestEnable = 1u;
            ds.depthWriteEnable = depthWrite ? 1u : 0u;
            ds.depthCompareOp = Vk.COMPARE_OP_LESS;
            ds.depthBoundsTestEnable = 0u;
            ds.stencilTestEnable = 0u;
            ds.minDepthBounds = 0.0f; ds.maxDepthBounds = 1.0f;

            VkPipelineColorBlendAttachmentState cba;
            if (blend)
            {
                cba.blendEnable = 1u;
                cba.srcColorBlendFactor = 6u;   // SRC_ALPHA
                cba.dstColorBlendFactor = 7u;   // ONE_MINUS_SRC_ALPHA
                cba.colorBlendOp = 0u;          // ADD
                cba.srcAlphaBlendFactor = 1u;   // ONE
                cba.dstAlphaBlendFactor = 0u;   // ZERO
                cba.alphaBlendOp = 0u;
            }
            else
            {
                cba.blendEnable = 0u;
                cba.srcColorBlendFactor = 0u; cba.dstColorBlendFactor = 0u; cba.colorBlendOp = 0u;
                cba.srcAlphaBlendFactor = 0u; cba.dstAlphaBlendFactor = 0u; cba.alphaBlendOp = 0u;
            }
            cba.colorWriteMask = Vk.COLOR_COMPONENT_RGBA;

            VkPipelineColorBlendStateCreateInfo cb;
            cb.sType = Vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
            cb.pNext = null; cb.flags = 0u;
            cb.logicOpEnable = 0u; cb.logicOp = 0u;
            cb.attachmentCount = 1u; cb.pAttachments = (void*)&cba;
            cb.blendConstant0 = 0.0f; cb.blendConstant1 = 0.0f; cb.blendConstant2 = 0.0f; cb.blendConstant3 = 0.0f;

            VkGraphicsPipelineCreateInfo gp;
            gp.sType = Vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
            gp.pNext = null; gp.flags = 0u;
            gp.stageCount = 2u; gp.pStages = (void*)stages;
            gp.pVertexInputState = (void*)&vin;
            gp.pInputAssemblyState = (void*)&ia;
            gp.pTessellationState = null;
            gp.pViewportState = (void*)&vps;
            gp.pRasterizationState = (void*)&rs;
            gp.pMultisampleState = (void*)&ms;
            gp.pDepthStencilState = (void*)&ds;
            gp.pColorBlendState = (void*)&cb;
            gp.pDynamicState = null;
            gp.layout = PipelineLayout;
            gp.renderPass = RenderPass;
            gp.subpass = 0u;
            gp.basePipelineHandle = null;
            gp.basePipelineIndex = -1;

            void* pp = Memory.Alloc(8);
            Check(Vk.vkCreateGraphicsPipelines(Device, null, 1u, (void*)&gp, null, pp), "vkCreateGraphicsPipelines");
            void* pipe = *(void**)pp;
            Memory.Free(pp);
            return pipe;
        }

        // --- framebuffers (colour + depth) ---------------------------------
        func CreateFramebuffers()
        {
            Framebuffers = Memory.Alloc(ImageCount * 8);
            for (int i = 0; i < ImageCount; i++)
            {
                void** att = (void**)Memory.Alloc(16);
                att[0] = ((void**)ImageViews)[i];
                att[1] = DepthView;

                VkFramebufferCreateInfo ci;
                ci.sType = Vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
                ci.pNext = null; ci.flags = 0u;
                ci.renderPass = RenderPass;
                ci.attachmentCount = 2u;
                ci.pAttachments = (void*)att;
                ci.width = ExtentW; ci.height = ExtentH; ci.layers = 1u;

                void* p = Memory.Alloc(8);
                Check(Vk.vkCreateFramebuffer(Device, (void*)&ci, null, p), "vkCreateFramebuffer");
                ((void**)Framebuffers)[i] = *(void**)p;
                Memory.Free(p);
            }
        }

        // --- command buffers ------------------------------------------------
        func CreateCommandBuffers()
        {
            VkCommandPoolCreateInfo pci;
            pci.sType = Vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
            pci.pNext = null;
            pci.flags = Vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
            pci.queueFamilyIndex = QueueFamilyIndex;

            void* pp = Memory.Alloc(8);
            Check(Vk.vkCreateCommandPool(Device, (void*)&pci, null, pp), "vkCreateCommandPool");
            CommandPool = *(void**)pp;
            Memory.Free(pp);

            CommandBuffers = Memory.Alloc(ImageCount * 8);
            VkCommandBufferAllocateInfo ai;
            ai.sType = Vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            ai.pNext = null;
            ai.commandPool = CommandPool;
            ai.level = Vk.COMMAND_BUFFER_LEVEL_PRIMARY;
            ai.commandBufferCount = (uint)ImageCount;
            Check(Vk.vkAllocateCommandBuffers(Device, (void*)&ai, CommandBuffers), "vkAllocateCommandBuffers");
        }

        // --- sync -----------------------------------------------------------
        func CreateSyncObjects()
        {
            VkSemaphoreCreateInfo sci;
            sci.sType = Vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
            sci.pNext = null; sci.flags = 0u;

            void* p1 = Memory.Alloc(8);
            Check(Vk.vkCreateSemaphore(Device, (void*)&sci, null, p1), "vkCreateSemaphore");
            ImageAvailable = *(void**)p1; Memory.Free(p1);

            void* p2 = Memory.Alloc(8);
            Check(Vk.vkCreateSemaphore(Device, (void*)&sci, null, p2), "vkCreateSemaphore");
            RenderFinished = *(void**)p2; Memory.Free(p2);

            VkFenceCreateInfo fci;
            fci.sType = Vk.STRUCTURE_TYPE_FENCE_CREATE_INFO;
            fci.pNext = null; fci.flags = Vk.FENCE_CREATE_SIGNALED_BIT;

            void* p3 = Memory.Alloc(8);
            Check(Vk.vkCreateFence(Device, (void*)&fci, null, p3), "vkCreateFence");
            InFlight = *(void**)p3; Memory.Free(p3);
        }

        // --- mesh creation (host-visible buffers) --------------------------
        func CreateHostBuffer(sizeBytes: ulong, usage: uint, memOut: void**) -> void*
        {
            VkBufferCreateInfo bi;
            bi.sType = Vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO;
            bi.pNext = null; bi.flags = 0u;
            bi.size = sizeBytes;
            bi.usage = usage;
            bi.sharingMode = Vk.SHARING_MODE_EXCLUSIVE;
            bi.queueFamilyIndexCount = 0u; bi.pQueueFamilyIndices = null;

            void* p = Memory.Alloc(8);
            Check(Vk.vkCreateBuffer(Device, (void*)&bi, null, p), "vkCreateBuffer");
            void* buf = *(void**)p;
            Memory.Free(p);

            VkMemoryRequirements req;
            Vk.vkGetBufferMemoryRequirements(Device, buf, (void*)&req);

            VkMemoryAllocateInfo ai;
            ai.sType = Vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            ai.pNext = null;
            ai.allocationSize = req.size;
            ai.memoryTypeIndex = FindMemoryType(req.memoryTypeBits,
                Vk.MEMORY_PROPERTY_HOST_VISIBLE | Vk.MEMORY_PROPERTY_HOST_COHERENT);

            void* pm = Memory.Alloc(8);
            Check(Vk.vkAllocateMemory(Device, (void*)&ai, null, pm), "vkAllocateMemory");
            void* mem = *(void**)pm;
            Memory.Free(pm);

            Check(Vk.vkBindBufferMemory(Device, buf, mem, 0UL), "vkBindBufferMemory");
            *memOut = mem;
            return buf;
        }

        func UploadBytes(mem: void*, src: void*, sizeBytes: long)
        {
            void* pp = Memory.Alloc(8);
            Check(Vk.vkMapMemory(Device, mem, 0UL, (ulong)sizeBytes, 0u, pp), "vkMapMemory");
            void* dst = *(void**)pp;
            Memory.Copy(dst, src, sizeBytes);
            Vk.vkUnmapMemory(Device, mem);
            Memory.Free(pp);
        }

        public func CreateMesh(mb: MeshBuilder) -> Mesh
        {
            var mesh = new Mesh();
            long vbytes = mb.VertexBytes();
            long ibytes = mb.IndexBytes();

            void* vmem;
            mesh.VertexBuffer = CreateHostBuffer((ulong)vbytes, Vk.BUFFER_USAGE_VERTEX_BUFFER, (void**)&vmem);
            mesh.VertexMemory = vmem;
            UploadBytes(mesh.VertexMemory, (void*)mb.VertexPtr(), vbytes);

            void* imem;
            mesh.IndexBuffer = CreateHostBuffer((ulong)ibytes, Vk.BUFFER_USAGE_INDEX_BUFFER, (void**)&imem);
            mesh.IndexMemory = imem;
            UploadBytes(mesh.IndexMemory, (void*)mb.IndexPtr(), ibytes);

            mesh.IndexCount = mb.IndexCount;
            return mesh;
        }

        // Upload the given CPU geometry into the persistent dynamic buffers.
        func UpdateDynamic(mb: MeshBuilder)
        {
            int ic = mb.IndexCount;
            if (ic == 0 || mb.VertCount > DynCapV || ic > DynCapI) { DynIndexCount = 0; return; }
            UploadBytes(DynVM, (void*)mb.VertexPtr(), mb.VertexBytes());
            UploadBytes(DynIM, (void*)mb.IndexPtr(), mb.IndexBytes());
            DynIndexCount = ic;
        }

        // --- per-frame rendering -------------------------------------------
        func RecordFrame(imageIndex: uint)
        {
            void* cmd = ((void**)CommandBuffers)[(int)imageIndex];
            void* fb  = ((void**)Framebuffers)[(int)imageIndex];

            VkCommandBufferBeginInfo bi;
            bi.sType = Vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
            bi.pNext = null; bi.flags = 0u; bi.pInheritanceInfo = null;
            Check(Vk.vkBeginCommandBuffer(cmd, (void*)&bi), "vkBeginCommandBuffer");

            // --- shadow pass: render opaque geometry depth from the sun ---
            VkClearValue sdc; sdc.r = 1.0f; sdc.g = 0.0f; sdc.b = 0.0f; sdc.a = 0.0f;
            VkRenderPassBeginInfo srbi;
            srbi.sType = Vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO; srbi.pNext = null;
            srbi.renderPass = ShadowRenderPass; srbi.framebuffer = ShadowFramebuffer;
            srbi.renderAreaOffsetX = 0; srbi.renderAreaOffsetY = 0;
            srbi.renderAreaExtentW = (uint)ShadowSize; srbi.renderAreaExtentH = (uint)ShadowSize;
            srbi.clearValueCount = 1u; srbi.pClearValues = (void*)&sdc;

            Vk.vkCmdBeginRenderPass(cmd, (void*)&srbi, Vk.SUBPASS_CONTENTS_INLINE);
            Vk.vkCmdBindPipeline(cmd, Vk.PIPELINE_BIND_POINT_GRAPHICS, ShadowPipeline);
            Vk.vkCmdPushConstants(cmd, PipelineLayout, Vk.SHADER_STAGE_VERTEX_BIT, 0u, 128u, (void*)PushData);
            for (int i = 0; i < Meshes.Count; i++)
            {
                var sm = Meshes[i];
                if (sm == null || sm.IndexCount == 0) continue;
                void* vb = sm.VertexBuffer; ulong off = 0UL;
                Vk.vkCmdBindVertexBuffers(cmd, 0u, 1u, (void*)&vb, (void*)&off);
                Vk.vkCmdBindIndexBuffer(cmd, sm.IndexBuffer, 0UL, Vk.INDEX_TYPE_UINT32);
                Vk.vkCmdDrawIndexed(cmd, (uint)sm.IndexCount, 1u, 0u, 0, 0u);
            }
            Vk.vkCmdEndRenderPass(cmd);

            // make shadow depth writes visible to fragment sampling in the main pass
            VkImageMemoryBarrier sb;
            sb.sType = Vk.STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER; sb.pNext = null;
            sb.srcAccessMask = Vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE; sb.dstAccessMask = Vk.ACCESS_SHADER_READ_BIT;
            sb.oldLayout = Vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL; sb.newLayout = Vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            sb.srcQueueFamilyIndex = Vk.QUEUE_FAMILY_IGNORED; sb.dstQueueFamilyIndex = Vk.QUEUE_FAMILY_IGNORED;
            sb.image = ShadowImage;
            sb.aspectMask = Vk.IMAGE_ASPECT_DEPTH_BIT; sb.baseMipLevel = 0u; sb.levelCount = 1u;
            sb.baseArrayLayer = 0u; sb.layerCount = 1u;
            Vk.vkCmdPipelineBarrier(cmd, Vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS, Vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                                    0u, 0u, null, 0u, null, 1u, (void*)&sb);

            VkClearValue* clears = (VkClearValue*)Memory.Alloc(2 * 16);
            clears[0].r = ClearR; clears[0].g = ClearG; clears[0].b = ClearB; clears[0].a = 1.0f;
            clears[1].r = 1.0f;   clears[1].g = 0.0f;   clears[1].b = 0.0f;   clears[1].a = 0.0f;  // depth=1, stencil=0

            VkRenderPassBeginInfo rbi;
            rbi.sType = Vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
            rbi.pNext = null;
            rbi.renderPass = RenderPass;
            rbi.framebuffer = fb;
            rbi.renderAreaOffsetX = 0; rbi.renderAreaOffsetY = 0;
            rbi.renderAreaExtentW = ExtentW; rbi.renderAreaExtentH = ExtentH;
            rbi.clearValueCount = 2u;
            rbi.pClearValues = (void*)clears;

            Vk.vkCmdBeginRenderPass(cmd, (void*)&rbi, Vk.SUBPASS_CONTENTS_INLINE);
            Vk.vkCmdBindPipeline(cmd, Vk.PIPELINE_BIND_POINT_GRAPHICS, GraphicsPipeline);
            void* ds = DescriptorSet;
            Vk.vkCmdBindDescriptorSets(cmd, Vk.PIPELINE_BIND_POINT_GRAPHICS, PipelineLayout, 0u, 1u, (void*)&ds, 0u, null);
            Vk.vkCmdPushConstants(cmd, PipelineLayout, Vk.SHADER_STAGE_VERTEX_BIT, 0u, 128u, (void*)PushData);

            for (int i = 0; i < Meshes.Count; i++)
            {
                var mesh = Meshes[i];
                if (mesh == null || mesh.IndexCount == 0) continue;
                void* vb = mesh.VertexBuffer;
                ulong off = 0UL;
                Vk.vkCmdBindVertexBuffers(cmd, 0u, 1u, (void*)&vb, (void*)&off);
                Vk.vkCmdBindIndexBuffer(cmd, mesh.IndexBuffer, 0UL, Vk.INDEX_TYPE_UINT32);
                Vk.vkCmdDrawIndexed(cmd, (uint)mesh.IndexCount, 1u, 0u, 0, 0u);
            }

            // particles (opaque pipeline still bound)
            if (DynIndexCount > 0)
            {
                void* dvb = DynVB; ulong doff = 0UL;
                Vk.vkCmdBindVertexBuffers(cmd, 0u, 1u, (void*)&dvb, (void*)&doff);
                Vk.vkCmdBindIndexBuffer(cmd, DynIB, 0UL, Vk.INDEX_TYPE_UINT32);
                Vk.vkCmdDrawIndexed(cmd, (uint)DynIndexCount, 1u, 0u, 0, 0u);
            }

            // translucent water pass (same layout: descriptor set + push constants stay bound)
            Vk.vkCmdBindPipeline(cmd, Vk.PIPELINE_BIND_POINT_GRAPHICS, WaterPipeline);
            for (int i = 0; i < WaterMeshes.Count; i++)
            {
                var wm = WaterMeshes[i];
                if (wm == null || wm.IndexCount == 0) continue;
                void* vb = wm.VertexBuffer;
                ulong off = 0UL;
                Vk.vkCmdBindVertexBuffers(cmd, 0u, 1u, (void*)&vb, (void*)&off);
                Vk.vkCmdBindIndexBuffer(cmd, wm.IndexBuffer, 0UL, Vk.INDEX_TYPE_UINT32);
                Vk.vkCmdDrawIndexed(cmd, (uint)wm.IndexCount, 1u, 0u, 0, 0u);
            }

            Vk.vkCmdEndRenderPass(cmd);
            Check(Vk.vkEndCommandBuffer(cmd), "vkEndCommandBuffer");
            Memory.Free((void*)clears);
        }

        public func DrawFrame(eye: Vec3, center: Vec3, particles: MeshBuilder)
        {
            void* fence = InFlight;
            Vk.vkWaitForFences(Device, 1u, (void*)&fence, 1u, Vk.UINT64_MAX);
            Vk.vkResetFences(Device, 1u, (void*)&fence);

            UpdateDynamic(particles);   // GPU is idle for this frame-in-flight now

            uint index = 0u;
            Vk.vkAcquireNextImageKHR(Device, Swapchain, Vk.UINT64_MAX, ImageAvailable, null, (void*)&index);

            Mat.LookAt(eye, center, new Vec3(0.0f, 1.0f, 0.0f), View);
            Mat.Mul(Proj, View, Mvp);

            // sun light matrix: orthographic, centred on the camera
            float D = 130.0f;
            float H = 75.0f;
            var sun = new Vec3(SunX, SunY, SunZ);
            var lightEye = eye - sun * D;
            Mat.LookAt(lightEye, eye, new Vec3(0.0f, 1.0f, 0.0f), LightView);
            Mat.Ortho(-H, H, -H, H, 1.0f, 2.0f * D + 60.0f, LightProj);
            Mat.Mul(LightProj, LightView, LightVP);

            for (int i = 0; i < 16; i++) PushData[i] = Mvp[i];
            for (int i = 0; i < 16; i++) PushData[16 + i] = LightVP[i];
            RecordFrame(index);

            void* waitSem   = ImageAvailable;
            void* signalSem = RenderFinished;
            uint  waitStage = Vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT;
            void* cmd       = ((void**)CommandBuffers)[(int)index];

            VkSubmitInfo si;
            si.sType = Vk.STRUCTURE_TYPE_SUBMIT_INFO;
            si.pNext = null;
            si.waitSemaphoreCount = 1u;
            si.pWaitSemaphores = (void*)&waitSem;
            si.pWaitDstStageMask = (void*)&waitStage;
            si.commandBufferCount = 1u;
            si.pCommandBuffers = (void*)&cmd;
            si.signalSemaphoreCount = 1u;
            si.pSignalSemaphores = (void*)&signalSem;
            Check(Vk.vkQueueSubmit(GraphicsQueue, 1u, (void*)&si, fence), "vkQueueSubmit");

            void* swapchain = Swapchain;
            VkPresentInfoKHR pi;
            pi.sType = Vk.STRUCTURE_TYPE_PRESENT_INFO_KHR;
            pi.pNext = null;
            pi.waitSemaphoreCount = 1u;
            pi.pWaitSemaphores = (void*)&signalSem;
            pi.swapchainCount = 1u;
            pi.pSwapchains = (void*)&swapchain;
            pi.pImageIndices = (void*)&index;
            pi.pResults = null;
            Vk.vkQueuePresentKHR(GraphicsQueue, (void*)&pi);
        }

        public func WaitIdle() { Vk.vkDeviceWaitIdle(Device); }
    }
}
