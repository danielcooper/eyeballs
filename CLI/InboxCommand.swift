import ArgumentParser
import EyeballsKit

struct InboxCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Print every thread that waits on you, bottom layer first.",
        discussion: "Threads shown before are included and labelled, so an interrupted inbox loses nothing.")

    @Option(help: "Show only this stack: its ID, such as s3, or any branch in it.")
    var stack: String?

    @Option(help: "The page to print, from the line that ends a long inbox.")
    var page = 1

    @Flag(help: "Show the inbox without marking anything as delivered.")
    var peek = false

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        _ = try validatedStack(stack)
        guard page >= 1 else { throw ValidationError("--page must be 1 or more.") }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let arguments = InboxArguments(stack: try validatedStack(stack), page: page, peek: peek)
            let call = AppCall(operation: .inbox, agent: agent, start: .inBackground, timeout: .seconds(60))
            try call.send(arguments).print(json: output.json)
        }
    }
}
