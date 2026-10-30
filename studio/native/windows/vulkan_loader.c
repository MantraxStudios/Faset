/* =============================================================================
 *  FasetStudio en Windows: carga de Vulkan en tiempo de ejecución.
 *
 *  Vk.fst declara las funciones de Vulkan como externas (en Linux se enlazan con
 *  libvulkan.so.1). En Windows no hay biblioteca de importación de vulkan-1.dll en
 *  llvm-mingw y, además, enlazarla haría que el programa no arrancase sin Vulkan
 *  (con un error del sistema poco claro). Así que cada función es un "trampolín"
 *  de una instrucción (jmp a un puntero) que faset_vk_load() rellena con
 *  LoadLibraryW + GetProcAddress. Como el salto no toca la pila ni los registros,
 *  sirve para cualquier firma (ABI de Windows x64).
 * ============================================================================= */
#if !defined(_WIN32) || !defined(__x86_64__)
#error "vulkan_loader.c es solo para Windows x86_64"
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

/* Funciones de Vulkan que usa FasetStudio (Vk.fst salvo vkCreateXlibSurfaceKHR). */
#define FASET_VK_FUNCS(X) \
    X(vkAcquireNextImageKHR) \
    X(vkAllocateCommandBuffers) \
    X(vkAllocateDescriptorSets) \
    X(vkAllocateMemory) \
    X(vkBeginCommandBuffer) \
    X(vkBindBufferMemory) \
    X(vkBindImageMemory) \
    X(vkCmdBeginRenderPass) \
    X(vkCmdBindDescriptorSets) \
    X(vkCmdBindPipeline) \
    X(vkCmdBindVertexBuffers) \
    X(vkCmdCopyBufferToImage) \
    X(vkCmdCopyImageToBuffer) \
    X(vkCmdDraw) \
    X(vkCmdEndRenderPass) \
    X(vkCmdPipelineBarrier) \
    X(vkCmdPushConstants) \
    X(vkCmdSetScissor) \
    X(vkCmdSetViewport) \
    X(vkCreateBuffer) \
    X(vkCreateCommandPool) \
    X(vkCreateDescriptorPool) \
    X(vkCreateDescriptorSetLayout) \
    X(vkCreateDevice) \
    X(vkCreateFence) \
    X(vkCreateFramebuffer) \
    X(vkCreateGraphicsPipelines) \
    X(vkCreateImage) \
    X(vkCreateImageView) \
    X(vkCreateInstance) \
    X(vkCreatePipelineLayout) \
    X(vkCreateRenderPass) \
    X(vkCreateSampler) \
    X(vkCreateSemaphore) \
    X(vkCreateShaderModule) \
    X(vkCreateSwapchainKHR) \
    X(vkCreateWin32SurfaceKHR) \
    X(vkDestroyBuffer) \
    X(vkDestroyCommandPool) \
    X(vkDestroyDescriptorPool) \
    X(vkDestroyDescriptorSetLayout) \
    X(vkDestroyDevice) \
    X(vkDestroyFence) \
    X(vkDestroyFramebuffer) \
    X(vkDestroyImage) \
    X(vkDestroyImageView) \
    X(vkDestroyInstance) \
    X(vkDestroyPipeline) \
    X(vkDestroyPipelineLayout) \
    X(vkDestroyRenderPass) \
    X(vkDestroySampler) \
    X(vkDestroySemaphore) \
    X(vkDestroyShaderModule) \
    X(vkDestroySurfaceKHR) \
    X(vkDestroySwapchainKHR) \
    X(vkDeviceWaitIdle) \
    X(vkEndCommandBuffer) \
    X(vkEnumeratePhysicalDevices) \
    X(vkFreeMemory) \
    X(vkGetBufferMemoryRequirements) \
    X(vkGetDeviceQueue) \
    X(vkGetImageMemoryRequirements) \
    X(vkGetPhysicalDeviceMemoryProperties) \
    X(vkGetPhysicalDeviceProperties) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) \
    X(vkGetPhysicalDeviceSurfaceFormatsKHR) \
    X(vkGetPhysicalDeviceSurfaceSupportKHR) \
    X(vkGetSwapchainImagesKHR) \
    X(vkMapMemory) \
    X(vkQueuePresentKHR) \
    X(vkQueueSubmit) \
    X(vkQueueWaitIdle) \
    X(vkResetCommandBuffer) \
    X(vkResetFences) \
    X(vkUnmapMemory) \
    X(vkUpdateDescriptorSets) \
    X(vkWaitForFences)

/* Punteros (globales: el ensamblador los nombra). */
#define X(n) void* faset_vkp_##n;
FASET_VK_FUNCS(X)
#undef X

/* Trampolines: n: jmp *faset_vkp_n(%rip) */
#define X(n) __asm__(".text\n\t.globl " #n "\n\t.def " #n "; .scl 2; .type 32; .endef\n\t.p2align 4\n" #n ":\n\tjmp *faset_vkp_" #n "(%rip)\n");
FASET_VK_FUNCS(X)
#undef X

/* 1 si vulkan-1.dll está y exporta todo lo necesario; 0 si no (el llamador muestra el error). */
int faset_vk_load(void) {
    static int state; /* 0 sin intentar, 1 cargado, -1 no disponible */
    if (state) return state > 0;
    state = -1;
    HMODULE m = LoadLibraryW(L"vulkan-1.dll");
    if (!m) return 0;
#define X(n) if (!(faset_vkp_##n = (void*)GetProcAddress(m, #n))) return 0;
    FASET_VK_FUNCS(X)
#undef X
    state = 1;
    return 1;
}
