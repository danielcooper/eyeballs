import Foundation

extension GitRepository {
    /// Every changed file in `base..head`, with its hunks at 3 lines of context.
    ///
    /// Paths, modes and blobs come from `git diff --raw -z`, which is exact even for 100%
    /// renames and mode-only changes. Hunks come from the patch. A type change, which git prints
    /// as a deletion and an addition, comes back as one `.typeChanged` file with both sets of hunks.
    public func changedFiles(from base: ObjectID, to head: ObjectID) async throws -> [DiffFile] {
        async let raw = rawDiff(from: base, to: head)
        async let patch = git.run(["diff"] + Self.patchOptions + ["-M", "-U3", "--diff-algorithm=myers", base.hex, head.hex, "--"])
        let patches = try UnifiedDiffParser.parse(try await patch.output)
        return Self.combine(raw: try await raw, patches: patches)
    }

    /// `git diff --raw -z` for two commits. Pass a `renameThreshold` such as 60 to find renames
    /// at that similarity; nil uses git's default of 50.
    public func rawDiff(from base: ObjectID, to head: ObjectID, renameThreshold: Int? = nil) async throws -> [RawDiffEntry] {
        let renames = renameThreshold.map { "-M\($0)%" } ?? "-M"
        let result = try await git.run(["diff", "--raw", "-z", "--no-abbrev", renames] + Self.listingOptions + [base.hex, head.hex, "--"])
        return try RawDiffParser.parse(result.output)
    }

    /// `git diff --numstat -z` for two commits, to check the counts the window shows.
    public func numstat(from base: ObjectID, to head: ObjectID) async throws -> [NumstatEntry] {
        let result = try await git.run(["diff", "--numstat", "-z", "-M"] + Self.listingOptions + [base.hex, head.hex, "--"])
        return try NumstatParser.parse(result.output)
    }

    /// The hunks that turn one blob into another, with `contextLines` of context.
    ///
    /// The porter uses 0 context and the histogram algorithm, as Gerrit does. Returns a file with
    /// no hunks when the blobs are equal, and one marked binary when git treats them as binary.
    public func diffBlobs(_ old: ObjectID, _ new: ObjectID, contextLines: Int = 0) async throws -> DiffFile {
        guard old != new else { return DiffFile(oldPath: nil, newPath: nil, change: .modified, oldBlob: old, newBlob: new) }
        let result = try await git.run(["diff"] + Self.patchOptions + ["-U\(max(0, contextLines))", "--histogram", old.hex, new.hex])
        var file = try UnifiedDiffParser.parse(result.output).first
            ?? DiffFile(oldPath: nil, newPath: nil, change: .modified)
        file.oldBlob = old
        file.newBlob = new
        return file
    }

    /// A blob split into lines, read through the blob reader.
    public func fileText(_ blob: ObjectID) async throws -> FileText {
        FileText(try await blobs.blob(blob))
    }

    /// Both sides of a changed file as lines, for context expansion. A side is nil when the file
    /// does not exist there, or is binary or a submodule.
    public func fileTexts(for file: DiffFile) async throws -> (old: FileText?, new: FileText?) {
        guard !file.isBinary else { return (nil, nil) }
        var old: FileText?
        var new: FileText?
        if let blob = file.oldBlob, file.oldMode?.isSubmodule != true { old = try await fileText(blob) }
        if let blob = file.newBlob, file.newMode?.isSubmodule != true { new = try await fileText(blob) }
        return (old, new)
    }

    static let patchOptions = [
        "--no-ext-diff", "--no-textconv", "--no-color", "--no-relative", "--full-index",
        "--src-prefix=a/", "--dst-prefix=b/", "--submodule=short", "--ignore-submodules=none",
        "-O/dev/null", "--inter-hunk-context=0",
    ]

    static let listingOptions = ["--no-ext-diff", "--no-textconv", "--no-relative", "--ignore-submodules=none", "-O/dev/null"]

    /// Puts the raw entries' exact paths and blobs together with the patch's hunks.
    static func combine(raw: [RawDiffEntry], patches: [DiffFile]) -> [DiffFile] {
        var waiting = PatchesByPath(patches)
        return raw.map { entry in
            let parts = entry.change == .typeChanged
                ? [waiting.take(old: entry.oldPath, new: nil), waiting.take(old: nil, new: entry.newPath)].compactMap { $0 }
                : [waiting.take(old: entry.oldPath, new: entry.newPath)].compactMap { $0 }
            return DiffFile(
                oldPath: entry.oldPath, newPath: entry.newPath, change: entry.change,
                oldMode: entry.oldMode, newMode: entry.newMode, oldBlob: entry.oldBlob, newBlob: entry.newBlob,
                similarity: entry.score, isBinary: parts.contains { $0.isBinary }, hunks: parts.flatMap(\.hunks)
            )
        }
    }
}

/// Patch entries waiting to be matched with raw entries, by their pair of paths.
struct PatchesByPath {
    private var waiting: [PathPair: [DiffFile]] = [:]

    init(_ patches: [DiffFile]) {
        for patch in patches {
            waiting[PathPair(old: patch.oldPath, new: patch.newPath), default: []].append(patch)
        }
    }

    mutating func take(old: GitPath?, new: GitPath?) -> DiffFile? {
        let key = PathPair(old: old, new: new)
        guard var queue = waiting[key], !queue.isEmpty else { return nil }
        let first = queue.removeFirst()
        waiting[key] = queue
        return first
    }

    private struct PathPair: Hashable {
        var old: GitPath?
        var new: GitPath?
    }
}
