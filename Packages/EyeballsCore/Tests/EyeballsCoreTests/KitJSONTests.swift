import EyeballsKit
import Foundation
import Testing

struct KitJSONTests {
    @Test func keepsKeyOrderThroughParseAndWrite() throws {
        let text = #"{"schema":"eyeballs.x/1","ok":true,"zeta":1,"alpha":[1,2.5,"s",null,false],"mid":{"b":1,"a":2}}"#
        #expect(try JSONValue(parsing: text).serialized() == text)
    }

    @Test func escapesControlCharactersButNotSlashes() throws {
        let value = JSONValue.string("a\u{1b}[31m\"\\/\n\t\r\u{0}\u{7f}\u{9b}é")
        #expect(value.serialized() == #""a\u001b[31m\"\\/\n\t\r\u0000\u007f\u009bé""#)
        #expect(try JSONValue(parsing: value.serialized()) == value)
    }

    @Test func readsUnicodeEscapes() throws {
        #expect(try JSONValue(parsing: #""\u00e9\ud83d\ude00""#) == .string("é😀"))
        #expect(try JSONValue(parsing: #""\ud83d!""#) == .string("\u{FFFD}!"))
    }

    @Test func tellsIntegersFromDoubles() throws {
        #expect(try JSONValue(parsing: "42") == .integer(42))
        #expect(try JSONValue(parsing: "-7") == .integer(-7))
        #expect(try JSONValue(parsing: "4.5") == .double(4.5))
        #expect(try JSONValue(parsing: "1e3") == .double(1000))
        #expect(try JSONValue(parsing: "9223372036854775808") == .double(9_223_372_036_854_775_808))
    }

    @Test(arguments: [
        "", "{", "[1,]", "{a:1}", "01", "1.", "-", "\"tab\there\"", "tru", "[1] 2", "{\"a\" 1}", "\"\\x\"", "\"\\u12\"",
    ])
    func rejectsInvalidJSON(text: String) {
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: text) }
    }

    @Test func refusesDeepNesting() {
        let deep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(throws: JSONParseError.self) { try JSONValue(parsing: deep) }
        let fine = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        #expect(throws: Never.self) { try JSONValue(parsing: fine) }
    }

    @Test func parseErrorsNeverQuoteTheInput() throws {
        do {
            _ = try JSONValue(parsing: #"{"secret-token-123": nope}"#)
            Issue.record("Expected a parse error")
        } catch let error as JSONParseError {
            #expect(!error.description.contains("secret"))
            #expect(!error.description.contains("nope"))
        }
    }

    @Test func encodesInDeclarationOrderWithNulls() throws {
        struct Sample: Codable {
            var schema = "eyeballs.sample/1"
            var ok = true
            var zeta: Int? = nil
            var alpha = [1, 2]
            var nested = Nested()
        }
        struct Nested: Codable {
            var b = "x"
            var a: String? = nil
        }
        let value = try JSONValue(encoding: Sample())
        #expect(value.serialized() == #"{"schema":"eyeballs.sample/1","ok":true,"zeta":null,"alpha":[1,2],"nested":{"b":"x","a":null}}"#)
    }

    @Test func roundTripsAResultThroughJSONValue() throws {
        let result = ReviewResult(
            stack: StackSummary(id: StackID(3), name: "checkout-v2", source: .ghStack, trunk: "main", repo: "/Users/alex/src/shop"),
            revision: 4, created: true,
            layers: [ReviewLayer(position: 1, branch: "models", pr: 811, files: 4, additions: 120, deletions: 8,
                                 baseRule: "parent_tip", changedSinceLast: true)],
            ported: PortCounts(current: 3, moved: 1, outdated: 1),
            warnings: [Warning(code: .dirtyWorktree, message: "3 uncommitted files are not in this revision.")],
            waitingOnYou: [], waitingOnReviewer: 5, listening: [], next: .runWaitInBackground)
        let value = try JSONValue(encoding: result)
        #expect(try value.decode(ReviewResult.self) == result)
        #expect(value.serialized().hasPrefix(#"{"schema":"eyeballs.review/1","ok":true,"stack":{"id":"s3","name":"checkout-v2","source":"gh_stack","trunk":"main","repo":"/Users/alex/src/shop"},"revision":4,"created":true,"layers":[{"position":1,"branch":"models","pr":811,"files":4,"additions":120,"deletions":8,"base_rule":"parent_tip","changed_since_last":true}],"ported":{"current":3,"moved":1,"whitespace":0,"changed":0,"relocated":0,"outdated":1,"gone":0}"#))
    }

    @Test func jsonValueNestsInsideCodableTypes() throws {
        let input = try JSONValue(parsing: #"{"session_id":"abc","stop_hook_active":true}"#)
        let arguments = HookArguments(event: .stop, input: input)
        let value = try JSONValue(encoding: arguments)
        #expect(value.serialized() == #"{"event":"stop","input":{"session_id":"abc","stop_hook_active":true}}"#)
        let decoded = try value.decode(HookArguments.self)
        #expect(decoded.input?["session_id"] == .string("abc"))
        #expect(decoded.input?["stop_hook_active"] == .bool(true))
    }

    @Test func objectSubscriptReplacesInPlaceAndRemoves() {
        var object = JSONObject(["a": .integer(1), "b": .integer(2)])
        object["a"] = .integer(3)
        object["c"] = .null
        object["b"] = nil
        #expect(object.keys == ["a", "c"])
        #expect(JSONValue.object(object).serialized() == #"{"a":3,"c":null}"#)
    }
}
