import EyeballsCore
import EyeballsKit
import EyeballsStore
import Foundation
import Testing

/// wait, inbox, reply, the driver rule, Send now and the hooks, against a real repo and store.
@Suite struct AgentLoopTests {
    @Test func submitWakesEveryConnectionOfTheDriversClaudeProcess() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        try await fixture.submitComment("Why?", lines: 21...22, summary: "Close.")
        let submitted = fixture.sink.events.filter { $0.event.result["event"] == .string("review.submitted") }
        #expect(submitted.count == 1)
        #expect(submitted.first?.listener == .claudeProcess(BackendFixture.agentProcess))
        let line = try #require(submitted.first?.event.text)
        #expect(line == "eyeballs: Alex submitted review 1 on b (s1, r1): 1 thread, changes requested. Run: eyeballs inbox")
        #expect(line.count <= TextBudget.eventLine)
    }

    @Test func waitAnswersAtOnceWhenAReviewIsWaiting() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        guard case .stream(let request) = try await fixture.service.wait(WaitArguments(timeoutSeconds: 60), client: fixture.agent) else {
            Issue.record("With nothing waiting, wait should stream")
            return
        }
        #expect(request.mode == .wait)
        #expect(request.listener == .claudeProcess(BackendFixture.agentProcess))
        #expect(request.stack == StackID(1))
        #expect(request.timeout?.after == .seconds(60))

        try await fixture.submitComment("Why?", lines: 21...22)
        guard case .respond(.success(let result, let text)) = try await fixture.service.wait(WaitArguments(), client: fixture.agent) else {
            Issue.record("With a review waiting, wait should answer at once")
            return
        }
        #expect(result["event"] == .string("review.submitted"))
        #expect(result["next"] == .string("run_inbox"))
        #expect(text.hasPrefix("eyeballs: Alex submitted review 1"))
    }

    @Test func inboxShowsEveryWaitingThreadAndLabelsTheOnesShownBefore() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Use a constant here.", lines: 21...22, summary: "Mostly naming.")

        let (first, text) = try await fixture.inbox()
        #expect(first.status == .threads)
        #expect(first.reviewer == "Alex")
        #expect(first.threads.map(\.id) == [submitted.thread])
        #expect(first.threads.first?.shownBefore == false)
        #expect(first.threads.first?.code == ["line 21", "line 22"])
        #expect(first.threads.first?.anchor == .current)
        #expect(text.hasPrefix("Eyeballs review 1 · b (s1) · r1 · changes requested\n1 thread for you."))
        #expect(text.contains("Alex: Mostly naming."))
        #expect(text.contains("## \(submitted.thread) · new · layer 1 a · a.txt:21-22\n   21 | line 21\n   22 | line 22\nAlex: Use a constant here."))

        // An interrupted inbox hides nothing: the next one shows the same thread, labelled.
        let (second, again) = try await fixture.inbox()
        #expect(second.threads.map(\.id) == [submitted.thread])
        #expect(second.threads.first?.shownBefore == true)
        #expect(again.contains("## \(submitted.thread) · new · shown before · layer 1 a"))
        #expect(again.contains("1 was shown before."))
    }

    @Test func peekMarksNothingDelivered() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        try await fixture.submitComment("Why?", lines: 21...21)
        _ = try await fixture.inbox(peek: true)
        let (inbox, _) = try await fixture.inbox()
        #expect(inbox.threads.first?.shownBefore == false)
    }

    @Test func aLiveDriverMeansInboxSaysNotDriverAndADeadOneHandsOver() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        try await fixture.submitComment("Why?", lines: 21...21)
        let other = BackendFixture.client(session: "session-2", process: BackendFixture.otherProcess, cwd: fixture.repo.path)
        let (refused, text) = try await fixture.inbox(as: other)
        #expect(refused.status == .notDriver)
        #expect(text == "Another session now drives b (s1). Stop, or run eyeballs attach.")

        // The driver's session ends, so the next session to ask takes the role.
        let driver = try #require(try fixture.store.session(agent: .claude, key: "session-1"))
        try fixture.store.endAgentSession(id: driver.id)
        let (taken, _) = try await fixture.inbox(as: other)
        #expect(taken.status == .threads)
        let stack = try #require(try fixture.store.stack(id: fixture.stackID()))
        #expect(stack.driverSession != driver.id)
    }

    @Test func replyIsAllOrNothing() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Why?", lines: 21...21)
        do {
            _ = try await fixture.reply("## \(submitted.thread) addressed\nDone.\n\n## t99 declined\nNo.\n")
            Issue.record("A batch with an unknown thread should fail")
        } catch let error as EyeballsError {
            #expect(error.code == .unknownThread)
            #expect(error.code.exitStatus == 65)
        }
        let facts = try #require(try fixture.store.facts(stackID: fixture.stackID()))
        #expect(facts.threads.allSatisfy { thread in !(facts.comments[thread.id] ?? []).contains { $0.author == .agent } })
    }

    @Test func replyFinishesTheReviewAndSaysWhatIsNext() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let first = try await fixture.submitComment("Why?", lines: 21...21)
        _ = try await fixture.inbox()
        let (result, text) = try await fixture.reply("## \(first.thread) question\nShould line 21 stay?\n")
        #expect(result.replied.map(\.status) == [.question])
        #expect(result.waitingOnYou.isEmpty)
        #expect(result.next == .runWaitInBackground)
        #expect(text == "Sent 1 reply on review 1: 1 question.\nNext: nothing changed in the code, so run `eyeballs wait` with run_in_background: true, then end your turn.")
        #expect(text.split(separator: "\n").count <= TextBudget.replyLines)
        let review = try #require(try fixture.store.facts(stackID: fixture.stackID())?.lastSubmittedReview)
        #expect(review.status == .replied)
    }

    @Test func aReplyFromAnotherSessionIsSavedWithAWarning() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Why?", lines: 21...21)
        let other = BackendFixture.client(session: "session-2", process: BackendFixture.otherProcess, cwd: fixture.repo.path)
        let (result, text) = try await fixture.reply("## \(submitted.thread) addressed\nDone.\n", as: other)
        #expect(result.replied.count == 1)
        #expect(result.warnings.map(\.code) == [.notDriver])
        #expect(text.contains("Warning: another session drives b (s1)"))
    }

    @Test func aReplyToAResolvedThreadIsSavedWithAWarning() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Why?", lines: 21...21)
        try await fixture.service.setResolved(true, threadID: submitted.thread.number)
        let (result, _) = try await fixture.reply("## \(submitted.thread) addressed\nDone anyway.\n")
        #expect(result.warnings.map(\.code) == [.threadResolved])
    }

    @Test func sendNowPortsToTheNewestRevisionFirst() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let stackID = try fixture.stackID()
        let r1 = try #require(try fixture.store.latestRevision(stackID: stackID))
        let layer = try #require(try fixture.store.activeLayers(stackID: stackID).first)
        // The agent's branch moves on while you look at r1: two lines go in at the top of layer a.
        try fixture.amendLayerA(["new 1", "new 2"] + (1...22).map { "line \($0)" })

        try await fixture.service.addComment(
            "Is this right?", at: .lines(LineRange(path: "a.txt", side: .head, start: 21, end: 22)), layerID: layer.id, viewing: r1.id, sendNow: true)

        let (inbox, _) = try await fixture.inbox()
        let thread = try #require(inbox.threads.first)
        #expect(inbox.revision == 2)
        #expect(thread.start == 23)
        #expect(thread.end == 24)
        #expect(thread.code == ["line 21", "line 22"])
        #expect(fixture.sink.events.contains { $0.event.result["event"] == .string("comment.sent") })
    }

    @Test func theStopHookBlocksOncePerReason() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let submitted = try await fixture.submitComment("Why?", lines: 21...21)
        let input = try JSONValue(parsing: #"{"session_id":"session-1","stop_hook_active":true}"#)
        let stop = HookArguments(event: .stop, input: input)

        let first = await fixture.service.hook(stop, client: fixture.agent)
        #expect(first.output?["decision"] == .string("block"))
        #expect(first.output?["reason"] == .string("Eyeballs: Alex submitted review 1 (1 thread). Run eyeballs inbox."))
        // stop_hook_active stays true, and the same reason never blocks twice.
        let second = await fixture.service.hook(stop, client: fixture.agent)
        #expect(second.output == nil)

        _ = try await fixture.inbox()
        let unreplied = await fixture.service.hook(stop, client: fixture.agent)
        #expect(unreplied.output?["reason"]?.stringValue?.contains("\(submitted.thread) from review 1 has no reply") == true)
        let quiet = await fixture.service.hook(stop, client: fixture.agent)
        #expect(quiet.output == nil)
    }

    @Test func sessionStartAfterClearMovesTheDriverToTheNewSession() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        // After /clear, the hook arrives with a new session ID and the same CLAUDE_PID.
        let cleared = BackendFixture.client(session: nil, process: BackendFixture.agentProcess, cwd: fixture.repo.path)
        let input = try JSONValue(parsing: #"{"session_id":"session-after-clear","source":"clear"}"#)
        let result = await fixture.service.hook(HookArguments(event: .sessionStart, input: input), client: cleared)

        #expect(try fixture.driverKey() == "session-after-clear")
        let context = try #require(result.output?["hookSpecificOutput"]?["additionalContext"]?.stringValue)
        #expect(context.hasPrefix("Eyeballs: you drive b (s1) at r1."))
        #expect(context.count <= TextBudget.sessionStartContext)
    }

    @Test func sessionStartFromAResumeDoesNotTakeTheRole() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let resumed = BackendFixture.client(session: nil, process: BackendFixture.agentProcess, cwd: fixture.repo.path)
        let input = try JSONValue(parsing: #"{"session_id":"another-conversation","source":"resume"}"#)
        _ = await fixture.service.hook(HookArguments(event: .sessionStart, input: input), client: resumed)
        #expect(try fixture.driverKey() == "session-1")
    }

    @Test func approvalReachesTheAgentAsApproved() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        try await fixture.service.submitReview(stackID: try fixture.stackID(), verdict: .approved, summary: "")
        let (inbox, text) = try await fixture.inbox()
        #expect(inbox.status == .approved)
        #expect(text == "Alex approved b r1. No changes needed. Tell Alex. Push or merge only if Alex asks you in the terminal.")
        guard case .stream = try await fixture.service.wait(WaitArguments(), client: fixture.agent) else {
            Issue.record("An approval inbox has shown should not wake wait again")
            return
        }
    }

    @Test func watchWithoutClaudePIDFindsItsProcessAmongItsAncestors() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let monitor = BackendFixture.client(session: nil, process: nil, cwd: fixture.repo.path, ancestors: [900, BackendFixture.agentProcess.pid, 1])
        guard case .stream(let request) = try await fixture.service.watch(client: monitor) else {
            Issue.record("watch should stream")
            return
        }
        #expect(request.mode == .watch)
        #expect(request.listener == .claudeProcess(BackendFixture.agentProcess))
    }

    @Test func statusSaysWhatTheSessionDrives() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        try await fixture.submitComment("Why?", lines: 21...21)
        let (_, waiting) = await fixture.service.status(StatusArguments(brief: true), client: fixture.agent)
        #expect(waiting == "Eyeballs: you drive b (s1) at r1. Review 1 is waiting: run eyeballs inbox. Listening: nothing.")
        _ = try await fixture.inbox()
        let (_, shown) = await fixture.service.status(StatusArguments(brief: true), client: fixture.agent)
        #expect(shown == "Eyeballs: you drive b (s1) at r1. Review 1: 1 thread still needs your reply (t1). Listening: nothing.")
    }
}
