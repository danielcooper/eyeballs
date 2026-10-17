import ArgumentParser
import EyeballsKit
import Foundation

struct ReviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "Submit a new revision of your stack and open it in Eyeballs.",
        discussion: "Commit your work first: Eyeballs reviews commits, not uncommitted changes. The last line of the output says what to do next.")

    @Option(help: "The stack: its ID, such as s3, or the name of any branch in it.")
    var stack: String?

    @Option(help: "Review this one branch.")
    var branch: String?

    @Option(help: "Review these branches as a stack, bottom layer first, separated by commas.")
    var branches: String?

    @Option(help: "The trunk for --branch or --branches. Defaults to origin/HEAD, then main.")
    var trunk: String?

    @Option(help: "What changed, in 1 to 5 lines.")
    var note: String?

    @Option(name: .customLong("note-file"), help: "Read the note from a file, or - for standard input.")
    var noteFile: String?

    @Flag(help: "Take keyboard focus when the window comes to the front.")
    var focus = false

    @Flag(help: "Submit even when threads you were shown have no reply yet.")
    var force = false

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        guard [stack, branch, branches].compactMap({ $0 }).count <= 1 else {
            throw ValidationError("Name the stack one way only: --stack, --branch or --branches.")
        }
        if trunk != nil, branch == nil, branches == nil {
            throw ValidationError("--trunk works only with --branch or --branches.")
        }
        if note != nil, noteFile != nil {
            throw ValidationError("Give the note with --note or --note-file, not both.")
        }
        _ = try validatedStack(stack)
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let arguments = ReviewArguments(
                stack: try validatedStack(stack),
                branch: branch,
                branches: branches.map { $0.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } },
                trunk: trunk,
                note: try note ?? noteFile.map { try TextInput.read($0, option: "--note-file", limit: WireLimits.maximumBodyBytes) },
                focus: focus,
                force: force)
            try arguments.validate()
            let call = AppCall(operation: .review, agent: agent, start: .inBackground, timeout: .seconds(120))
            try call.send(arguments).print(json: output.json)
        }
    }
}
