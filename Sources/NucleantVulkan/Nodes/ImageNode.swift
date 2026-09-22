//
//  ImageNode.swift
//  NucleantVulkan
//
//  A node that is a plain sampled image, filled by copying a region out of
//  another node's image. It draws nothing itself: a host that rasterizes
//  many small pieces of UI through one shared canvas node gives each piece
//  one of these, and every piece gets a composited slot of its own —
//  updated only when it changes, moved for free — without a canvas each
//  (a ThorVG wg canvas costs tens of milliseconds to make; this image,
//  microseconds).
//
//  The copy is recorded by `update`, into the frame's own command buffer.
//  The engine updates nodes in list order, so the host lists the source
//  before the images copying out of it: the source's own update has then
//  drawn it, waited for its writer (`waitForExternalCompletion`) and left
//  it in `ImageCopy.sourceLayout` by the time the copy reads it, and the
//  copy puts it back in that layout — the source node's own layout
//  tracking stays true. Like `OGLShaderNode`, the node owns its image; the
//  source is borrowed, and a host that drops the source clears the copies
//  that name it first.
//

import Observation
@preconcurrency import CVulkan

/// A region of another image to copy into an `ImageNode`: `width × height`
/// texels from (`sourceX`, `sourceY`) in the source to (`x`, `y`) in the
/// node's image. `sourceLayout` is the layout the source is in when the
/// copy runs, and is restored after it — by default what every node's
/// update leaves its image in for the composite, right for a source node
/// listed (and so updated) before this one in the same frame.
public struct ImageCopy: Sendable {
    public let source:       VkImage
    public let sourceLayout: VkImageLayout
    public let sourceX:      Int
    public let sourceY:      Int
    public let x:            Int
    public let y:            Int
    public let width:        Int
    public let height:       Int

    public init(
        source:       VkImage,
        sourceLayout: VkImageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        sourceX:      Int,
        sourceY:      Int,
        x:            Int,
        y:            Int,
        width:        Int,
        height:       Int
    ) {
        self.source       = source
        self.sourceLayout = sourceLayout
        self.sourceX      = sourceX
        self.sourceY      = sourceY
        self.x            = x
        self.y            = y
        self.width        = width
        self.height       = height
    }
}

/// Only what the container observes (`dirty`, the compute trio) is
/// tracked. The rest is read on every pass and frame — and on a generic
/// class a tracked access instantiates its key path each time, demangling
/// included, which cost more than the whole lookup it sat in.
@Observable
public final class ImageNode<ContainerNode: RenderContainerNode>: VulkanRenderNode, @unchecked Sendable {

    public typealias Engine = VulkanRenderEngine<ContainerNode>

    @ObservationIgnored public var width:  UInt32
    @ObservationIgnored public var height: UInt32

    @ObservationIgnored public var image:     VkImage
    @ObservationIgnored public var imageView: VkImageView
    /// The allocation backing `image` — carried for whoever tears the node
    /// down, same contract as `OGLShaderNode.memory`.
    @ObservationIgnored public var memory:    VkDeviceMemory?

    /// The copy to record at the next update; cleared once it is. Until the
    /// first copy has been recorded the node is unpublished — the engine
    /// keeps an image nothing has been copied into out of the composite.
    @ObservationIgnored public var pendingCopy: ImageCopy?

    public var dirty: Bool = true

    /// `VulkanRenderNode`'s post-process seam. The image is a copy target,
    /// not a storage image; no compute pass is installed over it.
    public var computePipeline:      VkPipeline?
    public var computeLayout:        VkPipelineLayout?
    public var computeDescriptorSet: VkDescriptorSet?
    public let storageCapable = false

    /// Where the image really is: UNDEFINED until the first copy, then what
    /// the composite samples in.
    @ObservationIgnored var currentLayout: VkImageLayout = VK_IMAGE_LAYOUT_UNDEFINED

    /// `image` must carry `TRANSFER_DST | SAMPLED` usage and start in
    /// UNDEFINED; the first copy's barrier takes it from there.
    public init(
        width:     UInt32,
        height:    UInt32,
        image:     VkImage,
        imageView: VkImageView,
        memory:    VkDeviceMemory? = nil
    ) {
        self.width     = width
        self.height    = height
        self.image     = image
        self.imageView = imageView
        self.memory    = memory
    }
}

extension ImageNode {
    /// Record the pending copy: the source to TRANSFER_SRC and back, this
    /// image to TRANSFER_DST and on to what the composite samples — ordered
    /// against a composite in flight that may still be sampling the old
    /// content — and the copy between them. Nothing pending, nothing
    /// recorded.
    public func update(_ engine: Engine, slot: ContainerNode, cmd: VkCommandBuffer) {
        guard slot.needsRender, let copy = pendingCopy else { return }
        pendingCopy = nil

        let transfer = VK_PIPELINE_STAGE_TRANSFER_BIT
        // The source was written by whatever drew it — outside this queue
        // for an externally-backed canvas — and is read by whoever samples
        // it: every access, every stage, both ways.
        let any = VkAccessFlags(VK_ACCESS_MEMORY_WRITE_BIT.rawValue) | VkAccessFlags(VK_ACCESS_MEMORY_READ_BIT.rawValue)
        engineImageBarrier(
            cmd,
            image:     copy.source,
            srcLayout: copy.sourceLayout,
            srcAccess: any,
            srcStage:  VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
            dstLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
            dstStage:  transfer
        )
        let fresh = currentLayout == VK_IMAGE_LAYOUT_UNDEFINED
        engineImageBarrier(
            cmd,
            image:     image,
            srcLayout: currentLayout,
            srcAccess: fresh ? 0 : VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
            srcStage:  fresh ? VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT : VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            dstLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            dstAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
            dstStage:  transfer
        )
        let layer = VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            mipLevel: 0, baseArrayLayer: 0, layerCount: 1
        )
        var region = VkImageCopy(
            srcSubresource: layer,
            srcOffset:      VkOffset3D(x: Int32(copy.sourceX), y: Int32(copy.sourceY), z: 0),
            dstSubresource: layer,
            dstOffset:      VkOffset3D(x: Int32(copy.x), y: Int32(copy.y), z: 0),
            extent:         VkExtent3D(width: UInt32(copy.width), height: UInt32(copy.height), depth: 1)
        )
        vkCmdCopyImage(
            cmd,
            copy.source, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            image,       VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1, &region
        )
        engineImageBarrier(
            cmd,
            image:     image,
            srcLayout: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_WRITE_BIT.rawValue),
            srcStage:  transfer,
            dstLayout: VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            dstAccess: VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue),
            dstStage:  VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        )
        engineImageBarrier(
            cmd,
            image:     copy.source,
            srcLayout: VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            srcAccess: VkAccessFlags(VK_ACCESS_TRANSFER_READ_BIT.rawValue),
            srcStage:  transfer,
            dstLayout: copy.sourceLayout,
            dstAccess: any,
            dstStage:  VK_PIPELINE_STAGE_ALL_COMMANDS_BIT
        )
        currentLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        // Sampleable from this command buffer on: the composite that
        // follows in the same frame sees the copy.
        engine.readable.insert(slot.id)
    }

    /// Free the image, view and memory this node owns. Drains the device
    /// first: no in-flight frame may still sample the image.
    public func destroyResources(_ engine: Engine) {
        vkDeviceWaitIdle(engine.device)
        vkDestroyImageView(engine.device, imageView, nil)
        vkDestroyImage(engine.device, image, nil)
        if let memory {
            vkFreeMemory(engine.device, memory, nil)
        }
    }
}
