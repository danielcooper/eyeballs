import ArgumentParser
import EyeballsKit

struct HookCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "For Claude Code's hooks only: session-start, stop or session-end. Always exits 0.",
        discussion: "It forwards the hook's JSON from standard input to the app, and prints what the app asks Claude Code to do. It never starts the app.")

    @Argument(help: "session-start, stop or session-end.")
    var event: String

    @OptionGroup var agent: AgentOptions

    /// Every path exits 0, because a failing hook would show an error on every turn. An event
    /// this build does not know is ignored, so a newer plugin never breaks an older command.
    func run() {
        let event = HookEvent(rawValue: event)
        guard HookEvent.all.contains(event) else { return }
        let arguments = HookArguments(event: event, input: TextInput.hookInput())
        guard let request = try? Request(operation: .hook, client: agent.identity(), arguments: arguments),
              let client = try? SocketClient.connect(to: Install.home.socket, timeout: .seconds(1)) else { return }
        defer { client.close() }

        if event == .sessionEnd {
            // SessionEnd allows about 1.5 s, so send and leave without waiting for an answer.
            try? client.send(request, timeout: .milliseconds(500))
            return
        }
        let timeout: Duration = event == .stop ? .seconds(8) : .seconds(3)
        guard let response = try? client.exchange(request, timeout: timeout),
              case .success(let result, _) = response.outcome,
              let hookOutput = result["output"], !hookOutput.isNull else { return }
        Output.writeLine(hookOutput.serialized())
    }
}
