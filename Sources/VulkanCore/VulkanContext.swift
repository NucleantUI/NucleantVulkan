//
//  VulkanContext.swift
//  VulkanCore
//
//  Minimal context surface the pipeline ports below need from a host renderer.
//  In the C++ reference (ogldev VulkanCore) these come from `OgldevVK::VulkanCore`.
//  Implement this against your own device/swapchain bootstrap.
//

import CVulkan

/// The slice of a Vulkan bootstrap that the compute / indirect ports depend on.
///
/// This intentionally mirrors only what `ComputePipeline` and `IndirectDraw`
/// touch in the C++ tutorials (device, descriptor pool, per-frame image count,
/// a memory-type chooser, and one-shot buffer creation) so the ports stay
/// faithful without dragging in a whole swapchain/queue stack.
public protocol VulkanContext: AnyObject {
    var device: VkDevice { get }
    var physicalDevice: VkPhysicalDevice { get }

    /// Number of swapchain images / frames-in-flight. Descriptor sets and
    /// uniform buffers are allocated one-per-image, exactly like the tutorials.
    var imageCount: Int { get }

    /// A descriptor pool with room for the storage-image / uniform / storage
    /// buffers these pipelines allocate. See `ComputePipeline.makeDescriptorPool`.
    var descriptorPool: VkDescriptorPool { get }
}

public extension VulkanContext {
    /// Pick a memory type index satisfying `typeFilter` and `properties`.
    /// Direct port of the usual `findMemoryType` helper.
    func findMemoryType(typeFilter: UInt32, properties: VkMemoryPropertyFlags) -> UInt32 {
        var memProps = VkPhysicalDeviceMemoryProperties()
        vkGetPhysicalDeviceMemoryProperties(physicalDevice, &memProps)

        let count = Int(memProps.memoryTypeCount)
        withUnsafeBytes(of: &memProps.memoryTypes) { _ in }
        for i in 0..<count {
            let typeOK = (typeFilter & (UInt32(1) << UInt32(i))) != 0
            let memType = withUnsafePointer(to: &memProps.memoryTypes) {
                $0.withMemoryRebound(to: VkMemoryType.self, capacity: count) { $0[i] }
            }
            let propsOK = (memType.propertyFlags & properties) == properties
            if typeOK && propsOK { return UInt32(i) }
        }
        fatalError("VulkanContext.findMemoryType: no suitable memory type")
    }
}

/// A GPU buffer + its backing allocation. Mirrors `OgldevVK::BufferAndMemory`.
public struct BufferAndMemory {
    public var buffer: VkBuffer?
    public var memory: VkDeviceMemory?
    public var size: VkDeviceSize = 0

    public init() {}

    /// Copy `bytes` of `data` into the mapped allocation. Buffer must be
    /// HOST_VISIBLE | HOST_COHERENT (how these helpers allocate it).
    public func update(device: VkDevice, data: UnsafeRawPointer, bytes: Int) {
        guard let memory else { return }
        var mapped: UnsafeMutableRawPointer?
        vkMapMemory(device, memory, 0, VkDeviceSize(bytes), 0, &mapped)
        if let mapped { mapped.copyMemory(from: data, byteCount: bytes) }
        vkUnmapMemory(device, memory)
    }

    public func destroy(device: VkDevice) {
        if let buffer { vkDestroyBuffer(device, buffer, nil) }
        if let memory { vkFreeMemory(device, memory, nil) }
    }
}

public extension VulkanContext {
    /// Create a HOST_VISIBLE|HOST_COHERENT buffer and optionally seed it.
    /// Used for uniforms, SSBOs, and indirect buffers in the ports below.
    func createBuffer(size: Int,
                      usage: VkBufferUsageFlags,
                      seed: UnsafeRawPointer? = nil) -> BufferAndMemory {
        var out = BufferAndMemory()
        out.size = VkDeviceSize(size)

        var bufInfo = VkBufferCreateInfo()
        bufInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
        bufInfo.size = VkDeviceSize(size)
        bufInfo.usage = usage
        bufInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE

        guard vkCreateBuffer(device, &bufInfo, nil, &out.buffer) == VK_SUCCESS else {
            fatalError("vkCreateBuffer failed")
        }

        var req = VkMemoryRequirements()
        vkGetBufferMemoryRequirements(device, out.buffer, &req)

        let hostVisible = VkMemoryPropertyFlags(
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue |
            VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue)

        var alloc = VkMemoryAllocateInfo()
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        alloc.allocationSize = req.size
        alloc.memoryTypeIndex = findMemoryType(typeFilter: req.memoryTypeBits,
                                               properties: hostVisible)

        guard vkAllocateMemory(device, &alloc, nil, &out.memory) == VK_SUCCESS else {
            fatalError("vkAllocateMemory failed")
        }
        vkBindBufferMemory(device, out.buffer, out.memory, 0)

        if let seed { out.update(device: device, data: seed, bytes: size) }
        return out
    }
}
