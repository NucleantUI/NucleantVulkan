// Formats, device memory, buffers, images, views and samplers.
//
// Memory is where Vulkan and WebGPU differ most: a WebGPU buffer or texture
// owns its storage, and nothing on the CPU can point into it. So a
// VkDeviceMemory here is bookkeeping plus, for the HOST_VISIBLE type, a
// shadow copy in wasm memory — the bytes vkMapMemory returns. Host writes
// reach the GPU buffers bound to it at vkUnmapMemory, and for memory that
// stays mapped (coherent, persistent maps) at every vkQueueSubmit, before
// the work that reads them. GPU writes into it come back through the
// bridge's readback once the submit that wrote them finishes.

#if defined(__wasm__)

#include "vkw_internal.h"

// MARK: - Formats

enum {
    FMT_SAMPLE  = 1 << 0,
    FMT_FILTER  = 1 << 1,
    FMT_RENDER  = 1 << 2,
    FMT_BLEND   = 1 << 3,
    FMT_STORAGE = 1 << 4,
    FMT_DEPTH   = 1 << 5,
};

typedef struct { VkFormat format; uint32_t bytes; uint32_t flags; } format_info_t;

// The WebGPU core format capability table, for the formats with a Vulkan
// counterpart. bgra8unorm storage and r32float filtering depend on optional
// features and are added per device in format_flags().
static const format_info_t kFormats[] = {
    { VK_FORMAT_R8_UNORM,                 1, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_R8_SNORM,                 1, FMT_SAMPLE | FMT_FILTER },
    { VK_FORMAT_R8_UINT,                  1, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R8_SINT,                  1, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R8G8_UNORM,               2, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_R8G8_SNORM,               2, FMT_SAMPLE | FMT_FILTER },
    { VK_FORMAT_R8G8_UINT,                2, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R8G8_SINT,                2, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R8G8B8A8_UNORM,           4, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND | FMT_STORAGE },
    { VK_FORMAT_R8G8B8A8_SNORM,           4, FMT_SAMPLE | FMT_FILTER | FMT_STORAGE },
    { VK_FORMAT_R8G8B8A8_UINT,            4, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R8G8B8A8_SINT,            4, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R8G8B8A8_SRGB,            4, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_B8G8R8A8_UNORM,           4, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_B8G8R8A8_SRGB,            4, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_A2B10G10R10_UNORM_PACK32, 4, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_R16_UINT,                 2, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R16_SINT,                 2, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R16_SFLOAT,               2, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_R16G16_UINT,              4, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R16G16_SINT,              4, FMT_SAMPLE | FMT_RENDER },
    { VK_FORMAT_R16G16_SFLOAT,            4, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND },
    { VK_FORMAT_R16G16B16A16_UINT,        8, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R16G16B16A16_SINT,        8, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R16G16B16A16_SFLOAT,      8, FMT_SAMPLE | FMT_FILTER | FMT_RENDER | FMT_BLEND | FMT_STORAGE },
    { VK_FORMAT_R32_UINT,                 4, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32_SINT,                 4, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32_SFLOAT,               4, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32G32_UINT,              8, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32G32_SINT,              8, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32G32_SFLOAT,            8, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32G32B32A32_UINT,       16, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32G32B32A32_SINT,       16, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_R32G32B32A32_SFLOAT,     16, FMT_SAMPLE | FMT_RENDER | FMT_STORAGE },
    { VK_FORMAT_D16_UNORM,                2, FMT_SAMPLE | FMT_DEPTH },
    { VK_FORMAT_D32_SFLOAT,               4, FMT_SAMPLE | FMT_DEPTH },
    { VK_FORMAT_D24_UNORM_S8_UINT,        4, FMT_SAMPLE | FMT_DEPTH },
};

static const format_info_t *find_format(VkFormat format) {
    for (size_t i = 0; i < sizeof kFormats / sizeof kFormats[0]; i++) {
        if (kFormats[i].format == format) return &kFormats[i];
    }
    return NULL;
}

static uint32_t format_flags(const nwg_device_info_t *info, VkFormat format) {
    const format_info_t *entry = find_format(format);
    if (!entry) return 0;
    uint32_t flags = entry->flags;
    if (format == VK_FORMAT_B8G8R8A8_UNORM && info->bgra8unormStorage) flags |= FMT_STORAGE;
    if (format == VK_FORMAT_R32_SFLOAT && info->float32Filterable) flags |= FMT_FILTER;
    return flags;
}

uint32_t vkw_format_bytes(VkFormat format) {
    const format_info_t *entry = find_format(format);
    return entry ? entry->bytes : 0;
}

VkFormatFeatureFlags vkw_format_features(const nwg_device_info_t *info, VkFormat format) {
    uint32_t flags = format_flags(info, format);
    if (!flags) return 0;
    VkFormatFeatureFlags features = VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    if (flags & FMT_SAMPLE) features |= VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_BLIT_SRC_BIT;
    if (flags & FMT_FILTER) features |= VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    if (flags & FMT_RENDER) features |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT;
    if (flags & FMT_BLEND) features |= VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
    if (flags & FMT_STORAGE) features |= VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT;
    if (flags & FMT_DEPTH) features |= VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT;
    return features;
}

int vkw_format_supports(const nwg_device_info_t *info, VkFormat format, VkFormatFeatureFlags features) {
    return (vkw_format_features(info, format) & features) == features;
}

// MARK: - Device memory

static int host_visible(VkDeviceMemory memory) {
    return memory && memory->typeIndex == VKW_MEMORY_TYPE_HOST_VISIBLE;
}

VKAPI_ATTR VkResult VKAPI_CALL vkAllocateMemory(
    VkDevice device, const VkMemoryAllocateInfo *pAllocateInfo, const VkAllocationCallbacks *pAllocator,
    VkDeviceMemory *pMemory) {
    (void)pAllocator;
    if (pAllocateInfo->memoryTypeIndex >= VKW_MEMORY_TYPE_COUNT) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    VkDeviceMemory memory = calloc(1, sizeof *memory);
    if (!memory) return VK_ERROR_OUT_OF_HOST_MEMORY;
    memory->id = vkw_next_id();
    memory->size = pAllocateInfo->allocationSize;
    memory->typeIndex = pAllocateInfo->memoryTypeIndex;
    if (memory->typeIndex == VKW_MEMORY_TYPE_HOST_VISIBLE) {
        if (memory->size > UINT32_MAX) {
            free(memory);
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        memory->shadow = calloc(1, (size_t)memory->size);
        if (!memory->shadow) {
            free(memory);
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
    }
    *pMemory = memory;
    return VK_SUCCESS;
}

static void unlink_mapped(VkDevice device, VkDeviceMemory memory) {
    for (VkDeviceMemory *link = &device->mappedMemories; *link; link = &(*link)->nextMapped) {
        if (*link == memory) {
            *link = memory->nextMapped;
            memory->nextMapped = NULL;
            return;
        }
    }
}

VKAPI_ATTR void VKAPI_CALL vkFreeMemory(VkDevice device, VkDeviceMemory memory, const VkAllocationCallbacks *pAllocator) {
    (void)pAllocator;
    if (!memory) return;
    if (memory->mapped) unlink_mapped(device, memory);
    for (VkBuffer buffer = memory->buffers; buffer;) {
        VkBuffer next = buffer->nextInMemory;
        buffer->memory = NULL;
        buffer->nextInMemory = NULL;
        buffer = next;
    }
    // Readbacks still in flight into the shadow must not land in freed memory.
    nwg_memory_release(memory->id);
    free(memory->shadow);
    free(memory);
}

VKAPI_ATTR VkResult VKAPI_CALL vkMapMemory(
    VkDevice device, VkDeviceMemory memory, VkDeviceSize offset, VkDeviceSize size, VkMemoryMapFlags flags,
    void **ppData) {
    (void)flags;
    if (!host_visible(memory) || memory->mapped || offset >= memory->size) {
        *ppData = NULL;
        return VK_ERROR_MEMORY_MAP_FAILED;
    }
    if (size == VK_WHOLE_SIZE) size = memory->size - offset;
    memory->mapped = 1;
    memory->mapOffset = offset;
    memory->mapSize = size;
    memory->nextMapped = device->mappedMemories;
    device->mappedMemories = memory;
    *ppData = memory->shadow + offset;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkUnmapMemory(VkDevice device, VkDeviceMemory memory) {
    if (!memory || !memory->mapped) return;
    vkw_memory_flush(memory, memory->mapOffset, memory->mapSize);
    unlink_mapped(device, memory);
    memory->mapped = 0;
}

void vkw_memory_flush(VkDeviceMemory memory, uint64_t offset, uint64_t size) {
    if (!host_visible(memory)) return;
    uint64_t end = offset + size;
    for (VkBuffer buffer = memory->buffers; buffer; buffer = buffer->nextInMemory) {
        uint64_t start = buffer->memoryOffset > offset ? buffer->memoryOffset : offset;
        uint64_t stop = buffer->memoryOffset + buffer->size < end ? buffer->memoryOffset + buffer->size : end;
        if (start >= stop) continue;
        // writeBuffer wants 4-byte offsets and sizes; the GPU buffer was
        // created rounded up to 4 and memory sizes are 256-multiples, so
        // widening the range stays inside both.
        uint64_t local = (start - buffer->memoryOffset) & ~3ull;
        uint64_t localEnd = (stop - buffer->memoryOffset + 3) & ~3ull;
        if (buffer->memoryOffset + localEnd > memory->size) localEnd = (memory->size - buffer->memoryOffset) & ~3ull;
        if (localEnd <= local) continue;
        nwg_buffer_write(buffer->gpu, (uint32_t)local, memory->shadow + buffer->memoryOffset + local,
                         (uint32_t)(localEnd - local));
    }
}

void vkw_flush_mapped(VkDevice device) {
    for (VkDeviceMemory memory = device->mappedMemories; memory; memory = memory->nextMapped) {
        // Memory the GPU copies into is a readback target: its shadow is
        // what came back, and pushing it up again would overwrite newer GPU
        // results with older ones.
        if (memory->gpuWritten) continue;
        vkw_memory_flush(memory, memory->mapOffset, memory->mapSize);
    }
}

// MARK: - Buffers

static uint32_t buffer_usage(VkBufferUsageFlags usage) {
    // Always copyable both ways: host writes arrive by queue.writeBuffer and
    // readbacks leave by copyBufferToBuffer.
    uint32_t out = GPU_BUFFER_COPY_SRC | GPU_BUFFER_COPY_DST;
    if (usage & VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT) out |= GPU_BUFFER_UNIFORM;
    if (usage & VK_BUFFER_USAGE_STORAGE_BUFFER_BIT) out |= GPU_BUFFER_STORAGE;
    if (usage & VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT) out |= GPU_BUFFER_INDIRECT;
    if (usage & VK_BUFFER_USAGE_VERTEX_BUFFER_BIT) out |= GPU_BUFFER_VERTEX;
    if (usage & VK_BUFFER_USAGE_INDEX_BUFFER_BIT) out |= GPU_BUFFER_INDEX;
    return out;
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateBuffer(
    VkDevice device, const VkBufferCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkBuffer *pBuffer) {
    (void)pAllocator;
    if (pCreateInfo->usage & (VK_BUFFER_USAGE_UNIFORM_TEXEL_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT)) {
        vkw_logf("vkCreateBuffer: texel buffers have no WebGPU equivalent");
        return VK_ERROR_FEATURE_NOT_PRESENT;
    }
    uint64_t size = (pCreateInfo->size + 3) & ~3ull;
    if (pCreateInfo->size == 0 || size > vkw_device_info(device)->maxBufferSize) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    uint32_t gpu = nwg_buffer_create((uint32_t)size, buffer_usage(pCreateInfo->usage));
    if (!gpu) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    VkBuffer buffer = calloc(1, sizeof *buffer);
    if (!buffer) {
        nwg_buffer_destroy(gpu);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    buffer->gpu = gpu;
    buffer->size = pCreateInfo->size;
    buffer->usage = pCreateInfo->usage;
    *pBuffer = buffer;
    return VK_SUCCESS;
}

static void unlink_buffer(VkBuffer buffer) {
    if (!buffer->memory) return;
    for (VkBuffer *link = &buffer->memory->buffers; *link; link = &(*link)->nextInMemory) {
        if (*link == buffer) {
            *link = buffer->nextInMemory;
            break;
        }
    }
    buffer->memory = NULL;
    buffer->nextInMemory = NULL;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyBuffer(VkDevice device, VkBuffer buffer, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!buffer) return;
    unlink_buffer(buffer);
    nwg_buffer_destroy(buffer->gpu);
    free(buffer);
}

VKAPI_ATTR void VKAPI_CALL vkGetBufferMemoryRequirements(
    VkDevice device, VkBuffer buffer, VkMemoryRequirements *pMemoryRequirements) {
    (void)device;
    // 256: WebGPU's uniform/storage offset alignment, so any suballocation a
    // caller makes is also a legal binding offset.
    pMemoryRequirements->alignment = 256;
    pMemoryRequirements->size = (buffer->size + 255) & ~255ull;
    pMemoryRequirements->memoryTypeBits = (1u << VKW_MEMORY_TYPE_COUNT) - 1;
}

VKAPI_ATTR VkResult VKAPI_CALL vkBindBufferMemory(
    VkDevice device, VkBuffer buffer, VkDeviceMemory memory, VkDeviceSize memoryOffset) {
    (void)device;
    if (memoryOffset + buffer->size > memory->size) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    unlink_buffer(buffer);
    buffer->memory = memory;
    buffer->memoryOffset = memoryOffset;
    buffer->nextInMemory = memory->buffers;
    memory->buffers = buffer;
    // Host data written before the bind belongs in the buffer too.
    if (host_visible(memory) && memory->mapped) vkw_memory_flush(memory, memoryOffset, buffer->size);
    return VK_SUCCESS;
}

// MARK: - Images

static uint32_t texture_usage(const nwg_device_info_t *info, VkFormat format, VkImageUsageFlags usage) {
    uint32_t flags = format_flags(info, format);
    uint32_t out = 0;
    if (usage & (VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT)) out |= GPU_TEXTURE_BINDING;
    if (usage & VK_IMAGE_USAGE_STORAGE_BIT) out |= GPU_TEXTURE_STORAGE;
    if (usage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)) {
        out |= GPU_TEXTURE_RENDER_ATTACHMENT;
    }
    if (usage & VK_IMAGE_USAGE_TRANSFER_SRC_BIT) {
        out |= GPU_TEXTURE_COPY_SRC;
        // vkCmdBlitImage reads its source through a sampler.
        if (flags & FMT_SAMPLE) out |= GPU_TEXTURE_BINDING;
    }
    if (usage & VK_IMAGE_USAGE_TRANSFER_DST_BIT) {
        out |= GPU_TEXTURE_COPY_DST;
        // vkCmdClearColorImage and vkCmdBlitImage write through a render pass.
        if (flags & FMT_RENDER) out |= GPU_TEXTURE_RENDER_ATTACHMENT;
    }
    return out;
}

static VkResult check_image_usage(const nwg_device_info_t *info, VkFormat format, VkImageUsageFlags usage) {
    uint32_t flags = format_flags(info, format);
    if (!flags) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    if ((usage & VK_IMAGE_USAGE_STORAGE_BIT) && !(flags & FMT_STORAGE)) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    if ((usage & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) && !(flags & FMT_RENDER)) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    if ((usage & VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT) && !(flags & FMT_DEPTH)) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    if ((usage & VK_IMAGE_USAGE_SAMPLED_BIT) && !(flags & FMT_SAMPLE)) return VK_ERROR_FORMAT_NOT_SUPPORTED;
    return VK_SUCCESS;
}

static const VkImportWebGPUTextureInfoNUCLEANT *webgpu_texture_import(const void *next) {
    for (const VkBaseInStructure *s = next; s; s = s->pNext) {
        if (s->sType == VK_STRUCTURE_TYPE_IMPORT_WEBGPU_TEXTURE_INFO_NUCLEANT) {
            return (const VkImportWebGPUTextureInfoNUCLEANT *)s;
        }
    }
    return NULL;
}

static int imports_memory(const void *next) {
    for (const VkBaseInStructure *s = next; s; s = s->pNext) {
        switch (s->sType) {
        case VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO:
        case VK_STRUCTURE_TYPE_IMPORT_METAL_TEXTURE_INFO_EXT:
        case VK_STRUCTURE_TYPE_IMPORT_METAL_IO_SURFACE_INFO_EXT:
            return 1;
        default:
            break;
        }
    }
    return 0;
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateImage(
    VkDevice device, const VkImageCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkImage *pImage) {
    (void)pAllocator;
    const nwg_device_info_t *info = vkw_device_info(device);
    VkResult supported = check_image_usage(info, pCreateInfo->format, pCreateInfo->usage);
    if (supported != VK_SUCCESS) {
        vkw_logf("vkCreateImage: format %d does not support usage 0x%x on WebGPU",
                 (int)pCreateInfo->format, (unsigned)pCreateInfo->usage);
        return supported;
    }
    const VkImportWebGPUTextureInfoNUCLEANT *import = webgpu_texture_import(pCreateInfo->pNext);
    uint32_t gpu;
    if (import) {
        // VK_NUCLEANT_webgpu_objects: the image is the texture.
        if (pCreateInfo->imageType != VK_IMAGE_TYPE_2D || pCreateInfo->mipLevels != 1 || pCreateInfo->arrayLayers != 1) {
            vkw_logf("vkCreateImage: a WebGPU texture is imported as a single-level 2D image");
            return VK_ERROR_INVALID_EXTERNAL_HANDLE;
        }
        gpu = nwg_texture_import((uint32_t)(uintptr_t)import->texture, (uint32_t)pCreateInfo->format,
                                 pCreateInfo->extent.width, pCreateInfo->extent.height);
        if (!gpu) return VK_ERROR_INVALID_EXTERNAL_HANDLE;
    } else if (pCreateInfo->tiling == VK_IMAGE_TILING_LINEAR || imports_memory(pCreateInfo->pNext)) {
        // Linear images exist for host access, and external-memory images
        // for importing platform memory (Metal, fd, AHB) — WebGPU has
        // neither, and a plain texture in their place would be silently
        // wrong rather than visibly unsupported.
        vkw_logf("vkCreateImage: linear tiling / imported memory is not available on WebGPU");
        return VK_ERROR_FORMAT_NOT_SUPPORTED;
    } else {
        uint32_t dimension = pCreateInfo->imageType == VK_IMAGE_TYPE_1D ? 1 : pCreateInfo->imageType == VK_IMAGE_TYPE_3D ? 3 : 2;
        nwg_texture_desc_t desc = {
            .format = (uint32_t)pCreateInfo->format,
            .width = pCreateInfo->extent.width,
            .height = pCreateInfo->extent.height,
            .depthOrLayers = dimension == 3 ? pCreateInfo->extent.depth : pCreateInfo->arrayLayers,
            .mipLevels = pCreateInfo->mipLevels,
            .sampleCount = (uint32_t)pCreateInfo->samples,
            .dimension = dimension,
            .usage = texture_usage(info, pCreateInfo->format, pCreateInfo->usage),
        };
        gpu = nwg_texture_create(&desc);
        if (!gpu) return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    }
    VkImage image = calloc(1, sizeof *image);
    if (!image) {
        nwg_texture_destroy(gpu);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    image->gpu = gpu;
    image->format = pCreateInfo->format;
    image->type = pCreateInfo->imageType;
    image->width = pCreateInfo->extent.width;
    image->height = pCreateInfo->extent.height;
    image->depth = pCreateInfo->extent.depth;
    image->mipLevels = pCreateInfo->mipLevels;
    image->arrayLayers = pCreateInfo->arrayLayers;
    image->usage = pCreateInfo->usage;
    image->samples = pCreateInfo->samples;
    *pImage = image;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyImage(VkDevice device, VkImage image, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!image) return;
    if (image->gpu) nwg_texture_destroy(image->gpu);
    free(image);
}

VKAPI_ATTR void VKAPI_CALL vkExportWebGPUObjectsNUCLEANT(
    VkDevice device, VkExportWebGPUTextureInfoNUCLEANT *pExportInfo) {
    (void)device;
    for (VkBaseOutStructure *s = (VkBaseOutStructure *)pExportInfo; s; s = s->pNext) {
        if (s->sType != VK_STRUCTURE_TYPE_EXPORT_WEBGPU_TEXTURE_INFO_NUCLEANT) continue;
        VkExportWebGPUTextureInfoNUCLEANT *info = (VkExportWebGPUTextureInfoNUCLEANT *)s;
        // A swapchain image is the canvas's current texture, not one of its own.
        uint32_t texture = info->image && info->image->gpu ? nwg_texture_export(info->image->gpu) : 0;
        info->texture = (void *)(uintptr_t)texture;
    }
}

VKAPI_ATTR void VKAPI_CALL vkGetImageMemoryRequirements(
    VkDevice device, VkImage image, VkMemoryRequirements *pMemoryRequirements) {
    (void)device;
    uint64_t bytes = 0;
    uint32_t texel = vkw_format_bytes(image->format);
    for (uint32_t mip = 0; mip < image->mipLevels; mip++) {
        uint64_t w = image->width >> mip ? image->width >> mip : 1;
        uint64_t h = image->height >> mip ? image->height >> mip : 1;
        uint64_t d = image->depth >> mip ? image->depth >> mip : 1;
        bytes += w * h * d * texel;
    }
    bytes *= image->arrayLayers * (uint64_t)image->samples;
    pMemoryRequirements->alignment = 256;
    pMemoryRequirements->size = (bytes + 255) & ~255ull;
    pMemoryRequirements->memoryTypeBits = (1u << VKW_MEMORY_TYPE_COUNT) - 1;
}

VKAPI_ATTR VkResult VKAPI_CALL vkBindImageMemory(
    VkDevice device, VkImage image, VkDeviceMemory memory, VkDeviceSize memoryOffset) {
    (void)device;
    (void)memoryOffset;
    // The GPUTexture owns its storage from creation; the binding is only
    // remembered.
    image->memory = memory;
    return VK_SUCCESS;
}

// MARK: - Image views

VKAPI_ATTR VkResult VKAPI_CALL vkCreateImageView(
    VkDevice device, const VkImageViewCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkImageView *pView) {
    (void)device;
    (void)pAllocator;
    VkImage image = pCreateInfo->image;
    const VkImageSubresourceRange *range = &pCreateInfo->subresourceRange;
    uint32_t mipCount = range->levelCount == VK_REMAINING_MIP_LEVELS ? image->mipLevels - range->baseMipLevel : range->levelCount;
    uint32_t layerCount = range->layerCount == VK_REMAINING_ARRAY_LAYERS ? image->arrayLayers - range->baseArrayLayer : range->layerCount;
    nwg_view_desc_t desc = {
        .texture = image->gpu,
        .surface = image->gpu ? 0 : image->surface,
        .format = (uint32_t)pCreateInfo->format,
        .viewType = (uint32_t)pCreateInfo->viewType,
        .baseMip = range->baseMipLevel,
        .mipCount = mipCount,
        .baseLayer = range->baseArrayLayer,
        .layerCount = layerCount,
    };
    uint32_t gpu = nwg_view_create(&desc);
    if (!gpu) return VK_ERROR_OUT_OF_HOST_MEMORY;
    VkImageView view = calloc(1, sizeof *view);
    if (!view) {
        nwg_view_destroy(gpu);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    view->gpu = gpu;
    view->image = image;
    view->format = pCreateInfo->format;
    view->baseMip = range->baseMipLevel;
    view->mipCount = mipCount;
    view->baseLayer = range->baseArrayLayer;
    view->layerCount = layerCount;
    *pView = view;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroyImageView(VkDevice device, VkImageView imageView, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!imageView) return;
    nwg_view_destroy(imageView->gpu);
    free(imageView);
}

// MARK: - Samplers

VKAPI_ATTR VkResult VKAPI_CALL vkCreateSampler(
    VkDevice device, const VkSamplerCreateInfo *pCreateInfo, const VkAllocationCallbacks *pAllocator,
    VkSampler *pSampler) {
    (void)device;
    (void)pAllocator;
    nwg_sampler_desc_t desc = {
        .magFilter = (uint32_t)pCreateInfo->magFilter,
        .minFilter = (uint32_t)pCreateInfo->minFilter,
        .mipmapMode = (uint32_t)pCreateInfo->mipmapMode,
        .addressU = (uint32_t)pCreateInfo->addressModeU,
        .addressV = (uint32_t)pCreateInfo->addressModeV,
        .addressW = (uint32_t)pCreateInfo->addressModeW,
        .minLod = pCreateInfo->minLod,
        .maxLod = pCreateInfo->maxLod,
        .compareEnable = pCreateInfo->compareEnable,
        .compareOp = (uint32_t)pCreateInfo->compareOp,
        .maxAnisotropy = pCreateInfo->anisotropyEnable ? (uint32_t)pCreateInfo->maxAnisotropy : 1,
    };
    uint32_t gpu = nwg_sampler_create(&desc);
    if (!gpu) return VK_ERROR_OUT_OF_HOST_MEMORY;
    VkSampler sampler = calloc(1, sizeof *sampler);
    if (!sampler) {
        nwg_sampler_destroy(gpu);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    sampler->gpu = gpu;
    *pSampler = sampler;
    return VK_SUCCESS;
}

VKAPI_ATTR void VKAPI_CALL vkDestroySampler(VkDevice device, VkSampler sampler, const VkAllocationCallbacks *pAllocator) {
    (void)device;
    (void)pAllocator;
    if (!sampler) return;
    nwg_sampler_destroy(sampler->gpu);
    free(sampler);
}

#endif /* __wasm__ */
