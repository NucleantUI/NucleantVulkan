//
//  VulkanRenderEngine+Wasm.swift
//  NucleantVulkan
//
//  WebAssembly entry point: the engine on an HTML <canvas>. The wasm
//  counterpart of `init(metalLayer:)` / `init(waylandDisplay:…)` /
//  `init(androidWindow:…)` — it makes the VkInstance with the surface
//  extension this platform has (VK_NUCLEANT_webgpu_surface, see
//  Sources/CVulkanWasm/include/vulkan_webgpu_nucleant.h) and the VkSurfaceKHR
//  for the canvas, then hands both to the shared designated init, which is
//  the same Vulkan code every platform runs.
//
#if os(WASI)
import CVulkan

extension VulkanRenderEngine {

    /// - Parameters:
    ///   - canvasSelector: CSS selector of the `<canvas>` to present into.
    ///   - getSize: the canvas's drawing-buffer size in pixels (its `width` /
    ///     `height` attributes) — plain pixels, as on Android, so the windowing
    ///     layer needs no Vulkan types.
    public convenience init(canvasSelector: String, getSize: @escaping () -> (Int, Int)) throws {
        let instanceExtensions = ["VK_KHR_surface", "VK_NUCLEANT_webgpu_surface"]

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withWasmCStringArray(instanceExtensions) { extPtr, extCount in
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
        let surfResult: VkResult = canvasSelector.withCString { selector in
            var surfaceInfo = VkWebGPUSurfaceCreateInfoNUCLEANT()
            surfaceInfo.sType = VK_STRUCTURE_TYPE_WEBGPU_SURFACE_CREATE_INFO_NUCLEANT
            surfaceInfo.pCanvasSelector = selector
            return vkCreateWebGPUSurfaceNUCLEANT(instance, &surfaceInfo, nil, &createdSurface)
        }
        guard surfResult == VK_SUCCESS, let surface = createdSurface else {
            vkDestroyInstance(instance, nil)
            throw VulkanEngineError.surface(surfResult.rawValue)
        }

        try self.init(instance: instance, surface: surface, getExtent: {
            let (w, h) = getSize()
            return VkExtent2D(width: UInt32(max(w, 0)), height: UInt32(max(h, 0)))
        })
    }
}

/// Call `body` with a C array of NULL-terminated C strings, valid for the call.
private func withWasmCStringArray<R>(
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
