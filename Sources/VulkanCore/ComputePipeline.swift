//
//  ComputePipeline.swift
//  VulkanCore
//
//  Swift port of ogldev Tutorial 28 (Compute Shaders).
//  Reference:
//    VulkanScienceAcadamy/ogldev/Vulkan/VulkanCore/Source/compute_pipeline.cpp
//    VulkanScienceAcadamy/ogldev/Vulkan/VulkanCore/Source/Pipelines/texgen_pipeline.cpp
//
//  See docs: VulkanScienceAcadamy/docs/28-compute-shaders.md
//
//  Shader boundary: VulkanCore does NOT compile shaders and stores none. It
//  consumes already-compiled SPIR-V words (`[UInt32]`) — exactly what
//  `SulphurShader`'s `VKShaderCompiler` emits. SulphurShader (which depends on
//  SulphurVulkan) compiles GLSL and *injects* the SPIR-V here. Keeping it this
//  way means the GLSL→SPIR-V toolchain (shaderc) lives entirely in SulphurShader.
//

import CVulkan

/// A minimal storage image: the same `VkImage` used as STORAGE (compute writes)
/// and SAMPLED (fragment reads). Mirrors the `m_csOutput` texture in Tutorial 28.
public struct StorageImage {
    public var image: VkImage?
    public var view: VkImageView?
    public var sampler: VkSampler?
    public var memory: VkDeviceMemory?
    public var width: Int = 0
    public var height: Int = 0

    public init() {}

    public func destroy(device: VkDevice) {
        if let sampler { vkDestroySampler(device, sampler, nil) }
        if let view { vkDestroyImageView(device, view, nil) }
        if let image { vkDestroyImage(device, image, nil) }
        if let memory { vkFreeMemory(device, memory, nil) }
    }
}

/// Turns already-compiled SPIR-V into a `VkShaderModule`. The injection seam:
/// `SulphurShader` compiles GLSL→SPIR-V (`[UInt32]`) and hands the words here.
/// VulkanCore never compiles and never owns shader source. This is also the
/// shared loader `SulphurShader.VKShader` can call instead of rolling its own.
public enum ShaderModuleLoader {
    public static func load(device: VkDevice, spirv: [UInt32]) throws -> VkShaderModule {
        var module: VkShaderModule?
        try spirv.withUnsafeBufferPointer { buf in
            var info = VkShaderModuleCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
            info.codeSize = buf.count * MemoryLayout<UInt32>.stride
            info.pCode = buf.baseAddress
            guard vkCreateShaderModule(device, &info, nil, &module) == VK_SUCCESS else {
                throw VulkanCoreError.shaderModule
            }
        }
        return module!
    }
}

public enum VulkanCoreError: Error {
    case shaderModule
    case pipeline
    case descriptorSet
}

/// Compute pipeline that generates a texture into a storage image.
///
/// Faithful port of `OgldevVK::ComputePipeline` + `TexGenComputePipeline`:
///  - binding 0: STORAGE_IMAGE  (the output the shader writes)
///  - binding 1: UNIFORM_BUFFER (the `time` uniform driving animation)
public final class TexGenComputePipeline {

    private let device: VkDevice
    private let imageCount: Int
    private let descriptorPool: VkDescriptorPool

    private var shaderModule: VkShaderModule?
    private var pipeline: VkPipeline?
    private var pipelineLayout: VkPipelineLayout?
    private var setLayout: VkDescriptorSetLayout?

    /// - Parameter computeSPIRV: compiled SPIR-V words for the `.comp` shader,
    ///   produced by `SulphurShader.VKShaderCompiler` and injected here.
    public init(context: VulkanContext, computeSPIRV: [UInt32]) throws {
        self.device = context.device
        self.imageCount = context.imageCount
        self.descriptorPool = context.descriptorPool

        try createDescriptorSetLayout()
        try createPipelineLayout()
        self.shaderModule = try ShaderModuleLoader.load(device: device, spirv: computeSPIRV)
        try createPipeline()
    }

    deinit {
        if let shaderModule { vkDestroyShaderModule(device, shaderModule, nil) }
        if let setLayout { vkDestroyDescriptorSetLayout(device, setLayout, nil) }
        if let pipelineLayout { vkDestroyPipelineLayout(device, pipelineLayout, nil) }
        if let pipeline { vkDestroyPipeline(device, pipeline, nil) }
    }

    // MARK: Setup (port of CreateDescSetLayout / CreatePipelineLayout / CreatePipeline)

    private func createDescriptorSetLayout() throws {
        var storageImageBinding = VkDescriptorSetLayoutBinding()
        storageImageBinding.binding = 0
        storageImageBinding.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
        storageImageBinding.descriptorCount = 1
        storageImageBinding.stageFlags = VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)

        var uniformBinding = VkDescriptorSetLayoutBinding()
        uniformBinding.binding = 1
        uniformBinding.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
        uniformBinding.descriptorCount = 1
        uniformBinding.stageFlags = VkShaderStageFlags(VK_SHADER_STAGE_COMPUTE_BIT.rawValue)

        let bindings = [storageImageBinding, uniformBinding]
        try bindings.withUnsafeBufferPointer { buf in
            var info = VkDescriptorSetLayoutCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
            info.bindingCount = UInt32(buf.count)
            info.pBindings = buf.baseAddress
            guard vkCreateDescriptorSetLayout(device, &info, nil, &setLayout) == VK_SUCCESS else {
                throw VulkanCoreError.pipeline
            }
        }
    }

    private func createPipelineLayout() throws {
        try withUnsafePointer(to: setLayout) { layoutPtr in
            var info = VkPipelineLayoutCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
            info.setLayoutCount = 1
            info.pSetLayouts = layoutPtr
            guard vkCreatePipelineLayout(device, &info, nil, &pipelineLayout) == VK_SUCCESS else {
                throw VulkanCoreError.pipeline
            }
        }
    }

    private func createPipeline() throws {
        try "main".withCString { entry in
            var stage = VkPipelineShaderStageCreateInfo()
            stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
            stage.module = shaderModule
            stage.pName = entry

            var info = VkComputePipelineCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO
            info.stage = stage
            info.layout = pipelineLayout
            info.basePipelineIndex = -1

            guard vkCreateComputePipelines(device, nil, 1, &info, nil, &pipeline) == VK_SUCCESS else {
                throw VulkanCoreError.pipeline
            }
        }
    }

    // MARK: Descriptor sets (port of AllocDescSets / UpdateDescSets)

    /// Allocate one descriptor set per swapchain image.
    public func allocateDescriptorSets() throws -> [VkDescriptorSet] {
        let layouts = Array(repeating: setLayout, count: imageCount)
        var sets = [VkDescriptorSet?](repeating: nil, count: imageCount)

        try layouts.withUnsafeBufferPointer { layoutBuf in
            var info = VkDescriptorSetAllocateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
            info.descriptorPool = descriptorPool
            info.descriptorSetCount = UInt32(imageCount)
            info.pSetLayouts = layoutBuf.baseAddress
            guard vkAllocateDescriptorSets(device, &info, &sets) == VK_SUCCESS else {
                throw VulkanCoreError.descriptorSet
            }
        }
        return sets.compactMap { $0 }
    }

    /// Point each set at the storage image (binding 0) and its per-image
    /// uniform buffer (binding 1). Port of `TexGenComputePipeline::UpdateDescSets`.
    public func updateDescriptorSets(_ sets: [VkDescriptorSet],
                                     output: StorageImage,
                                     uniformBuffers: [BufferAndMemory]) {
        precondition(sets.count == imageCount && uniformBuffers.count == imageCount)

        var imageInfo = VkDescriptorImageInfo()
        imageInfo.sampler = output.sampler
        imageInfo.imageView = output.view
        imageInfo.imageLayout = VK_IMAGE_LAYOUT_GENERAL

        withUnsafePointer(to: &imageInfo) { imageInfoPtr in
            for i in 0..<imageCount {
                var bufInfo = VkDescriptorBufferInfo()
                bufInfo.buffer = uniformBuffers[i].buffer
                bufInfo.offset = 0
                bufInfo.range = VkDeviceSize(bitPattern: -1) // VK_WHOLE_SIZE

                withUnsafePointer(to: &bufInfo) { bufInfoPtr in
                    var writeImage = VkWriteDescriptorSet()
                    writeImage.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                    writeImage.dstSet = sets[i]
                    writeImage.dstBinding = 0
                    writeImage.descriptorCount = 1
                    writeImage.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
                    writeImage.pImageInfo = imageInfoPtr

                    var writeUniform = VkWriteDescriptorSet()
                    writeUniform.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
                    writeUniform.dstSet = sets[i]
                    writeUniform.dstBinding = 1
                    writeUniform.descriptorCount = 1
                    writeUniform.descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER
                    writeUniform.pBufferInfo = bufInfoPtr

                    var writes = [writeImage, writeUniform]
                    vkUpdateDescriptorSets(device, 2, &writes, 0, nil)
                }
            }
        }
    }

    // MARK: Dispatch (port of ComputePipeline::RecordCommandBuffer)

    /// Bind + dispatch. `groupCount` is workgroups, NOT threads — pass
    /// `(ceil(W/16), ceil(H/16), 1)` for a 16×16 local size. See doc footgun note.
    public func record(commandBuffer: VkCommandBuffer,
                       descriptorSet: VkDescriptorSet,
                       groupCountX: UInt32, groupCountY: UInt32, groupCountZ: UInt32) {
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
        var set: VkDescriptorSet? = descriptorSet
        vkCmdBindDescriptorSets(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                                pipelineLayout, 0, 1, &set, 0, nil)
        vkCmdDispatch(commandBuffer, groupCountX, groupCountY, groupCountZ)
    }

    /// Convenience for the common "one thread per pixel, 16×16 local size" case.
    /// Uses ceil division so non-multiple-of-16 sizes still cover every pixel.
    public func record(commandBuffer: VkCommandBuffer,
                       descriptorSet: VkDescriptorSet,
                       outputWidth: Int, outputHeight: Int,
                       localSize: Int = 16) {
        let gx = UInt32((outputWidth + localSize - 1) / localSize)
        let gy = UInt32((outputHeight + localSize - 1) / localSize)
        record(commandBuffer: commandBuffer, descriptorSet: descriptorSet,
               groupCountX: gx, groupCountY: gy, groupCountZ: 1)
    }
}
