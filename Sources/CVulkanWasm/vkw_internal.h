// Internal to the wasm Vulkan implementation: the Vk object layouts, the JS
// bridge it calls into (Web/nucleant-webgpu.js), and the command stream a
// submit hands that bridge.
//
// Division of labour. This C side owns every piece of *Vulkan* state —
// memory and its host-visible shadow, descriptor sets, render passes,
// recorded command buffers, fences — and keeps Vulkan's semantics for them.
// The JS side owns the WebGPU objects, referenced from here by integer ids
// (0 = none; ids are never reused, so a stale one fails loudly instead of
// aliasing a newer object). A command buffer is recorded here and only
// turned into WebGPU commands at vkQueueSubmit, when everything Vulkan says
// is read at execution time (descriptor contents, mapped memory) has its
// final value.

#ifndef VKW_INTERNAL_H
#define VKW_INTERNAL_H

#if defined(__wasm__)

#include "include/shim.h"
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

// MARK: - JS bridge imports

#define NWG_IMPORT(name) __attribute__((import_module("nucleant_webgpu"), import_name(#name)))

/// Facts about the adapter/device the bridge acquired before wasm started.
/// Filled by the bridge; every field is a 32-bit little-endian word.
typedef struct nwg_device_info {
    uint32_t preferredFormat;            // VkFormat of getPreferredCanvasFormat()
    uint32_t bgra8unormStorage;          // 'bgra8unorm-storage' enabled
    uint32_t float32Filterable;          // 'float32-filterable' enabled
    uint32_t maxTextureDimension2D;
    uint32_t maxTextureDimension3D;
    uint32_t maxTextureArrayLayers;
    uint32_t maxBindGroups;
    uint32_t maxUniformBufferBindingSize;
    uint32_t maxStorageBufferBindingSize;
    uint32_t maxBufferSize;              // clamped to 32 bits
    uint32_t maxComputeWorkgroupsPerDimension;
    uint32_t maxComputeInvocationsPerWorkgroup;
    uint32_t blockingWaits;              // 1 when waits really block (JSPI)
    char     adapterName[200];
} nwg_device_info_t;

typedef struct nwg_texture_desc {
    uint32_t format;          // VkFormat
    uint32_t width, height, depthOrLayers;
    uint32_t mipLevels, sampleCount;
    uint32_t dimension;       // 1, 2 or 3
    uint32_t usage;           // GPUTextureUsage bits
} nwg_texture_desc_t;

typedef struct nwg_view_desc {
    uint32_t texture;         // texture id, or 0 for a swapchain image's view
    uint32_t surface;         // surface id for a swapchain image's view
    uint32_t format;          // VkFormat
    uint32_t viewType;        // VkImageViewType
    uint32_t baseMip, mipCount, baseLayer, layerCount;
} nwg_view_desc_t;

typedef struct nwg_sampler_desc {
    uint32_t magFilter, minFilter, mipmapMode;          // VkFilter / VkSamplerMipmapMode
    uint32_t addressU, addressV, addressW;              // VkSamplerAddressMode
    float    minLod, maxLod;
    uint32_t compareEnable, compareOp;                  // VkCompareOp
    uint32_t maxAnisotropy;
} nwg_sampler_desc_t;

typedef struct nwg_stage {
    const uint32_t *code;     // SPIR-V words
    uint32_t        wordCount;
    const char     *entry;
    uint32_t        entryLen;
} nwg_stage_t;

typedef struct nwg_color_target {
    uint32_t format;          // VkFormat
    uint32_t blendEnable;
    uint32_t srcColor, dstColor, colorOp;   // VkBlendFactor / VkBlendOp
    uint32_t srcAlpha, dstAlpha, alphaOp;
    uint32_t writeMask;       // VkColorComponentFlags (same bit order as GPUColorWrite)
} nwg_color_target_t;

#define NWG_MAX_VERTEX_BINDINGS   16
#define NWG_MAX_VERTEX_ATTRIBUTES 16

typedef struct nwg_vertex_binding {
    uint32_t binding;         // the Vulkan binding number
    uint32_t stride;
    uint32_t perInstance;
} nwg_vertex_binding_t;

typedef struct nwg_vertex_attribute {
    uint32_t location, binding;
    uint32_t format;          // VkFormat
    uint32_t offset;
} nwg_vertex_attribute_t;

typedef struct nwg_stencil_face {
    uint32_t compare;         // VkCompareOp
    uint32_t fail, depthFail, pass;   // VkStencilOp
} nwg_stencil_face_t;

typedef struct nwg_render_pipeline_desc {
    nwg_stage_t        vertex;
    nwg_stage_t        fragment;
    uint32_t           hasFragment;
    uint32_t           setCount;        // the draw-data group sits right after the sets
    uint32_t           topology;        // VkPrimitiveTopology
    uint32_t           cullMode;        // VkCullModeFlags
    uint32_t           frontFace;       // VkFrontFace
    uint32_t           sampleCount;
    uint32_t           colorCount;
    nwg_color_target_t colors[8];
    uint32_t               bindingCount;
    nwg_vertex_binding_t   bindings[NWG_MAX_VERTEX_BINDINGS];
    uint32_t               attributeCount;
    nwg_vertex_attribute_t attributes[NWG_MAX_VERTEX_ATTRIBUTES];
    uint32_t           depthFormat;     // VkFormat of the subpass's depth/stencil attachment, 0 = none
    uint32_t           depthTest, depthWrite;
    uint32_t           depthCompare;    // VkCompareOp
    uint32_t           stencilTest;
    nwg_stencil_face_t front, back;
    uint32_t           stencilReadMask, stencilWriteMask;  // the static ones; dynamic masks come per draw
} nwg_render_pipeline_desc_t;

typedef struct nwg_compute_pipeline_desc {
    nwg_stage_t compute;
    uint32_t    setCount;
} nwg_compute_pipeline_desc_t;

NWG_IMPORT(deviceInfo)        void     nwg_device_info(nwg_device_info_t *out);
NWG_IMPORT(log)               void     nwg_log(const char *message, uint32_t length);

NWG_IMPORT(surfaceCreate)     uint32_t nwg_surface_create(const char *selector, uint32_t length);
NWG_IMPORT(surfaceDestroy)    void     nwg_surface_destroy(uint32_t surface);
NWG_IMPORT(surfaceGetSize)    void     nwg_surface_get_size(uint32_t surface, uint32_t *widthHeight);
NWG_IMPORT(surfaceConfigure)  void     nwg_surface_configure(uint32_t surface, uint32_t format, uint32_t usage, uint32_t premultiplied);
NWG_IMPORT(surfaceUnconfigure) void    nwg_surface_unconfigure(uint32_t surface);

NWG_IMPORT(bufferCreate)      uint32_t nwg_buffer_create(uint32_t size, uint32_t usage);
NWG_IMPORT(bufferDestroy)     void     nwg_buffer_destroy(uint32_t buffer);
NWG_IMPORT(bufferWrite)       void     nwg_buffer_write(uint32_t buffer, uint32_t offset, const void *data, uint32_t size);

NWG_IMPORT(textureCreate)     uint32_t nwg_texture_create(const nwg_texture_desc_t *desc);
/// A reference to a texture made through webgpu.h (CWgpu), for a VkImage
/// over it (VK_NUCLEANT_webgpu_objects); 0 when it is not a texture of that
/// VkFormat and size. Released by nwg_texture_destroy like any other.
NWG_IMPORT(textureImport)     uint32_t nwg_texture_import(uint32_t texture, uint32_t format, uint32_t width, uint32_t height);
/// A new reference to an image's texture, as webgpu.h's `WGPUTexture`
/// (VK_NUCLEANT_webgpu_objects); released through webgpu.h.
NWG_IMPORT(textureExport)     uint32_t nwg_texture_export(uint32_t texture);
/// Drops a texture reference; the GPUTexture is destroyed with its last.
NWG_IMPORT(textureDestroy)    void     nwg_texture_destroy(uint32_t texture);
NWG_IMPORT(viewCreate)        uint32_t nwg_view_create(const nwg_view_desc_t *desc);
NWG_IMPORT(viewDestroy)       void     nwg_view_destroy(uint32_t view);
NWG_IMPORT(samplerCreate)     uint32_t nwg_sampler_create(const nwg_sampler_desc_t *desc);
NWG_IMPORT(samplerDestroy)    void     nwg_sampler_destroy(uint32_t sampler);

NWG_IMPORT(renderPipelineCreate)  uint32_t nwg_render_pipeline_create(const nwg_render_pipeline_desc_t *desc);
NWG_IMPORT(computePipelineCreate) uint32_t nwg_compute_pipeline_create(const nwg_compute_pipeline_desc_t *desc);
NWG_IMPORT(pipelineDestroy)       void     nwg_pipeline_destroy(uint32_t pipeline);

NWG_IMPORT(descriptorSetRelease)  void     nwg_descriptor_set_release(uint32_t set);
NWG_IMPORT(memoryRelease)         void     nwg_memory_release(uint32_t memory);

/// Encodes and submits `stream` (see NWG_OP_*), with `arena` uploaded first
/// as the submit's scratch buffer. Returns the submit's serial.
NWG_IMPORT(queueSubmit)           uint32_t nwg_queue_submit(const uint32_t *stream, uint32_t wordCount, const void *arena, uint32_t arenaSize);
/// Newest serial whose GPU work (and readbacks) have finished.
NWG_IMPORT(queueCompletedSerial)  uint32_t nwg_queue_completed_serial(void);
/// Blocks until `serial` has finished when the bridge can block (JSPI);
/// returns 1 then, 0 when it had to return without waiting.
NWG_IMPORT(queueWaitSerial)       uint32_t nwg_queue_wait_serial(uint32_t serial);

// MARK: - Command stream

enum {
    NWG_OP_BEGIN_RENDER_PASS     = 1,  // count, {view, loadOp, storeOp, r, g, b, a} * count,
                                       // depthView (0 = none), depthLoad, depthStore, depth (f32),
                                       // stencilLoad, stencilStore, stencil, width, height
    NWG_OP_END_RENDER_PASS       = 2,
    NWG_OP_SET_PIPELINE          = 3,  // bindPoint, pipeline
    NWG_OP_BIND_SET              = 4,  // bindPoint, index, set, version, count, {binding, type, a, b, c} * count
    NWG_OP_SET_VIEWPORT          = 5,  // x, y, w, h, minDepth, maxDepth (f32 bits)
    NWG_OP_SET_SCISSOR           = 6,  // x, y, w, h
    NWG_OP_DRAW_DATA             = 7,  // bindPoint, arena offset of the slot
    NWG_OP_DRAW                  = 8,  // vertexCount, instanceCount, firstVertex, firstInstance
    NWG_OP_DRAW_INDIRECT         = 9,  // buffer, offset
    NWG_OP_BEGIN_COMPUTE_PASS    = 10,
    NWG_OP_END_COMPUTE_PASS      = 11,
    NWG_OP_DISPATCH              = 12, // x, y, z
    NWG_OP_COPY_BUFFER_TO_BUFFER = 13, // src, srcOffset, dst, dstOffset, size
    NWG_OP_COPY_BUFFER_TO_TEXTURE= 14, // buffer (0 = arena), offset, bytesPerRow, rowsPerImage, texture, mip, x, y, z, w, h, d
    NWG_OP_COPY_TEXTURE_TO_BUFFER= 15, // texture, mip, x, y, z, w, h, d, buffer, offset, bytesPerRow, rowsPerImage
    NWG_OP_COPY_TEXTURE_TO_TEXTURE=16, // src, srcMip, sx, sy, sz, dst, dstMip, dx, dy, dz, w, h, d
    NWG_OP_CLEAR_TEXTURE         = 17, // texture, mip, layer, r, g, b, a (f32 bits)
    NWG_OP_BLIT_TEXTURE          = 18, // src, srcMip, srcLayer, x0, y0, x1, y1, dst, dstMip, dstLayer, x0, y0, x1, y1, filter
    NWG_OP_READBACK              = 19, // buffer, offset, size, memory, host pointer
    NWG_OP_SET_VERTEX_BUFFER     = 20, // binding (Vulkan's), buffer, offset
    NWG_OP_SET_INDEX_BUFFER      = 21, // buffer, offset, uint32 (0 = 16-bit indices)
    NWG_OP_DRAW_INDEXED          = 22, // indexCount, instanceCount, firstIndex, vertexOffset (i32), firstInstance
    NWG_OP_SET_STENCIL_REFERENCE = 23, // reference
    NWG_OP_SET_STENCIL_MASKS     = 24, // compareMask, writeMask
    NWG_OP_SET_BLEND_CONSTANT    = 25, // r, g, b, a (f32 bits)
    NWG_OP_CLEAR_ATTACHMENTS     = 26, // x, y, w, h, colorCount, {attachment, r, g, b, a} * colorCount,
                                       // clearDepth, depth (f32), clearStencil, stencil
};

enum {
    NWG_BIND_GRAPHICS = 0,
    NWG_BIND_COMPUTE  = 1,
};

enum {
    NWG_DESC_SAMPLER         = 1, // a = sampler
    NWG_DESC_COMBINED        = 2, // a = view, b = sampler
    NWG_DESC_SAMPLED_IMAGE   = 3, // a = view
    NWG_DESC_STORAGE_IMAGE   = 4, // a = view
    NWG_DESC_UNIFORM_BUFFER  = 5, // a = buffer, b = offset, c = size (0 = rest of buffer)
    NWG_DESC_STORAGE_BUFFER  = 6, // a = buffer, b = offset, c = size (0 = rest of buffer)
};

/// One draw/dispatch's emulated per-draw data in the arena: the viewport
/// remap at +0, push constants at +256 (both dynamic storage offsets, which
/// WebGPU aligns to 256).
#define NWG_DRAW_DATA_SLOT        512u
#define NWG_PUSH_CONSTANT_OFFSET  256u
#define NWG_MAX_PUSH_CONSTANTS    128u
#define NWG_COPY_ROW_ALIGNMENT    256u

// GPUBufferUsage / GPUTextureUsage bits.
enum {
    GPU_BUFFER_MAP_READ = 0x1, GPU_BUFFER_MAP_WRITE = 0x2, GPU_BUFFER_COPY_SRC = 0x4,
    GPU_BUFFER_COPY_DST = 0x8, GPU_BUFFER_INDEX = 0x10, GPU_BUFFER_VERTEX = 0x20,
    GPU_BUFFER_UNIFORM = 0x40, GPU_BUFFER_STORAGE = 0x80, GPU_BUFFER_INDIRECT = 0x100,
};
enum {
    GPU_TEXTURE_COPY_SRC = 0x1, GPU_TEXTURE_COPY_DST = 0x2, GPU_TEXTURE_BINDING = 0x4,
    GPU_TEXTURE_STORAGE = 0x8, GPU_TEXTURE_RENDER_ATTACHMENT = 0x10,
};

// MARK: - Objects

#define VKW_MEMORY_TYPE_DEVICE_LOCAL 0u
#define VKW_MEMORY_TYPE_HOST_VISIBLE 1u
#define VKW_MEMORY_TYPE_COUNT        2u
#define VKW_MAX_SETS                 4u
#define VKW_MAX_COLOR_ATTACHMENTS    8u
#define VKW_MAX_SWAPCHAIN_IMAGES     3u

struct VkInstance_T {
    uint32_t                 surfaceExtension;   // VK_NUCLEANT_webgpu_surface enabled
    struct VkPhysicalDevice_T *physicalDevice;
};

struct VkPhysicalDevice_T {
    VkInstance        instance;
    nwg_device_info_t info;
};

struct VkQueue_T {
    VkDevice device;
    uint32_t lastSerial;      // newest serial submitted
};

struct VkDevice_T {
    VkPhysicalDevice   physicalDevice;
    struct VkQueue_T   queue;
    VkDeviceMemory     mappedMemories;   // linked through VkDeviceMemory_T.nextMapped
};

struct VkDeviceMemory_T {
    uint32_t       id;
    uint64_t       size;
    uint32_t       typeIndex;
    uint8_t       *shadow;               // host copy, HOST_VISIBLE only
    VkBuffer       buffers;              // bound buffers, linked through nextInMemory
    int            mapped;
    uint64_t       mapOffset, mapSize;
    int            gpuWritten;           // a GPU copy writes it: it is read back, not flushed
    VkDeviceMemory nextMapped;
};

struct VkBuffer_T {
    uint32_t           gpu;
    uint64_t           size;
    VkBufferUsageFlags usage;
    VkDeviceMemory     memory;
    uint64_t           memoryOffset;
    VkBuffer           nextInMemory;
};

struct VkImage_T {
    uint32_t           gpu;            // 0 for a swapchain image
    uint32_t           surface;        // swapchain images: the canvas surface
    VkFormat           format;
    VkImageType        type;
    uint32_t           width, height, depth, mipLevels, arrayLayers;
    VkImageUsageFlags  usage;
    VkSampleCountFlagBits samples;
    VkDeviceMemory     memory;
};

struct VkImageView_T {
    uint32_t gpu;
    VkImage  image;
    VkFormat format;
    uint32_t baseMip, mipCount, baseLayer, layerCount;
};

struct VkSampler_T {
    uint32_t gpu;
};

struct VkShaderModule_T {
    uint32_t *words;
    uint32_t  wordCount;
};

typedef struct vkw_layout_binding {
    uint32_t         binding;
    VkDescriptorType type;
    uint32_t         count;
    VkSampler       *immutableSamplers;  // count entries, or NULL
} vkw_layout_binding_t;

struct VkDescriptorSetLayout_T {
    uint32_t              bindingCount;
    vkw_layout_binding_t *bindings;
    uint32_t              descriptorCount;  // sum of counts
};

struct VkPipelineLayout_T {
    uint32_t setCount;
    uint32_t pushConstantSize;
};

/// One descriptor's current contents, already in bridge terms.
typedef struct vkw_descriptor {
    uint32_t binding;
    uint32_t type;      // NWG_DESC_*, 0 = never written
    uint32_t a, b, c;
    uint32_t immutableSampler;  // the layout's sampler for this slot, 0 = none
} vkw_descriptor_t;

struct VkDescriptorSet_T {
    uint32_t                id;
    uint32_t                version;      // bumped on every update
    VkDescriptorSetLayout   layout;       // borrowed; must outlive the set, as in Vulkan
    uint32_t                count;
    vkw_descriptor_t       *descriptors;
    VkDescriptorPool        pool;
    VkDescriptorSet         nextInPool;
};

struct VkDescriptorPool_T {
    uint32_t        maxSets;
    uint32_t        liveSets;
    VkDescriptorSet sets;
};

typedef struct vkw_attachment {
    VkFormat            format;
    VkAttachmentLoadOp  loadOp;
    VkAttachmentStoreOp storeOp;
    VkAttachmentLoadOp  stencilLoadOp;
    VkAttachmentStoreOp stencilStoreOp;
} vkw_attachment_t;

struct VkRenderPass_T {
    uint32_t         attachmentCount;
    vkw_attachment_t attachments[VKW_MAX_COLOR_ATTACHMENTS + 1];
    uint32_t         colorCount;                          // subpass 0
    uint32_t         colorRefs[VKW_MAX_COLOR_ATTACHMENTS];  // attachment index or VK_ATTACHMENT_UNUSED
    uint32_t         depthRef;                            // attachment index or VK_ATTACHMENT_UNUSED
};

struct VkFramebuffer_T {
    uint32_t    attachmentCount;
    VkImageView attachments[VKW_MAX_COLOR_ATTACHMENTS + 1];
    uint32_t    width, height, layers;
};

struct VkPipeline_T {
    uint32_t   gpu;
    int        compute;
    uint32_t   setCount;
    int        dynamicViewport, dynamicScissor;
    VkViewport viewport;
    VkRect2D   scissor;
    // State Vulkan takes from the pipeline unless it is dynamic.
    int        dynamicStencilReference, dynamicStencilMasks, dynamicBlendConstants;
    uint32_t   stencilReference, stencilCompareMask, stencilWriteMask;
    float      blendConstants[4];
};

struct VkCommandPool_T {
    VkCommandBuffer buffers;   // linked through nextInPool
};

struct VkFence_T {
    uint32_t serial;           // signalled once this serial completes; UINT32_MAX = unsignalled, unsubmitted
};

struct VkSemaphore_T {
    int unused;
};

struct VkSurfaceKHR_T {
    uint32_t id;
};

struct VkSwapchainKHR_T {
    VkSurfaceKHR surface;
    VkFormat     format;
    VkExtent2D   extent;
    uint32_t     imageCount;
    VkImage      images[VKW_MAX_SWAPCHAIN_IMAGES];
    uint32_t     nextImage;
};

// MARK: - Recorded commands

typedef enum vkw_cmd_type {
    VKW_CMD_BEGIN_RENDER_PASS,
    VKW_CMD_END_RENDER_PASS,
    VKW_CMD_BIND_PIPELINE,
    VKW_CMD_BIND_SETS,
    VKW_CMD_PUSH_CONSTANTS,
    VKW_CMD_SET_VIEWPORT,
    VKW_CMD_SET_SCISSOR,
    VKW_CMD_DRAW,
    VKW_CMD_DRAW_INDIRECT,
    VKW_CMD_DISPATCH,
    VKW_CMD_COPY_BUFFER_TO_IMAGE,
    VKW_CMD_COPY_IMAGE_TO_BUFFER,
    VKW_CMD_COPY_IMAGE,
    VKW_CMD_BLIT_IMAGE,
    VKW_CMD_CLEAR_COLOR_IMAGE,
    VKW_CMD_BIND_VERTEX_BUFFERS,
    VKW_CMD_BIND_INDEX_BUFFER,
    VKW_CMD_DRAW_INDEXED,
    VKW_CMD_SET_STENCIL,
    VKW_CMD_SET_BLEND_CONSTANTS,
    VKW_CMD_CLEAR_ATTACHMENTS,
} vkw_cmd_type_t;

enum { VKW_STENCIL_COMPARE_MASK, VKW_STENCIL_WRITE_MASK, VKW_STENCIL_REFERENCE };

typedef struct vkw_cmd {
    vkw_cmd_type_t type;
    union {
        struct {
            VkRenderPass  renderPass;
            VkFramebuffer framebuffer;
            uint32_t      clearCount;
            VkClearValue  clears[VKW_MAX_COLOR_ATTACHMENTS];
        } beginRenderPass;
        struct { uint32_t bindPoint; VkPipeline pipeline; } bindPipeline;
        struct {
            uint32_t        bindPoint;
            uint32_t        firstSet, count;
            VkDescriptorSet sets[VKW_MAX_SETS];
        } bindSets;
        struct { uint32_t offset, size; uint8_t bytes[NWG_MAX_PUSH_CONSTANTS]; } pushConstants;
        VkViewport viewport;
        VkRect2D   scissor;
        struct { uint32_t vertexCount, instanceCount, firstVertex, firstInstance; } draw;
        struct { VkBuffer buffer; uint64_t offset; } drawIndirect;
        struct { uint32_t x, y, z; } dispatch;
        struct { VkBuffer buffer; VkImage image; VkBufferImageCopy region; } bufferImage;
        struct { VkImage src, dst; VkImageCopy region; } copyImage;
        struct { VkImage src, dst; VkImageBlit region; VkFilter filter; } blit;
        struct { VkImage image; VkClearColorValue color; VkImageSubresourceRange range; } clear;
        struct {
            uint32_t first, count;
            VkBuffer buffers[NWG_MAX_VERTEX_BINDINGS];
            uint64_t offsets[NWG_MAX_VERTEX_BINDINGS];
        } vertexBuffers;
        struct { VkBuffer buffer; uint64_t offset; VkIndexType type; } indexBuffer;
        struct { uint32_t indexCount, instanceCount, firstIndex; int32_t vertexOffset; uint32_t firstInstance; } drawIndexed;
        struct { uint32_t which; VkStencilFaceFlags faces; uint32_t value; } stencil;
        float blendConstants[4];
        struct {
            uint32_t          count;
            VkClearAttachment attachments[VKW_MAX_COLOR_ATTACHMENTS + 1];
            VkClearRect       rect;
        } clearAttachments;
    };
} vkw_cmd_t;

struct VkCommandBuffer_T {
    VkDevice        device;
    VkCommandPool   pool;
    VkCommandBuffer nextInPool;
    vkw_cmd_t      *commands;
    uint32_t        count, capacity;
    int             recording;
};

// MARK: - Shared helpers

void vkw_logf(const char *format, ...) __attribute__((format(printf, 1, 2)));

/// A fresh id for a descriptor set or device memory, unique for the life of
/// the process — the bridge keys its caches by these across every device.
uint32_t vkw_next_id(void);

/// Device-level state the command/queue code needs.
const nwg_device_info_t *vkw_device_info(VkDevice device);

/// Bytes per texel of an uncompressed colour format, 0 when unsupported.
uint32_t vkw_format_bytes(VkFormat format);
/// Whether the bridge can create a texture of `format` with `usage`.
int vkw_format_supports(const nwg_device_info_t *info, VkFormat format, VkFormatFeatureFlags features);
VkFormatFeatureFlags vkw_format_features(const nwg_device_info_t *info, VkFormat format);

/// Uploads the host shadow of `memory` (the overlap with [offset, offset+size))
/// to every buffer bound to it.
void vkw_memory_flush(VkDeviceMemory memory, uint64_t offset, uint64_t size);
/// Flushes every currently-mapped host-visible memory (persistent maps) of
/// `device` that the GPU does not write.
void vkw_flush_mapped(VkDevice device);

#endif /* __wasm__ */

#endif /* VKW_INTERNAL_H */
