import EyeballsCore
import Foundation

/// A repository holding a three-layer stack, `models` on `main`, `api` on `models` and `web` on
/// `api`, with a gh-stack catalog shaped like one gh-stack v0.2.1 writes.
struct StackFixture {
    let git: GitFixture
    let root: ObjectID
    /// The tips each branch had when the stack was built, which the catalog records as bases.
    let tips: [String: ObjectID]

    static let branches = ["models", "api", "web"]

    init() throws {
        git = try GitFixture()
        try git.write("README.md", "shop\n")
        root = try git.commit("root")
        var tips = ["main": root]
        var parent = "main"
        for branch in Self.branches {
            try git.git(["checkout", "-q", "-b", branch, parent])
            try git.write("\(branch).txt", "\(branch) line 1\n\(branch) line 2\n")
            tips[branch] = try git.commit("Add \(branch)")
            parent = branch
        }
        try git.git(["checkout", "-q", "main"])
        self.tips = tips
    }

    func tip(_ branch: String) -> ObjectID { tips[branch]! }

    /// Writes `.git/gh-stack` with every layer's recorded base set to its parent's tip at build time.
    /// `merged` marks layers whose PR merged; `recordBases: false` leaves bases out.
    func writeCatalog(schemaVersion: Int = 1, merged: Set<String> = [], recordBases: Bool = true, staleHeads: Bool = true) throws {
        var parent = "main"
        var branches: [[String: Any]] = []
        for (index, branch) in Self.branches.enumerated() {
            var pullRequest: [String: Any] = [
                "number": 811 + index,
                "id": "PR_kwDO\(index)",
                "url": "https://github.com/owner/shop/pull/\(811 + index)",
            ]
            if merged.contains(branch) { pullRequest["merged"] = true }
            var entry: [String: Any] = [
                "branch": branch,
                "head": staleHeads ? String(repeating: "e", count: 40) : tip(branch).hex,
                "pullRequest": pullRequest,
            ]
            if recordBases { entry["base"] = tip(parent).hex }
            branches.append(entry)
            parent = branch
        }
        let catalog: [String: Any] = [
            "schemaVersion": schemaVersion,
            "repository": "owner/shop",
            "stacks": [[
                "id": "S_kwDO42",
                "number": 11280,
                "trunk": ["branch": "main", "head": root.hex],
                "branches": branches,
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: git.repo.appendingPathComponent(".git/gh-stack"))
    }

    func writeGitFile(_ path: String, _ text: String) throws {
        let url = git.repo.appendingPathComponent(".git").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func reader() async throws -> StackReader {
        StackReader(repository: try await git.repository())
    }
}
