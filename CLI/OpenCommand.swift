import ArgumentParser
import EyeballsKit
import Foundation

struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Bring the Eyeballs window to the front, or open a repo in it.",
        discussion: "Without a folder, it shows the stack you are working on and adds nothing. With one, it opens that repo's stack.")

    @Argument(help: "A repo's folder, to open its stack in Eyeballs.")
    var path: String?

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let folder = path.map { URL(fileURLWithPath: $0, relativeTo: workingDirectory).standardizedFileURL.path }
            let call = AppCall(operation: .open, agent: agent, start: .inFront, timeout: .seconds(30))
            try call.send(OpenArguments(path: folder)).print(json: output.json)
        }
    }
}
