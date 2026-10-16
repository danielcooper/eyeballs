import Darwin
import EyeballsKit
import Foundation
import Testing

struct KitIdentityTests {
    @Test func readsClaudeCodesEnvironment() {
        let me = getpid()
        let identity = AgentIdentity.current(
            environment: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "abc-123", "CLAUDE_PID": String(me)],
            workingDirectory: "/Users/alex/src/shop")
        #expect(identity.agent == "claude")
        #expect(identity.session == "abc-123")
        #expect(identity.pid == me)
        #expect(identity.pidStart == ProcessInspector.live.startTime(me))
        #expect(identity.pidStart != nil)
        #expect(identity.ancestors.first == getppid())
        #expect(identity.cwd == "/Users/alex/src/shop")
        #expect(identity.claudeProcess.map(ProcessInspector.live.isAlive) == true)
    }

    @Test func flagsOverrideTheEnvironment() {
        let identity = AgentIdentity.current(
            environment: ["CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "abc"],
            agent: "fake-agent", session: "loop-1")
        #expect(identity.agent == "fake-agent")
        #expect(identity.session == "loop-1")
    }

    @Test func recognisesCodex() {
        let identity = AgentIdentity.current(environment: ["CODEX_THREAD_ID": "thread-9"])
        #expect(identity.agent == "codex")
        #expect(identity.session == "thread-9")
        #expect(identity.pid == nil)
    }

    @Test func anUnknownAgentIsOther() {
        let identity = AgentIdentity.current(environment: [:])
        #expect(identity.agent == "other")
        #expect(identity.session == nil)
        #expect(identity.pidStart == nil)
    }

    @Test(arguments: ["abc", "1", "0", "-5", "", "99999999999"])
    func ignoresUnusableProcessIDs(value: String) {
        let identity = AgentIdentity.current(environment: ["CLAUDECODE": "1", "CLAUDE_PID": value])
        #expect(identity.pid == nil)
        #expect(identity.pidStart == nil)
    }

    @Test func ignoresSessionsWithControlCharacters() {
        let identity = AgentIdentity.current(environment: ["CLAUDE_CODE_SESSION_ID": "bad\u{1b}[2J"])
        #expect(identity.session == nil)
        #expect(!AgentIdentity.isValidSession("bad\u{1b}"))
        #expect(!AgentIdentity.isValidSession(String(repeating: "x", count: 257)))
        #expect(AgentIdentity.isValidSession("0b6f0d6e-1c7a-4c5e-9d3a-2f1e7c9b8a10"))
    }

    @Test(arguments: [("claude", true), ("fake-agent_2.0", true), ("Claude", false), ("", false), ("a b", false),
                      (String(repeating: "a", count: 33), false)])
    func checksAgentNames(name: String, valid: Bool) {
        #expect(AgentIdentity.isValidAgentName(name) == valid)
    }

    @Test func aReusedProcessIDIsNotAlive() throws {
        let me = getpid()
        let start = try #require(ProcessInspector.live.startTime(me))
        #expect(ProcessInspector.live.isAlive(ClaudeProcess(pid: me, start: start)))
        #expect(!ProcessInspector.live.isAlive(ClaudeProcess(pid: me, start: start - 1)))
        #expect(!ProcessInspector.live.isAlive(ClaudeProcess(pid: Int32.max, start: start)))
        #expect(start > 1_600_000_000)
    }

    @Test func walksTheAncestorChainAndStopsBeforeLaunchd() {
        let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 1]
        let inspector = ProcessInspector(startTime: { _ in 1 }, parent: { parents[$0] })
        #expect(inspector.ancestors(of: 500) == [400, 300])
        let loop = ProcessInspector(startTime: { _ in 1 }, parent: { $0 == 7 ? 8 : 7 })
        #expect(loop.ancestors(of: 7) == [8, 7])
        let deep = ProcessInspector(startTime: { _ in 1 }, parent: { $0 + 1 })
        #expect(deep.ancestors(of: 2, limit: 5) == [3, 4, 5, 6, 7])
    }
}
