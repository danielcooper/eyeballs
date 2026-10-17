import Darwin
import Foundation

/// Runs git with the settings that keep a repository's own config from running programs.
///
/// Every call passes arguments as an array, never through a shell. It sets
/// `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0` and `GIT_LITERAL_PATHSPECS=1`, drops every other
/// `GIT_*` variable it inherited, and adds `-c core.fsmonitor=false -c core.quotePath=false
/// -c color.ui=false` before the subcommand. Put `--` before paths yourself.
public struct Git: Sendable {
    public static let defaultExecutable = URL(fileURLWithPath: "/usr/bin/git")

    public var executable: URL
    /// The folder git runs in.
    public var directory: URL

    public init(directory: URL, executable: URL = Git.defaultExecutable) {
        self.directory = directory
        self.executable = executable
    }

    /// Runs git off the calling thread and returns what it printed.
    ///
    /// Throws `GitError.commandFailed` when git exits with a status outside `acceptedStatuses`.
    public func run(_ arguments: [String], input: Data? = nil, acceptedStatuses: Set<Int32> = [0]) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            Thread {
                continuation.resume(with: Result { try self.runNow(arguments, input: input, acceptedStatuses: acceptedStatuses) })
            }.start()
        }
    }

    /// Runs git and blocks the calling thread until it exits. Prefer `run` from async code.
    public func runNow(_ arguments: [String], input: Data? = nil, acceptedStatuses: Set<Int32> = [0]) throws -> GitResult {
        let process = makeProcess(arguments)
        let output = Pipe()
        let errors = Pipe()
        let stdin = input == nil ? nil : Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin ?? FileHandle.nullDevice

        // `waitUntilExit` can hang on a thread other than the one that launched git, so wait for this instead.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(executable: executable.path, reason: error.localizedDescription)
        }

        // Read both pipes and write stdin at once, or a full pipe buffer would block git forever.
        let errorReader = BlockingTask { errors.fileHandleForReading.readDataToEndOfFile() }
        var inputWriter: BlockingTask<Void>?
        if let stdin, let input {
            let writer = stdin.fileHandleForWriting
            Git.ignoreBrokenPipe(writer)
            inputWriter = BlockingTask {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        let outputBytes = output.fileHandleForReading.readDataToEndOfFile()
        let errorBytes = errorReader.wait()
        inputWriter?.wait()
        exited.wait()

        let result = GitResult(
            status: process.terminationReason == .exit ? process.terminationStatus : -process.terminationStatus,
            output: outputBytes,
            errorOutput: errorBytes
        )
        guard acceptedStatuses.contains(result.status) else {
            throw GitError.commandFailed(subcommand: Git.subcommand(in: arguments), status: result.status, message: result.errorSummary)
        }
        return result
    }

    static let hardeningOptions = ["-c", "core.fsmonitor=false", "-c", "core.quotePath=false", "-c", "color.ui=false"]

    func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = Git.hardeningOptions + arguments
        process.currentDirectoryURL = directory
        process.environment = Git.environment()
        return process
    }

    static func environment(from inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        return environment
    }

    /// Makes a write to a pipe whose reader has gone fail with EPIPE instead of killing the app with SIGPIPE.
    static func ignoreBrokenPipe(_ handle: FileHandle) {
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    static func subcommand(in arguments: [String]) -> String {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-c" || argument == "-C" {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                return argument
            }
        }
        return "git"
    }
}

/// Runs blocking work on a thread of its own, so it never ties up a thread that other work is waiting for.
final class BlockingTask<Value: Sendable>: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    // Written once on the task's thread before `finished` signals, and read only after it has.
    private var value: Value?

    init(_ work: @escaping @Sendable () -> Value) {
        Thread { [self] in
            value = work()
            finished.signal()
        }.start()
    }

    @discardableResult
    func wait() -> Value {
        finished.wait()
        return value!
    }
}

/// What one git command printed, and how it exited.
public struct GitResult: Sendable {
    public var status: Int32
    public var output: Data
    public var errorOutput: Data

    /// The output as UTF-8 text, with one trailing newline removed.
    public var text: String {
        var text = String(decoding: output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// The last line git wrote to stderr, cut to 300 characters, with control characters escaped
    /// so it is safe to log or print.
    var errorSummary: String {
        let lines = String(decoding: errorOutput, as: UTF8.self).split(whereSeparator: \.isNewline)
        let last = lines.last.map(String.init) ?? ""
        return String(last.prefix(300)).escapingControlCharacters
    }
}

public enum GitError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The git executable could not be started.
    case launchFailed(executable: String, reason: String)
    /// Git ran but exited with a status the caller did not accept. `message` is git's last stderr line.
    case commandFailed(subcommand: String, status: Int32, message: String)
    /// The folder is not inside a git repository.
    case notARepository
    /// The repository has no object with this name.
    case missingObject(ObjectID)
    /// The object exists but is not a blob.
    case notABlob(ObjectID)
    /// Git printed something Eyeballs could not read.
    case unexpectedOutput(subcommand: String, expected: String)
    /// An argument was refused before git ran, because git could misread it.
    case invalidArgument(String)
    /// The long-lived `git cat-file --batch` process stopped answering.
    case blobReaderStopped

    public var description: String {
        switch self {
        case let .launchFailed(executable, reason):
            "Could not start git at \(executable): \(reason)"
        case let .commandFailed(subcommand, status, message):
            message.isEmpty ? "git \(subcommand) exited with status \(status)" : "git \(subcommand) exited with status \(status): \(message)"
        case .notARepository:
            "This folder is not inside a git repository."
        case let .missingObject(id):
            "The repository has no object \(id.hex)."
        case let .notABlob(id):
            "Object \(id.hex) is not a file's contents."
        case let .unexpectedOutput(subcommand, expected):
            "git \(subcommand) printed something unexpected: expected \(expected)."
        case let .invalidArgument(problem):
            problem
        case .blobReaderStopped:
            "git cat-file stopped answering. The next read starts it again."
        }
    }
}

extension String {
    /// Control characters other than tab, shown as `\u{1b}`-style escapes.
    var escapingControlCharacters: String {
        var escaped = ""
        for scalar in unicodeScalars {
            if (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F {
                escaped += "\\u{\(String(scalar.value, radix: 16))}"
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }
}

/// Refuses a revision argument that git would read as an option.
func checkedRevision(_ revision: String) throws -> String {
    guard !revision.isEmpty, !revision.hasPrefix("-"), !revision.contains("\0"), !revision.contains("\n") else {
        throw GitError.invalidArgument("A revision must be a branch, ref or commit name that does not start with \"-\" and has no newline; got \(revision.count) characters.")
    }
    return revision
}
