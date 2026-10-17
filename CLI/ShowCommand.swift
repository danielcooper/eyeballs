import ArgumentParser
import EyeballsKit

struct ShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print one thread in full, with its code and anchor history.")

    @Argument(help: "The thread, such as t41 or 41.")
    var thread: String

    @Option(help: "Lines of context around the thread's lines. Defaults to 5.")
    var context: Int?

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        guard ThreadID(parsing: thread) != nil else { throw ValidationError("A thread ID looks like t41 or 41.") }
        if let context, !(0...100).contains(context) { throw ValidationError("--context must be between 0 and 100.") }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            guard let id = ThreadID(parsing: thread) else { throw ValidationError("A thread ID looks like t41 or 41.") }
            let call = AppCall(operation: .show, agent: agent, start: .inBackground, timeout: .seconds(60))
            try call.send(ShowArguments(thread: id, context: context)).print(json: output.json)
        }
    }
}
