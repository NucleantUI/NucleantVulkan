//
//  CompositePipeline.swift
//  NucleantVulkan
//
import VulkanCore
import CVulkan

public final class CompositePipeline {

    private let device:         VkDevice
    private let slotCount:      Int

    private var setLayout:      VkDescriptorSetLayout?
    private var pipelineLayout: VkPipelineLayout?
    private var pipeline:       VkPipeline?
    private var sampler:        VkSampler?

    /// - Parameters:
    ///   - renderPass: the VkRenderPass this pipeline draws into (swapchain subpass)
    ///   - vertSPIRV:  full-screen-quad vertex shader — positions from gl_VertexIndex, no VBO
    ///   - fragSPIRV:  composite fragment shader — samples all N slot images and blends them
    public init(
        context:    VulkanContext,
        slotCount:  Int,
        renderPass: VkRenderPass,
        vertSPIRV:  [UInt32],
        fragSPIRV:  [UInt32]
    ) throws {
        self.device         = context.device
        self.slotCount      = slotCount
        try createSampler()
        try createDescriptorSetLayout()
        try createPipelineLayout()
        try createPipeline(renderPass: renderPass, vertSPIRV: vertSPIRV, fragSPIRV: fragSPIRV)
    }

    deinit {
        if let sampler        { vkDestroySampler(device, sampler, nil) }
        if let pipeline       { vkDestroyPipeline(device, pipeline, nil) }
        if let pipelineLayout { vkDestroyPipelineLayout(device, pipelineLayout, nil) }
        if let setLayout      { vkDestroyDescriptorSetLayout(device, setLayout, nil) }
    }

    // MARK: Setup

    private func createSampler() throws {
        var info = VkSamplerCreateInfo()
        info.sType        = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
        info.magFilter    = VK_FILTER_NEAREST
        info.minFilter    = VK_FILTER_NEAREST
        info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
        guard vkCreateSampler(device, &info, nil, &sampler) == VK_SUCCESS else {
            throw VulkanCoreError.pipeline
        }
    }

    private func createDescriptorSetLayout() throws {
        // One COMBINED_IMAGE_SAMPLER per slot — binding i samples slot i's VkImage
        let bindings: [VkDescriptorSetLayoutBinding] = (0..<slotCount).map { i in
            var b = VkDescriptorSetLayoutBinding()
            b.binding         = UInt32(i)
            b.descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
            b.descriptorCount = 1
            b.stageFlags      = VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)
            return b
        }
        try bindings.withUnsafeBufferPointer { buf in
            var info = VkDescriptorSetLayoutCreateInfo()
            info.sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
            info.bindingCount = UInt32(buf.count)
            info.pBindings    = buf.baseAddress
            guard vkCreateDescriptorSetLayout(device, &info, nil, &setLayout) == VK_SUCCESS else {
                throw VulkanCoreError.pipeline
            }
        }
    }

    private func createPipelineLayout() throws {
        try withUnsafePointer(to: setLayout) { layoutPtr in
            var info = VkPipelineLayoutCreateInfo()
            info.sType          = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
            info.setLayoutCount = 1
            info.pSetLayouts    = layoutPtr
            guard vkCreatePipelineLayout(device, &info, nil, &pipelineLayout) == VK_SUCCESS else {
                throw VulkanCoreError.pipeline
            }
        }
    }

    private func createPipeline(
        renderPass: VkRenderPass,
        vertSPIRV:  [UInt32],
        fragSPIRV:  [UInt32]
    ) throws {
        let vertModule = try ShaderModuleLoader.load(device: device, spirv: vertSPIRV)
        let fragModule = try ShaderModuleLoader.load(device: device, spirv: fragSPIRV)
        defer {
            vkDestroyShaderModule(device, vertModule, nil)
            vkDestroyShaderModule(device, fragModule, nil)
        }

        try "main".withCString { entry in
            let stages: [VkPipelineShaderStageCreateInfo] = [
                {
                    var s = VkPipelineShaderStageCreateInfo()
                    s.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                    s.stage = VK_SHADER_STAGE_VERTEX_BIT
                    s.module = vertModule
                    s.pName = entry
                    return s
                }(),
                {
                    var s = VkPipelineShaderStageCreateInfo()
                    s.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                    s.stage = VK_SHADER_STAGE_FRAGMENT_BIT
                    s.module = fragModule
                    s.pName = entry
                    return s
                }()
            ]

            var vertexInput = VkPipelineVertexInputStateCreateInfo()
            vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO

            var inputAssembly = VkPipelineInputAssemblyStateCreateInfo()
            inputAssembly.sType    = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
            inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST

            var rasterizer = VkPipelineRasterizationStateCreateInfo()
            rasterizer.sType       = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
            rasterizer.polygonMode = VK_POLYGON_MODE_FILL
            rasterizer.cullMode    = VkCullModeFlags(VK_CULL_MODE_NONE.rawValue)
            rasterizer.frontFace   = VK_FRONT_FACE_COUNTER_CLOCKWISE
            rasterizer.lineWidth   = 1.0

            var multisample = VkPipelineMultisampleStateCreateInfo()
            multisample.sType                = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
            multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT

            var blendAtt = VkPipelineColorBlendAttachmentState()
            blendAtt.blendEnable         = VK_TRUE
            blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA
            blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            blendAtt.colorBlendOp        = VK_BLEND_OP_ADD
            blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
            blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO
            blendAtt.alphaBlendOp        = VK_BLEND_OP_ADD
            blendAtt.colorWriteMask      = VkColorComponentFlags(
                VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue |
                VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue
            )

            let dynStates: [VkDynamicState] = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]

            var viewportState = VkPipelineViewportStateCreateInfo()
            viewportState.sType         = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
            viewportState.viewportCount = 1
            viewportState.scissorCount  = 1

            try withUnsafePointer(to: blendAtt) { blendAttPtr in
                var blendState = VkPipelineColorBlendStateCreateInfo()
                blendState.sType           = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
                blendState.attachmentCount = 1
                blendState.pAttachments    = blendAttPtr

                try dynStates.withUnsafeBufferPointer { dynBuf in
                    var dynState = VkPipelineDynamicStateCreateInfo()
                    dynState.sType             = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
                    dynState.dynamicStateCount = UInt32(dynBuf.count)
                    dynState.pDynamicStates    = dynBuf.baseAddress

                    try withUnsafePointer(to: vertexInput)   { viPtr  in
                    try withUnsafePointer(to: inputAssembly) { iaPtr  in
                    try withUnsafePointer(to: rasterizer)    { rsPtr  in
                    try withUnsafePointer(to: multisample)   { msPtr  in
                    try withUnsafePointer(to: blendState)    { bsPtr  in
                    try withUnsafePointer(to: dynState)      { dyPtr  in
                    try withUnsafePointer(to: viewportState) { vpPtr  in
                    try stages.withUnsafeBufferPointer { stgBuf in
                        var info = VkGraphicsPipelineCreateInfo()
                        info.sType               = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
                        info.stageCount          = UInt32(stgBuf.count)
                        info.pStages             = stgBuf.baseAddress
                        info.pVertexInputState   = viPtr
                        info.pInputAssemblyState = iaPtr
                        info.pRasterizationState = rsPtr
                        info.pMultisampleState   = msPtr
                        info.pColorBlendState    = bsPtr
                        info.pDynamicState       = dyPtr
                        info.pViewportState      = vpPtr
                        info.layout              = pipelineLayout
                        info.renderPass          = renderPass
                        info.subpass             = 0
                        info.basePipelineIndex   = -1
                        guard vkCreateGraphicsPipelines(device, nil, 1, &info, nil, &pipeline) == VK_SUCCESS else {
                            throw VulkanCoreError.pipeline
                        }
                    }}}}}}}}
                }
            }
        }
    }

    // MARK: Descriptor set

    /// Allocates a descriptor set from a fresh, single-set pool dedicated to
    /// it, rather than sharing the engine's general pool. MoltenVK packs
    /// same-layout sets from one pool back-to-back in its Metal argument
    /// buffer at this layout's natural byte stride (16 bytes for one
    /// COMBINED_IMAGE_SAMPLER); on some GPUs that leaves every other set at
    /// a 16-byte offset, which fails Metal's 32-byte buffer-binding
    /// alignment requirement (`MTLDebugRenderCommandEncoder
    /// validateCommonDrawErrors`). Giving each set its own pool makes every
    /// allocation the first (offset-0) one in its pool, sidestepping that
    /// packing entirely — at the cost of one small pool per composited node.
    /// Caller owns the returned pool and must destroy it (which frees the
    /// set) when the node is dropped.
    public func allocateNodeDescriptorSet() throws -> (pool: VkDescriptorPool, set: VkDescriptorSet) {
        var poolSize = VkDescriptorPoolSize(
            type: VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            descriptorCount: UInt32(slotCount)
        )
        var poolOpt: VkDescriptorPool?
        let poolResult: VkResult = withUnsafePointer(to: &poolSize) { sizePtr in
            var info = VkDescriptorPoolCreateInfo()
            info.sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
            info.maxSets       = 1
            info.poolSizeCount = 1
            info.pPoolSizes    = sizePtr
            return vkCreateDescriptorPool(device, &info, nil, &poolOpt)
        }
        guard poolResult == VK_SUCCESS, let pool = poolOpt else {
            throw VulkanCoreError.descriptorSet
        }

        var set: VkDescriptorSet?
        let setResult: VkResult = withUnsafePointer(to: setLayout) { layoutPtr in
            var info = VkDescriptorSetAllocateInfo()
            info.sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
            info.descriptorPool     = pool
            info.descriptorSetCount = 1
            info.pSetLayouts        = layoutPtr
            return vkAllocateDescriptorSets(device, &info, &set)
        }
        guard setResult == VK_SUCCESS, let set else {
            vkDestroyDescriptorPool(device, pool, nil)
            throw VulkanCoreError.descriptorSet
        }
        return (pool, set)
    }

    /// Bind all slot image views. VkImageViews are stable for slot lifetime —
    /// call once after buildSlots; no rebind needed when contents change.
    public func updateDescriptorSet(_ set: VkDescriptorSet, imageViews: [VkImageView?]) {
        let imageInfos: [VkDescriptorImageInfo] = imageViews.map { view in
            var info = VkDescriptorImageInfo()
            info.sampler     = sampler
            info.imageView   = view
            info.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
            return info
        }
        imageInfos.withUnsafeBufferPointer { infoBuf in
            var writes: [VkWriteDescriptorSet] = (0..<imageViews.count).map { i in
                var w = VkWriteDescriptorSet()
                w.sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                w.dstSet          = set
                w.dstBinding      = UInt32(i)
                w.descriptorCount = 1
                w.descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER
                w.pImageInfo      = infoBuf.baseAddress!.advanced(by: i)
                return w
            }
            vkUpdateDescriptorSets(device, UInt32(writes.count), &writes, 0, nil)
        }
    }

    // MARK: Record

    /// Call inside your render pass subpass. Binds pipeline + descriptor set,
    /// sets dynamic viewport/scissor, draws the full-screen composite quad.
    public func record(
        commandBuffer: VkCommandBuffer,
        descriptorSet: VkDescriptorSet,
        viewport:      VkViewport,
        scissor:       VkRect2D
    ) {
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
        var set: VkDescriptorSet? = descriptorSet
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &set, 0, nil)
        var vp = viewport
        var sc = scissor
        vkCmdSetViewport(commandBuffer, 0, 1, &vp)
        vkCmdSetScissor(commandBuffer, 0, 1, &sc)
        vkCmdDraw(commandBuffer, 6, 1, 0, 0)
    }
}
