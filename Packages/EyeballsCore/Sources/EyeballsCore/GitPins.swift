import Foundation

/// The refs that keep reviewed commits alive through rebases and `git gc`.
///
/// Each pin is `refs/eyeballs/<install-id>/<sha>`, pointing at that commit, so writing a pin
/// twice is harmless and a Debug install never touches a Release install's pins. Every change
/// runs as one `git update-ref --stdin` transaction with hooks turned off. Eyeballs never runs
/// `git gc` or `git prune`.
public struct PinStore: Sendable {
    public let repository: GitRepository
    public let installID: String

    /// Throws `GitError.invalidArgument` unless `installID` is 1 to 64 letters, digits or hyphens,
    /// starting with a letter or digit.
    public init(repository: GitRepository, installID: String) throws {
        let allowed = installID.utf8.allSatisfy { $0 == 0x2D || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
        guard (1...64).contains(installID.utf8.count), allowed, installID.first != "-" else {
            throw GitError.invalidArgument("An install ID must be 1 to 64 letters, digits or hyphens, starting with a letter or digit; got \(installID.count) characters.")
        }
        self.repository = repository
        self.installID = installID
    }

    /// `refs/eyeballs/<install-id>/`.
    public var refPrefix: String { "refs/eyeballs/\(installID)/" }

    public func ref(for commit: ObjectID) -> String { refPrefix + commit.hex }

    /// Pins every commit in one transaction. Throws, and pins none of them, if any commit is missing.
    public func pin(_ commits: some Collection<ObjectID>) async throws {
        guard !commits.isEmpty else { return }
        let commands = Set(commits).sorted().map { "update \(ref(for: $0)) \($0.hex)\n" }.joined()
        try await updateRefs(commands)
    }

    /// The commits this install has pinned in this repository.
    public func pinnedCommits() async throws -> Set<ObjectID> {
        let references = try await repository.references(under: [refPrefix])
        return Set(references.compactMap { reference in
            guard let pinned = ObjectID(reference.name.dropFirst(refPrefix.count)), pinned == reference.target else { return nil }
            return pinned
        })
    }

    /// Deletes the pins for these commits in one transaction. Commits with no pin are skipped.
    public func release(_ commits: some Collection<ObjectID>) async throws {
        let pinned = try await pinnedCommits()
        let releasing = Set(commits).intersection(pinned).sorted()
        guard !releasing.isEmpty else { return }
        try await updateRefs(releasing.map { "delete \(ref(for: $0)) \($0.hex)\n" }.joined())
    }

    // The reference-transaction hook runs on every ref update, so a repository's hooks must stay off.
    private func updateRefs(_ commands: String) async throws {
        _ = try await repository.git.run(["-c", "core.hooksPath=/dev/null", "update-ref", "--stdin"], input: Data(commands.utf8))
    }
}
