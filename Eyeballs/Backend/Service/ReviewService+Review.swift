import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation

extension ReviewService {
    /// `eyeballs review`, following design C, "`eyeballs review`, step by step".
    func review(_ arguments: ReviewArguments, client: ClientIdentity) async throws -> (ReviewResult, String) {
        try await oneAtATime.run { try await self.reviewNow(arguments, client: client) }
    }

    private func reviewNow(_ arguments: ReviewArguments, client: ClientIdentity) async throws -> (ReviewResult, String) {
        let session = try register(client)
        // Step 1. Finding the stack refuses with mid_operation during a real operation (fix 9).
        let found = try await findStack(for: arguments, client: client)
        let repo = try await recordRepo(found.repository, remote: found.discovered.remoteRepository)
        let stack = try store.findOrCreateStack(repoID: repo.id, Self.description(of: found.discovered)).stack

        // Step 2, across the whole stack, whichever session read the threads (fix 11).
        if !arguments.force { try refuseUnreplied(stack) }

        // Steps 3 to 5.
        let dirtyFiles = await dirtyFileCount(in: found.repository, stack: found.discovered)
        let outcome = try await recordRevision(
            found.discovered, of: stack, repo: repo, in: found.repository,
            trigger: .agentSubmit, session: session, note: arguments.note, dirtyFiles: dirtyFiles)

        // Steps 6 and 7.
        try takeDriverRole(of: stack, for: session)
        notify(.agentReview(stackID: stack.id, revisionNumber: outcome.revision.number, created: outcome.created))
        showWindow(forStack: stack.id, focus: arguments.focus)

        let result = try await reviewResult(outcome, repo: repo, discovered: found.discovered, dirtyFiles: dirtyFiles,
                                            listener: Self.listener(for: client, session: session))
        return (result, ReviewText.render(result, reviewer: await reviewerName(for: repo)))
    }

    private func reviewResult(_ outcome: RevisionOutcome, repo: RepoRecord, discovered: DiscoveredStack, dirtyFiles: Int,
                              listener: ListenerKey?) async throws -> ReviewResult {
        let facts = try facts(outcome.stack.id)
        let files = try store.files(ofSnapshots: outcome.snapshots.map(\.id))
        let previous = outcome.previous.map { facts.revisionSnapshots[$0.id] ?? [:] } ?? [:]
        let layers = zip(outcome.layers, outcome.snapshots).map { layer, snapshot in
            let changed = files[snapshot.id] ?? []
            return ReviewLayer(
                position: layer.position, branch: layer.branch, pr: layer.prNumber, files: changed.count,
                additions: changed.reduce(0) { $0 + ($1.additions ?? 0) }, deletions: changed.reduce(0) { $0 + ($1.deletions ?? 0) },
                baseRule: snapshot.baseRule.rawValue, changedSinceLast: outcome.created && previous[layer.id] != snapshot.id)
        }

        var warnings: [Warning] = []
        if dirtyFiles > 0 {
            warnings.append(Warning(code: .dirtyWorktree,
                                    message: "\(AgentText.count(dirtyFiles, "uncommitted file")) \(dirtyFiles == 1 ? "is" : "are") not in this revision."))
        }
        warnings += discovered.warnings.map(Self.warning)

        let waiting = try store.threadsWaitingOnAgent(stackID: outcome.stack.id).map { ThreadID($0.thread.id) }
        let waitingOnReviewer = facts.threads.filter { facts.progress(of: $0).state.needsYou }.count
        return ReviewResult(
            stack: summary(of: facts.stack, repo: repo), revision: outcome.revision.number, created: outcome.created,
            layers: layers, ported: outcome.ported, warnings: warnings, waitingOnYou: waiting,
            waitingOnReviewer: waitingOnReviewer, listening: listening(listener),
            next: waiting.isEmpty ? .runWaitInBackground : .runInbox)
    }

    private static func warning(_ warning: StackWarning) -> Warning {
        let code: WarningCode = switch warning {
        case .staleRebaseState: "stale_rebase_state"
        case .mergedBranchMissing: "merged_branch_missing"
        case .operationInProgress: "operation_in_progress"
        }
        return Warning(code: code, message: warning.description)
    }

    /// Refuses with `unreplied` when an open thread that `inbox` already showed has no newer
    /// agent reply (fix 11). `--force` skips this.
    func refuseUnreplied(_ stack: StackRecord) throws {
        let shown = try store.threadsWaitingOnAgent(stackID: stack.id).filter(\.wasShown)
        guard !shown.isEmpty else { return }
        let ids = AgentText.list(shown.map { "t\($0.thread.id)" })
        throw EyeballsError(
            .unreplied,
            "\(ids) \(shown.count == 1 ? "has" : "have") no reply yet, and eyeballs inbox already showed \(shown.count == 1 ? "it" : "them").",
            hint: "Reply with eyeballs reply --file -, then run eyeballs review again. Pass --force to submit anyway.")
    }

    /// Uncommitted files in the agent's worktree, when it has a stack branch checked out.
    private func dirtyFileCount(in repository: GitRepository, stack: DiscoveredStack) async -> Int {
        guard repository.workTree != nil,
              let branch = try? await repository.currentBranch(), stack.layers.contains(where: { $0.branch == branch }),
              let status = try? await repository.git.run(["status", "--porcelain=v1", "-z", "--untracked-files=normal"]) else { return 0 }
        var count = 0
        var skipNext = false
        for entry in status.output.split(separator: 0) {
            if skipNext {
                skipNext = false
                continue
            }
            count += 1
            // A rename or copy entry is followed by its old path.
            if let first = entry.first, first == UInt8(ascii: "R") || first == UInt8(ascii: "C") { skipNext = true }
        }
        return count
    }

    // MARK: Finding the stack

    struct FoundStack: Sendable {
        var repository: GitRepository
        var discovered: DiscoveredStack
    }

    func findStack(for arguments: ReviewArguments, client: ClientIdentity) async throws -> FoundStack {
        if let reference = arguments.stack {
            return try await findStack(reference, client: client)
        }
        let repository = try await repository(at: URL(fileURLWithPath: client.cwd, isDirectory: true))
        let reader = StackReader(repository: repository)
        if let branch = arguments.branch {
            return FoundStack(repository: repository, discovered: try await reader.singleBranch(branch, trunk: arguments.trunk))
        }
        if let branches = arguments.branches {
            return FoundStack(repository: repository, discovered: try await reader.branchList(branches, trunk: arguments.trunk))
        }
        guard let branch = try await repository.currentBranch() else {
            throw EyeballsError(.noStack, "HEAD is detached here, so Eyeballs cannot tell which stack to review.",
                                hint: "Check out a branch of the stack, or pass --stack, --branch or --branches.")
        }
        return try await findStack(containing: branch, in: repository)
    }

    private func findStack(_ reference: StackReference, client: ClientIdentity) async throws -> FoundStack {
        switch reference {
        case .id(let id):
            guard let stack = try store.stack(id: id.number), let repo = try store.repo(id: stack.repoID) else {
                throw EyeballsError(.noStack, "No stack \(id) exists in Eyeballs.", hint: "Run eyeballs threads or eyeballs status to see your stacks.")
            }
            let repository = try await repository(for: repo)
            return FoundStack(repository: repository, discovered: try await rediscover(stack, in: repository))
        case .branch(let branch):
            let repository = try await repository(at: URL(fileURLWithPath: client.cwd, isDirectory: true))
            return try await findStack(containing: branch, in: repository)
        }
    }

    /// The stack Eyeballs already knows with this branch, else the gh-stack stack that has it,
    /// else the branch on its own against the default trunk.
    func findStack(containing branch: String, in repository: GitRepository) async throws -> FoundStack {
        if let repo = try store.repo(commonDir: repository.commonDirectory.path),
           let stack = try store.activeStacks(containing: branch, repoID: repo.id).first {
            return FoundStack(repository: repository, discovered: try await rediscover(stack, in: repository, preferring: branch))
        }
        let reader = StackReader(repository: repository)
        do {
            return FoundStack(repository: repository, discovered: try await reader.ghStack(containing: branch))
        } catch StackError.noCatalog {
        } catch StackError.noStack {
        }
        return FoundStack(repository: repository, discovered: try await reader.singleBranch(branch))
    }

    /// Reads a known stack again from git, the way it was first read.
    func rediscover(_ stack: StackRecord, in repository: GitRepository, preferring preferred: String? = nil) async throws -> DiscoveredStack {
        let reader = StackReader(repository: repository)
        let branches = try store.activeLayers(stackID: stack.id).map(\.branch)
        switch stack.source {
        case .branchList where !branches.isEmpty:
            return try await reader.branchList(branches, trunk: stack.trunkBranch)
        case .singleBranch, .branchList:
            return try await reader.singleBranch(branches.last ?? preferred ?? stack.name, trunk: stack.trunkBranch)
        default:
            var lastError: any Error = StackError.noStack(branch: stack.name)
            for branch in [preferred].compactMap({ $0 }) + branches.reversed() {
                do {
                    return try await reader.ghStack(containing: branch)
                } catch StackError.noStack {
                    lastError = StackError.noStack(branch: branch)
                }
            }
            throw lastError
        }
    }

    static func description(of discovered: DiscoveredStack) -> StackDescription {
        StackDescription(
            name: discovered.name, source: StoredSource(discovered.source), trunkBranch: discovered.trunk,
            branches: discovered.layers.map(\.branch), ghStackID: discovered.ghStackID, ghStackNumber: discovered.ghStackNumber)
    }

    // MARK: Recording a revision

    struct RevisionOutcome: Sendable {
        var stack: StackRecord
        var revision: RevisionRecord
        /// False when the stack had not changed, so `revision` is the latest one.
        var created: Bool
        /// The revision before this one, or `revision` itself when nothing changed.
        var previous: RevisionRecord?
        /// The stack's layers now, bottom first, with each one's snapshot.
        var layers: [LayerRecord]
        var snapshots: [SnapshotRecord]
        var ported: PortCounts
    }

    /// Snapshots every layer and records a revision, unless nothing changed since the latest one.
    ///
    /// Pins come first, so a row never names a commit that `git gc` may delete. Then the
    /// snapshot and revision rows, then the open threads move to the new revision.
    func recordRevision(
        _ discovered: DiscoveredStack, of stack: StackRecord, repo: RepoRecord, in repository: GitRepository,
        trigger: RevisionTrigger, session: AgentSessionRecord?, note: String?, dirtyFiles: Int
    ) async throws -> RevisionOutcome {
        let oldNames = Dictionary(discovered.renamedBranches.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let descriptions = discovered.layers.map {
            LayerDescription(branch: $0.branch, prNumber: $0.pullRequest?.number, prURL: $0.pullRequest?.url, previousBranch: oldNames[$0.branch])
        }
        let merged = Set(discovered.warnings.compactMap { warning -> String? in
            if case .mergedBranchMissing(let branch) = warning { return branch }
            return nil
        })
        let layers = try store.syncLayers(stackID: stack.id, descriptions, mergedBranches: merged)
        let previous = try store.latestRevision(stackID: stack.id)
        let previousSnapshots = try previous.map { try store.snapshotIDs(ofRevision: $0.id) } ?? [:]

        var saved: [SnapshotRecord?] = []
        for (layer, found) in zip(layers, discovered.layers) {
            saved.append(try store.snapshot(layerID: layer.id, base: found.base.hex, head: found.head.hex))
        }
        var savedSnapshots: [Int: Int] = [:]
        for (layer, snapshot) in zip(layers, saved) {
            if let snapshot { savedSnapshots[layer.id] = snapshot.id }
        }
        let unchanged = savedSnapshots.count == layers.count && savedSnapshots == previousSnapshots
        if unchanged, let previous {
            return RevisionOutcome(stack: stack, revision: previous, created: false, previous: previous,
                                   layers: layers, snapshots: saved.compactMap { $0 }, ported: PortCounts())
        }

        let heads = discovered.layers.map(\.head)
        try await PinStore(repository: repository, installID: store.installID).pin(heads)
        try store.recordPins(repoID: repo.id, shas: heads.map(\.hex))

        var snapshots: [SnapshotRecord] = []
        for (index, (layer, found)) in zip(layers, discovered.layers).enumerated() {
            if let existing = saved[index] {
                snapshots.append(existing)
            } else {
                snapshots.append(try store.insertSnapshot(try await snapshotDescription(of: found, layerID: layer.id, in: repository)))
            }
        }
        let placed = zip(layers, snapshots).map { RevisionLayerDescription(layerID: $0.id, position: $0.position, snapshotID: $1.id) }
        let (revision, created) = try store.createRevision(
            stackID: stack.id, trigger: trigger, layers: placed, agentSession: session?.id, agentNote: note, dirtyFiles: dirtyFiles)
        let ported = created ? try await portOpenThreads(stackID: stack.id, to: revision, in: repository) : PortCounts()
        if created { Log.store.info("Recorded r\(revision.number, privacy: .public) of s\(stack.id, privacy: .public)") }
        return RevisionOutcome(stack: stack, revision: revision, created: created, previous: created ? previous : revision,
                               layers: layers, snapshots: snapshots, ported: ported)
    }

    private func snapshotDescription(of layer: StackLayer, layerID: Int, in repository: GitRepository) async throws -> SnapshotDescription {
        let files = try await repository.changedFiles(from: layer.base, to: layer.head)
        let baseTree = try await repository.tree(of: layer.base)
        let headTree = try await repository.tree(of: layer.head)
        return SnapshotDescription(
            layerID: layerID, baseSHA: layer.base.hex, headSHA: layer.head.hex, baseTree: baseTree.hex, headTree: headTree.hex,
            baseRule: StoredBaseRule(rawValue: layer.baseRule.rawValue), parentRef: layer.parentRef,
            files: Self.uniqueByPath(files).map(Self.snapshotFile))
    }

    /// `snapshot_file` holds one row per path.
    private static func uniqueByPath(_ files: [DiffFile]) -> [DiffFile] {
        var seen = Set<String>()
        return files.filter { seen.insert($0.path.string).inserted }
    }

    private static func snapshotFile(_ file: DiffFile) -> SnapshotDescription.File {
        let keepsOldPath = file.change == .renamed || file.change == .copied
        return SnapshotDescription.File(
            path: file.path.string, oldPath: keepsOldPath ? file.oldPath?.string : nil, change: FileChangeKind(rawValue: file.change.letter),
            baseBlob: file.oldBlob.flatMap { $0.isZero ? nil : $0.hex }, headBlob: file.newBlob.flatMap { $0.isZero ? nil : $0.hex },
            additions: file.isBinary ? nil : file.additions, deletions: file.isBinary ? nil : file.deletions)
    }

    // MARK: Snapshots you start

    /// Takes a `human_start` revision when the branch tips moved past the latest revision, as
    /// Submit and Send now do (fix 13). Returns the newest revision.
    ///
    /// When git cannot read the stack now, for example during the agent's rebase, it keeps the
    /// latest revision, because your comment matters more than a fresh snapshot.
    func snapshotIfMoved(_ stackID: Int) async throws -> RevisionRecord {
        guard let stack = try store.stack(id: stackID), let repo = try store.repo(id: stack.repoID) else {
            throw EyeballsError(.noStack, "Stack s\(stackID) no longer exists.")
        }
        let latest = try store.latestRevision(stackID: stackID)
        do {
            let repository = try await repository(for: repo)
            let discovered = try await rediscover(stack, in: repository)
            let outcome = try await recordRevision(discovered, of: stack, repo: repo, in: repository,
                                                   trigger: .humanStart, session: nil, note: nil, dirtyFiles: 0)
            return outcome.revision
        } catch {
            guard let latest else { throw error }
            Log.store.info("Kept r\(latest.number, privacy: .public) of s\(stackID, privacy: .public): \(String(describing: error), privacy: .public)")
            return latest
        }
    }
}

extension Store {
    /// Each layer's snapshot in a revision, by layer ID.
    func snapshotIDs(ofRevision revisionID: Int) throws -> [Int: Int] {
        try reader.read { db in
            let rows = try RevisionLayerRecord.filter(sql: "revision_id = ?", arguments: [revisionID]).fetchAll(db)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0.layerID, $0.snapshotID) })
        }
    }
}
