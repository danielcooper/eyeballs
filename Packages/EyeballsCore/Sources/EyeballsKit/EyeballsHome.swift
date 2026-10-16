import Foundation

/// The folder that holds Eyeballs' database, backups, socket and lock.
///
/// Release builds use `~/Library/Application Support/Eyeballs`, Debug builds use `Eyeballs-Debug`
/// beside it, and `EYEBALLS_HOME` overrides both, so tests and Instruments runs never touch real data.
public struct EyeballsHome: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var database: URL { root.appendingPathComponent("eyeballs.sqlite") }
    public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    public var run: URL { root.appendingPathComponent("run", isDirectory: true) }
    public var socket: URL { run.appendingPathComponent("eyeballs.sock") }
    public var lock: URL { run.appendingPathComponent("app.lock") }

    /// Pass `debug: true` from code compiled with `#if DEBUG`.
    public static func current(debug: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> EyeballsHome {
        if let override = environment["EYEBALLS_HOME"], !override.isEmpty {
            return EyeballsHome(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return EyeballsHome(root: support.appendingPathComponent(debug ? "Eyeballs-Debug" : "Eyeballs", isDirectory: true))
    }

    /// Creates the folders, readable only by you.
    public func prepare() throws {
        for folder in [root, run, backups] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }
}
