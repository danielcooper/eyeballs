import EyeballsKit
import Foundation
import Testing

struct KitReplyBatchTests {
    @Test func readsTheDesignExample() throws {
        let text = """
            ## t41 addressed
            Money is Decimal now, and both callers are updated.

            ## t42 addressed
            at: Sources/API/Client.swift:40-58
            at: Sources/API/Retry.swift:1-30
            Only 5xx and URLError.timedOut retry now. 4xx fails at once.

            ## t43 declined
            Retry is its own type in Retry.swift, but I kept it internal. Tests use @testable import.

            ## t45 question
            Should sum() live in a shared utils module, or stay local to Checkout?
            """
        let replies = try ReplyBatch.parse(text)
        #expect(replies.map(\.thread) == [ThreadID(41), ThreadID(42), ThreadID(43), ThreadID(45)])
        #expect(replies.map(\.status) == [.addressed, .addressed, .declined, .question])
        #expect(replies[0].body == "Money is Decimal now, and both callers are updated.")
        #expect(replies[1].at == [
            LineSpan(path: "Sources/API/Client.swift", start: 40, end: 58),
            LineSpan(path: "Sources/API/Retry.swift", start: 1, end: 30),
        ])
        #expect(replies[1].body == "Only 5xx and URLError.timedOut retry now. 4xx fails at once.")
        #expect(replies[3].at.isEmpty)
    }

    @Test func keepsIndentedHeadersAndLaterAtLinesInTheBody() throws {
        let text = "## 41 addressed\nFirst line.\n  ## t99 addressed\nat: not a range line\n\n```\ncode\n```\n"
        let replies = try ReplyBatch.parse(text)
        #expect(replies.count == 1)
        #expect(replies[0].thread == ThreadID(41))
        #expect(replies[0].body == "First line.\n  ## t99 addressed\nat: not a range line\n\n```\ncode\n```")
    }

    @Test func acceptsCRLFAndUppercaseStatus() throws {
        let replies = try ReplyBatch.parse("## t7 Addressed\r\nat: a.swift:3\r\nDone.\r\n")
        #expect(replies == [ReplyItem(thread: ThreadID(7), status: .addressed, body: "Done.", at: [LineSpan(path: "a.swift", start: 3, end: 3)])])
    }

    @Test(arguments: [
        ("Hello\n## t41 addressed\nx", "before the first"),
        ("## t41 adressed\nx", "needs a status"),
        ("## tx addressed\nx", "needs a thread ID"),
        ("## t41\nx", "must be a header"),
        ("## t41 addressed extra\nx", "must be a header"),
        ("## t41 addressed\n\n", "has no reply text"),
        ("## t41 addressed\nat: nowhere\nx", "not PATH:A-B"),
        ("", "no ## t<id> <status> header"),
        ("## t41 addressed\nx\n## t41 declined\ny", "twice"),
    ])
    func refusesTheWholeBatch(text: String, expected: String) {
        do {
            _ = try ReplyBatch.parse(text)
            Issue.record("Expected the batch to fail")
        } catch let error as EyeballsError {
            #expect(error.code == .badInput)
            #expect(error.message.contains(expected), "\(error.message)")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func listsEveryProblemAndNeverQuotesBadValues() throws {
        do {
            _ = try ReplyBatch.parse("## t1 frobnicated\nx\n## t2 addressed\n\n## tzz9 declined\ny")
            Issue.record("Expected the batch to fail")
        } catch let error as EyeballsError {
            #expect(error.message.contains("3 problems"))
            #expect(error.message.contains("line 1"))
            #expect(error.message.contains("line 3"))
            #expect(error.message.contains("line 5"))
            #expect(!error.message.contains("frobnicated"))
            #expect(!error.message.contains("tzz9"))
        }
    }

    @Test func enforcesTheSizeLimits() {
        let tooMany = (1...201).map { "## t\($0) addressed\nDone." }.joined(separator: "\n")
        #expect(throws: EyeballsError.self) { try ReplyBatch.parse(tooMany) }
        let longBody = "## t1 addressed\n" + String(repeating: "x", count: WireLimits.maximumBodyBytes + 1)
        #expect(throws: EyeballsError.self) { try ReplyBatch.parse(longBody) }
        let fine = (1...200).map { "## t\($0) addressed\nDone." }.joined(separator: "\n")
        #expect(throws: Never.self) { try ReplyBatch.parse(fine) }
    }

    @Test func readsTheJSONForm() throws {
        let json = #"[{"thread":"t42","status":"addressed","body":"Fixed.","at":["Sources/API/Client.swift:40-58"]},{"thread":43,"status":"question","body":"Which?"},{"thread":"44","status":"declined","body":"No.","at":null}]"#
        let replies = try ReplyBatch.parseJSON(Array(json.utf8))
        #expect(replies == [
            ReplyItem(thread: ThreadID(42), status: .addressed, body: "Fixed.", at: [LineSpan(path: "Sources/API/Client.swift", start: 40, end: 58)]),
            ReplyItem(thread: ThreadID(43), status: .question, body: "Which?"),
            ReplyItem(thread: ThreadID(44), status: .declined, body: "No."),
        ])
    }

    @Test(arguments: [
        (#"{"thread":"t1"}"#, "must be an array"),
        (#"[{"thread":"t1","body":"x"}]"#, "needs a status"),
        (#"[{"status":"addressed","body":"x"}]"#, "needs a thread"),
        (#"[{"thread":"t1","status":"addressed"}]"#, "needs a body"),
        (#"[{"thread":"t1","status":"addressed","body":"x","at":["nope"]}]"#, "not PATH:A-B"),
        (#"[{"thread":"t1","status":"addressed","body":"  "}]"#, "has no text"),
        (#"[1,"#, "does not parse"),
        ("[]", "no replies"),
    ])
    func refusesBadJSON(json: String, expected: String) {
        do {
            _ = try ReplyBatch.parseJSON(Array(json.utf8))
            Issue.record("Expected the JSON to fail")
        } catch let error as EyeballsError {
            #expect(error.code == .badInput)
            #expect(error.message.contains(expected), "\(error.message)")
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }
}

struct KitIDTests {
    @Test(arguments: [("t41", 41), ("41", 41), ("T41", 41), ("t1", 1), ("999999999999999999", 999_999_999_999_999_999)])
    func readsThreadIDs(text: String, number: Int) {
        #expect(ThreadID(parsing: text) == ThreadID(number))
    }

    @Test(arguments: ["", "t", "t0", "0", "041", "t041", "-1", "+1", "t 41", "41x", "s41", "t١٢", "9999999999999999999"])
    func rejectsOtherThreadIDs(text: String) {
        #expect(ThreadID(parsing: text) == nil)
    }

    @Test func idsEncodeWithTheirPrefix() throws {
        #expect(try JSONValue(encoding: [ThreadID(41)]).serialized() == #"["t41"]"#)
        #expect(try JSONValue(encoding: StackID(3)).serialized() == #""s3""#)
        #expect(try JSONValue(encoding: CommentID(210)).serialized() == #""c210""#)
        #expect(try JSONValue(parsing: "[41, \"t42\", \"43\"]").decode([ThreadID].self) == [ThreadID(41), ThreadID(42), ThreadID(43)])
    }

    @Test func stackReferencesNameAnIDOrABranch() throws {
        #expect(StackReference(parsing: "s3") == .id(StackID(3)))
        #expect(StackReference(parsing: "3") == .id(StackID(3)))
        #expect(StackReference(parsing: "feature/api-client") == .branch("feature/api-client"))
        #expect(StackReference(parsing: "") == nil)
        #expect(StackReference(parsing: "two words") == nil)
        let encoded = try JSONValue(encoding: [StackReference.id(StackID(3)), .branch("x")])
        #expect(encoded.serialized() == #"[{"id":"s3"},{"branch":"x"}]"#)
        #expect(try encoded.decode([StackReference].self) == [.id(StackID(3)), .branch("x")])
    }
}

struct KitDurationAndRangeTests {
    @Test(arguments: [("90s", 90), ("30m", 1800), ("2h", 7200), ("1s", 1), ("2400h", 8_640_000)])
    func readsDurations(text: String, seconds: Int64) throws {
        #expect(try DurationText.parse(text) == .seconds(seconds))
    }

    @Test(arguments: ["", "s", "0s", "5", "5d", "-5s", "+5s", "1.5h", "5 m", "2401h", "99999999999h", "5S"])
    func rejectsOtherDurations(text: String) {
        #expect(throws: EyeballsError.self) { try DurationText.parse(text) }
    }

    @Test func formatsDurations() {
        #expect(DurationText.format(.seconds(1500)) == "25m")
        #expect(DurationText.format(.seconds(7200)) == "2h")
        #expect(DurationText.format(.seconds(90)) == "90s")
    }

    @Test(arguments: [
        ("Sources/API/Client.swift:40-58", "Sources/API/Client.swift", 40, 58),
        ("a.swift:7", "a.swift", 7, 7),
        ("odd:name.swift:3-4", "odd:name.swift", 3, 4),
        ("  spaced.swift :1-1", "spaced.swift", 1, 1),
    ])
    func readsLineRanges(text: String, path: String, start: Int, end: Int) throws {
        #expect(try LineSpan(parsing: text) == LineSpan(path: path, start: start, end: end))
    }

    @Test(arguments: ["a.swift", "a.swift:", ":3", "a:0", "a:5-3", "a:3-", "a:x-y", "a:1-2-3", "a:01"])
    func rejectsOtherLineRanges(text: String) {
        #expect(throws: EyeballsError.self) { try LineSpan(parsing: text) }
    }

    @Test func lineRangesPrintAsWritten() {
        #expect(LineSpan(path: "a.swift", start: 40, end: 58).description == "a.swift:40-58")
        #expect(LineSpan(path: "a.swift", start: 7, end: 7).description == "a.swift:7")
    }
}

struct KitTerminalTextTests {
    @Test func escapesEscape() {
        #expect(TerminalText.escape("red: \u{1b}[31mX\u{1b}[0m") == "red: \\u{1b}[31mX\\u{1b}[0m")
    }

    @Test func keepsTabsAndNewlines() {
        #expect(TerminalText.escape("a\tb\nc") == "a\tb\nc")
    }

    @Test func escapesEveryOtherControlCharacter() {
        #expect(TerminalText.escape("\u{0}\r\u{7}\u{7f}\u{9b}") == "\\u{0}\\u{d}\\u{7}\\u{7f}\\u{9b}")
    }

    @Test func leavesOrdinaryTextAlone() {
        let text = "Plain text, ünïcödé, 😀 and a \\u{1b} already written out."
        #expect(TerminalText.escape(text) == text)
    }
}

struct KitWatchLineTests {
    @Test func oneLinePassesThrough() {
        #expect(WatchLine.merge(["eyeballs: Alex sent a comment. Run: eyeballs inbox"]) == "eyeballs: Alex sent a comment. Run: eyeballs inbox")
    }

    @Test func severalLinesShowTheCountAndTheNewest() {
        let merged = WatchLine.merge([
            "eyeballs: Alex sent a comment on t41. Run: eyeballs inbox",
            "eyeballs: Alex submitted review 7 on checkout-v2 (s3, r4): 5 threads, changes requested. Run: eyeballs inbox",
        ])
        #expect(merged == "eyeballs: 2 updates. Latest: Alex submitted review 7 on checkout-v2 (s3, r4): 5 threads, changes requested. Run: eyeballs inbox")
    }

    @Test func staysWithinTheBudget() {
        let long = "eyeballs: " + String(repeating: "x", count: 195)
        #expect(WatchLine.merge(["a", long]).count <= TextBudget.eventLine)
        #expect(WatchLine.merge([long + "y\nz"]).count == TextBudget.eventLine)
        #expect(!WatchLine.merge(["two\nlines"]).contains("\n"))
    }
}
