import Foundation
import GRDB

/// What git and gh-stack say about a stack, for `findOrCreateStack`.
public struct StackDescription: Hashable, Sendable {
    /// The top branch, used as the name of a new stack.
    public var name: String
    public var source: StackSource
    public var trunkBranch: String
    /// Every branch in the stack, bottom first.
    public var branches: [String]
    public var ghStackID: String?
    public var ghStackNumber: Int?

    public init(name: String, source: StackSource, trunkBranch: String, branches: [String], ghStackID: String? = nil, ghStackNumber: Int? = nil) {
        self.name = name
        self.source = source
        self.trunkBranch = trunkBranch
        self.branches = branches
        self.ghStackID = ghStackID
        self.ghStackNumber = ghStackNumber
    }
}

/// One branch of the stack as git sees it now, for `syncLayers`.
public struct LayerDescription: Hashable, Sendable {
    public var branch: String
    public var prNumber: Int?
    public var prURL: String?
    /// The branch's old name, from `renamed_branches` in a `pending_submit` modify file.
    public var previousBranch: String?

    public init(branch: String, prNumber: Int? = nil, prURL: String? = nil, previousBranch: String? = nil) {
        self.branch = branch
        self.prNumber = prNumber
        self.prURL = prURL
        self.previousBranch = previousBranch
    }
}

extension Store {
    /// Finds the active stack this description belongs to, or creates it.
    ///
    /// A stack matches when it shares any active branch, then by gh-stack's `id`, then by its
    /// number. A matched stack takes the description's trunk and gh-stack IDs, which change after
    /// `gh stack modify` and a submit. Its name stays, because you can rename it.
    public func findOrCreateStack(repoID: Int, _ description: StackDescription) throws -> (stack: StackRecord, created: Bool) {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            if let match = try matchingStack(db, repoID: repoID, description) {
                let stack = try update(StackRecord.self, db, id: match.id,
                                       set: "trunk_branch = ?, gh_stack_id = COALESCE(?, gh_stack_id), gh_stack_number = COALESCE(?, gh_stack_number)",
                                       arguments: [description.trunkBranch, description.ghStackID, description.ghStackNumber])
                return (stack, false)
            }
            let stack = try insert(StackRecord.self, db, sql: """
                INSERT INTO stack (repo_id, name, source, trunk_branch, gh_stack_id, gh_stack_number, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [repoID, description.name, description.source, description.trunkBranch,
                                 description.ghStackID, description.ghStackNumber, now])
            return (stack, true)
        }
    }

    /// Makes the stack's active layers match `layers`, given bottom first.
    ///
    /// Each branch matches an active layer with the same branch, then one named `previousBranch`,
    /// then one with the same PR number, so a layer keeps its ID through a rename or a reorder.
    /// Unmatched branches become new layers. Left-over layers end as `merged` when their branch
    /// is in `mergedBranches`, and as `dropped` otherwise.
    /// - Returns: the active layers, bottom first.
    @discardableResult
    public func syncLayers(stackID: Int, _ layers: [LayerDescription], mergedBranches: Set<String> = []) throws -> [LayerRecord] {
        let now = clock().databaseMilliseconds
        return try pool.write { db in
            var unmatched = try activeLayers(db, stackID: stackID)
            var matches: [(LayerDescription, LayerRecord?)] = []
            for layer in layers {
                let index = unmatched.firstIndex { $0.branch == layer.branch }
                    ?? layer.previousBranch.flatMap { previous in unmatched.firstIndex { $0.branch == previous } }
                    ?? layer.prNumber.flatMap { number in unmatched.firstIndex { $0.prNumber == number } }
                matches.append((layer, index.map { unmatched.remove(at: $0) }))
            }

            // End left-over layers first, so a renamed layer can take a branch name they free.
            for leftover in unmatched {
                let state: LayerState = mergedBranches.contains(leftover.branch) ? .merged : .dropped
                try db.execute(sql: "UPDATE layer SET state = ?, ended_at = ? WHERE id = ?", arguments: [state, now, leftover.id])
            }

            var result: [LayerRecord] = []
            for (offset, (layer, match)) in matches.enumerated() {
                let position = offset + 1
                let record = if let match {
                    try update(LayerRecord.self, db, id: match.id, set: "branch = ?, position = ?, pr_number = COALESCE(?, pr_number), pr_url = COALESCE(?, pr_url)",
                               arguments: [layer.branch, position, layer.prNumber, layer.prURL])
                } else {
                    try insert(LayerRecord.self, db, sql: """
                        INSERT INTO layer (stack_id, branch, position, pr_number, pr_url, created_at) VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [stackID, layer.branch, position, layer.prNumber, layer.prURL, now])
                }
                try db.execute(sql: "INSERT INTO layer_name (layer_id, branch, first_seen) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                               arguments: [record.id, record.branch, now])
                result.append(record)
            }
            return result
        }
    }

    /// Makes `sessionID` the agent session that gets the stack's wake-ups.
    public func setDriver(stackID: Int, sessionID: Int) throws {
        try pool.write { db in
            _ = try update(StackRecord.self, db, id: stackID, set: "driver_session = ?", arguments: [sessionID])
        }
    }

    private func matchingStack(_ db: Database, repoID: Int, _ description: StackDescription) throws -> StackRecord? {
        let active = "repo_id = ? AND state = 'active'"
        if !description.branches.isEmpty,
           let stack = try StackRecord.fetchOne(db, sql: """
               SELECT * FROM stack WHERE \(active) AND id IN (
                 SELECT stack_id FROM layer WHERE state = 'active' AND branch IN (\(databaseQuestionMarks(count: description.branches.count))))
               ORDER BY id LIMIT 1
               """, arguments: StatementArguments([repoID]) + StatementArguments(description.branches)) {
            return stack
        }
        if let ghStackID = description.ghStackID,
           let stack = try StackRecord.filter(sql: "\(active) AND gh_stack_id = ?", arguments: [repoID, ghStackID]).order(sql: "id").fetchOne(db) {
            return stack
        }
        if let number = description.ghStackNumber {
            return try StackRecord.filter(sql: "\(active) AND gh_stack_number = ?", arguments: [repoID, number]).order(sql: "id").fetchOne(db)
        }
        return nil
    }
}

func activeLayers(_ db: Database, stackID: Int) throws -> [LayerRecord] {
    try LayerRecord.filter(sql: "stack_id = ? AND state = 'active'", arguments: [stackID]).order(sql: "position").fetchAll(db)
}
