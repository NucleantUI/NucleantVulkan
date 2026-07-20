import Foundation
import CVulkan


public enum VKShaderError: Error, LocalizedError {
    case failed(String)
    
    public var errorDescription: String? {
        switch self {
        case .failed(let msg): return "Vulkan shader failed: \(msg)"
        }
    }
}


/// Vulkan shader with GPU pipeline
@MainActor
public final class VKShader {
    
    public let fragmentSource: String
    public private(set) var isReady: Bool = false
    
    // Vulkan objects
    private var vertexModule: VkShaderModule?
    private var fragmentModule: VkShaderModule?
    private var pipelineLayout: VkPipelineLayout?
    private var pipeline: VkPipeline?
    
    // SPIR-V bytecode
    private var vertexSPIRV: [UInt32]?
    private var fragmentSPIRV: [UInt32]?
    
    public init(fragmentSource: String) {
        self.fragmentSource = fragmentSource
        
        // Load SPIR-V
        self.vertexSPIRV = VKShaderCompiler.shared.getDefaultVertexSPIRV()
        self.fragmentSPIRV = VKShaderCompiler.shared.tryCompileFragment(fragmentSource)
    }
    
    public func createPipeline(device: VkDevice, renderPass: VkRenderPass, extent: VkExtent2D) throws {
        guard let vertSPIRV = vertexSPIRV, let fragSPIRV = fragmentSPIRV else {
            throw VKShaderError.failed("Missing SPIR-V bytecode")
        }
        
        // Create shader modules
        vertexModule = try createShaderModule(device: device, code: vertSPIRV)
        fragmentModule = try createShaderModule(device: device, code: fragSPIRV)
        
        guard let vertModule = vertexModule, let fragModule = fragmentModule else {
            throw VKShaderError.failed("Failed to create shader modules")
        }
        
        // Entry point name - must persist for the duration of pipeline creation
        let entryPointName = strdup("main")!
        defer { free(entryPointName) }
        
        // Shader stages
        var vertStageInfo = VkPipelineShaderStageCreateInfo()
        vertStageInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        vertStageInfo.stage = VK_SHADER_STAGE_VERTEX_BIT
        vertStageInfo.module = vertModule
        vertStageInfo.pName = UnsafePointer(entryPointName)
        
        var fragStageInfo = VkPipelineShaderStageCreateInfo()
        fragStageInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        fragStageInfo.stage = VK_SHADER_STAGE_FRAGMENT_BIT
        fragStageInfo.module = fragModule
        fragStageInfo.pName = UnsafePointer(entryPointName)
        
        var shaderStages = [vertStageInfo, fragStageInfo]
        
        // Vertex input - fullscreen quad doesn't need vertex input
        var vertexInputInfo = VkPipelineVertexInputStateCreateInfo()
        vertexInputInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        
        // Input assembly
        var inputAssembly = VkPipelineInputAssemblyStateCreateInfo()
        inputAssembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        inputAssembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
        inputAssembly.primitiveRestartEnable = VkBool32(VK_FALSE)
        
        // Viewport
        var viewport = VkViewport(
            x: 0, y: 0,
            width: Float(extent.width),
            height: Float(extent.height),
            minDepth: 0, maxDepth: 1
        )
        
        var scissor = VkRect2D(
            offset: VkOffset2D(x: 0, y: 0),
            extent: extent
        )
        
        var viewportState = VkPipelineViewportStateCreateInfo()
        viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewportState.viewportCount = 1
        viewportState.scissorCount = 1
        
        // Rasterizer
        var rasterizer = VkPipelineRasterizationStateCreateInfo()
        rasterizer.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        rasterizer.depthClampEnable = VkBool32(VK_FALSE)
        rasterizer.rasterizerDiscardEnable = VkBool32(VK_FALSE)
        rasterizer.polygonMode = VK_POLYGON_MODE_FILL
        rasterizer.lineWidth = 1.0
        rasterizer.cullMode = UInt32(VK_CULL_MODE_BACK_BIT.rawValue)
        rasterizer.frontFace = VK_FRONT_FACE_CLOCKWISE
        rasterizer.depthBiasEnable = VkBool32(VK_FALSE)
        
        // Multisampling
        var multisampling = VkPipelineMultisampleStateCreateInfo()
        multisampling.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        multisampling.sampleShadingEnable = VkBool32(VK_FALSE)
        multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
        
        // Color blending
        var colorBlendAttachment = VkPipelineColorBlendAttachmentState()
        colorBlendAttachment.colorWriteMask = UInt32(VK_COLOR_COMPONENT_R_BIT.rawValue | VK_COLOR_COMPONENT_G_BIT.rawValue | VK_COLOR_COMPONENT_B_BIT.rawValue | VK_COLOR_COMPONENT_A_BIT.rawValue)
        colorBlendAttachment.blendEnable = VkBool32(VK_FALSE)
        
        var colorBlending = VkPipelineColorBlendStateCreateInfo()
        colorBlending.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        colorBlending.logicOpEnable = VkBool32(VK_FALSE)
        colorBlending.attachmentCount = 1
        
        // Push constants for uniforms
        var pushConstantRange = VkPushConstantRange()
        pushConstantRange.stageFlags = UInt32(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue)
        pushConstantRange.offset = 0
        pushConstantRange.size = UInt32(MemoryLayout<ShaderPushConstants>.size)
        
        // Pipeline layout
        var pipelineLayoutInfo = VkPipelineLayoutCreateInfo()
        pipelineLayoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        pipelineLayoutInfo.pushConstantRangeCount = 1
        
        var layout: VkPipelineLayout?
        let layoutResult = withUnsafePointer(to: &pushConstantRange) { pcPtr in
            pipelineLayoutInfo.pPushConstantRanges = pcPtr
            return vkCreatePipelineLayout(device, &pipelineLayoutInfo, nil, &layout)
        }
        
        guard layoutResult == VK_SUCCESS else {
            throw VKShaderError.failed("Failed to create pipeline layout: \(layoutResult.rawValue)")
        }
        self.pipelineLayout = layout
        
        // Dynamic states
        var dynamicStates: [VkDynamicState] = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR]
        var dynamicState = VkPipelineDynamicStateCreateInfo()
        dynamicState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dynamicState.dynamicStateCount = UInt32(dynamicStates.count)
        
        // Create pipeline
        var pipelineInfo = VkGraphicsPipelineCreateInfo()
        pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        pipelineInfo.stageCount = 2
        pipelineInfo.renderPass = renderPass
        pipelineInfo.subpass = 0
        pipelineInfo.layout = layout
        
        var createdPipeline: VkPipeline?
        let pipelineResult = shaderStages.withUnsafeBufferPointer { stagesPtr in
            pipelineInfo.pStages = stagesPtr.baseAddress
            return withUnsafePointer(to: &vertexInputInfo) { viPtr in
                pipelineInfo.pVertexInputState = viPtr
                return withUnsafePointer(to: &inputAssembly) { iaPtr in
                    pipelineInfo.pInputAssemblyState = iaPtr
                    return withUnsafePointer(to: &viewport) { vpPtr in
                        return withUnsafePointer(to: &scissor) { scPtr in
                            viewportState.pViewports = vpPtr
                            viewportState.pScissors = scPtr
                            return withUnsafePointer(to: &viewportState) { vsPtr in
                                pipelineInfo.pViewportState = vsPtr
                                return withUnsafePointer(to: &rasterizer) { rastPtr in
                                    pipelineInfo.pRasterizationState = rastPtr
                                    return withUnsafePointer(to: &multisampling) { msPtr in
                                        pipelineInfo.pMultisampleState = msPtr
                                        return withUnsafePointer(to: &colorBlendAttachment) { cbaPtr in
                                            colorBlending.pAttachments = cbaPtr
                                            return withUnsafePointer(to: &colorBlending) { cbPtr in
                                                pipelineInfo.pColorBlendState = cbPtr
                                                return dynamicStates.withUnsafeBufferPointer { dsPtr in
                                                    dynamicState.pDynamicStates = dsPtr.baseAddress
                                                    return withUnsafePointer(to: &dynamicState) { dynPtr in
                                                        pipelineInfo.pDynamicState = dynPtr
                                                        return vkCreateGraphicsPipelines(device, nil, 1, &pipelineInfo, nil, &createdPipeline)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        
        guard pipelineResult == VK_SUCCESS else {
            throw VKShaderError.failed("Failed to create graphics pipeline: \(pipelineResult.rawValue)")
        }
        
        self.pipeline = createdPipeline
        self.isReady = true
    }
    
    private func createShaderModule(device: VkDevice, code: [UInt32]) throws -> VkShaderModule? {
        var createInfo = VkShaderModuleCreateInfo()
        createInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
        createInfo.codeSize = code.count * MemoryLayout<UInt32>.size
        
        var module: VkShaderModule?
        let result = code.withUnsafeBufferPointer { codePtr in
            createInfo.pCode = codePtr.baseAddress
            return vkCreateShaderModule(device, &createInfo, nil, &module)
        }
        
        guard result == VK_SUCCESS else {
            throw VKShaderError.failed("vkCreateShaderModule failed: \(result.rawValue)")
        }
        
        return module
    }
    
    public func bind(commandBuffer: VkCommandBuffer) {
        guard let pipeline = pipeline else { return }
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
    }
    
    public func pushConstants(commandBuffer: VkCommandBuffer, constants: ShaderPushConstants) {
        guard let layout = pipelineLayout else { return }
        
        var mutableConstants = constants
        withUnsafePointer(to: &mutableConstants) { ptr in
            vkCmdPushConstants(
                commandBuffer,
                layout,
                UInt32(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue),
                0,
                UInt32(MemoryLayout<ShaderPushConstants>.size),
                ptr
            )
        }
    }
    
    public func cleanup(device: VkDevice) {
        if let pipeline = pipeline {
            vkDestroyPipeline(device, pipeline, nil)
        }
        if let layout = pipelineLayout {
            vkDestroyPipelineLayout(device, layout, nil)
        }
        if let module = vertexModule {
            vkDestroyShaderModule(device, module, nil)
        }
        if let module = fragmentModule {
            vkDestroyShaderModule(device, module, nil)
        }
        
        pipeline = nil
        pipelineLayout = nil
        vertexModule = nil
        fragmentModule = nil
        isReady = false
    }
}




