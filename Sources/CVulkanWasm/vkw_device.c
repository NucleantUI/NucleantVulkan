// Instance, physical device, logical device, queue, surface and swapchain —
// the part of Vulkan that, on the browser, is one GPUAdapter/GPUDevice the
// bridge acquired before wasm started, and one GPUCanvasContext per window.

#if defined(__wasm__)

#include "vkw_internal.h"
#include <stdarg.h>
#include <stdio.h>

// MARK: - Logging

void vkw_logf(const char *format, ...) {
    char buffer[512];
    va_list args;
    va_start(args, format);
    int length = vsnprintf(buffer, sizeof buffer, format, args);
    va_end(args);
    if (length < 0) return;
    if ((size_t)length >= sizeof buffer) length = sizeof buffer - 1;
    nwg_log(buffer, (uint32_t)length);
}

// MARK: - Extensions

static const char *const kInstanceExtensions[] = {
    VK_KHR_SURFACE_EXTENSION_NAME,
    VK_NUCLEANT_WEBGPU_SURFACE_EXTENSION_NAME,
};
static const uint32_t kInstanceExtensionSpecs[] = { 25, VK_NUCLEANT_WEBGPU_SURFACE_SPEC_VERSION };

static const char *const kDeviceExtensions[] = {
    VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    VK_NUCLEANT_WEBGPU_OBJECTS_EXTENSION_NAME,
};
static const uint32_t kDeviceExtensionSpecs[] = { 70, VK_NUCLEANT_WEBGPU_OBJECTS_SPEC_VERSION };

static VkResult enumerate_extensions(const char *const *names, const uint32_t *specs, uint32_t total,
                                     uint32_t *pCount, VkExtensionProperties *pProperties) {
    if (!pProperties) {
        *pCount = total;
        return VK_SUCCESS;
    }
    uint32_t n = *pCount < total ? *pCount : total;
    for (uint32_t i = 0; i < n; i++) {
        memset(&pProperties[i], 0, sizeof pProperties[i]);
        strncpy(pProperties[i].extensionName, names[i], VK_MAX_EXTENSION_NAME_SIZE - 1);
        pProperties[i].specVersion = specs[i];
    }
    *pCount = n;
    return n < total ? VK_INCOMPLETE : VK_SUCCESS;
}

static int has_name(const char *const *names, uint32_t total, const char *name) {
    for (uint32_t i = 0; i < total; i++) {
        if (strcmp(names[i], name) == 0) return 1;
    }
    return 0;
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(
    const char *pLayerName, uint32_t *pPropertyCount, VkExtensionProperties *pProperties) {
    if (pLayerName) {
        *pPropertyCount = 0;
        return VK_ERROR_LAYER_NOT_PRESENT;
    }
    return enumerate_extensions(kInstanceExtensions, kInstanceExtensionSpecs, 2, pPropertyCount, pProperties);
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceExtensionProperties(
    VkPhysicalDevice physicalDevice, const char *pLayerName, uint32_t *pPropertyCount,
    VkExtensionProperties *pProperties) {
    (void)physicalDevice;
    if (pLayerName) {
        *pPropertyCount = 0;
        return VK_ERROR_LAYER_NOT_PRESENT;
    }
    return enumerate_extensions(kDeviceExtensions, kDeviceExtensionSpecs, sizeof kDeviceExtensions / sizeof *kDeviceExtensions,
                                pPropertyCount, pProperties);
}

// MARK: - Instance

VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(
    const VkInstanceCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator, VkInstance *pInstance) {
    (void)pAllocator;
    if (pCreateInfo->enabledLayerCount > 0) return VK_ERROR_LAYER_NOT_PRESENT;
    uint32_t surfaceExtension = 0;
    for (uint32_t i = 0; i < pCreateInfo->enabledExtensionCount; i++) {
        const char *name = pCreateInfo->ppEnabledExtensionNames[i];
        if (!has_name(kInstanceExtensions, 2, name)) {
            vkw_logf("vkCreateInstance: extension %s is not available on WebGPU", name);
            return VK_ERROR_EXTENSION_NOT_PRESENT;
        }
        if (strcmp(name, VK_NUCLEANT_WEBGPU_SURFACE_EXTENSION_NAME) == 0) surfaceExtension = 1;
    }
    VkInstance instance = calloc(1, sizeof *instance);
    VkPhysicalDevice gpu = calloc(1, sizeof *gpu);
    if (!instance || !gpu) {
        free(instance);
        free(gpu);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    gpu->instance = instance;
    nwg_device_info(&gpu->info);
    gpu->info.adapterName[sizeof gpu->info.adapterName - 1] = 0;
    instance->physicalDevice = gpu;
    instance->surfaceExtension = surfaceExtension;
    *pInstance = instance;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyInstance(VkInstance instance, const VkAllocationCallbacks *pAllocator) {
    (void)pAllocator;
    if (!instance) return;
    free(instance->physicalDevice);
    free(instance);
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumeratePhysicalDevices(
    VkInstance instance, uint32_t *pPhysicalDeviceCount, VkPhysicalDevice *pPhysicalDevices) {
    if (!pPhysicalDevices) {
        *pPhysicalDeviceCount = 1;
        return VK_SUCCESS;
    }
    if (*pPhysicalDeviceCount == 0) return VK_INCOMPLETE;
    pPhysicalDevices[0] = instance->physicalDevice;
    *pPhysicalDeviceCount = 1;
    return VK_SUCCESS;
}

// MARK: - Physical device

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceQueueFamilyProperties(
    VkPhysicalDevice physicalDevice, uint32_t *pQueueFamilyPropertyCount,
    VkQueueFamilyProperties *pQueueFamilyProperties) {
    (void)physicalDevice;
    if (!pQueueFamilyProperties) {
        *pQueueFamilyPropertyCount = 1;
        return;
    }
    if (*pQueueFamilyPropertyCount == 0) return;
    // A GPUDevice has exactly one queue, and it does everything.
    memset(&pQueueFamilyProperties[0], 0, sizeof pQueueFamilyProperties[0]);
    pQueueFamilyProperties[0].queueFlags = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT;
    pQueueFamilyProperties[0].queueCount = 1;
    pQueueFamilyProperties[0].minImageTransferGranularity = (VkExtent3D){ 1, 1, 1 };
    *pQueueFamilyPropertyCount = 1;
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceMemoryProperties(
    VkPhysicalDevice physicalDevice, VkPhysicalDeviceMemoryProperties *pMemoryProperties) {
    (void)physicalDevice;
    memset(pMemoryProperties, 0, sizeof *pMemoryProperties);
    // Type 0 is GPU memory, the GPUBuffer/GPUTexture itself. Type 1 is the
    // same plus a host copy in wasm memory, which is what a mapping returns;
    // writes reach the GPU at vkUnmapMemory and at every submit (coherent),
    // GPU writes come back after the work finishes.
    pMemoryProperties->memoryTypeCount = VKW_MEMORY_TYPE_COUNT;
    pMemoryProperties->memoryTypes[VKW_MEMORY_TYPE_DEVICE_LOCAL].propertyFlags = VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
    pMemoryProperties->memoryTypes[VKW_MEMORY_TYPE_DEVICE_LOCAL].heapIndex = 0;
    pMemoryProperties->memoryTypes[VKW_MEMORY_TYPE_HOST_VISIBLE].propertyFlags =
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    pMemoryProperties->memoryTypes[VKW_MEMORY_TYPE_HOST_VISIBLE].heapIndex = 1;
    pMemoryProperties->memoryHeapCount = 2;
    pMemoryProperties->memoryHeaps[0].size = 1ull << 30;
    pMemoryProperties->memoryHeaps[0].flags = VK_MEMORY_HEAP_DEVICE_LOCAL_BIT;
    pMemoryProperties->memoryHeaps[1].size = 1ull << 30;
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceProperties(VkPhysicalDevice physicalDevice, VkPhysicalDeviceProperties *pProperties) {
    const nwg_device_info_t *info = &physicalDevice->info;
    memset(pProperties, 0, sizeof *pProperties);
    pProperties->apiVersion = VK_API_VERSION_1_0;
    pProperties->deviceType = VK_PHYSICAL_DEVICE_TYPE_OTHER;
    size_t length = strlen(info->adapterName);
    if (length >= sizeof pProperties->deviceName) length = sizeof pProperties->deviceName - 1;
    memcpy(pProperties->deviceName, info->adapterName, length);
    // WebGPU's limits, as the device was created with them.
    VkPhysicalDeviceLimits *limits = &pProperties->limits;
    limits->maxImageDimension1D = info->maxTextureDimension2D;
    limits->maxImageDimension2D = info->maxTextureDimension2D;
    limits->maxImageDimension3D = info->maxTextureDimension3D;
    limits->maxImageDimensionCube = info->maxTextureDimension2D;
    limits->maxImageArrayLayers = info->maxTextureArrayLayers;
    limits->maxUniformBufferRange = info->maxUniformBufferBindingSize;
    limits->maxStorageBufferRange = info->maxStorageBufferBindingSize;
    limits->maxPushConstantsSize = NWG_MAX_PUSH_CONSTANTS;
    limits->maxBoundDescriptorSets = info->maxBindGroups > 1 ? info->maxBindGroups - 1 : 1;  // one is the draw-data group
    limits->maxVertexInputAttributes = NWG_MAX_VERTEX_ATTRIBUTES;
    limits->maxVertexInputBindings = 8;
    limits->maxVertexInputAttributeOffset = 2047;
    limits->maxVertexInputBindingStride = 2048;
    limits->maxComputeWorkGroupInvocations = info->maxComputeInvocationsPerWorkgroup;
    for (int i = 0; i < 3; i++) limits->maxComputeWorkGroupCount[i] = info->maxComputeWorkgroupsPerDimension;
    limits->maxViewports = 1;
    limits->maxViewportDimensions[0] = limits->maxViewportDimensions[1] = info->maxTextureDimension2D;
    limits->maxFramebufferWidth = limits->maxFramebufferHeight = info->maxTextureDimension2D;
    limits->maxFramebufferLayers = 1;
    limits->maxColorAttachments = VKW_MAX_COLOR_ATTACHMENTS;
    limits->framebufferColorSampleCounts = limits->framebufferDepthSampleCounts =
        limits->framebufferStencilSampleCounts = VK_SAMPLE_COUNT_1_BIT | VK_SAMPLE_COUNT_4_BIT;
    limits->minUniformBufferOffsetAlignment = 256;
    limits->minStorageBufferOffsetAlignment = 256;
    limits->minMemoryMapAlignment = 64;
    limits->optimalBufferCopyOffsetAlignment = 256;
    limits->optimalBufferCopyRowPitchAlignment = NWG_COPY_ROW_ALIGNMENT;
    limits->nonCoherentAtomSize = 4;
    limits->maxSamplerAnisotropy = 16;
    limits->maxSamplerLodBias = 0;
    limits->timestampComputeAndGraphics = VK_FALSE;
    limits->pointSizeRange[0] = limits->pointSizeRange[1] = 1;
    limits->lineWidthRange[0] = limits->lineWidthRange[1] = 1;
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFormatProperties(
    VkPhysicalDevice physicalDevice, VkFormat format, VkFormatProperties *pFormatProperties) {
    memset(pFormatProperties, 0, sizeof *pFormatProperties);
    // Optimal tiling only: a GPUTexture's layout is opaque, and there is no
    // host-mapped linear image in WebGPU.
    pFormatProperties->optimalTilingFeatures = vkw_format_features(&physicalDevice->info, format);
}

// MARK: - Device

VKAPI_ATTR VkResult VKAPI_CALL vkCreateDevice(
    VkPhysicalDevice physicalDevice, const VkDeviceCreateInfo *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkDevice *pDevice) {
    (void)pAllocator;
    for (uint32_t i = 0; i < pCreateInfo->enabledExtensionCount; i++) {
        const char *name = pCreateInfo->ppEnabledExtensionNames[i];
        if (!has_name(kDeviceExtensions, sizeof kDeviceExtensions / sizeof *kDeviceExtensions, name)) {
            vkw_logf("vkCreateDevice: extension %s is not available on WebGPU", name);
            return VK_ERROR_EXTENSION_NOT_PRESENT;
        }
    }
    for (uint32_t i = 0; i < pCreateInfo->queueCreateInfoCount; i++) {
        const VkDeviceQueueCreateInfo *queue = &pCreateInfo->pQueueCreateInfos[i];
        if (queue->queueFamilyIndex != 0 || queue->queueCount > 1) return VK_ERROR_INITIALIZATION_FAILED;
    }
    VkDevice device = calloc(1, sizeof *device);
    if (!device) return VK_ERROR_OUT_OF_HOST_MEMORY;
    device->physicalDevice = physicalDevice;
    device->queue.device = device;
    *pDevice = device;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyDevice(VkDevice device, const VkAllocationCallbacks *pAllocator) {
    (void)pAllocator;
    free(device);
}

VKAPI_ATTR void VKAPI_CALL vkGetDeviceQueue(VkDevice device, uint32_t queueFamilyIndex, uint32_t queueIndex, VkQueue *pQueue) {
    *pQueue = (queueFamilyIndex == 0 && queueIndex == 0) ? &device->queue : NULL;
}

uint32_t vkw_next_id(void) {
    static uint32_t next = 1;
    return next++;
}

const nwg_device_info_t *vkw_device_info(VkDevice device) {
    return &device->physicalDevice->info;
}

// MARK: - Surface

VKAPI_ATTR VkResult VKAPI_CALL vkCreateWebGPUSurfaceNUCLEANT(
    VkInstance instance, const VkWebGPUSurfaceCreateInfoNUCLEANT *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkSurfaceKHR *pSurface) {
    (void)pAllocator;
    if (!instance->surfaceExtension) {
        vkw_logf("vkCreateWebGPUSurfaceNUCLEANT: %s was not enabled on the instance",
                 VK_NUCLEANT_WEBGPU_SURFACE_EXTENSION_NAME);
        return VK_ERROR_EXTENSION_NOT_PRESENT;
    }
    const char *selector = pCreateInfo->pCanvasSelector ? pCreateInfo->pCanvasSelector : "";
    uint32_t id = nwg_surface_create(selector, (uint32_t)strlen(selector));
    if (id == 0) {
        vkw_logf("vkCreateWebGPUSurfaceNUCLEANT: no <canvas> matches \"%s\"", selector);
        return VK_ERROR_INITIALIZATION_FAILED;
    }
    VkSurfaceKHR surface = calloc(1, sizeof *surface);
    if (!surface) {
        nwg_surface_destroy(id);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    surface->id = id;
    *pSurface = surface;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroySurfaceKHR(VkInstance instance, VkSurfaceKHR surface, const VkAllocationCallbacks *pAllocator) {
    (void)instance;
    (void)pAllocator;
    if (!surface) return;
    nwg_surface_destroy(surface->id);
    free(surface);
}

VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceSupportKHR(
    VkPhysicalDevice physicalDevice, uint32_t queueFamilyIndex, VkSurfaceKHR surface, VkBool32 *pSupported) {
    (void)physicalDevice;
    (void)surface;
    *pSupported = queueFamilyIndex == 0 ? VK_TRUE : VK_FALSE;
    return VK_SUCCESS;
}

static VkExtent2D surface_size(VkSurfaceKHR surface) {
    uint32_t size[2] = { 0, 0 };
    nwg_surface_get_size(surface->id, size);
    return (VkExtent2D){ size[0], size[1] };
}

VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
    VkPhysicalDevice physicalDevice, VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR *pSurfaceCapabilities) {
    memset(pSurfaceCapabilities, 0, sizeof *pSurfaceCapabilities);
    uint32_t maxDimension = physicalDevice->info.maxTextureDimension2D;
    // The canvas's drawing-buffer size is the size of every texture its
    // context hands out — the surface size is fixed by it, as on Wayland
    // it is by the client.
    pSurfaceCapabilities->currentExtent = surface_size(surface);
    pSurfaceCapabilities->minImageCount = 2;
    pSurfaceCapabilities->maxImageCount = VKW_MAX_SWAPCHAIN_IMAGES;
    pSurfaceCapabilities->minImageExtent = (VkExtent2D){ 1, 1 };
    pSurfaceCapabilities->maxImageExtent = (VkExtent2D){ maxDimension, maxDimension };
    pSurfaceCapabilities->maxImageArrayLayers = 1;
    pSurfaceCapabilities->supportedTransforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    pSurfaceCapabilities->currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    pSurfaceCapabilities->supportedCompositeAlpha =
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR | VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    pSurfaceCapabilities->supportedUsageFlags = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
        VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkGetPhysicalDeviceSurfaceFormatsKHR(
    VkPhysicalDevice physicalDevice, VkSurfaceKHR surface, uint32_t *pSurfaceFormatCount,
    VkSurfaceFormatKHR *pSurfaceFormats) {
    (void)surface;
    // Only the browser's preferred canvas format: any other is legal but
    // costs the compositor a conversion every frame.
    if (!pSurfaceFormats) {
        *pSurfaceFormatCount = 1;
        return VK_SUCCESS;
    }
    if (*pSurfaceFormatCount == 0) return VK_INCOMPLETE;
    pSurfaceFormats[0].format = (VkFormat)physicalDevice->info.preferredFormat;
    pSurfaceFormats[0].colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    *pSurfaceFormatCount = 1;
    return VK_SUCCESS;
}

// MARK: - Swapchain

/// The swapchain each surface's canvas context is currently configured for,
/// so destroying a retired swapchain after its replacement was created
/// doesn't unconfigure the replacement.
typedef struct { uint32_t surface; VkSwapchainKHR swapchain; } configured_t;
static configured_t gConfigured[16];

static void set_configured(uint32_t surface, VkSwapchainKHR swapchain) {
    for (int i = 0; i < 16; i++) {
        if (gConfigured[i].surface == surface || gConfigured[i].surface == 0) {
            gConfigured[i].surface = swapchain ? surface : 0;
            gConfigured[i].swapchain = swapchain;
            return;
        }
    }
}

static VkSwapchainKHR configured_swapchain(uint32_t surface) {
    for (int i = 0; i < 16; i++) {
        if (gConfigured[i].surface == surface) return gConfigured[i].swapchain;
    }
    return NULL;
}

static uint32_t canvas_usage(VkImageUsageFlags usage) {
    uint32_t out = GPU_TEXTURE_RENDER_ATTACHMENT;
    if (usage & VK_IMAGE_USAGE_TRANSFER_SRC_BIT) out |= GPU_TEXTURE_COPY_SRC;
    if (usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT) out |= GPU_TEXTURE_COPY_DST;
    if (usage & VK_IMAGE_USAGE_SAMPLED_BIT) out |= GPU_TEXTURE_BINDING;
    return out;
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateSwapchainKHR(
    VkDevice device, const VkSwapchainCreateInfoKHR *pCreateInfo,
    const VkAllocationCallbacks *pAllocator, VkSwapchainKHR *pSwapchain) {
    (void)pAllocator;
    (void)device;
    VkFormat format = pCreateInfo->imageFormat;
    if (format != VK_FORMAT_B8G8R8A8_UNORM && format != VK_FORMAT_R8G8B8A8_UNORM &&
        format != VK_FORMAT_R16G16B16A16_SFLOAT) {
        vkw_logf("vkCreateSwapchainKHR: format %d cannot back a canvas", (int)format);
        return VK_ERROR_FORMAT_NOT_SUPPORTED;
    }
    VkExtent2D extent = pCreateInfo->imageExtent;
    if (extent.width == 0 || extent.height == 0) return VK_ERROR_INITIALIZATION_FAILED;

    VkSwapchainKHR swapchain = calloc(1, sizeof *swapchain);
    if (!swapchain) return VK_ERROR_OUT_OF_HOST_MEMORY;
    swapchain->surface = pCreateInfo->surface;
    swapchain->format = format;
    swapchain->extent = extent;
    uint32_t count = pCreateInfo->minImageCount;
    if (count < 2) count = 2;
    if (count > VKW_MAX_SWAPCHAIN_IMAGES) count = VKW_MAX_SWAPCHAIN_IMAGES;
    swapchain->imageCount = count;
    for (uint32_t i = 0; i < count; i++) {
        VkImage image = calloc(1, sizeof *image);
        if (!image) {
            for (uint32_t j = 0; j < i; j++) free(swapchain->images[j]);
            free(swapchain);
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        // No texture of its own: the canvas hands out the frame's texture
        // when a submit first draws into it (see the bridge's view
        // resolution), as a swapchain hands out an acquired image.
        image->surface = pCreateInfo->surface->id;
        image->format = format;
        image->type = VK_IMAGE_TYPE_2D;
        image->width = extent.width;
        image->height = extent.height;
        image->depth = 1;
        image->mipLevels = 1;
        image->arrayLayers = 1;
        image->usage = pCreateInfo->imageUsage;
        image->samples = VK_SAMPLE_COUNT_1_BIT;
        swapchain->images[i] = image;
    }
    uint32_t premultiplied = pCreateInfo->compositeAlpha == VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR;
    nwg_surface_configure(pCreateInfo->surface->id, format, canvas_usage(pCreateInfo->imageUsage), premultiplied);
    set_configured(pCreateInfo->surface->id, swapchain);
    *pSwapchain = swapchain;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroySwapchainKHR(VkDevice device, VkSwapchainKHR swapchain, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!swapchain) return;
    uint32_t surface = swapchain->surface->id;
    if (configured_swapchain(surface) == swapchain) {
        nwg_surface_unconfigure(surface);
        set_configured(surface, NULL);
    }
    for (uint32_t i = 0; i < swapchain->imageCount; i++) free(swapchain->images[i]);
    free(swapchain);
}

VKAPI_ATTR VkResult VKAPI_CALL vkGetSwapchainImagesKHR(
    VkDevice device, VkSwapchainKHR swapchain, uint32_t *pSwapchainImageCount, VkImage *pSwapchainImages) {
    (void)device;
    if (!pSwapchainImages) {
        *pSwapchainImageCount = swapchain->imageCount;
        return VK_SUCCESS;
    }
    uint32_t n = *pSwapchainImageCount < swapchain->imageCount ? *pSwapchainImageCount : swapchain->imageCount;
    for (uint32_t i = 0; i < n; i++) pSwapchainImages[i] = swapchain->images[i];
    *pSwapchainImageCount = n;
    return n < swapchain->imageCount ? VK_INCOMPLETE : VK_SUCCESS;
}

static int swapchain_out_of_date(VkSwapchainKHR swapchain) {
    VkExtent2D size = surface_size(swapchain->surface);
    return size.width != swapchain->extent.width || size.height != swapchain->extent.height ||
           configured_swapchain(swapchain->surface->id) != swapchain;
}

VKAPI_ATTR VkResult VKAPI_CALL vkAcquireNextImageKHR(
    VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout, VkSemaphore semaphore, VkFence fence,
    uint32_t *pImageIndex) {
    (void)device;
    (void)timeout;
    (void)semaphore;
    // A canvas resized since the swapchain was made hands out textures of
    // the new size, which the old framebuffers can't render into — the same
    // situation a resized window reports through OUT_OF_DATE.
    if (swapchain_out_of_date(swapchain)) return VK_ERROR_OUT_OF_DATE_KHR;
    *pImageIndex = swapchain->nextImage;
    swapchain->nextImage = (swapchain->nextImage + 1) % swapchain->imageCount;
    if (fence) fence->serial = 0;
    return VK_SUCCESS;
}

VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *pPresentInfo) {
    (void)queue;
    // The browser presents a canvas's texture by itself once the task that
    // rendered into it returns; there is nothing to call. What remains is
    // the result code.
    VkResult result = VK_SUCCESS;
    for (uint32_t i = 0; i < pPresentInfo->swapchainCount; i++) {
        VkResult one = swapchain_out_of_date(pPresentInfo->pSwapchains[i]) ? VK_SUBOPTIMAL_KHR : VK_SUCCESS;
        if (pPresentInfo->pResults) pPresentInfo->pResults[i] = one;
        if (one != VK_SUCCESS) result = one;
    }
    return result;
}

#endif /* __wasm__ */
