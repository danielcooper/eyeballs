/// `eyeballs hook session-start|stop|session-end`: Claude Code's hooks. They always exit 0.
///
/// The command forwards the hook's stdin JSON unchanged, and the app decides what to print.
public struct HookArguments: Codable, Sendable, Hashable {
    public var event: HookEvent
    /// The JSON Claude Code wrote to the hook's stdin, such as `{"session_id":"…","source":"clear"}`.
    /// Nil when stdin was empty or was not JSON.
    public var input: JSONValue?

    public init(event: HookEvent, input: JSONValue?) {
        self.event = event
        self.input = input
    }
}

public struct HookEvent: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let sessionStart: HookEvent = "session-start"
    public static let stop: HookEvent = "stop"
    public static let sessionEnd: HookEvent = "session-end"

    public static let all: [HookEvent] = [.sessionStart, .stop, .sessionEnd]
}

/// What the app returns for a hook. The command prints `output` as the hook's stdout, or
/// nothing when it is null.
public struct HookResult: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.hook/1"
    public private(set) var ok = true
    /// Claude Code's own hook output JSON. Build it with `HookOutput`.
    public var output: JSONValue?

    public init(output: JSONValue?) {
        self.output = output
    }
}

/// Claude Code's hook output shapes. Their texts carry counts and commands only, never
/// comment bodies.
public enum HookOutput {
    /// Stops the agent ending its turn: `{"decision":"block","reason":"…"}`. `reason` is cut to
    /// 300 characters.
    public static func block(reason: String) -> JSONValue {
        .object(JSONObject(["decision": .string("block"), "reason": .string(String(reason.prefix(TextBudget.stopReason)))]))
    }

    /// Adds context at session start: `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}`.
    /// `context` is cut to 600 characters.
    public static func sessionStartContext(_ context: String) -> JSONValue {
        let specific = JSONObject([
            "hookEventName": .string("SessionStart"),
            "additionalContext": .string(String(context.prefix(TextBudget.sessionStartContext))),
        ])
        return .object(JSONObject(["hookSpecificOutput": .object(specific)]))
    }
}
