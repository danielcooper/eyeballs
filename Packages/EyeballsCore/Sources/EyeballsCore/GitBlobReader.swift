import Darwin
import Foundation

/// Reads blobs through one long-lived `git cat-file --batch` process.
///
/// Every request writes an object name and reads its answer on one serial queue, with no
/// suspension in between. So concurrent callers each get the blob they asked for, never another
/// caller's. An actor would not do: it can interleave two callers at any `await`.
///
/// The process starts on the first read. If it stops answering, the read throws
/// `GitError.blobReaderStopped` and the next read starts a new one.
public final class BlobReader: @unchecked Sendable {
    private let git: Git
    private let queue = DispatchQueue(label: "coops.eyeballs.cat-file")
    // Only code running on `queue` touches the state below. That is what makes sharing this class safe.
    private var process: Process?
    private var requests: FileHandle?
    private var answers: FileHandle?
    private var buffer: [UInt8] = []

    public init(git: Git) {
        self.git = git
    }

    deinit {
        stopProcess()
    }

    /// The contents of a blob. Throws `GitError.missingObject` or `GitError.notABlob`.
    public func blob(_ id: ObjectID) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.readBlobOnQueue(id) })
            }
        }
    }

    /// The same as `blob(_:)`, blocking the calling thread.
    public func blobNow(_ id: ObjectID) throws -> Data {
        try queue.sync { try readBlobOnQueue(id) }
    }

    /// Stops the `cat-file` process. A later read starts a new one.
    public func close() {
        queue.sync { stopProcess() }
    }

    private func readBlobOnQueue(_ id: ObjectID) throws -> Data {
        do {
            try startProcessIfNeeded()
            try requests?.write(contentsOf: Data((id.hex + "\n").utf8))
            let header = try readLine()
            let fields = header.split(separator: 0x20)
            if fields.count == 2, fields[1].elementsEqual("missing".utf8) {
                throw GitError.missingObject(id)
            }
            guard fields.count == 3, let size = Int(String(decoding: fields[2], as: UTF8.self)), size >= 0 else {
                throw GitError.unexpectedOutput(subcommand: "cat-file", expected: "a line \"<name> <type> <size>\"")
            }
            let contents = try readExactly(size)
            guard try readExactly(1) == [0x0A] else {
                throw GitError.unexpectedOutput(subcommand: "cat-file", expected: "a newline after the object's contents")
            }
            guard fields[1].elementsEqual("blob".utf8) else { throw GitError.notABlob(id) }
            return Data(contents)
        } catch let error as GitError {
            switch error {
            case .missingObject, .notABlob:
                throw error
            default:
                stopProcess()
                throw error
            }
        } catch {
            stopProcess()
            throw GitError.blobReaderStopped
        }
    }

    private func startProcessIfNeeded() throws {
        if let process, process.isRunning { return }
        stopProcess()
        let process = git.makeProcess(["cat-file", "--batch"])
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        Git.ignoreBrokenPipe(input.fileHandleForWriting)
        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(executable: git.executable.path, reason: error.localizedDescription)
        }
        self.process = process
        self.requests = input.fileHandleForWriting
        self.answers = output.fileHandleForReading
        self.buffer = []
    }

    private func stopProcess() {
        try? requests?.close()
        if let process, process.isRunning {
            process.terminate()
        }
        try? answers?.close()
        process = nil
        requests = nil
        answers = nil
        buffer = []
    }

    private func readLine() throws -> [UInt8] {
        var searchedUpTo = 0
        while true {
            if let newline = buffer[searchedUpTo...].firstIndex(of: 0x0A) {
                let line = Array(buffer[..<newline])
                buffer.removeFirst(newline + 1)
                return line
            }
            searchedUpTo = buffer.count
            try fill(wanting: 1)
        }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        while buffer.count < count {
            try fill(wanting: count - buffer.count)
        }
        let bytes = Array(buffer[..<count])
        buffer.removeFirst(count)
        return bytes
    }

    /// Reads whatever `cat-file` has written so far, waiting for at least one byte.
    // `FileHandle.read(upToCount:)` waits for the full count or end of file, so it would hang here.
    private func fill(wanting count: Int) throws {
        guard let answers else { throw GitError.blobReaderStopped }
        var chunk = [UInt8](repeating: 0, count: max(count, 1 << 16))
        var received = 0
        repeat {
            received = chunk.withUnsafeMutableBytes { Darwin.read(answers.fileDescriptor, $0.baseAddress, $0.count) }
        } while received < 0 && errno == EINTR
        guard received > 0 else { throw GitError.blobReaderStopped }
        buffer.append(contentsOf: chunk[..<received])
    }
}
