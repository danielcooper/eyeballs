import ArgumentParser
import EyeballsKit
import Foundation

@main
struct Eyeballs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eyeballs",
        abstract: "Open your stack in Eyeballs for review, and act on the comments.",
        version: versionLine)

    /// For example `eyeballs 0.1.0 (42) protocol 1`.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "eyeballs \(version) (\(build)) protocol \(WireProtocol.version)"
    }
}
