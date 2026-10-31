//
//  RenderDeviceTests.swift
//  NucleantVulkanTests
//
//  `VulkanRenderDevice` on macOS: made with no window at all, rendering and
//  reading back node work on its own, and shared by every engine it is
//  handed to — so one node shows in several windows, and one window going
//  away leaves the others (and the node) as they were.
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

/// One composite slot holding an `ExternalTextureNode` (written from the
/// CPU, readable back) or an `ImageNode` (filled by a copy the device's
/// render records).
final class MetalTestSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case texture(ExternalTextureNode<MetalTestSlot>)
        case image(ImageNode<MetalTestSlot>)
    }

    let id: Int
    let context: Context
    var needsRender = true

    init(id: Int, context: Context) {
        self.id = id
        self.context = context
    }

    func observeContext() {
        switch context {
        case .texture(let node): observe(node)
        case .image(let node):   observe(node)
        }
    }

    func update(device: Device, cmd: VkCommandBuffer) {
        switch context {
        case .texture(let node): node.update(device, slot: self, cmd: cmd)
        case .image(let node):   node.update(device, slot: self, cmd: cmd)
        }
    }

    func destroyResources(device: Device) {
        switch context {
        case .texture(let node): node.destroyResources(device)
        case .image(let node):   node.destroyResources(device)
        }
    }

    func getImageView() -> VkImageView? {
        switch context {
        case .texture(let node): node.imageView
        case .image(let node):   node.imageView
        }
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

/// A 4×4 external texture holding `pixels`.
private func writtenTexture(
    _ pixels: [UInt8],
    on device: VulkanRenderDevice<MetalTestSlot>
) throws -> ExternalTextureNode<MetalTestSlot> {
    let node = try device.makeExternalTextureNode(width: 4, height: 4)
    let written = pixels.withUnsafeBytes { bytes in
        device.writeExternalTexture(node, bgra: bytes.baseAddress!, width: 4, height: 4, bytesPerRow: 16)
    }
    #expect(written)
    return node
}

/// On the main actor, as an app drives the engine — and so never alongside
/// ShaderToolsTests, which shares `VKShaderCompiler.shared` with it.
@MainActor
@Suite struct RenderDeviceTests {

    @Test func deviceRendersWithNoWindow() throws {
        let device = try VulkanRenderDevice<MetalTestSlot>()
        let pixels = testPixels(seed: 5)
        let source = try writtenTexture(pixels, on: device)

        // A node whose content only a render produces: a copy out of the
        // source, recorded by its update.
        let copy = try device.makeImageNode(
            width: 4, height: 4,
            format: VK_FORMAT_B8G8R8A8_UNORM,
            viewFormat: VK_FORMAT_B8G8R8A8_UNORM
        )
        copy.pendingCopy = ImageCopy(source: source.image, sourceX: 0, sourceY: 0, x: 0, y: 0, width: 4, height: 4)
        let slots: [MetalTestSlot] = [.new(id: 1, context: .texture(source)), .new(id: 2, context: .image(copy))]

        #expect(device.readPixels(of: copy, id: 2) == nil)
        device.render(slots)

        #expect(device.readable.contains(1))
        #expect(device.readable.contains(2))
        #expect(device.readPixels(of: copy, id: 2) == pixels)

        for slot in slots { slot.destroyResources(device: device) }
    }

    @Test func enginesShareTheDeviceTheyAreGiven() throws {
        let device = try VulkanRenderDevice<MetalTestSlot>()
        let first = try VulkanRenderEngine<MetalTestSlot>(device: device, metalLayer: makeLayer(width: 64, height: 48))
        let second = try VulkanRenderEngine<MetalTestSlot>(device: device, metalLayer: makeLayer(width: 32, height: 32))

        #expect(first.renderDevice === device)
        #expect(second.renderDevice === device)
        // Each window still has a surface of its own.
        #expect(first.surface != second.surface)
    }

    @Test func engineWithoutADeviceMakesItsOwn() throws {
        let first = try VulkanRenderEngine<MetalTestSlot>(metalLayer: makeLayer(width: 32, height: 32))
        let second = try VulkanRenderEngine<MetalTestSlot>(metalLayer: makeLayer(width: 32, height: 32))
        #expect(first.renderDevice !== second.renderDevice)
    }

    @Test func oneNodeShowsInTwoWindows() throws {
        let device = try VulkanRenderDevice<MetalTestSlot>()
        let staying = try VulkanRenderEngine<MetalTestSlot>(device: device, metalLayer: makeLayer(width: 64, height: 64))
        var leaving: VulkanRenderEngine<MetalTestSlot>? =
            try VulkanRenderEngine<MetalTestSlot>(device: device, metalLayer: makeLayer(width: 64, height: 64))

        let pixels = testPixels(seed: 3)
        let node = try writtenTexture(pixels, on: device)
        staying.replace(id: 1, with: .texture(node))
        leaving!.replace(id: 1, with: .texture(node))

        for _ in 0..<3 {
            staying.drawFrame(1.0 / 60.0)
            leaving!.drawFrame(1.0 / 60.0)
        }
        #expect(device.readable.contains(1))

        // The window goes; the node is the device's, so it stays — for its
        // owner, and for the window still showing it.
        leaving = nil

        for _ in 0..<3 {
            staying.drawFrame(1.0 / 60.0)
        }
        #expect(device.readable.contains(1))
        #expect(device.readExternalTexture(node) == pixels)

        staying.remove(id: 1)
        node.destroyResources(device)
    }
}
#endif
