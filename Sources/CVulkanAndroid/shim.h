// CVulkan Android shim — Vulkan is built into Android (API 24+).
// The NDK provides <vulkan/vulkan.h> and <vulkan/vulkan_android.h>.

#ifndef CVulkanAndroid_shim_h
#define CVulkanAndroid_shim_h

#define VK_USE_PLATFORM_ANDROID_KHR 1
#include <vulkan/vulkan.h>

#endif /* CVulkanAndroid_shim_h */
