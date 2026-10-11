//
//  WebGPUHeaderTests.swift
//  NucleantVulkanTests
//
//  webgpu.h on the browser's WebGPU (CWgpu on wasm) and the VkImage made over
//  one of its textures (VK_NUCLEANT_webgpu_objects): a texture is drawn
//  through webgpu.h the way ThorVG's wg engine draws — vertex and index
//  buffers, a bind group of uniform, texture and sampler, an indexed draw in
//  a cleared render pass — then read back through Vulkan from the imported
//  image. The other direction too: the texture a Vulkan image is, handed to
//  webgpu.h (what Skia's Graphite draws into). Run with
//  scripts/run_wasm_tests.py (headless Chrome).
//
#if os(WASI)
import Testing
import CVulkan
import CWgpu
import VulkanCore
@testable import NucleantVulkan

@Suite(.serialized)
struct WebGPUHeaderTests {

    @Test func contextIsThePagesDevice() throws {
        let context = try #require(WgpuContext.shared)
        let target = try #require(context.makeTarget(width: 8, height: 4))
        defer { target.release() }
        let texture = OpaquePointer(target.nativeWebGPUTexture())
        #expect(wgpuTextureGetWidth(texture) == 8)
        #expect(wgpuTextureGetHeight(texture) == 4)
        #expect(wgpuTextureGetFormat(texture) == WGPUTextureFormat_BGRA8Unorm)
        #expect(WgpuContext.targetPixelOrder == .bgra8Unorm)
    }

    @Test func textureDrawnThroughWebGPUIsWhatTheImportedImageHolds() throws {
        let context = try #require(WgpuContext.shared)
        let width = 20, height = 12
        let target = try #require(context.makeTarget(width: width, height: height))
        defer { target.release() }
        try TexturedQuad(context).draw(into: target, clear: WGPUColor(r: 0.2, g: 0.4, b: 0.6, a: 1))

        let core = try VulkanCore(imageCount: 1)
        let image = try importImage(core, target)
        defer { vkDestroyImage(core.device, image, nil) }
        let pixels = readPixels(core, image, width: width, height: height)

        // BGRA bytes. Left half: the 2×2 texture, nearest-sampled, times the
        // (1, 0.5, 1, 1) tint; right half: the clear colour.
        expectPixel(pixels, width, 2, 2, [0, 0, 255, 255])       // red
        expectPixel(pixels, width, 7, 2, [0, 128, 0, 255])       // green × 0.5
        expectPixel(pixels, width, 2, 9, [255, 0, 0, 255])       // blue
        expectPixel(pixels, width, 7, 9, [255, 128, 255, 255])   // white × tint
        expectPixel(pixels, width, 15, 6, [153, 102, 51, 255])   // clear (0.2, 0.4, 0.6)
    }

    @Test func importedImageKeepsTheTextureAfterWebGPUReleasesIt() throws {
        let context = try #require(WgpuContext.shared)
        let target = try #require(context.makeTarget(width: 4, height: 4))
        try TexturedQuad(context).draw(into: target, clear: WGPUColor(r: 1, g: 0, b: 0, a: 1))

        let core = try VulkanCore(imageCount: 1)
        let image = try importImage(core, target)
        defer { vkDestroyImage(core.device, image, nil) }
        // The image's own reference keeps the texture.
        target.release()
        let pixels = readPixels(core, image, width: 4, height: 4)
        expectPixel(pixels, 4, 3, 0, [0, 0, 255, 255])
    }

    @Test func importOfAMismatchedImageFails() throws {
        let context = try #require(WgpuContext.shared)
        let target = try #require(context.makeTarget(width: 4, height: 4))
        defer { target.release() }
        let core = try VulkanCore(imageCount: 1)
        #expect(throws: ImportError.self) { try importImage(core, target, width: 8) }
        #expect(throws: ImportError.self) { try importImage(core, target, format: VK_FORMAT_R8G8B8A8_UNORM) }
    }
}

// MARK: - Export

extension WebGPUHeaderTests {

    @Test func exportedTextureIsTheImage() throws {
        let context = try #require(WgpuContext.shared)
        let core = try VulkanCore(imageCount: 1)
        let image = try ExportImage(core, width: 12, height: 6)
        defer { image.destroy(core) }
        let texture = try #require(exportTexture(core, image.image))
        defer { wgpuTextureRelease(texture) }
        #expect(wgpuTextureGetWidth(texture) == 12)
        #expect(wgpuTextureGetHeight(texture) == 6)
        #expect(wgpuTextureGetDepthOrArrayLayers(texture) == 1)
        #expect(wgpuTextureGetMipLevelCount(texture) == 1)
        #expect(wgpuTextureGetSampleCount(texture) == 1)
        #expect(wgpuTextureGetDimension(texture) == WGPUTextureDimension_2D)
        #expect(wgpuTextureGetFormat(texture) == WGPUTextureFormat_RGBA8Unorm)
        #expect(wgpuTextureGetUsage(texture) & WGPUTextureUsage_RenderAttachment != 0)

        // Drawn through webgpu.h, read through Vulkan: one texture.
        try clear(texture, context, WGPUColor(r: 1, g: 0.5, b: 0, a: 1))
        let pixels = readPixels(core, image.image, width: 12, height: 6)
        expectPixel(pixels, 12, 0, 0, [255, 128, 0, 255])
        expectPixel(pixels, 12, 11, 5, [255, 128, 0, 255])
    }

    @Test func exportedTextureOutlivesTheImage() throws {
        let context = try #require(WgpuContext.shared)
        let core = try VulkanCore(imageCount: 1)
        let image = try ExportImage(core, width: 4, height: 4)
        let texture = try #require(exportTexture(core, image.image))
        defer { wgpuTextureRelease(texture) }
        image.destroy(core)
        // Still a live texture: drawing into a destroyed one is a WebGPU
        // validation error, which fails the run.
        #expect(wgpuTextureGetWidth(texture) == 4)
        try clear(texture, context, WGPUColor(r: 0, g: 1, b: 0, a: 1))
    }

    @Test func eachExportIsItsOwnReference() throws {
        let context = try #require(WgpuContext.shared)
        let core = try VulkanCore(imageCount: 1)
        let image = try ExportImage(core, width: 4, height: 4)
        defer { image.destroy(core) }
        let first = try #require(exportTexture(core, image.image))
        let second = try #require(exportTexture(core, image.image))
        #expect(first == second)
        wgpuTextureRelease(first)
        wgpuTextureRelease(second)
        // The image keeps its own.
        try clear(try #require(exportTexture(core, image.image)), context, WGPUColor(r: 0, g: 0, b: 1, a: 1), release: true)
        let pixels = readPixels(core, image.image, width: 4, height: 4)
        expectPixel(pixels, 4, 2, 2, [0, 0, 255, 255])
    }
}

/// The WebGPU texture `image` is (VK_NUCLEANT_webgpu_objects), or nil.
private func exportTexture(_ core: VulkanCore, _ image: VkImage) -> WGPUTexture? {
    var info = VkExportWebGPUTextureInfoNUCLEANT()
    info.sType = VK_STRUCTURE_TYPE_EXPORT_WEBGPU_TEXTURE_INFO_NUCLEANT
    info.image = image
    vkExportWebGPUObjectsNUCLEANT(core.device, &info)
    return info.texture.map { OpaquePointer($0) }
}

/// Clears `texture` through webgpu.h, in a render pass of its own.
private func clear(_ texture: WGPUTexture, _ context: WgpuContext, _ color: WGPUColor, release: Bool = false) throws {
    defer { if release { wgpuTextureRelease(texture) } }
    let device: WGPUDevice = OpaquePointer(context.devicePointer)
    let queue = wgpuDeviceGetQueue(device)
    let view = try #require(wgpuTextureCreateView(texture, nil))
    defer { wgpuTextureViewRelease(view) }
    let encoder = try #require(wgpuDeviceCreateCommandEncoder(device, nil))
    defer { wgpuCommandEncoderRelease(encoder) }
    var attachment = WGPURenderPassColorAttachment()
    attachment.view = view
    attachment.depthSlice = UInt32.max
    attachment.loadOp = WGPULoadOp_Clear
    attachment.storeOp = WGPUStoreOp_Store
    attachment.clearValue = color
    let pass = try #require(withUnsafePointer(to: &attachment) { attachmentPtr in
        var descriptor = WGPURenderPassDescriptor()
        descriptor.colorAttachmentCount = 1
        descriptor.colorAttachments = attachmentPtr
        return wgpuCommandEncoderBeginRenderPass(encoder, &descriptor)
    })
    wgpuRenderPassEncoderEnd(pass)
    wgpuRenderPassEncoderRelease(pass)
    var commands: WGPUCommandBuffer? = wgpuCommandEncoderFinish(encoder, nil)
    wgpuQueueSubmit(queue, 1, &commands)
    wgpuCommandBufferRelease(commands)
}

/// An RGBA8 image a renderer draws into: render target, sampled, copyable.
private struct ExportImage {
    let image: VkImage
    let memory: VkDeviceMemory

    init(_ core: VulkanCore, width: Int, height: Int) throws {
        var info = VkImageCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.imageType = VK_IMAGE_TYPE_2D
        info.format = VK_FORMAT_R8G8B8A8_UNORM
        info.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
        info.mipLevels = 1
        info.arrayLayers = 1
        info.samples = VK_SAMPLE_COUNT_1_BIT
        info.tiling = VK_IMAGE_TILING_OPTIMAL
        info.usage = VkImageUsageFlags(VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_SAMPLED_BIT.rawValue
                                       | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        var image: VkImage?
        guard vkCreateImage(core.device, &info, nil, &image) == VK_SUCCESS, let image else { throw ImportError.failed(VK_ERROR_UNKNOWN) }
        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(core.device, image, &requirements)
        var alloc = VkMemoryAllocateInfo()
        alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        alloc.allocationSize = requirements.size
        alloc.memoryTypeIndex = core.findMemoryType(typeFilter: requirements.memoryTypeBits,
                                                    properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue))
        var memory: VkDeviceMemory?
        guard vkAllocateMemory(core.device, &alloc, nil, &memory) == VK_SUCCESS, let memory else {
            vkDestroyImage(core.device, image, nil)
            throw ImportError.failed(VK_ERROR_OUT_OF_DEVICE_MEMORY)
        }
        vkBindImageMemory(core.device, image, memory, 0)
        self.image = image
        self.memory = memory
    }

    func destroy(_ core: VulkanCore) {
        vkDestroyImage(core.device, image, nil)
        vkFreeMemory(core.device, memory, nil)
    }
}

// MARK: - Helpers

private enum ImportError: Error {
    case failed(VkResult)
}

/// A VkImage over `target`'s texture — what NucleantThorVG does on wasm.
private func importImage(
    _ core: VulkanCore, _ target: WgpuContext.Target, width: Int? = nil, format: VkFormat = VK_FORMAT_B8G8R8A8_UNORM
) throws -> VkImage {
    var importInfo = VkImportWebGPUTextureInfoNUCLEANT()
    importInfo.sType = VK_STRUCTURE_TYPE_IMPORT_WEBGPU_TEXTURE_INFO_NUCLEANT
    importInfo.texture = target.nativeWebGPUTexture()
    var image: VkImage?
    let result: VkResult = withUnsafePointer(to: &importInfo) { importPtr in
        var info = VkImageCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.pNext = UnsafeRawPointer(importPtr)
        info.imageType = VK_IMAGE_TYPE_2D
        info.format = format
        info.extent = VkExtent3D(width: UInt32(width ?? target.width), height: UInt32(target.height), depth: 1)
        info.mipLevels = 1
        info.arrayLayers = 1
        info.samples = VK_SAMPLE_COUNT_1_BIT
        info.tiling = VK_IMAGE_TILING_OPTIMAL
        info.usage = VkImageUsageFlags(VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue)
        return vkCreateImage(core.device, &info, nil, &image)
    }
    guard result == VK_SUCCESS, let image else { throw ImportError.failed(result) }
    return image
}

private func readPixels(_ core: VulkanCore, _ image: VkImage, width: Int, height: Int) -> [UInt8] {
    let byteCount = width * height * 4
    let staging = core.createBuffer(size: byteCount, usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue))
    defer { staging.destroy(device: core.device) }
    core.withOneTimeCommands { cmd in
        var region = VkBufferImageCopy()
        region.imageSubresource = VkImageSubresourceLayers(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue), mipLevel: 0, baseArrayLayer: 0, layerCount: 1)
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

private func expectPixel(
    _ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int, _ expected: [UInt8], sourceLocation: SourceLocation = #_sourceLocation
) {
    let i = (y * width + x) * 4
    let actual = Array(pixels[i..<i + 4])
    let close = zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
    #expect(close, "pixel \(x),\(y): \(actual), expected \(expected)", sourceLocation: sourceLocation)
}

private func label(_ text: StaticString) -> WGPUStringView {
    WGPUStringView(data: UnsafeRawPointer(text.utf8Start).assumingMemoryBound(to: CChar.self), length: text.utf8CodeUnitCount)
}

/// A 2×2 texture drawn over the left half of a target through webgpu.h.
private struct TexturedQuad {
    let device: WGPUDevice
    let queue: WGPUQueue

    init(_ context: WgpuContext) {
        device = OpaquePointer(context.devicePointer)
        queue = wgpuDeviceGetQueue(device)
    }

    static let shader: StaticString = """
    struct VertexOut { @builtin(position) position: vec4f, @location(0) uv: vec2f }
    @vertex fn vs(@location(0) position: vec2f, @location(1) uv: vec2f) -> VertexOut {
        var out: VertexOut;
        out.position = vec4f(position, 0.0, 1.0);
        out.uv = uv;
        return out;
    }
    @group(0) @binding(0) var<uniform> tint: vec4f;
    @group(0) @binding(1) var image: texture_2d<f32>;
    @group(0) @binding(2) var imageSampler: sampler;
    @fragment fn fs(in: VertexOut) -> @location(0) vec4f {
        return textureSample(image, imageSampler, in.uv) * tint;
    }
    """

    func draw(into target: WgpuContext.Target, clear: WGPUColor) throws {
        // Shader.
        var source = WGPUShaderSourceWGSL()
        source.chain.sType = WGPUSType_ShaderSourceWGSL
        source.code = label(Self.shader)
        let module = try #require(withUnsafeMutablePointer(to: &source.chain) { chain in
            var descriptor = WGPUShaderModuleDescriptor()
            descriptor.nextInChain = chain
            return wgpuDeviceCreateShaderModule(device, &descriptor)
        })
        defer { wgpuShaderModuleRelease(module) }

        // Vertices (position, uv) over x ∈ [-1, 0], and two triangles.
        let vertices: [Float] = [-1, 1, 0, 0,   0, 1, 1, 0,   -1, -1, 0, 1,   0, -1, 1, 1]
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3, 0, 0]   // padded to a 4-byte multiple
        let vertexBuffer = makeBuffer(vertices, usage: WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst)
        let indexBuffer = makeBuffer(indices, usage: WGPUBufferUsage_Index | WGPUBufferUsage_CopyDst)
        let tintBuffer = makeBuffer([Float](arrayLiteral: 1, 0.5, 1, 1), usage: WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst)
        defer {
            for buffer in [vertexBuffer, indexBuffer, tintBuffer] {
                wgpuBufferDestroy(buffer)
                wgpuBufferRelease(buffer)
            }
        }
        #expect(wgpuBufferGetSize(vertexBuffer) == 64)

        // A 2×2 RGBA texture: red, green / blue, white.
        var textureDescriptor = WGPUTextureDescriptor()
        textureDescriptor.usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopyDst
        textureDescriptor.dimension = WGPUTextureDimension_2D
        textureDescriptor.size = WGPUExtent3D(width: 2, height: 2, depthOrArrayLayers: 1)
        textureDescriptor.format = WGPUTextureFormat_RGBA8Unorm
        textureDescriptor.mipLevelCount = 1
        textureDescriptor.sampleCount = 1
        let texture = try #require(wgpuDeviceCreateTexture(device, &textureDescriptor))
        defer { wgpuTextureRelease(texture) }
        let texels: [UInt8] = [255, 0, 0, 255,  0, 255, 0, 255,  0, 0, 255, 255,  255, 255, 255, 255]
        var destination = WGPUTexelCopyTextureInfo()
        destination.texture = texture
        destination.aspect = WGPUTextureAspect_All
        var layout = WGPUTexelCopyBufferLayout(offset: 0, bytesPerRow: 8, rowsPerImage: 2)
        var size = WGPUExtent3D(width: 2, height: 2, depthOrArrayLayers: 1)
        texels.withUnsafeBytes { wgpuQueueWriteTexture(queue, &destination, $0.baseAddress, $0.count, &layout, &size) }
        let textureView = try #require(wgpuTextureCreateView(texture, nil))
        defer { wgpuTextureViewRelease(textureView) }

        var samplerDescriptor = WGPUSamplerDescriptor()
        samplerDescriptor.addressModeU = WGPUAddressMode_ClampToEdge
        samplerDescriptor.addressModeV = WGPUAddressMode_ClampToEdge
        samplerDescriptor.addressModeW = WGPUAddressMode_ClampToEdge
        samplerDescriptor.magFilter = WGPUFilterMode_Nearest
        samplerDescriptor.minFilter = WGPUFilterMode_Nearest
        samplerDescriptor.mipmapFilter = WGPUMipmapFilterMode_Nearest
        samplerDescriptor.lodMaxClamp = 32
        samplerDescriptor.maxAnisotropy = 1
        let sampler = try #require(wgpuDeviceCreateSampler(device, &samplerDescriptor))
        defer { wgpuSamplerRelease(sampler) }

        // Bind group layout + bind group: tint, texture, sampler.
        var layoutEntries = [WGPUBindGroupLayoutEntry](repeating: WGPUBindGroupLayoutEntry(), count: 3)
        for i in 0..<3 {
            layoutEntries[i].binding = UInt32(i)
            layoutEntries[i].visibility = WGPUShaderStage_Fragment
        }
        layoutEntries[0].buffer.type = WGPUBufferBindingType_Uniform
        layoutEntries[1].texture.sampleType = WGPUTextureSampleType_Float
        layoutEntries[1].texture.viewDimension = WGPUTextureViewDimension_2D
        layoutEntries[2].sampler.type = WGPUSamplerBindingType_Filtering
        let groupLayout = try #require(layoutEntries.withUnsafeBufferPointer { entries in
            var descriptor = WGPUBindGroupLayoutDescriptor()
            descriptor.entryCount = entries.count
            descriptor.entries = entries.baseAddress
            return wgpuDeviceCreateBindGroupLayout(device, &descriptor)
        })
        defer { wgpuBindGroupLayoutRelease(groupLayout) }

        var groupEntries = [WGPUBindGroupEntry](repeating: WGPUBindGroupEntry(), count: 3)
        groupEntries[0].binding = 0
        groupEntries[0].buffer = tintBuffer
        groupEntries[0].size = 16
        groupEntries[1].binding = 1
        groupEntries[1].textureView = textureView
        groupEntries[2].binding = 2
        groupEntries[2].sampler = sampler
        let group = try #require(groupEntries.withUnsafeBufferPointer { entries in
            var descriptor = WGPUBindGroupDescriptor()
            descriptor.layout = groupLayout
            descriptor.entryCount = entries.count
            descriptor.entries = entries.baseAddress
            return wgpuDeviceCreateBindGroup(device, &descriptor)
        })
        defer { wgpuBindGroupRelease(group) }

        var groupLayoutRef: WGPUBindGroupLayout? = groupLayout
        let pipelineLayout = try #require(withUnsafePointer(to: &groupLayoutRef) { layouts in
            var descriptor = WGPUPipelineLayoutDescriptor()
            descriptor.bindGroupLayoutCount = 1
            descriptor.bindGroupLayouts = layouts
            return wgpuDeviceCreatePipelineLayout(device, &descriptor)
        })
        defer { wgpuPipelineLayoutRelease(pipelineLayout) }

        let pipeline = try #require(makePipeline(module: module, layout: pipelineLayout))
        defer { wgpuRenderPipelineRelease(pipeline) }

        // Encode: clear, draw the quad, submit.
        let targetTexture = OpaquePointer(target.nativeWebGPUTexture())
        let targetView = try #require(wgpuTextureCreateView(targetTexture, nil))
        defer { wgpuTextureViewRelease(targetView) }
        let encoder = try #require(wgpuDeviceCreateCommandEncoder(device, nil))
        defer { wgpuCommandEncoderRelease(encoder) }
        var attachment = WGPURenderPassColorAttachment()
        attachment.view = targetView
        attachment.depthSlice = UInt32.max
        attachment.loadOp = WGPULoadOp_Clear
        attachment.storeOp = WGPUStoreOp_Store
        attachment.clearValue = clear
        let pass = try #require(withUnsafePointer(to: &attachment) { attachmentPtr in
            var descriptor = WGPURenderPassDescriptor()
            descriptor.colorAttachmentCount = 1
            descriptor.colorAttachments = attachmentPtr
            return wgpuCommandEncoderBeginRenderPass(encoder, &descriptor)
        })
        wgpuRenderPassEncoderSetPipeline(pass, pipeline)
        wgpuRenderPassEncoderSetBindGroup(pass, 0, group, 0, nil)
        wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertexBuffer, 0, wgpuBufferGetSize(vertexBuffer))
        wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuffer, WGPUIndexFormat_Uint16, 0, 12)
        wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, UInt32(target.width), UInt32(target.height))
        wgpuRenderPassEncoderDrawIndexed(pass, 6, 1, 0, 0, 0)
        wgpuRenderPassEncoderEnd(pass)
        wgpuRenderPassEncoderRelease(pass)
        var commands: WGPUCommandBuffer? = wgpuCommandEncoderFinish(encoder, nil)
        wgpuQueueSubmit(queue, 1, &commands)
        wgpuCommandBufferRelease(commands)
    }

    private func makeBuffer<T>(_ contents: [T], usage: WGPUBufferUsage) -> WGPUBuffer {
        let bytes = contents.count * MemoryLayout<T>.stride
        var descriptor = WGPUBufferDescriptor()
        descriptor.usage = usage
        descriptor.size = UInt64(bytes)
        let buffer = wgpuDeviceCreateBuffer(device, &descriptor)!
        contents.withUnsafeBytes { wgpuQueueWriteBuffer(queue, buffer, 0, $0.baseAddress, bytes) }
        return buffer
    }

    private func makePipeline(module: WGPUShaderModule, layout: WGPUPipelineLayout) -> WGPURenderPipeline? {
        var attributes = [
            WGPUVertexAttribute(nextInChain: nil, format: WGPUVertexFormat_Float32x2, offset: 0, shaderLocation: 0),
            WGPUVertexAttribute(nextInChain: nil, format: WGPUVertexFormat_Float32x2, offset: 8, shaderLocation: 1),
        ]
        return attributes.withUnsafeMutableBufferPointer { attributesPtr in
            var vertexLayout = WGPUVertexBufferLayout()
            vertexLayout.stepMode = WGPUVertexStepMode_Vertex
            vertexLayout.arrayStride = 16
            vertexLayout.attributeCount = attributesPtr.count
            vertexLayout.attributes = UnsafePointer(attributesPtr.baseAddress)
            var colorTarget = WGPUColorTargetState()
            colorTarget.format = WGPUTextureFormat_BGRA8Unorm
            colorTarget.writeMask = WGPUColorWriteMask_All
            return withUnsafePointer(to: &vertexLayout) { vertexLayoutPtr in
                withUnsafePointer(to: &colorTarget) { colorTargetPtr in
                    var fragment = WGPUFragmentState()
                    fragment.module = module
                    fragment.entryPoint = label("fs")
                    fragment.targetCount = 1
                    fragment.targets = colorTargetPtr
                    return withUnsafePointer(to: &fragment) { fragmentPtr in
                        var descriptor = WGPURenderPipelineDescriptor()
                        descriptor.layout = layout
                        descriptor.vertex.module = module
                        descriptor.vertex.entryPoint = label("vs")
                        descriptor.vertex.bufferCount = 1
                        descriptor.vertex.buffers = vertexLayoutPtr
                        descriptor.primitive.topology = WGPUPrimitiveTopology_TriangleList
                        descriptor.primitive.cullMode = WGPUCullMode_None
                        descriptor.multisample.count = 1
                        descriptor.multisample.mask = UInt32.max
                        descriptor.fragment = fragmentPtr
                        return wgpuDeviceCreateRenderPipeline(device, &descriptor)
                    }
                }
            }
        }
    }
}
#endif
