@testable import EyeballsCore
import Foundation
import Testing

struct GitRunnerTests {
    @Test func returnsWhatGitPrinted() async throws {
        let fixture = try GitFixture()
        let result = try await Git(directory: fixture.repo).run(["rev-parse", "--is-inside-work-tree"])
        #expect(result.status == 0)
        #expect(result.text == "true")
    }

    @Test func sendsInputOnStdin() async throws {
        let fixture = try GitFixture()
        let result = try await Git(directory: fixture.repo).run(["hash-object", "--stdin"], input: Data("hello\n".utf8))
        #expect(result.text == "ce013625030ba8dba906f756967f9e9ca394464a")
    }

    @Test func throwsWithTheStatusWhenGitFails() async throws {
        let fixture = try GitFixture()
        await #expect(throws: GitError.commandFailed(subcommand: "rev-parse", status: 128, message: "fatal: Needed a single revision")) {
            try await Git(directory: fixture.repo).run(["rev-parse", "--verify", "no-such-branch"])
        }
    }

    @Test func acceptsTheStatusesItIsTold() async throws {
        let fixture = try GitFixture()
        let result = try await Git(directory: fixture.repo).run(["rev-parse", "--verify", "--quiet", "nope"], acceptedStatuses: [0, 1])
        #expect(result.status == 1)
    }

    @Test func dropsInheritedGitVariablesAndSetsItsOwn() {
        let environment = Git.environment(from: [
            "PATH": "/usr/bin", "GIT_DIR": "/elsewhere", "GIT_EXTERNAL_DIFF": "/bin/evil", "GIT_OPTIONAL_LOCKS": "1",
        ])
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["GIT_DIR"] == nil)
        #expect(environment["GIT_EXTERNAL_DIFF"] == nil)
        #expect(environment["GIT_OPTIONAL_LOCKS"] == "0")
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(environment["GIT_LITERAL_PATHSPECS"] == "1")
    }

    @Test func neverRunsTheRepositorysFsmonitor() async throws {
        let fixture = try GitFixture()
        let marker = fixture.root.appendingPathComponent("fsmonitor-ran")
        try installMarkerScript(named: "fsmonitor.sh", marking: marker, in: fixture)
        try fixture.write("a.txt", "a\n")
        try fixture.commit("one")
        try fixture.git(["config", "core.fsmonitor", fixture.root.appendingPathComponent("fsmonitor.sh").path])

        _ = try await Git(directory: fixture.repo).run(["status", "--porcelain"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        try fixture.git(["status", "--porcelain"])
        #expect(FileManager.default.fileExists(atPath: marker.path), "The fixture should prove the script runs without the guard")
    }

    @Test(arguments: ["--output=/tmp/x", "-p", "", "main\nother"])
    func refusesRevisionsGitWouldMisread(revision: String) async throws {
        let fixture = try GitFixture()
        let repository = try await fixture.repository()
        await #expect(throws: GitError.self) {
            _ = try await repository.resolveCommit(revision)
        }
    }

    @Test func escapesControlCharactersInGitsMessage() {
        let result = GitResult(status: 1, output: Data(), errorOutput: Data("warning\nfatal: bad \u{1B}[31mref\n".utf8))
        #expect(result.errorSummary == "fatal: bad \\u{1b}[31mref")
    }

    private func installMarkerScript(named name: String, marking marker: URL, in fixture: GitFixture) throws {
        let script = fixture.root.appendingPathComponent(name)
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }
}
