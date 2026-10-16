import Foundation

/// `eyeballs doctor`: you and CI check the install, and the app checks the store's invariants.
public struct DoctorArguments: Codable, Sendable, Hashable {
    public init() {}
}

/// What the app answers to `doctor`: who it is, and its own checks, such as "every open thread
/// has an anchor on its stack's latest revision".
public struct AppHealth: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.app-health/1"
    public private(set) var ok = true
    public var version: String
    public var build: String
    public var protocolVersion: Int
    /// The running app's bundle path.
    public var path: String
    public var home: String
    public var checks: [DoctorCheck]

    public init(version: String, build: String, protocolVersion: Int = WireProtocol.version, path: String, home: String,
                checks: [DoctorCheck]) {
        self.version = version
        self.build = build
        self.protocolVersion = protocolVersion
        self.path = path
        self.home = home
        self.checks = checks
        self.ok = !checks.contains { $0.status == .failed }
    }

    enum CodingKeys: String, CodingKey {
        case schema, ok, version, build
        case protocolVersion = "protocol"
        case path, home, checks
    }
}

/// What `eyeballs doctor` prints: the command's own checks plus the app's.
public struct DoctorReport: Codable, Sendable, Hashable {
    public private(set) var schema = "eyeballs.doctor/1"
    /// False when any check failed.
    public private(set) var ok = true
    public var cli: ComponentInfo
    public var app: ComponentInfo
    public var home: String
    public var socket: String
    public var checks: [DoctorCheck]
    /// The rule to add to `permissions.allow` in `~/.claude/settings.json`: `Bash(eyeballs *)`.
    public var permissionRule: String
    /// The setting to add when Claude Code's sandbox is on.
    public var sandboxSetting: String

    public init(cli: ComponentInfo, app: ComponentInfo, home: String, socket: String, checks: [DoctorCheck],
                permissionRule: String, sandboxSetting: String) {
        self.cli = cli
        self.app = app
        self.home = home
        self.socket = socket
        self.checks = checks
        self.permissionRule = permissionRule
        self.sandboxSetting = sandboxSetting
        self.ok = !checks.contains { $0.status == .failed }
    }

    /// The rule for a command named `commandName`, such as `Bash(eyeballs *)`.
    public static func permissionRule(commandName: String) -> String {
        "Bash(\(commandName) *)"
    }

    /// `"sandbox":{"network":{"allowUnixSockets":["<socket>"]}}`, with the socket path JSON-escaped.
    public static func sandboxSetting(socket: String) -> String {
        let allow = JSONValue.object(JSONObject(["allowUnixSockets": .array([.string(socket)])]))
        let sandbox = JSONValue.object(JSONObject(["network": allow]))
        return "\"sandbox\":" + sandbox.serialized()
    }

    /// The report in words, one check per line, then the settings to add.
    public var text: String {
        var lines = ["Eyeballs doctor"]
        for check in checks {
            lines.append("\(check.status.label)  \(check.name): \(check.message)")
        }
        lines.append("")
        lines.append("Add this rule to permissions.allow in ~/.claude/settings.json:")
        lines.append("  \"\(permissionRule)\"")
        lines.append("If you turn on Claude Code's sandbox, also add:")
        lines.append("  \(sandboxSetting)")
        return lines.joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey {
        case schema, ok, cli, app, home, socket, checks
        case permissionRule = "permission_rule"
        case sandboxSetting = "sandbox_setting"
    }
}

/// One part of the install: the command or the app.
public struct ComponentInfo: Codable, Sendable, Hashable {
    /// For the app: whether it answered on the socket. The command is always running.
    public var running: Bool
    public var path: String?
    public var version: String?
    public var build: String?
    public var protocolVersion: Int?

    public init(running: Bool, path: String?, version: String?, build: String?, protocolVersion: Int?) {
        self.running = running
        self.path = path
        self.version = version
        self.build = build
        self.protocolVersion = protocolVersion
    }

    enum CodingKeys: String, CodingKey {
        case running, path, version, build
        case protocolVersion = "protocol"
    }
}

public struct DoctorCheck: Codable, Sendable, Hashable {
    public var name: String
    public var status: CheckStatus
    public var message: String

    public init(name: String, status: CheckStatus, message: String) {
        self.name = name
        self.status = status
        self.message = message
    }
}

public struct CheckStatus: WireName {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let passed: CheckStatus = "passed"
    /// Worth fixing, but nothing is broken.
    public static let warning: CheckStatus = "warning"
    public static let failed: CheckStatus = "failed"
    /// Not checked, for example because the app is not running.
    public static let skipped: CheckStatus = "skipped"

    /// A fixed-width word for the text report.
    var label: String {
        switch self {
        case .passed: "ok  "
        case .warning: "warn"
        case .failed: "FAIL"
        case .skipped: "skip"
        default: rawValue
        }
    }
}
