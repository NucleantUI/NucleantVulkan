#if canImport(RenderNodeSettings)
import Testing
@testable import RenderNodeSettings

@Suite struct RenderSettingsTests {

    @Test func readsThePlansSettings() throws {
        let settings = try RenderSettings(yaml: """
            imports:
                - NucleantUI
                - NucleantSkia
                - NucleantThorVG

            # optional only if we completely wanna override more behavior of NucleantContainerNode
            protocol: MyOwnRenderProtocol # inherits NucleantContainerNode protocol ofc..


            RenderNode:
              - SkiaShaderNode:
                  observe: true # optional just true by default
                  update: true # optional just true by default
                  resize_to_window: true # optional just false by default
              - ThorShaderNode # if just string then all is default
              - ComputeShaderNode

              - VertFragShaderNode
              - ImageNode
              - ExternalTextureNode
              - RenderTextureNode
            """)
        #expect(settings == RenderSettings(
            imports: ["NucleantUI", "NucleantSkia", "NucleantThorVG"],
            conformance: "MyOwnRenderProtocol",
            nodes: [
                .init(type: "SkiaShaderNode", resizeToWindow: true),
                .init(type: "ThorShaderNode"),
                .init(type: "ComputeShaderNode"),
                .init(type: "VertFragShaderNode"),
                .init(type: "ImageNode"),
                .init(type: "ExternalTextureNode"),
                .init(type: "RenderTextureNode"),
            ]
        ))
    }

    @Test func importsAndProtocolAreOptional() throws {
        let settings = try RenderSettings(yaml: """
            imports:
            RenderNode:
              - ImageNode:
            """)
        #expect(settings == RenderSettings(nodes: [.init(type: "ImageNode")]))
    }

    @Test(arguments: [
        ("SkiaShaderNode", "skia", "resizeSkiaNode"),
        ("ThorShaderNode", "thor", "resizeThorNode"),
        ("VertFragShaderNode", "vertFrag", "resizeVertFragNode"),
        ("ExternalTextureNode", "externalTexture", "resizeExternalTextureNode"),
        ("OGLShaderNode", "ogl", "resizeOGLNode"),
        ("URLImageNode", "urlImage", "resizeURLImageNode"),
        ("Node", "node", "resizeNodeNode"),
        ("Canvas", "canvas", "resizeCanvasNode"),
    ])
    func namesFromTheType(type: String, caseName: String, resizeFunction: String) {
        let node = RenderSettings.NodeSettings(type: type)
        #expect(node.caseName == caseName)
        #expect(node.resizeFunction == resizeFunction)
    }

    @Test(arguments: [
        ("foo: 1\nRenderNode:\n  - ImageNode\n",
         "unknown key `foo`; expected `imports`, `protocol`, `RenderNode`", 1),
        ("RenderNode:\n  - SkiaShaderNode:\n      resize_to_widow: true\n",
         "unknown key `resize_to_widow`; expected `observe`, `update`, `resize_to_window`", 3),
        ("RenderNode:\n  - ImageNode:\n      observe: maybe\n",
         "`RenderNode[0].ImageNode.observe`: Expected to decode Bool but found Scalar instead.", nil),
        ("RenderNode: []\n",
         "`RenderNode` lists at least one node type", nil),
        ("RenderNode:\n  - ImageNode\n  - ImageNode\n",
         "ImageNode is listed twice", nil),
        ("RenderNode:\n  - SkiaShaderNode\n  - SkiaNode\n",
         "SkiaShaderNode and SkiaNode both make the case `.skia`", nil),
        ("RenderNode:\n  - Image Node\n",
         "a node entry is a type name, or a type name with options under it", 2),
        ("RenderNode:\n  - ImageNode:\n    SkiaShaderNode:\n",
         "one node type per entry", 2),
        ("RenderNode:\n  - ImageNode: true\n",
         "`RenderNode[0].ImageNode`: Expected to decode Mapping but found Node instead.", nil),
        ("imports: NucleantSkia\nRenderNode:\n  - ImageNode\n",
         "`imports`: Expected to decode Sequence but found Node instead.", nil),
        ("protocol: [A, B]\nRenderNode:\n  - ImageNode\n",
         "`protocol`: Expected to decode Scalar but found Sequence instead.", nil),
    ] as [(String, String, Int?)])
    func pointsAtTheMistake(yaml: String, message: String, line: Int?) {
        #expect(throws: RenderSettingsError(message: message, line: line)) {
            try RenderSettings(yaml: yaml)
        }
    }

    @Test func needsTheNodeList() {
        #expect(throws: RenderSettingsError(message: "missing `RenderNode`, the list of node types", line: nil)) {
            try RenderSettings(yaml: "imports:\n  - NucleantSkia\n")
        }
    }
}

@Suite struct RenderNodeSourceTests {

    @Test func generatesTheRenderNode() throws {
        let settings = try RenderSettings(yaml: """
            imports:
                - NucleantUI
                - NucleantSkia
                - NucleantVulkan

            RenderNode:
              - SkiaShaderNode:
                  resize_to_window: true
              - ImageNode:
                  observe: false
              - ExternalTextureNode:
                  update: false
            """)
        // NucleantUI is the module it is generated into, and NucleantVulkan
        // is always imported: neither is imported twice.
        let source = settings.renderNodeSource(module: "NucleantUI", settingsName: "render-settings.yml")
        #expect(source == """
            // Generated by RenderNodeBuilder from render-settings.yml. Edit that file, not this one.

            import NucleantVulkan
            import CVulkan
            import NucleantSkia

            public final class RenderNode: RenderContainerNode, @unchecked Sendable {

                public enum Context: RenderNodeContext {
                    case skia(SkiaShaderNode<RenderNode>)
                    case image(ImageNode<RenderNode>)
                    case externalTexture(ExternalTextureNode<RenderNode>)
                }

                public let id: Int
                public let context: Context
                public var needsRender = true
                public var compositesToWindow = true
                public var compositeRect: SIMD4<Double>?
                public var compositeScissor: SIMD4<Double>?

                public init(id: Int, context: Context) {
                    self.id = id
                    self.context = context
                }

                public func observeContext() {
                    switch context {
                    case .skia(let node):
                        observe(node)
                    case .externalTexture(let node):
                        observe(node)
                    case .image:
                        break
                    }
                }

                public func update(device: Device, cmd: VkCommandBuffer) {
                    guard needsRender else { return }
                    switch context {
                    case .skia(let node):
                        node.update(device, slot: self, cmd: cmd)
                    case .image(let node):
                        node.update(device, slot: self, cmd: cmd)
                    case .externalTexture:
                        break
                    }
                    needsRender = false
                }

                public func destroyResources(device: Device) {
                    switch context {
                    case .skia(let node):
                        node.destroyResources(device)
                    case .image(let node):
                        node.destroyResources(device)
                    case .externalTexture(let node):
                        node.destroyResources(device)
                    }
                }

                public func getImageView() -> VkImageView? {
                    guard compositesToWindow else { return nil }
                    switch context {
                    case .skia(let node):
                        return node.imageView
                    case .image(let node):
                        return node.imageView
                    case .externalTexture(let node):
                        return node.imageView
                    }
                }

                public func resizeToFitWindow(width: Int, height: Int, device: Device) {
                    guard compositesToWindow && compositeRect == nil else { return }
                    switch context {
                    case .skia(let node):
                        device.resizeSkiaNode(node, id: id, width: width, height: height)
                    case .image, .externalTexture:
                        break
                    }
                }
            }

            """)
    }

    @Test func conformsToTheSettingsProtocol() throws {
        let settings = try RenderSettings(yaml: "protocol: MyOwnRenderProtocol\nRenderNode:\n  - ImageNode\n")
        let source = settings.renderNodeSource(module: nil, settingsName: "render-settings.yml")
        #expect(source.contains("public final class RenderNode: MyOwnRenderProtocol, @unchecked Sendable {"))
    }

    /// No node resizes with the window: the protocol's own no-op stays.
    @Test func leavesResizeToTheProtocol() throws {
        let settings = try RenderSettings(yaml: "RenderNode:\n  - ImageNode\n  - ThorShaderNode\n")
        let source = settings.renderNodeSource(module: nil, settingsName: "render-settings.yml")
        #expect(!source.contains("resizeToFitWindow"))
    }

    /// Nothing observed: an empty `observeContext`, not a switch of breaks.
    @Test func skipsAnEmptySwitch() throws {
        let settings = try RenderSettings(yaml: "RenderNode:\n  - ImageNode:\n      observe: false\n")
        let source = settings.renderNodeSource(module: nil, settingsName: "render-settings.yml")
        #expect(source.contains("    public func observeContext() {\n    }\n"))
    }
}
#endif
