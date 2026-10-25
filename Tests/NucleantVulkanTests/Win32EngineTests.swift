//
//  Win32EngineTests.swift
//  NucleantVulkanTests
//
//  The engine on a Win32 window through `init(win32Instance:win32Window:…)`:
//  instance, VK_KHR_win32_surface, device, swapchain, composite pipeline, a
//  frame presented, and a texture's pixels through the GPU and back.
//
//  Needs a Vulkan driver. CI's Windows machines have no GPU, so the workflow
//  registers Mesa's software one (lavapipe) in the registry, where installed
//  drivers are; on a desktop it is the machine's own.
//
#if os(Windows)
import Testing
import WinSDK
import CVulkan
@testable import NucleantVulkan

/// One composite slot holding an `ExternalTextureNode` — the smallest node
/// that both reaches the composite and can be read back.
final class Win32TestSlot: RenderContainerNode, @unchecked Sendable {
    enum Context: RenderNodeContext {
        case texture(ExternalTextureNode<Win32TestSlot>)
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

/// A top-level window of the system STATIC class (nothing to register), never
/// shown — a surface needs a window, not a visible one.
private final class TestWindow {
    let instance: HINSTANCE
    let hwnd: HWND

    init(width: Int32, height: Int32) throws {
        instance = try #require(GetModuleHandleW(nil))
        hwnd = try #require("STATIC".withCString(encodedAs: UTF16.self) { className in
            "NucleantVulkanTests".withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(0, className, title, 0, 0, 0, width, height, nil, nil, instance, nil)
            }
        })
    }

    /// The client area, in pixels.
    var extent: VkExtent2D {
        var rect = RECT()
        GetClientRect(hwnd, &rect)
        return VkExtent2D(width: UInt32(max(rect.right - rect.left, 0)),
                          height: UInt32(max(rect.bottom - rect.top, 0)))
    }

    deinit {
        DestroyWindow(hwnd)
    }
}

/// On the main actor, as an app drives the engine — and so never alongside
/// ShaderToolsTests, which shares `VKShaderCompiler.shared` with it.
@MainActor
@Suite struct Win32EngineTests {

    @Test func engineRendersOnAWin32Window() throws {
        let window = try TestWindow(width: 160, height: 120)
        try withExtendedLifetime(window) {
            let engine = try VulkanRenderEngine<Win32TestSlot>(
                win32Instance: window.instance,
                win32Window: window.hwnd,
                getExtent: { window.extent }
            )

            // 4×4 BGRA, every pixel different.
            let width = 4, height = 4
            var pixels: [UInt8] = []
            for i in 0..<width * height {
                let blue = UInt8(i * 16), green = UInt8(255 - i * 16), red = UInt8(i * 7)
                pixels += [blue, green, red, 255]
            }
            let node = try engine.makeExternalTextureNode(width: width, height: height)
            let written = pixels.withUnsafeBytes { bytes in
                engine.writeExternalTexture(node, bgra: bytes.baseAddress!, width: width, height: height,
                                            bytesPerRow: width * 4)
            }
            #expect(written)

            engine.replace(id: 1, with: .texture(node))
            for _ in 0..<3 {
                engine.drawFrame(1.0 / 60.0)
            }
            // The frame published the node to the composite...
            #expect(engine.readable.contains(1))
            // ...and its pixels are the ones written, through the GPU.
            #expect(engine.readExternalTexture(node) == pixels)
        }
    }
}
#endif
