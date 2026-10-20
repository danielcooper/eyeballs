import Foundation
import Testing

/// The Commits view shows one commit's own changes, against its parent.
struct CommitFilesTests {
    @Test func aCommitShowsOnlyItsOwnChanges() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let sha = try BackendFixture.git(fixture.repo, "rev-parse", "a").trimmingCharacters(in: .whitespacesAndNewlines)

        let files = try await fixture.service.commitFiles(stackID: try fixture.stackID(), sha: sha)

        #expect(files.map(\.path) == ["a.txt"])
        #expect(files.first?.additions == 2)
        #expect(files.first?.deletions == 0)
    }

    @Test func aRootCommitShowsEveryFileAsAdded() async throws {
        let fixture = try BackendFixture()
        try await fixture.review()
        let sha = try BackendFixture.git(fixture.repo, "rev-parse", "main").trimmingCharacters(in: .whitespacesAndNewlines)

        let files = try await fixture.service.commitFiles(stackID: try fixture.stackID(), sha: sha)

        #expect(files.map(\.path) == ["a.txt"])
        #expect(files.first?.change == .added)
        #expect(files.first?.additions == 20)
    }
}
