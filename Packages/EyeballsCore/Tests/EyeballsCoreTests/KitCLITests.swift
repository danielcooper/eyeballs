import Darwin
import EyeballsKit
import Foundation
import Testing

/// Runs the built `eyeballs` command against a fake app.
///
/// Set `EYEBALLS_CLI` to the helper inside a built Eyeballs.app to run these. Commands that may
/// start the app always run with a server listening, so no test ever launches Eyeballs. `open`
/// is left out, because it brings the app to the front even when it runs.
@Suite(.serialized, .enabled(if: builtCommand != nil, "Set EYEBALLS_CLI to the built eyeballs helper."))
struct KitCLITests {
    // MARK: Without the app

    @Test func printsItsVersion() async throws {
        let run = try await Self.run(["--version"])
        #expect(run.status == 0)
        #expect(run.stdout.hasPrefix("eyeballs 0.1.0 ("))
        #expect(run.stdout.hasSuffix(") protocol 1\n"))
    }

    @Test func statusSaysTheAppIsNotRunningAndExits0() async throws {
        let text = try await Self.run(["status", "--brief"])
        #expect(text.status == 0)
        #expect(text.stdout == "Eyeballs: app not running.\n")
        #expect(text.stderr.isEmpty)
        let json = try await Self.run(["status", "--json"])
        #expect(json.status == 0)
        #expect(json.stdout == #"{"schema":"eyeballs.status/1","ok":true,"app":"not_running","stacks":[],"listening":[]}"# + "\n")
    }

    @Test func aCommandThatDoesNotStartTheAppExits69() async throws {
        let text = try await Self.run(["threads"])
        #expect(text.status == 69)
        #expect(text.stderr == "eyeballs: Eyeballs is not running.\n")
        #expect(text.stdout == "Open Eyeballs, then try again.\n")
        let json = try await Self.run(["threads", "--json"])
        #expect(json.status == 69)
        let document = try JSONValue(parsing: json.stdout)
        #expect(document["schema"] == .string("eyeballs.error/1"))
        #expect(document["ok"] == .bool(false))
        #expect(document["error"]?["code"] == .string("app_unavailable"))
        #expect(json.stderr.split(separator: "\n").count == 1)
    }

    @Test func hooksExit0AndPrintNothingWithoutTheApp() async throws {
        for event in ["session-start", "stop", "session-end", "pre-compact-from-a-newer-plugin"] {
            let run = try await Self.run(["hook", event], stdin: #"{"session_id":"abc"}"#)
            #expect(run.status == 0, "\(event)")
            #expect(run.stdout.isEmpty, "\(event)")
        }
    }

    @Test func doctorExits0WithoutTheAppUnlessStrict() async throws {
        let relaxed = try await Self.run(["doctor", "--json"])
        #expect(relaxed.status == 0)
        let report = try JSONValue(parsing: relaxed.stdout)
        #expect(report["schema"] == .string("eyeballs.doctor/1"))
        #expect(report["permission_rule"]?.stringValue?.hasPrefix("Bash(eyeballs") == true)
        #expect(report["app"]?["running"] == .bool(false))

        let text = try await Self.run(["doctor"])
        #expect(text.status == 0)
        #expect(text.stdout.contains("Add this rule to permissions.allow in ~/.claude/settings.json:"))

        let strict = try await Self.run(["doctor", "--strict"])
        #expect(strict.status == 69)
        #expect(strict.stderr == "eyeballs: Eyeballs is not running.\n")
    }

    @Test func waitTimesOutWithoutTheApp() async throws {
        let run = try await Self.run(["wait", "--timeout", "1s"])
        #expect(run.status == 0)
        #expect(run.stdout == "eyeballs: Nothing arrived within 1s. Run: eyeballs inbox\n")
        let json = try await Self.run(["wait", "--timeout", "1s", "--json"])
        #expect(try JSONValue(parsing: json.stdout)["event"] == .string("timeout"))
    }

    @Test(arguments: [
        ["show", "x41"],
        ["review", "--stack", "s3", "--branch", "b"],
        ["review", "--trunk", "main"],
        ["wait", "--timeout", "5d"],
        ["inbox", "--page", "0"],
        ["reply"],
        ["reply", "t41", "fixed", "--body", "x"],
        ["reply", "--file", "-", "--body", "x"],
        ["threads", "--open", "--all"],
        ["inbox", "--agent", "Not Valid"],
        ["no-such-command"],
    ])
    func usageErrorsExit64(arguments: [String]) async throws {
        let run = try await Self.run(arguments)
        #expect(run.status == 64)
        #expect(run.stderr.hasPrefix("Error: "))
    }

    @Test(arguments: [["hook"], ["hook", "stop", "--flag-from-a-newer-plugin"], ["status", "--agent", "Not Valid"], ["status", "--nope"]])
    func hookAndStatusUsageErrorsStillExit0(arguments: [String]) async throws {
        let run = try await Self.run(arguments)
        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.hasPrefix("Error: "))
    }

    // MARK: With a fake app

    @Test func eachCommandSendsItsOperationAndArguments() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let cases: [([String], String, String?)] = [
                (["review", "--branches", "models, api", "--trunk", "main", "--note", "Moved to Decimal.", "--focus"], "review",
                 #"{"stack":null,"branch":null,"branches":["models","api"],"trunk":"main","note":"Moved to Decimal.","focus":true,"force":false}"#),
                (["review", "--stack", "s3", "--force"], "review",
                 #"{"stack":{"id":"s3"},"branch":null,"branches":null,"trunk":null,"note":null,"focus":false,"force":true}"#),
                (["inbox", "--page", "2", "--peek", "--stack", "api-client"], "inbox", #"{"stack":{"branch":"api-client"},"page":2,"peek":true}"#),
                (["show", "41", "--context", "3"], "show", #"{"thread":"t41","context":3}"#),
                (["reply", "t41", "declined", "--body", "Kept it.", "--at", "a.swift:1-2"], "reply",
                 #"{"replies":[{"thread":"t41","status":"declined","body":"Kept it.","at":[{"path":"a.swift","start":1,"end":2}]}]}"#),
                (["threads", "--all"], "threads", #"{"filter":"all"}"#),
                (["attach", "--stack", "s3"], "attach", #"{"stack":{"id":"s3"}}"#),
                (["status", "--brief"], "status", #"{"brief":true}"#),
            ]
            for (arguments, operation, expected) in cases {
                let run = try await Self.run(arguments, home: home)
                #expect(run.status == 0, "\(arguments)")
                #expect(run.stdout == "did \(operation)\n", "\(arguments)")
                #expect(handler.requests.last?.operation.rawValue == operation)
                if let expected { #expect(handler.requests.last?.arguments.serialized() == expected, "\(arguments)") }
            }
        }
    }

    @Test func repliesFromStandardInput() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let batch = "## t41 addressed\nat: Sources/Order.swift:12-14\nMoney is Decimal now.\n\n## 42 question\nShould sum() be shared?\n"
            let text = try await Self.run(["reply", "--file", "-"], home: home, stdin: batch)
            #expect(text.status == 0)
            let replies = try #require(handler.requests.last).decodeArguments(ReplyArguments.self).replies
            #expect(replies.map(\.thread) == [ThreadID(41), ThreadID(42)])
            #expect(replies[0].at == [LineSpan(path: "Sources/Order.swift", start: 12, end: 14)])

            let json = #"[{"thread":"t43","status":"addressed","body":"Done."}]"#
            let fromJSON = try await Self.run(["reply", "--json-file", "-"], home: home, stdin: json)
            #expect(fromJSON.status == 0)
            #expect(try handler.requests.last?.decodeArguments(ReplyArguments.self).replies.map(\.thread) == [ThreadID(43)])
        }
    }

    @Test func aBadBatchExits65AndSendsNothing() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let run = try await Self.run(["reply", "--file", "-"], home: home, stdin: "## t41 fixed\nDone.\n")
            #expect(run.status == 65)
            #expect(run.stderr.contains("Nothing was sent."))
            let json = try await Self.run(["reply", "--file", "-", "--json"], home: home, stdin: "")
            #expect(json.status == 65)
            #expect(try JSONValue(parsing: json.stdout)["error"]?["code"] == .string("bad_input"))
        }
        #expect(handler.requests.isEmpty)
    }

    @Test func printsTheResultExactlyWithJSON() async throws {
        try await withServer(FakeHandler.echo()) { _, home in
            let run = try await Self.run(["threads", "--json"], home: home)
            #expect(run.stdout == #"{"schema":"eyeballs.echo/1","ok":true,"operation":"threads","arguments":{"filter":"open"}}"# + "\n")
        }
    }

    @Test func escapesControlCharactersInText() async throws {
        let handler = FakeHandler { _, _ in try .success(EchoResult(operation: "x", arguments: .null), text: "code: \u{1b}[31mred\u{1b}[0m\tok") }
        try await withServer(handler) { _, home in
            let run = try await Self.run(["inbox"], home: home)
            #expect(run.stdout == "code: \\u{1b}[31mred\\u{1b}[0m\tok\n")
            let json = try await Self.run(["inbox", "--json"], home: home)
            #expect(!json.stdout.contains("\u{1b}"))
        }
    }

    @Test(arguments: [
        (ErrorCode.unreplied, Int32(77)), (.midOperation, 75), (.versionMismatch, 78), (.noStack, 65), (.unknownThread, 65),
        (.sandboxBlocked, 69), (.internalError, 70), ("a_code_from_a_newer_app", 70),
    ])
    func mapsTheAppsErrorsToExitCodes(code: ErrorCode, status: Int32) async throws {
        let handler = FakeHandler { _, _ in .failure(EyeballsError(code, "Something about \(code.rawValue).", hint: "Do the next thing.")) }
        try await withServer(handler) { _, home in
            let text = try await Self.run(["review"], home: home)
            #expect(text.status == status)
            #expect(text.stderr == "eyeballs: Something about \(code.rawValue).\n")
            #expect(text.stdout == "Do the next thing.\n")
            let json = try await Self.run(["review", "--json"], home: home)
            #expect(json.status == status)
            #expect(try JSONValue(parsing: json.stdout)["error"]?["code"] == .string(code.rawValue))
        }
    }

    @Test func statusAndHooksExit0WhateverTheAppSays() async throws {
        let handler = FakeHandler { _, _ in .failure(EyeballsError(.versionMismatch, "The app speaks protocol 2.")) }
        try await withServer(handler) { _, home in
            let status = try await Self.run(["status", "--brief"], home: home)
            #expect(status.status == 0)
            #expect(status.stdout == "Eyeballs: The app speaks protocol 2.\n")
            let hook = try await Self.run(["hook", "stop"], home: home, stdin: "{}")
            #expect(hook.status == 0)
            #expect(hook.stdout.isEmpty)
        }
    }

    @Test func sendsTheAgentsIdentity() async throws {
        let handler = FakeHandler.echo()
        try await withServer(handler) { _, home in
            let me = getpid()
            let environment = ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "sess-9", "CLAUDE_PID": String(me)]
            _ = try await Self.run(["inbox"], home: home, environment: environment)
            let identity = try #require(handler.requests.last?.client)
            #expect(identity.agent == "claude")
            #expect(identity.session == "sess-9")
            #expect(identity.pid == me)
            #expect(identity.pidStart == ProcessInspector.live.startTime(me))
            #expect(identity.ancestors.first == me)

            _ = try await Self.run(["inbox", "--agent", "fake", "--session", "loop-1"], home: home, environment: environment)
            #expect(handler.requests.last?.client.agent == "fake")
            #expect(handler.requests.last?.client.session == "loop-1")
        }
    }

    @Test func hookStopForwardsItsInputAndPrintsTheAppsDecision() async throws {
        let handler = FakeHandler { request, _ in
            let arguments = try request.decodeArguments(HookArguments.self)
            let reason = "Eyeballs: Alex submitted review 7 (5 threads). Run eyeballs inbox."
            return try .success(HookResult(output: arguments.event == .stop ? HookOutput.block(reason: reason) : nil), text: "")
        }
        try await withServer(handler) { _, home in
            let stop = try await Self.run(["hook", "stop"], home: home, stdin: #"{"session_id":"abc","stop_hook_active":true}"#)
            #expect(stop.status == 0)
            #expect(stop.stdout == #"{"decision":"block","reason":"Eyeballs: Alex submitted review 7 (5 threads). Run eyeballs inbox."}"# + "\n")
            let input = try #require(handler.requests.last).decodeArguments(HookArguments.self).input
            #expect(input?["stop_hook_active"] == .bool(true))

            let start = try await Self.run(["hook", "session-start"], home: home, stdin: #"{"source":"clear"}"#)
            #expect(start.status == 0)
            #expect(start.stdout.isEmpty)

            let end = try await Self.run(["hook", "session-end"], home: home, stdin: #"{"reason":"exit"}"#)
            #expect(end.status == 0)
            #expect(await eventually { handler.requests.count == 3 })
            #expect(try handler.requests.last?.decodeArguments(HookArguments.self).event == .sessionEnd)
        }
    }

    @Test func doctorReportsTheRunningApp() async throws {
        let failing = Recorder<Bool>()
        let handler = FakeHandler { _, _ in
            let checks = failing.values.isEmpty ? [] : [DoctorCheck(name: "Anchors", status: .failed, message: "t41 has no anchor on r4.")]
            return try .success(AppHealth(version: "0.1.0", build: "7", path: "/Applications/Eyeballs.app", home: "/h", checks: checks), text: "")
        }
        try await withServer(handler) { _, home in
            let healthy = try await Self.run(["doctor", "--json", "--strict"], home: home)
            #expect(healthy.status == 0)
            #expect(try JSONValue(parsing: healthy.stdout)["app"]?["version"] == .string("0.1.0"))

            failing.append(true)
            let broken = try await Self.run(["doctor"], home: home)
            #expect(broken.status == 70)
            #expect(broken.stdout.contains("FAIL  Anchors: t41 has no anchor on r4."))
            #expect(broken.stderr == "eyeballs: 1 doctor check failed.\n")
        }
    }

    @Test func waitPrintsTheEventAndExits0() async throws {
        try await withServer(KitServerTests.streamingHandler()) { server, home in
            let wait = try Self.launch(["wait", "--json"], home: home, environment: Self.claudeEnvironment)
            #expect(await eventually { server.liveStreams().count == 1 })
            #expect(server.broadcast(try KitServerTests.submittedEvent(), to: .claudeProcess(Self.claudeProcess)) == 1)
            let status = try await wait.waitForExit()
            #expect(status == 0)
            #expect(wait.stdout.text == #"{"schema":"eyeballs.wait/1","ok":true,"event":"review.submitted","stack":"s3","review":7,"threads":5,"verdict":"changes_requested","next":"run_inbox"}"# + "\n")
        }
    }

    @Test func waitSurvivesTheAppQuitting() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let first = SocketServer(home: folder.home, handler: KitServerTests.streamingHandler())
        try first.start(holdingInstanceLock: true)
        let wait = try Self.launch(["wait"], home: folder.home, environment: Self.claudeEnvironment)
        #expect(await eventually { first.liveStreams().count == 1 })
        first.stop()

        try await Task.sleep(for: .milliseconds(300))
        let second = SocketServer(home: folder.home, handler: KitServerTests.streamingHandler())
        try second.start(holdingInstanceLock: true)
        defer { second.stop() }
        #expect(await eventually(timeout: .seconds(10)) { second.liveStreams().count == 1 })
        second.broadcast(try KitServerTests.submittedEvent(), to: .claudeProcess(Self.claudeProcess))
        #expect(try await wait.waitForExit() == 0)
        #expect(wait.stdout.text.hasPrefix("eyeballs: Alex submitted review 7"))
    }

    @Test func watchPrintsLinesMergesBurstsAndReconnects() async throws {
        let folder = try TemporaryFolder.make()
        defer { folder.remove() }
        let first = SocketServer(home: folder.home, handler: KitServerTests.streamingHandler())
        try first.start(holdingInstanceLock: true)
        let watch = try Self.launch(["watch"], home: folder.home, environment: Self.claudeEnvironment)
        defer { watch.terminate() }
        #expect(await eventually { first.liveStreams().count == 1 })

        first.broadcast(try KitServerTests.submittedEvent(), to: .claudeProcess(Self.claudeProcess))
        #expect(await eventually { watch.stdout.lines.count == 1 })
        #expect(watch.stdout.lines.first?.hasPrefix("eyeballs: Alex submitted review 7") == true)

        for text in ["eyeballs: Alex sent a comment on t41. Run: eyeballs inbox", "eyeballs: Alex sent a comment on t42. Run: eyeballs inbox"] {
            first.broadcast(try StreamEvent(WaitEvent(event: .commentSent, stack: StackID(3)), text: text, stack: StackID(3)),
                            to: .claudeProcess(Self.claudeProcess))
        }
        #expect(await eventually(timeout: .seconds(6)) { watch.stdout.lines.count == 2 })
        #expect(watch.stdout.lines.last == "eyeballs: 2 updates. Latest: Alex sent a comment on t42. Run: eyeballs inbox")

        first.stop()
        let second = SocketServer(home: folder.home, handler: KitServerTests.streamingHandler())
        try second.start(holdingInstanceLock: true)
        defer { second.stop() }
        #expect(await eventually(timeout: .seconds(10)) { second.liveStreams().count == 1 })
        second.broadcast(try KitServerTests.submittedEvent(), to: .claudeProcess(Self.claudeProcess))
        #expect(await eventually { watch.stdout.lines.count == 3 })
        #expect(watch.isRunning)
    }

    // MARK: Running the command

    static let claudeProcess = ClaudeProcess(pid: getpid(), start: ProcessInspector.live.startTime(getpid()) ?? 0)

    static var claudeEnvironment: [String: String] {
        ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "sess-1", "CLAUDE_PID": String(getpid())]
    }

    struct Run: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs the command to completion in a home with no app, unless `home` names one.
    static func run(_ arguments: [String], home: EyeballsHome? = nil, stdin: String? = nil,
                    environment: [String: String] = [:]) async throws -> Run {
        let folder = home == nil ? try TemporaryFolder.make() : nil
        defer { folder?.remove() }
        let process = try launch(arguments, home: home ?? folder!.home, stdin: stdin, environment: environment)
        let status = try await process.waitForExit()
        return Run(status: status, stdout: process.stdout.text, stderr: process.stderr.text)
    }

    static func launch(_ arguments: [String], home: EyeballsHome, stdin: String? = nil,
                       environment: [String: String] = [:]) throws -> CommandProcess {
        try CommandProcess(binary: builtCommand!, arguments: arguments, stdin: stdin, environment: [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "EYEBALLS_HOME": home.root.path,
        ].merging(environment) { $1 })
    }
}

let builtCommand = ProcessInfo.processInfo.environment["EYEBALLS_CLI"].flatMap { $0.isEmpty ? nil : $0 }

/// One run of the command, with its output collected as it arrives.
final class CommandProcess: Sendable {
    let stdout = CollectedOutput()
    let stderr = CollectedOutput()
    private let process: Process

    init(binary: String, arguments: [String], stdin: String?, environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        stdout.collect(from: output.fileHandleForReading)
        stderr.collect(from: errors.fileHandleForReading)
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    /// The exit status, once the process has exited and its output has all arrived.
    func waitForExit(timeout: Duration = .seconds(20)) async throws -> Int32 {
        let finished = await eventually(timeout: timeout) { [self] in !process.isRunning && stdout.isFinished && stderr.isFinished }
        guard finished else {
            terminate()
            throw SystemFailure(call: "the command did not finish within \(timeout)")
        }
        return process.terminationStatus
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    func collect(from handle: FileHandle) {
        DispatchQueue.global().async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                self.lock.withLock { self.data.append(chunk) }
            }
            self.lock.withLock { self.finished = true }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    var isFinished: Bool { lock.withLock { finished } }
    var lines: [String] { text.split(separator: "\n").map(String.init) }
}
