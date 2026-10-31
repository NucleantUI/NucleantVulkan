import Foundation
import RenderNodeSettings

/// `RenderNodeGenerator <render-settings.yml> --output <RenderNode.swift> [--module <name>]`
///
/// Run by the RenderNodeBuilder plugin. Errors come out as
/// `<file>:<line>: error: <message>`, so the build shows them on the line
/// of the settings file they are about.
@main
struct RenderNodeGenerator {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let settingsPath = arguments.first, let output = option("--output", in: arguments) else {
            fail("usage: RenderNodeGenerator <render-settings.yml> --output <RenderNode.swift> [--module <name>]")
        }
        let settingsURL = URL(fileURLWithPath: settingsPath)
        do {
            let settings = try RenderSettings(yaml: String(contentsOf: settingsURL, encoding: .utf8))
            let source = settings.renderNodeSource(
                module: option("--module", in: arguments),
                settingsName: settingsURL.lastPathComponent
            )
            try source.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
        } catch let error as RenderSettingsError {
            fail("\(settingsPath):\(error.line.map { "\($0):" } ?? "") error: \(error.message)")
        } catch {
            fail("\(settingsPath): error: \(error)")
        }
    }

    static func option(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
