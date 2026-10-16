import EyeballsKit
import Foundation
import Testing

struct KitWireTests {
    @Test func requestLinesHaveTheDesignShape() throws {
        let line = try request(.inbox, InboxArguments(), id: 7).line()
        let text = String(decoding: line, as: UTF8.self)
        #expect(text == #"{"v":1,"id":7,"op":"inbox","client":{"agent":"claude","session":"session-1","pid":4242,"pid_start":1760620000,"ancestors":[100,50],"cwd":"/Users/alex/src/shop"},"args":{"stack":null,"page":1,"peek":false}}"# + "\n")
        let decoded = try Request.decode(line: line.dropLast())
        #expect(decoded == (try request(.inbox, InboxArguments(), id: 7)))
        #expect(try decoded.decodeArguments(InboxArguments.self) == InboxArguments())
    }

    @Test func aNewerVersionGetsVersionMismatchFirst() {
        let line = #"{"v":2,"id":9,"op":"something-new","client":"whatever"}"#
        do {
            _ = try Request.decode(line: Array(line.utf8))
            Issue.record("Expected a rejection")
        } catch {
            #expect(error.id == 9)
            #expect(error.error.code == .versionMismatch)
            #expect(error.error.code.exitStatus == 78)
        }
    }

    @Test(arguments: [
        "not json",
        "[1]",
        #"{"id":1,"op":"inbox","client":{}}"#,
        #"{"v":1,"op":"inbox","client":{"agent":"a","ancestors":[],"cwd":"/"}}"#,
        #"{"v":1,"id":1,"client":{"agent":"a","ancestors":[],"cwd":"/"}}"#,
        #"{"v":1,"id":1,"op":"inbox","client":{"agent":"a"}}"#,
        #"{"v":1,"id":1,"op":"inbox","client":{"agent":"a","ancestors":[],"cwd":"/"},"args":[]}"#,
    ])
    func malformedRequestsGetBadInput(line: String) {
        do {
            _ = try Request.decode(line: Array(line.utf8))
            Issue.record("Expected a rejection")
        } catch {
            #expect(error.error.code == .badInput)
        }
    }

    @Test func argumentsAreValidatedAsTheyAreDecoded() throws {
        let replies = (1...201).map { ReplyItem(thread: ThreadID($0), status: .addressed, body: "Done.") }
        let tooMany = try request(.reply, ReplyArguments(replies: replies))
        #expect(throws: EyeballsError.self) { try tooMany.decodeArguments(ReplyArguments.self) }
        let wrongShape = try request(.reply, ["replies": "nope"])
        do {
            _ = try wrongShape.decodeArguments(ReplyArguments.self)
            Issue.record("Expected bad_input")
        } catch let error as EyeballsError {
            #expect(error.code == .badInput)
        }
    }

    @Test func responseLinesHaveTheDesignShape() throws {
        let success = Response(id: 7, outcome: try .success(StatusResult.notRunning, text: "Eyeballs: app not running."))
        #expect(String(decoding: success.line(), as: UTF8.self) ==
            #"{"id":7,"ok":true,"result":{"schema":"eyeballs.status/1","ok":true,"app":"not_running","stacks":[],"listening":[]},"text":"Eyeballs: app not running."}"# + "\n")
        #expect(try Response(line: success.line().dropLast()) == success)

        let failure = Response(id: 7, outcome: .failure(EyeballsError(.midOperation, "A rebase is paused.", hint: "Finish it.", retryAfterSeconds: 10)))
        #expect(String(decoding: failure.line(), as: UTF8.self) ==
            #"{"id":7,"ok":false,"error":{"code":"mid_operation","message":"A rebase is paused.","hint":"Finish it.","retry_after_s":10}}"# + "\n")
        #expect(try Response(line: failure.line().dropLast()) == failure)
    }

    @Test func unreadableResponsesAreInternalErrors() {
        for line in ["{}", #"{"id":1,"ok":false,"error":"x"}"#, "garbage"] {
            do {
                _ = try Response(line: Array(line.utf8))
                Issue.record("Expected an error")
            } catch let error as EyeballsError {
                #expect(error.code == .internalError)
            } catch {
                Issue.record("Unexpected error \(error)")
            }
        }
    }
}

struct KitExitStatusTests {
    @Test(arguments: [
        (ErrorCode.notARepo, Int32(65)), (.noStack, 65), (.unknownThread, 65), (.badInput, 65), (.unsupportedCatalog, 65),
        (.appUnavailable, 69), (.sandboxBlocked, 69), (.internalError, 70), (.midOperation, 75), (.unreplied, 77),
        (.versionMismatch, 78), ("something_new", 70),
    ])
    func mapsEveryCodeToTheDesignTable(code: ErrorCode, status: Int32) {
        #expect(code.exitStatus == status)
    }

    @Test func unknownErrorsExit70() {
        struct Surprise: Error {}
        #expect(ExitStatus.forError(Surprise()) == 70)
        #expect(EyeballsError(Surprise()).code == .internalError)
    }

    @Test func socketErrorsMapToTheirCodes() {
        #expect(ExitStatus.forError(SocketClientError.notRunning) == 69)
        #expect(EyeballsError(SocketClientError.blocked).code == .sandboxBlocked)
        #expect(ExitStatus.forError(SocketClientError.timedOut(seconds: 5)) == 69)
        #expect(ExitStatus.forError(SocketClientError.requestTooLarge(bytes: 2_000_000)) == 65)
        #expect(ExitStatus.forError(SocketClientError.malformedResponse) == 70)
    }

    @Test func errorDocumentsHaveTheDesignShape() throws {
        let document = ErrorDocument(error: EyeballsError(.unreplied, "t44 has no reply.", hint: "Reply first, or pass --force."))
        #expect(try JSONValue(encoding: document).serialized() ==
            #"{"schema":"eyeballs.error/1","ok":false,"error":{"code":"unreplied","message":"t44 has no reply.","hint":"Reply first, or pass --force.","retry_after_s":null}}"#)
    }
}

struct KitResultShapeTests {
    @Test func waitEventsMatchTheDesign() throws {
        let event = WaitEvent(event: .reviewSubmitted, stack: StackID(3), review: 7, threads: 5, verdict: .changesRequested)
        #expect(try JSONValue(encoding: event).serialized() ==
            #"{"schema":"eyeballs.wait/1","ok":true,"event":"review.submitted","stack":"s3","review":7,"threads":5,"verdict":"changes_requested","next":"run_inbox"}"#)
    }

    @Test func replyResultsMatchTheDesign() throws {
        let result = ReplyResult(replied: [RepliedThread(thread: ThreadID(41), status: .addressed, comment: CommentID(210))],
                                 waitingOnYou: [ThreadID(44)], warnings: [], next: .replyRemaining)
        #expect(try JSONValue(encoding: result).serialized() ==
            #"{"schema":"eyeballs.reply/1","ok":true,"replied":[{"thread":"t41","status":"addressed","comment":"c210"}],"waiting_on_you":["t44"],"warnings":[],"next":"reply_remaining"}"#)
    }

    @Test func inboxThreadsMatchTheDesign() throws {
        let thread = InboxThread(
            id: ThreadID(42), kind: .new, review: 7, shownBefore: true,
            layer: ThreadLayer(position: 2, branch: "api-client", pr: 812, checkout: "/Users/alex/src/shop-wt/api-client"),
            subject: .line, side: .head, path: "Sources/API/Client.swift", start: 40, end: 44, commit: "9f2c1ab",
            anchor: .current, commentedOn: 4, code: ["  func get(_ path: String) async throws -> Data {"], original: nil,
            history: [], comment: InboxComment(id: CommentID(203), body: "This retries on 4xx too. Only retry 5xx and timeouts."))
        #expect(try JSONValue(encoding: thread).serialized() ==
            #"{"id":"t42","kind":"new","review":7,"shown_before":true,"layer":{"position":2,"branch":"api-client","pr":812,"checkout":"/Users/alex/src/shop-wt/api-client"},"subject":"line","side":"head","path":"Sources/API/Client.swift","start":40,"end":44,"commit":"9f2c1ab","anchor":"current","commented_on":4,"code":["  func get(_ path: String) async throws -> Data {"],"original":null,"history":[],"comment":{"id":"c203","body":"This retries on 4xx too. Only retry 5xx and timeouts."}}"#)
        let result = InboxResult(status: .nothing, stack: nil, revision: nil, reviewer: "the reviewer", next: .runWaitInBackground)
        #expect(try JSONValue(encoding: result).serialized().hasSuffix(#""more":false,"next_page":null,"next":"run_wait_in_background"}"#))
    }

    @Test func everyResultStartsWithSchemaAndOk() throws {
        let stack = StackSummary(id: StackID(3), name: "checkout-v2", source: .ghStack, trunk: "main", repo: "/r")
        let layer = ThreadLayer(position: 1, branch: "models")
        let shown = ShownThread(id: ThreadID(1), status: .open, state: "Waiting on agent", subject: .file, side: nil, layer: layer,
                                path: "a", start: nil, end: nil, commit: nil, anchor: .current, revision: 1, code: [], original: nil,
                                comments: [], anchors: [])
        let documents: [(any Encodable, String)] = [
            (ReviewResult(stack: stack, revision: 1, created: false, layers: [], ported: PortCounts(), warnings: [], waitingOnYou: [],
                          waitingOnReviewer: 0, listening: [.wait], next: .endTurn), "review"),
            (WaitEvent(event: .timeout, stack: nil), "wait"),
            (InboxResult(status: .nothing, stack: nil, revision: nil, reviewer: "Alex", next: .runWaitInBackground), "inbox"),
            (ShowResult(stack: stack, thread: shown), "show"),
            (ReplyResult(replied: [], waitingOnYou: [], warnings: [], next: .runReview), "reply"),
            (ThreadsResult(threads: []), "threads"),
            (StatusResult.notRunning, "status"),
            (AttachResult(stack: stack, revision: 1, tookOver: false, next: .runWaitInBackground), "attach"),
            (HookResult(output: nil), "hook"),
            (OpenResult(repo: "/r", stacks: [stack]), "open"),
            (DoctorReport(cli: ComponentInfo(running: true, path: nil, version: nil, build: nil, protocolVersion: 1),
                          app: ComponentInfo(running: false, path: nil, version: nil, build: nil, protocolVersion: nil),
                          home: "/h", socket: "/h/run/eyeballs.sock", checks: [], permissionRule: "Bash(eyeballs *)",
                          sandboxSetting: ""), "doctor"),
            (ErrorDocument(error: EyeballsError(.internalError, "x")), "error"),
        ]
        for (document, kind) in documents {
            let value = try JSONValue(encoding: document)
            let keys = try #require(value.objectValue).keys
            #expect(Array(keys.prefix(2)) == ["schema", "ok"], "\(kind)")
            #expect(value["schema"] == .string("eyeballs.\(kind)/1"))
        }
    }

    @Test func hookOutputsHaveClaudeCodesShapes() {
        #expect(HookOutput.block(reason: "Eyeballs: Alex submitted review 7 (5 threads). Run eyeballs inbox.").serialized() ==
            #"{"decision":"block","reason":"Eyeballs: Alex submitted review 7 (5 threads). Run eyeballs inbox."}"#)
        #expect(HookOutput.sessionStartContext("Eyeballs: you drive checkout-v2 (s3) at r4.").serialized() ==
            #"{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Eyeballs: you drive checkout-v2 (s3) at r4."}}"#)
        let long = String(repeating: "x", count: 1000)
        #expect(HookOutput.block(reason: long)["reason"]?.stringValue?.count == TextBudget.stopReason)
    }

    @Test func doctorPrintsThePermissionRuleAndSandboxSetting() {
        #expect(DoctorReport.permissionRule(commandName: "eyeballs") == "Bash(eyeballs *)")
        #expect(DoctorReport.sandboxSetting(socket: "/Users/alex/Library/Application Support/Eyeballs/run/eyeballs.sock") ==
            #""sandbox":{"network":{"allowUnixSockets":["/Users/alex/Library/Application Support/Eyeballs/run/eyeballs.sock"]}}"#)
    }

    @Test func timeoutEventsSayToRunInbox() {
        let event = WaitEvent.timeoutEvent(after: .seconds(1500), stack: StackID(3))
        #expect(event.text == "eyeballs: Nothing arrived within 25m. Run: eyeballs inbox")
        #expect(event.result["event"] == .string("timeout"))
        #expect(event.result["next"] == .string("run_inbox"))
        #expect(event.text.count <= TextBudget.eventLine)
    }

    @Test func listenerKeysPreferTheClaudeProcess() {
        #expect(ListenerKey(client: client()) == .claudeProcess(testProcess))
        #expect(ListenerKey(client: client(process: nil)) == .session(agent: "claude", session: "session-1"))
        #expect(ListenerKey(client: client(process: nil, session: nil)) == nil)
    }
}
