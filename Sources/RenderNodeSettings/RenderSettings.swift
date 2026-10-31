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

extension RenderSettings {

    /// Decodes a settings file. What decoding leaves unchecked is checked
    /// here: the names are Swift names, and every node type makes a case of
    /// its own.
    public init(yaml: String) throws {
        do {
            self = try YAMLDecoder().decode(RenderSettings.self, from: yaml)
        } catch let error as DecodingError {
            throw RenderSettingsError(error)
        }
        guard !nodes.isEmpty else {
            throw RenderSettingsError(message: "`RenderNode` lists at least one node type")
        }
        for (index, node) in nodes.enumerated() {
            if let other = nodes[..<index].first(where: { $0.caseName == node.caseName }) {
                throw RenderSettingsError(message: other.type == node.type
                    ? "\(node.type) is listed twice"
                    : "\(other.type) and \(node.type) both make the case `.\(node.caseName)`")
            }
        }
        for name in imports where !Self.isName(name, dotted: true) {
            throw RenderSettingsError(message: "`\(name)` in `imports` is not a module name")
        }
        guard Self.isName(conformance, dotted: true) else {
            throw RenderSettingsError(message: "`protocol` is the name of a protocol refining RenderContainerNode")
        }
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

extension RenderSettings: Decodable {

    enum CodingKeys: String, CodingKey, CaseIterable {
        case imports
        case conformance = "protocol"
        case nodes = "RenderNode"
    }

    public init(from decoder: Decoder) throws {
        try SettingsKey.refuseUnknownKeys(in: decoder, expected: CodingKeys.allCases.map(\.rawValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.nodes) else {
            throw RenderSettingsError(message: "missing `RenderNode`, the list of node types")
        }
        imports = try container.decodeIfPresent([String].self, forKey: .imports) ?? []
        conformance = try container.decodeIfPresent(String.self, forKey: .conformance) ?? "RenderContainerNode"
        nodes = try container.decode([NodeSettings].self, forKey: .nodes)
    }
}

extension RenderSettings.NodeSettings: Decodable {

    /// `- ImageNode`, or `- SkiaShaderNode:` with its options under it.
    init(from decoder: Decoder) throws {
        let line = decoder.mark?.line
        if let type = try? decoder.singleValueContainer().decode(String.self) {
            guard RenderSettings.isName(type) else {
                throw RenderSettingsError(message: "a node entry is a type name, or a type name with options under it", line: line)
            }
            self.init(type: type)
            return
        }
        let entry = try decoder.container(keyedBy: SettingsKey.self)
        guard entry.allKeys.count == 1, let key = entry.allKeys.first, RenderSettings.isName(key.stringValue) else {
            throw RenderSettingsError(message: "one node type per entry", line: line)
        }
        let options = try entry.decodeIfPresent(Options.self, forKey: key)
        self.init(
            type: key.stringValue,
            observe: options?.observe ?? true,
            update: options?.update ?? true,
            resizeToWindow: options?.resizeToWindow ?? false
        )
    }

    struct Options: Decodable {
        var observe: Bool?
        var update: Bool?
        var resizeToWindow: Bool?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case observe
            case update
            case resizeToWindow = "resize_to_window"
        }

        init(from decoder: Decoder) throws {
            try SettingsKey.refuseUnknownKeys(in: decoder, expected: CodingKeys.allCases.map(\.rawValue))
            let container = try decoder.container(keyedBy: CodingKeys.self)
            observe = try container.decodeIfPresent(Bool.self, forKey: .observe)
            update = try container.decodeIfPresent(Bool.self, forKey: .update)
            resizeToWindow = try container.decodeIfPresent(Bool.self, forKey: .resizeToWindow)
        }
    }
}

/// Any key: a node entry's type name, and a typo, which decoding would
/// otherwise skip without a word.
struct SettingsKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    static func refuseUnknownKeys(in decoder: Decoder, expected: [String]) throws {
        let keys = try decoder.container(keyedBy: SettingsKey.self).allKeys
        if let unknown = keys.first(where: { !expected.contains($0.stringValue) }) {
            throw RenderSettingsError(
                message: "unknown key `\(unknown.stringValue)`; expected \(expected.map { "`\($0)`" }.joined(separator: ", "))",
                line: decoder.mark?.line
            )
        }
    }
}

extension RenderSettingsError {
    init(message: String) {
        self.init(message: message, line: nil)
    }

    /// The decoder's own complaint, with the key path it is about. One the
    /// settings types threw themselves comes back as it was: YAMLDecoder
    /// wraps whatever a `Decodable` throws.
    init(_ error: DecodingError) {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .keyNotFound(_, let c), .dataCorrupted(let c):
            context = c
        @unknown default:
            self.init(message: "\(error)")
            return
        }
        if let own = context.underlyingError as? RenderSettingsError {
            self = own
            return
        }
        let dotted = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        let path = dotted.hasPrefix(".") ? String(dotted.dropFirst()) : dotted
        self.init(message: path.isEmpty ? context.debugDescription : "`\(path)`: \(context.debugDescription)")
    }
}
