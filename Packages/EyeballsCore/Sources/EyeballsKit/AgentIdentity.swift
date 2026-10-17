import Darwin
import Foundation

/// Works out who is running the `eyeballs` command, for the request's client block.
public enum AgentIdentity {
    /// Reads `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID` and `CODEX_THREAD_ID`.
    /// `agent` and `session`, from `--agent` and `--session`, override what the environment says.
    ///
    /// An environment value that is empty, too long or holds control characters is ignored.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        agent agentOverride: String? = nil,
        session sessionOverride: String? = nil,
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        processes: ProcessInspector = .live,
        ownProcess: Int32 = getpid()
    ) -> ClientIdentity {
        let claudeSession = usable(environment["CLAUDE_CODE_SESSION_ID"])
        let codexThread = usable(environment["CODEX_THREAD_ID"])
        let inClaude = environment["CLAUDECODE"].map { !$0.isEmpty } ?? false

        var agent = "other"
        var session: String?
        if inClaude || claudeSession != nil {
            agent = "claude"
            session = claudeSession
        } else if let codexThread {
            agent = "codex"
            session = codexThread
        }
        if let agentOverride { agent = agentOverride }
        if let sessionOverride { session = sessionOverride }

        let pid = environment["CLAUDE_PID"].flatMap { Int32($0) }.flatMap { $0 > 1 ? $0 : nil }
        return ClientIdentity(
            agent: agent,
            session: session,
            pid: pid,
            pidStart: pid.flatMap(processes.startTime),
            ancestors: processes.ancestors(of: ownProcess),
            cwd: workingDirectory)
    }

    /// An agent name from `--agent`: 1 to 32 lowercase letters, digits, `-`, `_` or `.`.
    public static func isValidAgentName(_ name: String) -> Bool {
        (1...32).contains(name.count) && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "-_.".contains($0)) }
    }

    /// A session ID from `--session`: 1 to 256 printable characters.
    public static func isValidSession(_ session: String) -> Bool {
        usable(session) != nil
    }

    private static func usable(_ value: String?) -> String? {
        guard let value, (1...256).contains(value.count),
              !value.unicodeScalars.contains(where: { TerminalText.isControl($0) }) else { return nil }
        return value
    }
}

/// Reads facts about running processes from the kernel, with `proc_pidinfo`.
///
/// Tests replace the two functions to describe a process tree of their own.
public struct ProcessInspector: Sendable {
    /// When `pid` started, in seconds since 1970 (`pbi_start_tvsec`). Nil when it is not running.
    public var startTime: @Sendable (Int32) -> Int64?
    /// The parent of `pid`. Nil when it is not running.
    public var parent: @Sendable (Int32) -> Int32?

    public init(startTime: @escaping @Sendable (Int32) -> Int64?, parent: @escaping @Sendable (Int32) -> Int32?) {
        self.startTime = startTime
        self.parent = parent
    }

    public static let live = ProcessInspector(
        startTime: { pid in bsdInfo(pid).map { Int64($0.pbi_start_tvsec) } },
        parent: { pid in bsdInfo(pid).map { Int32(bitPattern: $0.pbi_ppid) } })

    /// True when the process is still running and is the same one: a PID that was reused
    /// by a newer process has a different start time.
    public func isAlive(_ process: ClaudeProcess) -> Bool {
        startTime(process.pid) == process.start
    }

    /// The parent of `pid`, its parent, and so on, nearest first. Stops before launchd.
    public func ancestors(of pid: Int32, limit: Int = 64) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        while chain.count < limit, let next = parent(current), next > 1, next != current, !chain.contains(next) {
            chain.append(next)
            current = next
        }
        return chain
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
