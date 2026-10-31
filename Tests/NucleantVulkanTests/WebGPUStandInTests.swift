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
import WASILibc
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

    // MARK: Vertex input, depth/stencil, dynamic state

    @Test func indexedDrawsReadVertexAndIndexBuffers() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try ColorTarget(core, width: 32, height: 16)
        defer { target.destroy(core) }
        // Two quads: the left half red, the right half blue. Positions at
        // binding 0, colours at binding 3 — bindings, not WebGPU's slots.
        let positions: [Float] = [-1, -1, 0,  0, -1, 0,  -1, 1, 0,  0, 1, 0,
                                   0, -1, 0,  1, -1, 0,   0, 1, 0,  1, 1, 0]
        let colors: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255,
                               0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let shortIndices: [UInt16] = [0, 1, 2, 2, 1, 3]
        let longIndices: [UInt32] = [0, 1, 2, 2, 1, 3]
        let buffers = [
            upload(core, positions, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT), upload(core, colors, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT),
            upload(core, shortIndices, VK_BUFFER_USAGE_INDEX_BUFFER_BIT), upload(core, longIndices, VK_BUFFER_USAGE_INDEX_BUFFER_BIT),
        ]
        defer { buffers.forEach { $0.destroy(device: core.device) } }
        let draw = try TestPipeline(core, renderPass: target.pass.renderPass!, colorShaders())
        defer { draw.destroy(core) }

        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            draw.bind(cmd, width: 32, height: 16)
            var vertexBuffers: [VkBuffer?] = [buffers[0].buffer, buffers[1].buffer]
            var offsets: [VkDeviceSize] = [0, 0]
            vkCmdBindVertexBuffers(cmd, 0, 1, &vertexBuffers[0], &offsets[0])
            vkCmdBindVertexBuffers(cmd, 3, 1, &vertexBuffers[1], &offsets[1])
            vkCmdBindIndexBuffer(cmd, buffers[2].buffer, 0, VK_INDEX_TYPE_UINT16)
            vkCmdDrawIndexed(cmd, 6, 1, 0, 0, 0)
            // The same indices, 32-bit, four vertices on: the right quad.
            vkCmdBindIndexBuffer(cmd, buffers[3].buffer, 0, VK_INDEX_TYPE_UINT32)
            vkCmdDrawIndexed(cmd, 6, 1, 0, 4, 0)
            vkCmdEndRenderPass(cmd)
        }
        let pixels = target.read(core)

        #expect(rgba(pixels, 32, 2, 3) == [255, 0, 0, 255])
        #expect(rgba(pixels, 32, 15, 12) == [255, 0, 0, 255])
        #expect(rgba(pixels, 32, 16, 3) == [0, 0, 255, 255])
        #expect(rgba(pixels, 32, 30, 14) == [0, 0, 255, 255])
    }

    @Test func stencilWrittenWithDynamicMasksDecidesWhereLaterDrawsLand() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try DepthStencilTarget(core, width: 32, height: 16)
        defer { target.destroy(core) }
        let buffers = quadBuffers(core)
        defer { buffers.forEach { $0.destroy(device: core.device) } }

        func stencil(_ compare: VkCompareOp, _ pass: VkStencilOp) -> VkPipelineDepthStencilStateCreateInfo {
            var face = VkStencilOpState()
            face.compareOp = compare
            face.passOp = pass
            face.failOp = VK_STENCIL_OP_KEEP
            face.depthFailOp = VK_STENCIL_OP_KEEP
            var state = VkPipelineDepthStencilStateCreateInfo()
            state.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
            state.stencilTestEnable = VK_TRUE
            state.front = face
            state.back = face
            return state
        }
        let write = try TestPipeline(core, renderPass: target.renderPass, colorShaders(),
                                     depthStencil: stencil(VK_COMPARE_OP_ALWAYS, VK_STENCIL_OP_REPLACE), colorWriteMask: 0)
        let test = try TestPipeline(core, renderPass: target.renderPass, colorShaders(),
                                    depthStencil: stencil(VK_COMPARE_OP_EQUAL, VK_STENCIL_OP_KEEP))
        defer { write.destroy(core); test.destroy(core) }

        let both = VkStencilFaceFlags(VK_STENCIL_FACE_FRONT_AND_BACK.rawValue)
        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            // Reference 3 through write mask 1: the left half's stencil becomes 1.
            write.bind(cmd, width: 32, height: 16)
            vkCmdSetStencilReference(cmd, both, 3)
            vkCmdSetStencilWriteMask(cmd, both, 0x1)
            vkCmdSetStencilCompareMask(cmd, both, 0xFF)
            buffers.draw(cmd, quad: 0)
            // Equal to 1 passes exactly there; green over the whole target.
            test.bind(cmd, width: 32, height: 16)
            vkCmdSetStencilReference(cmd, both, 1)
            buffers.draw(cmd, quad: 2)
            vkCmdEndRenderPass(cmd)
        }
        let pixels = target.read(core)

        #expect(rgba(pixels, 32, 3, 8) == [0, 255, 0, 255])
        #expect(rgba(pixels, 32, 15, 0) == [0, 255, 0, 255])
        #expect(rgba(pixels, 32, 16, 8) == [0, 0, 0, 255])
        #expect(rgba(pixels, 32, 31, 15) == [0, 0, 0, 255])
    }

    @Test func depthTestKeepsTheNearerSurface() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try DepthStencilTarget(core, width: 16, height: 16)
        defer { target.destroy(core) }
        let buffers = quadBuffers(core)
        defer { buffers.forEach { $0.destroy(device: core.device) } }
        var depth = VkPipelineDepthStencilStateCreateInfo()
        depth.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        depth.depthTestEnable = VK_TRUE
        depth.depthWriteEnable = VK_TRUE
        depth.depthCompareOp = VK_COMPARE_OP_LESS
        let draw = try TestPipeline(core, renderPass: target.renderPass, colorShaders(), depthStencil: depth)
        defer { draw.destroy(core) }

        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            draw.bind(cmd, width: 16, height: 16)
            buffers.draw(cmd, quad: 1)   // red, z 0.25
            buffers.draw(cmd, quad: 2)   // green, z 0.75: behind, hidden
            vkCmdEndRenderPass(cmd)
        }
        let pixels = target.read(core)

        #expect(rgba(pixels, 16, 0, 0) == [255, 0, 0, 255])
        #expect(rgba(pixels, 16, 8, 8) == [255, 0, 0, 255])
        #expect(rgba(pixels, 16, 15, 15) == [255, 0, 0, 255])
    }

    @Test func clearAttachmentsClearsOnlyTheRectAndLaterDrawsCarryOn() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try ColorTarget(core, width: 32, height: 16)
        defer { target.destroy(core) }
        let fragment = try compile("""
        #version 450
        layout(location = 0) out vec4 fragColor;
        void main() { fragColor = vec4(1.0, 0.0, 0.0, 1.0); }
        """, .fragment)
        let draw = try QuadDraw(core, pass: target.pass, fragment: fragment, pushConstantBytes: 0)
        defer { draw.destroy(core) }

        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            var scissor = VkRect2D(offset: VkOffset2D(x: 24, y: 0), extent: VkExtent2D(width: 8, height: 16))
            vkCmdSetScissor(cmd, 0, 1, &scissor)
            var attachment = VkClearAttachment()
            attachment.aspectMask = VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue)
            attachment.colorAttachment = 0
            attachment.clearValue.color = VkClearColorValue(float32: (0, 1, 0, 1))
            var rect = VkClearRect(rect: VkRect2D(offset: VkOffset2D(x: 0, y: 4), extent: VkExtent2D(width: 16, height: 8)),
                                   baseArrayLayer: 0, layerCount: 1)
            vkCmdClearAttachments(cmd, 1, &attachment, 1, &rect)
            // Red through the scissor set before the clear: the clear must
            // not have changed it.
            draw.record(cmd)
            vkCmdEndRenderPass(cmd)
        }
        let pixels = target.read(core)

        #expect(rgba(pixels, 32, 0, 4) == [0, 255, 0, 255])
        #expect(rgba(pixels, 32, 15, 11) == [0, 255, 0, 255])
        #expect(rgba(pixels, 32, 0, 3) == [0, 0, 0, 0])
        #expect(rgba(pixels, 32, 16, 8) == [0, 0, 0, 0])
        #expect(rgba(pixels, 32, 24, 0) == [255, 0, 0, 255])
        #expect(rgba(pixels, 32, 31, 15) == [255, 0, 0, 255])
    }

    @Test func blendConstantsScaleTheSource() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try ColorTarget(core, width: 8, height: 8)
        defer { target.destroy(core) }
        let buffers = quadBuffers(core)
        defer { buffers.forEach { $0.destroy(device: core.device) } }
        var blend = VkPipelineColorBlendAttachmentState()
        blend.blendEnable = VK_TRUE
        blend.srcColorBlendFactor = VK_BLEND_FACTOR_CONSTANT_COLOR
        blend.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO
        blend.colorBlendOp = VK_BLEND_OP_ADD
        blend.srcAlphaBlendFactor = VK_BLEND_FACTOR_CONSTANT_ALPHA
        blend.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO
        blend.alphaBlendOp = VK_BLEND_OP_ADD
        blend.colorWriteMask = 0xF
        let draw = try TestPipeline(core, renderPass: target.pass.renderPass!, colorShaders(), blend: blend)
        defer { draw.destroy(core) }

        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            draw.bind(cmd, width: 8, height: 8)
            var constants: (Float, Float, Float, Float) = (0.25, 0.5, 0.75, 1)
            withUnsafePointer(to: &constants) { $0.withMemoryRebound(to: Float.self, capacity: 4) { vkCmdSetBlendConstants(cmd, $0) } }
            buffers.draw(cmd, quad: 3)   // white
            vkCmdEndRenderPass(cmd)
        }
        let pixel = rgba(target.read(core), 8, 4, 4)

        #expect(close(pixel[0], 0.25 * 255) && close(pixel[1], 0.5 * 255) && close(pixel[2], 0.75 * 255) && pixel[3] == 255, "\(pixel)")
    }

    @Test func vertexShaderWritingPointSizeStillDraws() throws {
        let core = try VulkanCore(imageCount: 1)
        let target = try ColorTarget(core, width: 8, height: 8)
        defer { target.destroy(core) }
        let buffers = quadBuffers(core)
        defer { buffers.forEach { $0.destroy(device: core.device) } }
        // What a pipeline that may draw points writes; WebGPU has no point
        // size, so the translation drops it and the draw goes ahead.
        let vertex = try compile("""
        #version 450
        layout(location = 0) in vec3 position;
        layout(location = 1) in vec4 color;
        layout(location = 0) out vec4 vColor;
        void main() { gl_PointSize = 1.0; gl_Position = vec4(position, 1.0); vColor = color; }
        """, .vertex)
        let draw = try TestPipeline(core, renderPass: target.pass.renderPass!, (vertex, colorShaders().fragment))
        defer { draw.destroy(core) }

        core.withOneTimeCommands { cmd in
            target.begin(cmd)
            draw.bind(cmd, width: 8, height: 8)
            buffers.draw(cmd, quad: 2)   // green
            vkCmdEndRenderPass(cmd)
        }
        let pixels = target.read(core)

        #expect(rgba(pixels, 8, 0, 0) == [0, 255, 0, 255])
        #expect(rgba(pixels, 8, 7, 7) == [0, 255, 0, 255])
    }

    // MARK: Descriptor pools, device

    @Test func resetDescriptorPoolReturnsEverySet() throws {
        let core = try VulkanCore(imageCount: 1)
        var binding = VkDescriptorSetLayoutBinding(
            binding: 0, descriptorType: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 1,
            stageFlags: VkShaderStageFlags(VK_SHADER_STAGE_FRAGMENT_BIT.rawValue), pImmutableSamplers: nil)
        var layoutInfo = VkDescriptorSetLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
        layoutInfo.bindingCount = 1
        var setLayout: VkDescriptorSetLayout?
        withUnsafePointer(to: &binding) { layoutInfo.pBindings = $0; vkCreateDescriptorSetLayout(core.device, &layoutInfo, nil, &setLayout) }
        var size = VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, descriptorCount: 2)
        var poolInfo = VkDescriptorPoolCreateInfo()
        poolInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
        poolInfo.maxSets = 2
        poolInfo.poolSizeCount = 1
        var pool: VkDescriptorPool?
        withUnsafePointer(to: &size) { poolInfo.pPoolSizes = $0; vkCreateDescriptorPool(core.device, &poolInfo, nil, &pool) }
        defer {
            vkDestroyDescriptorPool(core.device, pool, nil)
            vkDestroyDescriptorSetLayout(core.device, setLayout, nil)
        }
        func allocate(_ count: Int) -> VkResult {
            var layouts = [VkDescriptorSetLayout?](repeating: setLayout, count: count)
            var sets = [VkDescriptorSet?](repeating: nil, count: count)
            var info = VkDescriptorSetAllocateInfo()
            info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
            info.descriptorPool = pool
            info.descriptorSetCount = UInt32(count)
            return layouts.withUnsafeMutableBufferPointer { info.pSetLayouts = UnsafePointer($0.baseAddress); return vkAllocateDescriptorSets(core.device, &info, &sets) }
        }

        #expect(allocate(2) == VK_SUCCESS)
        #expect(allocate(1) == VK_ERROR_OUT_OF_POOL_MEMORY)
        #expect(vkResetDescriptorPool(core.device, pool, 0) == VK_SUCCESS)
        #expect(allocate(2) == VK_SUCCESS)
    }

    @Test func physicalDevicePropertiesReportTheWebGPULimits() throws {
        let core = try VulkanCore(imageCount: 1)
        var properties = VkPhysicalDeviceProperties()
        vkGetPhysicalDeviceProperties(core.physicalDevice, &properties)
        let name = withUnsafeBytes(of: properties.deviceName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }

        #expect(!name.isEmpty)
        #expect(properties.limits.minUniformBufferOffsetAlignment == 256)
        #expect(properties.limits.maxImageDimension2D >= 8192)
        #expect(properties.limits.maxColorAttachments == 8)
        #expect(properties.limits.maxBoundDescriptorSets >= 3)
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
        let node = try engine.renderDevice.makePixelBufferNode(width: 16, height: 8, scale: 2)
        node.write(rgba: [UInt32](repeating: 0xFF00_80FF, count: 16 * 8))
        engine.append(TestSlot(id: 1, context: .pixels(node)))
        for _ in 0..<3 { engine.drawFrame(1.0 / 60.0) }
        engine.waitForPreviousFrame()
        #expect(engine.renderDevice.readable.contains(1))
        // The window only shows the node; its maker frees it.
        engine.remove(id: 1)
        node.destroyResources(engine.renderDevice)
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


/// A host-visible buffer holding `values`.
private func upload<T>(_ core: VulkanCore, _ values: [T], _ usage: VkBufferUsageFlagBits) -> BufferAndMemory {
    values.withUnsafeBytes { core.createBuffer(size: $0.count, usage: VkBufferUsageFlags(usage.rawValue), seed: $0.baseAddress) }
}

/// The vertex and fragment shader of the vertex-input tests: a clip-space
/// position (binding 0) and an RGBA8 colour (binding 3).
private func colorShaders() throws -> (vertex: [UInt32], fragment: [UInt32]) {
    let vertex = try compile("""
    #version 450
    layout(location = 0) in vec3 position;
    layout(location = 1) in vec4 color;
    layout(location = 0) out vec4 vColor;
    void main() { gl_Position = vec4(position, 1.0); vColor = color; }
    """, .vertex)
    let fragment = try compile("""
    #version 450
    layout(location = 0) in vec4 vColor;
    layout(location = 0) out vec4 fragColor;
    void main() { fragColor = vColor; }
    """, .fragment)
    return (vertex, fragment)
}

/// Full-target quads for `colorShaders`: 0 the left half (z 0.5, red), 1 the
/// whole target (z 0.25, red), 2 the whole target (z 0.75, green), 3 the
/// whole target (z 0.5, white) — four vertices each, as a strip.
private struct QuadBuffers: Sequence {
    let positions: BufferAndMemory
    let colors: BufferAndMemory

    func makeIterator() -> IndexingIterator<[BufferAndMemory]> { [positions, colors].makeIterator() }

    func draw(_ cmd: VkCommandBuffer, quad: Int) {
        var buffers: [VkBuffer?] = [positions.buffer, colors.buffer]
        var offsets: [VkDeviceSize] = [0, 0]
        vkCmdBindVertexBuffers(cmd, 0, 1, &buffers[0], &offsets[0])
        vkCmdBindVertexBuffers(cmd, 3, 1, &buffers[1], &offsets[1])
        vkCmdDraw(cmd, 4, 1, UInt32(quad * 4), 0)
    }
}

private func quadBuffers(_ core: VulkanCore) -> QuadBuffers {
    func quad(x0: Float, x1: Float, z: Float) -> [Float] { [x0, -1, z, x1, -1, z, x0, 1, z, x1, 1, z] }
    let positions = quad(x0: -1, x1: 0, z: 0.5) + quad(x0: -1, x1: 1, z: 0.25) + quad(x0: -1, x1: 1, z: 0.75) + quad(x0: -1, x1: 1, z: 0.5)
    let colors: [[UInt8]] = [[255, 0, 0, 255], [255, 0, 0, 255], [0, 255, 0, 255], [255, 255, 255, 255]]
    let perVertex = colors.flatMap { color in Array(repeating: color, count: 4).flatMap { $0 } }
    return QuadBuffers(positions: upload(core, positions, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT),
                       colors: upload(core, perVertex, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT))
}

/// A graphics pipeline for the vertex-input tests: position at binding 0,
/// colour at binding 3, dynamic viewport/scissor/stencil/blend constants.
private struct TestPipeline {
    let layout: VkPipelineLayout
    let pipeline: VkPipeline

    init(_ core: VulkanCore, renderPass: VkRenderPass, _ shaders: (vertex: [UInt32], fragment: [UInt32]),
         depthStencil: VkPipelineDepthStencilStateCreateInfo? = nil, colorWriteMask: UInt32 = 0xF,
         blend: VkPipelineColorBlendAttachmentState? = nil) throws {
        var layoutInfo = VkPipelineLayoutCreateInfo()
        layoutInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO
        var layout: VkPipelineLayout?
        guard vkCreatePipelineLayout(core.device, &layoutInfo, nil, &layout) == VK_SUCCESS, let layout else { throw VulkanCoreError.pipeline }
        self.layout = layout

        func module(_ words: [UInt32]) -> VkShaderModule? {
            var info = VkShaderModuleCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO
            info.codeSize = words.count * 4
            var module: VkShaderModule?
            words.withUnsafeBufferPointer { info.pCode = $0.baseAddress; _ = vkCreateShaderModule(core.device, &info, nil, &module) }
            return module
        }
        let vertexModule = module(shaders.vertex), fragmentModule = module(shaders.fragment)
        defer {
            vkDestroyShaderModule(core.device, vertexModule, nil)
            vkDestroyShaderModule(core.device, fragmentModule, nil)
        }
        let main = strdup("main")!
        defer { free(main) }
        var stages = [VkPipelineShaderStageCreateInfo(), VkPipelineShaderStageCreateInfo()]
        for (i, (stage, module)) in [(VK_SHADER_STAGE_VERTEX_BIT, vertexModule), (VK_SHADER_STAGE_FRAGMENT_BIT, fragmentModule)].enumerated() {
            stages[i].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
            stages[i].stage = stage
            stages[i].module = module
            stages[i].pName = UnsafePointer(main)
        }
        var bindings = [
            VkVertexInputBindingDescription(binding: 0, stride: 12, inputRate: VK_VERTEX_INPUT_RATE_VERTEX),
            VkVertexInputBindingDescription(binding: 3, stride: 4, inputRate: VK_VERTEX_INPUT_RATE_VERTEX),
        ]
        var attributes = [
            VkVertexInputAttributeDescription(location: 0, binding: 0, format: VK_FORMAT_R32G32B32_SFLOAT, offset: 0),
            VkVertexInputAttributeDescription(location: 1, binding: 3, format: VK_FORMAT_R8G8B8A8_UNORM, offset: 0),
        ]
        var vertexInput = VkPipelineVertexInputStateCreateInfo()
        vertexInput.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO
        var assembly = VkPipelineInputAssemblyStateCreateInfo()
        assembly.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
        assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
        var viewport = VkPipelineViewportStateCreateInfo()
        viewport.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
        viewport.viewportCount = 1
        viewport.scissorCount = 1
        var raster = VkPipelineRasterizationStateCreateInfo()
        raster.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
        raster.lineWidth = 1
        var multisample = VkPipelineMultisampleStateCreateInfo()
        multisample.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO
        multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT
        var attachment = blend ?? VkPipelineColorBlendAttachmentState()
        if blend == nil { attachment.colorWriteMask = VkColorComponentFlags(colorWriteMask) }
        var colorBlend = VkPipelineColorBlendStateCreateInfo()
        colorBlend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO
        colorBlend.attachmentCount = 1
        var depth = depthStencil ?? VkPipelineDepthStencilStateCreateInfo()
        depth.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        var dynamicStates = [VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR, VK_DYNAMIC_STATE_BLEND_CONSTANTS,
                             VK_DYNAMIC_STATE_STENCIL_COMPARE_MASK, VK_DYNAMIC_STATE_STENCIL_WRITE_MASK, VK_DYNAMIC_STATE_STENCIL_REFERENCE]
        var dynamic = VkPipelineDynamicStateCreateInfo()
        dynamic.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
        dynamic.dynamicStateCount = UInt32(dynamicStates.count)

        var info = VkGraphicsPipelineCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO
        info.stageCount = 2
        info.layout = layout
        info.renderPass = renderPass
        var pipeline: VkPipeline?
        let result = stages.withUnsafeBufferPointer { stagesPtr in
            bindings.withUnsafeMutableBufferPointer { bindingsPtr in
                attributes.withUnsafeMutableBufferPointer { attributesPtr in
                    dynamicStates.withUnsafeMutableBufferPointer { dynamicPtr in
                        withUnsafeMutablePointer(to: &attachment) { attachmentPtr in
                            vertexInput.vertexBindingDescriptionCount = 2
                            vertexInput.pVertexBindingDescriptions = UnsafePointer(bindingsPtr.baseAddress)
                            vertexInput.vertexAttributeDescriptionCount = 2
                            vertexInput.pVertexAttributeDescriptions = UnsafePointer(attributesPtr.baseAddress)
                            colorBlend.pAttachments = UnsafePointer(attachmentPtr)
                            dynamic.pDynamicStates = UnsafePointer(dynamicPtr.baseAddress)
                            info.pStages = stagesPtr.baseAddress
                            return withUnsafePointer(to: &vertexInput) { info.pVertexInputState = $0
                                return withUnsafePointer(to: &assembly) { info.pInputAssemblyState = $0
                                    return withUnsafePointer(to: &viewport) { info.pViewportState = $0
                                        return withUnsafePointer(to: &raster) { info.pRasterizationState = $0
                                            return withUnsafePointer(to: &multisample) { info.pMultisampleState = $0
                                                return withUnsafePointer(to: &depth) { info.pDepthStencilState = depthStencil == nil ? nil : $0
                                                    return withUnsafePointer(to: &colorBlend) { info.pColorBlendState = $0
                                                        return withUnsafePointer(to: &dynamic) { info.pDynamicState = $0
                                                            return vkCreateGraphicsPipelines(core.device, nil, 1, &info, nil, &pipeline)
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
        }
        guard result == VK_SUCCESS, let pipeline else { throw VulkanCoreError.pipeline }
        self.pipeline = pipeline
    }

    /// Binds the pipeline with a viewport and scissor over the target.
    func bind(_ cmd: VkCommandBuffer, width: Int, height: Int) {
        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
        var viewport = VkViewport(x: 0, y: 0, width: Float(width), height: Float(height), minDepth: 0, maxDepth: 1)
        vkCmdSetViewport(cmd, 0, 1, &viewport)
        var scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(width), height: UInt32(height)))
        vkCmdSetScissor(cmd, 0, 1, &scissor)
    }

    func destroy(_ core: VulkanCore) {
        vkDestroyPipeline(core.device, pipeline, nil)
        vkDestroyPipelineLayout(core.device, layout, nil)
    }
}

/// An RGBA8 colour image and a D24S8 depth/stencil image in one render
/// pass: colour cleared to opaque black, depth to 1, stencil to 0.
private struct DepthStencilTarget {
    let color: TestImage
    let depthStencil: TestImage
    let renderPass: VkRenderPass
    let framebuffer: VkFramebuffer
    let width: Int
    let height: Int

    init(_ core: VulkanCore, width: Int, height: Int) throws {
        color = try TestImage(core, width: width, height: height,
                              usage: VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        depthStencil = try TestImage(core, width: width, height: height, usage: VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT.rawValue,
                                     format: VK_FORMAT_D24_UNORM_S8_UINT,
                                     aspect: VK_IMAGE_ASPECT_DEPTH_BIT.rawValue | VK_IMAGE_ASPECT_STENCIL_BIT.rawValue)
        var attachments = [VkAttachmentDescription(), VkAttachmentDescription()]
        for (i, format) in [VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_D24_UNORM_S8_UINT].enumerated() {
            attachments[i].format = format
            attachments[i].samples = VK_SAMPLE_COUNT_1_BIT
            attachments[i].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
            attachments[i].storeOp = VK_ATTACHMENT_STORE_OP_STORE
            attachments[i].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_CLEAR
            attachments[i].stencilStoreOp = VK_ATTACHMENT_STORE_OP_STORE
            attachments[i].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            attachments[i].finalLayout = i == 0 ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL : VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
        }
        var colorRef = VkAttachmentReference(attachment: 0, layout: VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
        var depthRef = VkAttachmentReference(attachment: 1, layout: VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
        var subpass = VkSubpassDescription()
        subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS
        subpass.colorAttachmentCount = 1
        var info = VkRenderPassCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO
        info.attachmentCount = 2
        info.subpassCount = 1
        var pass: VkRenderPass?
        let result = withUnsafePointer(to: &colorRef) { colorPtr in
            withUnsafePointer(to: &depthRef) { depthPtr in
                attachments.withUnsafeBufferPointer { attachmentsPtr in
                    subpass.pColorAttachments = colorPtr
                    subpass.pDepthStencilAttachment = depthPtr
                    info.pAttachments = attachmentsPtr.baseAddress
                    return withUnsafePointer(to: &subpass) { info.pSubpasses = $0; return vkCreateRenderPass(core.device, &info, nil, &pass) }
                }
            }
        }
        guard result == VK_SUCCESS, let pass else { throw VulkanCoreError.pipeline }
        renderPass = pass
        var views: [VkImageView?] = [color.view, depthStencil.view]
        var framebufferInfo = VkFramebufferCreateInfo()
        framebufferInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
        framebufferInfo.renderPass = pass
        framebufferInfo.attachmentCount = 2
        framebufferInfo.width = UInt32(width)
        framebufferInfo.height = UInt32(height)
        framebufferInfo.layers = 1
        var framebuffer: VkFramebuffer?
        views.withUnsafeMutableBufferPointer { framebufferInfo.pAttachments = UnsafePointer($0.baseAddress); _ = vkCreateFramebuffer(core.device, &framebufferInfo, nil, &framebuffer) }
        self.framebuffer = try #require(framebuffer)
        self.width = width
        self.height = height
    }

    func begin(_ cmd: VkCommandBuffer) {
        var clears = [VkClearValue(), VkClearValue()]
        clears[0].color = VkClearColorValue(float32: (0, 0, 0, 1))
        clears[1].depthStencil = VkClearDepthStencilValue(depth: 1, stencil: 0)
        var info = VkRenderPassBeginInfo()
        info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
        info.renderPass = renderPass
        info.framebuffer = framebuffer
        info.renderArea = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(width), height: UInt32(height)))
        info.clearValueCount = 2
        clears.withUnsafeBufferPointer { info.pClearValues = $0.baseAddress; vkCmdBeginRenderPass(cmd, &info, VK_SUBPASS_CONTENTS_INLINE) }
    }

    func read(_ core: VulkanCore) -> [UInt8] {
        readPixels(core, color.image, width: width, height: height)
    }

    func destroy(_ core: VulkanCore) {
        vkDestroyFramebuffer(core.device, framebuffer, nil)
        vkDestroyRenderPass(core.device, renderPass, nil)
        depthStencil.destroy(core)
        color.destroy(core)
    }
}

/// An RGBA8 image with its memory and a 2D view.
private struct TestImage {
    let image: VkImage
    let memory: VkDeviceMemory
    let view: VkImageView

    init(_ core: VulkanCore, width: Int, height: Int, usage: UInt32,
         format: VkFormat = VK_FORMAT_R8G8B8A8_UNORM, aspect: UInt32 = VK_IMAGE_ASPECT_COLOR_BIT.rawValue) throws {
        var info = VkImageCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.imageType = VK_IMAGE_TYPE_2D
        info.format = format
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
        viewInfo.format = format
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask: VkImageAspectFlags(aspect), baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1)
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

    func update(device: Device, cmd: VkCommandBuffer) {
        if case .pixels(let node) = context { node.update(device, slot: self, cmd: cmd) }
    }

    func destroyResources(device: Device) {
        if case .pixels(let node) = context { node.destroyResources(device) }
    }

    func getImageView() -> VkImageView? {
        if case .pixels(let node) = context { return node.imageView }
        return nil
    }
}
#endif
