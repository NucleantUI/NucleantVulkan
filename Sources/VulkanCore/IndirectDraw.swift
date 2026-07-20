//
//  IndirectDraw.swift
//  VulkanCore
//
//  Swift port of ogldev Tutorial 27 (Indirect Rendering).
//  Reference:
//    VulkanScienceAcadamy/ogldev/Vulkan/VulkanCore/Source/model.cpp
//      (CreateIndirectBuffer / RecordCommandBufferIndirect)
//    VulkanScienceAcadamy/ogldev/Vulkan/Tutorial27/tutorial27.cpp
//
//  See docs: VulkanScienceAcadamy/docs/27-indirect-rendering.md
//
//  The point of indirect rendering: the per-draw parameters live in a GPU
//  buffer, so one `vkCmdDrawIndirect` issues many draws, and a compute pass
//  (Tutorial 28) can author/cull that buffer. This is the GPU-driven path.
//

import CVulkan

/// Holds a buffer of `VkDrawIndirectCommand` and issues them with one call.
/// Direct port of the indirect-buffer half of `OgldevVK::VkModel`.
public final class IndirectDrawBuffer {

    private let device: VkDevice
    private var buffer = BufferAndMemory()
    public private(set) var drawCount: Int = 0

    /// Build an indirect buffer from explicit draw commands.
    public init(context: VulkanContext, commands: [VkDrawIndirectCommand]) {
        self.device = context.device
        self.drawCount = commands.count

        let usage = VkBufferUsageFlags(
            VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT.rawValue |
            VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue)

        commands.withUnsafeBytes { raw in
            self.buffer = context.createBuffer(size: raw.count,
                                               usage: usage,
                                               seed: raw.baseAddress)
        }
    }

    /// Convenience matching `VkModel::CreateIndirectBuffer`: one draw per
    /// submesh, abusing `firstInstance = submeshIndex` as a free per-draw index
    /// the vertex shader reads as `gl_InstanceIndex` to look up per-mesh data.
    public convenience init(context: VulkanContext, vertexCounts: [UInt32]) {
        let commands = vertexCounts.enumerated().map { (i, count) in
            VkDrawIndirectCommand(vertexCount: count,
                                  instanceCount: 1,
                                  firstVertex: 0,
                                  firstInstance: UInt32(i))
        }
        self.init(context: context, commands: commands)
    }

    deinit { buffer.destroy(device: device) }

    /// The single draw for the whole set. Port of
    /// `VkModel::RecordCommandBufferIndirect`.
    public func record(commandBuffer: VkCommandBuffer) {
        vkCmdDrawIndirect(commandBuffer,
                          buffer.buffer,
                          0,                                              // offset
                          UInt32(drawCount),                              // drawCount
                          UInt32(MemoryLayout<VkDrawIndirectCommand>.stride)) // stride
    }

    /// The buffer handle — pass to `vkCmdDrawIndirectCount`, or bind as a
    /// STORAGE_BUFFER so a compute cull pass can rewrite the draw commands
    /// (see docs/thorvg-multigpu-viewports.md, GPU-driven culling).
    public var handle: VkBuffer? { buffer.buffer }
}

/// Barriers for the compute → indirect handoff described in the docs.
public enum IndirectBarrier {

    /// Insert after a compute pass that *wrote* an indirect buffer and before
    /// the `vkCmdDrawIndirect*` that reads it. This is the buffer analog of the
    /// image barriers Tutorial 28 uses around its compute dispatch.
    public static func computeWriteToIndirectRead(commandBuffer: VkCommandBuffer,
                                                  buffer: VkBuffer) {
        var barrier = VkBufferMemoryBarrier()
        barrier.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
        barrier.srcAccessMask = VkAccessFlags(VK_ACCESS_SHADER_WRITE_BIT.rawValue)
        barrier.dstAccessMask = VkAccessFlags(VK_ACCESS_INDIRECT_COMMAND_READ_BIT.rawValue)
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
        barrier.buffer = buffer
        barrier.offset = 0
        barrier.size = VkDeviceSize(bitPattern: -1) // VK_WHOLE_SIZE

        vkCmdPipelineBarrier(
            commandBuffer,
            VkPipelineStageFlags(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT.rawValue),
            VkPipelineStageFlags(VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT.rawValue),
            0,
            0, nil,
            1, &barrier,
            0, nil)
    }
}
