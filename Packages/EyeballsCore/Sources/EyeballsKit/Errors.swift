/// An error the app or the `eyeballs` command reports to the agent.
///
/// On the wire it is `{"code":"…","message":"…","hint":"…","retry_after_s":10}`. `message` says
/// what went wrong and `hint` says what to do next. Neither ever quotes a value that failed
/// validation, because both reach logs and the agent's context.
public struct EyeballsError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String
    public var hint: String?
    public var retryAfterSeconds: Int?

    public init(_ code: ErrorCode, _ message: String, hint: String? = nil, retryAfterSeconds: Int? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// Wraps any error, so every failure reaches the agent with a code and an exit status.
    /// An error Eyeballs does not know becomes `internal`, which exits 70.
    public init(_ error: any Error) {
        switch error {
        case let error as EyeballsError:
            self = error
        case let error as SocketClientError:
            self = error.eyeballsError
        case let error as JSONParseError:
            self = EyeballsError(.badInput, error.description)
        default:
            self = EyeballsError(.internalError, "Eyeballs hit an unexpected error.", hint: "Tell the reviewer, quoting this line.")
        }
    }

    public static func badInput(_ message: String, hint: String? = nil) -> EyeballsError {
        EyeballsError(.badInput, message, hint: hint)
    }

    public var description: String { "\(code.rawValue): \(message)" }

    enum CodingKeys: String, CodingKey {
        case code, message, hint
        case retryAfterSeconds = "retry_after_s"
    }
}

/// The error codes in the design's exit-code table. Codes added later decode too, and exit 70.
public struct ErrorCode: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let notARepo: ErrorCode = "not_a_repo"
    public static let noStack: ErrorCode = "no_stack"
    public static let unknownThread: ErrorCode = "unknown_thread"
    public static let badInput: ErrorCode = "bad_input"
    public static let unsupportedCatalog: ErrorCode = "unsupported_catalog"
    public static let appUnavailable: ErrorCode = "app_unavailable"
    public static let sandboxBlocked: ErrorCode = "sandbox_blocked"
    public static let internalError: ErrorCode = "internal"
    public static let midOperation: ErrorCode = "mid_operation"
    public static let unreplied: ErrorCode = "unreplied"
    public static let versionMismatch: ErrorCode = "version_mismatch"

    /// The process exit status for this code. Anything not in the table exits 70 (fix 6).
    public var exitStatus: Int32 {
        switch self {
        case .notARepo, .noStack, .unknownThread, .badInput, .unsupportedCatalog: ExitStatus.dataError
        case .appUnavailable, .sandboxBlocked: ExitStatus.unavailable
        case .midOperation: ExitStatus.tryAgainLater
        case .unreplied: ExitStatus.refused
        case .versionMismatch: ExitStatus.versionMismatch
        default: ExitStatus.internalError
        }
    }
}

/// The `eyeballs` command's exit statuses, from the sysexits family.
public enum ExitStatus {
    /// Every expected outcome, including timeouts, "nothing waiting" and `not_driver`.
    public static let success: Int32 = 0
    /// swift-argument-parser uses this for a command line it cannot parse.
    public static let usage: Int32 = 64
    public static let dataError: Int32 = 65
    public static let unavailable: Int32 = 69
    public static let internalError: Int32 = 70
    public static let tryAgainLater: Int32 = 75
    public static let refused: Int32 = 77
    public static let versionMismatch: Int32 = 78

    /// The exit status for any error, with 70 for errors Eyeballs does not know.
    public static func forError(_ error: any Error) -> Int32 {
        EyeballsError(error).code.exitStatus
    }
}

/// What `--json` prints when a command fails.
public struct ErrorDocument: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.error/1"
    public private(set) var ok = false
    public var error: EyeballsError

    public init(error: EyeballsError) {
        self.error = error
    }
}

/// A name sent between the app and the command, from a list that can grow.
///
/// A value this build does not know still decodes, so an older command can read a newer app's
/// results. That is why these are structs with constants rather than enums.
public protocol WireName: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible
where RawValue == String {
    init(rawValue: String)
}

extension WireName {
    public init(stringLiteral value: String) { self.init(rawValue: value) }
    public var description: String { rawValue }
}
