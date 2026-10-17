import ArgumentParser
import EyeballsKit

struct ThreadsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "threads",
        abstract: "Print one line per thread.")

    enum Filter: String, EnumerableFlag {
        case open
        case all

        static func help(for value: Filter) -> ArgumentHelp? {
            switch value {
            case .open: "Only open threads. This is the default."
            case .all: "Resolved threads too."
            }
        }
    }

    @Flag(exclusivity: .exclusive)
    var filter: Filter = .open

    @Option(help: "Show only this stack: its ID, such as s3, or any branch in it.")
    var stack: String?

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        _ = try validatedStack(stack)
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let call = AppCall(operation: .threads, agent: agent, start: .never, timeout: .seconds(30))
            let arguments = ThreadsArguments(filter: ThreadFilter(rawValue: filter.rawValue), stack: try validatedStack(stack))
            try call.send(arguments).print(json: output.json)
        }
    }
}
