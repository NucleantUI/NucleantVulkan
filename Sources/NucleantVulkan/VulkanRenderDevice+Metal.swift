//
//  VulkanRenderDevice+Metal.swift
//  NucleantVulkan
//
//  Apple: the instance MoltenVK surfaces are made from, and on macOS the
//  process's one device, made without a window.
//
#if os(macOS) || os(iOS)
import CVulkan

extension VulkanRenderDevice {

    /// The VkInstance a `CAMetalLayer` surface can be made from: the Metal
    /// surface extensions, plus MoltenVK's configuration
    /// (`withMoltenVKSettings`). Apple only reaches Vulkan through
    /// MoltenVK/Metal, so this is the only kind of instance there is here.
    static func makeMetalInstance() throws -> VkInstance {
        let availableInstanceExts = enumerateInstanceExtensions()
        var instanceExtensions = ["VK_KHR_surface", "VK_EXT_metal_surface"]
        if availableInstanceExts.contains("VK_KHR_get_physical_device_properties2") {
            instanceExtensions.append("VK_KHR_get_physical_device_properties2")
        }
        var instanceFlags: VkInstanceCreateFlags = 0
        if availableInstanceExts.contains("VK_KHR_portability_enumeration") {
            instanceExtensions.append("VK_KHR_portability_enumeration")
            instanceFlags = VkInstanceCreateFlags(0x00000001) // ENUMERATE_PORTABILITY_BIT_KHR
        }
        // MoltenVK's per-instance configuration travels through
        // VK_EXT_layer_settings; see `withMoltenVKSettings` for what is set.
        let configurable = availableInstanceExts.contains("VK_EXT_layer_settings")
        if configurable {
            instanceExtensions.append("VK_EXT_layer_settings")
        }

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = (1 << 22) | (2 << 12) // Vulkan 1.2
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withCStringArray(instanceExtensions) { extPtr, extCount in
                Self.withMoltenVKSettings(enabled: configurable) { settingsPtr in
                    var ci = VkInstanceCreateInfo()
                    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                    ci.pNext = settingsPtr
                    ci.flags = instanceFlags
                    ci.pApplicationInfo = appPtr
                    ci.enabledExtensionCount = extCount
                    ci.ppEnabledExtensionNames = extPtr
                    return vkCreateInstance(&ci, nil, &createdInstance)
                }
            }
        }
        guard instResult == VK_SUCCESS, let instance = createdInstance else {
            throw VulkanEngineError.instance(instResult.rawValue)
        }
        return instance
    }

    /// Runs `body` with a `VkLayerSettingsCreateInfoEXT` to chain into the
    /// instance's `pNext` (nil when the extension isn't available).
    ///
    /// One setting: `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS = never`. On GPUs
    /// where MoltenVK would otherwise bind descriptors through Metal 3
    /// argument buffers — Apple silicon, so every iPhone/iPad and M-series
    /// Mac — a sampled image *imported* from an external `MTLTexture`
    /// (the wgpu texture ThorVG draws into, via VK_EXT_metal_objects) is not
    /// made resident for the composite pass and reads back as zero: the
    /// window shows only its clear colour. Discrete resource indexes bind it
    /// correctly, and the engine's descriptor sets are a handful of textures,
    /// so argument buffers bought nothing here anyway. Seen on an M1 iPad
    /// with MoltenVK 1.4.1; Intel Macs and the simulator never take the
    /// Metal 3 path, which is why it went unnoticed.
    private static func withMoltenVKSettings<R>(
        enabled: Bool,
        _ body: (UnsafeRawPointer?) -> R
    ) -> R {
        guard enabled else { return body(nil) }
        var never: Int32 = 0 // MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS_NEVER
        return "MoltenVK".withCString { layerName in
            "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS".withCString { settingName in
                withUnsafePointer(to: &never) { valuePtr in
                    var setting = VkLayerSettingEXT(
                        pLayerName:   layerName,
                        pSettingName: settingName,
                        type:         VK_LAYER_SETTING_TYPE_INT32_EXT,
                        valueCount:   1,
                        pValues:      UnsafeRawPointer(valuePtr)
                    )
                    return withUnsafePointer(to: &setting) { settingPtr in
                        var info = VkLayerSettingsCreateInfoEXT()
                        info.sType        = VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT
                        info.settingCount = 1
                        info.pSettings    = settingPtr
                        return withUnsafePointer(to: &info) { body(UnsafeRawPointer($0)) }
                    }
                }
            }
        }
    }
}

#if os(macOS)
extension VulkanRenderDevice {

    /// Made once, the first time anything asks — a window or not. A failure
    /// is kept too: asking again gets the same error, not a second attempt.
    private static let sharedDevice = Result {
        try VulkanRenderDevice(instance: makeMetalInstance())
    }

    /// The process's device. Every engine made from a `CAMetalLayer`
    /// presents through it, so nodes made on it can be composited into any
    /// window — and it exists before the first window and after the last.
    public static var shared: VulkanRenderDevice {
        get throws { try sharedDevice.get() }
    }
}
#endif
#endif
