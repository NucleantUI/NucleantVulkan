//
//  RenderNodeCheckTests.swift
//  NucleantVulkan
//
//  The RenderNode this target's render-settings.yml generates, driven
//  through a real engine on macOS: it draws its node, only observed nodes
//  mark it for a redraw, and only window-filling slots resize with the window.
//
//  The layers are never put in a window: a CAMetalLayer hands out drawables
//  with or without one, which is all a surface needs.
//
#if os(macOS)
import Testing
import QuartzCore
import Metal
import CVulkan
import NucleantVulkan

/// Compiles only while the generated cases are exactly the settings' nodes,
/// named from their types.
private func caseName(_ context: RenderNode.Context) -> String {
    switch context {
    case .externalTexture: "externalTexture"
    case .image:           "image"
    case .pixelBuffer:     "pixelBuffer"
    case .vertFrag:        "vertFrag"
    }
}

/// A layer with a drawable size, outside any window. The frame too: MoltenVK
/// reports the surface's extent from the layer's bounds.
private func makeLayer(width: Int, height: Int) -> CAMetalLayer {
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.contentsScale = 1
    resize(layer, width: width, height: height)
    return layer
}

private func resize(_ layer: CAMetalLayer, width: Int, height: Int) {
    layer.frame = CGRect(x: 0, y: 0, width: width, height: height)
    layer.drawableSize = CGSize(width: width, height: height)
}

/// 4×4 BGRA, every pixel different.
private func testPixels(seed: Int) -> [UInt8] {
    var pixels: [UInt8] = []
    for i in 0..<16 {
        pixels += [UInt8((i * 16 + seed) % 256), UInt8(255 - i * 16), UInt8(i * 7), 255]
    }
    return pixels
}

@MainActor
@Suite struct RenderNodeCheckTests {

    @Test func slotDrawsItsNode() throws {
        let engine = try VulkanRenderEngine<RenderNode>(metalLayer: makeLayer(width: 64, height: 64))
        let node = try engine.renderDevice.makeExternalTextureNode(width: 4, height: 4)
        let pixels = testPixels(seed: 7)
        let written = pixels.withUnsafeBytes { bytes in
            engine.renderDevice.writeExternalTexture(node, bgra: bytes.baseAddress!, width: 4, height: 4, bytesPerRow: 16)
        }
        #expect(written)

        engine.replace(id: 1, with: .externalTexture(node))
        let slot = try #require(engine.nodes.first)
        #expect(caseName(slot.context) == "externalTexture")
        #expect(slot.needsRender)

        engine.drawFrame(1.0 / 60.0)
        #expect(!slot.needsRender)
        #expect(engine.renderDevice.readable.contains(1))
        #expect(slot.getImageView() == node.imageView)
        #expect(engine.renderDevice.readExternalTexture(node) == pixels)

        // Not shown in the window: no image to composite.
        slot.compositesToWindow = false
        #expect(slot.getImageView() == nil)

        // The window only shows the node; its maker frees it.
        engine.remove(id: 1)
        slot.destroyResources(device: engine.renderDevice)
    }

    /// ImageNode is listed with `observe: false`, ExternalTextureNode isn't.
    @Test func onlyObservedNodesMarkTheSlot() throws {
        let engine = try VulkanRenderEngine<RenderNode>(metalLayer: makeLayer(width: 64, height: 64))
        let texture = try engine.renderDevice.makeExternalTextureNode(width: 4, height: 4)
        let image = try engine.renderDevice.makeImageNode(width: 4, height: 4, format: VK_FORMAT_B8G8R8A8_UNORM)
        engine.replace(id: 1, with: .externalTexture(texture))
        engine.replace(id: 2, with: .image(image))
        let textureSlot = try #require(engine.nodes.first { $0.id == 1 })
        let imageSlot = try #require(engine.nodes.first { $0.id == 2 })
        #expect(caseName(imageSlot.context) == "image")

        engine.drawFrame(1.0 / 60.0)
        #expect(!textureSlot.needsRender)
        #expect(!imageSlot.needsRender)

        // A change, not just a set: an equal value notifies no one.
        texture.dirty.toggle()
        image.dirty.toggle()
        #expect(textureSlot.needsRender)
        #expect(!imageSlot.needsRender)

        engine.remove(id: 1)
        engine.remove(id: 2)
        textureSlot.destroyResources(device: engine.renderDevice)
        imageSlot.destroyResources(device: engine.renderDevice)
    }

    /// ExternalTextureNode is listed with `resize_to_window: true`: a slot
    /// filling the window follows its size; a hidden one, or one with a frame
    /// of its own, keeps its size.
    @Test func windowResizeResizesFillingSlots() throws {
        let layer = makeLayer(width: 64, height: 64)
        let engine = try VulkanRenderEngine<RenderNode>(metalLayer: layer)
        let filling = try engine.renderDevice.makeExternalTextureNode(width: 64, height: 64)
        let hidden = try engine.renderDevice.makeExternalTextureNode(width: 64, height: 64)
        let placed = try engine.renderDevice.makeExternalTextureNode(width: 64, height: 64)
        engine.replace(id: 1, with: .externalTexture(filling))
        engine.replace(id: 2, with: .externalTexture(hidden))
        engine.replace(id: 3, with: .externalTexture(placed))
        try #require(engine.nodes.first { $0.id == 2 }).compositesToWindow = false
        try #require(engine.nodes.first { $0.id == 3 }).compositeRect = SIMD4(0, 0, 16, 16)

        engine.drawFrame(1.0 / 60.0)
        resize(layer, width: 32, height: 24)
        engine.drawFrame(1.0 / 60.0)

        #expect(filling.width == 32 && filling.height == 24)
        #expect(hidden.width == 64 && hidden.height == 64)
        #expect(placed.width == 64 && placed.height == 64)

        for slot in engine.nodes {
            engine.remove(id: slot.id)
            slot.destroyResources(device: engine.renderDevice)
        }
    }
}
#endif
