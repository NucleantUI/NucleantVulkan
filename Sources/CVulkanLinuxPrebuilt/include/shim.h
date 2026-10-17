// CVulkan Linux shim for the prebuilt libraries — Vulkan-Headers 1.4.334,
// vendored: the same vulkan_core.h as Sources/CVulkan (Apple), so every
// platform compiles against one API version, with no libvulkan-dev, and the
// Khronos loader of the same version (libvulkan.so) ships in the release's
// artifact bundle next to the app.
//
// Every WSI backend is always compiled in. Its headers need only a few of the
// window systems' types — opaque pointers and integer handles — so they are
// declared here rather than taken from libwayland-dev / libxcb1-dev /
// libx11-dev, which a machine building (or running) the app need not have.
// The declarations are the window systems' own, so they agree with theirs
// wherever both are seen.

#ifndef CVulkanLinuxPrebuilt_shim_h
#define CVulkanLinuxPrebuilt_shim_h

#include <stdint.h>

#include "vulkan/vk_platform.h"
#include "vulkan/vulkan_core.h"

// Wayland (wayland-client.h): opaque.
struct wl_display;
struct wl_surface;

// xcb (xcb/xcb.h, xcb/xproto.h)
typedef struct xcb_connection_t xcb_connection_t;
typedef uint32_t xcb_window_t;
typedef uint32_t xcb_visualid_t;

// Xlib (X11/Xlib.h, X11/X.h)
typedef struct _XDisplay Display;
typedef unsigned long XID;
typedef XID Window;
typedef unsigned long VisualID;

#define VK_USE_PLATFORM_WAYLAND_KHR 1
#define VK_USE_PLATFORM_XCB_KHR 1
#define VK_USE_PLATFORM_XLIB_KHR 1

#include "vulkan/vulkan_wayland.h"
#include "vulkan/vulkan_xcb.h"
#include "vulkan/vulkan_xlib.h"

#endif /* CVulkanLinuxPrebuilt_shim_h */
