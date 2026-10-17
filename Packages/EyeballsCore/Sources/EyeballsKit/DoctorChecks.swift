import Darwin
import Foundation

/// The checks `eyeballs doctor` runs itself, without the app. None of them writes anything.
public enum DoctorChecks {
    public static func local(
        home: EyeballsHome,
        executable: URL?,
        link: CommandLineToolLink,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> [DoctorCheck] {
        [
            commandCheck(executable),
            folderCheck("Home folder", home.root),
            folderCheck("Run folder", home.run),
            socketPathCheck(home.socket),
            linkCheck(link, executable: executable),
            searchPathCheck(link.folder, searchPath: searchPath),
        ]
    }

    static func commandCheck(_ executable: URL?) -> DoctorCheck {
        guard let executable else {
            return DoctorCheck(name: "Command", status: .warning, message: "this command could not find its own path.")
        }
        guard AppBundle.containing(helper: executable) != nil else {
            return DoctorCheck(name: "Command", status: .warning,
                               message: "\(executable.path) is not inside Eyeballs.app, so it cannot start the app.")
        }
        return DoctorCheck(name: "Command", status: .passed, message: executable.path)
    }

    /// A folder that does not exist yet passes: the app creates it at first launch.
    static func folderCheck(_ name: String, _ folder: URL) -> DoctorCheck {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else {
            return DoctorCheck(name: name, status: .passed, message: "\(folder.path) does not exist yet. The app creates it.")
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            return DoctorCheck(name: name, status: .failed, message: "\(folder.path) is not a folder.")
        }
        guard info.st_uid == geteuid() else {
            return DoctorCheck(name: name, status: .failed, message: "\(folder.path) belongs to another user.")
        }
        let mode = info.st_mode & 0o777
        guard mode & 0o077 == 0 else {
            return DoctorCheck(name: name, status: .failed,
                               message: "\(folder.path) has permissions \(String(mode, radix: 8)), so other users can enter it. Run chmod 700 on it.")
        }
        return DoctorCheck(name: name, status: .passed, message: "\(folder.path) (\(String(mode, radix: 8)))")
    }

    static func socketPathCheck(_ socket: URL) -> DoctorCheck {
        let bytes = socket.path.utf8.count
        let limit = UnixSocket.maximumPathBytes
        guard bytes <= limit else {
            return DoctorCheck(name: "Socket path", status: .failed,
                               message: "\(bytes) bytes, over the \(limit)-byte limit. Set EYEBALLS_HOME to a shorter folder.")
        }
        return DoctorCheck(name: "Socket path", status: .passed, message: "\(bytes) of \(limit) bytes")
    }

    static func linkCheck(_ link: CommandLineToolLink, executable: URL?) -> DoctorCheck {
        let name = "Command link"
        let shown = "~/.local/bin/\(link.name)"
        switch link.state {
        case .missing:
            return DoctorCheck(name: name, status: .warning, message: "\(shown) is missing. Choose Eyeballs > Install Command Line Tool.")
        case .notALink:
            return DoctorCheck(name: name, status: .warning, message: "\(shown) is a file, not a link to Eyeballs, so Eyeballs leaves it alone.")
        case .link(let destination):
            let target = URL(fileURLWithPath: destination, relativeTo: link.folder).standardizedFileURL.resolvingSymlinksInPath()
            if let executable, target.path == executable.resolvingSymlinksInPath().path {
                return DoctorCheck(name: name, status: .passed, message: "\(shown) points to this command.")
            }
            return DoctorCheck(name: name, status: .warning, message: "\(shown) points to \(destination), not to this command.")
        }
    }

    static func searchPathCheck(_ folder: URL, searchPath: String) -> DoctorCheck {
        let entries = searchPath.split(separator: ":").map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
        guard entries.contains(folder.standardizedFileURL.path) else {
            return DoctorCheck(name: "PATH", status: .warning, message: "~/.local/bin is not on your PATH, so agents cannot run eyeballs by name.")
        }
        return DoctorCheck(name: "PATH", status: .passed, message: "~/.local/bin is on your PATH.")
    }
}
