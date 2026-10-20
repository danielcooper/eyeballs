import Foundation

/// Checks whether a rebase or `gh stack modify` is part way through.
///
/// - A `gh-stack-modify-state` file blocks only in its applying or conflict phase, or in a phase
///   gh-stack itself would refuse. In its `pending_submit` phase it blocks nothing, and its
///   `renamed_branches` help match layers.
/// - A paused `git rebase` or `git am` blocks only when it touches a stack branch: the branch in
///   its `head-name` file, or the branch its worktree has checked out.
/// - Worktrees that `git worktree list` marks prunable are skipped.
/// - A `gh-stack-rebase-state` file with no such rebase only adds a warning.
struct OperationCheck {
    let repository: GitRepository

    /// Throws `StackError.midOperation` when `refuse` is true and an operation blocks. With
    /// `refuse` false, it reports the operation as a warning instead.
    func run(stackBranches: Set<String>, refuse: Bool) async throws -> OperationReport {
        var report = OperationReport()
        let adminFolders = gitStateFolders()

        for folder in adminFolders {
            guard let state = readModifyState(in: folder) else { continue }
            if let phase = state.blockingPhase {
                try report.add(.modify(phase), refuse: refuse)
            } else {
                report.renamedBranches.merge(state.renamedBranches ?? [:]) { $1 }
            }
        }

        var foundRebase = false
        for worktree in try await liveWorktrees() {
            guard let rebase = Self.pausedRebase(in: worktree.gitDirectory) else { continue }
            let touched = Set([rebase.headBranch, worktree.branch].compactMap { $0 })
            if let branch = touched.intersection(stackBranches).sorted().first {
                foundRebase = true
                try report.add(.rebase(branch: branch, worktree: worktree.path), refuse: refuse)
            }
        }

        let fileManager = FileManager.default
        let rebaseStateLeft = adminFolders.contains { fileManager.fileExists(atPath: $0.appendingPathComponent("gh-stack-rebase-state").path) }
        if rebaseStateLeft && !foundRebase {
            report.warnings.append(.staleRebaseState)
        }
        return report
    }

    /// The common folder, where gh-stack keeps its state, plus each linked worktree's admin
    /// folder, where older gh-stack versions kept it.
    private func gitStateFolders() -> [URL] {
        let worktrees = repository.commonDirectory.appendingPathComponent("worktrees", isDirectory: true)
        let linked = (try? FileManager.default.contentsOfDirectory(at: worktrees, includingPropertiesForKeys: nil)) ?? []
        return [repository.commonDirectory] + linked.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Nil when there is no file. A file that cannot be read comes back in an unrecognised phase.
    private func readModifyState(in folder: URL) -> ModifyState? {
        let url = folder.appendingPathComponent("gh-stack-modify-state")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(ModifyState.self, from: data) else {
            return ModifyState(schemaVersion: nil, phase: nil, renamedBranches: nil)
        }
        return state
    }

    /// Every worktree `git worktree list` reports that is not bare or prunable, with its git folder.
    private func liveWorktrees() async throws -> [LiveWorktree] {
        let listing = try await repository.git.run(["worktree", "list", "--porcelain", "-z"])
        return Self.worktreeRecords(in: listing.output).compactMap { record in
            guard !record.isBare, !record.isPrunable, let gitDirectory = Self.gitDirectory(ofWorktreeAt: record.path) else { return nil }
            return LiveWorktree(path: record.path, gitDirectory: gitDirectory, branch: record.branch)
        }
    }

    /// Reads `git worktree list --porcelain -z`: fields end in NUL, and an empty field ends a worktree.
    static func worktreeRecords(in output: Data) -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var current: WorktreeRecord?
        for field in output.split(separator: 0, omittingEmptySubsequences: false) {
            let text = String(decoding: field, as: UTF8.self)
            if text.isEmpty {
                if let finished = current { records.append(finished) }
                current = nil
            } else if text.hasPrefix("worktree ") {
                current = WorktreeRecord(path: URL(fileURLWithPath: String(text.dropFirst("worktree ".count)), isDirectory: true))
            } else if text.hasPrefix("branch refs/heads/") {
                current?.branch = String(text.dropFirst("branch refs/heads/".count))
            } else if text == "bare" {
                current?.isBare = true
            } else if text == "prunable" || text.hasPrefix("prunable ") {
                current?.isPrunable = true
            }
        }
        if let finished = current { records.append(finished) }
        return records
    }

    /// The git folder a worktree's `.git` names: the folder itself, or the `gitdir:` a `.git` file points at.
    static func gitDirectory(ofWorktreeAt worktree: URL) -> URL? {
        let dotGit = worktree.appendingPathComponent(".git")
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue { return dotGit }
        guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8), pointer.hasPrefix("gitdir: ") else { return nil }
        let path = pointer.dropFirst("gitdir: ".count).trimmingCharacters(in: .newlines)
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : URL(fileURLWithPath: path, isDirectory: true, relativeTo: worktree).absoluteURL.standardized
    }

    /// A paused rebase or `git am` in a git folder, with the branch it is rebasing when it names one.
    static func pausedRebase(in gitDirectory: URL) -> PausedRebase? {
        for name in ["rebase-merge", "rebase-apply"] {
            let folder = gitDirectory.appendingPathComponent(name, isDirectory: true)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            let headName = (try? String(contentsOf: folder.appendingPathComponent("head-name"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = headName.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
            return PausedRebase(headBranch: branch)
        }
        return nil
    }
}

struct PausedRebase {
    /// The branch from `head-name`. Nil for `git am`, or a rebase of a detached HEAD.
    var headBranch: String?
}

struct OperationReport {
    var renamedBranches: [String: String] = [:]
    var warnings: [StackWarning] = []

    mutating func add(_ operation: MidOperation, refuse: Bool) throws {
        if refuse { throw StackError.midOperation(operation) }
        warnings.append(.operationInProgress(operation))
    }
}

struct WorktreeRecord {
    var path: URL
    var branch: String?
    var isBare = false
    var isPrunable = false
}

struct LiveWorktree {
    var path: URL
    var gitDirectory: URL
    var branch: String?
}

/// The parts of gh-stack's `gh-stack-modify-state` that decide whether it blocks.
struct ModifyState: Decodable {
    var schemaVersion: Int?
    var phase: String?
    var renamedBranches: [String: String]?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case phase
        case renamedBranches = "renamed_branches"
    }

    /// Nil when the modify is only waiting for `gh stack submit`.
    var blockingPhase: ModifyPhase? {
        if let schemaVersion, schemaVersion > 1 { return .unrecognised }
        switch phase {
        case "pending_submit": return nil
        case "applying": return .applying
        case "conflict": return .conflict
        default: return .unrecognised
        }
    }
}
