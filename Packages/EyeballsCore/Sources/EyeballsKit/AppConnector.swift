import Darwin
import Foundation

/// Connects the `eyeballs` command to the app, starting the app first when the command may.
///
/// Only commands the design marks "Starts the app" pass a start mode other than `.never`.
/// The command starts the app at its own bundle's path, so a Debug build never answers for
/// Release.
public struct AppConnector: Sendable {
    public enum Start: Sendable {
        /// Fail with `app_unavailable` when the app is not running.
        case never
        /// Start the app without bringing it to the front, with `open -g`.
        case inBackground
        /// Bring the app to the front, starting it if needed. `eyeballs open` uses this.
        case inFront
    }

    public var home: EyeballsHome
    /// The `.app` this command lives in. Nil when the command is not inside a bundle.
    public var app: URL?
    public var connectTimeout: Duration = .seconds(1)
    public var startupTimeout: Duration = .seconds(10)
    public var retryInterval: Duration = .milliseconds(100)
    /// Starts the app at a path. The default runs `/usr/bin/open`.
    public var launch: @Sendable (_ app: URL, _ inFront: Bool) throws -> Void

    public init(home: EyeballsHome, app: URL?, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.app = app
        let home = environment["EYEBALLS_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        launch = { app, inFront in try Self.openApp(app, inFront: inFront, home: home) }
    }

    /// A connected client. Throws `SocketClientError.notRunning` when the app is not running
    /// and `start` is `.never`, and an `app_unavailable` `EyeballsError` when it could not be
    /// started. `EyeballsError(_:)` turns either into the error to report.
    public func connect(start: Start) throws -> SocketClient {
        if start == .inFront, let app {
            try launch(app, true)
        }
        do {
            return try SocketClient.connect(to: home.socket, timeout: connectTimeout)
        } catch SocketClientError.notRunning where start != .never {
            guard let app else {
                throw EyeballsError(
                    .appUnavailable,
                    "Eyeballs is not running, and this eyeballs command is not inside Eyeballs.app, so it cannot start it.",
                    hint: "Open Eyeballs, then try again.")
            }
            if start == .inBackground { try launch(app, false) }
            return try connectWhileStarting()
        }
    }

    private func connectWhileStarting() throws -> SocketClient {
        let deadline = ContinuousClock.now + startupTimeout
        while ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: Double(retryInterval.wholeMilliseconds) / 1000)
            do {
                return try SocketClient.connect(to: home.socket, timeout: connectTimeout)
            } catch SocketClientError.notRunning {
                continue
            }
        }
        throw EyeballsError(
            .appUnavailable,
            "Eyeballs did not start within \(startupTimeout.wholeSecondsRoundedUp) s.",
            hint: "Open Eyeballs yourself, then try again. Run eyeballs doctor if it still fails.")
    }

    /// Runs `/usr/bin/open -g -a <app>`, passing `EYEBALLS_HOME` on so a test home reaches the app.
    static func openApp(_ app: URL, inFront: Bool, home: String?) throws {
        var arguments: [String] = []
        if let home { arguments += ["--env", "EYEBALLS_HOME=\(home)"] }
        if !inFront { arguments.append("-g") }
        arguments += ["-a", app.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw EyeballsError(.appUnavailable, "macOS could not run /usr/bin/open to start Eyeballs.", hint: "Open Eyeballs yourself, then try again.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EyeballsError(
                .appUnavailable,
                "macOS could not start Eyeballs: open exited with status \(process.terminationStatus).",
                hint: "Check that Eyeballs.app is still in place, then try again.")
        }
    }
}

/// Finds the app bundle around the running `eyeballs` command.
public enum AppBundle {
    /// The command's real path, with every symlink resolved, from `_NSGetExecutablePath` and
    /// `realpath`. This works through the `~/.local/bin` link and the plugin's wrapper.
    public static func executablePath() -> URL? {
        var size: UInt32 = 1024
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        }
        guard let resolved = realpath(buffer, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    /// `/Applications/Eyeballs.app` for `/Applications/Eyeballs.app/Contents/Helpers/eyeballs`.
    /// Nil for a command anywhere else.
    public static func containing(helper: URL) -> URL? {
        let helpers = helper.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", app.pathExtension == "app" else {
            return nil
        }
        return app
    }

    /// The app this command was started from, if it runs from inside one.
    public static func current() -> URL? {
        executablePath().flatMap(containing(helper:))
    }

    /// The `CFBundleIdentifier` in a bundle's `Contents/Info.plist`.
    public static func identifier(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleIdentifier"] as? String
    }
}
