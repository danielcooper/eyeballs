import EyeballsKit
import Foundation
import Testing

/// Closing stacks from the window: they leave the overview, keep their history, tell a waiting
/// agent, and come back as a new stack when the agent reviews the same branches again.
struct CloseStackTests {
    @Test func closingAStackTellsItsAgentAndHidesIt() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let stackID = try fixture.stackID()

        try await fixture.service.closeStacks([stackID])

        #expect(try fixture.store.activeStacks().isEmpty)
        #expect(try await fixture.service.overview(viewing: [:]).repositories.isEmpty)
        #expect(fixture.sink.events.contains { $0.event.text.contains("closed") })
        #expect(try fixture.store.facts(stackID: stackID)?.latestRevision != nil)
    }

    @Test func aWaitOnAClosedStackReturnsAtOnce() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let stackID = try fixture.stackID()
        try await fixture.service.closeStacks([stackID])

        let outcome = try await fixture.service.wait(WaitArguments(stack: .id(StackID(stackID))), client: fixture.agent)
        guard case .respond(.success(_, let text)) = outcome else {
            Issue.record("wait on a closed stack should answer at once, not stream")
            return
        }
        #expect(text.contains("closed"))
    }

    @Test func reviewingTheSameBranchesAgainStartsANewStack() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let first = try fixture.stackID()
        try await fixture.service.closeStacks([first])

        try await fixture.review()
        let second = try fixture.stackID()
        #expect(second != first)
        #expect(try fixture.store.activeStacks().count == 1)
    }
}
