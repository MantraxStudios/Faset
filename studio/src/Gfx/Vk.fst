// =============================================================================
//  Bindings de Vulkan 1.0 (+ VK_KHR_surface, VK_KHR_swapchain, VK_KHR_xlib_surface)
//  escritos en Faset. Los structs reproducen exactamente la disposición en memoria
//  de los de C; los handles no despachables son ulong y los despachables void*.
// =============================================================================
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
        public int sType; public void* pNext;
        public byte* pApplicationName; public uint applicationVersion;
        public byte* pEngineName; public uint engineVersion; public uint apiVersion;
    }

    public struct VkInstanceCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public VkApplicationInfo* pApplicationInfo;
        public uint enabledLayerCount; public byte** ppEnabledLayerNames;
        public uint enabledExtensionCount; public byte** ppEnabledExtensionNames;
    }

    public struct VkXlibSurfaceCreateInfoKHR
    {
        public int sType; public void* pNext; public uint flags;
        public void* dpy; public ulong window;
    }

    public struct VkDeviceQueueCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint queueFamilyIndex; public uint queueCount; public float* pQueuePriorities;
    }

    public struct VkDeviceCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint queueCreateInfoCount; public VkDeviceQueueCreateInfo* pQueueCreateInfos;
        public uint enabledLayerCount; public byte** ppEnabledLayerNames;
        public uint enabledExtensionCount; public byte** ppEnabledExtensionNames;
        public void* pEnabledFeatures;
    }

    public struct VkQueueFamilyProperties
    {
        public uint queueFlags; public uint queueCount; public uint timestampValidBits;
        public uint granularityW; public uint granularityH; public uint granularityD;
    }

    public struct VkSurfaceCapabilitiesKHR
    {
        public uint minImageCount; public uint maxImageCount;
        public uint currentWidth; public uint currentHeight;
        public uint minWidth; public uint minHeight;
        public uint maxWidth; public uint maxHeight;
        public uint maxImageArrayLayers; public uint supportedTransforms; public uint currentTransform;
        public uint supportedCompositeAlpha; public uint supportedUsageFlags;
    }

    public struct VkSurfaceFormatKHR { public int format; public int colorSpace; }

    public struct VkSwapchainCreateInfoKHR
    {
        public int sType; public void* pNext; public uint flags;
        public ulong surface; public uint minImageCount;
        public int imageFormat; public int imageColorSpace;
        public uint width; public uint height; public uint imageArrayLayers; public uint imageUsage;
        public int imageSharingMode; public uint queueFamilyIndexCount; public uint* pQueueFamilyIndices;
        public uint preTransform; public uint compositeAlpha; public int presentMode; public uint clipped;
        public ulong oldSwapchain;
    }

    public struct VkImageViewCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public ulong image; public int viewType; public int format;
        public int swizzleR; public int swizzleG; public int swizzleB; public int swizzleA;
        public uint aspectMask; public uint baseMipLevel; public uint levelCount; public uint baseArrayLayer; public uint layerCount;
    }

    public struct VkAttachmentDescription
    {
        public uint flags; public int format; public int samples;
        public int loadOp; public int storeOp; public int stencilLoadOp; public int stencilStoreOp;
        public int initialLayout; public int finalLayout;
    }

    public struct VkAttachmentReference { public uint attachment; public int layout; }

    public struct VkSubpassDescription
    {
        public uint flags; public int pipelineBindPoint;
        public uint inputAttachmentCount; public void* pInputAttachments;
        public uint colorAttachmentCount; public VkAttachmentReference* pColorAttachments;
        public void* pResolveAttachments; public void* pDepthStencilAttachment;
        public uint preserveAttachmentCount; public uint* pPreserveAttachments;
    }

    public struct VkSubpassDependency
    {
        public uint srcSubpass; public uint dstSubpass;
        public uint srcStageMask; public uint dstStageMask;
        public uint srcAccessMask; public uint dstAccessMask; public uint dependencyFlags;
    }

    public struct VkRenderPassCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint attachmentCount; public VkAttachmentDescription* pAttachments;
        public uint subpassCount; public VkSubpassDescription* pSubpasses;
        public uint dependencyCount; public VkSubpassDependency* pDependencies;
    }

    public struct VkFramebufferCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public ulong renderPass; public uint attachmentCount; public ulong* pAttachments;
        public uint width; public uint height; public uint layers;
    }

    public struct VkShaderModuleCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public ulong codeSize; public uint* pCode;
    }

    public struct VkPipelineShaderStageCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint stage; public ulong module; public byte* pName; public void* pSpecializationInfo;
    }

    public struct VkVertexInputBindingDescription { public uint binding; public uint stride; public int inputRate; }

    public struct VkVertexInputAttributeDescription { public uint location; public uint binding; public int format; public uint offset; }

    public struct VkPipelineVertexInputStateCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint vertexBindingDescriptionCount; public VkVertexInputBindingDescription* pVertexBindingDescriptions;
        public uint vertexAttributeDescriptionCount; public VkVertexInputAttributeDescription* pVertexAttributeDescriptions;
    }

    public struct VkPipelineInputAssemblyStateCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public int topology; public uint primitiveRestartEnable;
    }

    public struct VkPipelineViewportStateCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint viewportCount; public void* pViewports; public uint scissorCount; public void* pScissors;
    }

    public struct VkPipelineRasterizationStateCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint depthClampEnable; public uint rasterizerDiscardEnable;
        public int polygonMode; public uint cullMode; public int frontFace;
        public uint depthBiasEnable; public float depthBiasConstantFactor; public float depthBiasClamp;
        public float depthBiasSlopeFactor; public float lineWidth;
    }

    public struct VkPipelineMultisampleStateCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public int rasterizationSamples; public uint sampleShadingEnable; public float minSampleShading;
        public void* pSampleMask; public uint alphaToCoverageEnable; public uint alphaToOneEnable;
    }

    public struct VkPipelineColorBlendAttachmentState
    {
        public uint blendEnable;
        public int srcColorBlendFactor; public int dstColorBlendFactor; public int colorBlendOp;
        public int srcAlphaBlendFactor; public int dstAlphaBlendFactor; public int alphaBlendOp;
        public uint colorWriteMask;
    }

    public struct VkPipelineColorBlendStateCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint logicOpEnable; public int logicOp;
        public uint attachmentCount; public VkPipelineColorBlendAttachmentState* pAttachments;
        public float blendR; public float blendG; public float blendB; public float blendA;
    }

    public struct VkPipelineDynamicStateCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint dynamicStateCount; public int* pDynamicStates;
    }

    public struct VkPushConstantRange { public uint stageFlags; public uint offset; public uint size; }

    public struct VkPipelineLayoutCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint setLayoutCount; public ulong* pSetLayouts;
        public uint pushConstantRangeCount; public VkPushConstantRange* pPushConstantRanges;
    }

    public struct VkGraphicsPipelineCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint stageCount; public VkPipelineShaderStageCreateInfo* pStages;
        public void* pVertexInputState; public void* pInputAssemblyState; public void* pTessellationState;
        public void* pViewportState; public void* pRasterizationState; public void* pMultisampleState;
        public void* pDepthStencilState; public void* pColorBlendState; public void* pDynamicState;
        public ulong layout; public ulong renderPass; public uint subpass;
        public ulong basePipelineHandle; public int basePipelineIndex;
    }

    public struct VkDescriptorSetLayoutBinding
    {
        public uint binding; public int descriptorType; public uint descriptorCount;
        public uint stageFlags; public ulong* pImmutableSamplers;
    }

    public struct VkDescriptorSetLayoutCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint bindingCount; public VkDescriptorSetLayoutBinding* pBindings;
    }

    public struct VkDescriptorPoolSize { public int type; public uint descriptorCount; }

    public struct VkDescriptorPoolCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public uint maxSets; public uint poolSizeCount; public VkDescriptorPoolSize* pPoolSizes;
    }

    public struct VkDescriptorSetAllocateInfo
    {
        public int sType; public void* pNext;
        public ulong descriptorPool; public uint descriptorSetCount; public ulong* pSetLayouts;
    }

    public struct VkDescriptorImageInfo { public ulong sampler; public ulong imageView; public int imageLayout; }

    public struct VkWriteDescriptorSet
    {
        public int sType; public void* pNext;
        public ulong dstSet; public uint dstBinding; public uint dstArrayElement;
        public uint descriptorCount; public int descriptorType;
        public VkDescriptorImageInfo* pImageInfo; public void* pBufferInfo; public void* pTexelBufferView;
    }

    public struct VkSamplerCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public int magFilter; public int minFilter; public int mipmapMode;
        public int addressModeU; public int addressModeV; public int addressModeW;
        public float mipLodBias; public uint anisotropyEnable; public float maxAnisotropy;
        public uint compareEnable; public int compareOp; public float minLod; public float maxLod;
        public int borderColor; public uint unnormalizedCoordinates;
    }

    public struct VkImageCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public int imageType; public int format;
        public uint width; public uint height; public uint depth;
        public uint mipLevels; public uint arrayLayers; public int samples; public int tiling;
        public uint usage; public int sharingMode;
        public uint queueFamilyIndexCount; public uint* pQueueFamilyIndices; public int initialLayout;
    }

    public struct VkMemoryRequirements { public ulong size; public ulong alignment; public uint memoryTypeBits; }

    public struct VkMemoryAllocateInfo
    {
        public int sType; public void* pNext; public ulong allocationSize; public uint memoryTypeIndex;
    }

    public struct VkBufferCreateInfo
    {
        public int sType; public void* pNext; public uint flags;
        public ulong size; public uint usage; public int sharingMode;
        public uint queueFamilyIndexCount; public uint* pQueueFamilyIndices;
    }

    public struct VkCommandPoolCreateInfo
    {
        public int sType; public void* pNext; public uint flags; public uint queueFamilyIndex;
    }

    public struct VkCommandBufferAllocateInfo
    {
        public int sType; public void* pNext; public ulong commandPool; public int level; public uint commandBufferCount;
    }

    public struct VkCommandBufferBeginInfo
    {
        public int sType; public void* pNext; public uint flags; public void* pInheritanceInfo;
    }

    public struct VkClearColor { public float R; public float G; public float B; public float A; }

    public struct VkRenderPassBeginInfo
    {
        public int sType; public void* pNext;
        public ulong renderPass; public ulong framebuffer;
        public int x; public int y; public uint width; public uint height;
        public uint clearValueCount; public VkClearColor* pClearValues;
    }

    public struct VkViewport
    {
        public float x; public float y; public float width; public float height;
        public float minDepth; public float maxDepth;
    }

    public struct VkRect2D { public int x; public int y; public uint width; public uint height; }

    public struct VkImageMemoryBarrier
    {
        public int sType; public void* pNext;
        public uint srcAccessMask; public uint dstAccessMask;
        public int oldLayout; public int newLayout;
        public uint srcQueueFamilyIndex; public uint dstQueueFamilyIndex;
        public ulong image;
        public uint aspectMask; public uint baseMipLevel; public uint levelCount; public uint baseArrayLayer; public uint layerCount;
    }

    public struct VkBufferImageCopy
    {
        public ulong bufferOffset; public uint bufferRowLength; public uint bufferImageHeight;
        public uint aspectMask; public uint mipLevel; public uint baseArrayLayer; public uint layerCount;
        public int offsetX; public int offsetY; public int offsetZ;
        public uint width; public uint height; public uint depth;
    }

    public struct VkSubmitInfo
    {
        public int sType; public void* pNext;
        public uint waitSemaphoreCount; public ulong* pWaitSemaphores; public uint* pWaitDstStageMask;
        public uint commandBufferCount; public void** pCommandBuffers;
        public uint signalSemaphoreCount; public ulong* pSignalSemaphores;
    }

    public struct VkPresentInfoKHR
    {
        public int sType; public void* pNext;
        public uint waitSemaphoreCount; public ulong* pWaitSemaphores;
        public uint swapchainCount; public ulong* pSwapchains; public uint* pImageIndices; public int* pResults;
    }

    public struct VkSimpleCreateInfo { public int sType; public void* pNext; public uint flags; }

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

    static extern int vkCreateXlibSurfaceKHR(void* instance, VkXlibSurfaceCreateInfoKHR* info, void* alloc, ulong* surface);
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
