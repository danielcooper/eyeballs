import ArgumentParser
import EyeballsKit
import Foundation

struct WaitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait until the reviewer needs you. Run it in the background.",
        discussion: """
            It prints one line and exits 0 when the reviewer submits a review, sends a comment, approves or closes \
            the stack, when another session takes over, or when the timeout passes. After any exit, run eyeballs inbox. \
            It never starts the app: it waits for the app's socket, and reconnects if the app quits.
            """)

    @Option(help: "Wait only for this stack: its ID, such as s3, or any branch in it.")
    var stack: String?

    @Option(help: "Give up after this long, such as 90s, 30m or 2h. Without it, wait forever.")
    var timeout: String?

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        _ = try validatedStack(stack)
        if let timeout {
            do {
                _ = try DurationText.parse(timeout)
            } catch let error as EyeballsError {
                throw ValidationError(error.message)
            }
        }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let limit = try timeout.map(DurationText.parse)
            let deadline = limit.map { ContinuousClock.now + $0 }
            let stack = try validatedStack(stack)
            let identity = agent.identity()
            var requestID = 1

            while true {
                let remaining = deadline.map { ContinuousClock.now.duration(to: $0) }
                if let remaining, remaining <= .zero {
                    printTimeout(after: limit ?? .zero)
                    return
                }
                guard let client = try connectWhenListening(within: remaining) else { continue }
                defer { client.close() }
                let arguments = WaitArguments(stack: stack, timeoutSeconds: remaining.map { Int(max(1, $0.components.seconds)) })
                let request = try Request(id: requestID, operation: .wait, client: identity, arguments: arguments)
                requestID += 1
                do {
                    try client.exchange(request, timeout: remaining.map { $0 + .seconds(5) }).outcome.print(json: output.json)
                    return
                } catch SocketClientError.closedBeforeResponse {
                    // The app quit while we waited. Wait for it to come back.
                    Thread.sleep(forTimeInterval: 1)
                } catch SocketClientError.timedOut {
                    printTimeout(after: limit ?? .zero)
                    return
                }
            }
        }
    }

    /// A client once the app's socket answers, or nil after up to a second while the app is not
    /// running. Any other connection error, such as a sandbox block, ends the wait.
    private func connectWhenListening(within remaining: Duration?) throws -> SocketClient? {
        do {
            return try SocketClient.connect(to: Install.home.socket, timeout: .seconds(1))
        } catch SocketClientError.notRunning {
            let pause = min(remaining ?? .seconds(1), .seconds(1))
            Thread.sleep(forTimeInterval: Double(pause.components.seconds) + Double(pause.components.attoseconds) / 1e18)
            return nil
        }
    }

    private func printTimeout(after limit: Duration) {
        let event = WaitEvent.timeoutEvent(after: limit, stack: nil)
        Output.printSuccess(result: event.result, text: event.text, json: output.json)
    }
}
