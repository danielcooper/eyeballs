import ArgumentParser
import EyeballsKit

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print one status line. Always exits 0.",
        discussion: "The skill and hooks run it on every turn, so it never fails and never starts the app.")

    @Flag(help: "Print a single line.")
    var brief = false

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    /// Every path exits 0, because a failing status line would show an error on every turn.
    func run() {
        do {
            let call = AppCall(operation: .status, agent: agent, start: .never, timeout: .seconds(5))
            switch try call.send(StatusArguments(brief: brief)) {
            case .success(let result, let text):
                Output.printSuccess(result: result, text: text, json: output.json)
            case .failure(let error):
                printProblem(error)
            }
        } catch SocketClientError.notRunning {
            let result = (try? JSONValue(encoding: StatusResult.notRunning)) ?? .null
            Output.printSuccess(result: result, text: StatusResult.notRunningText, json: output.json)
        } catch {
            printProblem(EyeballsError(error))
        }
    }

    private func printProblem(_ error: EyeballsError) {
        if output.json {
            Output.writeLine((try? JSONValue(encoding: ErrorDocument(error: error)).serialized()) ?? "")
        } else {
            Output.writeLine("Eyeballs: " + TerminalText.escape(error.message))
        }
    }
}
