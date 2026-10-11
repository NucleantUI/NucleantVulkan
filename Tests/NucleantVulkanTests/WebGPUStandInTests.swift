//
//  WebGPUStandInTests.swift
//  NucleantVulkanTests
//
//  The Vulkan implementation on WebGPU (wasm only), exercised through the
//  same Vulkan code every platform runs — VulkanCore's pipelines, shaderc,
//  the render engine — with the results read back and checked against what
//  Vulkan itself defines. Run with scripts/run_wasm_tests.py, which builds
//  this target for wasm and runs it in headless Chrome.
//
#if os(WASI)
import Testing
import Observation
import CVulkan
import VulkanCore
import NucleantShader
@testable import NucleantVulkan

@Suite(.serialized)
struct WebGPUStandInTests {

    // MARK: Compute

    @Test func computeDispatchWritesStorageImageThatReadsBack() throws {
        let core = try VulkanCore(imageCount: 1)
        // 20 px: 80-byte rows, not the 256-byte multiple WebGPU copies want.
        let width = 20, height = 12
        let image = try core.createStorageImage(width: width, height: height)
        defer { image.destroy(device: core.device) }

        let source = """
        #version 450
        layout(local_size_x = 16, local_size_y = 16) in;
        layout(binding = 0, rgba8) uniform writeonly image2D outImage;
        layout(binding = 1) uniform Params { float blue; } params;
        void main() {
            ivec2 p = ivec2(gl_GlobalInvocationID.xy);
            if (p.x >= \(width) || p.y >= \(height)) return;
            imageStore(outImage, p, vec4(float(p.x * 10) / 255.0, float(p.y * 20) / 255.0, params.blue, 1.0));
        }
        """
        let spirv = try #require(VKShaderCompiler.shared.tryCompileCompute(source),
                                 "\(VKShaderCompiler.shared.lastErrorMessage ?? "")")
        let pipeline = try TexGenComputePipeline(context: core, computeSPIRV: spirv)
        let sets = try pipeline.allocateDescriptorSets()
        var blue: Float = 1
        let uniforms = core.createUniformBuffers(size: MemoryLayout<Float>.size)
        defer { uniforms.forEach { $0.destroy(device: core.device) } }
        uniforms[0].update(device: core.device, data: &blue, bytes: MemoryLayout<Float>.size)
        pipeline.updateDescriptorSets(sets, output: image, uniformBuffers: uniforms)

        core.withOneTimeCommands { cmd in
            pipeline.record(commandBuffer: cmd, descriptorSet: sets[0], outputWidth: width, outputHeight: height)
        }
        let pixels = core.readbackRGBA8(image)

        #expect(pixels.count == width * height * 4)
        for (x, y) in [(0, 0), (19, 0), (7, 5), (19, 11)] {
            #expect(rgba(pixels, width, x, y) == [UInt8(x * 10), UInt8(y * 20), 255, 255], "pixel \(x),\(y)")
        }
    }

    // MARK: Render pass, viewport, push constants

    @Test func viewportPastTheFramebufferEdgeMapsAsOnVulkan() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try ColorTarget(core, width: 64, height: 48)
        defer { target.destroy(core) }
        let fragment = try compile("""
        #version 450
        layout(location = 0) in vec2 vTexCoord;
        layout(location = 0) out vec4 fragColor;
        void main() { fragColor = vec4(vTexCoord, 0.0, 1.0); }
        """, .fragment)
        let draw = try QuadDraw(core, pass: target.pass, fragment: fragment, pushConstantBytes: 0)
        defer { draw.destroy(core) }

        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            // Twice the target's width and starting half of that off its
            // left edge: Vulkan maps the quad over x ∈ [-32, 96), so the
            // target shows u from 0.25 to 0.75. WebGPU forbids such a
            // viewport; the implementation has to reproduce the mapping.
            var viewport = VkViewport(x: -32, y: 0, width: 128, height: 48, minDepth: 0, maxDepth: 1)
            vkCmdSetViewport(cmd, 0, 1, &viewport)
            draw.record(cmd)
            vkCmdEndRenderPass(cmd)
        }
        let pixels = target.read(core)

        for (x, y) in [(0, 0), (63, 0), (31, 24), (0, 47), (63, 47)] {
            let u = (Double(x) + 0.5 + 32) / 128
            let v = (Double(y) + 0.5) / 48
            let pixel = rgba(pixels, 64, x, y)
            #expect(close(pixel[0], u * 255) && close(pixel[1], v * 255) && pixel[3] == 255,
                    "pixel \(x),\(y) = \(pixel), want u \(u) v \(v)")
        }
    }

    @Test func pushConstantsReachEveryDraw() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try ColorTarget(core, width: 32, height: 16)
        defer { target.destroy(core) }
        let fragment = try compile("""
        #version 450
        layout(location = 0) out vec4 fragColor;
        layout(push_constant) uniform Push { vec4 color; } push;
        void main() { fragColor = push.color; }
        """, .fragment)
        let draw = try QuadDraw(core, pass: target.pass, fragment: fragment, pushConstantBytes: 16)
        defer { draw.destroy(core) }

        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            for (half, color) in [(0, SIMD4<Float>(1, 0, 0, 1)), (1, SIMD4<Float>(0, 0, 1, 1))] {
                var scissor = VkRect2D(offset: VkOffset2D(x: Int32(half * 16), y: 0), extent: VkExtent2D(width: 16, height: 16))
                vkCmdSetScissor(cmd, 0, 1, &scissor)
                var value = color
                vkCmdPushConstants(cmd, draw.layout, VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue), 0, 16, &value)
                draw.record(cmd)
            }
            vkCmdEndRenderPass(cmd)
        }
        let pixels = target.read(core)

        #expect(rgba(pixels, 32, 3, 8) == [255, 0, 0, 255])
        #expect(rgba(pixels, 32, 15, 0) == [255, 0, 0, 255])
        #expect(rgba(pixels, 32, 16, 15) == [0, 0, 255, 255])
        #expect(rgba(pixels, 32, 31, 8) == [0, 0, 255, 255])
    }

    // MARK: Transfers

    @Test func unalignedUploadThenScalingBlitThenReadback() throws {
        let core = try VulkanCore(imageCount: 1)
        let usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
        // 10 px: 40-byte rows on the way in, 80-byte rows on the way out.
        let small = try TestImage(core, width: 10, height: 6, usage: usage)
        let large = try TestImage(core, width: 20, height: 12, usage: usage)
        defer {
            small.destroy(core)
            large.destroy(core)
        }
        var source = [UInt8]()
        for y in 0..<6 {
            for x in 0..<10 { source += [UInt8(x * 20), UInt8(y * 40), UInt8(x + y), 255] }
        }
        let staging = source.withUnsafeBytes { raw in
            core.createBuffer(size: raw.count, usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue), seed: raw.baseAddress)
        }
        defer { staging.destroy(device: core.device) }

        core.withOneTimeCommands { cmd in
            var region = VkBufferImageCopy()
            region.imageSubresource = colorLayer
            region.imageExtent = VkExtent3D(width: 10, height: 6, depth: 1)
            vkCmdCopyBufferToImage(cmd, staging.buffer, small.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region)
            var blit = VkImageBlit()
            blit.srcSubresource = colorLayer
            blit.srcOffsets.1 = VkOffset3D(x: 10, y: 6, z: 1)
            blit.dstSubresource = colorLayer
            blit.dstOffsets.1 = VkOffset3D(x: 20, y: 12, z: 1)
            vkCmdBlitImage(cmd, small.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, large.image,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, VK_FILTER_NEAREST)
        }

        #expect(readPixels(core, small.image, width: 10, height: 6) == source)
        let scaled = readPixels(core, large.image, width: 20, height: 12)
        for (x, y) in [(0, 0), (9, 0), (4, 3), (9, 5)] {
            let want = Array(source[(y * 10 + x) * 4..<(y * 10 + x) * 4 + 4])
            #expect(rgba(scaled, 20, x * 2, y * 2) == want, "scaled pixel of \(x),\(y)")
            #expect(rgba(scaled, 20, x * 2 + 1, y * 2 + 1) == want, "scaled pixel of \(x),\(y)")
        }
    }

    @Test func clearColorImageFillsTheImage() throws {
        let core = try VulkanCore(imageCount: 1)
        let image = try TestImage(core, width: 8, height: 4,
                                  usage: VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        defer { image.destroy(core) }
        core.withOneTimeCommands { cmd in
            var color = VkClearColorValue(float32: (0, 1, 0, 1))
            var range = VkImageSubresourceRange(aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
                                                baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
            vkCmdClearColorImage(cmd, image.image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range)
        }
        let pixels = readPixels(core, image.image, width: 8, height: 4)
        #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy { Array(pixels[$0..<$0 + 4]) == [0, 255, 0, 255] })
    }

    // MARK: Synchronisation

    @Test func fenceSignalsOnceTheSubmittedWorkFinishes() throws {
        let core = try VulkanCore(imageCount: 1)
        var fenceInfo = VkFenceCreateInfo()
        fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
        var fence: VkFence?
        #expect(vkCreateFence(core.device, &fenceInfo, nil, &fence) == VK_SUCCESS)
        defer { vkDestroyFence(core.device, fence, nil) }
        #expect(vkGetFenceStatus(core.device, fence) == VK_NOT_READY)

        var cmd: VkCommandBuffer?
        var alloc = VkCommandBufferAllocateInfo()
        alloc.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
        alloc.commandPool = core.commandPool
        alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
        alloc.commandBufferCount = 1
        vkAllocateCommandBuffers(core.device, &alloc, &cmd)
        defer { vkFreeCommandBuffers(core.device, core.commandPool, 1, &cmd) }
        var begin = VkCommandBufferBeginInfo()
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
        vkBeginCommandBuffer(cmd, &begin)
        vkEndCommandBuffer(cmd)
        withUnsafePointer(to: cmd) { cmdPtr in
            var submit = VkSubmitInfo()
            submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
            submit.commandBufferCount = 1
            submit.pCommandBuffers = cmdPtr
            #expect(vkQueueSubmit(core.computeQueue, 1, &submit, fence) == VK_SUCCESS)
        }
        #expect(vkWaitForFences(core.device, 1, &fence, VK_TRUE, UInt64.max) == VK_SUCCESS)
        #expect(vkGetFenceStatus(core.device, fence) == VK_SUCCESS)
        vkResetFences(core.device, 1, &fence)
        #expect(vkGetFenceStatus(core.device, fence) == VK_NOT_READY)
    }

    // MARK: Engine

    @Test func engineCompositesAPixelBufferNodeOntoTheCanvas() throws {
        let engine = try VulkanRenderEngine<TestSlot>(canvasSelector: "#test-canvas", getSize: { (64, 48) })
        let node = try engine.makePixelBufferNode(width: 16, height: 8, scale: 2)
        node.write(rgba: [UInt32](repeating: 0xFF00_80FF, count: 16 * 8))
        engine.append(TestSlot(id: 1, context: .pixels(node)))
        for _ in 0..<3 { engine.drawFrame(1.0 / 60.0) }
        engine.waitForPreviousFrame()
        #expect(engine.readable.contains(1))
        engine.remove(id: 1)
    }
}

// MARK: - Helpers

private let colorLayer = VkImageSubresourceLayers(
    aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)

private func rgba(_ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
    let i = (y * width + x) * 4
    return Array(pixels[i..<i + 4])
}

/// Within one step of 8-bit rounding.
private func close(_ value: UInt8, _ expected: Double) -> Bool {
    abs(Double(value) - expected) <= 1
}

private func compile(_ source: String, _ stage: VKShaderCompiler.ShaderStage) throws -> [UInt32] {
    try #require(VKShaderCompiler.shared.compile(source: source, stage: stage, filename: "test.glsl"),
                 "\(VKShaderCompiler.shared.lastErrorMessage ?? "")")
}

/// An RGBA8 image with its memory and a 2D view.
private struct TestImage {
    let image: VkImage
    let memory: VkDeviceMemory
    let view: VkImageView

    init(_ core: VulkanCore, width: Int, height: Int, usage: UInt32) throws {
        var info = VkImageCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.imageType = VK_IMAGE_TYPE_2D
        info.format = VK_FORMAT_R8G8B8A8_UNORM
        info.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        info.mipLevels = 1
        info.arrayLayers = 1
        info.samples = VK_SAMPLE_COUNT_1_BIT
        info.tiling = VK_IMAGE_TILING_OPTIMAL
        info.usage = VkImageUsageFlags(usage)
        var image: VkImage?
        guard vkCreateImage(core.device, &info, nil, &image) == VK_SUCCESS, let image else { throw VulkanBootstrapError.image }
        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(core.device, image, &requirements)
        var alloc = VkMemoryAllocateInfo()
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        alloc.allocationSize = requirements.size
        alloc.memoryTypeIndex = core.findMemoryType(typeFilter: requirements.memoryTypeBits,
                                                    properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue))
        var memory: VkDeviceMemory?
        guard vkAllocateMemory(core.device, &alloc, nil, &memory) == VK_SUCCESS, let memory else { throw VulkanBootstrapError.memory }
        vkBindImageMemory(core.device, image, memory, 0)
        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image = image
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format = VK_FORMAT_R8G8B8A8_UNORM
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
        var view: VkImageView?
        guard vkCreateImageView(core.device, &viewInfo, nil, &view) == VK_SUCCESS, let view else { throw VulkanBootstrapError.image }
        self.image = image
        self.memory = memory
        self.view = view
    }

    func destroy(_ core: VulkanCore) {
        vkDestroyImageView(core.device, view, nil)
        vkDestroyImage(core.device, image, nil)
        vkFreeMemory(core.device, memory, nil)
    }
}

/// Copies an RGBA8 image to host memory: copy into a host-visible buffer,
/// wait for the queue, map — the Vulkan way, nothing WebGPU-specific.
private func readPixels(_ core: VulkanCore, _ image: VkImage, width: Int, height: Int) -> [UInt8] {
    let byteCount = width * height * 4
    let staging = core.createBuffer(size: byteCount, usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue))
    defer { staging.destroy(device: core.device) }
    core.withOneTimeCommands { cmd in
        var region = VkBufferImageCopy()
        region.imageSubresource = colorLayer
        region.imageExtent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        vkCmdCopyImageToBuffer(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging.buffer, 1, &region)
    }
    var out = [UInt8](repeating: 0, count: byteCount)
    var mapped: UnsafeMutableRawPointer?
    vkMapMemory(core.device, staging.memory, 0, VkDeviceSize(byteCount), 0, &mapped)
    if let mapped {
        out.withUnsafeMutableBytes { $0.baseAddress?.copyMemory(from: mapped, byteCount: byteCount) }
    }
    vkUnmapMemory(core.device, staging.memory)
    return out
}

/// A colour target for `ColorAttachmentPass`, readable afterwards.
private struct ColorTarget {
    let image: TestImage
    let pass: ColorAttachmentPass
    let framebuffer: VkFramebuffer
    let width: Int
    let height: Int

    init(_ core: VulkanCore, width: Int, height: Int) throws {
        image = try TestImage(core, width: width, height: height,
                              usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        pass = try ColorAttachmentPass(device: core.device)
        framebuffer = try pass.makeFramebuffer(imageView: image.view, width: width, height: height)
        self.width = width
        self.height = height
    }

    func begin(_ cmd: VkCommandBuffer) {
        pass.begin(cmd, framebuffer: framebuffer, width: width, height: height)
    }

    func read(_ core: VulkanCore) -> [UInt8] {
        readPixels(core, image.image, width: width, height: height)
    }

    func destroy(_ core: VulkanCore) {
        vkDestroyFramebuffer(core.device, framebuffer, nil)
        image.destroy(core)
    }
}

/// `InstancedQuadPipeline` drawing the engine's full-screen quad
/// (VKPresetShaders.defaultVertex) with the given fragment shader.
private struct QuadDraw {
    let layout: VkPipelineLayout
    let pipeline: VkPipeline

    init(_ core: VulkanCore, pass: ColorAttachmentPass, fragment: [UInt32], pushConstantBytes: UInt32) throws {
        var range = VkPushConstantRange(stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue), offset: 0, size: pushConstantBytes)
        var info = VkPipelineLayoutCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        var layout: VkPipelineLayout?
        let result: VkResult = withUnsafePointer(to: &range) { rangePtr in
            if pushConstantBytes > 0 {
                info.pushConstantRangeCount = 1
                info.pPushConstantRanges = rangePtr
            }
            return vkCreatePipelineLayout(core.device, &info, nil, &layout)
        }
        guard result == VK_SUCCESS, let layout else { throw VulkanCoreError.pipeline }
        let vertex = try #require(VKShaderCompiler.shared.getDefaultVertexSPIRV())
        self.layout = layout
        self.pipeline = try InstancedQuadPipeline.create(
            device: core.device, renderPass: pass.renderPass!, layout: layout,
            vertex: (vertex, "main"), fragment: (fragment, "main"))
    }

    func record(_ cmd: VkCommandBuffer) {
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
        vkCmdDraw(cmd, 6, 1, 0, 0)
    }

    func destroy(_ core: VulkanCore) {
        vkDestroyPipeline(core.device, pipeline, nil)
        vkDestroyPipelineLayout(core.device, layout, nil)
    }
}

/// The smallest composite slot the engine can drive: one pixel-buffer node.
@Observable
final class TestSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case pixels(PixelBufferShaderNode<TestSlot>)
    }

    let id: Int
    let context: Context
    var needsRender = true

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {
        if case .pixels(let node) = context { observe(node) }
    }

    func update(engine: Engine, cmd: VkCommandBuffer) {
        if case .pixels(let node) = context { node.update(engine, slot: self, cmd: cmd) }
    }

    func destroyResources(engine: Engine) {
        if case .pixels(let node) = context { node.destroyResources(engine) }
    }

    func getImageView() -> VkImageView? {
        if case .pixels(let node) = context { return node.imageView }
        return nil
    }
}
#endif
