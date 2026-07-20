// CVulkan Linux shim — system Vulkan loader via pkg-config vulkan.
// WSI display backends are enabled automatically based on what dev
// headers are installed on the build machine at compile time.

#ifndef CVulkanLinux_shim_h
#define CVulkanLinux_shim_h

#if __has_include(<wayland-client.h>)
    #define VK_USE_PLATFORM_WAYLAND_KHR 1
#endif
#if __has_include(<xcb/xcb.h>)
    #define VK_USE_PLATFORM_XCB_KHR 1
#endif
#if __has_include(<X11/Xlib.h>)
    #define VK_USE_PLATFORM_XLIB_KHR 1
#endif

#include <vulkan/vulkan.h>

#endif /* CVulkanLinux_shim_h */
