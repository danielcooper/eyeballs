@testable import EyeballsStore
import EyeballsKit
import Foundation

/// Runs `body` with a freshly opened store and a stack of two layers at r1.
func withStore<T>(clock: TestClock = TestClock(), _ body: (Store, StackFixture) throws -> T) throws -> T {
    try withTemporaryHome { home in
        let store = try Store.open(home: home, appVersion: "0.1.0-test", clock: clock.function)
        defer { try? store.close() }
        return try body(store, try StackFixture(store: store))
    }
}

/// A repo with a two-layer stack, `models` under `api-client`, and its first revision.
struct StackFixture {
    let repo: RepoRecord
    let stack: StackRecord
    let layers: [LayerRecord]
    let snapshots: [SnapshotRecord]
    let revision: RevisionRecord

    init(store: Store) throws {
        repo = try store.upsertRepo(commonDir: "/tmp/shop/.git", rootCommits: "root1", remoteKey: "github.com/alex/shop")
        stack = try store.findOrCreateStack(repoID: repo.id, StackDescription(
            name: "api-client", source: .ghStack, trunkBranch: "main", branches: ["models", "api-client"])).stack
        layers = try store.syncLayers(stackID: stack.id, [
            LayerDescription(branch: "models", prNumber: 811),
            LayerDescription(branch: "api-client", prNumber: 812),
        ])
        snapshots = try [
            store.insertSnapshot(Self.snapshot(layer: layers[0], base: "trunk1", head: "models1")),
            store.insertSnapshot(Self.snapshot(layer: layers[1], base: "models1", head: "api1")),
        ]
        revision = try store.createRevision(stackID: stack.id, trigger: .agentSubmit, layers: Self.revisionLayers(layers, snapshots)).revision
    }

    static func snapshot(layer: LayerRecord, base: String, head: String) -> SnapshotDescription {
        SnapshotDescription(
            layerID: layer.id, baseSHA: base, headSHA: head, baseTree: "tree-\(base)", headTree: "tree-\(head)",
            baseRule: .parentTip, parentRef: "refs/heads/parent",
            files: [.init(path: "Sources/\(layer.branch).swift", change: .modified, baseBlob: "b-\(base)", headBlob: "b-\(head)",
                          additions: 3, deletions: 1)])
    }

    static func revisionLayers(_ layers: [LayerRecord], _ snapshots: [SnapshotRecord]) -> [RevisionLayerDescription] {
        zip(layers, snapshots).map { RevisionLayerDescription(layerID: $0.id, position: $0.position, snapshotID: $1.id) }
    }

    /// An anchor on lines 12 to 14 of the layer's file, at r1.
    func anchor(layer index: Int = 0, lines: ClosedRange<Int>? = 12...14) -> NewAnchor {
        NewAnchor(revisionID: revision.id, snapshotID: snapshots[index].id, layerID: layers[index].id,
                  path: "Sources/\(layers[index].branch).swift", blob: snapshots[index].headSHA, lines: lines,
                  inDiff: true, coveredText: "struct Order {\n  var total: Double\n}", engineVersion: 1)
    }

    /// Opens a line thread with your first comment.
    @discardableResult
    func openThread(_ store: Store, layer index: Int = 0, body: String = "Use Decimal for money.",
                    delivery: CommentDelivery = .sendNow) throws -> (thread: ThreadRecord, comment: CommentRecord) {
        let created = try store.createThread(subject: .line, side: .head, origin: anchor(layer: index), body: body, delivery: delivery)
        return (created.thread, created.comment)
    }
}
