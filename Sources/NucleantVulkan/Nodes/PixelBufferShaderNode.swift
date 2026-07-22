//
//  PixelBufferShaderNode.swift
//  PyNucleantUI
//
import NucleantVulkan
import VulkanCore
import CVulkan
import Observation

/// A CPU-fed render node: the content is a pixel buffer some CPU-side
/// producer (e.g. the NES PPU) writes each frame, uploaded into the
/// node's VkImage through a persistently-mapped staging buffer — plus
/// the same compute post-shader slot `ThorShaderNode` carries, so a
/// `CanvasShader` (CRT filter, bloom, …) runs on the uploaded pixels
/// before the composite pass samples them.
///
/// `@Observable` for the same reason as the other nodes: the owning
/// `RenderNode` slot tracks `dirty` / the compute trio, so a `write`
/// or a pipeline swap re-renders on its own.
///
/// Threading contract: `write` and the engine's frame loop must share a
/// thread (everything runs on main today). `write` only touches the
/// CPU-side backing store — the copy into the staging slice happens at
/// record time, after the frame fence proved the GPU is done with that
/// slice, so the producer can never scribble over pixels the GPU is
/// still reading.
@Observable
public final class PixelBufferShaderNode: VulkanRenderNode {

    /// Size of `image` — the surface shaders and the composite see.
    /// This is `sourceWidth/Height × scale`.
    public let width:  UInt32
    public let height: UInt32

    /// Content resolution the producer `write`s (e.g. 256×240 for a NES).
    /// With `scale` > 1 the upload path nearest-blits these pixels up
    /// into the scale×-larger `image`, so the producer never pays for
    /// the magnification — a post shader gets real subpixels for free.
    public let sourceWidth:  UInt32
    public let sourceHeight: UInt32
    public let scale:        UInt32

    public let image:     VkImage
    public let imageView: VkImageView
    /// The allocation backing `image` — carried for whoever tears the
    /// node down, same contract as `ThorShaderNode.memory`.
    public let memory:    VkDeviceMemory?

    /// Intermediate upload target at source resolution — the blit source
    /// feeding `image`. Nil at scale 1, where staging copies straight
    /// into `image` exactly as before scaling existed.
    public let uploadImage:  VkImage?
    public let uploadMemory: VkDeviceMemory?
    /// Vulkan-tracked layout of `uploadImage`, same stale-oldLayout
    /// contract as `currentLayout`.
    var uploadLayout: VkImageLayout = VK_IMAGE_LAYOUT_UNDEFINED

    /// Host-visible upload buffer, one slice per frame-in-flight so the
    /// CPU never rewrites bytes an in-flight copy still reads. Mapped
    /// once at creation and unmapped only at teardown.
    public let stagingBuffer: VkBuffer
    public let stagingMemory: VkDeviceMemory
    let stagingPointer:       UnsafeMutableRawPointer
    /// Bytes of one full *source* frame (sourceWidth × sourceHeight × 4,
    /// tightly packed RGBA8) — staging and `write` deal in source pixels.
    public let bytesPerFrame: Int
    let stagingSliceCount:    Int

    public var computePipeline:      VkPipeline?
    public var computeLayout:        VkPipelineLayout?
    public var computeDescriptorSet: VkDescriptorSet?
    public var dirty:                Bool = true

    /// The upload image is engine-owned RGBA8 with STORAGE usage — a
    /// compute post shader may always bind it as its output image.
    public let storageCapable: Bool = true

    /// The image's actual current Vulkan-tracked layout — same
    /// stale-oldLayout contract as `ThorShaderNode.currentLayout`.
    /// Starts UNDEFINED: nothing has ever been uploaded, and the first
    /// upload overwrites every texel, so discarding is fine.
    var currentLayout: VkImageLayout = VK_IMAGE_LAYOUT_UNDEFINED

    /// False until the first `write` — the engine keeps the node out of
    /// the composite until there are real pixels, the same way an
    /// `OGLShaderNode` stays unpublished without a pipeline.
    public private(set) var hasContent: Bool = false

    /// CPU-side backing store the producer writes into. Ignored by
    /// Observation on purpose: a 240p frame is ~61k pixels a frame, and
    /// `dirty` already carries the change signal.
    @ObservationIgnored
    private var pixels: [UInt8]

    init(
        sourceWidth:    UInt32,
        sourceHeight:   UInt32,
        scale:          UInt32,
        image:          VkImage,
        imageView:      VkImageView,
        memory:         VkDeviceMemory?,
        uploadImage:    VkImage?,
        uploadMemory:   VkDeviceMemory?,
        stagingBuffer:  VkBuffer,
        stagingMemory:  VkDeviceMemory,
        stagingPointer: UnsafeMutableRawPointer,
        sliceCount:     Int
    ) {
        self.sourceWidth       = sourceWidth
        self.sourceHeight      = sourceHeight
        self.scale             = max(scale, 1)
        self.width             = sourceWidth  * self.scale
        self.height            = sourceHeight * self.scale
        self.image             = image
        self.imageView         = imageView
        self.memory            = memory
        self.uploadImage       = uploadImage
        self.uploadMemory      = uploadMemory
        self.stagingBuffer     = stagingBuffer
        self.stagingMemory     = stagingMemory
        self.stagingPointer    = stagingPointer
        self.bytesPerFrame     = Int(sourceWidth) * Int(sourceHeight) * 4
        self.stagingSliceCount = max(sliceCount, 1)
        self.pixels            = [UInt8](repeating: 0, count: self.bytesPerFrame)
    }

    /// Hand a full frame of tightly-packed RGBA8 bytes to the node.
    /// Short input fills what it covers; excess bytes are ignored.
    public func write(pixels source: UnsafeRawBufferPointer) {
        guard let base = source.baseAddress, source.count > 0 else { return }
        let count = min(source.count, bytesPerFrame)
        pixels.withUnsafeMutableBytes { destination in
            destination.baseAddress!.copyMemory(from: base, byteCount: count)
        }
        hasContent = true
        dirty = true
    }

    /// Convenience for producers holding pixels as one UInt32 per texel
    /// (little-endian 0xAABBGGRR — i.e. R,G,B,A byte order in memory,
    /// matching the image's R8G8B8A8_UNORM layout).
    public func write(rgba: [UInt32]) {
        rgba.withUnsafeBytes { write(pixels: $0) }
    }

    // MARK: Engine-side upload

    /// Byte offset of a frame slice inside `stagingBuffer`.
    func stagingOffset(of slice: Int) -> Int {
        (slice % stagingSliceCount) * bytesPerFrame
    }

    /// Copy the CPU backing store into a staging slice. Only the engine
    /// calls this, after the slice's frame fence signalled — that fence
    /// is the proof no in-flight copy still reads these bytes.
    func stage(into slice: Int) {
        pixels.withUnsafeBytes { source in
            stagingPointer
                .advanced(by: stagingOffset(of: slice))
                .copyMemory(from: source.baseAddress!, byteCount: bytesPerFrame)
        }
    }
}
