// CVulkan shim — Vulkan API on WebAssembly, implemented on the browser's
// WebGPU (Sources/CVulkanWasm/*.c + Web/nucleant-webgpu.js).
//
// The wasm counterpart of the Apple shim, where MoltenVK implements Vulkan on
// Metal: here the implementation is this target's own C, translating each
// vk* call into WebGPU through the JS bridge. Swift code imports `CVulkan`
// exactly as on every other platform and sees the same Vulkan API.

#ifndef CVulkan_shim_h
#define CVulkan_shim_h

#if defined(__wasm__)

// Non-dispatchable handles as pointers, the way every 64-bit platform has
// them. wasm32 is a 32-bit target, where the header would otherwise make
// them `uint64_t` — and the engine's Swift code (`VkImage?`, `if let view`)
// is written against pointer handles. Every handle is one of this
// implementation's own objects, so the choice is internal to the build.
#define VK_USE_64_BIT_PTR_DEFINES 1

#include "vulkan/vulkan.h"
#include "vulkan_webgpu_nucleant.h"

#endif /* __wasm__ */

#endif /* CVulkan_shim_h */
