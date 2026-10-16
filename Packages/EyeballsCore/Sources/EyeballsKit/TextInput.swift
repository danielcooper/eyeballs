import Darwin
import Foundation

/// Reads the text the agent passes with `--note-file`, `--body-file`, `--file` and `--json-file`.
public enum TextInput {
    /// Reads the file at `path`, or standard input when `path` is `-`.
    ///
    /// Throws a `bad_input` `EyeballsError` that names `option`, never the path, when the file
    /// cannot be read, is over `limit` bytes, or is not UTF-8.
    public static func read(_ path: String, option: String, limit: Int) throws -> String {
        let data = try readData(path, option: option, limit: limit)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EyeballsError.badInput("The text given to \(option) is not UTF-8.")
        }
        return text
    }

    public static func readData(_ path: String, option: String, limit: Int) throws -> Data {
        let fd = path == "-" ? STDIN_FILENO : open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            throw EyeballsError.badInput("The file given to \(option) cannot be read: \(String(cString: strerror(errno))).")
        }
        defer { if fd != STDIN_FILENO { close(fd) } }
        guard let data = try readAll(fd, limit: limit, deadline: nil) else {
            throw EyeballsError.badInput("The text given to \(option) is over the \(limit / 1024) KB limit.")
        }
        return data
    }

    /// The hook's JSON from standard input, or nil when there is none in time.
    ///
    /// Claude Code writes the JSON and closes the pipe at once. A terminal never closes it,
    /// so stdin is skipped when it is a terminal, and reading stops at `timeout`.
    public static func hookInput(limit: Int = WireLimits.maximumRequestBytes / 2, timeout: Duration = .seconds(1)) -> JSONValue? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        guard let data = try? readAll(STDIN_FILENO, limit: limit, deadline: ContinuousClock.now + timeout), !data.isEmpty else {
            return nil
        }
        return try? JSONValue(parsing: data)
    }

    /// Nil when the input passes `limit`. Returns what arrived by `deadline` when it passes.
    private static func readAll(_ fd: Int32, limit: Int, deadline: ContinuousClock.Instant?) throws -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let deadline, !(try UnixSocket.wait(fd, for: Int16(POLLIN), until: deadline)) { return data }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                data.append(contentsOf: chunk[..<count])
                if data.count > limit { return nil }
            } else if count == 0 {
                return data
            } else if errno != EINTR && errno != EAGAIN {
                throw EyeballsError.badInput("Reading the input failed: \(String(cString: strerror(errno))).")
            }
        }
    }
}
