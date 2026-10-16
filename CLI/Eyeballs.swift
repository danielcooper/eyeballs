import ArgumentParser
import EyeballsKit
import Foundation

@main
struct Eyeballs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eyeballs",
        abstract: "Open your stack in Eyeballs for review, and act on the comments.",
        version: versionLine,
        subcommands: [
            ReviewCommand.self,
            WaitCommand.self,
            InboxCommand.self,
            ShowCommand.self,
            ReplyCommand.self,
            ThreadsCommand.self,
            StatusCommand.self,
            AttachCommand.self,
            WatchCommand.self,
            HookCommand.self,
            OpenCommand.self,
            DoctorCommand.self,
        ])

    /// For example `eyeballs 0.1.0 (42) protocol 1`.
    static var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        return "eyeballs \(version) (\(build)) protocol \(WireProtocol.version)"
    }

    /// Runs the command, mapping every error to the design's exit-code table (fix 6).
    ///
    /// swift-argument-parser's own `main()` exits 1 for any error it does not know, and Claude
    /// Code reads exit 1 as a plain failure. Here usage errors still exit 64, and anything
    /// unexpected exits 70.
    static func main() {
        var command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            if alwaysExitsZero, exitCode(for: error) != .success {
                // Hooks and status run on every turn, so even a flag from a newer plugin must not fail.
                Output.writeLine(fullMessage(for: error), to: .standardError)
                Foundation.exit(ExitStatus.success)
            }
            exit(withError: error)
        }
        do {
            try command.run()
        } catch {
            // swift-argument-parser maps only errors it does not know to EXIT_FAILURE; map those here.
            guard exitCode(for: error) == .failure else { exit(withError: error) }
            let failure = EyeballsError(error)
            Output.printFailure(failure, json: CommandLine.arguments.contains("--json"))
            Foundation.exit(failure.code.exitStatus)
        }
    }

    /// True for `hook` and `status`, which exit 0 whatever happens.
    private static var alwaysExitsZero: Bool {
        let subcommand = CommandLine.arguments.dropFirst().first
        return subcommand == HookCommand.configuration.commandName || subcommand == StatusCommand.configuration.commandName
    }
}
