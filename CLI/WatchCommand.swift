import ArgumentParser
import EyeballsKit
import Foundation

struct WatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "For the plugin monitor only. Prints one line per event and never exits.",
        discussion: "Events that arrive within 3 s share one line. It reconnects after 1 to 30 s when the app goes away, and never starts the app.")

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    /// Never returns. A monitor that exits sends Claude a notification, so errors only pause it.
    func run() {
        let identity = agent.identity()
        var backoff: Duration = .seconds(1)
        var requestID = 1
        while true {
            let connectedAt = ContinuousClock.now
            if let client = try? SocketClient.connect(to: Install.home.socket, timeout: .seconds(1)),
               let request = try? Request(id: requestID, operation: .watch, client: identity, arguments: WatchArguments()),
               (try? client.send(request, timeout: .seconds(5))) != nil {
                requestID += 1
                printEvents(from: client)
                client.close()
            }
            if ContinuousClock.now - connectedAt > .seconds(30) { backoff = .seconds(1) }
            Thread.sleep(forTimeInterval: Double(backoff.components.seconds))
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    /// Prints events until the connection ends or the app answers with an error.
    private func printEvents(from client: SocketClient) {
        while let first = try? client.receive(timeout: nil), case .success(let result, let text) = first.outcome {
            if output.json {
                Output.writeLine(result.serialized())
                continue
            }
            var lines = [text]
            let windowEnds = ContinuousClock.now + WatchLine.mergeWindow
            while case let remaining = ContinuousClock.now.duration(to: windowEnds), remaining > .zero,
                  let next = try? client.receive(timeout: remaining), case .success(_, let more) = next.outcome {
                lines.append(more)
            }
            Output.writeLine(TerminalText.escape(WatchLine.merge(lines)))
        }
    }
}
