//
//  CompositeTests.swift
//  NucleantVulkanTests
//
//  `CompositePipeline` putting node images over each other, as a window's
//  composite does: a node image holds premultiplied colour, and a
//  translucent one goes over what is under it with its alpha applied once.
//
//  Drawn into an offscreen image rather than a swapchain, so the result can
//  be read back.
//
#if os(macOS)
import Testing
import CVulkan
import VulkanCore
import NucleantShader
@testable import NucleantVulkan

/// 4×4 BGRA, every pixel `bgra`.
private func filledTexture(
    _ bgra: [UInt8],
    on device: VulkanRenderDevice<MetalTestSlot>
) throws -> ExternalTextureNode<MetalTestSlot> {
    let pixels = Array([[UInt8]](repeating: bgra, count: 16).joined())
    let node = try device.makeExternalTextureNode(width: 4, height: 4)
    let written = pixels.withUnsafeBytes { bytes in
        device.writeExternalTexture(node, bgra: bytes.baseAddress!, width: 4, height: 4, bytesPerRow: 16)
    }
    #expect(written)
    return node
}

/// A 4×4 BGRA image to draw into and read back.
private struct Target {
    let image: VkImage
    let view: VkImageView
    let memory: VkDeviceMemory

    init(on device: VulkanRenderDevice<MetalTestSlot>) throws {
        var info = VkImageCreateInfo()
        info.sType         = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
        info.imageType     = VK_IMAGE_TYPE_2D
        info.format        = VK_FORMAT_B8G8R8A8_UNORM
        info.extent        = VkExtent3D(width: 4, height: 4, depth: 1)
        info.mipLevels     = 1
        info.arrayLayers   = 1
        info.samples       = VK_SAMPLE_COUNT_1_BIT
        info.tiling        = VK_IMAGE_TILING_OPTIMAL
        info.usage         = VkImageUsageFlags(
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue
        )
        info.sharingMode   = VK_SHARING_MODE_EXCLUSIVE
        info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
        var image: VkImage?
        try #require(vkCreateImage(device.device, &info, nil, &image) == VK_SUCCESS)
        let created = try #require(image)

        var requirements = VkMemoryRequirements()
        vkGetImageMemoryRequirements(device.device, created, &requirements)
        var alloc = VkMemoryAllocateInfo()
        alloc.sType           = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
        alloc.allocationSize  = requirements.size
        alloc.memoryTypeIndex = device.findMemoryType(
            typeFilter: requirements.memoryTypeBits,
            properties: VkMemoryPropertyFlags(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue)
        )
        var memory: VkDeviceMemory?
        try #require(vkAllocateMemory(device.device, &alloc, nil, &memory) == VK_SUCCESS)
        let allocated = try #require(memory)
        vkBindImageMemory(device.device, created, allocated, 0)

        var viewInfo = VkImageViewCreateInfo()
        viewInfo.sType    = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
        viewInfo.image    = created
        viewInfo.viewType = VK_IMAGE_VIEW_TYPE_2D
        viewInfo.format   = VK_FORMAT_B8G8R8A8_UNORM
        viewInfo.subresourceRange = VkImageSubresourceRange(
            aspectMask: VkImageAspectFlags(VK_IMAGE_ASPECT_COLOR_BIT.rawValue),
            baseMipLevel: 0, levelCount: 1, baseArrayLayer: 0, layerCount: 1
        )
        var view: VkImageView?
        try #require(vkCreateImageView(device.device, &viewInfo, nil, &view) == VK_SUCCESS)

        self.image = created
        self.view = try #require(view)
        self.memory = allocated
    }

    func destroy(on device: VulkanRenderDevice<MetalTestSlot>) {
        vkDestroyImageView(device.device, view, nil)
        vkDestroyImage(device.device, image, nil)
        vkFreeMemory(device.device, memory, nil)
    }
}

/// On the main actor, as `RenderDeviceTests` is: `VKShaderCompiler.shared`
/// is not used from two tests at once.
@MainActor
@Suite struct CompositeTests {

    /// Translucent blue at half alpha over opaque grey (200): premultiplied,
    /// the blue image holds (0, 0, 128, 128). Applied once, its alpha gives
    /// (100, 100, 228), opaque. Applied twice, the blue would be 164.
    @Test func translucentImageGoesOverOnce() throws {
        let device = try VulkanRenderDevice<MetalTestSlot>()
        let grey = try filledTexture([200, 200, 200, 255], on: device)
        let blue = try filledTexture([128, 0, 0, 128], on: device)
        let target = try Target(on: device)
        let pass = try ColorAttachmentPass(device: device.device, format: VK_FORMAT_B8G8R8A8_UNORM)
        let renderPass = try #require(pass.renderPass)
        let framebuffer = try pass.makeFramebuffer(imageView: target.view, width: 4, height: 4)

        let compiler = VKShaderCompiler.shared
        let vertex = try #require(compiler.getDefaultVertexSPIRV())
        let fragment = try #require(compiler.compile(
            source: VulkanRenderEngine<MetalTestSlot>.compositeFragmentSource,
            stage: .fragment,
            filename: "composite_test.frag"
        ))
        let composite = try CompositePipeline(
            context: device, slotCount: 1, renderPass: renderPass,
            vertSPIRV: vertex, fragSPIRV: fragment
        )
        let greySet = try composite.allocateNodeDescriptorSet()
        let blueSet = try composite.allocateNodeDescriptorSet()
        composite.updateDescriptorSet(greySet.set, imageViews: [grey.imageView])
        composite.updateDescriptorSet(blueSet.set, imageViews: [blue.imageView])

        let viewport = VkViewport(x: 0, y: 0, width: 4, height: 4, minDepth: 0, maxDepth: 1)
        let scissor = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: 4, height: 4))
        device.oneTimeSubmit { cmd in
            pass.begin(cmd, framebuffer: framebuffer, width: 4, height: 4)
            composite.record(commandBuffer: cmd, descriptorSet: greySet.set, viewport: viewport, scissor: scissor)
            composite.record(commandBuffer: cmd, descriptorSet: blueSet.set, viewport: viewport, scissor: scissor)
            vkCmdEndRenderPass(cmd)
        }

        let pixels = try #require(device.readPixels(of: target.image, width: 4, height: 4))
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let bgra = Array(pixels[pixel..<pixel + 4]).map(Int.init)
            #expect(abs(bgra[0] - 228) <= 1, "blue \(bgra)")
            #expect(abs(bgra[1] - 100) <= 1, "green \(bgra)")
            #expect(abs(bgra[2] - 100) <= 1, "red \(bgra)")
            #expect(bgra[3] == 255, "alpha \(bgra)")
        }

        vkDestroyDescriptorPool(device.device, greySet.pool, nil)
        vkDestroyDescriptorPool(device.device, blueSet.pool, nil)
        vkDestroyFramebuffer(device.device, framebuffer, nil)
        target.destroy(on: device)
        grey.destroyResources(device)
        blue.destroyResources(device)
    }
}
#endif
