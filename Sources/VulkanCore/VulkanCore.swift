//
//  VulkanCore.swift
//  VulkanCore
//
//  Headless Vulkan bootstrap (instance / physical device / device / queue /
//  command pool / descriptor pool) that conforms to `VulkanContext`, so the
//  compute (Tutorial 28) and indirect (Tutorial 27) ports have a real device to
//  run on. No swapchain is created — compute texture generation and indirect
//  buffer authoring are offscreen work, so this stays window-system agnostic.
//
//  Shader boundary: this type creates NO shader modules and stores NO shaders.
//  `SulphurShader` compiles GLSL→SPIR-V and injects the words into the pipeline
//  classes (see ComputePipeline.swift). VulkanCore only owns GPU plumbing.
//

import CVulkan

@inline(__always)
private func vkMakeApiVersion(_ variant: UInt32, _ major: UInt32,
                              _ minor: UInt32, _ patch: UInt32) -> UInt32 {
    (variant << 29) | (major << 22) | (minor << 12) | patch
}

/// Call `body` with a C array of the given strings (NULL-terminated C strings),
/// valid only for the duration of the call.
private func withCStringArray<R>(_ strings: [String],
                                 _ body: (UnsafePointer<UnsafePointer<CChar>?>?, UInt32) -> R) -> R {
    func recurse(_ index: Int, _ acc: [UnsafePointer<CChar>?]) -> R {
        if index == strings.count {
            return acc.withUnsafeBufferPointer { buf in
                body(buf.baseAddress, UInt32(strings.count))
            }
        }
        return strings[index].withCString { c in
            recurse(index + 1, acc + [c])
        }
    }
    return recurse(0, [])
}

public enum VulkanBootstrapError: Error {
    case instance(Int32)
    case noPhysicalDevice
    case noComputeQueue
    case device(Int32)
    case commandPool
    case descriptorPool
    case image
    case memory
}

/// Minimal headless Vulkan context for offscreen compute / indirect work.
public final class VulkanCore: VulkanContext {

    public let instance: VkInstance
    public let physicalDevice: VkPhysicalDevice
    public let device: VkDevice
    public let computeQueue: VkQueue
    public let queueFamilyIndex: UInt32
    public let commandPool: VkCommandPool
    public let descriptorPool: VkDescriptorPool
    public let imageCount: Int

    /// - Parameter imageCount: frames-in-flight; descriptor sets / uniform
    ///   buffers are allocated one per image, matching the tutorials.
    public init(imageCount: Int = 2) throws {
        self.imageCount = imageCount

        // --- Instance ------------------------------------------------------
        // Enable portability_enumeration only if it's actually present — when
        // MoltenVK is linked directly (no Vulkan loader) it usually isn't, and
        // requesting it unconditionally fails vkCreateInstance.
        let availableInstanceExts = VulkanCore.instanceExtensionNames()
        var instanceExtensions = [String]()
        if availableInstanceExts.contains("VK_KHR_get_physical_device_properties2") {
            instanceExtensions.append("VK_KHR_get_physical_device_properties2")
        }
        var instanceFlags: VkInstanceCreateFlags = 0
        if availableInstanceExts.contains("VK_KHR_portability_enumeration") {
            instanceExtensions.append("VK_KHR_portability_enumeration")
            instanceFlags = VkInstanceCreateFlags(0x00000001) // ENUMERATE_PORTABILITY_BIT_KHR
        }

        var createdInstance: VkInstance?
        var appInfo = VkApplicationInfo()
        appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
        appInfo.apiVersion = vkMakeApiVersion(0, 1, 2, 0)
        let instResult: VkResult = withUnsafePointer(to: &appInfo) { appPtr in
            withCStringArray(instanceExtensions) { extPtr, extCount in
                var ci = VkInstanceCreateInfo()
                ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                ci.flags = instanceFlags
                ci.pApplicationInfo = appPtr
                ci.enabledExtensionCount = extCount
                ci.ppEnabledExtensionNames = extPtr
                return vkCreateInstance(&ci, nil, &createdInstance)
            }
        }
        guard instResult == VK_SUCCESS, let instance = createdInstance else {
            throw VulkanBootstrapError.instance(instResult.rawValue)
        }
        self.instance = instance

        // --- Physical device -----------------------------------------------
        var gpuCount: UInt32 = 0
        vkEnumeratePhysicalDevices(instance, &gpuCount, nil)
        guard gpuCount > 0 else { throw VulkanBootstrapError.noPhysicalDevice }
        var gpus = [VkPhysicalDevice?](repeating: nil, count: Int(gpuCount))
        vkEnumeratePhysicalDevices(instance, &gpuCount, &gpus)
        guard let gpu = gpus.compactMap({ $0 }).first else {
            throw VulkanBootstrapError.noPhysicalDevice
        }
        self.physicalDevice = gpu

        // --- Compute queue family ------------------------------------------
        var familyCount: UInt32 = 0
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, nil)
        var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(),
                                                 count: Int(familyCount))
        vkGetPhysicalDeviceQueueFamilyProperties(gpu, &familyCount, &families)
        let computeBit = VkQueueFlags(VK_QUEUE_COMPUTE_BIT.rawValue)
        guard let familyIndex = families.firstIndex(where: { ($0.queueFlags & computeBit) != 0 }) else {
            throw VulkanBootstrapError.noComputeQueue
        }
        self.queueFamilyIndex = UInt32(familyIndex)

        // --- Logical device + queue ----------------------------------------
        // portability_subset must be enabled if present, but is absent on a
        // direct-MoltenVK link — enable it conditionally.
        let availableDeviceExts = VulkanCore.deviceExtensionNames(gpu)
        var deviceExtensions = [String]()
        if availableDeviceExts.contains("VK_KHR_portability_subset") {
            deviceExtensions.append("VK_KHR_portability_subset")
        }
        var createdDevice: VkDevice?
        var priority: Float = 1.0
        let devResult: VkResult = withUnsafePointer(to: &priority) { priorityPtr in
            var qci = VkDeviceQueueCreateInfo()
            qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            qci.queueFamilyIndex = UInt32(familyIndex)
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
            throw VulkanBootstrapError.device(devResult.rawValue)
        }
        self.device = device

        var queue: VkQueue?
        vkGetDeviceQueue(device, UInt32(familyIndex), 0, &queue)
        guard let queue else { throw VulkanBootstrapError.noComputeQueue }
        self.computeQueue = queue

        // --- Command pool ---------------------------------------------------
        var createdPool: VkCommandPool?
        var poolInfo = VkCommandPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
        poolInfo.flags = VkCommandPoolCreateFlags(VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue)
        poolInfo.queueFamilyIndex = UInt32(familyIndex)
        guard vkCreateCommandPool(device, &poolInfo, nil, &createdPool) == VK_SUCCESS,
              let pool = createdPool else {
            throw VulkanBootstrapError.commandPool
        }
        self.commandPool = pool

        // --- Descriptor pool ------------------------------------------------
        self.descriptorPool = try VulkanCore.makeDescriptorPool(device: device,
                                                                maxSets: imageCount * 4)
    }

    deinit {
        vkDestroyDescriptorPool(device, descriptorPool, nil)
        vkDestroyCommandPool(device, commandPool, nil)
        vkDestroyDevice(device, nil)
        vkDestroyInstance(instance, nil)
    }

    // MARK: Extension discovery

    /// Names of available instance-level extensions.
    static func instanceExtensionNames() -> Set<String> {
        var count: UInt32 = 0
        vkEnumerateInstanceExtensionProperties(nil, &count, nil)
        guard count > 0 else { return [] }
        var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
        vkEnumerateInstanceExtensionProperties(nil, &count, &props)
        return Set(props.map(extensionName))
    }

    /// Names of available extensions for a physical device.
    static func deviceExtensionNames(_ gpu: VkPhysicalDevice) -> Set<String> {
        var count: UInt32 = 0
        vkEnumerateDeviceExtensionProperties(gpu, nil, &count, nil)
        guard count > 0 else { return [] }
        var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
        vkEnumerateDeviceExtensionProperties(gpu, nil, &count, &props)
        return Set(props.map(extensionName))
    }

    private static func extensionName(_ prop: VkExtensionProperties) -> String {
        var name = prop.extensionName
        return withUnsafeBytes(of: &name) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    // MARK: Descriptor pool

    /// Pool sized for the storage-image / uniform / SSBO / sampler descriptors
    /// the compute + indirect ports allocate.
    static func makeDescriptorPool(device: VkDevice, maxSets: Int) throws -> VkDescriptorPool {
        func size(_ type: VkDescriptorType, _ count: UInt32) -> VkDescriptorPoolSize {
            VkDescriptorPoolSize(type: type, descriptorCount: count)
        }
        let n = UInt32(maxSets)
        let sizes = [
            size(VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, n),
            size(VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, n),
            size(VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, n),
            size(VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, n),
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
        guard result == VK_SUCCESS, let pool else { throw VulkanBootstrapError.descriptorPool }
        return pool
    }

    // MARK: Per-image uniform buffers (port of CreateUniformBuffers)

    public func createUniformBuffers(size: Int) -> [BufferAndMemory] {
        let usage = VkBufferUsageFlags(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT.rawValue)
        return (0..<imageCount).map { _ in createBuffer(size: size, usage: usage) }
    }

    // MARK: One-time command submission

    /// Allocate a transient command buffer, record `body`, submit to the compute
    /// queue, and block until it finishes. Used for layout transitions, clears,
    /// and one-shot dispatches.
    public func withOneTimeCommands(_ body: (VkCommandBuffer) -> Void) {
        var cmd: VkCommandBuffer?
        var alloc = VkCommandBufferAllocateInfo()
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        alloc.commandPool = commandPool
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        alloc.commandBufferCount = 1
        vkAllocateCommandBuffers(device, &alloc, &cmd)
        guard let cmd else { return }

        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        begin.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue)
        vkBeginCommandBuffer(cmd, &begin)

        body(cmd)

        vkEndCommandBuffer(cmd)

        var cmdOpt: VkCommandBuffer? = cmd
        withUnsafePointer(to: &cmdOpt) { cmdPtr in
            var submit = VkSubmitInfo()
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
            submit.commandBufferCount = 1
            submit.pCommandBuffers = cmdPtr
            vkQueueSubmit(computeQueue, 1, &submit, nil)
        }
        vkQueueWaitIdle(computeQueue)
        vkFreeCommandBuffers(device, commandPool, 1, &cmdOpt)
    }

    // MARK: Host readback

    /// Copy an RGBA8 storage image back to host memory. The image is read from
    /// `VK_IMAGE_LAYOUT_GENERAL`; `withOneTimeCommands` fully syncs before the
    /// returned bytes are mapped. Returns `width*height*4` bytes, row-major,
    /// channel order R,G,B,A. Intended for tests / debugging, not the hot path.
    public func readbackRGBA8(_ image: StorageImage) -> [UInt8] {
        let byteCount = image.width * image.height * 4
        let staging = createBuffer(
            size: byteCount,
            usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue))
        defer { staging.destroy(device: device) }

        withOneTimeCommands { cmd in
            var region = VkBufferImageCopy()
            region.imageSubresource = VkImageSubresourceLayers(
                aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
            region.imageExtent = VkExtent3D(width: UInt32(image.width),
                                            height: UInt32(image.height), depth: 1)
            vkCmdCopyImageToBuffer(cmd, image.image, VK_IMAGE_LAYOUT_GENERAL,
                                   staging.buffer, 1, &region)
        }

        var out = [UInt8](repeating: 0, count: byteCount)
        var mapped: UnsafeMutableRawPointer?
        vkMapMemory(device, staging.memory, 0, VkDeviceSize(byteCount), 0, &mapped)
        if let mapped {
            out.withUnsafeMutableBytes { dst in
                dst.baseAddress?.copyMemory(from: mapped, byteCount: byteCount)
            }
        }
        vkUnmapMemory(device, staging.memory)
        return out
    }

    // MARK: Storage image (port of CreateTexture for the compute output)

    /// Create the storage image the compute shader writes and the FS quad
    /// samples. Usage covers compute write, fragment sample, and host readback.
    /// The image is left in `VK_IMAGE_LAYOUT_GENERAL`.
    public func createStorageImage(width: Int, height: Int,
                                   format: VkFormat = VK_FORMAT_R8G8B8A8_UNORM) throws -> StorageImage {
        var img = StorageImage()
        img.width = width
        img.height = height

        var imageInfo = VkImageCreateInfo()
        imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        imageInfo.imageType = VK_IMAGE_TYPE_2D
        imageInfo.format = format
        imageInfo.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        imageInfo.mipLevels = 1
        imageInfo.arrayLayers = 1
        imageInfo.samples = VK_SAMPLE_COUNT_1_BIT
        imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL
        imageInfo.usage = VkImageUsageFlags(
            VK_IMAGE_USAGE_STORAGE_BIT.rawValue |
            VK_IMAGE_USAGE_SAMPLED_BIT.rawValue |
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue |
            VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue)
        imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE
        imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        guard vkCreateImage(device, &imageInfo, nil, &img.image) == VK_SUCCESS else {
            throw VulkanBootstrapError.image
        }

        var req = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device, img.image, &req)
        let deviceLocal = VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        var memAlloc = VkMemoryAllocateInfo()
        memAlloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        memAlloc.allocationSize = req.size
        memAlloc.memoryTypeIndex = findMemoryType(typeFilter: req.memoryTypeBits, properties: deviceLocal)
        guard vkAllocateMemory(device, &memAlloc, nil, &img.memory) == VK_SUCCESS else {
            throw VulkanBootstrapError.memory
        }
        vkBindImageMemory(device, img.image, img.memory, 0)

        // View
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = img.image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format = format
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
        vkCreateImageView(device, &viewInfo, nil, &img.view)

        // Sampler (for the later FS-quad sampling path; ignored by storage binding)
        var samplerInfo = VkSamplerCreateInfo()
        samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
        samplerInfo.magFilter = VK_FILTER_LINEAR
        samplerInfo.minFilter = VK_FILTER_LINEAR
        samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        samplerInfo.maxLod = 1.0
        vkCreateSampler(device, &samplerInfo, nil, &img.sampler)

        // UNDEFINED -> GENERAL so compute can write immediately.
        withOneTimeCommands { cmd in
            VulkanCore.imageBarrier(cmd, image: img.image,
                                    from: VK_IMAGE_LAYOUT_UNDEFINED,
                                    to: VK_IMAGE_LAYOUT_GENERAL,
                                    srcStage: VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                    dstStage: VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT)
        }
        return img
    }

    /// Layout-transition barrier for a 2D color image. The Tutorial 28 GENERAL ↔
    /// SHADER_READ_ONLY flips go through here.
    public static func imageBarrier(_ cmd: VkCommandBuffer, image: VkImage?,
                                    from: VkImageLayout, to: VkImageLayout,
                                    srcStage: VkPipelineStageFlagBits,
                                    dstStage: VkPipelineStageFlagBits) {
        var barrier = VkImageMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
        barrier.oldLayout = from
        barrier.newLayout = to
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
        barrier.image = image
        barrier.subresourceRange = VkImageSubresourceRange(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
        barrier.srcAccessMask = VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue)
        barrier.dstAccessMask = VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue)
        vkCmdPipelineBarrier(cmd,
                             VkPipelineStageFlags(srcStage.rawValue),
                             VkPipelineStageFlags(dstStage.rawValue),
                             0, 0, nil, 0, nil, 1, &barrier)
    }
}
