// =============================================================================
//  Renderizador 2D sobre Vulkan para la interfaz de FasetStudio.
//
//  Todo (rectángulos y texto) se dibuja con un único pipeline: triángulos con
//  posición, coordenada de textura y color, y una textura atlas de cobertura.
//  Los recortes (clip) se implementan con scissor por lote de dibujo.
//
//  Modos: ventana (swapchain sobre X11) o fuera de pantalla (para capturas/pruebas).
// =============================================================================
using std.collections;
using std.io;
using std.text;
using FasetStudio.Platform;

namespace FasetStudio.Gfx
{
    public struct Color
    {
        public float R;
        public float G;
        public float B;
        public float A;

        public Color(float r, float g, float b, float a) { R = r; G = g; B = b; A = a; }

        // 0xRRGGBB
        public static Color Hex(uint rgb) => new Color(((rgb >> 16) & 255) / 255.0f, ((rgb >> 8) & 255) / 255.0f, (rgb & 255) / 255.0f, 1);
        public static Color Hex(uint rgb, float alpha)
        {
            Color c = Hex(rgb);
            c.A = alpha;
            return c;
        }
    }

    struct Vertex
    {
        public float X;
        public float Y;
        public float U;
        public float V;
        public float R;
        public float G;
        public float B;
        public float A;
        public float LocalX;    // posición respecto al centro de la forma
        public float LocalY;
        public float HalfW;     // semitamaño de la forma
        public float HalfH;
        public float Radius;    // < 0: texto / textura
        public float Border;    // > 0: solo el contorno
        public float Soft;      // difuminado (sombras)
        public float Pad;
    }

    struct DrawCmd
    {
        public int First;
        public int Count;
        public VkRect2D Clip;
    }

    public memory_unsafe class Renderer
    {
        const int MaxVertices = 400000;

        // Vulkan
        void* instance;
        void* physical;
        void* device;
        void* queue;
        uint queueFamily;
        byte* memProps;
        ulong surface;
        ulong swapchain;
        int imageCount;
        ulong* images;
        ulong* views;
        ulong* framebuffers;
        int colorFormat;
        ulong renderPass;
        ulong descriptorLayout;
        ulong pipelineLayout;
        ulong pipeline;
        ulong descriptorPool;
        ulong descriptorSet;
        ulong sampler;
        ulong atlasImage;
        ulong atlasMemory;
        ulong atlasView;
        bool atlasReady;
        // Imagen RGBA de hasta ImageSize x ImageSize (pantalla del dispositivo Android).
        public const int ImageSize = 1024;
        ulong imageSampler;
        ulong imageTex;
        ulong imageMemory;
        ulong imageView;
        bool imageReady;
        bool imageDirty;
        ulong imageStaging;
        ulong imageStagingMemory;
        byte* imageMapped;
        public int ImageWidth;
        public int ImageHeight;
        ulong stagingBuffer;
        ulong stagingMemory;
        void* stagingMapped;
        ulong vertexBuffer;
        ulong vertexMemory;
        Vertex* vertices;
        ulong commandPool;
        void* cmd;
        ulong imageAvailable;
        ulong renderFinished;
        ulong inFlight;

        // Fuera de pantalla
        bool offscreen;
        ulong offImage;
        ulong offMemory;
        ulong readbackBuffer;
        ulong readbackMemory;

        Window window;
        int width;
        int height;
        uint currentImage;
        bool needsRecreate;

        // Lote del fotograma actual
        int vertexCount;
        List<DrawCmd> commands = new List<DrawCmd>();
        List<VkRect2D> clipStack = new List<VkRect2D>();
        VkClearColor clear;

        public Atlas Atlas;
        public Font Code;        // fuente monoespaciada (editor)
        public Font CodeBold;
        public Font CodeItalic;
        public Font Ui;          // fuente de la interfaz
        public Font UiBold;
        public Font UiSmall;
        public Font Icons;       // símbolos (▸ ▾ ▶ ■ × ●)
        public Font Title;       // títulos grandes
        Dictionary<int, Glyph> logos = new Dictionary<int, Glyph>();
        public string DeviceName = "";
        public string Error = "";

        public int Width => width;
        public int Height => height;

        // ------------------------------------------------------------------ inicialización

        bool Fail(string message)
        {
            Error = message;
            return false;
        }

        public bool InitWindow(Window win)
        {
            window = win;
            width = win.Width;
            height = win.Height;
            return Init(false);
        }

        public bool InitOffscreen(int w, int h)
        {
            width = w;
            height = h;
            return Init(true);
        }

        bool Init(bool headless)
        {
            offscreen = headless;
#if WINDOWS
            if (faset_vk_load() == 0)
                return Fail("No se encontró Vulkan (vulkan-1.dll).\n\nFasetStudio dibuja con Vulkan: instala o actualiza el controlador de tu tarjeta gráfica (NVIDIA, AMD o Intel) y vuelve a abrirlo.");
#endif
            if (!CreateInstance()) return false;
            if (!offscreen)
            {
#if WINDOWS
                VkWin32SurfaceCreateInfoKHR si = new VkWin32SurfaceCreateInfoKHR();
                si.sType = VK.ST_WIN32_SURFACE_CREATE_INFO_KHR;
                si.hinstance = User32.GetModuleHandleW(null);
                si.hwnd = window.Hwnd;
                if (vkCreateWin32SurfaceKHR(instance, &si, null, &surface) != VK.SUCCESS)
                    return Fail("no se pudo crear la superficie Vulkan para la ventana");
#else
                VkXlibSurfaceCreateInfoKHR si = new VkXlibSurfaceCreateInfoKHR();
                si.sType = VK.ST_XLIB_SURFACE_CREATE_INFO_KHR;
                si.dpy = window.Display;
                si.window = window.Handle;
                if (vkCreateXlibSurfaceKHR(instance, &si, null, &surface) != VK.SUCCESS)
                    return Fail("no se pudo crear la superficie Vulkan para la ventana");
#endif
            }
            if (!PickDevice()) return false;
            if (!CreateDevice()) return false;
            colorFormat = offscreen ? VK.FORMAT_R8G8B8A8_UNORM : ChooseSurfaceFormat();
            if (!CreateRenderPass()) return false;
            if (offscreen ? !CreateOffscreenTarget() : !CreateSwapchain()) return false;
            if (!CreatePipeline()) return false;
            if (!CreateResources()) return false;
            if (!LoadFonts()) return false;
            return true;
        }

        bool CreateInstance()
        {
            VkApplicationInfo app = new VkApplicationInfo();
            app.sType = VK.ST_APPLICATION_INFO;
            app.pApplicationName = "FasetStudio".Ptr;
            app.pEngineName = "Faset".Ptr;
            app.apiVersion = VK.ApiVersion10;
            byte** exts = new byte*[2];
            exts[0] = "VK_KHR_surface".Ptr;
#if WINDOWS
            exts[1] = "VK_KHR_win32_surface".Ptr;
#else
            exts[1] = "VK_KHR_xlib_surface".Ptr;
#endif
            VkInstanceCreateInfo ci = new VkInstanceCreateInfo();
            ci.sType = VK.ST_INSTANCE_CREATE_INFO;
            ci.pApplicationInfo = &app;
            ci.enabledExtensionCount = offscreen ? 0u : 2u;
            ci.ppEnabledExtensionNames = exts;
            int r = vkCreateInstance(&ci, null, &instance);
            delete[] exts;
            if (r != VK.SUCCESS) return Fail("no se pudo crear la instancia de Vulkan (¿hay un driver instalado?)");
            return true;
        }

        bool PickDevice()
        {
            uint count = 0;
            vkEnumeratePhysicalDevices(instance, &count, null);
            if (count == 0) return Fail("no hay ninguna GPU compatible con Vulkan");
            void** devices = new void*[count];
            vkEnumeratePhysicalDevices(instance, &count, devices);
            string want = Environment.GetVariable("FASET_STUDIO_GPU");   // "cpu" fuerza lavapipe
            byte* props = (byte*)Memory.AllocZeroed(1024);
            int bestScore = -1;
            for (uint i = 0; i < count; i++)
            {
                uint families = 0;
                vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, null);
                VkQueueFamilyProperties* fam = Memory.New<VkQueueFamilyProperties>(families);
                vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &families, fam);
                int family = -1;
                for (uint f = 0; f < families && family < 0; f++)
                {
                    if ((fam[f].queueFlags & VK.QUEUE_GRAPHICS) == 0) continue;
                    uint present = 1;
                    if (!offscreen) vkGetPhysicalDeviceSurfaceSupportKHR(devices[i], f, surface, &present);
                    if (present != 0) family = (int)f;
                }
                Memory.Free(fam);
                if (family < 0) continue;
                vkGetPhysicalDeviceProperties(devices[i], props);
                int type = *(int*)(props + 16);  // 1 integrada, 2 dedicada, 3 virtual, 4 CPU
                int score = type == 2 ? 30 : type == 1 ? 20 : type == 3 ? 10 : 5;
                if (want == "cpu" && type == 4) score = 100;
                if (score > bestScore)
                {
                    bestScore = score;
                    physical = devices[i];
                    queueFamily = (uint)family;
                    DeviceName = String.Copy(String.FromCString(props + 20));
                }
            }
            String.Free(want);
            Memory.Free(props);
            delete[] devices;
            if (physical == null) return Fail("ninguna GPU puede dibujar en esta ventana");
            memProps = (byte*)Memory.AllocZeroed(520);
            vkGetPhysicalDeviceMemoryProperties(physical, memProps);
            return true;
        }

        bool CreateDevice()
        {
            float* priority = new float[1];
            priority[0] = 1;
            VkDeviceQueueCreateInfo qi = new VkDeviceQueueCreateInfo();
            qi.sType = VK.ST_DEVICE_QUEUE_CREATE_INFO;
            qi.queueFamilyIndex = queueFamily;
            qi.queueCount = 1;
            qi.pQueuePriorities = priority;
            byte** exts = new byte*[1];
            exts[0] = "VK_KHR_swapchain".Ptr;
            VkDeviceCreateInfo di = new VkDeviceCreateInfo();
            di.sType = VK.ST_DEVICE_CREATE_INFO;
            di.queueCreateInfoCount = 1;
            di.pQueueCreateInfos = &qi;
            di.enabledExtensionCount = offscreen ? 0u : 1u;
            di.ppEnabledExtensionNames = exts;
            int r = vkCreateDevice(physical, &di, null, &device);
            delete[] exts;
            delete[] priority;
            if (r != VK.SUCCESS) return Fail("no se pudo crear el dispositivo Vulkan");
            vkGetDeviceQueue(device, queueFamily, 0, &queue);
            return true;
        }

        int FindMemory(uint typeBits, uint flags)
        {
            uint count = *(uint*)memProps;
            for (uint i = 0; i < count; i++)
            {
                uint props = *(uint*)(memProps + 4 + i * 8);
                if ((typeBits & (1u << (int)i)) != 0 && (props & flags) == flags) return (int)i;
            }
            return -1;
        }

        int ChooseSurfaceFormat()
        {
            uint count = 0;
            vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, null);
            VkSurfaceFormatKHR* formats = Memory.New<VkSurfaceFormatKHR>(count);
            vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, formats);
            int chosen = count > 0 ? formats[0].format : VK.FORMAT_B8G8R8A8_UNORM;
            for (uint i = 0; i < count; i++)
                if (formats[i].format == VK.FORMAT_B8G8R8A8_UNORM || formats[i].format == VK.FORMAT_R8G8B8A8_UNORM)
                {
                    chosen = formats[i].format;
                    break;
                }
            Memory.Free(formats);
            return chosen;
        }

        bool CreateRenderPass()
        {
            VkAttachmentDescription att = new VkAttachmentDescription();
            att.format = colorFormat;
            att.samples = 1;
            att.loadOp = 1;          // CLEAR
            att.storeOp = 0;         // STORE
            att.stencilLoadOp = 2;   // DONT_CARE
            att.stencilStoreOp = 1;  // DONT_CARE
            att.initialLayout = VK.LAYOUT_UNDEFINED;
            att.finalLayout = offscreen ? VK.LAYOUT_TRANSFER_SRC_OPTIMAL : VK.LAYOUT_PRESENT_SRC_KHR;
            VkAttachmentReference colorRef = new VkAttachmentReference();
            colorRef.attachment = 0;
            colorRef.layout = VK.LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            VkSubpassDescription sub = new VkSubpassDescription();
            sub.pipelineBindPoint = 0;
            sub.colorAttachmentCount = 1;
            sub.pColorAttachments = &colorRef;
            VkSubpassDependency dep = new VkSubpassDependency();
            dep.srcSubpass = VK.SUBPASS_EXTERNAL;
            dep.dstSubpass = 0;
            dep.srcStageMask = VK.STAGE_COLOR_ATTACHMENT_OUTPUT;
            dep.dstStageMask = VK.STAGE_COLOR_ATTACHMENT_OUTPUT;
            dep.dstAccessMask = VK.ACCESS_COLOR_ATTACHMENT_WRITE;
            VkRenderPassCreateInfo rp = new VkRenderPassCreateInfo();
            rp.sType = VK.ST_RENDER_PASS_CREATE_INFO;
            rp.attachmentCount = 1;
            rp.pAttachments = &att;
            rp.subpassCount = 1;
            rp.pSubpasses = &sub;
            rp.dependencyCount = 1;
            rp.pDependencies = &dep;
            if (vkCreateRenderPass(device, &rp, null, &renderPass) != VK.SUCCESS) return Fail("vkCreateRenderPass falló");
            return true;
        }

        ulong CreateView(ulong image, int format)
        {
            VkImageViewCreateInfo vi = new VkImageViewCreateInfo();
            vi.sType = VK.ST_IMAGE_VIEW_CREATE_INFO;
            vi.image = image;
            vi.viewType = 1;  // 2D
            vi.format = format;
            vi.aspectMask = VK.ASPECT_COLOR;
            vi.levelCount = 1;
            vi.layerCount = 1;
            ulong view = 0;
            vkCreateImageView(device, &vi, null, &view);
            return view;
        }

        ulong CreateFramebuffer(ulong view)
        {
            VkFramebufferCreateInfo fi = new VkFramebufferCreateInfo();
            fi.sType = VK.ST_FRAMEBUFFER_CREATE_INFO;
            fi.renderPass = renderPass;
            fi.attachmentCount = 1;
            fi.pAttachments = &view;
            fi.width = (uint)width;
            fi.height = (uint)height;
            fi.layers = 1;
            ulong fb = 0;
            vkCreateFramebuffer(device, &fi, null, &fb);
            return fb;
        }

        bool CreateSwapchain()
        {
            VkSurfaceCapabilitiesKHR caps = new VkSurfaceCapabilitiesKHR();
            vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps);
            if (caps.currentWidth != 4294967295u)
            {
                width = (int)caps.currentWidth;
                height = (int)caps.currentHeight;
            }
            if (width <= 0 || height <= 0) return true;  // ventana minimizada
            uint count = caps.minImageCount + 1;
            if (caps.maxImageCount > 0 && count > caps.maxImageCount) count = caps.maxImageCount;
            ulong old = swapchain;
            VkSwapchainCreateInfoKHR sc = new VkSwapchainCreateInfoKHR();
            sc.sType = VK.ST_SWAPCHAIN_CREATE_INFO_KHR;
            sc.surface = surface;
            sc.minImageCount = count;
            sc.imageFormat = colorFormat;
            sc.imageColorSpace = 0;
            sc.width = (uint)width;
            sc.height = (uint)height;
            sc.imageArrayLayers = 1;
            sc.imageUsage = VK.IMAGE_USAGE_COLOR_ATTACHMENT;
            sc.preTransform = caps.currentTransform;
            sc.compositeAlpha = 1;  // OPAQUE
            sc.presentMode = 2;     // FIFO (sincronía vertical)
            sc.clipped = 1;
            sc.oldSwapchain = old;
            if (vkCreateSwapchainKHR(device, &sc, null, &swapchain) != VK.SUCCESS) return Fail("vkCreateSwapchainKHR falló");
            if (old != 0) vkDestroySwapchainKHR(device, old, null);
            uint n = 0;
            vkGetSwapchainImagesKHR(device, swapchain, &n, null);
            imageCount = (int)n;
            images = new ulong[n];
            views = new ulong[n];
            framebuffers = new ulong[n];
            vkGetSwapchainImagesKHR(device, swapchain, &n, images);
            for (int i = 0; i < imageCount; i++)
            {
                views[i] = CreateView(images[i], colorFormat);
                framebuffers[i] = CreateFramebuffer(views[i]);
            }
            return true;
        }

        void DestroySwapchainTargets()
        {
            for (int i = 0; i < imageCount; i++)
            {
                vkDestroyFramebuffer(device, framebuffers[i], null);
                vkDestroyImageView(device, views[i], null);
            }
            delete[] images;
            delete[] views;
            delete[] framebuffers;
            images = null;
            views = null;
            framebuffers = null;
            imageCount = 0;
        }

        bool CreateImage(int w, int h, int format, uint usage, out ulong image, out ulong memory)
        {
            VkImageCreateInfo ii = new VkImageCreateInfo();
            ii.sType = VK.ST_IMAGE_CREATE_INFO;
            ii.imageType = 1;
            ii.format = format;
            ii.width = (uint)w;
            ii.height = (uint)h;
            ii.depth = 1;
            ii.mipLevels = 1;
            ii.arrayLayers = 1;
            ii.samples = 1;
            ii.usage = usage;
            ii.initialLayout = VK.LAYOUT_UNDEFINED;
            ulong img = 0, mem = 0;
            image = 0;
            memory = 0;
            if (vkCreateImage(device, &ii, null, &img) != VK.SUCCESS) return false;
            VkMemoryRequirements req = new VkMemoryRequirements();
            vkGetImageMemoryRequirements(device, img, &req);
            VkMemoryAllocateInfo ai = new VkMemoryAllocateInfo();
            ai.sType = VK.ST_MEMORY_ALLOCATE_INFO;
            ai.allocationSize = req.size;
            int type = FindMemory(req.memoryTypeBits, VK.MEMORY_DEVICE_LOCAL);
            if (type < 0) type = FindMemory(req.memoryTypeBits, 0);
            ai.memoryTypeIndex = (uint)type;
            if (vkAllocateMemory(device, &ai, null, &mem) != VK.SUCCESS) return false;
            vkBindImageMemory(device, img, mem, 0);
            image = img;
            memory = mem;
            return true;
        }

        bool CreateBuffer(ulong size, uint usage, out ulong buffer, out ulong memory, out void* mapped)
        {
            VkBufferCreateInfo bi = new VkBufferCreateInfo();
            bi.sType = VK.ST_BUFFER_CREATE_INFO;
            bi.size = size;
            bi.usage = usage;
            ulong buf = 0, mem = 0;
            void* ptr = null;
            buffer = 0;
            memory = 0;
            mapped = null;
            if (vkCreateBuffer(device, &bi, null, &buf) != VK.SUCCESS) return false;
            VkMemoryRequirements req = new VkMemoryRequirements();
            vkGetBufferMemoryRequirements(device, buf, &req);
            VkMemoryAllocateInfo ai = new VkMemoryAllocateInfo();
            ai.sType = VK.ST_MEMORY_ALLOCATE_INFO;
            ai.allocationSize = req.size;
            int type = FindMemory(req.memoryTypeBits, VK.MEMORY_HOST_VISIBLE | VK.MEMORY_HOST_COHERENT);
            if (type < 0) return false;
            ai.memoryTypeIndex = (uint)type;
            if (vkAllocateMemory(device, &ai, null, &mem) != VK.SUCCESS) return false;
            vkBindBufferMemory(device, buf, mem, 0);
            vkMapMemory(device, mem, 0, VK.WHOLE_SIZE, 0, &ptr);
            buffer = buf;
            memory = mem;
            mapped = ptr;
            return true;
        }

        bool CreateOffscreenTarget()
        {
            if (!CreateImage(width, height, colorFormat, VK.IMAGE_USAGE_COLOR_ATTACHMENT | VK.IMAGE_USAGE_TRANSFER_SRC, out offImage, out offMemory))
                return Fail("no se pudo crear la imagen fuera de pantalla");
            imageCount = 1;
            views = new ulong[1];
            framebuffers = new ulong[1];
            views[0] = CreateView(offImage, colorFormat);
            framebuffers[0] = CreateFramebuffer(views[0]);
            void* unused = null;
            if (!CreateBuffer((ulong)width * (ulong)height * 4, VK.BUFFER_USAGE_TRANSFER_DST, out readbackBuffer, out readbackMemory, out unused))
                return Fail("no se pudo crear el búfer de lectura");
            return true;
        }

        ulong CreateShader(uint* code, int words)
        {
            VkShaderModuleCreateInfo si = new VkShaderModuleCreateInfo();
            si.sType = VK.ST_SHADER_MODULE_CREATE_INFO;
            si.codeSize = (ulong)words * 4;
            si.pCode = code;
            ulong module = 0;
            vkCreateShaderModule(device, &si, null, &module);
            return module;
        }

        bool CreatePipeline()
        {
            // binding 0: atlas (cobertura); binding 1: imagen RGBA
            VkDescriptorSetLayoutBinding* bindings = new VkDescriptorSetLayoutBinding[2];
            for (int i = 0; i < 2; i++)
            {
                bindings[i].binding = (uint)i;
                bindings[i].descriptorType = 1;  // COMBINED_IMAGE_SAMPLER
                bindings[i].descriptorCount = 1;
                bindings[i].stageFlags = VK.SHADER_STAGE_FRAGMENT;
            }
            VkDescriptorSetLayoutCreateInfo dl = new VkDescriptorSetLayoutCreateInfo();
            dl.sType = VK.ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
            dl.bindingCount = 2;
            dl.pBindings = bindings;
            vkCreateDescriptorSetLayout(device, &dl, null, &descriptorLayout);
            Memory.Free(bindings);

            VkPushConstantRange push = new VkPushConstantRange();
            push.stageFlags = VK.SHADER_STAGE_VERTEX;
            push.size = 8;
            VkPipelineLayoutCreateInfo pl = new VkPipelineLayoutCreateInfo();
            pl.sType = VK.ST_PIPELINE_LAYOUT_CREATE_INFO;
            pl.setLayoutCount = 1;
            pl.pSetLayouts = &descriptorLayout;
            pl.pushConstantRangeCount = 1;
            pl.pPushConstantRanges = &push;
            if (vkCreatePipelineLayout(device, &pl, null, &pipelineLayout) != VK.SUCCESS) return Fail("vkCreatePipelineLayout falló");

            uint* vcode = Shaders.Vertex();
            uint* fcode = Shaders.Fragment();
            ulong vmod = CreateShader(vcode, Shaders.VertexWords);
            ulong fmod = CreateShader(fcode, Shaders.FragmentWords);
            Memory.Free(vcode);
            Memory.Free(fcode);

            VkPipelineShaderStageCreateInfo* stages = Memory.New<VkPipelineShaderStageCreateInfo>(2);
            stages[0].sType = VK.ST_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[0].stage = VK.SHADER_STAGE_VERTEX;
            stages[0].module = vmod;
            stages[0].pName = "main".Ptr;
            stages[1].sType = VK.ST_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stages[1].stage = VK.SHADER_STAGE_FRAGMENT;
            stages[1].module = fmod;
            stages[1].pName = "main".Ptr;

            VkVertexInputBindingDescription vb = new VkVertexInputBindingDescription();
            vb.stride = (uint)sizeof(Vertex);
            VkVertexInputAttributeDescription* attrs = Memory.New<VkVertexInputAttributeDescription>(5);
            attrs[0].location = 0;
            attrs[0].format = VK.FORMAT_R32G32_SFLOAT;
            attrs[0].offset = 0;
            attrs[1].location = 1;
            attrs[1].format = VK.FORMAT_R32G32_SFLOAT;
            attrs[1].offset = 8;
            attrs[2].location = 2;
            attrs[2].format = VK.FORMAT_R32G32B32A32_SFLOAT;
            attrs[2].offset = 16;
            attrs[3].location = 3;
            attrs[3].format = VK.FORMAT_R32G32B32A32_SFLOAT;
            attrs[3].offset = 32;
            attrs[4].location = 4;
            attrs[4].format = VK.FORMAT_R32G32B32A32_SFLOAT;
            attrs[4].offset = 48;
            VkPipelineVertexInputStateCreateInfo vi = new VkPipelineVertexInputStateCreateInfo();
            vi.sType = VK.ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
            vi.vertexBindingDescriptionCount = 1;
            vi.pVertexBindingDescriptions = &vb;
            vi.vertexAttributeDescriptionCount = 5;
            vi.pVertexAttributeDescriptions = attrs;

            VkPipelineInputAssemblyStateCreateInfo ia = new VkPipelineInputAssemblyStateCreateInfo();
            ia.sType = VK.ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
            ia.topology = 3;  // TRIANGLE_LIST

            VkPipelineViewportStateCreateInfo vp = new VkPipelineViewportStateCreateInfo();
            vp.sType = VK.ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
            vp.viewportCount = 1;
            vp.scissorCount = 1;

            VkPipelineRasterizationStateCreateInfo rs = new VkPipelineRasterizationStateCreateInfo();
            rs.sType = VK.ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
            rs.lineWidth = 1;

            VkPipelineMultisampleStateCreateInfo ms = new VkPipelineMultisampleStateCreateInfo();
            ms.sType = VK.ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
            ms.rasterizationSamples = 1;

            VkPipelineColorBlendAttachmentState blend = new VkPipelineColorBlendAttachmentState();
            blend.blendEnable = 1;
            blend.srcColorBlendFactor = 6;  // SRC_ALPHA
            blend.dstColorBlendFactor = 7;  // ONE_MINUS_SRC_ALPHA
            blend.srcAlphaBlendFactor = 1;  // ONE
            blend.dstAlphaBlendFactor = 7;
            blend.colorWriteMask = 15;
            VkPipelineColorBlendStateCreateInfo cb = new VkPipelineColorBlendStateCreateInfo();
            cb.sType = VK.ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
            cb.attachmentCount = 1;
            cb.pAttachments = &blend;

            int* dynamics = new int[2];
            dynamics[0] = 0;  // VIEWPORT
            dynamics[1] = 1;  // SCISSOR
            VkPipelineDynamicStateCreateInfo ds = new VkPipelineDynamicStateCreateInfo();
            ds.sType = VK.ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
            ds.dynamicStateCount = 2;
            ds.pDynamicStates = dynamics;

            VkGraphicsPipelineCreateInfo gp = new VkGraphicsPipelineCreateInfo();
            gp.sType = VK.ST_GRAPHICS_PIPELINE_CREATE_INFO;
            gp.stageCount = 2;
            gp.pStages = stages;
            gp.pVertexInputState = &vi;
            gp.pInputAssemblyState = &ia;
            gp.pViewportState = &vp;
            gp.pRasterizationState = &rs;
            gp.pMultisampleState = &ms;
            gp.pColorBlendState = &cb;
            gp.pDynamicState = &ds;
            gp.layout = pipelineLayout;
            gp.renderPass = renderPass;
            gp.basePipelineIndex = -1;
            int r = vkCreateGraphicsPipelines(device, 0, 1, &gp, null, &pipeline);
            vkDestroyShaderModule(device, vmod, null);
            vkDestroyShaderModule(device, fmod, null);
            Memory.Free(stages);
            Memory.Free(attrs);
            delete[] dynamics;
            if (r != VK.SUCCESS) return Fail("vkCreateGraphicsPipelines falló");
            return true;
        }

        bool CreateResources()
        {
            Atlas = new Atlas(1024);
            if (!CreateImage(Atlas.Size, Atlas.Size, VK.FORMAT_R8_UNORM, VK.IMAGE_USAGE_SAMPLED | VK.IMAGE_USAGE_TRANSFER_DST, out atlasImage, out atlasMemory))
                return Fail("no se pudo crear la textura del atlas");
            atlasView = CreateView(atlasImage, VK.FORMAT_R8_UNORM);
            if (!CreateBuffer((ulong)Atlas.Size * (ulong)Atlas.Size, VK.BUFFER_USAGE_TRANSFER_SRC, out stagingBuffer, out stagingMemory, out stagingMapped))
                return Fail("no se pudo crear el búfer de subida");
            void* vmapped = null;
            if (!CreateBuffer((ulong)MaxVertices * (ulong)sizeof(Vertex), VK.BUFFER_USAGE_VERTEX, out vertexBuffer, out vertexMemory, out vmapped))
                return Fail("no se pudo crear el búfer de vértices");
            vertices = (Vertex*)vmapped;
            if (!CreateImage(ImageSize, ImageSize, VK.FORMAT_R8G8B8A8_UNORM, VK.IMAGE_USAGE_SAMPLED | VK.IMAGE_USAGE_TRANSFER_DST, out imageTex, out imageMemory))
                return Fail("no se pudo crear la textura de imagen");
            imageView = CreateView(imageTex, VK.FORMAT_R8G8B8A8_UNORM);
            void* imapped = null;
            if (!CreateBuffer((ulong)ImageSize * (ulong)ImageSize * 4, VK.BUFFER_USAGE_TRANSFER_SRC, out imageStaging, out imageStagingMemory, out imapped))
                return Fail("no se pudo crear el búfer de la imagen");
            imageMapped = (byte*)imapped;

            VkSamplerCreateInfo si = new VkSamplerCreateInfo();
            si.sType = VK.ST_SAMPLER_CREATE_INFO;
            si.magFilter = 0;  // NEAREST: glifos alineados a píxel, nítidos
            si.minFilter = 0;
            si.addressModeU = 2;
            si.addressModeV = 2;
            si.addressModeW = 2;
            si.maxLod = 1;
            vkCreateSampler(device, &si, null, &sampler);
            si.magFilter = 1;  // LINEAR: la imagen se escala suave
            si.minFilter = 1;
            vkCreateSampler(device, &si, null, &imageSampler);

            VkDescriptorPoolSize ps = new VkDescriptorPoolSize();
            ps.type = 1;
            ps.descriptorCount = 2;
            VkDescriptorPoolCreateInfo dp = new VkDescriptorPoolCreateInfo();
            dp.sType = VK.ST_DESCRIPTOR_POOL_CREATE_INFO;
            dp.maxSets = 1;
            dp.poolSizeCount = 1;
            dp.pPoolSizes = &ps;
            vkCreateDescriptorPool(device, &dp, null, &descriptorPool);
            VkDescriptorSetAllocateInfo da = new VkDescriptorSetAllocateInfo();
            da.sType = VK.ST_DESCRIPTOR_SET_ALLOCATE_INFO;
            da.descriptorPool = descriptorPool;
            da.descriptorSetCount = 1;
            da.pSetLayouts = &descriptorLayout;
            vkAllocateDescriptorSets(device, &da, &descriptorSet);
            VkDescriptorImageInfo info = new VkDescriptorImageInfo();
            info.sampler = sampler;
            info.imageView = atlasView;
            info.imageLayout = VK.LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            VkWriteDescriptorSet w = new VkWriteDescriptorSet();
            w.sType = VK.ST_WRITE_DESCRIPTOR_SET;
            w.dstSet = descriptorSet;
            w.descriptorCount = 1;
            w.descriptorType = 1;
            w.pImageInfo = &info;
            vkUpdateDescriptorSets(device, 1, &w, 0, null);
            VkDescriptorImageInfo info2 = new VkDescriptorImageInfo();
            info2.sampler = imageSampler;
            info2.imageView = imageView;
            info2.imageLayout = VK.LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            w.dstBinding = 1;
            w.pImageInfo = &info2;
            vkUpdateDescriptorSets(device, 1, &w, 0, null);
            // La imagen empieza vacía (transparente) para que el descriptor sea válido.
            Memory.Set(imageMapped, 0, (long)ImageSize * ImageSize * 4);
            imageDirty = true;

            VkCommandPoolCreateInfo cp = new VkCommandPoolCreateInfo();
            cp.sType = VK.ST_COMMAND_POOL_CREATE_INFO;
            cp.flags = 2;  // RESET_COMMAND_BUFFER
            cp.queueFamilyIndex = queueFamily;
            vkCreateCommandPool(device, &cp, null, &commandPool);
            VkCommandBufferAllocateInfo ca = new VkCommandBufferAllocateInfo();
            ca.sType = VK.ST_COMMAND_BUFFER_ALLOCATE_INFO;
            ca.commandPool = commandPool;
            ca.commandBufferCount = 1;
            vkAllocateCommandBuffers(device, &ca, &cmd);

            VkSimpleCreateInfo sem = new VkSimpleCreateInfo();
            sem.sType = VK.ST_SEMAPHORE_CREATE_INFO;
            vkCreateSemaphore(device, &sem, null, &imageAvailable);
            vkCreateSemaphore(device, &sem, null, &renderFinished);
            VkSimpleCreateInfo fi = new VkSimpleCreateInfo();
            fi.sType = VK.ST_FENCE_CREATE_INFO;
            fi.flags = 1;  // SIGNALED
            vkCreateFence(device, &fi, null, &inFlight);
            return true;
        }

        string sansPath = "";
        string sansBoldPath = "";
        List<Font> sized = new List<Font>();
        List<int> sizedKeys = new List<int>();

        // Fuente de interfaz de cualquier tamaño (vista previa del diseñador); se cargan bajo demanda.
        public Font Sans(int size, bool bold)
        {
            if (size < 6) size = 6;
            if (size > 72) size = 72;
            int key = size * 2 + (bold ? 1 : 0);
            for (int i = 0; i < sizedKeys.Count; i++)
                if (sizedKeys[i] == key) return sized[i];
            Font f = new Font();
            if (!f.Load(bold ? sansBoldPath : sansPath, size, Atlas))
            {
                delete f;
                return bold ? UiBold : Ui;
            }
            sized.Add(f);
            sizedKeys.Add(key);
            return f;
        }

#if WINDOWS
        // "a.ttf;b.ttf" -> "<carpeta>/a.ttf;<carpeta>/b.ttf" (lista para Font.FindFile).
        static string FontList(string folder, string names)
        {
            List<string> parts = std.text.Text.Split(names, ";");
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < parts.Count; i++)
            {
                if (i > 0) sb.Append(";");
                string full = Path.Combine(folder, parts[i]);
                sb.Append(full);
                String.Free(full);
            }
            delete parts;
            string r = sb.ToString();
            delete sb;
            return r;
        }
#endif

        bool LoadFonts()
        {
#if WINDOWS
            // Fuentes del sistema (%WINDIR%\Fonts): Consolas para el código y Segoe UI para la interfaz;
            // Segoe UI Symbol cubre los símbolos (▸ ▾ ▶ ■ ●) que no tienen las otras. DejaVu, si
            // está instalada, sirve de alternativa (también en Wine, que no trae las fuentes de Windows).
            string windir = Environment.GetVariable("WINDIR");
            if (windir.IsEmpty()) windir = "C:\\Windows";
            string fonts = Path.Combine(windir, "Fonts");
            string mono = Font.FindFile(FontList(fonts, "consola.ttf;DejaVuSansMono.ttf;cour.ttf;lucon.ttf"));
            string monoBold = Font.FindFile(FontList(fonts, "consolab.ttf;DejaVuSansMono-Bold.ttf;courbd.ttf"));
            string monoItalic = Font.FindFile(FontList(fonts, "consolai.ttf;DejaVuSansMono-Oblique.ttf;couri.ttf"));
            string sans = Font.FindFile(FontList(fonts, "segoeui.ttf;DejaVuSans.ttf;tahoma.ttf;arial.ttf"));
            string sansBold = Font.FindFile(FontList(fonts, "segoeuib.ttf;DejaVuSans-Bold.ttf;tahomabd.ttf;arialbd.ttf"));
            Font.FallbackPath = Font.FindFile(FontList(fonts, "seguisym.ttf;DejaVuSans.ttf;segoeui.ttf"));
            if (mono.IsEmpty()) return Fail("no se encontró una fuente monoespaciada en la carpeta Fonts de Windows (Consolas o Courier New)");
#else
            string mono = Font.FindFile("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf;/usr/share/fonts/TTF/DejaVuSansMono.ttf;/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf;/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf;C:/Windows/Fonts/consola.ttf");
            string monoBold = Font.FindFile("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf;/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf;/usr/share/fonts/truetype/noto/NotoSansMono-Bold.ttf;C:/Windows/Fonts/consolab.ttf");
            string monoItalic = Font.FindFile("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Oblique.ttf;/usr/share/fonts/TTF/DejaVuSansMono-Oblique.ttf;/usr/share/fonts/truetype/liberation/LiberationMono-Italic.ttf;C:/Windows/Fonts/consolai.ttf");
            string sans = Font.FindFile("/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf;/usr/share/fonts/noto/NotoSans-Regular.ttf;/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf;/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf;C:/Windows/Fonts/segoeui.ttf");
            string sansBold = Font.FindFile("/usr/share/fonts/truetype/noto/NotoSans-Bold.ttf;/usr/share/fonts/noto/NotoSans-Bold.ttf;/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf;/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf;C:/Windows/Fonts/segoeuib.ttf");
            if (mono.IsEmpty()) return Fail("no se encontró una fuente monoespaciada (instala DejaVu Sans Mono)");
#endif
            if (monoBold.IsEmpty()) monoBold = mono;
            if (monoItalic.IsEmpty()) monoItalic = mono;
            if (sans.IsEmpty()) sans = mono;
            if (sansBold.IsEmpty()) sansBold = sans;
            sansPath = sans;
            sansBoldPath = sansBold;
            Code = new Font();
            CodeBold = new Font();
            CodeItalic = new Font();
            Ui = new Font();
            UiBold = new Font();
            UiSmall = new Font();
            Icons = new Font();
            Title = new Font();
            bool ok = Code.Load(mono, 14, Atlas) && CodeBold.Load(monoBold, 14, Atlas) && CodeItalic.Load(monoItalic, 14, Atlas) &&
                      Ui.Load(sans, 13, Atlas) && UiBold.Load(sansBold, 13, Atlas) && UiSmall.Load(sans, 11, Atlas) &&
                      Icons.Load(mono, 12, Atlas) && Title.Load(sansBold, 24, Atlas);
#if WINDOWS
            if (!ok) return Fail("no se pudieron cargar las fuentes de Windows (stb_truetype)");
#else
            if (!ok) return Fail("FreeType no pudo cargar las fuentes");
#endif
            // Interlineado más generoso para el editor; todas las variantes comparten el alto de línea.
            Code.LineHeight += 4;
            CodeBold.LineHeight = Code.LineHeight;
            CodeItalic.LineHeight = Code.LineHeight;
            return true;
        }

        // ------------------------------------------------------------------ fotograma

        public void Resize(int w, int h)
        {
            if (w == width && h == height) return;
            width = w;
            height = h;
            needsRecreate = true;
        }

        void Recreate()
        {
            needsRecreate = false;
            vkDeviceWaitIdle(device);
            DestroySwapchainTargets();
            CreateSwapchain();
        }

        public void BeginFrame(Color background)
        {
            ulong fence = inFlight;
            vkWaitForFences(device, 1, &fence, 1, VK.NO_TIMEOUT);
            vertexCount = 0;
            commands.Clear();
            clipStack.Clear();
            clear.R = background.R;
            clear.G = background.G;
            clear.B = background.B;
            clear.A = 1;
            VkRect2D full = new VkRect2D();
            full.width = (uint)Math.Max(width, 1);
            full.height = (uint)Math.Max(height, 1);
            clipStack.Add(full);
            StartCommand();
        }

        void StartCommand()
        {
            DrawCmd c = new DrawCmd();
            c.First = vertexCount;
            c.Clip = clipStack.Last();
            commands.Add(c);
        }

        public void PushClip(float x, float y, float w, float h)
        {
            VkRect2D parent = clipStack.Last();
            int x0 = Math.Max((int)x, parent.x), y0 = Math.Max((int)y, parent.y);
            int x1 = Math.Min((int)(x + w), parent.x + (int)parent.width);
            int y1 = Math.Min((int)(y + h), parent.y + (int)parent.height);
            VkRect2D r = new VkRect2D();
            r.x = x0;
            r.y = y0;
            r.width = (uint)Math.Max(0, x1 - x0);
            r.height = (uint)Math.Max(0, y1 - y0);
            clipStack.Add(r);
            StartCommand();
        }

        public void PopClip()
        {
            if (clipStack.Count > 1) clipStack.Pop();
            StartCommand();
        }

        void Quad(float x0, float y0, float x1, float y1, float u0, float v0, float u1, float v1, Color c)
        {
            if (vertexCount + 6 > MaxVertices) return;
            Vertex* v = vertices + vertexCount;
            v[0].X = x0; v[0].Y = y0; v[0].U = u0; v[0].V = v0;
            v[1].X = x1; v[1].Y = y0; v[1].U = u1; v[1].V = v0;
            v[2].X = x1; v[2].Y = y1; v[2].U = u1; v[2].V = v1;
            v[3].X = x0; v[3].Y = y0; v[3].U = u0; v[3].V = v0;
            v[4].X = x1; v[4].Y = y1; v[4].U = u1; v[4].V = v1;
            v[5].X = x0; v[5].Y = y1; v[5].U = u0; v[5].V = v1;
            for (int i = 0; i < 6; i++)
            {
                v[i].R = c.R;
                v[i].G = c.G;
                v[i].B = c.B;
                v[i].A = c.A;
                v[i].Radius = -1;
            }
            vertexCount += 6;
        }

        // Rectángulo redondeado (relleno, contorno o sombra) evaluado en el shader.
        public void Shape(float x, float y, float w, float h, float radius, float border, float soft, Color c)
        {
            if (w <= 0 || h <= 0 || vertexCount + 6 > MaxVertices) return;
            float pad = soft + 1;
            float hw = w / 2, hh = h / 2;
            float cx = x + hw, cy = y + hh;
            float x0 = x - pad, y0 = y - pad, x1 = x + w + pad, y1 = y + h + pad;
            float r = (float)Math.Min(radius, Math.Min(hw, hh));
            Quad(x0, y0, x1, y1, Atlas.WhiteU, Atlas.WhiteV, Atlas.WhiteU, Atlas.WhiteV, c);
            Vertex* v = vertices + vertexCount - 6;
            for (int i = 0; i < 6; i++)
            {
                v[i].LocalX = v[i].X - cx;
                v[i].LocalY = v[i].Y - cy;
                v[i].HalfW = hw;
                v[i].HalfH = hh;
                v[i].Radius = r;
                v[i].Border = border;
                v[i].Soft = soft;
            }
        }

        public void RoundRect(float x, float y, float w, float h, float radius, Color c) { Shape(x, y, w, h, radius, 0, 0, c); }

        // Rectángulo redondeado con degradado lineal (el color se interpola entre vértices).
        public void GradientRoundRect(float x, float y, float w, float h, float radius, Color from, Color to, bool horizontal)
        {
            int before = vertexCount;
            Shape(x, y, w, h, radius, 0, 0, from);
            if (vertexCount == before) return;
            Vertex* v = vertices + vertexCount - 6;
            for (int i = 0; i < 6; i++)
            {
                float t = horizontal ? (v[i].X - x) / w : (v[i].Y - y) / h;
                v[i].R = from.R + (to.R - from.R) * t;
                v[i].G = from.G + (to.G - from.G) * t;
                v[i].B = from.B + (to.B - from.B) * t;
                v[i].A = from.A + (to.A - from.A) * t;
            }
        }

        public void RoundBorder(float x, float y, float w, float h, float radius, float thickness, Color c)
        {
            Shape(x, y, w, h, radius, thickness, 0, c);
        }

        // Sombra suave bajo una forma redondeada.
        public void Shadow(float x, float y, float w, float h, float radius, float blur, Color c)
        {
            Shape(x, y + blur / 4, w, h, radius, 0, blur, c);
        }

        public void Rect(float x, float y, float w, float h, Color c)
        {
            if (w <= 0 || h <= 0) return;
            float u = Atlas.WhiteU, v = Atlas.WhiteV;
            Quad(x, y, x + w, y + h, u, v, u, v, c);
        }

        public void RectOutline(float x, float y, float w, float h, float t, Color c)
        {
            Rect(x, y, w, t, c);
            Rect(x, y + h - t, w, t, c);
            Rect(x, y, t, h, c);
            Rect(x + w - t, y, t, h, c);
        }

        // Decodifica el carácter UTF-8 que empieza en s[i]; avanza i.
        public static char NextChar(string s, ref int i)
        {
            byte b = s[i];
            if (b < 0x80)
            {
                i++;
                return (char)b;
            }
            int extra = b >= 0xF8 ? 0 : (b >= 0xF0 ? 3 : (b >= 0xE0 ? 2 : (b >= 0xC2 ? 1 : 0)));
            // Secuencia inválida (p. ej. un archivo en Latin-1): el byte vale por sí mismo.
            bool valid = extra > 0 && i + extra < s.Length;
            for (int k = 1; valid && k <= extra; k++)
                if ((s[i + k] & 0xC0) != 0x80) valid = false;
            if (!valid)
            {
                i++;
                return (char)b;
            }
            uint cp = (uint)(b & (0x3F >> extra));
            i++;
            for (int k = 0; k < extra; k++)
            {
                cp = (cp << 6) | (uint)(s[i] & 0x3F);
                i++;
            }
            return (char)cp;
        }

        // Dibuja texto con la parte superior de la línea en 'y'; devuelve la x final.
        public float Text(Font f, float x, float y, string s, Color c)
        {
            float baseline = (float)Math.Floor(y + f.Ascent + 1);
            float pen = x;
            int i = 0;
            while (i < s.Length)
            {
                char ch = NextChar(s, ref i);
                if (ch == '\t') ch = ' ';
                Glyph g = f.Get(ch);
                if (g.Width > 0)
                {
                    float gx = (float)Math.Floor(pen + g.Left + 0.5), gy = baseline - g.Top;
                    Quad(gx, gy, gx + g.Width, gy + g.Height, g.U0, g.V0, g.U1, g.V1, c);
                }
                pen += g.Advance;
            }
            return pen;
        }

        // Logotipo de Faset de 'size' x 'size' píxeles (se rasteriza una vez por tamaño).
        public void Logo(float x, float y, int size, Color c)
        {
            Glyph g;
            if (!logos.TryGetValue(size, out g))
            {
                g = new Glyph();
                int ax = 0, ay = 0;
                if (Atlas.Allocate(size, size, out ax, out ay))
                {
                    for (int py = 0; py < size; py++)
                        for (int px = 0; px < size; px++)
                            Atlas.Pixels[(ay + py) * Atlas.Size + ax + px] = LogoShape.Coverage(px, py, size);
                    float s = Atlas.Size;
                    g.U0 = ax / s;
                    g.V0 = ay / s;
                    g.U1 = (ax + size) / s;
                    g.V1 = (ay + size) / s;
                    g.Width = size;
                    g.Height = size;
                    Atlas.Dirty = true;
                }
                logos.Set(size, g);
            }
            if (g.Width > 0) Quad(x, y, x + size, y + size, g.U0, g.V0, g.U1, g.V1, c);
        }

        // Dibuja un solo carácter con la parte superior de la línea en 'y'.
        public void Char(Font f, float x, float y, char ch, Color c)
        {
            Glyph g = f.Get(ch);
            if (g.Width == 0) return;
            float baseline = (float)Math.Floor(y + f.Ascent + 1);
            float gx = (float)Math.Floor(x + g.Left + 0.5), gy = baseline - g.Top;
            Quad(gx, gy, gx + g.Width, gy + g.Height, g.U0, g.V0, g.U1, g.V1, c);
        }

        public float TextWidth(Font f, string s)
        {
            float w = 0;
            int i = 0;
            while (i < s.Length) w += f.Get(NextChar(s, ref i)).Advance;
            return w;
        }

        void UploadAtlas()
        {
            Memory.Copy(stagingMapped, Atlas.Pixels, (long)Atlas.Size * Atlas.Size);
            VkImageMemoryBarrier b = new VkImageMemoryBarrier();
            b.sType = VK.ST_IMAGE_MEMORY_BARRIER;
            b.srcAccessMask = atlasReady ? VK.ACCESS_SHADER_READ : 0u;
            b.dstAccessMask = VK.ACCESS_TRANSFER_WRITE;
            b.oldLayout = atlasReady ? VK.LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK.LAYOUT_UNDEFINED;
            b.newLayout = VK.LAYOUT_TRANSFER_DST_OPTIMAL;
            b.srcQueueFamilyIndex = 4294967295u;
            b.dstQueueFamilyIndex = 4294967295u;
            b.image = atlasImage;
            b.aspectMask = VK.ASPECT_COLOR;
            b.levelCount = 1;
            b.layerCount = 1;
            vkCmdPipelineBarrier(cmd, atlasReady ? VK.STAGE_FRAGMENT_SHADER : VK.STAGE_TOP_OF_PIPE, VK.STAGE_TRANSFER, 0, 0, null, 0, null, 1, &b);
            VkBufferImageCopy region = new VkBufferImageCopy();
            region.aspectMask = VK.ASPECT_COLOR;
            region.layerCount = 1;
            region.width = (uint)Atlas.Size;
            region.height = (uint)Atlas.Size;
            region.depth = 1;
            vkCmdCopyBufferToImage(cmd, stagingBuffer, atlasImage, VK.LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
            b.srcAccessMask = VK.ACCESS_TRANSFER_WRITE;
            b.dstAccessMask = VK.ACCESS_SHADER_READ;
            b.oldLayout = VK.LAYOUT_TRANSFER_DST_OPTIMAL;
            b.newLayout = VK.LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            vkCmdPipelineBarrier(cmd, VK.STAGE_TRANSFER, VK.STAGE_FRAGMENT_SHADER, 0, 0, null, 0, null, 1, &b);
            Atlas.Dirty = false;
            atlasReady = true;
        }

        void UploadImage()
        {
            VkImageMemoryBarrier b = new VkImageMemoryBarrier();
            b.sType = VK.ST_IMAGE_MEMORY_BARRIER;
            b.srcAccessMask = imageReady ? VK.ACCESS_SHADER_READ : 0u;
            b.dstAccessMask = VK.ACCESS_TRANSFER_WRITE;
            b.oldLayout = imageReady ? VK.LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK.LAYOUT_UNDEFINED;
            b.newLayout = VK.LAYOUT_TRANSFER_DST_OPTIMAL;
            b.srcQueueFamilyIndex = 4294967295u;
            b.dstQueueFamilyIndex = 4294967295u;
            b.image = imageTex;
            b.aspectMask = VK.ASPECT_COLOR;
            b.levelCount = 1;
            b.layerCount = 1;
            vkCmdPipelineBarrier(cmd, imageReady ? VK.STAGE_FRAGMENT_SHADER : VK.STAGE_TOP_OF_PIPE, VK.STAGE_TRANSFER, 0, 0, null, 0, null, 1, &b);
            VkBufferImageCopy region = new VkBufferImageCopy();
            region.aspectMask = VK.ASPECT_COLOR;
            region.layerCount = 1;
            region.width = (uint)ImageSize;
            region.height = (uint)ImageSize;
            region.depth = 1;
            vkCmdCopyBufferToImage(cmd, imageStaging, imageTex, VK.LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
            b.srcAccessMask = VK.ACCESS_TRANSFER_WRITE;
            b.dstAccessMask = VK.ACCESS_SHADER_READ;
            b.oldLayout = VK.LAYOUT_TRANSFER_DST_OPTIMAL;
            b.newLayout = VK.LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            vkCmdPipelineBarrier(cmd, VK.STAGE_TRANSFER, VK.STAGE_FRAGMENT_SHADER, 0, 0, null, 0, null, 1, &b);
            imageDirty = false;
            imageReady = true;
        }

        // Carga una imagen RGBA (4 bytes por píxel, 'stride' bytes por fila); si es mayor que
        // ImageSize se reduce conservando la proporción. Se sube a la GPU en el siguiente fotograma.
        public void SetImage(byte* rgba, int w, int h, int stride)
        {
            if (w <= 0 || h <= 0) return;
            int tw = w, th = h;
            if (tw > ImageSize || th > ImageSize)
            {
                double k = Math.Min((double)ImageSize / w, (double)ImageSize / h);
                tw = Math.Max(1, (int)(w * k));
                th = Math.Max(1, (int)(h * k));
            }
            for (int y = 0; y < th; y++)
            {
                byte* src = rgba + (long)(y * h / th) * stride;
                uint* dst = (uint*)(imageMapped + (long)y * ImageSize * 4);
                if (tw == w) Memory.Copy(dst, src, (long)w * 4);
                else
                    for (int x = 0; x < tw; x++) dst[x] = *(uint*)(src + (long)(x * w / tw) * 4);
            }
            ImageWidth = tw;
            ImageHeight = th;
            imageDirty = true;
        }

        // Dibuja la imagen cargada con SetImage en el rectángulo indicado.
        public void Image(float x, float y, float w, float h, Color tint)
        {
            if (ImageWidth == 0 || vertexCount + 6 > MaxVertices) return;
            Quad(x, y, x + w, y + h, 0, 0, ImageWidth / (float)ImageSize, ImageHeight / (float)ImageSize, tint);
            Vertex* v = vertices + vertexCount - 6;
            for (int i = 0; i < 6; i++) v[i].Radius = -2;
        }

        // Envía el fotograma a la GPU y lo presenta. Devuelve false si no se pudo dibujar.
        public bool EndFrame()
        {
            if (needsRecreate && !offscreen) Recreate();
            if (width <= 0 || height <= 0 || imageCount == 0) return false;
            ulong fence = inFlight;
            uint index = 0;
            if (!offscreen)
            {
                int r = vkAcquireNextImageKHR(device, swapchain, VK.NO_TIMEOUT, imageAvailable, 0, &index);
                if (r == VK.ERROR_OUT_OF_DATE_KHR)
                {
                    Recreate();
                    return false;
                }
            }
            vkResetFences(device, 1, &fence);
            vkResetCommandBuffer(cmd, 0);
            VkCommandBufferBeginInfo bi = new VkCommandBufferBeginInfo();
            bi.sType = VK.ST_COMMAND_BUFFER_BEGIN_INFO;
            bi.flags = 1;
            vkBeginCommandBuffer(cmd, &bi);
            if (Atlas.Dirty) UploadAtlas();
            if (imageDirty) UploadImage();

            VkRenderPassBeginInfo rb = new VkRenderPassBeginInfo();
            rb.sType = VK.ST_RENDER_PASS_BEGIN_INFO;
            rb.renderPass = renderPass;
            rb.framebuffer = framebuffers[index];
            rb.width = (uint)width;
            rb.height = (uint)height;
            rb.clearValueCount = 1;
            rb.pClearValues = &clear;
            vkCmdBeginRenderPass(cmd, &rb, 0);
            VkViewport viewport = new VkViewport();
            viewport.width = width;
            viewport.height = height;
            viewport.maxDepth = 1;
            vkCmdSetViewport(cmd, 0, 1, &viewport);
            vkCmdBindPipeline(cmd, 0, pipeline);
            vkCmdBindDescriptorSets(cmd, 0, pipelineLayout, 0, 1, &descriptorSet, 0, null);
            ulong offset = 0;
            vkCmdBindVertexBuffers(cmd, 0, 1, &vertexBuffer, &offset);
            float* screen = new float[2];
            screen[0] = width;
            screen[1] = height;
            vkCmdPushConstants(cmd, pipelineLayout, VK.SHADER_STAGE_VERTEX, 0, 8, screen);
            delete[] screen;
            for (int i = 0; i < commands.Count; i++)
            {
                DrawCmd c = commands[i];
                int end = i + 1 < commands.Count ? commands[i + 1].First : vertexCount;
                int count = end - c.First;
                if (count <= 0 || c.Clip.width == 0 || c.Clip.height == 0) continue;
                VkRect2D clip = c.Clip;
                vkCmdSetScissor(cmd, 0, 1, &clip);
                vkCmdDraw(cmd, (uint)count, 1, (uint)c.First, 0);
            }
            vkCmdEndRenderPass(cmd);
            if (offscreen)
            {
                VkBufferImageCopy region = new VkBufferImageCopy();
                region.aspectMask = VK.ASPECT_COLOR;
                region.layerCount = 1;
                region.width = (uint)width;
                region.height = (uint)height;
                region.depth = 1;
                vkCmdCopyImageToBuffer(cmd, offImage, VK.LAYOUT_TRANSFER_SRC_OPTIMAL, readbackBuffer, 1, &region);
            }
            vkEndCommandBuffer(cmd);

            uint waitStage = VK.STAGE_COLOR_ATTACHMENT_OUTPUT;
            void* cb = cmd;
            VkSubmitInfo si = new VkSubmitInfo();
            si.sType = VK.ST_SUBMIT_INFO;
            si.commandBufferCount = 1;
            si.pCommandBuffers = &cb;
            if (!offscreen)
            {
                si.waitSemaphoreCount = 1;
                si.pWaitSemaphores = &imageAvailable;
                si.pWaitDstStageMask = &waitStage;
                si.signalSemaphoreCount = 1;
                si.pSignalSemaphores = &renderFinished;
            }
            vkQueueSubmit(queue, 1, &si, fence);
            if (offscreen) return true;

            VkPresentInfoKHR pi = new VkPresentInfoKHR();
            pi.sType = VK.ST_PRESENT_INFO_KHR;
            pi.waitSemaphoreCount = 1;
            pi.pWaitSemaphores = &renderFinished;
            pi.swapchainCount = 1;
            pi.pSwapchains = &swapchain;
            pi.pImageIndices = &index;
            int pr = vkQueuePresentKHR(queue, &pi);
            if (pr == VK.ERROR_OUT_OF_DATE_KHR || pr == VK.SUBOPTIMAL_KHR) needsRecreate = true;
            return true;
        }

        // Guarda el último fotograma fuera de pantalla como imagen PPM.
        public bool SaveScreenshot(string path)
        {
            if (!offscreen) return false;
            ulong fence = inFlight;
            vkWaitForFences(device, 1, &fence, 1, VK.NO_TIMEOUT);
            void* data = null;
            vkMapMemory(device, readbackMemory, 0, VK.WHOLE_SIZE, 0, &data);
            byte* src = (byte*)data;
            StringBuilder header = new StringBuilder();
            header.Append("P6\n").Append(width).Append(" ").Append(height).Append("\n255\n");
            long size = (long)width * height * 3;
            byte* rgb = (byte*)Memory.Alloc(size);
            for (long i = 0; i < (long)width * height; i++)
            {
                rgb[i * 3] = src[i * 4];
                rgb[i * 3 + 1] = src[i * 4 + 1];
                rgb[i * 3 + 2] = src[i * 4 + 2];
            }
            vkUnmapMemory(device, readbackMemory);
            bool ok = File.WriteAllText(path, header.View()) && File.AppendAllText(path, String.FromBytes(rgb, size));
            Memory.Free(rgb);
            delete header;
            return ok;
        }

        public void Shutdown()
        {
            if (device == null) return;
            vkDeviceWaitIdle(device);
            // El sistema operativo libera el resto de recursos de Vulkan al salir.
            if (!offscreen)
            {
                DestroySwapchainTargets();
                vkDestroySwapchainKHR(device, swapchain, null);
                vkDestroySurfaceKHR(instance, surface, null);
            }
        }
    }
}
