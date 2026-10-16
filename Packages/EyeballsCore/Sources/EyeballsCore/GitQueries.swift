import Foundation

/// A ref and the object it points at.
public struct GitReference: Hashable, Sendable {
    /// The full name, such as `refs/heads/main`.
    public var name: String
    public var target: ObjectID
}

/// One commit in a layer. It maps onto the window's `CommitItem`.
public struct CommitInfo: Hashable, Sendable {
    public var sha: ObjectID
    public var subject: String
    public var author: String
    public var date: Date
}

extension GitRepository {
    /// The commit a revision names, or nil when it names no commit.
    public func resolveCommit(_ revision: String) async throws -> ObjectID? {
        try await resolve(try checkedRevision(revision) + "^{commit}")
    }

    /// The object a revision names, or nil when it names none.
    public func resolve(_ revision: String) async throws -> ObjectID? {
        let result = try await git.run(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", try checkedRevision(revision)],
            acceptedStatuses: [0, 1]
        )
        guard result.status == 0 else { return nil }
        return try objectID(in: result, from: "rev-parse")
    }

    /// The tree of a commit, for the snapshot's `base_tree` and `head_tree`.
    public func tree(of commit: ObjectID) async throws -> ObjectID {
        guard let tree = try await resolve(commit.hex + "^{tree}") else { throw GitError.missingObject(commit) }
        return tree
    }

    /// The best common ancestor of two commits, or nil when they share no history.
    public func mergeBase(_ first: String, _ second: String) async throws -> ObjectID? {
        let result = try await git.run(["merge-base", try checkedRevision(first), try checkedRevision(second)], acceptedStatuses: [0, 1])
        guard result.status == 0 else { return nil }
        return try objectID(in: result, from: "merge-base")
    }

    /// True when `ancestor` is `descendant` or one of its ancestors.
    public func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let result = try await git.run(
            ["merge-base", "--is-ancestor", try checkedRevision(ancestor), try checkedRevision(descendant)],
            acceptedStatuses: [0, 1]
        )
        return result.status == 0
    }

    /// Where `commit` forked from `upstream`, using the upstream ref's reflog, as
    /// `git merge-base --fork-point` finds it. Nil when git finds no fork point.
    public func forkPoint(upstream: String, of commit: String) async throws -> ObjectID? {
        let result = try await git.run(
            ["merge-base", "--fork-point", try checkedRevision(upstream), try checkedRevision(commit)],
            acceptedStatuses: [0, 1]
        )
        guard result.status == 0, !result.output.isEmpty else { return nil }
        return try objectID(in: result, from: "merge-base")
    }

    /// Every ref under the given prefixes, such as `refs/heads/`, read in one `git for-each-ref`.
    public func references(under prefixes: [String]) async throws -> [GitReference] {
        let patterns = try prefixes.map(checkedRevision)
        let result = try await git.run(["for-each-ref", "--format=%(refname)%00%(objectname)"] + patterns)
        return try result.output.split(separator: 0x0A).map { line in
            let fields = line.split(separator: 0, omittingEmptySubsequences: false)
            guard fields.count == 2, let target = ObjectID(bytes: fields[1]) else {
                throw GitError.unexpectedOutput(subcommand: "for-each-ref", expected: "\"<ref>\\0<object>\" lines")
            }
            return GitReference(name: String(decoding: fields[0], as: UTF8.self), target: target)
        }
    }

    /// The branch checked out in this worktree, without `refs/heads/`, or nil when HEAD is detached.
    public func currentBranch() async throws -> String? {
        try await symbolicTarget(of: "HEAD").flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
    }

    /// The ref a symbolic ref points at, such as `refs/remotes/origin/main` for `refs/remotes/origin/HEAD`.
    public func symbolicTarget(of ref: String) async throws -> String? {
        let result = try await git.run(["symbolic-ref", "--quiet", try checkedRevision(ref)], acceptedStatuses: [0, 1, 128])
        guard result.status == 0 else { return nil }
        return result.text
    }

    /// The commits in `base..head`, newest first.
    public func commits(from base: ObjectID, to head: ObjectID) async throws -> [CommitInfo] {
        let result = try await git.run([
            "log", "--no-show-signature", "--no-color", "-z", "--format=%H%x00%an%x00%at%x00%s",
            "\(base.hex)..\(head.hex)", "--",
        ])
        var fields = result.output.split(separator: 0, omittingEmptySubsequences: false)
        if result.output.last == 0 || result.output.isEmpty { fields.removeLast() }
        guard fields.count % 4 == 0 else {
            throw GitError.unexpectedOutput(subcommand: "log", expected: "4 fields per commit")
        }
        return try stride(from: 0, to: fields.count, by: 4).map { start in
            guard let sha = ObjectID(bytes: fields[start]), let seconds = TimeInterval(String(decoding: fields[start + 2], as: UTF8.self)) else {
                throw GitError.unexpectedOutput(subcommand: "log", expected: "a commit name and a Unix time")
            }
            return CommitInfo(
                sha: sha,
                subject: String(decoding: fields[start + 3], as: UTF8.self),
                author: String(decoding: fields[start + 1], as: UTF8.self),
                date: Date(timeIntervalSince1970: seconds)
            )
        }
    }

    /// The blob at `path` in `commit`, or nil when the commit has no file there.
    public func blobID(in commit: ObjectID, at path: GitPath) async throws -> ObjectID? {
        guard let text = path.exactString, !text.contains("\n") else {
            return try await blobIDByListingTree(of: commit, at: path)
        }
        let result = try await git.run(["ls-tree", "-z", "--full-tree", commit.hex, "--", text])
        return try Self.blobs(inTreeListing: result.output).first { $0.path == path }?.blob
    }

    /// Lists the whole tree, for a path git cannot be given as an argument.
    private func blobIDByListingTree(of commit: ObjectID, at path: GitPath) async throws -> ObjectID? {
        let result = try await git.run(["ls-tree", "-z", "-r", "--full-tree", commit.hex])
        return try Self.blobs(inTreeListing: result.output).first { $0.path == path }?.blob
    }

    /// Reads `<mode> <type> <object>\t<path>` records from `git ls-tree -z`.
    static func blobs(inTreeListing output: Data) throws -> [(path: GitPath, blob: ObjectID)] {
        try output.split(separator: 0).compactMap { record in
            guard let tab = record.firstIndex(of: 0x09) else {
                throw GitError.unexpectedOutput(subcommand: "ls-tree", expected: "\"<mode> <type> <object>\\t<path>\" records")
            }
            let fields = record[..<tab].split(separator: 0x20)
            guard fields.count == 3, let object = ObjectID(bytes: fields[2]) else {
                throw GitError.unexpectedOutput(subcommand: "ls-tree", expected: "\"<mode> <type> <object>\\t<path>\" records")
            }
            guard fields[1].elementsEqual("blob".utf8) else { return nil }
            return (GitPath(bytes: record[(tab + 1)...]), object)
        }
    }

    func objectID(in result: GitResult, from subcommand: String) throws -> ObjectID {
        guard let id = ObjectID(result.text) else {
            throw GitError.unexpectedOutput(subcommand: subcommand, expected: "one object name")
        }
        return id
    }
}
