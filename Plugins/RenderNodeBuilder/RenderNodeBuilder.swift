import Foundation
import PackagePlugin

/// Generates the target's `RenderNode`, the composite slot class the render
/// engine is generic over, from `render-settings.yml` in the target's folder:
///
/// ```yaml
/// imports:                       # modules the node types come from
///     - NucleantSkia
///     - NucleantThorVG
///
/// protocol: MyOwnRenderProtocol  # optional: refines RenderContainerNode
///
/// RenderNode:
///   - SkiaShaderNode:
///       observe: true            # optional, true by default
///       update: true             # optional, true by default
///       resize_to_window: true   # optional, false by default
///   - ThorShaderNode             # just the name: every option at its default
///   - ImageNode
/// ```
///
/// `NUCLEANT_RENDER_SETTINGS` in the environment, set to the absolute path of
/// another settings file, replaces the target's own: a library builds its
/// RenderNode from an app's node list instead of its default one.
@main
struct RenderNodeBuilder: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let own = target.directoryURL.appending(path: settingsFileName)
        let settings = try settingsOverride() ?? existing(own, for: target.name)
        return [
            try generateCommand(
                settings: settings,
                own: own,
                module: target.sourceModule?.moduleName ?? target.name,
                output: context.pluginWorkDirectoryURL,
                generator: context.tool(named: "RenderNodeGenerator").url
            )
        ]
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension RenderNodeBuilder: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        let listed = target.inputFiles.first { $0.url.lastPathComponent == settingsFileName }?.url
        let settings = try settingsOverride() ?? existing(listed, for: target.displayName)
        return [
            try generateCommand(
                settings: settings,
                own: listed,
                module: target.displayName,
                output: context.pluginWorkDirectoryURL,
                generator: context.tool(named: "RenderNodeGenerator").url
            )
        ]
    }
}
#endif

let settingsFileName = "render-settings.yml"

extension RenderNodeBuilder {

    /// The settings file `NUCLEANT_RENDER_SETTINGS` names, if it is set.
    func settingsOverride() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["NUCLEANT_RENDER_SETTINGS"],
              !path.isEmpty
        else { return nil }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw RenderNodeBuilderError(
                description: "NUCLEANT_RENDER_SETTINGS names \(url.path(percentEncoded: false)), which doesn't exist"
            )
        }
        return url
    }

    /// The target's own settings file, which a target using the plugin must have.
    func existing(_ settings: URL?, for target: String) throws -> URL {
        guard let settings, FileManager.default.fileExists(atPath: settings.path(percentEncoded: false)) else {
            throw RenderNodeBuilderError(
                description: "\(target) uses RenderNodeBuilder but has no \(settingsFileName) (or set NUCLEANT_RENDER_SETTINGS)"
            )
        }
        return settings
    }

    /// Runs the generator on `settings`, writing `RenderNode.swift` into the
    /// plugin's work folder, which the build compiles into the target.
    ///
    /// The target's `own` settings file is an input even while
    /// `NUCLEANT_RENDER_SETTINGS` replaces it, or SwiftPM warns about it as
    /// a file nothing handles.
    func generateCommand(settings: URL, own: URL?, module: String, output: URL, generator: URL) -> Command {
        let renderNode = output.appending(path: "RenderNode.swift")
        var inputs = [settings]
        if let own, own != settings, FileManager.default.fileExists(atPath: own.path(percentEncoded: false)) {
            inputs.append(own)
        }
        return .buildCommand(
            displayName: "Generating RenderNode from \(settings.lastPathComponent)",
            executable: generator,
            arguments: [
                settings.path(percentEncoded: false),
                "--output", renderNode.path(percentEncoded: false),
                "--module", module,
            ],
            inputFiles: inputs,
            outputFiles: [renderNode]
        )
    }
}

struct RenderNodeBuilderError: Error, CustomStringConvertible {
    let description: String
}
