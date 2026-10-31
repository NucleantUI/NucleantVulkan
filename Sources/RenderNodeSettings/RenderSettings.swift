import Yams

/// What a `render-settings.yml` asks for: the modules to import, the protocol
/// the generated `RenderNode` conforms to, and its node types.
public struct RenderSettings: Equatable {
    var imports: [String] = []
    /// `RenderContainerNode`, or a protocol of the library's own that refines it.
    var conformance = "RenderContainerNode"
    var nodes: [NodeSettings] = []

    /// One `Context` case: the node type, and which of the slot's calls reach it.
    struct NodeSettings: Equatable {
        var type: String
        var observe = true
        var update = true
        var resizeToWindow = false

        /// The type without its `ShaderNode` / `Node` suffix:
        /// `SkiaShaderNode` → `Skia`, `ExternalTextureNode` → `ExternalTexture`.
        var baseName: String {
            for suffix in ["ShaderNode", "Node"] where type.hasSuffix(suffix) && type.count > suffix.count {
                return String(type.dropLast(suffix.count))
            }
            return type
        }

        /// `skia`, `externalTexture`, `vertFrag`; a leading acronym is
        /// lowered whole: `OGLShaderNode` → `ogl`, `URLImageNode` → `urlImage`.
        var caseName: String {
            let base = baseName
            let upper = base.prefix { $0.isUppercase }.count
            guard upper > 1 else { return base.prefix(1).lowercased() + base.dropFirst() }
            let next = base.dropFirst(upper).first
            let lowered = next?.isLowercase == true ? upper - 1 : upper
            return base.prefix(lowered).lowercased() + base.dropFirst(lowered)
        }

        /// The device's resize call for this type, named the way the node
        /// packages name theirs: `resizeSkiaNode`, `resizeExternalTextureNode`.
        var resizeFunction: String {
            "resize\(baseName)Node"
        }
    }
}

public struct RenderSettingsError: Error, Equatable, CustomStringConvertible {
    public var message: String
    /// Where in the settings file, when it is about one place in it.
    public var line: Int?

    public var description: String {
        line.map { "line \($0): \(message)" } ?? message
    }
}

extension RenderSettingsError {
    init(_ message: String, at node: Node?) {
        self.init(message: message, line: node?.mark?.line)
    }
}

extension RenderSettings {

    public init(yaml: String) throws {
        guard let root = try Yams.compose(yaml: yaml), let top = root.mapping else {
            throw RenderSettingsError("expected `imports`, `protocol` and `RenderNode`", at: nil)
        }
        var listsNodes = false
        for (key, value) in top {
            switch key.scalar?.string {
            case "imports":
                imports = try Self.moduleNames(in: value)
            case "protocol":
                guard let name = value.scalar?.string, Self.isName(name, dotted: true) else {
                    throw RenderSettingsError("`protocol` is the name of a protocol refining RenderContainerNode", at: value)
                }
                conformance = name
            case "RenderNode":
                listsNodes = true
                nodes = try Self.nodes(in: value)
            default:
                throw RenderSettingsError(
                    "unknown key `\(key.scalar?.string ?? "")`; expected `imports`, `protocol` or `RenderNode`",
                    at: key
                )
            }
        }
        guard listsNodes else {
            throw RenderSettingsError("missing `RenderNode`, the list of node types", at: nil)
        }
    }

    private static func moduleNames(in value: Node) throws -> [String] {
        if value.null != nil { return [] }
        guard let list = value.sequence else {
            throw RenderSettingsError("`imports` is a list of module names", at: value)
        }
        return try list.map { entry in
            guard let name = entry.scalar?.string, isName(name, dotted: true) else {
                throw RenderSettingsError("`imports` is a list of module names", at: entry)
            }
            return name
        }
    }

    private static func nodes(in value: Node) throws -> [NodeSettings] {
        guard let list = value.sequence, !list.isEmpty else {
            throw RenderSettingsError("`RenderNode` lists at least one node type", at: value)
        }
        var nodes: [NodeSettings] = []
        for entry in list {
            let node = try NodeSettings(entry)
            if let other = nodes.first(where: { $0.caseName == node.caseName }) {
                throw RenderSettingsError(
                    other.type == node.type
                        ? "\(node.type) is listed twice"
                        : "\(other.type) and \(node.type) both make the case `.\(node.caseName)`",
                    at: entry
                )
            }
            nodes.append(node)
        }
        return nodes
    }

    /// A Swift identifier, or with `dotted` several joined by dots (`Module.Type`).
    static func isName(_ name: String, dotted: Bool = false) -> Bool {
        let parts = dotted ? name.split(separator: ".", omittingEmptySubsequences: false) : [Substring(name)]
        return parts.allSatisfy { part in
            guard let first = part.first, first.isLetter || first == "_" else { return false }
            return part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }
}

extension RenderSettings.NodeSettings {

    /// `- ImageNode`, or `- SkiaShaderNode:` with options under it.
    init(_ entry: Node) throws {
        guard let mapping = entry.mapping else {
            guard let type = entry.scalar?.string, RenderSettings.isName(type) else {
                throw RenderSettingsError("a node entry is a type name, or a type name with options under it", at: entry)
            }
            self.init(type: type)
            return
        }
        guard mapping.count == 1, let (key, options) = mapping.first,
              let type = key.scalar?.string, RenderSettings.isName(type)
        else {
            throw RenderSettingsError("one node type per entry", at: entry)
        }
        self.init(type: type)
        if options.null != nil { return }
        guard let options = options.mapping else {
            throw RenderSettingsError("\(type)'s options are `observe`, `update` and `resize_to_window`", at: options)
        }
        for (option, value) in options {
            guard let flag = value.bool else {
                throw RenderSettingsError("`\(option.scalar?.string ?? "")` is true or false", at: value)
            }
            switch option.scalar?.string {
            case "observe":          observe = flag
            case "update":           update = flag
            case "resize_to_window": resizeToWindow = flag
            default:
                throw RenderSettingsError(
                    "unknown option `\(option.scalar?.string ?? "")` for \(type); expected `observe`, `update` or `resize_to_window`",
                    at: option
                )
            }
        }
    }
}
