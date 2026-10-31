// =============================================================================
//  Bindings de Vulkan 1.0 (+ VK_KHR_surface, VK_KHR_swapchain y VK_KHR_xlib_surface o VK_KHR_win32_surface)
//  escritos en Faset. Los structs reproducen exactamente la disposición en memoria
//  de los de C; los handles no despachables son ulong y los despachables void*.
//  Todo el archivo es FFI: se declara entero como contexto memory_unsafe.
// =============================================================================
memory_unsafe;

namespace FasetStudio.Gfx
{
    public static class VK
    {
        public const uint ApiVersion10 = 4194304;  // VK_MAKE_VERSION(1, 0, 0)

        // VkStructureType
        public const int ST_APPLICATION_INFO = 0;
        public const int ST_INSTANCE_CREATE_INFO = 1;
        public const int ST_DEVICE_QUEUE_CREATE_INFO = 2;
        public const int ST_DEVICE_CREATE_INFO = 3;
        public const int ST_SUBMIT_INFO = 4;
        public const int ST_MEMORY_ALLOCATE_INFO = 5;
        public const int ST_FENCE_CREATE_INFO = 8;
        public const int ST_SEMAPHORE_CREATE_INFO = 9;
        public const int ST_BUFFER_CREATE_INFO = 12;
        public const int ST_IMAGE_CREATE_INFO = 14;
        public const int ST_IMAGE_VIEW_CREATE_INFO = 15;
        public const int ST_SHADER_MODULE_CREATE_INFO = 16;
        public const int ST_PIPELINE_SHADER_STAGE_CREATE_INFO = 18;
        public const int ST_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO = 19;
        public const int ST_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO = 20;
        public const int ST_PIPELINE_VIEWPORT_STATE_CREATE_INFO = 22;
        public const int ST_PIPELINE_RASTERIZATION_STATE_CREATE_INFO = 23;
        public const int ST_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO = 24;
        public const int ST_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO = 26;
        public const int ST_PIPELINE_DYNAMIC_STATE_CREATE_INFO = 27;
        public const int ST_GRAPHICS_PIPELINE_CREATE_INFO = 28;
        public const int ST_PIPELINE_LAYOUT_CREATE_INFO = 30;
        public const int ST_SAMPLER_CREATE_INFO = 31;
        public const int ST_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = 32;
        public const int ST_DESCRIPTOR_POOL_CREATE_INFO = 33;
        public const int ST_DESCRIPTOR_SET_ALLOCATE_INFO = 34;
        public const int ST_WRITE_DESCRIPTOR_SET = 35;
        public const int ST_FRAMEBUFFER_CREATE_INFO = 37;
        public const int ST_RENDER_PASS_CREATE_INFO = 38;
        public const int ST_COMMAND_POOL_CREATE_INFO = 39;
        public const int ST_COMMAND_BUFFER_ALLOCATE_INFO = 40;
        public const int ST_COMMAND_BUFFER_BEGIN_INFO = 42;
        public const int ST_RENDER_PASS_BEGIN_INFO = 43;
        public const int ST_IMAGE_MEMORY_BARRIER = 45;
        public const int ST_SWAPCHAIN_CREATE_INFO_KHR = 1000001000;
        public const int ST_PRESENT_INFO_KHR = 1000001001;
        public const int ST_XLIB_SURFACE_CREATE_INFO_KHR = 1000004000;
        public const int ST_WIN32_SURFACE_CREATE_INFO_KHR = 1000009000;

        // Resultados
        public const int SUCCESS = 0;
        public const int SUBOPTIMAL_KHR = 1000001003;
        public const int ERROR_OUT_OF_DATE_KHR = -1000001004;

        // Formatos
        public const int FORMAT_R8_UNORM = 9;
        public const int FORMAT_R8G8B8A8_UNORM = 37;
        public const int FORMAT_B8G8R8A8_UNORM = 44;
        public const int FORMAT_R32G32_SFLOAT = 103;
        public const int FORMAT_R32G32B32A32_SFLOAT = 109;

        // Layouts de imagen
        public const int LAYOUT_UNDEFINED = 0;
        public const int LAYOUT_COLOR_ATTACHMENT_OPTIMAL = 2;
        public const int LAYOUT_SHADER_READ_ONLY_OPTIMAL = 5;
        public const int LAYOUT_TRANSFER_SRC_OPTIMAL = 6;
        public const int LAYOUT_TRANSFER_DST_OPTIMAL = 7;
        public const int LAYOUT_PRESENT_SRC_KHR = 1000001002;

        // Flags varios
        public const uint QUEUE_GRAPHICS = 1;
        public const uint IMAGE_USAGE_TRANSFER_SRC = 1;
        public const uint IMAGE_USAGE_TRANSFER_DST = 2;
        public const uint IMAGE_USAGE_SAMPLED = 4;
        public const uint IMAGE_USAGE_COLOR_ATTACHMENT = 16;
        public const uint BUFFER_USAGE_TRANSFER_SRC = 1;
        public const uint BUFFER_USAGE_TRANSFER_DST = 2;
        public const uint BUFFER_USAGE_VERTEX = 128;
        public const uint MEMORY_DEVICE_LOCAL = 1;
        public const uint MEMORY_HOST_VISIBLE = 2;
        public const uint MEMORY_HOST_COHERENT = 4;
        public const uint SHADER_STAGE_VERTEX = 1;
        public const uint SHADER_STAGE_FRAGMENT = 16;
        public const uint ASPECT_COLOR = 1;
        public const uint STAGE_TOP_OF_PIPE = 1;
        public const uint STAGE_FRAGMENT_SHADER = 128;
        public const uint STAGE_COLOR_ATTACHMENT_OUTPUT = 1024;
        public const uint STAGE_TRANSFER = 4096;
        public const uint STAGE_HOST = 16384;
        public const uint ACCESS_SHADER_READ = 32;
        public const uint ACCESS_COLOR_ATTACHMENT_WRITE = 256;
        public const uint ACCESS_TRANSFER_READ = 2048;
        public const uint ACCESS_TRANSFER_WRITE = 4096;
        public const uint ACCESS_HOST_READ = 8192;
        public const uint SUBPASS_EXTERNAL = 4294967295;
        public const ulong WHOLE_SIZE = 18446744073709551615UL;
        public const ulong NO_TIMEOUT = 18446744073709551615UL;
    }

    // ------------------------------------------------------------------ structs

    public struct VkApplicationInfo
    {
        public var sType: int; public var pNext: void*;
        public var pApplicationName: byte*; public var applicationVersion: uint;
        public var pEngineName: byte*; public var engineVersion: uint; public var apiVersion: uint;
    }

    public struct VkInstanceCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var pApplicationInfo: VkApplicationInfo*;
        public var enabledLayerCount: uint; public var ppEnabledLayerNames: byte**;
        public var enabledExtensionCount: uint; public var ppEnabledExtensionNames: byte**;
    }

#if WINDOWS
    public struct VkWin32SurfaceCreateInfoKHR
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var hinstance: void*; public var hwnd: void*;
    }
#else
    public struct VkXlibSurfaceCreateInfoKHR
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var dpy: void*; public var window: ulong;
    }
#endif

    public struct VkDeviceQueueCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var queueFamilyIndex: uint; public var queueCount: uint; public var pQueuePriorities: float*;
    }

    public struct VkDeviceCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var queueCreateInfoCount: uint; public var pQueueCreateInfos: VkDeviceQueueCreateInfo*;
        public var enabledLayerCount: uint; public var ppEnabledLayerNames: byte**;
        public var enabledExtensionCount: uint; public var ppEnabledExtensionNames: byte**;
        public var pEnabledFeatures: void*;
    }

    public struct VkQueueFamilyProperties
    {
        public var queueFlags: uint; public var queueCount: uint; public var timestampValidBits: uint;
        public var granularityW: uint; public var granularityH: uint; public var granularityD: uint;
    }

    public struct VkSurfaceCapabilitiesKHR
    {
        public var minImageCount: uint; public var maxImageCount: uint;
        public var currentWidth: uint; public var currentHeight: uint;
        public var minWidth: uint; public var minHeight: uint;
        public var maxWidth: uint; public var maxHeight: uint;
        public var maxImageArrayLayers: uint; public var supportedTransforms: uint; public var currentTransform: uint;
        public var supportedCompositeAlpha: uint; public var supportedUsageFlags: uint;
    }

    public struct VkSurfaceFormatKHR { public var format: int; public var colorSpace: int; }

    public struct VkSwapchainCreateInfoKHR
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var surface: ulong; public var minImageCount: uint;
        public var imageFormat: int; public var imageColorSpace: int;
        public var width: uint; public var height: uint; public var imageArrayLayers: uint; public var imageUsage: uint;
        public var imageSharingMode: int; public var queueFamilyIndexCount: uint; public var pQueueFamilyIndices: uint*;
        public var preTransform: uint; public var compositeAlpha: uint; public var presentMode: int; public var clipped: uint;
        public var oldSwapchain: ulong;
    }

    public struct VkImageViewCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var image: ulong; public var viewType: int; public var format: int;
        public var swizzleR: int; public var swizzleG: int; public var swizzleB: int; public var swizzleA: int;
        public var aspectMask: uint; public var baseMipLevel: uint; public var levelCount: uint; public var baseArrayLayer: uint; public var layerCount: uint;
    }

    public struct VkAttachmentDescription
    {
        public var flags: uint; public var format: int; public var samples: int;
        public var loadOp: int; public var storeOp: int; public var stencilLoadOp: int; public var stencilStoreOp: int;
        public var initialLayout: int; public var finalLayout: int;
    }

    public struct VkAttachmentReference { public var attachment: uint; public var layout: int; }

    public struct VkSubpassDescription
    {
        public var flags: uint; public var pipelineBindPoint: int;
        public var inputAttachmentCount: uint; public var pInputAttachments: void*;
        public var colorAttachmentCount: uint; public var pColorAttachments: VkAttachmentReference*;
        public var pResolveAttachments: void*; public var pDepthStencilAttachment: void*;
        public var preserveAttachmentCount: uint; public var pPreserveAttachments: uint*;
    }

    public struct VkSubpassDependency
    {
        public var srcSubpass: uint; public var dstSubpass: uint;
        public var srcStageMask: uint; public var dstStageMask: uint;
        public var srcAccessMask: uint; public var dstAccessMask: uint; public var dependencyFlags: uint;
    }

    public struct VkRenderPassCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var attachmentCount: uint; public var pAttachments: VkAttachmentDescription*;
        public var subpassCount: uint; public var pSubpasses: VkSubpassDescription*;
        public var dependencyCount: uint; public var pDependencies: VkSubpassDependency*;
    }

    public struct VkFramebufferCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var renderPass: ulong; public var attachmentCount: uint; public var pAttachments: ulong*;
        public var width: uint; public var height: uint; public var layers: uint;
    }

    public struct VkShaderModuleCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var codeSize: ulong; public var pCode: uint*;
    }

    public struct VkPipelineShaderStageCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var stage: uint; public var module: ulong; public var pName: byte*; public var pSpecializationInfo: void*;
    }

    public struct VkVertexInputBindingDescription { public var binding: uint; public var stride: uint; public var inputRate: int; }

    public struct VkVertexInputAttributeDescription { public var location: uint; public var binding: uint; public var format: int; public var offset: uint; }

    public struct VkPipelineVertexInputStateCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var vertexBindingDescriptionCount: uint; public var pVertexBindingDescriptions: VkVertexInputBindingDescription*;
        public var vertexAttributeDescriptionCount: uint; public var pVertexAttributeDescriptions: VkVertexInputAttributeDescription*;
    }

    public struct VkPipelineInputAssemblyStateCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var topology: int; public var primitiveRestartEnable: uint;
    }

    public struct VkPipelineViewportStateCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var viewportCount: uint; public var pViewports: void*; public var scissorCount: uint; public var pScissors: void*;
    }

    public struct VkPipelineRasterizationStateCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var depthClampEnable: uint; public var rasterizerDiscardEnable: uint;
        public var polygonMode: int; public var cullMode: uint; public var frontFace: int;
        public var depthBiasEnable: uint; public var depthBiasConstantFactor: float; public var depthBiasClamp: float;
        public var depthBiasSlopeFactor: float; public var lineWidth: float;
    }

    public struct VkPipelineMultisampleStateCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var rasterizationSamples: int; public var sampleShadingEnable: uint; public var minSampleShading: float;
        public var pSampleMask: void*; public var alphaToCoverageEnable: uint; public var alphaToOneEnable: uint;
    }

    public struct VkPipelineColorBlendAttachmentState
    {
        public var blendEnable: uint;
        public var srcColorBlendFactor: int; public var dstColorBlendFactor: int; public var colorBlendOp: int;
        public var srcAlphaBlendFactor: int; public var dstAlphaBlendFactor: int; public var alphaBlendOp: int;
        public var colorWriteMask: uint;
    }

    public struct VkPipelineColorBlendStateCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var logicOpEnable: uint; public var logicOp: int;
        public var attachmentCount: uint; public var pAttachments: VkPipelineColorBlendAttachmentState*;
        public var blendR: float; public var blendG: float; public var blendB: float; public var blendA: float;
    }

    public struct VkPipelineDynamicStateCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var dynamicStateCount: uint; public var pDynamicStates: int*;
    }

    public struct VkPushConstantRange { public var stageFlags: uint; public var offset: uint; public var size: uint; }

    public struct VkPipelineLayoutCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var setLayoutCount: uint; public var pSetLayouts: ulong*;
        public var pushConstantRangeCount: uint; public var pPushConstantRanges: VkPushConstantRange*;
    }

    public struct VkGraphicsPipelineCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var stageCount: uint; public var pStages: VkPipelineShaderStageCreateInfo*;
        public var pVertexInputState: void*; public var pInputAssemblyState: void*; public var pTessellationState: void*;
        public var pViewportState: void*; public var pRasterizationState: void*; public var pMultisampleState: void*;
        public var pDepthStencilState: void*; public var pColorBlendState: void*; public var pDynamicState: void*;
        public var layout: ulong; public var renderPass: ulong; public var subpass: uint;
        public var basePipelineHandle: ulong; public var basePipelineIndex: int;
    }

    public struct VkDescriptorSetLayoutBinding
    {
        public var binding: uint; public var descriptorType: int; public var descriptorCount: uint;
        public var stageFlags: uint; public var pImmutableSamplers: ulong*;
    }

    public struct VkDescriptorSetLayoutCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var bindingCount: uint; public var pBindings: VkDescriptorSetLayoutBinding*;
    }

    public struct VkDescriptorPoolSize { public var type: int; public var descriptorCount: uint; }

    public struct VkDescriptorPoolCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var maxSets: uint; public var poolSizeCount: uint; public var pPoolSizes: VkDescriptorPoolSize*;
    }

    public struct VkDescriptorSetAllocateInfo
    {
        public var sType: int; public var pNext: void*;
        public var descriptorPool: ulong; public var descriptorSetCount: uint; public var pSetLayouts: ulong*;
    }

    public struct VkDescriptorImageInfo { public var sampler: ulong; public var imageView: ulong; public var imageLayout: int; }

    public struct VkWriteDescriptorSet
    {
        public var sType: int; public var pNext: void*;
        public var dstSet: ulong; public var dstBinding: uint; public var dstArrayElement: uint;
        public var descriptorCount: uint; public var descriptorType: int;
        public var pImageInfo: VkDescriptorImageInfo*; public var pBufferInfo: void*; public var pTexelBufferView: void*;
    }

    public struct VkSamplerCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var magFilter: int; public var minFilter: int; public var mipmapMode: int;
        public var addressModeU: int; public var addressModeV: int; public var addressModeW: int;
        public var mipLodBias: float; public var anisotropyEnable: uint; public var maxAnisotropy: float;
        public var compareEnable: uint; public var compareOp: int; public var minLod: float; public var maxLod: float;
        public var borderColor: int; public var unnormalizedCoordinates: uint;
    }

    public struct VkImageCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var imageType: int; public var format: int;
        public var width: uint; public var height: uint; public var depth: uint;
        public var mipLevels: uint; public var arrayLayers: uint; public var samples: int; public var tiling: int;
        public var usage: uint; public var sharingMode: int;
        public var queueFamilyIndexCount: uint; public var pQueueFamilyIndices: uint*; public var initialLayout: int;
    }

    public struct VkMemoryRequirements { public var size: ulong; public var alignment: ulong; public var memoryTypeBits: uint; }

    public struct VkMemoryAllocateInfo
    {
        public var sType: int; public var pNext: void*; public var allocationSize: ulong; public var memoryTypeIndex: uint;
    }

    public struct VkBufferCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint;
        public var size: ulong; public var usage: uint; public var sharingMode: int;
        public var queueFamilyIndexCount: uint; public var pQueueFamilyIndices: uint*;
    }

    public struct VkCommandPoolCreateInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint; public var queueFamilyIndex: uint;
    }

    public struct VkCommandBufferAllocateInfo
    {
        public var sType: int; public var pNext: void*; public var commandPool: ulong; public var level: int; public var commandBufferCount: uint;
    }

    public struct VkCommandBufferBeginInfo
    {
        public var sType: int; public var pNext: void*; public var flags: uint; public var pInheritanceInfo: void*;
    }

    public struct VkClearColor { public var R: float; public var G: float; public var B: float; public var A: float; }

    public struct VkRenderPassBeginInfo
    {
        public var sType: int; public var pNext: void*;
        public var renderPass: ulong; public var framebuffer: ulong;
        public var x: int; public var y: int; public var width: uint; public var height: uint;
        public var clearValueCount: uint; public var pClearValues: VkClearColor*;
    }

    public struct VkViewport
    {
        public var x: float; public var y: float; public var width: float; public var height: float;
        public var minDepth: float; public var maxDepth: float;
    }

    public struct VkRect2D { public var x: int; public var y: int; public var width: uint; public var height: uint; }

    public struct VkImageMemoryBarrier
    {
        public var sType: int; public var pNext: void*;
        public var srcAccessMask: uint; public var dstAccessMask: uint;
        public var oldLayout: int; public var newLayout: int;
        public var srcQueueFamilyIndex: uint; public var dstQueueFamilyIndex: uint;
        public var image: ulong;
        public var aspectMask: uint; public var baseMipLevel: uint; public var levelCount: uint; public var baseArrayLayer: uint; public var layerCount: uint;
    }

    public struct VkBufferImageCopy
    {
        public var bufferOffset: ulong; public var bufferRowLength: uint; public var bufferImageHeight: uint;
        public var aspectMask: uint; public var mipLevel: uint; public var baseArrayLayer: uint; public var layerCount: uint;
        public var offsetX: int; public var offsetY: int; public var offsetZ: int;
        public var width: uint; public var height: uint; public var depth: uint;
    }

    public struct VkSubmitInfo
    {
        public var sType: int; public var pNext: void*;
        public var waitSemaphoreCount: uint; public var pWaitSemaphores: ulong*; public var pWaitDstStageMask: uint*;
        public var commandBufferCount: uint; public var pCommandBuffers: void**;
        public var signalSemaphoreCount: uint; public var pSignalSemaphores: ulong*;
    }

    public struct VkPresentInfoKHR
    {
        public var sType: int; public var pNext: void*;
        public var waitSemaphoreCount: uint; public var pWaitSemaphores: ulong*;
        public var swapchainCount: uint; public var pSwapchains: ulong*; public var pImageIndices: uint*; public var pResults: int*;
    }

    public struct VkSimpleCreateInfo { public var sType: int; public var pNext: void*; public var flags: uint; }

    // ------------------------------------------------------------------ funciones

    static extern int vkCreateInstance(VkInstanceCreateInfo* info, void* alloc, void** instance);
    static extern void vkDestroyInstance(void* instance, void* alloc);
    static extern int vkEnumeratePhysicalDevices(void* instance, uint* count, void** devices);
    static extern void vkGetPhysicalDeviceProperties(void* pd, void* props);
    static extern void vkGetPhysicalDeviceQueueFamilyProperties(void* pd, uint* count, VkQueueFamilyProperties* props);
    static extern void vkGetPhysicalDeviceMemoryProperties(void* pd, void* props);
    static extern int vkCreateDevice(void* pd, VkDeviceCreateInfo* info, void* alloc, void** device);
    static extern void vkDestroyDevice(void* device, void* alloc);
    static extern void vkGetDeviceQueue(void* device, uint family, uint index, void** queue);
    static extern int vkDeviceWaitIdle(void* device);

#if WINDOWS
    static extern int vkCreateWin32SurfaceKHR(void* instance, VkWin32SurfaceCreateInfoKHR* info, void* alloc, ulong* surface);
    // vulkan-1.dll se carga al arrancar (native/windows/vulkan_loader.c): 0 si no está instalado.
    static extern int faset_vk_load();
#else
    static extern int vkCreateXlibSurfaceKHR(void* instance, VkXlibSurfaceCreateInfoKHR* info, void* alloc, ulong* surface);
#endif
    static extern void vkDestroySurfaceKHR(void* instance, ulong surface, void* alloc);
    static extern int vkGetPhysicalDeviceSurfaceSupportKHR(void* pd, uint family, ulong surface, uint* supported);
    static extern int vkGetPhysicalDeviceSurfaceCapabilitiesKHR(void* pd, ulong surface, VkSurfaceCapabilitiesKHR* caps);
    static extern int vkGetPhysicalDeviceSurfaceFormatsKHR(void* pd, ulong surface, uint* count, VkSurfaceFormatKHR* formats);
    static extern int vkCreateSwapchainKHR(void* device, VkSwapchainCreateInfoKHR* info, void* alloc, ulong* swapchain);
    static extern void vkDestroySwapchainKHR(void* device, ulong swapchain, void* alloc);
    static extern int vkGetSwapchainImagesKHR(void* device, ulong swapchain, uint* count, ulong* images);
    static extern int vkAcquireNextImageKHR(void* device, ulong swapchain, ulong timeout, ulong semaphore, ulong fence, uint* index);
    static extern int vkQueuePresentKHR(void* queue, VkPresentInfoKHR* info);

    static extern int vkCreateImageView(void* device, VkImageViewCreateInfo* info, void* alloc, ulong* view);
    static extern void vkDestroyImageView(void* device, ulong view, void* alloc);
    static extern int vkCreateRenderPass(void* device, VkRenderPassCreateInfo* info, void* alloc, ulong* pass);
    static extern void vkDestroyRenderPass(void* device, ulong pass, void* alloc);
    static extern int vkCreateFramebuffer(void* device, VkFramebufferCreateInfo* info, void* alloc, ulong* fb);
    static extern void vkDestroyFramebuffer(void* device, ulong fb, void* alloc);
    static extern int vkCreateShaderModule(void* device, VkShaderModuleCreateInfo* info, void* alloc, ulong* module);
    static extern void vkDestroyShaderModule(void* device, ulong module, void* alloc);
    static extern int vkCreatePipelineLayout(void* device, VkPipelineLayoutCreateInfo* info, void* alloc, ulong* layout);
    static extern void vkDestroyPipelineLayout(void* device, ulong layout, void* alloc);
    static extern int vkCreateGraphicsPipelines(void* device, ulong cache, uint count, VkGraphicsPipelineCreateInfo* infos, void* alloc, ulong* pipelines);
    static extern void vkDestroyPipeline(void* device, ulong pipeline, void* alloc);
    static extern int vkCreateDescriptorSetLayout(void* device, VkDescriptorSetLayoutCreateInfo* info, void* alloc, ulong* layout);
    static extern void vkDestroyDescriptorSetLayout(void* device, ulong layout, void* alloc);
    static extern int vkCreateDescriptorPool(void* device, VkDescriptorPoolCreateInfo* info, void* alloc, ulong* pool);
    static extern void vkDestroyDescriptorPool(void* device, ulong pool, void* alloc);
    static extern int vkAllocateDescriptorSets(void* device, VkDescriptorSetAllocateInfo* info, ulong* sets);
    static extern void vkUpdateDescriptorSets(void* device, uint writeCount, VkWriteDescriptorSet* writes, uint copyCount, void* copies);
    static extern int vkCreateSampler(void* device, VkSamplerCreateInfo* info, void* alloc, ulong* sampler);
    static extern void vkDestroySampler(void* device, ulong sampler, void* alloc);
    static extern int vkCreateImage(void* device, VkImageCreateInfo* info, void* alloc, ulong* image);
    static extern void vkDestroyImage(void* device, ulong image, void* alloc);
    static extern void vkGetImageMemoryRequirements(void* device, ulong image, VkMemoryRequirements* req);
    static extern int vkBindImageMemory(void* device, ulong image, ulong memory, ulong offset);
    static extern int vkCreateBuffer(void* device, VkBufferCreateInfo* info, void* alloc, ulong* buffer);
    static extern void vkDestroyBuffer(void* device, ulong buffer, void* alloc);
    static extern void vkGetBufferMemoryRequirements(void* device, ulong buffer, VkMemoryRequirements* req);
    static extern int vkBindBufferMemory(void* device, ulong buffer, ulong memory, ulong offset);
    static extern int vkAllocateMemory(void* device, VkMemoryAllocateInfo* info, void* alloc, ulong* memory);
    static extern void vkFreeMemory(void* device, ulong memory, void* alloc);
    static extern int vkMapMemory(void* device, ulong memory, ulong offset, ulong size, uint flags, void** data);
    static extern void vkUnmapMemory(void* device, ulong memory);

    static extern int vkCreateCommandPool(void* device, VkCommandPoolCreateInfo* info, void* alloc, ulong* pool);
    static extern void vkDestroyCommandPool(void* device, ulong pool, void* alloc);
    static extern int vkAllocateCommandBuffers(void* device, VkCommandBufferAllocateInfo* info, void** buffers);
    static extern int vkBeginCommandBuffer(void* cb, VkCommandBufferBeginInfo* info);
    static extern int vkEndCommandBuffer(void* cb);
    static extern int vkResetCommandBuffer(void* cb, uint flags);
    static extern void vkCmdBeginRenderPass(void* cb, VkRenderPassBeginInfo* info, int contents);
    static extern void vkCmdEndRenderPass(void* cb);
    static extern void vkCmdBindPipeline(void* cb, int bindPoint, ulong pipeline);
    static extern void vkCmdBindVertexBuffers(void* cb, uint first, uint count, ulong* buffers, ulong* offsets);
    static extern void vkCmdBindDescriptorSets(void* cb, int bindPoint, ulong layout, uint firstSet, uint count, ulong* sets, uint dynamicCount, uint* dynamicOffsets);
    static extern void vkCmdPushConstants(void* cb, ulong layout, uint stages, uint offset, uint size, void* values);
    static extern void vkCmdSetViewport(void* cb, uint first, uint count, VkViewport* viewports);
    static extern void vkCmdSetScissor(void* cb, uint first, uint count, VkRect2D* scissors);
    static extern void vkCmdDraw(void* cb, uint vertexCount, uint instanceCount, uint firstVertex, uint firstInstance);
    static extern void vkCmdPipelineBarrier(void* cb, uint srcStage, uint dstStage, uint dependencyFlags, uint memoryBarrierCount, void* memoryBarriers, uint bufferBarrierCount, void* bufferBarriers, uint imageBarrierCount, VkImageMemoryBarrier* imageBarriers);
    static extern void vkCmdCopyBufferToImage(void* cb, ulong buffer, ulong image, int layout, uint regionCount, VkBufferImageCopy* regions);
    static extern void vkCmdCopyImageToBuffer(void* cb, ulong image, int layout, ulong buffer, uint regionCount, VkBufferImageCopy* regions);
    static extern int vkQueueSubmit(void* queue, uint count, VkSubmitInfo* submits, ulong fence);
    static extern int vkQueueWaitIdle(void* queue);
    static extern int vkCreateSemaphore(void* device, VkSimpleCreateInfo* info, void* alloc, ulong* semaphore);
    static extern void vkDestroySemaphore(void* device, ulong semaphore, void* alloc);
    static extern int vkCreateFence(void* device, VkSimpleCreateInfo* info, void* alloc, ulong* fence);
    static extern void vkDestroyFence(void* device, ulong fence, void* alloc);
    static extern int vkWaitForFences(void* device, uint count, ulong* fences, uint waitAll, ulong timeout);
    static extern int vkResetFences(void* device, uint count, ulong* fences);
}
