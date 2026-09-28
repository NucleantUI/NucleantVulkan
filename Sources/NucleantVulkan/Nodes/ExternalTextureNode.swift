//
//  ExternalTextureNode.swift
//  NucleantVulkan
//
//  A node whose pixels come from outside the engine, at a time of the
//  producer's choosing — a browser's compositor, a video decoder — rather
//  than from anything the engine draws. The producer hands over a frame
//  (an IOSurface on Apple, or plain CPU pixels as the fallback) and the
//  frame is copied into an image this node owns, there and then.
//
//  "There and then" is the whole design. A producer that renders on its own
//  GPU timeline typically lends its frame only for the duration of a
//  callback and recycles it straight after — CEF's `OnAcceleratedPaint`
//  hands out a pool of two IOSurfaces, alternating every frame, and
//  documents that the surface must not be touched once the callback
//  returns. A composite that sampled the producer's surface directly would
//  read a frame the producer is already rewriting. So the copy is submitted
//  on the engine's own queue and waited for before the write returns
//  (`VulkanRenderEngine.writeExternalTexture`): queue order and the copy's
//  barriers then make every later composite see a whole frame, and every
//  earlier one finish sampling the old frame before it is overwritten.
//
//  Like `ImageNode`, the node draws nothing at frame time; `update` only
//  publishes the image once something has been written into it.
//

import Observation
@preconcurrency import CVulkan

/// Only what the container observes (`dirty`, the compute trio) is tracked —
/// the same split as `ImageNode`, for the same reason.
@Observable
public final class ExternalTextureNode<ContainerNode: RenderContainerNode>: VulkanRenderNode, @unchecked Sendable {

    public typealias Engine = VulkanRenderEngine<ContainerNode>

    @ObservationIgnored public var width:  UInt32
    @ObservationIgnored public var height: UInt32

    @ObservationIgnored public var image:     VkImage
    @ObservationIgnored public var imageView: VkImageView
    @ObservationIgnored public var memory:    VkDeviceMemory?

    public var dirty: Bool = true

    /// `VulkanRenderNode`'s post-process seam — unused: the image is a copy
    /// target, never a storage image.
    public var computePipeline:      VkPipeline?
    public var computeLayout:        VkPipelineLayout?
    public var computeDescriptorSet: VkDescriptorSet?
    public let storageCapable = false

    /// Whether a frame has landed in `image` since it was created. Until one
    /// has, the image holds nothing worth sampling and stays out of the
    /// composite.
    @ObservationIgnored public internal(set) var hasContent = false

    /// Where `image` really is: UNDEFINED until the first write, then what
    /// the composite samples in.
    @ObservationIgnored var currentLayout: VkImageLayout = VK_IMAGE_LAYOUT_UNDEFINED

    /// The write path's own command buffer and fence, made on first use and
    /// reused for every frame after — a producer writes at display rate, and
    /// allocating per write is churn for nothing.
    @ObservationIgnored var writeCommandBuffer: VkCommandBuffer?
    @ObservationIgnored var writeFence: VkFence?

    /// Host-visible buffer the CPU fallback stages pixels through, grown to
    /// the largest frame written so far and kept mapped.
    @ObservationIgnored var stagingBuffer: VkBuffer?
    @ObservationIgnored var stagingMemory: VkDeviceMemory?
    @ObservationIgnored var stagingMapped: UnsafeMutableRawPointer?
    @ObservationIgnored var stagingSize: Int = 0

    #if os(macOS) || os(iOS)
    /// IOSurfaces already imported as VkImages, keyed by surface. A producer
    /// that pools its surfaces (CEF keeps two) presents the same few over and
    /// over; importing once per surface instead of once per frame saves an
    /// image and an allocation every frame. Each entry holds a retain on its
    /// surface, so an address in here always names the surface that was
    /// imported, never a newer one allocated where a freed one stood. Only
    /// the *import* is kept — the surface's pixels are still read inside the
    /// write that hands it over, and nowhere else.
    @ObservationIgnored var importedSurfaces: [ImportedSurface] = []

    struct ImportedSurface {
        let surface: UnsafeMutableRawPointer
        let width:   Int
        let height:  Int
        let image:   VkImage
        let memory:  VkDeviceMemory?
        /// Where the import's image is: PREINITIALIZED until its first copy,
        /// GENERAL after every one.
        var layout:  VkImageLayout
    }

    /// Past this many, the least recently written surface is dropped.
    static var importedSurfaceLimit: Int { 4 }
    #endif

    /// `image` must carry `TRANSFER_DST | SAMPLED` usage and start in
    /// UNDEFINED; the first write's barrier takes it from there.
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

extension ExternalTextureNode {
    /// Nothing to record: writes are submitted when the producer makes them.
    /// Only publishes the image to the composite once one has landed.
    public func update(_ engine: Engine, slot: ContainerNode, cmd: VkCommandBuffer) {
        guard hasContent else { return }
        engine.readable.insert(slot.id)
    }

    /// Free the image, the write path's command buffer, fence and staging
    /// buffer, and every imported surface. Drains the device first: no
    /// in-flight frame may still sample the image.
    public func destroyResources(_ engine: Engine) {
        vkDeviceWaitIdle(engine.device)
        vkDestroyImageView(engine.device, imageView, nil)
        vkDestroyImage(engine.device, image, nil)
        if let memory {
            vkFreeMemory(engine.device, memory, nil)
        }
        releaseWriteResources(engine)
    }

    /// Everything but the image itself — also what a resize keeps: the
    /// command buffer, fence and staging buffer outlive a size change, the
    /// imported surfaces do not need to (a resized producer presents new
    /// ones), so only those are dropped there.
    func releaseWriteResources(_ engine: Engine) {
        if let commandBuffer = writeCommandBuffer {
            var commandBufferOpt: VkCommandBuffer? = commandBuffer
            vkFreeCommandBuffers(engine.device, engine.commandPool, 1, &commandBufferOpt)
            writeCommandBuffer = nil
        }
        if let fence = writeFence {
            vkDestroyFence(engine.device, fence, nil)
            writeFence = nil
        }
        if let stagingMemory {
            vkUnmapMemory(engine.device, stagingMemory)
            vkFreeMemory(engine.device, stagingMemory, nil)
        }
        if let stagingBuffer {
            vkDestroyBuffer(engine.device, stagingBuffer, nil)
        }
        stagingBuffer = nil
        stagingMemory = nil
        stagingMapped = nil
        stagingSize = 0
        #if os(macOS) || os(iOS)
        releaseImportedSurfaces(engine)
        #endif
    }
}
