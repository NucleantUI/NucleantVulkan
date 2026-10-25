//
//  VulkanRenderEngine+Windows.swift
//  NucleantVulkan
//
//  Windows entry point: the engine on a Win32 window. The Windows counterpart
//  of `init(metalLayer:)` / `init(waylandDisplay:…)` / `init(androidWindow:…)`
//  — it makes the VkInstance with VK_KHR_win32_surface and the VkSurfaceKHR
//  for the window, then hands both to the shared designated init, which is the
//  same Vulkan code every platform runs.
//
//  The loader is the Khronos one (vulkan-1.dll) the release's artifact bundle
//  puts next to the app, as on Linux; the driver (ICD) is the machine's, found
//  through the registry the way every Vulkan app on Windows finds it.
//
#if os(Windows)
import CVulkan
import WinSDK

extension VulkanRenderEngine {

    /// - Parameters:
    ///   - win32Instance: the module that owns the window class
    ///     (`GetModuleHandleW(nil)` for the app's own).
    ///   - win32Window: the window to present into.
    ///   - getExtent: the window's client area in pixels. Win32 surfaces report
    ///     it themselves (`currentExtent`), so this is only what the engine
    ///     compares against to notice a resize, as on Linux.
    public convenience init(
        win32Instance: HINSTANCE,
        win32Window: HWND,
        getExtent: @escaping () -> VkExtent2D
    ) throws {
        let instanceExtensions = ["VK_KHR_surface", "VK_KHR_win32_surface"]

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withWindowsCStringArray(instanceExtensions) { extPtr, extCount in
                var ci = VkInstanceCreateInfo()
                ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                ci.pApplicationInfo = appPtr
                ci.enabledExtensionCount = extCount
                ci.ppEnabledExtensionNames = extPtr
                return vkCreateInstance(&ci, nil, &createdInstance)
            }
        }
        guard instResult == VK_SUCCESS, let instance = createdInstance else {
            throw VulkanEngineError.instance(instResult.rawValue)
        }

        var createdSurface: VkSurfaceKHR?
        var surfaceInfo = VkWin32SurfaceCreateInfoKHR()
        surfaceInfo.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR
        surfaceInfo.hinstance = win32Instance
        surfaceInfo.hwnd = win32Window
        let surfResult = vkCreateWin32SurfaceKHR(instance, &surfaceInfo, nil, &createdSurface)
        guard surfResult == VK_SUCCESS, let surface = createdSurface else {
            vkDestroyInstance(instance, nil)
            throw VulkanEngineError.surface(surfResult.rawValue)
        }

        try self.init(instance: instance, surface: surface, getExtent: getExtent)
    }
}

/// Call `body` with a C array of NULL-terminated C strings, valid for the call.
private func withWindowsCStringArray<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, UInt32) -> R
) -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>?]) -> R {
        if index == strings.count {
            return acc.withUnsafeBufferPointer { buf in
                body(buf.baseAddress, UInt32(strings.count))
            }
        }
        return strings[index].withCString { cString in
            recurse(index + 1, acc + [cString])
        }
    }
    return recurse(0, [])
}
#endif
