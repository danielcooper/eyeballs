import EyeballsKit
import Foundation
import Testing

/// Which stack a command means when it names none, and what `eyeballs open` without a path does.
struct StackChoiceTests {
    @Test func inboxUsesTheStackTheSessionDrivesWhileAnotherBranchIsCheckedOut() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let driven = try fixture.stackID()
        _ = try await fixture.submitComment("Why?", lines: 21...21)

        try BackendFixture.git(fixture.repo, "checkout", "-q", "-b", "other", "main")
        let other = try await fixture.service.openRepository(at: fixture.repo).stack.id
        #expect(other != driven)

        let (result, _) = try await fixture.inbox()
        #expect(result.status == .threads)
        #expect(result.stack?.id == StackID(driven))
        #expect(result.threads.count == 1)
    }

    @Test func openWithoutAPathShowsTheDrivenStackAndAddsNone() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let driven = try fixture.stackID()
        try BackendFixture.git(fixture.repo, "checkout", "-q", "-b", "other", "main")

        let (result, text) = try await fixture.service.open(OpenArguments(path: nil), client: fixture.agent)
        #expect(result.stacks.map(\.id) == [StackID(driven)])
        #expect(text.hasPrefix("Showing"))
        #expect(try fixture.store.activeStacks().count == 1)
    }

    @Test func openWithoutAPathFromAStrangerOnlyBringsTheWindowForward() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        try BackendFixture.git(fixture.repo, "checkout", "-q", "-b", "other", "main")
        let stranger = BackendFixture.client(session: "session-2", process: BackendFixture.otherProcess, cwd: fixture.repo.path)

        let (result, text) = try await fixture.service.open(OpenArguments(path: nil), client: stranger)
        #expect(result.stacks.isEmpty)
        #expect(text.hasPrefix("Brought Eyeballs to the front"))
        #expect(try fixture.store.activeStacks().count == 1)
    }
}
