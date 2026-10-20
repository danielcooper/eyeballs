import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation
import Testing

/// `eyeballs review` against a real repo and a temporary store.
@Suite struct ReviewFlowTests {
    @Test func theFirstReviewRecordsRevision1WithEveryLayer() async throws {
        let fixture = try BackendFixture()
        let (result, text) = try await fixture.review()

        #expect(result.created)
        #expect(result.revision == 1)
        #expect(result.layers.map(\.branch) == ["a", "b"])
        #expect(result.layers.map(\.files) == [1, 1])
        #expect(result.layers.map(\.additions) == [2, 1])
        #expect(result.layers.allSatisfy { $0.baseRule == "parent_tip" })
        #expect(result.next == .runWaitInBackground)
        #expect(text.split(separator: "\n").count <= TextBudget.reviewLines)
        #expect(text.hasPrefix("Opened b (s1) r1 in Eyeballs: 2 layers, 2 files, +3 -0."))
        #expect(text.contains("Waiting on Alex: 0 threads. Waiting on you: 0."))
        #expect(text.hasSuffix("Next: run `eyeballs wait` with run_in_background: true, then end your turn."))
    }

    @Test func pinsAreWrittenForEveryHead() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let pins = try BackendFixture.git(fixture.repo, "for-each-ref", "--format=%(objectname)", "refs/eyeballs/")
        let heads = try ["a", "b"].map { try BackendFixture.git(fixture.repo, "rev-parse", $0).trimmingCharacters(in: .newlines) }
        #expect(Set(pins.split(separator: "\n").map(String.init)) == Set(heads))
        let recorded = try fixture.store.livePins(repoID: try #require(fixture.store.repos().first?.id)).map(\.sha)
        #expect(Set(recorded) == Set(heads))
    }

    @Test func anUnchangedStackMakesNoNewRevision() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let (again, text) = try await fixture.review()
        #expect(!again.created)
        #expect(again.revision == 1)
        #expect(text.hasPrefix("Nothing changed since r1 of b (s1)"))
    }

    @Test func linesInsertedAboveACommentMoveItsThread() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Why add these?", lines: 21...22)
        _ = try await fixture.inbox()
        _ = try await fixture.reply("## \(submitted.thread) addressed\nKept them, with a note.\n")

        try fixture.amendLayerA(["header"] + (1...22).map { "line \($0)" })
        let (result, text) = try await fixture.review()
        #expect(result.created)
        #expect(result.revision == 2)
        #expect(result.ported == PortCounts(moved: 1))
        #expect(text.contains("Threads carried over: 1 moved."))

        let (shown, _) = try await fixture.service.show(ShowArguments(thread: submitted.thread), client: fixture.agent)
        #expect(shown.thread.start == 22)
        #expect(shown.thread.end == 23)
        #expect(shown.thread.anchors.map(\.state) == [.original, .moved])
        #expect(shown.thread.code.filter(\.covered).map(\.text) == ["line 21", "line 22"])
    }

    @Test func editingTheCommentedLinesMakesTheThreadOutdated() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Rename these.", lines: 21...22)
        try fixture.amendLayerA((1...20).map { "line \($0)" } + ["renamed 21", "renamed 22"])
        let (result, _) = try await fixture.review(force: true)
        #expect(result.ported == PortCounts(outdated: 1))

        let (inbox, text) = try await fixture.inbox()
        let thread = try #require(inbox.threads.first)
        #expect(thread.id == submitted.thread)
        #expect(thread.anchor == .outdated)
        #expect(thread.start == nil)
        #expect(thread.original == ["line 21", "line 22"])
        #expect(text.contains("Originally:\n   21 | line 21\n   22 | line 22"))
    }

    @Test func reviewRefusesWhileAShownThreadHasNoReply() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Check this.", lines: 21...21)
        _ = try await fixture.inbox()

        await #expect(throws: EyeballsError.self) { try await fixture.review() }
        do {
            try await fixture.review()
        } catch let error as EyeballsError {
            #expect(error.code == .unreplied)
            #expect(error.code.exitStatus == 77)
            #expect(error.message.contains("\(submitted.thread)"))
        }
        let (forced, _) = try await fixture.review(force: true)
        #expect(!forced.created)
    }

    @Test func theUnrepliedCheckCoversThreadsAnotherSessionRead() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        try await fixture.submitComment("Check this.", lines: 21...21)
        // The driver read the inbox. A second session that later runs review is still refused.
        _ = try await fixture.inbox()
        let other = BackendFixture.client(session: "session-2", process: BackendFixture.otherProcess, cwd: fixture.repo.path)
        await #expect(throws: EyeballsError.self) { try await fixture.review(as: other) }
    }

    @Test func aPausedRebaseOfAStackBranchRefusesWithMidOperation() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        // An "edit" step pauses the rebase of b after its first commit.
        try BackendFixture.git(fixture.repo, environment: ["GIT_SEQUENCE_EDITOR": "sed -i '' -e 's/^pick/edit/'"], "rebase", "-q", "-i", "main")
        do {
            try await fixture.review()
            Issue.record("review should refuse during a paused rebase")
        } catch {
            let failure = AgentRequestHandler.agentError(error)
            #expect(failure.code == .midOperation)
            #expect(failure.code.exitStatus == 75)
        }
    }

    @Test func outsideARepositoryReviewSaysNotARepo() async throws {
        let fixture = try BackendFixture()
        let outside = BackendFixture.client(session: "session-1", process: BackendFixture.agentProcess, cwd: fixture.home.root.path)
        do {
            try await fixture.review(as: outside)
            Issue.record("review should refuse outside a repository")
        } catch {
            #expect(AgentRequestHandler.agentError(error).code == .notARepo)
        }
    }

    @Test func reviewMakesTheCallerTheDriverAndReboundsTheOldOne() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let other = BackendFixture.client(session: "session-2", process: BackendFixture.otherProcess, cwd: fixture.repo.path)
        try await fixture.review(as: other)

        #expect(try fixture.driverKey() == "session-2")
        let rebound = fixture.sink.events.filter { $0.event.result["event"] == .string("rebound") }
        #expect(rebound.count == 1)
        #expect(rebound.first?.listener == .claudeProcess(BackendFixture.agentProcess))
    }
}
