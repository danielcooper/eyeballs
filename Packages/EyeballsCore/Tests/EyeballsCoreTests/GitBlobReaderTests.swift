import EyeballsCore
import Foundation
import Testing

struct GitBlobReaderTests {
    @Test func concurrentReadsEachGetTheirOwnBlob() async throws {
        let fixture = try GitFixture()
        var expected: [ObjectID: Data] = [:]
        for number in 0..<100 {
            // Some blobs are larger than a pipe's buffer, so a read spans several chunks.
            let size = number % 10 == 0 ? 300_000 + number : 1 + number * 37
            let contents = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ number) })
            expected[try fixture.blob(contents)] = contents
        }
        let reader = try await fixture.repository().blobs

        let results = try await withThrowingTaskGroup(of: (ObjectID, Data).self) { group in
            for id in expected.keys {
                group.addTask { (id, try await reader.blob(id)) }
            }
            return try await group.reduce(into: [ObjectID: Data]()) { $0[$1.0] = $1.1 }
        }

        #expect(results.count == 100)
        for (id, contents) in expected {
            #expect(results[id] == contents, "Blob \(id.short) came back wrong")
        }
    }

    @Test func readsEmptyBlobsAndBlobsWithoutAFinalNewline() async throws {
        let fixture = try GitFixture()
        let empty = try fixture.blob(Data())
        let unterminated = try fixture.blob(Data("no newline".utf8))
        let reader = try await fixture.repository().blobs
        #expect(try await reader.blob(empty) == Data())
        #expect(try await reader.blob(unterminated) == Data("no newline".utf8))
    }

    @Test func aMissingObjectFailsOnlyThatRead() async throws {
        let fixture = try GitFixture()
        let present = try fixture.blob(Data("here\n".utf8))
        let missing = try #require(ObjectID(String(repeating: "ab", count: 20)))
        let reader = try await fixture.repository().blobs

        await #expect(throws: GitError.missingObject(missing)) { _ = try await reader.blob(missing) }
        #expect(try await reader.blob(present) == Data("here\n".utf8))
    }

    @Test func refusesObjectsThatAreNotBlobs() async throws {
        let fixture = try GitFixture()
        let commit = try fixture.commit("one")
        let present = try fixture.blob(Data("here\n".utf8))
        let reader = try await fixture.repository().blobs

        await #expect(throws: GitError.notABlob(commit)) { _ = try await reader.blob(commit) }
        #expect(try await reader.blob(present) == Data("here\n".utf8))
    }

    @Test func startsAgainAfterClose() async throws {
        let fixture = try GitFixture()
        let blob = try fixture.blob(Data("again\n".utf8))
        let reader = try await fixture.repository().blobs
        #expect(try reader.blobNow(blob) == Data("again\n".utf8))
        reader.close()
        #expect(try await reader.blob(blob) == Data("again\n".utf8))
    }
}
