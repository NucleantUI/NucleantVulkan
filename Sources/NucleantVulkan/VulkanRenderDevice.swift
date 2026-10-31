//
//  VulkanRenderDevice.swift
//  NucleantVulkan
//
//  The GPU half of the engine: instance → physical device → device → queue
//  → pools. Nothing here needs a window — a `VulkanRenderEngine` is one
//  window's surface, swapchain and composite pass, presenting through one of
//  these, and any number of engines can present through the same one.
//

import VulkanCore
import CVulkan

// @unchecked Sendable: every handle is an immutable `let` set once at init,
// and everything that drives the device runs on main — the same contract
// `WgpuContext.shared` is shared under.
public final class VulkanRenderDevice: VulkanContext, @unchecked Sendable {

    public let instance:         VkInstance
    public let physicalDevice:   VkPhysicalDevice
    public let device:           VkDevice
    public let queueFamilyIndex: UInt32
    public let graphicsQueue:    VkQueue
    public let commandPool:      VkCommandPool
    public let descriptorPool:   VkDescriptorPool

    /// Frames in flight for resources allocated against the device itself.
    /// Each engine keeps its own count for its own frames.
    public let imageCount: Int = 2

    /// Makes the device on the first GPU with a queue family that does
    /// graphics and compute — and, when `surface` is given, presents to it.
    /// Without one, presenting is checked per window instead
    /// (`canPresent(to:)`), when its engine is made.
    ///
    /// Owns `instance` from here on: it is destroyed with the device.
    public init(instance: VkInstance, presentingTo surface: VkSurfaceKHR? = nil) throws {
        self.instance = instance

        // --- Physical device --------------------------------------------------
        var gpuCount: UInt32 = 0
        vkEnumeratePhysicalDevices(instance, &gpuCount, nil)
        guard gpuCount > 0 else { throw VulkanEngineError.noPhysicalDevice }
        var gpus = [VkPhysicalDevice?](repeating: nil, count: Int(gpuCount))
        vkEnumeratePhysicalDevices(instance, &gpuCount, &gpus)
        guard let gpu = gpus.compactMap({ $0 }).first else {
            throw VulkanEngineError.noPhysicalDevice
        }
        self.physicalDevice = gpu

        // --- Queue family: graphics + compute (+ present) --------------------
        var familyCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, nil)
        var families = [VkQueueFamilyProperties](
            repeating: VkQueueFamilyProperties(),
            count: Int(familyCount)
        )
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, &families)
        let needed = VkQueueFlags(VK_QUEUE_GRAPHICS_BIT.rawValue | VK_QUEUE_COMPUTE_BIT.rawValue)
        var pickedFamily: UInt32?
        for (i, family) in families.enumerated() where (family.queueFlags & needed) == needed {
            if let surface {
                var presentable: VkBool32 = VK_FALSE
                vkGetPhysicalDeviceSurfaceSupportKHR(gpu, UInt32(i), surface, &presentable)
                guard presentable == VK_TRUE else { continue }
            }
            pickedFamily = UInt32(i)
            break
        }
        guard let familyIndex = pickedFamily else { throw VulkanEngineError.noPresentQueue }
        self.queueFamilyIndex = familyIndex

        // --- Device + queue ----------------------------------------------------
        let availableDeviceExts = enumerateDeviceExtensions(gpu)
        var deviceExtensions = ["VK_KHR_swapchain"]
        if availableDeviceExts.contains("VK_KHR_portability_subset") {
            deviceExtensions.append("VK_KHR_portability_subset")
        }
        if availableDeviceExts.contains("VK_EXT_metal_objects") {
            deviceExtensions.append("VK_EXT_metal_objects")
        }
        // Linux/Android ThorVG zero-copy: import wgpu-native's exported memory
        // fd (VK_KHR_external_memory_fd) as a VkImage on *this* device — the
        // Linux/Vulkan mirror of VK_EXT_metal_objects above. Both device
        // extensions are the cross-platform half of VK_KHR_external_memory,
        // already core since Vulkan 1.1.
        if availableDeviceExts.contains("VK_KHR_external_memory_fd") {
            deviceExtensions.append("VK_KHR_external_memory_fd")
        }
        // Windows' half of the same handoff: there wgpu-native exports the
        // memory as an NT handle (VK_KHR_external_memory_win32) instead.
        if availableDeviceExts.contains("VK_KHR_external_memory_win32") {
            deviceExtensions.append("VK_KHR_external_memory_win32")
        }
        #if os(Android) && NUCLEANT_ANDROID_USE_AHARDWAREBUFFER
        // Android ThorVG zero-copy, opt-in build only (see
        // ANDROID_USE_AHARDWAREBUFFER in Package.swift): the same idea one
        // handle type over, for devices/emulators that support this instead
        // of (or in addition to) VK_KHR_external_memory_fd.
        // VK_KHR_sampler_ycbcr_conversion and VK_EXT_queue_family_foreign are
        // its documented dependencies.
        for ext in [
            "VK_ANDROID_external_memory_android_hardware_buffer",
            "VK_KHR_sampler_ycbcr_conversion",
            "VK_EXT_queue_family_foreign",
        ] where availableDeviceExts.contains(ext) {
            deviceExtensions.append(ext)
        }
        #endif
        var createdDevice: VkDevice?
        var priority: Float = 1.0
        let devResult: VkResult = withUnsafePointer(to: &priority) { priorityPtr in
            var qci = VkDeviceQueueCreateInfo()
            qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            qci.queueFamilyIndex = familyIndex
            qci.queueCount = 1
            qci.pQueuePriorities = priorityPtr
            return withUnsafePointer(to: &qci) { qciPtr in
                withCStringArray(deviceExtensions) { extPtr, extCount in
                    var dci = VkDeviceCreateInfo()
                    dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                    dci.queueCreateInfoCount = 1
                    dci.pQueueCreateInfos = qciPtr
                    dci.enabledExtensionCount = extCount
                    dci.ppEnabledExtensionNames = extPtr
                    return vkCreateDevice(gpu, &dci, nil, &createdDevice)
                }
            }
        }
        guard devResult == VK_SUCCESS, let device = createdDevice else {
            throw VulkanEngineError.device(devResult.rawValue)
        }
        self.device = device

        var queue: VkQueue?
        vkGetDeviceQueue(device, familyIndex, 0, &queue)
        guard let queue else { throw VulkanEngineError.noPresentQueue }
        self.graphicsQueue = queue

        // --- Command pool -------------------------------------------------------
        var createdPool: VkCommandPool?
        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
        poolInfo.queueFamilyIndex = familyIndex
        guard vkCreateCommandPool(device, &poolInfo, nil, &createdPool) == VK_SUCCESS,
              let pool = createdPool else {
            throw VulkanEngineError.commandPool
        }
        self.commandPool = pool

        // --- Descriptor pool ------------------------------------------------------
        self.descriptorPool = try makeDeviceDescriptorPool(device: device, maxSets: 256)
    }

    deinit {
        // The last engine on the device is gone by now — nothing of any
        // window's is left to wait for but what the device ran itself.
        vkDeviceWaitIdle(device)
        vkDestroyDescriptorPool(device, descriptorPool, nil)
        vkDestroyCommandPool(device, commandPool, nil)
        vkDestroyDevice(device, nil)
        vkDestroyInstance(instance, nil)
    }

    /// Whether the device's queue can present to `surface` — asked of every
    /// window's surface, since the queue family was picked without it.
    public func canPresent(to surface: VkSurfaceKHR) -> Bool {
        var presentable: VkBool32 = VK_FALSE
        vkGetPhysicalDeviceSurfaceSupportKHR(physicalDevice, queueFamilyIndex, surface, &presentable)
        return presentable == VK_TRUE
    }
}


// MARK: - Helpers

private func enumerateDeviceExtensions(_ gpu: VkPhysicalDevice) -> Set<String> {
    var count: UInt32 = 0
    vkEnumerateDeviceExtensionProperties(gpu, nil, &count, nil)
    guard count > 0 else { return [] }
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    vkEnumerateDeviceExtensionProperties(gpu, nil, &count, &props)
    return Set(props.map(extensionName))
}

private func makeDeviceDescriptorPool(device: VkDevice, maxSets: Int) throws -> VkDescriptorPool {
    let n = UInt32(maxSets)
    let sizes = [
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,          descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,         descriptorCount: n),
        VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,         descriptorCount: n),
    ]
    var pool: VkDescriptorPool?
    let result = sizes.withUnsafeBufferPointer { buf -> VkResult in
        var info = VkDescriptorPoolCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        info.flags = VkDescriptorPoolCreateFlags(VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT.rawValue)
        info.maxSets = UInt32(maxSets)
        info.poolSizeCount = UInt32(buf.count)
        info.pPoolSizes = buf.baseAddress
        return vkCreateDescriptorPool(device, &info, nil, &pool)
    }
    guard result == VK_SUCCESS, let pool else { throw VulkanEngineError.descriptorPool }
    return pool
}
