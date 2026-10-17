import ArgumentParser
import EyeballsKit

struct AttachCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Take over as the stack's driver, so its wake-ups come to this session.")

    @Option(help: "The stack: its ID, such as s3, or any branch in it.")
    var stack: String?

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        _ = try validatedStack(stack)
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let call = AppCall(operation: .attach, agent: agent, start: .inBackground, timeout: .seconds(30))
            try call.send(AttachArguments(stack: try validatedStack(stack))).print(json: output.json)
        }
    }
}
