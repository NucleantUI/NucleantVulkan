@Observable
public final class OGLShaderNode: VulkanRenderNode {

    // public struct TextureInput {
    // ^ promoted to an @Observable class: a struct copy freezes the
    //   handles at registration — a live reference lets the owner write
    //   new handles in after a rebuild and this node notices on its own.

    /// A live slot for an extra image the shader samples alongside its
    /// output target (e.g. another node's rendered VkImage). The owner
    /// keeps the instance it registered and writes fresh handles into it
    /// when it rebuilds (resize) — this node observes both fields and
    /// flags itself `dirty` + `descriptorsNeedRebind`. Handles stay
    /// borrowed: whoever created the image keeps owning and freeing it.
    @Observable
    public final class TextureInput {
        public var image:     VkImage
        public var imageView: VkImageView

        public init(image: VkImage, imageView: VkImageView) {
            self.image     = image
            self.imageView = imageView
        }
    }

    public let width:  UInt32
    public let height: UInt32

    public let image:     VkImage
    public let imageView: VkImageView
    /// The allocation backing `image` — carried for whoever tears the
    /// node down, same contract as `ThorShaderNode.memory`.
    public let memory:    VkDeviceMemory?

    public var computePipeline:      VkPipeline?
    public var computeLayout:        VkPipelineLayout?
    public var computeDescriptorSet: VkDescriptorSet?
    public var dirty:                Bool = true

    /// Set when an input changed after the descriptor set was written —
    /// descriptor sets snapshot the bound VkImageView, so a redraw alone
    /// keeps sampling the old image. Whoever builds this node's pipeline
    /// consumes it: re-write the descriptor set behind a drain/fence,
    /// then clear the flag.
    public var descriptorsNeedRebind: Bool = false

    /// True when `image` carries STORAGE usage, so the compute shader may
    /// bind it as its output storage image.
    public let storageCapable: Bool

    /// The image's actual current Vulkan-tracked layout — same
    /// stale-oldLayout contract as `ThorShaderNode.currentLayout`.
    var currentLayout: VkImageLayout

    /// Sampled inputs for the compute pass, in binding order. Whoever
    /// builds the node's pipeline/descriptor set consumes these.
    public private(set) var textureInputs: [TextureInput] = []

    public init(
        width:                UInt32,
        height:               UInt32,
        image:                VkImage,
        imageView:            VkImageView,
        memory:               VkDeviceMemory?   = nil,
        storageCapable:       Bool              = true,
        computePipeline:      VkPipeline?       = nil,
        computeLayout:        VkPipelineLayout? = nil,
        computeDescriptorSet: VkDescriptorSet?  = nil
    ) {
        self.width                = width
        self.height               = height
        self.image                = image
        self.imageView            = imageView
        self.memory               = memory
        self.storageCapable       = storageCapable
        // A shader-only image starts in GENERAL (set by its creator) —
        // there is no color-attachment draw phase ahead of the compute
        // pass that would justify COLOR_ATTACHMENT_OPTIMAL.
        self.currentLayout        = VK_IMAGE_LAYOUT_GENERAL
        self.computePipeline      = computePipeline
        self.computeLayout        = computeLayout
        self.computeDescriptorSet = computeDescriptorSet
        observeInputs()
    }

    public func register(textureInput: TextureInput) {
        textureInputs.append(textureInput)
        dirty = true
    }

    /// Convenience wrap — returns the created slot so the caller can hold
    /// on and write new handles into it later; discard the result for
    /// fire-and-forget static inputs.
    @discardableResult
    public func register(image: VkImage, imageView: VkImageView) -> TextureInput {
        let input = TextureInput(image: image, imageView: imageView)
        register(textureInput: input)
        return input
    }

    /// Track in-place mutation of every registered input — and the input
    /// list itself, so a fresh registration re-arms coverage over it. One
    /// registration fires once, so `onChange` re-arms after flagging.
    /// Weak `self` on both closures: each input's registrar holds the
    /// onChange until it fires, so a strong capture would cycle this node
    /// with its own inputs.
    private func observeInputs() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            for input in self.textureInputs {
                _ = input.image
                _ = input.imageView
            }
        } onChange: { [weak self] in
            guard let self else { return }
            self.descriptorsNeedRebind = true
            self.dirty = true
            self.observeInputs()
        }
    }
}
