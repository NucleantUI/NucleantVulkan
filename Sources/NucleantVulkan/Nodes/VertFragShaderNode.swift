//
//  VertFragShaderNode.swift
//  NucleantVulkan
//
//  The graphics counterpart of `OGLShaderNode`: an image drawn by a vertex +
//  fragment pipeline instead of written by a compute dispatch. Everything
//  downstream is the same — the image is sampled by the composite pass into
//  the slot's rect — only the way pixels get into it differs: a render pass
//  over the image, one `vkCmdDraw(vertexCount, instanceCount)`, no vertex
//  buffers (the vertex stage works from `gl_VertexIndex` / `gl_InstanceIndex`
//  and whatever descriptors the pipeline binds).
//
//  Like `OGLShaderNode`, the node owns its image and, here, the render pass
//  and framebuffer over it; the pipeline, layout and descriptor set are
//  installed by whoever built them and are theirs to free.
//

import Observation
import VulkanCore
@preconcurrency import CVulkan

@Observable
public final class VertFragShaderNode<ContainerNode: RenderContainerNode>: VulkanRenderNode, @unchecked Sendable {

    public typealias Engine = VulkanRenderEngine<ContainerNode>

    public var width:  UInt32
    public var height: UInt32

    public var image:     VkImage
    public var imageView: VkImageView
    /// The allocation backing `image` — carried for whoever tears the node
    /// down, same contract as `OGLShaderNode.memory`.
    public var memory:    VkDeviceMemory?

    /// The pass this node draws with, and its framebuffer over `image`. The
    /// pass is shared by every node of the same format; the framebuffer is
    /// this node's own.
    public let pass: ColorAttachmentPass
    public private(set) var framebuffer: VkFramebuffer?

    /// The graphics pipeline and what it binds. Installed by the builder;
    /// the node draws nothing until all three are set.
    public var pipeline:       VkPipeline?
    public var pipelineLayout: VkPipelineLayout?
    public var descriptorSet:  VkDescriptorSet?

    /// What one draw covers: `vertexCount` vertices, `instanceCount` times.
    /// Zero instances still runs the pass, which clears the image.
    public var vertexCount:   UInt32
    public var instanceCount: UInt32

    public var dirty: Bool = true

    /// `VulkanRenderNode`'s post-process seam. A colour attachment is not a
    /// storage image, so no compute pass can be installed over this node's
    /// output; these stay nil and `storageCapable` says so.
    public var computePipeline:      VkPipeline?
    public var computeLayout:        VkPipelineLayout?
    public var computeDescriptorSet: VkDescriptorSet?
    public let storageCapable = false

    /// Where the render pass leaves the image; what the composite samples in.
    var currentLayout: VkImageLayout = VK_IMAGE_LAYOUT_UNDEFINED

    /// `image` must carry `COLOR_ATTACHMENT | SAMPLED` usage; no initial
    /// layout transition is needed, the pass starts from UNDEFINED.
    public init(
        width:         UInt32,
        height:        UInt32,
        image:         VkImage,
        imageView:     VkImageView,
        memory:        VkDeviceMemory? = nil,
        pass:          ColorAttachmentPass,
        vertexCount:   UInt32 = 6,
        instanceCount: UInt32 = 1
    ) throws {
        self.width         = width
        self.height        = height
        self.image         = image
        self.imageView     = imageView
        self.memory        = memory
        self.pass          = pass
        self.vertexCount   = vertexCount
        self.instanceCount = instanceCount
        self.framebuffer   = try pass.makeFramebuffer(imageView: imageView, width: Int(width), height: Int(height))
    }
}

extension VertFragShaderNode {
    /// One render pass over the image: clear, draw, and leave it readable for
    /// the composite. The pass's own dependencies order it against the
    /// previous frame's sampling, so there is no barrier to record here.
    /// Without an installed pipeline the node has no content and stays
    /// unpublished, as `OGLShaderNode` does.
    public func update(_ engine: Engine, slot: ContainerNode, cmd: VkCommandBuffer) {
        guard slot.needsRender else { return }
        guard let pipeline, let pipelineLayout, let descriptorSet, let framebuffer else { return }

        pass.begin(cmd, framebuffer: framebuffer, width: Int(width), height: Int(height))
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
        var set: VkDescriptorSet? = descriptorSet
        vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &set, 0, nil)
        vkCmdDraw(cmd, vertexCount, instanceCount, 0, 0)
        vkCmdEndRenderPass(cmd)

        currentLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        engine.readable.insert(slot.id)
    }

    /// Free the framebuffer, image, view and memory this node owns. The
    /// render pass is shared and outlives the node; the pipeline objects are
    /// the builder's.
    public func destroyResources(_ engine: Engine) {
        vkDeviceWaitIdle(engine.device)
        if let framebuffer {
            vkDestroyFramebuffer(engine.device, framebuffer, nil)
            self.framebuffer = nil
        }
        vkDestroyImageView(engine.device, imageView, nil)
        vkDestroyImage(engine.device, image, nil)
        if let memory {
            vkFreeMemory(engine.device, memory, nil)
        }
    }
}
