import ArgumentParser
import EyeballsKit
import Foundation

struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a repo in the Eyeballs window, bringing it to the front.")

    @Argument(help: "The repo's folder. Defaults to the current folder.")
    var path: String?

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let folder = URL(fileURLWithPath: path ?? ".", relativeTo: workingDirectory).standardizedFileURL
            let call = AppCall(operation: .open, agent: agent, start: .inFront, timeout: .seconds(30))
            try call.send(OpenArguments(path: folder.path)).print(json: output.json)
        }
    }
}
