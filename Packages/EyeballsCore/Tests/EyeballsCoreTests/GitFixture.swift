import EyeballsCore
import Foundation

/// A throwaway repository in a short temporary folder, removed when the fixture goes away.
///
/// It runs git directly, not through `Git`, so a bug in the code under test cannot hide in the
/// setup. Your global and system git config are ignored, and commit dates are fixed.
final class GitFixture: @unchecked Sendable {
    /// The folder that holds the repository and anything else a test makes.
    let root: URL
    /// The repository's work tree, or the repository itself when it is bare.
    let repo: URL
    private var clock = 1_760_000_000

    init(bare: Bool = false) throws {
        root = URL(fileURLWithPath: "/private/tmp/eb-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(bare ? ["init", "-q", "--bare", "-b", "main"] : ["init", "-q", "-b", "main"])
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs git in the repository, or in `folder`, and returns stdout without its last newline.
    @discardableResult
    func git(_ arguments: [String], input: Data? = nil, in folder: URL? = nil, environment extra: [String: String] = [:]) throws -> String {
        String(decoding: try gitData(arguments, input: input, in: folder, environment: extra), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    func gitData(_ arguments: [String], input: Data? = nil, in folder: URL? = nil, environment extra: [String: String] = [:]) throws -> Data {
        clock += 60
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=Eyeballs", "-c", "user.email=eyeballs@example.invalid",
            "-c", "commit.gpgsign=false", "-c", "core.autocrlf=false",
        ] + arguments
        process.currentDirectoryURL = folder ?? repo
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_AUTHOR_DATE"] = "@\(clock) +0000"
        environment["GIT_COMMITTER_DATE"] = "@\(clock) +0000"
        environment.merge(extra) { $1 }
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()
        if let input {
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError(message: "git \(arguments.joined(separator: " ")) failed: \(message)")
        }
        return data
    }

    func write(_ path: String, _ text: String) throws {
        try write(path, data: Data(text.utf8))
    }

    func write(_ path: String, data: Data) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: repo.appendingPathComponent(path))
    }

    /// Stages everything and commits it, then returns the new commit.
    @discardableResult
    func commit(_ message: String) throws -> ObjectID {
        try git(["add", "-A"])
        try git(["commit", "-q", "--allow-empty", "-m", message])
        return try sha("HEAD")
    }

    func sha(_ revision: String) throws -> ObjectID {
        guard let id = ObjectID(try git(["rev-parse", "--verify", revision])) else {
            throw FixtureError(message: "rev-parse printed no object name")
        }
        return id
    }

    /// Writes a blob straight into the object store.
    func blob(_ text: String) throws -> ObjectID {
        try blob(Data(text.utf8))
    }

    func blob(_ data: Data) throws -> ObjectID {
        guard let id = ObjectID(try git(["hash-object", "-w", "--stdin"], input: data)) else {
            throw FixtureError(message: "hash-object printed no object name")
        }
        return id
    }

    /// Builds a commit from tree entries without touching the work tree, for paths macOS cannot
    /// store on disk, such as ones that are not UTF-8.
    func commitTree(_ entries: [(mode: String, object: ObjectID, path: [UInt8])], parent: ObjectID?, message: String) throws -> ObjectID {
        let indexFile = root.appendingPathComponent("index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: indexFile) }
        var info = Data()
        for entry in entries {
            info.append(contentsOf: Array("\(entry.mode) \(entry.object.hex) 0\t".utf8) + entry.path + [0])
        }
        try git(["update-index", "-z", "--index-info"], input: info, environment: ["GIT_INDEX_FILE": indexFile])
        let tree = try git(["write-tree"], environment: ["GIT_INDEX_FILE": indexFile])
        let parentArguments = parent.map { ["-p", $0.hex] } ?? []
        guard let commit = ObjectID(try git(["commit-tree", tree] + parentArguments + ["-m", message])) else {
            throw FixtureError(message: "commit-tree printed no object name")
        }
        return commit
    }

    func repository() async throws -> GitRepository {
        try await GitRepository.locate(from: repo)
    }
}

struct FixtureError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
