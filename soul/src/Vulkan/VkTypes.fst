// =============================================================================
//  Soul - Vulkan structure definitions.
//
//  Every struct mirrors the exact C field order and type of its Vulkan
//  counterpart, so Faset generates an ABI-identical C struct. Nested structs
//  (VkExtent2D, VkOffset2D, component mappings, subresource ranges) are flattened
//  into scalar fields with the same layout to keep offsets obvious.
// =============================================================================
using std;

namespace Soul.Vulkan
{
    public memory_unsafe struct VkApplicationInfo
    {
        var sType: uint
        var pNext: void*
        var pApplicationName: byte*
        var applicationVersion: uint
        var pEngineName: byte*
        var engineVersion: uint
        var apiVersion: uint
    }

    public memory_unsafe struct VkInstanceCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var pApplicationInfo: void*
        var enabledLayerCount: uint
        var ppEnabledLayerNames: void*
        var enabledExtensionCount: uint
        var ppEnabledExtensionNames: void*
    }

    public memory_unsafe struct VkWin32SurfaceCreateInfoKHR
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var hinstance: void*
        var hwnd: void*
    }

    public memory_unsafe struct VkDeviceQueueCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var queueFamilyIndex: uint
        var queueCount: uint
        var pQueuePriorities: void*
    }

    public memory_unsafe struct VkDeviceCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var queueCreateInfoCount: uint
        var pQueueCreateInfos: void*
        var enabledLayerCount: uint
        var ppEnabledLayerNames: void*
        var enabledExtensionCount: uint
        var ppEnabledExtensionNames: void*
        var pEnabledFeatures: void*
    }

    public memory_unsafe struct VkQueueFamilyProperties
    {
        var queueFlags: uint
        var queueCount: uint
        var timestampValidBits: uint
        var minImageTransferGranularityW: uint
        var minImageTransferGranularityH: uint
        var minImageTransferGranularityD: uint
    }

    public memory_unsafe struct VkSurfaceCapabilitiesKHR
    {
        var minImageCount: uint
        var maxImageCount: uint
        var currentExtentWidth: uint
        var currentExtentHeight: uint
        var minImageExtentWidth: uint
        var minImageExtentHeight: uint
        var maxImageExtentWidth: uint
        var maxImageExtentHeight: uint
        var maxImageArrayLayers: uint
        var supportedTransforms: uint
        var currentTransform: uint
        var supportedCompositeAlpha: uint
        var supportedUsageFlags: uint
    }

    public memory_unsafe struct VkSurfaceFormatKHR
    {
        var format: uint
        var colorSpace: uint
    }

    public memory_unsafe struct VkSwapchainCreateInfoKHR
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var surface: void*
        var minImageCount: uint
        var imageFormat: uint
        var imageColorSpace: uint
        var imageExtentWidth: uint
        var imageExtentHeight: uint
        var imageArrayLayers: uint
        var imageUsage: uint
        var imageSharingMode: uint
        var queueFamilyIndexCount: uint
        var pQueueFamilyIndices: void*
        var preTransform: uint
        var compositeAlpha: uint
        var presentMode: uint
        var clipped: uint
        var oldSwapchain: void*
    }

    public memory_unsafe struct VkImageViewCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var image: void*
        var viewType: uint
        var format: uint
        // components (r,g,b,a swizzle)
        var componentsR: uint
        var componentsG: uint
        var componentsB: uint
        var componentsA: uint
        // subresourceRange
        var aspectMask: uint
        var baseMipLevel: uint
        var levelCount: uint
        var baseArrayLayer: uint
        var layerCount: uint
    }

    public memory_unsafe struct VkAttachmentDescription
    {
        var flags: uint
        var format: uint
        var samples: uint
        var loadOp: uint
        var storeOp: uint
        var stencilLoadOp: uint
        var stencilStoreOp: uint
        var initialLayout: uint
        var finalLayout: uint
    }

    public memory_unsafe struct VkAttachmentReference
    {
        var attachment: uint
        var layout: uint
    }

    public memory_unsafe struct VkSubpassDescription
    {
        var flags: uint
        var pipelineBindPoint: uint
        var inputAttachmentCount: uint
        var pInputAttachments: void*
        var colorAttachmentCount: uint
        var pColorAttachments: void*
        var pResolveAttachments: void*
        var pDepthStencilAttachment: void*
        var preserveAttachmentCount: uint
        var pPreserveAttachments: void*
    }

    public memory_unsafe struct VkRenderPassCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var attachmentCount: uint
        var pAttachments: void*
        var subpassCount: uint
        var pSubpasses: void*
        var dependencyCount: uint
        var pDependencies: void*
    }

    public memory_unsafe struct VkFramebufferCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var renderPass: void*
        var attachmentCount: uint
        var pAttachments: void*
        var width: uint
        var height: uint
        var layers: uint
    }

    public memory_unsafe struct VkCommandPoolCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var queueFamilyIndex: uint
    }

    public memory_unsafe struct VkCommandBufferAllocateInfo
    {
        var sType: uint
        var pNext: void*
        var commandPool: void*
        var level: uint
        var commandBufferCount: uint
    }

    public memory_unsafe struct VkCommandBufferBeginInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var pInheritanceInfo: void*
    }

    public memory_unsafe struct VkRenderPassBeginInfo
    {
        var sType: uint
        var pNext: void*
        var renderPass: void*
        var framebuffer: void*
        // renderArea: offset(x,y int32) + extent(width,height uint32)
        var renderAreaOffsetX: int
        var renderAreaOffsetY: int
        var renderAreaExtentW: uint
        var renderAreaExtentH: uint
        var clearValueCount: uint
        var pClearValues: void*
    }

    // VkClearValue is a union; for a color attachment it is four float32.
    public memory_unsafe struct VkClearValue
    {
        var r: float
        var g: float
        var b: float
        var a: float
    }

    public memory_unsafe struct VkSemaphoreCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
    }

    public memory_unsafe struct VkFenceCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
    }

    public memory_unsafe struct VkSubmitInfo
    {
        var sType: uint
        var pNext: void*
        var waitSemaphoreCount: uint
        var pWaitSemaphores: void*
        var pWaitDstStageMask: void*
        var commandBufferCount: uint
        var pCommandBuffers: void*
        var signalSemaphoreCount: uint
        var pSignalSemaphores: void*
    }

    public memory_unsafe struct VkPresentInfoKHR
    {
        var sType: uint
        var pNext: void*
        var waitSemaphoreCount: uint
        var pWaitSemaphores: void*
        var swapchainCount: uint
        var pSwapchains: void*
        var pImageIndices: void*
        var pResults: void*
    }

    // ---- graphics pipeline (milestone 3) ----

    public memory_unsafe struct VkShaderModuleCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var codeSize: ulong   // size_t, in bytes
        var pCode: void*      // const uint32_t*
    }

    public memory_unsafe struct VkPipelineShaderStageCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var stage: uint
        var module: void*
        var pName: byte*
        var pSpecializationInfo: void*
    }

    public memory_unsafe struct VkPipelineVertexInputStateCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var vertexBindingDescriptionCount: uint
        var pVertexBindingDescriptions: void*
        var vertexAttributeDescriptionCount: uint
        var pVertexAttributeDescriptions: void*
    }

    public memory_unsafe struct VkPipelineInputAssemblyStateCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var topology: uint
        var primitiveRestartEnable: uint
    }

    public memory_unsafe struct VkViewport
    {
        var x: float
        var y: float
        var width: float
        var height: float
        var minDepth: float
        var maxDepth: float
    }

    public memory_unsafe struct VkRect2D
    {
        var offsetX: int
        var offsetY: int
        var extentW: uint
        var extentH: uint
    }

    public memory_unsafe struct VkPipelineViewportStateCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var viewportCount: uint
        var pViewports: void*
        var scissorCount: uint
        var pScissors: void*
    }

    public memory_unsafe struct VkPipelineRasterizationStateCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var depthClampEnable: uint
        var rasterizerDiscardEnable: uint
        var polygonMode: uint
        var cullMode: uint
        var frontFace: uint
        var depthBiasEnable: uint
        var depthBiasConstantFactor: float
        var depthBiasClamp: float
        var depthBiasSlopeFactor: float
        var lineWidth: float
    }

    public memory_unsafe struct VkPipelineMultisampleStateCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var rasterizationSamples: uint
        var sampleShadingEnable: uint
        var minSampleShading: float
        var pSampleMask: void*
        var alphaToCoverageEnable: uint
        var alphaToOneEnable: uint
    }

    public memory_unsafe struct VkPipelineColorBlendAttachmentState
    {
        var blendEnable: uint
        var srcColorBlendFactor: uint
        var dstColorBlendFactor: uint
        var colorBlendOp: uint
        var srcAlphaBlendFactor: uint
        var dstAlphaBlendFactor: uint
        var alphaBlendOp: uint
        var colorWriteMask: uint
    }

    public memory_unsafe struct VkPipelineColorBlendStateCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var logicOpEnable: uint
        var logicOp: uint
        var attachmentCount: uint
        var pAttachments: void*
        var blendConstant0: float
        var blendConstant1: float
        var blendConstant2: float
        var blendConstant3: float
    }

    public memory_unsafe struct VkPipelineLayoutCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var setLayoutCount: uint
        var pSetLayouts: void*
        var pushConstantRangeCount: uint
        var pPushConstantRanges: void*
    }

    public memory_unsafe struct VkGraphicsPipelineCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var stageCount: uint
        var pStages: void*
        var pVertexInputState: void*
        var pInputAssemblyState: void*
        var pTessellationState: void*
        var pViewportState: void*
        var pRasterizationState: void*
        var pMultisampleState: void*
        var pDepthStencilState: void*
        var pColorBlendState: void*
        var pDynamicState: void*
        var layout: void*
        var renderPass: void*
        var subpass: uint
        var basePipelineHandle: void*
        var basePipelineIndex: int
    }

    // ---- buffers, memory, depth, vertex input (milestone 4) ----

    public memory_unsafe struct VkMemoryRequirements
    {
        var size: ulong
        var alignment: ulong
        var memoryTypeBits: uint
    }

    public memory_unsafe struct VkMemoryAllocateInfo
    {
        var sType: uint
        var pNext: void*
        var allocationSize: ulong
        var memoryTypeIndex: uint
    }

    public memory_unsafe struct VkBufferCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var size: ulong
        var usage: uint
        var sharingMode: uint
        var queueFamilyIndexCount: uint
        var pQueueFamilyIndices: void*
    }

    public memory_unsafe struct VkImageCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var imageType: uint
        var format: uint
        var extentW: uint
        var extentH: uint
        var extentD: uint
        var mipLevels: uint
        var arrayLayers: uint
        var samples: uint
        var tiling: uint
        var usage: uint
        var sharingMode: uint
        var queueFamilyIndexCount: uint
        var pQueueFamilyIndices: void*
        var initialLayout: uint
    }

    public memory_unsafe struct VkVertexInputBindingDescription
    {
        var binding: uint
        var stride: uint
        var inputRate: uint
    }

    public memory_unsafe struct VkVertexInputAttributeDescription
    {
        var location: uint
        var binding: uint
        var format: uint
        var offset: uint
    }

    public memory_unsafe struct VkPushConstantRange
    {
        var stageFlags: uint
        var offset: uint
        var size: uint
    }

    public memory_unsafe struct VkPipelineDepthStencilStateCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var depthTestEnable: uint
        var depthWriteEnable: uint
        var depthCompareOp: uint
        var depthBoundsTestEnable: uint
        var stencilTestEnable: uint
        // front VkStencilOpState (7 uints)
        var frontFailOp: uint
        var frontPassOp: uint
        var frontDepthFailOp: uint
        var frontCompareOp: uint
        var frontCompareMask: uint
        var frontWriteMask: uint
        var frontReference: uint
        // back VkStencilOpState (7 uints)
        var backFailOp: uint
        var backPassOp: uint
        var backDepthFailOp: uint
        var backCompareOp: uint
        var backCompareMask: uint
        var backWriteMask: uint
        var backReference: uint
        var minDepthBounds: float
        var maxDepthBounds: float
    }

    // ---- textures / descriptors (milestone: procedural textures) ----

    public memory_unsafe struct VkSamplerCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var magFilter: uint
        var minFilter: uint
        var mipmapMode: uint
        var addressModeU: uint
        var addressModeV: uint
        var addressModeW: uint
        var mipLodBias: float
        var anisotropyEnable: uint
        var maxAnisotropy: float
        var compareEnable: uint
        var compareOp: uint
        var minLod: float
        var maxLod: float
        var borderColor: uint
        var unnormalizedCoordinates: uint
    }

    public memory_unsafe struct VkDescriptorSetLayoutBinding
    {
        var binding: uint
        var descriptorType: uint
        var descriptorCount: uint
        var stageFlags: uint
        var pImmutableSamplers: void*
    }

    public memory_unsafe struct VkDescriptorSetLayoutCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var bindingCount: uint
        var pBindings: void*
    }

    public memory_unsafe struct VkDescriptorPoolSize
    {
        var type: uint
        var descriptorCount: uint
    }

    public memory_unsafe struct VkDescriptorPoolCreateInfo
    {
        var sType: uint
        var pNext: void*
        var flags: uint
        var maxSets: uint
        var poolSizeCount: uint
        var pPoolSizes: void*
    }

    public memory_unsafe struct VkDescriptorSetAllocateInfo
    {
        var sType: uint
        var pNext: void*
        var descriptorPool: void*
        var descriptorSetCount: uint
        var pSetLayouts: void*
    }

    public memory_unsafe struct VkDescriptorImageInfo
    {
        var sampler: void*
        var imageView: void*
        var imageLayout: uint
    }

    public memory_unsafe struct VkWriteDescriptorSet
    {
        var sType: uint
        var pNext: void*
        var dstSet: void*
        var dstBinding: uint
        var dstArrayElement: uint
        var descriptorCount: uint
        var descriptorType: uint
        var pImageInfo: void*
        var pBufferInfo: void*
        var pTexelBufferView: void*
    }

    public memory_unsafe struct VkBufferImageCopy
    {
        var bufferOffset: ulong
        var bufferRowLength: uint
        var bufferImageHeight: uint
        // imageSubresource (VkImageSubresourceLayers)
        var aspectMask: uint
        var mipLevel: uint
        var baseArrayLayer: uint
        var layerCount: uint
        // imageOffset
        var offsetX: int
        var offsetY: int
        var offsetZ: int
        // imageExtent
        var extentW: uint
        var extentH: uint
        var extentD: uint
    }

    public memory_unsafe struct VkImageMemoryBarrier
    {
        var sType: uint
        var pNext: void*
        var srcAccessMask: uint
        var dstAccessMask: uint
        var oldLayout: uint
        var newLayout: uint
        var srcQueueFamilyIndex: uint
        var dstQueueFamilyIndex: uint
        var image: void*
        // subresourceRange
        var aspectMask: uint
        var baseMipLevel: uint
        var levelCount: uint
        var baseArrayLayer: uint
        var layerCount: uint
    }
}
