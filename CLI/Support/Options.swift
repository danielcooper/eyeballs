import ArgumentParser
import EyeballsKit
import Foundation

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print the result as JSON.")
    var json = false
}

/// `--agent` and `--session`, which override what the environment says about the agent.
struct AgentOptions: ParsableArguments {
    @Option(help: "The agent's name, such as claude or codex. Overrides CLAUDECODE and CODEX_THREAD_ID.")
    var agent: String?

    @Option(help: "The agent's session ID. Overrides CLAUDE_CODE_SESSION_ID and CODEX_THREAD_ID.")
    var session: String?

    func validate() throws {
        if let agent, !AgentIdentity.isValidAgentName(agent) {
            throw ValidationError("--agent must be 1 to 32 lowercase letters, digits, dashes, underscores or dots.")
        }
        if let session, !AgentIdentity.isValidSession(session) {
            throw ValidationError("--session must be 1 to 256 characters, with no control characters.")
        }
    }

    func identity() -> ClientIdentity {
        AgentIdentity.current(agent: agent, session: session)
    }
}

/// Where this build of the command finds the app.
enum Install {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    static let home = EyeballsHome.current(debug: isDebug)

    /// The name agents run, which the permission rule names.
    static var commandName: String { isDebug ? "eyeballs-debug" : "eyeballs" }

    static func connector() -> AppConnector {
        AppConnector(home: home, app: AppBundle.current())
    }
}

/// One request to the app from a command.
struct AppCall {
    var operation: OperationName
    var agent: AgentOptions
    /// Only commands that may start the app pass a mode other than `.never`.
    var start: AppConnector.Start
    var timeout: Duration?

    func send(_ arguments: some Encodable) throws -> Response.Outcome {
        let request = try Request(operation: operation, client: agent.identity(), arguments: arguments)
        let client = try Install.connector().connect(start: start)
        defer { client.close() }
        return try client.exchange(request, timeout: timeout).outcome
    }
}

func validatedStack(_ text: String?) throws -> StackReference? {
    guard let text else { return nil }
    guard let reference = StackReference(parsing: text) else {
        throw ValidationError("--stack takes a stack ID such as s3, or the name of a branch in the stack.")
    }
    return reference
}
