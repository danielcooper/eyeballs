import EyeballsKit
import Foundation
import Testing

/// The packet text the agent reads, checked against fixed examples and the token budgets.
@Suite struct PacketTextTests {
    static let alex = ReviewerName(name: "Alex")

    static func thread(_ id: Int, kind: ThreadKind = .new, shownBefore: Bool = false, position: Int = 1, branch: String = "models",
                       pr: Int? = 811, subject: WireSubject = .line, path: String = "Sources/Models/Order.swift", start: Int? = 12,
                       code: [String] = ["struct Order: Codable {"],
                       anchor: WireAnchorState = .current, body: String = "Use Decimal for money, not Double.",
                       history: [HistoryComment] = [], checkout: String? = nil) -> PacketThread {
        let wire = InboxThread(
            id: ThreadID(id), kind: kind, review: 7, shownBefore: shownBefore,
            layer: ThreadLayer(position: position, branch: branch, pr: pr, checkout: checkout), subject: subject, side: .head,
            path: path, start: start, end: start.map { $0 + max(code.count, 1) - 1 }, commit: "9f2c1ab", anchor: anchor, commentedOn: 4,
            code: code, original: nil, history: history, comment: InboxComment(id: CommentID(200 + id), body: body))
        return PacketThread(wire: wire, movedFrom: nil, hiddenCodeLines: 0, originalStart: nil)
    }

    static func packet(_ threads: [PacketThread], body: String = "Close. Mostly naming, plus one real bug in the retry path.") -> InboxPacket {
        InboxPacket(reviewer: alex, stackLabel: "checkout-v2 (s3)", revision: 4,
                    reviews: [InboxReview(id: 7, verdict: .changesRequested, body: body, submittedAt: "2026-10-16T14:02:11Z")],
                    threads: threads)
    }

    @Test func thePacketReadsLikeTheDesignsExample() {
        let threads = [
            Self.thread(41, code: ["struct Order: Codable {", "  var id: String", "  var total: Double"]),
            Self.thread(42, shownBefore: true, position: 2, branch: "api-client", pr: 812, path: "Sources/API/Client.swift", start: 40,
                        code: ["  func get(_ path: String) async throws -> Data {"], body: "This retries on 4xx too. Only retry 5xx and timeouts.",
                        checkout: "/Users/alex/src/shop-wt/api-client"),
            Self.thread(43, kind: .followUp, position: 2, branch: "api-client", pr: 812, subject: .file, path: "Sources/API/Client.swift",
                        start: nil, code: [],
                        body: "Fine, but give Retry its own type so tests can drive it.",
                        history: [HistoryComment(id: CommentID(150), author: .agent, replyStatus: .declined, revision: 3,
                                                 body: "Keeping one file: Retry is 30 lines and only Client uses it.", truncated: false)]),
        ]
        let page = Self.packet(threads).page(1)
        let expected = """
            Eyeballs review 7 · checkout-v2 (s3) · r4 · changes requested
            3 threads for you, bottom layer first. 1 was shown before. Reply to all of them in one `eyeballs reply --file -`.

            Alex: Close. Mostly naming, plus one real bug in the retry path.

            ## t41 · new · layer 1 models (PR #811) · Sources/Models/Order.swift:12-14
               12 | struct Order: Codable {
               13 |   var id: String
               14 |   var total: Double
            Alex: Use Decimal for money, not Double.

            ## t42 · new · shown before · layer 2 api-client (PR #812) · Sources/API/Client.swift:40
            checkout: /Users/alex/src/shop-wt/api-client
               40 |   func get(_ path: String) async throws -> Data {
            Alex: This retries on 4xx too. Only retry 5xx and timeouts.

            ## t43 · follow-up · layer 2 api-client · Sources/API/Client.swift (file)
            You (r3, declined): Keeping one file: Retry is 30 lines and only Client uses it.
            Alex: Fine, but give Retry its own type so tests can drive it.

            Next: fix the code bottom layer first, reply with `eyeballs reply --file -`, then run `eyeballs review --note "…"`.
            """
        #expect(page.text == expected)
        #expect(!page.more)
    }

    @Test func longRangesStopAt12LinesAndPointAtShow() {
        var thread = Self.thread(45, code: (1...12).map { "line \($0)" })
        thread.hiddenCodeLines = 30
        let text = Self.packet([thread]).page(1).text
        #expect(text.contains("   23 | line 12\n(… 30 more lines; run eyeballs show t45)"))
    }

    @Test func aLongInboxSplitsIntoPagesUnderTheBudget() {
        let body = String(repeating: "This comment is long enough to fill the page quickly. ", count: 40)
        let threads = (1...40).map { Self.thread($0, body: body) }
        let packet = Self.packet(threads)
        let first = packet.page(1)
        #expect(first.more)
        #expect(first.nextPage == 2)
        #expect(first.text.count <= TextBudget.inboxPage)
        #expect(first.text.hasSuffix("more threads: run eyeballs inbox --page 2."))

        var seen = first.threads.count
        var number = 2
        while true {
            let page = packet.page(number)
            #expect(page.text.count <= TextBudget.inboxPage)
            #expect(page.text.hasPrefix("Eyeballs review 7 · checkout-v2 (s3) · r4 · changes requested · page \(number)"))
            seen += page.threads.count
            guard page.more else { break }
            number += 1
        }
        #expect(seen == 40)
    }

    @Test func reviewTextStaysWithinSixLines() {
        let result = ReviewResult(
            stack: StackSummary(id: StackID(3), name: "checkout-v2", source: .ghStack, trunk: "main", repo: "/Users/alex/src/shop"),
            revision: 4, created: true,
            layers: [ReviewLayer(position: 1, branch: "models", pr: 811, files: 14, additions: 412, deletions: 88, baseRule: "parent_tip", changedSinceLast: true)],
            ported: PortCounts(current: 3, moved: 1, outdated: 1),
            warnings: (1...4).map { Warning(code: .dirtyWorktree, message: "Warning number \($0).") },
            waitingOnYou: [], waitingOnReviewer: 5, listening: [], next: .runWaitInBackground)
        let text = ReviewText.render(result, reviewer: Self.alex)
        let lines = text.split(separator: "\n")
        #expect(lines.count == TextBudget.reviewLines)
        #expect(lines[0] == "Opened checkout-v2 (s3) r4 in Eyeballs: 1 layer, 14 files, +412 -88.")
        #expect(lines[1] == "Threads carried over: 3 current, 1 moved, 1 outdated.")
        #expect(lines[3] == "Warning: 3 more warnings. Run eyeballs review --json to see them.")
        #expect(lines[4] == "Waiting on Alex: 5 threads. Waiting on you: 0.")
        #expect(lines[5] == "Next: run `eyeballs wait` with run_in_background: true, then end your turn.")
    }

    @Test func eventLinesStayOnOneLineUnder200Characters() {
        let name = String(repeating: "very-long-branch-name-", count: 12)
        let event = AgentEvents.reviewSubmitted(review: 7, verdict: ReviewVerdictWords(wire: .changesRequested), stack: 3, name: name,
                                                revision: 4, reviewer: Self.alex, threads: 5)
        #expect(event.text.count <= TextBudget.eventLine)
        #expect(!event.text.contains("\n"))
        #expect(event.result["event"] == .string("review.submitted"))
    }

    @Test func anEscapeInCodeReachesTheTerminalEscaped() {
        let thread = Self.thread(41, code: ["let title = \"\u{1b}]0;pwned\u{07}\""])
        let text = Self.packet([thread]).page(1).text
        // The command escapes text as it prints it; the packet itself keeps the bytes as they are.
        #expect(text.contains("\u{1b}"))
        let printed = TerminalText.escape(text)
        #expect(!printed.contains("\u{1b}"))
        #expect(printed.contains("\\u{1b}]0;pwned\\u{7}"))
    }

    @Test func replyTextNamesWhatStillWaits() {
        let result = ReplyResult(
            replied: [RepliedThread(thread: ThreadID(41), status: .addressed, comment: CommentID(210)),
                      RepliedThread(thread: ThreadID(42), status: .addressed, comment: CommentID(211)),
                      RepliedThread(thread: ThreadID(43), status: .declined, comment: CommentID(212)),
                      RepliedThread(thread: ThreadID(45), status: .question, comment: CommentID(213))],
            waitingOnYou: [ThreadID(44)], warnings: [], next: .replyRemaining)
        let text = ReplyText.render(result, reviews: [7], waitingKinds: [ThreadID(44): .answer], stackLabels: [])
        #expect(text == """
            Sent 4 replies on review 7: 2 addressed, 1 declined, 1 question.
            Still waiting on you: t44 (answer). Next: fix t44, reply, then run `eyeballs review --note "…"`.
            """)
    }
}

@Suite struct DraftStoreTests {
    @MainActor @Test func draftsSurviveANewStore() throws {
        let file = URL(fileURLWithPath: "/tmp/eb-drafts-\(UInt32.random(in: .min ... .max)).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = DraftKey.newThread(.lines(LineRange(path: "a.txt", side: .head, start: 3, end: 4)))
        let drafts = DraftStore(file: file)
        drafts.set("Half a thought", for: lines, stack: 1, layer: 2)
        drafts.set("Reply text", for: .reply(threadID: 9), stack: 1, layer: 2)
        drafts.set("Summary", for: .reviewSummary, stack: 1, layer: nil)
        drafts.flush()

        let reopened = DraftStore(file: file)
        #expect(reopened.text(for: lines, stack: 1, layer: 2) == "Half a thought")
        #expect(reopened.text(for: lines, stack: 1, layer: 3).isEmpty)
        #expect(reopened.text(for: .reply(threadID: 9), stack: 1, layer: 5) == "Reply text")
        #expect(reopened.text(for: .reviewSummary, stack: 1, layer: 7) == "Summary")

        reopened.set("", for: lines, stack: 1, layer: 2)
        reopened.flush()
        #expect(DraftStore(file: file).text(for: lines, stack: 1, layer: 2).isEmpty)
    }
}
