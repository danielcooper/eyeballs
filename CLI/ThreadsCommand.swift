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

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let call = AppCall(operation: .threads, agent: agent, start: .never, timeout: .seconds(30))
            try call.send(ThreadsArguments(filter: ThreadFilter(rawValue: filter.rawValue))).print(json: output.json)
        }
    }
}
