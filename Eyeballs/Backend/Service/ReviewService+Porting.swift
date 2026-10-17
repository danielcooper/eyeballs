import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation

extension ReviewService {
    /// Moves every open thread of the stack to `target`, recording one anchor each.
    ///
    /// Each thread ports from its last good anchor, so a thread that went outdated can come back.
    /// Resolved threads never port, and a thread that already has an anchor at `target` is left
    /// alone. A thread whose port fails becomes outdated rather than failing the revision.
    /// - Parameter only: port just these threads, as Send now and Reopen do.
    @discardableResult
    func portOpenThreads(stackID: Int, to target: RevisionRecord, in repository: GitRepository, only: Set<Int>? = nil) async throws -> PortCounts {
        let facts = try facts(stackID)
        let targetSnapshots = Array((facts.revisionSnapshots[target.id] ?? [:]).values)
        let targetFiles = try store.files(ofSnapshots: targetSnapshots)
        var counts = PortCounts()
        for thread in facts.threads where thread.status == .open && (only?.contains(thread.id) ?? true) {
            let anchors = facts.anchors[thread.id] ?? []
            guard let from = anchors.last(where: { $0.state.isGood || $0.method == .human }),
                  from.revisionID != target.id, !anchors.contains(where: { $0.revisionID == target.id }) else { continue }
            let ported: PortedAnchor
            do {
                ported = try await port(thread, from: from, to: target, facts: facts, targetFiles: targetFiles, in: repository)
            } catch {
                Log.port.error("t\(thread.id, privacy: .public) could not port to r\(target.number, privacy: .public): \(String(describing: error), privacy: .public)")
                ported = PortedAnchor.outdated(from: from, thread: thread, target: target, snapshotID: facts.snapshot(layerID: thread.layerID, revisionID: target.id)?.id)
            }
            do {
                _ = try store.addAnchor(threadID: thread.id, ported.anchor, state: ported.state, method: ported.method,
                                        verified: ported.verified, nearLine: ported.nearLine, portedFrom: from.id)
            } catch {
                // Another flow ported this thread to the same revision first, which the store's index refuses twice.
                continue
            }
            counts.count(ported.state)
        }
        return counts
    }

    private func port(_ thread: ThreadRecord, from: AnchorRecord, to target: RevisionRecord, facts: StackFacts,
                      targetFiles: [Int: [SnapshotFileRecord]], in repository: GitRepository) async throws -> PortedAnchor {
        guard let toSnapshot = facts.snapshot(layerID: thread.layerID, revisionID: target.id) else {
            return PortedAnchor.gone(from: from, thread: thread, target: target, snapshotID: from.snapshotID, path: from.path)
        }
        let filesInDiff = Set((targetFiles[toSnapshot.id] ?? []).map(\.path))
        func carried(path: String?, blob: String?) -> PortedAnchor {
            PortedAnchor(
                anchor: NewAnchor(revisionID: target.id, snapshotID: toSnapshot.id, layerID: thread.layerID, path: path, blob: blob,
                                  inDiff: path.map(filesInDiff.contains) ?? true, engineVersion: Self.engineVersion),
                state: .current, method: .sameBlob, verified: true, nearLine: nil)
        }

        if thread.subject == .layer { return carried(path: nil, blob: nil) }
        guard let fromSnapshot = facts.snapshots[from.snapshotID], let path = from.path else {
            return PortedAnchor.outdated(from: from, thread: thread, target: target, snapshotID: toSnapshot.id)
        }
        let side = thread.side?.git ?? .head
        let oldCommit = try Self.commit(of: fromSnapshot, side: side)
        let newCommit = try Self.commit(of: toSnapshot, side: side)

        if thread.subject == .file {
            switch try await repository.followPath(GitPath(path), from: oldCommit, to: newCommit) {
            case .unchanged(let followed): return carried(path: followed.string, blob: from.blob)
            case .changed(let followed, let blob): return carried(path: followed.string, blob: blob.hex)
            case .deleted: return PortedAnchor.gone(from: from, thread: thread, target: target, snapshotID: toSnapshot.id, path: nil)
            }
        }

        guard let blobHex = from.blob, let blob = ObjectID(blobHex), let start = from.startLine, let end = from.endLine else {
            return PortedAnchor.outdated(from: from, thread: thread, target: target, snapshotID: toSnapshot.id)
        }
        let covered = try await coveredLines(of: blob, in: start...end, repository: repository)
            ?? (from.coveredText ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.utf8) }
        let anchor = PortAnchor(path: GitPath(path), side: side, start: start, end: end, blob: blob, coveredLines: covered)
        let result = try await repository.port(anchor, from: oldCommit, to: newCommit)
        var text: AnchorText?
        if let lines = result.lines, let newBlob = result.blob {
            text = try await anchorText(of: newBlob, lines: lines, repository: repository)
        }
        let newPath = result.path?.string
        return PortedAnchor(
            anchor: NewAnchor(revisionID: target.id, snapshotID: toSnapshot.id, layerID: thread.layerID, path: newPath,
                              blob: result.blob?.hex, lines: result.lines, inDiff: newPath.map(filesInDiff.contains) ?? false,
                              coveredText: text?.covered, contextBefore: text?.before, contextAfter: text?.after,
                              engineVersion: Self.engineVersion),
            state: StoredAnchorState(rawValue: result.state), method: AnchorMethod(rawValue: result.method.rawValue),
            verified: result.isVerified, nearLine: result.nearLine)
    }

    /// The porter's version, kept on every anchor so a later porter can tell which one placed it.
    static let engineVersion = 1

    static func commit(of snapshot: SnapshotRecord, side: GitSide) throws -> ObjectID {
        let sha = side == .base ? snapshot.baseSHA : snapshot.headSHA
        guard let commit = ObjectID(sha) else {
            throw EyeballsError(.internalError, "Snapshot \(snapshot.id) names a commit that is not a valid object name.")
        }
        return commit
    }

    /// The exact bytes of each covered line, or nil when git no longer has the blob.
    func coveredLines(of blob: ObjectID, in range: ClosedRange<Int>, repository: GitRepository) async throws -> [[UInt8]]? {
        do {
            return try await repository.fileText(blob).lines(in: range)
        } catch GitError.missingObject, GitError.notABlob {
            return nil
        }
    }

    /// The covered lines and up to 3 lines of context on each side, as an anchor stores them.
    func anchorText(of blob: ObjectID, lines: ClosedRange<Int>, repository: GitRepository) async throws -> AnchorText? {
        let text: FileText
        do {
            text = try await repository.fileText(blob)
        } catch GitError.missingObject, GitError.notABlob {
            return nil
        }
        return AnchorText(text, lines: lines)
    }

    /// The anchor a new thread starts from: where you clicked, in the revision you were looking at.
    func originAnchor(for anchor: ThreadAnchor, layerID: Int, revisionID: Int, facts: StackFacts) async throws
        -> (subject: StoredSubject, side: StoredSide?, anchor: NewAnchor) {
        var revision = revisionID
        var snapshot = facts.snapshot(layerID: layerID, revisionID: revisionID)
        if snapshot == nil, let latest = facts.latestRevision {
            revision = latest.id
            snapshot = facts.snapshot(layerID: layerID, revisionID: latest.id)
        }
        guard let snapshot else {
            throw EyeballsError(.badInput, "This layer has no snapshot yet, so it cannot take a comment.", hint: "Take a snapshot of the stack first.")
        }
        let files = try store.files(ofSnapshots: [snapshot.id])[snapshot.id] ?? []

        switch anchor {
        case .layer:
            return (.layer, nil, NewAnchor(revisionID: revision, snapshotID: snapshot.id, layerID: layerID, inDiff: true,
                                           engineVersion: Self.engineVersion))
        case .file(let path):
            let file = files.first { $0.path == path }
            let side: StoredSide = file?.headBlob == nil && file?.baseBlob != nil ? .base : .head
            let blob = side == .head ? file?.headBlob : file?.baseBlob
            return (.file, side, NewAnchor(revisionID: revision, snapshotID: snapshot.id, layerID: layerID, path: path, blob: blob,
                                           inDiff: file != nil, engineVersion: Self.engineVersion))
        case .lines(let range):
            let side: StoredSide = range.side == .base ? .base : .head
            let file = files.first { $0.path == range.path }
            let repository = try await repository(for: facts.repo)
            var blob = side == .head ? file?.headBlob : file?.baseBlob
            if blob == nil {
                blob = try await repository.blobID(in: try Self.commit(of: snapshot, side: side.git), at: GitPath(range.path))?.hex
            }
            let lines = min(range.start, range.end)...max(range.start, range.end)
            var text: AnchorText?
            if let blob, let id = ObjectID(blob) {
                text = try await anchorText(of: id, lines: lines, repository: repository)
            }
            return (.line, side, NewAnchor(
                revisionID: revision, snapshotID: snapshot.id, layerID: layerID, path: range.path, blob: blob, lines: lines,
                inDiff: file != nil, coveredText: text?.covered, contextBefore: text?.before, contextAfter: text?.after,
                engineVersion: Self.engineVersion))
        }
    }
}

/// An anchor the porter worked out, ready for `Store.addAnchor`.
struct PortedAnchor: Sendable {
    var anchor: NewAnchor
    var state: StoredAnchorState
    var method: AnchorMethod
    var verified: Bool
    var nearLine: Int?

    static func outdated(from: AnchorRecord, thread: ThreadRecord, target: RevisionRecord, snapshotID: Int?) -> PortedAnchor {
        PortedAnchor(
            anchor: NewAnchor(revisionID: target.id, snapshotID: snapshotID ?? from.snapshotID, layerID: thread.layerID, path: from.path,
                              inDiff: false, engineVersion: ReviewService.engineVersion),
            state: .outdated, method: .fallback, verified: false, nearLine: nil)
    }

    static func gone(from: AnchorRecord, thread: ThreadRecord, target: RevisionRecord, snapshotID: Int, path: String?) -> PortedAnchor {
        PortedAnchor(
            anchor: NewAnchor(revisionID: target.id, snapshotID: snapshotID, layerID: thread.layerID, path: path, inDiff: false,
                              engineVersion: ReviewService.engineVersion),
            state: .gone, method: .fallback, verified: false, nearLine: nil)
    }
}

/// The text an anchor keeps: its covered lines and up to 3 lines on each side.
struct AnchorText: Sendable, Hashable {
    var covered: String
    var before: String?
    var after: String?

    init?(_ text: FileText, lines: ClosedRange<Int>) {
        guard text.lines(in: lines) != nil else { return nil }
        let strings = text.strings
        covered = strings[(lines.lowerBound - 1)...(lines.upperBound - 1)].joined(separator: "\n")
        let beforeStart = max(1, lines.lowerBound - 3)
        before = beforeStart < lines.lowerBound ? strings[(beforeStart - 1)...(lines.lowerBound - 2)].joined(separator: "\n") : nil
        let afterEnd = min(strings.count, lines.upperBound + 3)
        after = afterEnd > lines.upperBound ? strings[lines.upperBound...(afterEnd - 1)].joined(separator: "\n") : nil
    }
}

extension PortCounts {
    mutating func count(_ state: StoredAnchorState) {
        switch state {
        case .current, .original: current += 1
        case .moved: moved += 1
        case .whitespace: whitespace += 1
        case .changed: changed += 1
        case .relocated: relocated += 1
        case .outdated: outdated += 1
        case .gone: gone += 1
        case .unknown: break
        }
    }
}
