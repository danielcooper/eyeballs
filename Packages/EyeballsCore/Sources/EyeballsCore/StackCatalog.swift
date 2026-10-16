import Foundation

/// gh-stack's own catalog of stacks, read straight from `<git-common-dir>/gh-stack`.
///
/// Eyeballs never runs `gh stack view`, because that command calls GitHub and rewrites this file.
/// The shape follows gh-stack v0.2.1, schema version 1. A recorded `head` is never trusted:
/// branch tips come from the live refs.
public struct GhStackCatalog: Hashable, Sendable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    /// The GitHub repository, such as `owner/name`.
    public var repository: String?
    public var stacks: [GhStack]

    /// Reads `<commonDirectory>/gh-stack`. When it is missing, reads and joins the legacy
    /// `worktrees/<id>/gh-stack` files that older gh-stack versions wrote.
    ///
    /// Returns nil when there is no catalog at all. Throws `StackError.unsupportedCatalog` for a
    /// newer schema version, and `StackError.unreadableCatalog` for anything that is not a catalog.
    public static func load(commonDirectory: URL) throws -> GhStackCatalog? {
        let fileManager = FileManager.default
        let common = commonDirectory.appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: common.path) {
            return try decode(try readFile(common))
        }
        let worktrees = commonDirectory.appendingPathComponent("worktrees", isDirectory: true)
        let folders = (try? fileManager.contentsOfDirectory(at: worktrees, includingPropertiesForKeys: nil)) ?? []
        let legacy = try folders
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.appendingPathComponent(fileName) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map { try decode(try readFile($0)) }
        guard let first = legacy.first else { return nil }
        var joined = GhStackCatalog(schemaVersion: first.schemaVersion, repository: first.repository, stacks: [])
        for catalog in legacy {
            joined.repository = joined.repository ?? catalog.repository
            for stack in catalog.stacks where !joined.stacks.contains(stack) {
                joined.stacks.append(stack)
            }
        }
        return joined
    }

    /// Decodes a catalog, refusing a schema version newer than 1 before reading anything else.
    public static func decode(_ data: Data) throws -> GhStackCatalog {
        let decoder = JSONDecoder()
        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).schemaVersion ?? 0
        } catch {
            throw StackError.unreadableCatalog
        }
        guard version <= supportedSchemaVersion else { throw StackError.unsupportedCatalog(schemaVersion: version) }
        do {
            let file = try decoder.decode(CatalogFile.self, from: data)
            return GhStackCatalog(schemaVersion: version, repository: file.repository, stacks: file.stacks ?? [])
        } catch {
            throw StackError.unreadableCatalog
        }
    }

    public init(schemaVersion: Int, repository: String?, stacks: [GhStack]) {
        self.schemaVersion = schemaVersion
        self.repository = repository
        self.stacks = stacks
    }

    /// The first stack with `branch` as one of its layers. The trunk alone matches no stack,
    /// because many stacks share one trunk.
    public func stack(containing branch: String) -> GhStack? {
        stacks.first { $0.branches.contains { $0.branch == branch } }
    }

    static let fileName = "gh-stack"

    private static func readFile(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw StackError.unreadableCatalog
        }
    }

    private struct VersionProbe: Decodable {
        var schemaVersion: Int?
    }

    private struct CatalogFile: Decodable {
        var repository: String?
        var stacks: [GhStack]?
    }
}

/// One stack in the catalog. `branches` runs bottom first.
public struct GhStack: Hashable, Sendable, Decodable {
    public var id: String?
    public var number: Int?
    public var trunk: GhStackBranch
    public var branches: [GhStackBranch]

    public init(id: String? = nil, number: Int? = nil, trunk: GhStackBranch, branches: [GhStackBranch]) {
        self.id = id
        self.number = number
        self.trunk = trunk
        self.branches = branches
    }
}

public struct GhStackBranch: Hashable, Sendable, Decodable {
    public var branch: String
    /// The tip gh-stack last saw. Stale as soon as anyone commits; never used as a tip.
    public var head: String?
    /// The parent's tip when gh-stack last synced or rebased this branch.
    public var base: String?
    public var pullRequest: GhStackPullRequest?

    public init(branch: String, head: String? = nil, base: String? = nil, pullRequest: GhStackPullRequest? = nil) {
        self.branch = branch
        self.head = head
        self.base = base
        self.pullRequest = pullRequest
    }
}

public struct GhStackPullRequest: Hashable, Sendable, Decodable {
    public var number: Int
    public var id: String?
    public var url: String?
    public var merged: Bool?

    public init(number: Int, id: String? = nil, url: String? = nil, merged: Bool? = nil) {
        self.number = number
        self.id = id
        self.url = url
        self.merged = merged
    }
}
