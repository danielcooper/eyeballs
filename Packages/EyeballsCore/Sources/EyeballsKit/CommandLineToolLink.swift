import Foundation

/// The `~/.local/bin/eyeballs` link that Install Command Line Tool creates.
///
/// Debug builds use `~/.local/bin/eyeballs-debug`, so a click in a Debug build run from Xcode
/// never points every agent session at the Debug store. The app calls `install(pointingTo:)`
/// from the menu item and `repairIfNeeded(helper:expectedIdentifier:)` at launch.
public struct CommandLineToolLink: Sendable {
    public var folder: URL
    public var name: String

    public init(folder: URL, name: String) {
        self.folder = folder
        self.name = name
    }

    /// `~/.local/bin/eyeballs`, or `~/.local/bin/eyeballs-debug` for Debug builds.
    public static func standard(debug: Bool) -> CommandLineToolLink {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        return CommandLineToolLink(folder: folder, name: debug ? "eyeballs-debug" : "eyeballs")
    }

    public var path: URL { folder.appendingPathComponent(name) }

    public enum State: Sendable, Hashable {
        case missing
        case link(to: String)
        /// A file or folder that is not a symlink. Eyeballs never replaces it.
        case notALink
    }

    public var state: State {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path) else { return .missing }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return .notALink }
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path) else { return .notALink }
        return .link(to: destination)
    }

    /// Points the link at `helper`, replacing an older link. Throws `EyeballsError` when a file
    /// that is not a symlink is in the way.
    public func install(pointingTo helper: URL) throws {
        if state == .notALink {
            throw EyeballsError(
                .badInput,
                "A file that is not a link is already at ~/.local/bin/\(name), so Eyeballs left it alone.",
                hint: "Move that file away, then choose Install Command Line Tool again.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try replaceLink(with: helper)
    }

    public enum Repair: Sendable, Hashable {
        case unchanged
        case repaired
    }

    /// Repoints the link at `helper` when it points into an `.app` that no longer exists, or
    /// into a bundle whose identifier is not `expectedIdentifier`. It leaves a missing link,
    /// a link to a path outside any bundle, and anything that is not a symlink alone.
    @discardableResult
    public func repairIfNeeded(helper: URL, expectedIdentifier: String) throws -> Repair {
        guard case .link(let destination) = state else { return .unchanged }
        let target = URL(fileURLWithPath: destination, relativeTo: folder).standardizedFileURL
        guard let bundle = Self.enclosingBundle(of: target) else { return .unchanged }
        let bundleExists = FileManager.default.fileExists(atPath: bundle.path)
        if bundleExists, AppBundle.identifier(of: bundle) == expectedIdentifier { return .unchanged }
        try replaceLink(with: helper)
        return .repaired
    }

    /// The nearest folder above `url` whose name ends in `.app`.
    static func enclosingBundle(of url: URL) -> URL? {
        var candidate = url
        while candidate.pathComponents.count > 1 {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// Writes a new link beside the old one and renames it into place, so the command never
    /// goes missing in between.
    private func replaceLink(with helper: URL) throws {
        let temporary = folder.appendingPathComponent(".\(name).\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: helper.path)
        guard rename(temporary.path, path.path) == 0 else {
            let error = SystemCallError("rename")
            try? FileManager.default.removeItem(at: temporary)
            throw EyeballsError(.internalError, "Eyeballs could not update ~/.local/bin/\(name): \(error.description).")
        }
    }
}
