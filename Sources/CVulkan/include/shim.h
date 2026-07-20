// CVulkan shim — Vulkan API via MoltenVK on Apple platforms.

#ifndef CVulkan_shim_h
#define CVulkan_shim_h

#include <TargetConditionals.h>

#if TARGET_OS_IOS
    #define VK_USE_PLATFORM_IOS_MVK 1
#elif TARGET_OS_OSX
    #define VK_USE_PLATFORM_MACOS_MVK 1
#endif

#define VK_USE_PLATFORM_METAL_EXT 1

#include "vulkan/vulkan.h"

#if TARGET_OS_IOS
    #include "vulkan/vulkan_ios.h"
#elif TARGET_OS_OSX
    #include "vulkan/vulkan_macos.h"
#endif
#include "vulkan/vulkan_metal.h"

#endif /* CVulkan_shim_h */
