//
//  RenderDeviceTests.swift
//  NucleantVulkanTests
//
//  `VulkanRenderDevice.shared` on macOS: made with no window at all, and the
//  one device every engine made from a `CAMetalLayer` presents through — so
//  one window going away leaves the others rendering.
//
//  The layers are never put in a window: a CAMetalLayer hands out drawables
//  with or without one, which is all a surface needs.
//
#if os(macOS)
import Testing
import QuartzCore
import Metal
import CVulkan
@testable import NucleantVulkan

/// One composite slot holding an `ExternalTextureNode` — the smallest node
/// that both reaches the composite and can be read back.
final class MetalTestSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case texture(ExternalTextureNode<MetalTestSlot>)
    }

    let id: Int
    let context: Context
    var needsRender = true

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {
        if case .texture(let node) = context { observe(node) }
    }

    func update(engine: Engine, cmd: VkCommandBuffer) {
        if case .texture(let node) = context { node.update(engine, slot: self, cmd: cmd) }
    }

    func destroyResources(engine: Engine) {
        if case .texture(let node) = context { node.destroyResources(engine) }
    }

    func getImageView() -> VkImageView? {
        if case .texture(let node) = context { return node.imageView }
        return nil
    }
}

/// A layer with a drawable size, outside any window. The frame too, not only
/// the drawable size: MoltenVK reports the surface's extent from the layer's
/// bounds, and a zero extent has no swapchain.
private func makeLayer(width: Int, height: Int) -> CAMetalLayer {
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.contentsScale = 1
    layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
    layer.drawableSize = CGSize(width: width, height: height)
    return layer
}

/// 4×4 BGRA, every pixel different.
private func testPixels(seed: Int) -> [UInt8] {
    var pixels: [UInt8] = []
    for i in 0..<16 {
        pixels += [UInt8((i * 16 + seed) % 256), UInt8(255 - i * 16), UInt8(i * 7), 255]
    }
    return pixels
}

/// On the main actor, as an app drives the engine — and so never alongside
/// ShaderToolsTests, which shares `VKShaderCompiler.shared` with it.
@MainActor
@Suite struct RenderDeviceTests {

    @Test func sharedDeviceNeedsNoWindow() throws {
        let device = try VulkanRenderDevice.shared
        #expect(try VulkanRenderDevice.shared === device)

        // Usable as it is: allocate against it with no surface anywhere.
        let buffer = device.createBuffer(
            size: 256,
            usage: VkBufferUsageFlags(VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue)
        )
        #expect(buffer.buffer != nil)
        #expect(buffer.memory != nil)
        buffer.destroy(device: device.device)
    }

    @Test func enginesOnTwoLayersShareTheDevice() throws {
        let first = try VulkanRenderEngine<MetalTestSlot>(metalLayer: makeLayer(width: 64, height: 48))
        let second = try VulkanRenderEngine<MetalTestSlot>(metalLayer: makeLayer(width: 32, height: 32))

        let shared = try VulkanRenderDevice.shared
        #expect(first.renderDevice === shared)
        #expect(second.renderDevice === shared)
        #expect(first.device == second.device)
        // Each window still has a surface of its own.
        #expect(first.surface != second.surface)
    }

    @Test func windowGoingAwayLeavesTheOtherRendering() throws {
        let staying = try VulkanRenderEngine<MetalTestSlot>(metalLayer: makeLayer(width: 64, height: 64))
        var leaving: VulkanRenderEngine<MetalTestSlot>? =
            try VulkanRenderEngine<MetalTestSlot>(metalLayer: makeLayer(width: 64, height: 64))

        let pixels = testPixels(seed: 3)
        let node = try staying.makeExternalTextureNode(width: 4, height: 4)
        let written = pixels.withUnsafeBytes { bytes in
            staying.writeExternalTexture(node, bgra: bytes.baseAddress!, width: 4, height: 4, bytesPerRow: 16)
        }
        #expect(written)
        staying.replace(id: 1, with: .texture(node))

        let otherPixels = testPixels(seed: 9)
        let otherNode = try #require(leaving).makeExternalTextureNode(width: 4, height: 4)
        let otherWritten = otherPixels.withUnsafeBytes { bytes in
            leaving!.writeExternalTexture(otherNode, bgra: bytes.baseAddress!, width: 4, height: 4, bytesPerRow: 16)
        }
        #expect(otherWritten)
        leaving!.replace(id: 2, with: .texture(otherNode))

        for _ in 0..<3 {
            staying.drawFrame(1.0 / 60.0)
            leaving!.drawFrame(1.0 / 60.0)
        }
        #expect(leaving!.readable.contains(2))

        // The window goes, its node with it — the device stays.
        leaving = nil

        for _ in 0..<3 {
            staying.drawFrame(1.0 / 60.0)
        }
        #expect(staying.readable.contains(1))
        #expect(staying.readExternalTexture(node) == pixels)
    }
}
#endif
