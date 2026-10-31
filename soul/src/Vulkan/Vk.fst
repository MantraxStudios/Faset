// =============================================================================
//  Soul - Vulkan bindings.
//
//  vulkan-1.dll is loaded at runtime (no import library, no SDK needed). Every
//  Vulkan command is fetched through vkGetInstanceProcAddr / vkGetDeviceProcAddr
//  and stored as a typed unmanaged function pointer (delegate*).
//
//  Handles are opaque pointers (void*). Structs live in VkTypes.fst with the
//  exact C field layout, so '&struct' can be passed straight to the driver.
// =============================================================================
using std;

namespace Soul.Vulkan
{
    public memory_unsafe static class Vk
    {
        // --- VkStructureType ---
        public const uint STRUCTURE_TYPE_APPLICATION_INFO            = 0;
        public const uint STRUCTURE_TYPE_INSTANCE_CREATE_INFO        = 1;
        public const uint STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO    = 2;
        public const uint STRUCTURE_TYPE_DEVICE_CREATE_INFO          = 3;
        public const uint STRUCTURE_TYPE_SUBMIT_INFO                 = 4;
        public const uint STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO        = 5;
        public const uint STRUCTURE_TYPE_BUFFER_CREATE_INFO          = 12;
        public const uint STRUCTURE_TYPE_IMAGE_CREATE_INFO           = 14;
        public const uint STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO = 25;
        public const uint STRUCTURE_TYPE_FENCE_CREATE_INFO           = 8;
        public const uint STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO       = 9;
        public const uint STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO      = 15;
        public const uint STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO     = 37;
        public const uint STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO     = 38;
        public const uint STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO    = 39;
        public const uint STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO= 40;
        public const uint STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO   = 42;
        public const uint STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO      = 43;
        public const uint STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO   = 16;
        public const uint STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO     = 18;
        public const uint STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO   = 19;
        public const uint STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO = 20;
        public const uint STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO       = 22;
        public const uint STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO  = 23;
        public const uint STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO    = 24;
        public const uint STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO    = 26;
        public const uint STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO = 28;
        public const uint STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO  = 30;
        public const uint STRUCTURE_TYPE_SAMPLER_CREATE_INFO          = 31;
        public const uint STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = 32;
        public const uint STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO  = 33;
        public const uint STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = 34;
        public const uint STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET         = 35;
        public const uint STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER         = 45;
        public const uint STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR   = 1000001000;
        public const uint STRUCTURE_TYPE_PRESENT_INFO_KHR            = 1000001001;
        public const uint STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR = 1000009000;

        // --- misc enums / flags ---
        public const uint QUEUE_GRAPHICS_BIT            = 0x00000001;
        public const uint FORMAT_B8G8R8A8_UNORM         = 44;
        public const uint FORMAT_B8G8R8A8_SRGB          = 50;
        public const uint COLOR_SPACE_SRGB_NONLINEAR    = 0;
        public const uint PRESENT_MODE_FIFO             = 2;
        public const uint IMAGE_USAGE_COLOR_ATTACHMENT  = 0x00000010;
        public const uint SHARING_MODE_EXCLUSIVE        = 0;
        public const uint COMPOSITE_ALPHA_OPAQUE        = 0x00000001;
        public const uint IMAGE_VIEW_TYPE_2D            = 1;
        public const uint IMAGE_ASPECT_COLOR_BIT        = 0x00000001;
        public const uint SAMPLE_COUNT_1_BIT            = 0x00000001;
        public const uint ATTACHMENT_LOAD_OP_CLEAR      = 1;
        public const uint ATTACHMENT_STORE_OP_STORE     = 0;
        public const uint ATTACHMENT_LOAD_OP_DONT_CARE  = 2;
        public const uint ATTACHMENT_STORE_OP_DONT_CARE = 1;
        public const uint IMAGE_LAYOUT_UNDEFINED        = 0;
        public const uint IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL = 2;
        public const uint IMAGE_LAYOUT_PRESENT_SRC_KHR  = 1000001002;
        public const uint PIPELINE_BIND_POINT_GRAPHICS  = 0;
        public const uint SUBPASS_CONTENTS_INLINE       = 0;
        public const uint COMMAND_BUFFER_LEVEL_PRIMARY  = 0;
        public const uint COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT = 0x00000002;
        public const uint FENCE_CREATE_SIGNALED_BIT     = 0x00000001;
        public const uint PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT = 0x00000400;
        public const uint SHADER_STAGE_VERTEX_BIT    = 0x00000001;
        public const uint SHADER_STAGE_FRAGMENT_BIT  = 0x00000010;
        public const uint PRIMITIVE_TOPOLOGY_TRIANGLE_LIST = 3;
        public const uint POLYGON_MODE_FILL          = 0;
        public const uint CULL_MODE_NONE             = 0;
        public const uint FRONT_FACE_CLOCKWISE       = 0;
        public const uint COLOR_COMPONENT_RGBA       = 0x0000000F;
        public const uint BUFFER_USAGE_VERTEX_BUFFER = 0x00000080;
        public const uint BUFFER_USAGE_INDEX_BUFFER  = 0x00000040;
        public const uint MEMORY_PROPERTY_DEVICE_LOCAL  = 0x00000001;
        public const uint MEMORY_PROPERTY_HOST_VISIBLE  = 0x00000002;
        public const uint MEMORY_PROPERTY_HOST_COHERENT = 0x00000004;
        public const uint FORMAT_R32G32B32_SFLOAT    = 106;
        public const uint FORMAT_D32_SFLOAT          = 126;
        public const uint IMAGE_TYPE_2D              = 1;
        public const uint IMAGE_TILING_OPTIMAL       = 0;
        public const uint IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT = 0x00000020;
        public const uint IMAGE_ASPECT_DEPTH_BIT     = 0x00000002;
        public const uint IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL = 3;
        public const uint COMPARE_OP_LESS            = 1;
        public const uint INDEX_TYPE_UINT32          = 1;
        public const uint VERTEX_INPUT_RATE_VERTEX   = 0;
        public const uint FORMAT_R32G32_SFLOAT       = 103;
        public const uint FORMAT_R8G8B8A8_UNORM      = 37;
        public const uint DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER = 1;
        public const uint FILTER_NEAREST             = 0;
        public const uint SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE = 2;
        public const uint SAMPLER_MIPMAP_MODE_NEAREST = 0;
        public const uint IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL = 7;
        public const uint IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL = 5;
        public const uint IMAGE_USAGE_TRANSFER_DST_BIT = 0x00000002;
        public const uint IMAGE_USAGE_SAMPLED_BIT    = 0x00000004;
        public const uint BUFFER_USAGE_TRANSFER_SRC_BIT = 0x00000001;
        public const uint ACCESS_TRANSFER_WRITE_BIT  = 0x00001000;
        public const uint ACCESS_SHADER_READ_BIT     = 0x00000020;
        public const uint PIPELINE_STAGE_TOP_OF_PIPE_BIT = 0x00000001;
        public const uint PIPELINE_STAGE_TRANSFER_BIT = 0x00001000;
        public const uint PIPELINE_STAGE_FRAGMENT_SHADER_BIT = 0x00000080;
        public const uint QUEUE_FAMILY_IGNORED       = 0xFFFFFFFF;
        public const uint COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT = 0x00000001;
        public const uint ACCESS_DEPTH_STENCIL_ATTACHMENT_READ  = 0x00000200;
        public const uint ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE = 0x00000400;
        public const uint PIPELINE_STAGE_EARLY_FRAGMENT_TESTS   = 0x00000100;
        public const uint PIPELINE_STAGE_LATE_FRAGMENT_TESTS    = 0x00000200;
        public const uint PIPELINE_STAGE_VERTEX_SHADER          = 0x00000008;
        public const uint API_VERSION_1_0               = 0x00400000;
        public const ulong UINT64_MAX                   = 0xFFFFFFFFFFFFFFFF;

        // --- loader ---
        public static var hLib: void*
        public static var getInstanceProc: delegate*<void*, byte*, void*>
        public static var getDeviceProc:   delegate*<void*, byte*, void*>

        // --- global / instance-level commands ---
        public static var vkCreateInstance:                           delegate*<void*, void*, void*, int>
        public static var vkCreateWin32SurfaceKHR:                    delegate*<void*, void*, void*, void*, int>
        public static var vkEnumeratePhysicalDevices:                 delegate*<void*, void*, void*, int>
        public static var vkGetPhysicalDeviceQueueFamilyProperties:   delegate*<void*, void*, void*, void>
        public static var vkGetPhysicalDeviceSurfaceSupportKHR:       delegate*<void*, uint, void*, void*, int>
        public static var vkGetPhysicalDeviceSurfaceCapabilitiesKHR:  delegate*<void*, void*, void*, int>
        public static var vkGetPhysicalDeviceSurfaceFormatsKHR:       delegate*<void*, void*, void*, void*, int>
        public static var vkGetPhysicalDeviceSurfacePresentModesKHR:  delegate*<void*, void*, void*, void*, int>
        public static var vkCreateDevice:                             delegate*<void*, void*, void*, void*, int>

        // --- device-level commands ---
        public static var vkGetDeviceQueue:         delegate*<void*, uint, uint, void*, void>
        public static var vkCreateSwapchainKHR:     delegate*<void*, void*, void*, void*, int>
        public static var vkGetSwapchainImagesKHR:  delegate*<void*, void*, void*, void*, int>
        public static var vkCreateImageView:        delegate*<void*, void*, void*, void*, int>
        public static var vkCreateRenderPass:       delegate*<void*, void*, void*, void*, int>
        public static var vkCreateFramebuffer:      delegate*<void*, void*, void*, void*, int>
        public static var vkCreateCommandPool:      delegate*<void*, void*, void*, void*, int>
        public static var vkAllocateCommandBuffers: delegate*<void*, void*, void*, int>
        public static var vkBeginCommandBuffer:     delegate*<void*, void*, int>
        public static var vkEndCommandBuffer:       delegate*<void*, int>
        public static var vkCmdBeginRenderPass:     delegate*<void*, void*, uint, void>
        public static var vkCmdEndRenderPass:       delegate*<void*, void>
        public static var vkCreateSemaphore:        delegate*<void*, void*, void*, void*, int>
        public static var vkCreateFence:            delegate*<void*, void*, void*, void*, int>
        public static var vkAcquireNextImageKHR:    delegate*<void*, void*, ulong, void*, void*, void*, int>
        public static var vkQueueSubmit:            delegate*<void*, uint, void*, void*, int>
        public static var vkQueuePresentKHR:        delegate*<void*, void*, int>
        public static var vkWaitForFences:          delegate*<void*, uint, void*, uint, ulong, int>
        public static var vkResetFences:            delegate*<void*, uint, void*, int>
        public static var vkDeviceWaitIdle:         delegate*<void*, int>
        public static var vkCreateShaderModule:     delegate*<void*, void*, void*, void*, int>
        public static var vkCreatePipelineLayout:   delegate*<void*, void*, void*, void*, int>
        public static var vkCreateGraphicsPipelines:delegate*<void*, void*, uint, void*, void*, void*, int>
        public static var vkCmdBindPipeline:        delegate*<void*, uint, void*, void>
        public static var vkCmdDraw:                delegate*<void*, uint, uint, uint, uint, void>
        public static var vkGetPhysicalDeviceMemoryProperties: delegate*<void*, void*, void>
        public static var vkCreateBuffer:           delegate*<void*, void*, void*, void*, int>
        public static var vkGetBufferMemoryRequirements: delegate*<void*, void*, void*, void>
        public static var vkAllocateMemory:         delegate*<void*, void*, void*, void*, int>
        public static var vkBindBufferMemory:       delegate*<void*, void*, void*, ulong, int>
        public static var vkMapMemory:              delegate*<void*, void*, ulong, ulong, uint, void*, int>
        public static var vkUnmapMemory:            delegate*<void*, void*, void>
        public static var vkCreateImage:            delegate*<void*, void*, void*, void*, int>
        public static var vkGetImageMemoryRequirements: delegate*<void*, void*, void*, void>
        public static var vkBindImageMemory:        delegate*<void*, void*, void*, ulong, int>
        public static var vkCmdBindVertexBuffers:   delegate*<void*, uint, uint, void*, void*, void>
        public static var vkCmdBindIndexBuffer:     delegate*<void*, void*, ulong, uint, void>
        public static var vkCmdDrawIndexed:         delegate*<void*, uint, uint, uint, int, uint, void>
        public static var vkCmdPushConstants:       delegate*<void*, void*, uint, uint, uint, void*, void>
        public static var vkDestroyBuffer:          delegate*<void*, void*, void*, void>
        public static var vkFreeMemory:             delegate*<void*, void*, void*, void>
        public static var vkCreateSampler:          delegate*<void*, void*, void*, void*, int>
        public static var vkCreateDescriptorSetLayout: delegate*<void*, void*, void*, void*, int>
        public static var vkCreateDescriptorPool:   delegate*<void*, void*, void*, void*, int>
        public static var vkAllocateDescriptorSets: delegate*<void*, void*, void*, int>
        public static var vkUpdateDescriptorSets:   delegate*<void*, uint, void*, uint, void*, void>
        public static var vkCmdBindDescriptorSets:  delegate*<void*, uint, void*, uint, uint, void*, uint, void*, void>
        public static var vkCmdCopyBufferToImage:   delegate*<void*, void*, void*, uint, uint, void*, void>
        public static var vkCmdPipelineBarrier:     delegate*<void*, uint, uint, uint, uint, void*, uint, void*, uint, void*, void>
        public static var vkQueueWaitIdle:          delegate*<void*, int>

        // Load the loader and the one global command we need.
        public static func LoadLoader() -> bool
        {
            hLib = Loader.LoadLibraryA("vulkan-1.dll".Ptr);
            if (hLib == null) return false;
            getInstanceProc = (delegate*<void*, byte*, void*>)Loader.GetProcAddress(hLib, "vkGetInstanceProcAddr".Ptr);
            if (getInstanceProc == null) return false;
            vkCreateInstance = (delegate*<void*, void*, void*, int>)getInstanceProc(null, "vkCreateInstance".Ptr);
            return vkCreateInstance != null;
        }

        // After an instance exists, resolve the instance-level commands.
        public static func LoadInstance(instance: void*)
        {
            getDeviceProc = (delegate*<void*, byte*, void*>)getInstanceProc(instance, "vkGetDeviceProcAddr".Ptr);
            vkCreateWin32SurfaceKHR                   = (delegate*<void*, void*, void*, void*, int>)getInstanceProc(instance, "vkCreateWin32SurfaceKHR".Ptr);
            vkEnumeratePhysicalDevices                = (delegate*<void*, void*, void*, int>)getInstanceProc(instance, "vkEnumeratePhysicalDevices".Ptr);
            vkGetPhysicalDeviceQueueFamilyProperties  = (delegate*<void*, void*, void*, void>)getInstanceProc(instance, "vkGetPhysicalDeviceQueueFamilyProperties".Ptr);
            vkGetPhysicalDeviceSurfaceSupportKHR      = (delegate*<void*, uint, void*, void*, int>)getInstanceProc(instance, "vkGetPhysicalDeviceSurfaceSupportKHR".Ptr);
            vkGetPhysicalDeviceSurfaceCapabilitiesKHR = (delegate*<void*, void*, void*, int>)getInstanceProc(instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR".Ptr);
            vkGetPhysicalDeviceSurfaceFormatsKHR      = (delegate*<void*, void*, void*, void*, int>)getInstanceProc(instance, "vkGetPhysicalDeviceSurfaceFormatsKHR".Ptr);
            vkGetPhysicalDeviceSurfacePresentModesKHR = (delegate*<void*, void*, void*, void*, int>)getInstanceProc(instance, "vkGetPhysicalDeviceSurfacePresentModesKHR".Ptr);
            vkCreateDevice                            = (delegate*<void*, void*, void*, void*, int>)getInstanceProc(instance, "vkCreateDevice".Ptr);
            vkGetPhysicalDeviceMemoryProperties       = (delegate*<void*, void*, void>)getInstanceProc(instance, "vkGetPhysicalDeviceMemoryProperties".Ptr);
        }

        // After a logical device exists, resolve the device-level commands.
        public static func LoadDevice(device: void*)
        {
            vkGetDeviceQueue         = (delegate*<void*, uint, uint, void*, void>)getDeviceProc(device, "vkGetDeviceQueue".Ptr);
            vkCreateSwapchainKHR     = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateSwapchainKHR".Ptr);
            vkGetSwapchainImagesKHR  = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkGetSwapchainImagesKHR".Ptr);
            vkCreateImageView        = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateImageView".Ptr);
            vkCreateRenderPass       = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateRenderPass".Ptr);
            vkCreateFramebuffer      = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateFramebuffer".Ptr);
            vkCreateCommandPool      = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateCommandPool".Ptr);
            vkAllocateCommandBuffers = (delegate*<void*, void*, void*, int>)getDeviceProc(device, "vkAllocateCommandBuffers".Ptr);
            vkBeginCommandBuffer     = (delegate*<void*, void*, int>)getDeviceProc(device, "vkBeginCommandBuffer".Ptr);
            vkEndCommandBuffer       = (delegate*<void*, int>)getDeviceProc(device, "vkEndCommandBuffer".Ptr);
            vkCmdBeginRenderPass     = (delegate*<void*, void*, uint, void>)getDeviceProc(device, "vkCmdBeginRenderPass".Ptr);
            vkCmdEndRenderPass       = (delegate*<void*, void>)getDeviceProc(device, "vkCmdEndRenderPass".Ptr);
            vkCreateSemaphore        = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateSemaphore".Ptr);
            vkCreateFence            = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateFence".Ptr);
            vkAcquireNextImageKHR    = (delegate*<void*, void*, ulong, void*, void*, void*, int>)getDeviceProc(device, "vkAcquireNextImageKHR".Ptr);
            vkQueueSubmit            = (delegate*<void*, uint, void*, void*, int>)getDeviceProc(device, "vkQueueSubmit".Ptr);
            vkQueuePresentKHR        = (delegate*<void*, void*, int>)getDeviceProc(device, "vkQueuePresentKHR".Ptr);
            vkWaitForFences          = (delegate*<void*, uint, void*, uint, ulong, int>)getDeviceProc(device, "vkWaitForFences".Ptr);
            vkResetFences            = (delegate*<void*, uint, void*, int>)getDeviceProc(device, "vkResetFences".Ptr);
            vkDeviceWaitIdle         = (delegate*<void*, int>)getDeviceProc(device, "vkDeviceWaitIdle".Ptr);
            vkCreateShaderModule     = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateShaderModule".Ptr);
            vkCreatePipelineLayout   = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreatePipelineLayout".Ptr);
            vkCreateGraphicsPipelines= (delegate*<void*, void*, uint, void*, void*, void*, int>)getDeviceProc(device, "vkCreateGraphicsPipelines".Ptr);
            vkCmdBindPipeline        = (delegate*<void*, uint, void*, void>)getDeviceProc(device, "vkCmdBindPipeline".Ptr);
            vkCmdDraw                = (delegate*<void*, uint, uint, uint, uint, void>)getDeviceProc(device, "vkCmdDraw".Ptr);
            vkCreateBuffer           = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateBuffer".Ptr);
            vkGetBufferMemoryRequirements = (delegate*<void*, void*, void*, void>)getDeviceProc(device, "vkGetBufferMemoryRequirements".Ptr);
            vkAllocateMemory         = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkAllocateMemory".Ptr);
            vkBindBufferMemory       = (delegate*<void*, void*, void*, ulong, int>)getDeviceProc(device, "vkBindBufferMemory".Ptr);
            vkMapMemory              = (delegate*<void*, void*, ulong, ulong, uint, void*, int>)getDeviceProc(device, "vkMapMemory".Ptr);
            vkUnmapMemory            = (delegate*<void*, void*, void>)getDeviceProc(device, "vkUnmapMemory".Ptr);
            vkCreateImage            = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateImage".Ptr);
            vkGetImageMemoryRequirements = (delegate*<void*, void*, void*, void>)getDeviceProc(device, "vkGetImageMemoryRequirements".Ptr);
            vkBindImageMemory        = (delegate*<void*, void*, void*, ulong, int>)getDeviceProc(device, "vkBindImageMemory".Ptr);
            vkCmdBindVertexBuffers   = (delegate*<void*, uint, uint, void*, void*, void>)getDeviceProc(device, "vkCmdBindVertexBuffers".Ptr);
            vkCmdBindIndexBuffer     = (delegate*<void*, void*, ulong, uint, void>)getDeviceProc(device, "vkCmdBindIndexBuffer".Ptr);
            vkCmdDrawIndexed         = (delegate*<void*, uint, uint, uint, int, uint, void>)getDeviceProc(device, "vkCmdDrawIndexed".Ptr);
            vkCmdPushConstants       = (delegate*<void*, void*, uint, uint, uint, void*, void>)getDeviceProc(device, "vkCmdPushConstants".Ptr);
            vkDestroyBuffer          = (delegate*<void*, void*, void*, void>)getDeviceProc(device, "vkDestroyBuffer".Ptr);
            vkFreeMemory             = (delegate*<void*, void*, void*, void>)getDeviceProc(device, "vkFreeMemory".Ptr);
            vkCreateSampler          = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateSampler".Ptr);
            vkCreateDescriptorSetLayout = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateDescriptorSetLayout".Ptr);
            vkCreateDescriptorPool   = (delegate*<void*, void*, void*, void*, int>)getDeviceProc(device, "vkCreateDescriptorPool".Ptr);
            vkAllocateDescriptorSets = (delegate*<void*, void*, void*, int>)getDeviceProc(device, "vkAllocateDescriptorSets".Ptr);
            vkUpdateDescriptorSets   = (delegate*<void*, uint, void*, uint, void*, void>)getDeviceProc(device, "vkUpdateDescriptorSets".Ptr);
            vkCmdBindDescriptorSets  = (delegate*<void*, uint, void*, uint, uint, void*, uint, void*, void>)getDeviceProc(device, "vkCmdBindDescriptorSets".Ptr);
            vkCmdCopyBufferToImage   = (delegate*<void*, void*, void*, uint, uint, void*, void>)getDeviceProc(device, "vkCmdCopyBufferToImage".Ptr);
            vkCmdPipelineBarrier     = (delegate*<void*, uint, uint, uint, uint, void*, uint, void*, uint, void*, void>)getDeviceProc(device, "vkCmdPipelineBarrier".Ptr);
            vkQueueWaitIdle          = (delegate*<void*, int>)getDeviceProc(device, "vkQueueWaitIdle".Ptr);
        }
    }

    // kernel32 dynamic-loading entry points.
    public memory_unsafe static class Loader
    {
        public static extern void* LoadLibraryA(byte* name);
        public static extern void* GetProcAddress(void* module, byte* name);
    }
}
