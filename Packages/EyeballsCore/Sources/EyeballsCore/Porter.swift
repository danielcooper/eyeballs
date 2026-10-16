import Foundation

/// The PR 7 porter: carries a line thread from one revision's file to the next.
///
/// If the blob is unchanged, the thread stays put. Otherwise Gerrit's shift rule moves it past
/// hunks above it, and any hunk that touches its lines makes it outdated. Every result is then
/// checked against the new blob's text, and a result whose lines no longer match comes back
/// outdated, because an outdated thread beats a wrong one.
public enum SimplePorter: Sendable {
    /// Ports `anchor` to `target`. A pure function: the same inputs always give the same result.
    public static func port(_ anchor: PortAnchor, to target: PortTarget) -> PortResult {
        guard let path = target.path else {
            return PortResult(placement: .gone, path: nil, blob: nil, method: .fallback)
        }
        guard let blob = target.blob, let text = target.text else {
            return PortResult(placement: .outdated(nearLine: nil), path: path, blob: target.blob, method: .fallback)
        }

        let candidate: ClosedRange<Int>?
        let method: PortMethod
        if blob == anchor.blob {
            candidate = anchor.lines
            method = .sameBlob
        } else if target.isBinary {
            candidate = nil
            method = .fallback
        } else {
            candidate = shift(anchor.lines, through: target.hunks)
            method = .diffShift
        }

        guard let lines = candidate, text.lines(in: lines) == anchor.coveredLines else {
            let near = blob == anchor.blob || target.isBinary ? nil : nearLine(for: anchor.lines, hunks: target.hunks, newLineCount: text.lineCount)
            return PortResult(placement: .outdated(nearLine: near), path: path, blob: blob, method: .fallback)
        }
        let placement: PortResult.Placement = lines == anchor.lines ? .current(lines) : .moved(lines)
        return PortResult(placement: placement, path: path, blob: blob, method: method)
    }

    /// Gerrit's shift rule on `-U0` hunks, sorted by `oldStart`. Lines are 1-based and inclusive.
    ///
    /// Returns the range moved past every hunk above it, or nil when a hunk touches the range or
    /// inserts lines inside it. A hunk with an old count of 0 inserts after old line `oldStart`.
    public static func shift(_ range: ClosedRange<Int>, through hunks: [DiffHunk]) -> ClosedRange<Int>? {
        var delta = 0
        for hunk in hunks {
            if hunk.oldCount == 0 {
                if hunk.oldStart < range.lowerBound {
                    delta += hunk.newCount
                    continue
                }
                if hunk.oldStart >= range.upperBound { break }
                return nil
            }
            let lastOldLine = hunk.oldStart + hunk.oldCount - 1
            if lastOldLine < range.lowerBound {
                delta += hunk.newCount - hunk.oldCount
                continue
            }
            if hunk.oldStart > range.upperBound { break }
            return nil
        }
        return (range.lowerBound + delta)...(range.upperBound + delta)
    }

    /// Where the lines of an outdated thread used to sit in the new file, for "was near line N".
    ///
    /// It is the new number of the first unchanged line after the range, or else of the last one
    /// before it. A hint only: a thread never ports from it.
    public static func nearLine(for range: ClosedRange<Int>, hunks: [DiffHunk], newLineCount: Int) -> Int? {
        var after = range.upperBound + 1
        while let hunk = hunks.first(where: { $0.oldCount > 0 && ($0.oldStart...($0.oldStart + $0.oldCount - 1)).contains(after) }) {
            after = hunk.oldStart + hunk.oldCount
        }
        guard newLineCount > 0 else { return nil }
        let afterInNewFile = after + delta(before: after, hunks: hunks)
        if (1...newLineCount).contains(afterInNewFile) { return afterInNewFile }

        var before = range.lowerBound - 1
        while let hunk = hunks.first(where: { $0.oldCount > 0 && ($0.oldStart...($0.oldStart + $0.oldCount - 1)).contains(before) }) {
            before = hunk.oldStart - 1
        }
        let beforeInNewFile = before + delta(before: before, hunks: hunks)
        return before >= 1 && (1...newLineCount).contains(beforeInNewFile) ? beforeInNewFile : nil
    }

    /// How far hunks above an unchanged old line move it.
    private static func delta(before oldLine: Int, hunks: [DiffHunk]) -> Int {
        hunks.reduce(0) { total, hunk in
            let isAbove = hunk.oldCount == 0 ? hunk.oldStart < oldLine : hunk.oldStart + hunk.oldCount - 1 < oldLine
            return isAbove ? total + hunk.newCount - hunk.oldCount : total
        }
    }
}

/// Where a line thread sits in the revision it ports from.
public struct PortAnchor: Hashable, Sendable {
    public var path: GitPath
    /// Base-side anchors port from base blob to base blob, as Gerrit does.
    public var side: DiffSide
    /// 1-based and inclusive.
    public var lines: ClosedRange<Int>
    public var blob: ObjectID
    /// The exact bytes of each covered line, without newlines, as `FileText` splits them.
    public var coveredLines: [[UInt8]]

    public init(path: GitPath, side: DiffSide, start: Int, end: Int, blob: ObjectID, coveredLines: [[UInt8]]) {
        self.path = path
        self.side = side
        self.lines = min(start, end)...max(start, end)
        self.blob = blob
        self.coveredLines = coveredLines
    }
}

/// What the porter needs to know about the file in the revision it ports to.
public struct PortTarget: Hashable, Sendable {
    /// The anchor's path followed through renames. Nil when the file was deleted.
    public var path: GitPath?
    public var blob: ObjectID?
    /// The target blob's text, which every result is checked against.
    public var text: FileText?
    /// The `-U0` hunks from the anchor's blob to the target blob. Empty when the blob is the same.
    public var hunks: [DiffHunk]
    public var isBinary: Bool

    public init(path: GitPath?, blob: ObjectID?, text: FileText?, hunks: [DiffHunk] = [], isBinary: Bool = false) {
        self.path = path
        self.blob = blob
        self.text = text
        self.hunks = hunks
        self.isBinary = isBinary
    }
}

/// Where a ported thread landed. It maps onto an `anchor` row: `state`, `method`, `path`, `blob`,
/// `start_line`, `end_line` and `near_line`.
public struct PortResult: Hashable, Sendable {
    public enum Placement: Hashable, Sendable {
        /// The same lines as before.
        case current(ClosedRange<Int>)
        /// New line numbers, same text.
        case moved(ClosedRange<Int>)
        /// The lines are gone or changed. `nearLine` is a display hint only.
        case outdated(nearLine: Int?)
        /// The file was deleted.
        case gone
    }

    public var placement: Placement
    public var path: GitPath?
    public var blob: ObjectID?
    public var method: PortMethod

    /// The `anchor.state` value.
    public var state: String {
        switch placement {
        case .current: "current"
        case .moved: "moved"
        case .outdated: "outdated"
        case .gone: "gone"
        }
    }

    /// The new line range, for current and moved results.
    public var lines: ClosedRange<Int>? {
        switch placement {
        case let .current(lines), let .moved(lines): lines
        case .outdated, .gone: nil
        }
    }

    public var nearLine: Int? {
        if case let .outdated(nearLine) = placement { return nearLine }
        return nil
    }

    /// True when the result's lines were checked against the target text and matched.
    public var isVerified: Bool { lines != nil }
}

/// How a result was found. The raw values match the `anchor.method` column.
public enum PortMethod: String, Hashable, Sendable {
    case sameBlob = "same_blob"
    case diffShift = "diff_shift"
    case fallback
}

/// Where a path went between two commits.
public enum FollowedPath: Hashable, Sendable {
    /// The file did not change.
    case unchanged(GitPath)
    /// The file changed, was renamed, or both.
    case changed(GitPath, blob: ObjectID)
    case deleted
}

extension GitRepository {
    /// Ports a line thread from the commit it was on to a newer one. Pass the base commits for a
    /// base-side anchor and the head commits for a head-side one.
    public func port(_ anchor: PortAnchor, from oldCommit: ObjectID, to newCommit: ObjectID) async throws -> PortResult {
        SimplePorter.port(anchor, to: try await portTarget(for: anchor, from: oldCommit, to: newCommit))
    }

    /// Gathers what `SimplePorter.port` needs: the followed path, the target blob and its text,
    /// and the `-U0` histogram hunks between the two blobs.
    public func portTarget(for anchor: PortAnchor, from oldCommit: ObjectID, to newCommit: ObjectID) async throws -> PortTarget {
        switch try await followPath(anchor.path, from: oldCommit, to: newCommit) {
        case .deleted:
            return PortTarget(path: nil, blob: nil, text: nil)
        case let .unchanged(path):
            return PortTarget(path: path, blob: anchor.blob, text: try await textIfBlob(anchor.blob))
        case let .changed(path, blob):
            guard let text = try await textIfBlob(blob) else { return PortTarget(path: path, blob: blob, text: nil) }
            guard blob != anchor.blob else { return PortTarget(path: path, blob: blob, text: text) }
            let diff = try await diffBlobs(anchor.blob, blob, contextLines: 0)
            return PortTarget(path: path, blob: blob, text: text, hunks: diff.hunks, isBinary: diff.isBinary)
        }
    }

    /// The text of a blob, or nil when the object is missing or is not a blob, as for a submodule.
    private func textIfBlob(_ id: ObjectID) async throws -> FileText? {
        do {
            return try await fileText(id)
        } catch GitError.missingObject, GitError.notABlob {
            return nil
        }
    }

    /// Follows a path from one commit to another through renames, with `git diff -M60%`.
    public func followPath(_ path: GitPath, from oldCommit: ObjectID, to newCommit: ObjectID) async throws -> FollowedPath {
        guard oldCommit != newCommit else { return .unchanged(path) }
        let entries = try await rawDiff(from: oldCommit, to: newCommit, renameThreshold: 60)
        guard let entry = entries.first(where: { $0.oldPath == path && $0.change != .copied }) else { return .unchanged(path) }
        guard let newPath = entry.newPath, let blob = entry.newBlob else { return .deleted }
        return .changed(newPath, blob: blob)
    }
}
