// CVulkan Windows shim for the prebuilt libraries — Vulkan-Headers 1.4.334,
// vendored: the same vulkan_core.h as Sources/CVulkan (Apple) and
// Sources/CVulkanLinuxPrebuilt, so every platform compiles against one API
// version, and the Khronos loader of the same version (vulkan-1.dll, with its
// import library) ships in the release's artifact bundle next to the app.
//
// VK_KHR_win32_surface and the Win32 external-memory/semaphore extensions are
// compiled in. Their types are windows.h's own — HWND, HINSTANCE, HANDLE … —
// which Swift sees through its WinSDK module, so a window handle from WinSDK
// passes straight into VkWin32SurfaceCreateInfoKHR. Every machine that builds
// Swift for Windows has the Windows SDK.

#ifndef CVulkanWindowsPrebuilt_shim_h
#define CVulkanWindowsPrebuilt_shim_h

#include <windows.h>

#include "vulkan/vk_platform.h"
#include "vulkan/vulkan_core.h"

#define VK_USE_PLATFORM_WIN32_KHR 1

#include "vulkan/vulkan_win32.h"

#endif /* CVulkanWindowsPrebuilt_shim_h */
