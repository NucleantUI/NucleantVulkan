// The browser's own Vulkan extensions. Khronos has none for a page, so this
// implementation defines them, each in the shape of the platform extension
// it stands in for.
//
// VK_NUCLEANT_webgpu_surface — a VkSurfaceKHR for an HTML <canvas>.
//
// Every platform reaches its window through its own surface extension
// (VK_EXT_metal_surface for a CAMetalLayer, VK_KHR_wayland_surface for a
// wl_surface, VK_KHR_android_surface for an ANativeWindow). This is the
// browser's: the canvas is named by a CSS selector, and the surface presents
// through that canvas's "webgpu" context.
//
// VK_NUCLEANT_webgpu_objects — a VkImage over a WebGPU texture, and the
// WebGPU texture under a VkImage.
//
// VK_EXT_metal_objects imports an MTLTexture as a VkImage. In the browser
// the texture is a webgpu.h `WGPUTexture` made on the page's GPUDevice — the
// one this implementation runs on — through CWgpu's webgpu.h. Chained to
// VkImageCreateInfo, the image *is* that texture: no memory of its own, no
// copy, and what is drawn into the texture through webgpu.h is what the
// image samples. The image holds its own reference to the texture until it
// is destroyed. Its format and extent must be the texture's.
//
// The structure is honoured whether or not the extension was enabled on the
// device, the way MoltenVK honours VkImportMetalTextureInfoEXT.
//
// The other direction is vkExportMetalObjectsEXT's: vkExportWebGPUObjectsNUCLEANT
// hands out the `WGPUTexture` an image is, for drawing into it through
// webgpu.h (Skia's Graphite does). Same texture, no copy; the caller gets
// its own reference and releases it with wgpuTextureRelease. Work submitted
// through either API reaches the one GPUQueue in call order, so no
// synchronization beyond submission order is needed. A swapchain image has
// no texture of its own (it is the canvas's current one) and exports NULL.

#ifndef VULKAN_WEBGPU_NUCLEANT_H_
#define VULKAN_WEBGPU_NUCLEANT_H_ 1

#if defined(__wasm__)

#ifdef __cplusplus
extern "C" {
#endif

#define VK_NUCLEANT_webgpu_surface 1
#define VK_NUCLEANT_WEBGPU_SURFACE_SPEC_VERSION 1
#define VK_NUCLEANT_WEBGPU_SURFACE_EXTENSION_NAME "VK_NUCLEANT_webgpu_surface"

/// Outside every range Khronos has assigned, so it never collides with a
/// real structure type.
static const VkStructureType VK_STRUCTURE_TYPE_WEBGPU_SURFACE_CREATE_INFO_NUCLEANT =
    (VkStructureType)1000999000;

typedef VkFlags VkWebGPUSurfaceCreateFlagsNUCLEANT;

typedef struct VkWebGPUSurfaceCreateInfoNUCLEANT {
    VkStructureType                    sType;
    const void*                        pNext;
    VkWebGPUSurfaceCreateFlagsNUCLEANT flags;
    /// CSS selector of the <canvas> to present into, e.g. "#nucleant-window-1".
    const char*                        pCanvasSelector;
} VkWebGPUSurfaceCreateInfoNUCLEANT;

VKAPI_ATTR VkResult VKAPI_CALL vkCreateWebGPUSurfaceNUCLEANT(
    VkInstance                               instance,
    const VkWebGPUSurfaceCreateInfoNUCLEANT* pCreateInfo,
    const VkAllocationCallbacks*             pAllocator,
    VkSurfaceKHR*                            pSurface);

#define VK_NUCLEANT_webgpu_objects 1
#define VK_NUCLEANT_WEBGPU_OBJECTS_SPEC_VERSION 1
#define VK_NUCLEANT_WEBGPU_OBJECTS_EXTENSION_NAME "VK_NUCLEANT_webgpu_objects"

static const VkStructureType VK_STRUCTURE_TYPE_IMPORT_WEBGPU_TEXTURE_INFO_NUCLEANT =
    (VkStructureType)1000999001;

typedef struct VkImportWebGPUTextureInfoNUCLEANT {
    VkStructureType sType;
    const void*     pNext;
    /// A webgpu.h `WGPUTexture` (CWgpu), as an opaque pointer so this header
    /// does not need webgpu.h.
    void*           texture;
} VkImportWebGPUTextureInfoNUCLEANT;

static const VkStructureType VK_STRUCTURE_TYPE_EXPORT_WEBGPU_TEXTURE_INFO_NUCLEANT =
    (VkStructureType)1000999002;

typedef struct VkExportWebGPUTextureInfoNUCLEANT {
    VkStructureType sType;
    const void*     pNext;
    VkImage         image;
    /// Out: a new reference to the image's `WGPUTexture` (CWgpu), or NULL.
    void*           texture;
} VkExportWebGPUTextureInfoNUCLEANT;

/// Fills `texture` of each VkExportWebGPUTextureInfoNUCLEANT in the chain
/// starting at `pExportInfo` (vkExportMetalObjectsEXT's shape).
VKAPI_ATTR void VKAPI_CALL vkExportWebGPUObjectsNUCLEANT(
    VkDevice                           device,
    VkExportWebGPUTextureInfoNUCLEANT* pExportInfo);

#ifdef __cplusplus
}
#endif

#endif /* __wasm__ */

#endif /* VULKAN_WEBGPU_NUCLEANT_H_ */
