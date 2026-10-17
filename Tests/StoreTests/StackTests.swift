@testable import EyeballsStore
import Foundation
import GRDB
import Testing

struct StackTests {
    @Test func aRepoIsFoundByItsCommonDirectoryOrByItsRootsWhenItMoved() throws {
        try withStore { store, fixture in
            let same = try store.upsertRepo(commonDir: "/tmp/shop/.git", rootCommits: "root1", remoteKey: "github.com/alex/shop")
            #expect(same.id == fixture.repo.id)

            let moved = try store.upsertRepo(commonDir: "/tmp/shop-moved/.git", rootCommits: "root1", remoteKey: "github.com/alex/shop")
            #expect(moved.id == fixture.repo.id)
            #expect(moved.commonDir == "/tmp/shop-moved/.git")

            let other = try store.upsertRepo(commonDir: "/tmp/other/.git", rootCommits: "root1", remoteKey: nil)
            #expect(other.id != fixture.repo.id)
        }
    }

    @Test func aSessionIsRefreshedAndRevivedOnEachCall() throws {
        let clock = TestClock()
        try withStore(clock: clock) { store, _ in
            let first = try store.upsertAgentSession(agent: .claude, sessionKey: "abc", pid: 100, pidStart: 1, cwd: "/tmp/shop")
            try store.endAgentSession(id: first.id)
            clock.advance(seconds: 60)
            let again = try store.upsertAgentSession(agent: .claude, sessionKey: "abc", pid: 200, pidStart: 2, cwd: "/tmp/elsewhere")
            #expect(again.id == first.id)
            #expect(again.pid == 200)
            #expect(again.pidStart == 2)
            #expect(again.endedAt == nil)
            #expect(again.firstSeen == first.firstSeen)
            #expect(again.lastSeen == clock.now)
            #expect(again.cwd == "/tmp/shop")
        }
    }

    @Test func aStackIsFoundByAnySharedBranchThenByItsGhStackID() throws {
        try withStore { store, fixture in
            let byBranch = try store.findOrCreateStack(repoID: fixture.repo.id, StackDescription(
                name: "renamed-top", source: .ghStack, trunkBranch: "main", branches: ["models", "new-top"], ghStackID: "gh-9"))
            #expect(byBranch.created == false)
            #expect(byBranch.stack.id == fixture.stack.id)
            #expect(byBranch.stack.name == "api-client")
            #expect(byBranch.stack.ghStackID == "gh-9")

            let byID = try store.findOrCreateStack(repoID: fixture.repo.id, StackDescription(
                name: "x", source: .ghStack, trunkBranch: "main", branches: ["unrelated"], ghStackID: "gh-9"))
            #expect(byID.stack.id == fixture.stack.id)
        }
    }

    @Test func layersKeepTheirIDsThroughARenameAndAReorder() throws {
        try withStore { store, fixture in
            let models = fixture.layers[0], api = fixture.layers[1]
            let synced = try store.syncLayers(stackID: fixture.stack.id, [
                LayerDescription(branch: "api-client-v2", prNumber: 812, previousBranch: "api-client"),
                LayerDescription(branch: "models", prNumber: 811),
                LayerDescription(branch: "web-ui"),
            ])
            #expect(synced.map(\.id).prefix(2) == [api.id, models.id])
            #expect(synced.map(\.position) == [1, 2, 3])
            #expect(synced[0].branch == "api-client-v2")

            let names = try store.reader.read {
                try String.fetchAll($0, sql: "SELECT branch FROM layer_name WHERE layer_id = ? ORDER BY branch", arguments: [api.id])
            }
            #expect(names == ["api-client", "api-client-v2"])
        }
    }

    @Test func leftOverLayersEndAsMergedOrDropped() throws {
        try withStore { store, fixture in
            let synced = try store.syncLayers(stackID: fixture.stack.id, [LayerDescription(branch: "web-ui")], mergedBranches: ["models"])
            #expect(synced.map(\.branch) == ["web-ui"])
            let states = try store.fetchAll(LayerRecord.self).reduce(into: [String: LayerState]()) { $0[$1.branch] = $1.state }
            #expect(states == ["models": .merged, "api-client": .dropped, "web-ui": .active])
        }
    }

    @Test func aSnapshotIsSavedOncePerLayerBaseAndHead() throws {
        try withStore { store, fixture in
            let again = try store.insertSnapshot(StackFixture.snapshot(layer: fixture.layers[0], base: "trunk1", head: "models1"))
            #expect(again.id == fixture.snapshots[0].id)
            #expect(try store.fetchAll(SnapshotFileRecord.self).count == 2)
            #expect(try store.fetchAll(SnapshotFileRecord.self).first?.change == .modified)
        }
    }

    @Test func theSameContentGivesNoNewRevision() throws {
        try withStore { store, fixture in
            let layers = StackFixture.revisionLayers(fixture.layers, fixture.snapshots)
            let same = try store.createRevision(stackID: fixture.stack.id, trigger: .agentSubmit, layers: layers)
            #expect(same.created == false)
            #expect(same.revision.id == fixture.revision.id)
            #expect(fixture.revision.number == 1)

            let amended = try store.insertSnapshot(StackFixture.snapshot(layer: fixture.layers[1], base: "models1", head: "api2"))
            let next = try store.createRevision(stackID: fixture.stack.id, trigger: .agentSubmit,
                                                layers: StackFixture.revisionLayers(fixture.layers, [fixture.snapshots[0], amended]),
                                                agentNote: "Retry only 5xx.")
            #expect(next.created)
            #expect(next.revision.number == 2)
            #expect(next.revision.contentHash != fixture.revision.contentHash)
            #expect(try store.latestRevision(stackID: fixture.stack.id)?.id == next.revision.id)
            let rows = try store.reader.read {
                try RevisionLayerRecord.filter(sql: "revision_id = ?", arguments: [next.revision.id]).order(sql: "position").fetchAll($0)
            }
            #expect(rows.map(\.snapshotID) == [fixture.snapshots[0].id, amended.id])
        }
    }

    @Test func aNewRevisionMarksAddressedRepliesFixedInIt() throws {
        try withStore { store, fixture in
            let (thread, _) = try fixture.openThread(store)
            let addressed = try store.addAgentReply(threadID: thread.id, status: .addressed, body: "Done.", sessionID: nil)
            let question = try store.addAgentReply(threadID: thread.id, status: .question, body: "Also tax?", sessionID: nil)
            let amended = try store.insertSnapshot(StackFixture.snapshot(layer: fixture.layers[0], base: "trunk1", head: "models2"))
            let r2 = try store.createRevision(stackID: fixture.stack.id, trigger: .agentSubmit,
                                              layers: StackFixture.revisionLayers(fixture.layers, [amended, fixture.snapshots[1]])).revision
            #expect(try store.comment(addressed.id).fixedIn == r2.id)
            #expect(try store.comment(question.id).fixedIn == nil)
        }
    }

    @Test func aRevisionRefusesASnapshotFromAnotherLayer() throws {
        try withStore { store, fixture in
            let crossed = [RevisionLayerDescription(layerID: fixture.layers[0].id, position: 1, snapshotID: fixture.snapshots[1].id)]
            #expect(throws: StoreError.snapshotLayerMismatch(snapshotID: fixture.snapshots[1].id, layerID: fixture.layers[0].id)) {
                _ = try store.createRevision(stackID: fixture.stack.id, trigger: .humanStart, layers: crossed)
            }
        }
    }

    @Test func pinsAreRecordedReleasedAndPinnedAgain() throws {
        try withStore { store, fixture in
            try store.recordPins(repoID: fixture.repo.id, shas: ["models1", "api1"])
            try store.recordPins(repoID: fixture.repo.id, shas: ["api1"])
            #expect(try store.livePins(repoID: fixture.repo.id).map(\.sha) == ["api1", "models1"])

            try store.releasePins(repoID: fixture.repo.id, shas: ["models1"])
            #expect(try store.livePins(repoID: fixture.repo.id).map(\.sha) == ["api1"])

            try store.recordPins(repoID: fixture.repo.id, shas: ["models1"])
            #expect(try store.livePins(repoID: fixture.repo.id).count == 2)
            #expect(store.pinRef(sha: "api1") == "refs/eyeballs/\(store.installID)/api1")
        }
    }

    @Test func theDriverIsTheSessionThatGetsWakeUps() throws {
        try withStore { store, fixture in
            let session = try store.upsertAgentSession(agent: .claude, sessionKey: "abc", pid: nil, pidStart: nil, cwd: "/tmp/shop")
            try store.setDriver(stackID: fixture.stack.id, sessionID: session.id)
            #expect(try store.reader.read { try StackRecord.fetchOne($0, id: fixture.stack.id)?.driverSession } == session.id)
        }
    }
}
