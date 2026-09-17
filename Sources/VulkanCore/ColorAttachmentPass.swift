//
//  ColorAttachmentPass.swift
//  VulkanCore
//
//  A render pass into one offscreen colour image, and the graphics pipeline
//  shape that draws into it: no vertex buffers (the vertex stage works from
//  `gl_VertexIndex` / `gl_InstanceIndex`), a triangle list, alpha blending,
//  dynamic viewport and scissor. The image is cleared to transparent at the
//  start of the pass and left in `SHADER_READ_ONLY_OPTIMAL` at the end, so
//  a composite can sample it with no barrier of its own.
//
//  Same boundary as `ComputePipeline`: this consumes SPIR-V words and owns no
//  shader source.
//

import CVulkan

/// The render pass for a single RGBA8 colour attachment, and a framebuffer
/// binding one image view to it.
public final class ColorAttachmentPass {

    public let device: VkDevice
    public let format: VkFormat
    public private(set) var renderPass: VkRenderPass?

    public init(device: VkDevice, format: VkFormat = VK_FORMAT_R8G8B8A8_UNORM) throws {
        self.device = device
        self.format = format
        try createRenderPass()
    }

    deinit {
        if let renderPass { vkDestroyRenderPass(device, renderPass, nil) }
    }

    /// `initialLayout` is UNDEFINED — the pass clears, so whatever the image
    /// held is discarded — and `finalLayout` is what a sampler wants. The
    /// two external dependencies order this pass after the previous frame's
    /// sampling of the image and before the next one's.
    private func createRenderPass() throws {
        var color = VkAttachmentDescription()
        color.format         = format
        color.samples        = VK_SAMPLE_COUNT_1_BIT
        color.loadOp         = VK_ATTACHMENT_LOAD_OP_CLEAR
        color.storeOp        = VK_ATTACHMENT_STORE_OP_STORE
        color.stencilLoadOp  = VK_ATTACHMENT_LOAD_OP_DONT_CARE
        color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE
        color.initialLayout  = VK_IMAGE_LAYOUT_UNDEFINED
        color.finalLayout    = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL

        var colorRef = VkAttachmentReference(attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)

        let result: VkResult = withUnsafePointer(to: &colorRef) { refPtr in
            var subpass = VkSubpassDescription()
            subpass.pipelineBindPoint    = VK_PIPELINE_BIND_POINT_GRAPHICS
            subpass.colorAttachmentCount = 1
            subpass.pColorAttachments    = refPtr

            var before = VkSubpassDependency()
            before.srcSubpass    = UInt32.max // VK_SUBPASS_EXTERNAL
            before.dstSubpass    = 0
            before.srcStageMask  = VkPipelineStageFlags(VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue)
            before.srcAccessMask = VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue)
            before.dstStageMask  = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            before.dstAccessMask = VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)

            var after = VkSubpassDependency()
            after.srcSubpass    = 0
            after.dstSubpass    = UInt32.max
            after.srcStageMask  = VkPipelineStageFlags(VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT.rawValue)
            after.srcAccessMask = VkAccessFlags(VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT.rawValue)
            after.dstStageMask  = VkPipelineStageFlags(VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT.rawValue)
            after.dstAccessMask = VkAccessFlags(VK_ACCESS_SHADER_READ_BIT.rawValue)

            let dependencies = [before, after]
            return withUnsafePointer(to: &color) { attPtr in
                withUnsafePointer(to: &subpass) { subPtr in
                    dependencies.withUnsafeBufferPointer { depBuf in
                        var info = VkRenderPassCreateInfo()
                        info.sType           = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
                        info.attachmentCount = 1
                        info.pAttachments    = attPtr
                        info.subpassCount    = 1
                        info.pSubpasses      = subPtr
                        info.dependencyCount = UInt32(depBuf.count)
                        info.pDependencies   = depBuf.baseAddress
                        return vkCreateRenderPass(device, &info, nil, &renderPass)
                    }
                }
            }
        }
        guard result == VK_SUCCESS else { throw VulkanCoreError.pipeline }
    }

    /// A framebuffer for `imageView` at `width` × `height`. Caller owns it.
    public func makeFramebuffer(imageView: VkImageView, width: Int, height: Int) throws -> VkFramebuffer {
        var framebuffer: VkFramebuffer?
        let result: VkResult = withUnsafePointer(to: imageView as VkImageView?) { viewPtr in
            var info = VkFramebufferCreateInfo()
            info.sType           = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
            info.renderPass      = renderPass
            info.attachmentCount = 1
            info.pAttachments    = viewPtr
            info.width           = UInt32(width)
            info.height          = UInt32(height)
            info.layers          = 1
            return vkCreateFramebuffer(device, &info, nil, &framebuffer)
        }
        guard result == VK_SUCCESS, let framebuffer else { throw VulkanCoreError.pipeline }
        return framebuffer
    }

    /// Begin the pass over the whole framebuffer, cleared to transparent
    /// black, with the viewport and scissor set to match. Pair with
    /// `vkCmdEndRenderPass`.
    public func begin(_ cmd: VkCommandBuffer, framebuffer: VkFramebuffer, width: Int, height: Int) {
        var clear = VkClearValue()
        clear.color = VkClearColorValue(float32: (0, 0, 0, 0))
        withUnsafePointer(to: &clear) { clearPtr in
            var info = VkRenderPassBeginInfo()
            info.sType             = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
            info.renderPass        = renderPass
            info.framebuffer       = framebuffer
            info.renderArea.offset = VkOffset2D(x: 0, y: 0)
            info.renderArea.extent = VkExtent2D(width: UInt32(width), height: UInt32(height))
            info.clearValueCount   = 1
            info.pClearValues      = clearPtr
            vkCmdBeginRenderPass(cmd, &info, VK_SUBPASS_CONTENTS_INLINE)
        }
        var viewport = VkViewport(x: 0, y: 0, width: Float(width), height: Float(height), minDepth: 0, maxDepth: 1)
        var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(width), height: UInt32(height)))
        vkCmdSetViewport(cmd, 0, 1, &viewport)
        vkCmdSetScissor(cmd, 0, 1, &scissor)
    }
}

/// Builds the one graphics pipeline shape `ColorAttachmentPass` draws with.
public enum InstancedQuadPipeline {

    /// How fragments are blended into the (transparent-cleared) attachment.
    public enum Blend {
        /// `src.rgb * src.a + dst.rgb * (1 - src.a)`; alpha accumulates as
        /// `src.a + dst.a * (1 - src.a)`. Straight-alpha input, the usual
        /// "over".
        case alpha
        /// `src + dst` for every channel. Glows and particles.
        case additive
    }

    /// - Parameters:
    ///   - vertex / fragment: SPIR-V words and the entry point name for each
    ///     stage — the same words twice, with different names, when both
    ///     stages live in one module.
    public static func create(
        device: VkDevice,
        renderPass: VkRenderPass,
        layout: VkPipelineLayout,
        vertex: (spirv: [UInt32], entryPoint: String),
        fragment: (spirv: [UInt32], entryPoint: String),
        blend: Blend = .alpha
    ) throws -> VkPipeline {
        let vertModule = try ShaderModuleLoader.load(device: device, spirv: vertex.spirv)
        defer { vkDestroyShaderModule(device, vertModule, nil) }
        let fragModule = try ShaderModuleLoader.load(device: device, spirv: fragment.spirv)
        defer { vkDestroyShaderModule(device, fragModule, nil) }

        var pipeline: VkPipeline?
        try vertex.entryPoint.withCString { vertEntry in
        try fragment.entryPoint.withCString { fragEntry in
            let stages: [VkPipelineShaderStageCreateInfo] = [
                {
                    var s = VkPipelineShaderStageCreateInfo()
                    s.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                    s.stage  = VK_SHADER_STAGE_VERTEX_BIT
                    s.module = vertModule
                    s.pName  = vertEntry
                    return s
                }(),
                {
                    var s = VkPipelineShaderStageCreateInfo()
                    s.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
                    s.stage  = VK_SHADER_STAGE_FRAGMENT_BIT
                    s.module = fragModule
                    s.pName  = fragEntry
                    return s
                }(),
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
            blendAtt.blendEnable = VK_TRUE
            switch blend {
            case .alpha:
                blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA
                blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
                blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
                blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
            case .additive:
                blendAtt.srcColorBlendFactor = VK_BLEND_FACTOR_ONE
                blendAtt.dstColorBlendFactor = VK_BLEND_FACTOR_ONE
                blendAtt.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE
                blendAtt.dstAlphaBlendFactor = VK_BLEND_FACTOR_ONE
            }
            blendAtt.colorBlendOp   = VK_BLEND_OP_ADD
            blendAtt.alphaBlendOp   = VK_BLEND_OP_ADD
            blendAtt.colorWriteMask = VkColorComponentFlags(
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
                        info.layout              = layout
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
        return pipeline!
    }
}
