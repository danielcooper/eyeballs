import EyeballsCore
import Foundation
import Testing

/// The simple porter as a pure function, with hunks written out by hand.
struct PorterTests {
    static let oldBlob = ObjectID(String(repeating: "a", count: 40))!
    static let newBlob = ObjectID(String(repeating: "b", count: 40))!
    static let oldFile = (1...10).map { "line \($0)" }

    @Test func staysPutWhenTheBlobIsTheSame() {
        let result = port(lines: 4...6, to: Self.oldFile, blob: Self.oldBlob, hunks: [])
        #expect(result.placement == .current(4...6))
        #expect(result.method == .sameBlob)
        #expect(result.isVerified)
    }

    @Test func movesDownPastLinesInsertedAbove() {
        let newFile = ["new a", "new b"] + Self.oldFile
        let result = port(lines: 4...6, to: newFile, hunks: [hunk(0, 0, 1, 2)])
        #expect(result.placement == .moved(6...8))
        #expect(result.method == .diffShift)
        #expect(result.state == "moved")
    }

    @Test func movesUpPastLinesDeletedAbove() {
        let newFile = Array(Self.oldFile.dropFirst(2))
        let result = port(lines: 4...6, to: newFile, hunks: [hunk(1, 2, 0, 0)])
        #expect(result.placement == .moved(2...4))
    }

    @Test func staysPutWhenLinesChangeBelow() {
        var newFile = Self.oldFile
        newFile[8] = "changed 9"
        newFile.insert("inserted after 6", at: 6)
        let result = port(lines: 4...6, to: newFile, hunks: [hunk(6, 0, 7, 1), hunk(9, 1, 10, 1)])
        #expect(result.placement == .current(4...6))
    }

    @Test func goesOutdatedWhenACoveredLineIsEdited() {
        var newFile = Self.oldFile
        newFile[4] = "edited 5"
        let result = port(lines: 4...6, to: newFile, hunks: [hunk(5, 1, 5, 1)])
        #expect(result.placement == .outdated(nearLine: 7))
        #expect(result.method == .fallback)
        #expect(!result.isVerified)
    }

    @Test func goesOutdatedWithANearLineWhenTheCoveredLinesAreDeleted() {
        let newFile = Array(Self.oldFile[0..<3] + Self.oldFile[6...])
        let result = port(lines: 4...6, to: newFile, hunks: [hunk(4, 3, 3, 0)])
        #expect(result.placement == .outdated(nearLine: 4))
        #expect(newFile[3] == "line 7")
    }

    @Test func usesTheLineBeforeWhenNothingSurvivesAfter() {
        let newFile = Array(Self.oldFile[0..<7])
        let result = port(lines: 8...10, to: newFile, hunks: [hunk(8, 3, 7, 0)])
        #expect(result.placement == .outdated(nearLine: 7))
    }

    @Test func goesOutdatedWhenLinesAreInsertedInsideTheRange() {
        var newFile = Self.oldFile
        newFile.insert("wedged in", at: 4)
        let result = port(lines: 4...6, to: newFile, hunks: [hunk(4, 0, 5, 1)])
        #expect(result.placement == .outdated(nearLine: 8))
    }

    @Test func treatsInsertionsAtTheEdgesOfTheRangeAsOutside() {
        #expect(SimplePorter.shift(4...6, through: [hunk(3, 0, 4, 2)]) == 6...8)
        #expect(SimplePorter.shift(4...6, through: [hunk(6, 0, 7, 2)]) == 4...6)
        #expect(SimplePorter.shift(4...6, through: [hunk(5, 0, 6, 1)]) == nil)
        #expect(SimplePorter.shift(4...4, through: [hunk(4, 0, 5, 1)]) == 4...4)
        #expect(SimplePorter.shift(4...6, through: [hunk(1, 1, 1, 3), hunk(3, 0, 6, 1)]) == 7...9)
    }

    @Test func checksEveryResultAgainstTheNewText() {
        let wrongHunks = [hunk(0, 0, 1, 2)]
        let result = port(lines: 4...6, to: Self.oldFile, hunks: wrongHunks)
        #expect(result.placement == .outdated(nearLine: 9))

        let sameBlobButWrongText = SimplePorter.port(
            anchor(lines: 4...6, covered: ["not", "these", "lines"]),
            to: PortTarget(path: "f.txt", blob: Self.oldBlob, text: text(Self.oldFile))
        )
        #expect(sameBlobButWrongText.placement == .outdated(nearLine: nil))
    }

    @Test func goesOutdatedWhenTheRangeRunsPastTheNewFile() {
        let result = port(lines: 9...10, to: Array(Self.oldFile.prefix(8)), hunks: [])
        #expect(result.lines == nil)
    }

    @Test func goesOutdatedForABinaryTarget() {
        let target = PortTarget(path: "f.txt", blob: Self.newBlob, text: text(Self.oldFile), hunks: [], isBinary: true)
        #expect(SimplePorter.port(anchor(lines: 4...6), to: target).placement == .outdated(nearLine: nil))
    }

    @Test func isGoneWhenTheFileWasDeleted() {
        let result = SimplePorter.port(anchor(lines: 4...6), to: PortTarget(path: nil, blob: nil, text: nil))
        #expect(result.placement == .gone)
        #expect(result.state == "gone")
    }

    // MARK: Helpers

    private func port(lines: ClosedRange<Int>, to newFile: [String], blob: ObjectID = PorterTests.newBlob, hunks: [DiffHunk]) -> PortResult {
        SimplePorter.port(anchor(lines: lines), to: PortTarget(path: "f.txt", blob: blob, text: text(newFile), hunks: hunks))
    }

    private func anchor(lines: ClosedRange<Int>, covered: [String]? = nil) -> PortAnchor {
        let coveredText = covered ?? Array(Self.oldFile[(lines.lowerBound - 1)...(lines.upperBound - 1)])
        return PortAnchor(path: "f.txt", side: .head, start: lines.lowerBound, end: lines.upperBound, blob: Self.oldBlob, coveredLines: coveredText.map { Array($0.utf8) })
    }

    private func text(_ lines: [String]) -> FileText {
        FileText(Data(lines.map { $0 + "\n" }.joined().utf8))
    }

    /// A `-U0` hunk, written as git prints its header: `hunk(4, 3, 3, 0)` is `@@ -4,3 +3,0 @@`.
    private func hunk(_ oldStart: Int, _ oldCount: Int, _ newStart: Int, _ newCount: Int) -> DiffHunk {
        DiffHunk(header: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@", oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
    }
}

/// The porter end to end, on real commits.
struct PorterRepositoryTests {
    static let original = (1...12).map { "line \($0)\n" }.joined()

    @Test func insertionAboveGivesMoved() async throws {
        let (fixture, before) = try commitOriginal()
        try fixture.write("f.txt", "inserted 1\ninserted 2\ninserted 3\n" + Self.original)
        let after = try fixture.commit("insert above")

        let result = try await port(lines: 5...7, in: fixture, from: before, to: after)
        #expect(result.placement == .moved(8...10))
        #expect(result.method == .diffShift)
        #expect(result.path == "f.txt")
    }

    @Test func editInsideGivesOutdated() async throws {
        let (fixture, before) = try commitOriginal()
        try fixture.write("f.txt", Self.original.replacingOccurrences(of: "line 6\n", with: "line six\n"))
        let after = try fixture.commit("edit inside")

        let result = try await port(lines: 5...7, in: fixture, from: before, to: after)
        #expect(result.placement == .outdated(nearLine: 8))
    }

    @Test func deletionGivesOutdatedNearTheNextLine() async throws {
        let (fixture, before) = try commitOriginal()
        try fixture.write("f.txt", Self.original.replacingOccurrences(of: "line 5\nline 6\nline 7\n", with: ""))
        let after = try fixture.commit("delete")

        let result = try await port(lines: 5...7, in: fixture, from: before, to: after)
        #expect(result.placement == .outdated(nearLine: 5))
    }

    @Test func renameFollowsThePath() async throws {
        let (fixture, before) = try commitOriginal()
        try fixture.git(["mv", "f.txt", "renamed.txt"])
        let after = try fixture.commit("rename")

        let result = try await port(lines: 5...7, in: fixture, from: before, to: after)
        #expect(result.placement == .current(5...7))
        #expect(result.path == "renamed.txt")
        #expect(result.method == .sameBlob)
    }

    @Test func renameWithAnEditAboveFollowsThePathAndMoves() async throws {
        let (fixture, before) = try commitOriginal()
        try fixture.remove("f.txt")
        try fixture.write("renamed.txt", "new first line\n" + Self.original)
        let after = try fixture.commit("rename and edit")

        let result = try await port(lines: 5...7, in: fixture, from: before, to: after)
        #expect(result.placement == .moved(6...8))
        #expect(result.path == "renamed.txt")
    }

    @Test func unchangedBlobStaysCurrent() async throws {
        let (fixture, before) = try commitOriginal()
        try fixture.write("other.txt", "unrelated\n")
        let after = try fixture.commit("touch another file")

        let result = try await port(lines: 5...7, in: fixture, from: before, to: after)
        #expect(result.placement == .current(5...7))
        #expect(result.method == .sameBlob)
    }

    @Test func deletedFileIsGone() async throws {
        let (fixture, before) = try commitOriginal()
        try fixture.remove("f.txt")
        let after = try fixture.commit("delete the file")

        let result = try await port(lines: 5...7, in: fixture, from: before, to: after)
        #expect(result.placement == .gone)
    }

    @Test func portsABaseSideAnchorBetweenBaseCommits() async throws {
        let (fixture, oldBase) = try commitOriginal()
        try fixture.write("f.txt", "parent changed this\n" + Self.original)
        let newBase = try fixture.commit("parent moved")

        let result = try await port(lines: 2...3, side: .base, in: fixture, from: oldBase, to: newBase)
        #expect(result.placement == .moved(3...4))
    }

    private func commitOriginal() throws -> (GitFixture, ObjectID) {
        let fixture = try GitFixture()
        try fixture.write("f.txt", Self.original)
        return (fixture, try fixture.commit("original"))
    }

    private func port(lines: ClosedRange<Int>, side: DiffSide = .head, in fixture: GitFixture, from before: ObjectID, to after: ObjectID) async throws -> PortResult {
        let repository = try await fixture.repository()
        let blob = try #require(try await repository.blobID(in: before, at: "f.txt"))
        let covered = try #require(try await repository.fileText(blob).lines(in: lines))
        let anchor = PortAnchor(path: "f.txt", side: side, start: lines.lowerBound, end: lines.upperBound, blob: blob, coveredLines: covered)
        return try await repository.port(anchor, from: before, to: after)
    }
}

/// Random edit scripts: a thread whose lines no hunk touches must land exactly where the diff
/// moved them, and any other thread must come back outdated. Nothing may crash or land outside the file.
struct PorterPropertyTests {
    @Test func portsMatchWhatTheDiffSays() {
        var random = SeededRandom(seed: 2026)
        for _ in 0..<3_000 {
            let old = (0..<Int.random(in: 1...30, using: &random)).map { _ in "l\(Int.random(in: 0..<8, using: &random))" }
            var new = old
            for _ in 0..<Int.random(in: 0...4, using: &random) {
                edit(&new, using: &random)
            }
            let start = Int.random(in: 1...old.count, using: &random)
            let end = Int.random(in: start...min(old.count, start + 3), using: &random)
            let diff = Hunks(from: old, to: new)
            let anchor = PortAnchor(
                path: "f", side: .head, start: start, end: end, blob: PorterTests.oldBlob,
                coveredLines: old[(start - 1)...(end - 1)].map { Array($0.utf8) }
            )
            let target = PortTarget(path: "f", blob: PorterTests.newBlob, text: FileText(Data(new.map { $0 + "\n" }.joined().utf8)), hunks: diff.hunks)

            let result = SimplePorter.port(anchor, to: target)

            if let expected = diff.untouchedRange(start...end) {
                #expect(result.lines == expected, "old \(old) new \(new) range \(start)...\(end)")
            } else {
                #expect(result.lines == nil, "old \(old) new \(new) range \(start)...\(end)")
            }
            if let lines = result.lines {
                #expect(lines.upperBound <= new.count)
                #expect(Array(new[(lines.lowerBound - 1)...(lines.upperBound - 1)]) == Array(old[(start - 1)...(end - 1)]))
            }
            if let near = result.nearLine {
                #expect((1...max(1, new.count)).contains(near))
            }
        }
    }

    private func edit(_ lines: inout [String], using random: inout SeededRandom) {
        let index = Int.random(in: 0...lines.count, using: &random)
        switch Int.random(in: 0..<3, using: &random) {
        case 0:
            lines.insert(contentsOf: (0..<Int.random(in: 1...3, using: &random)).map { _ in "n\(Int.random(in: 0..<4, using: &random))" }, at: index)
        case 1 where index < lines.count:
            lines.removeSubrange(index..<min(lines.count, index + Int.random(in: 1...3, using: &random)))
        default:
            if index < lines.count { lines[index] = "c\(Int.random(in: 0..<4, using: &random))" }
        }
    }
}

/// `-U0` hunks worked out from Swift's own diff, as a second opinion that needs no git.
private struct Hunks {
    var hunks: [DiffHunk] = []
    /// Old line to new line, for every line the diff keeps.
    private var kept: [Int: Int] = [:]
    /// Old lines after which the diff inserts new lines.
    private var insertionsAfter: Set<Int> = []

    init(from old: [String], to new: [String]) {
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, newIndex < new.count, !removed.contains(oldIndex), !inserted.contains(newIndex) {
                kept[oldIndex + 1] = newIndex + 1
                oldIndex += 1
                newIndex += 1
                continue
            }
            let oldStart = oldIndex
            let newStart = newIndex
            while (oldIndex < old.count && removed.contains(oldIndex)) || (newIndex < new.count && inserted.contains(newIndex)) {
                if oldIndex < old.count && removed.contains(oldIndex) { oldIndex += 1 } else { newIndex += 1 }
            }
            let oldCount = oldIndex - oldStart
            let newCount = newIndex - newStart
            if oldCount == 0 { insertionsAfter.insert(oldStart) }
            hunks.append(DiffHunk(
                header: "", oldStart: oldCount == 0 ? oldStart : oldStart + 1, oldCount: oldCount,
                newStart: newCount == 0 ? newStart : newStart + 1, newCount: newCount
            ))
        }
    }

    /// Where the diff puts a range whose lines it keeps, with nothing inserted between them.
    func untouchedRange(_ range: ClosedRange<Int>) -> ClosedRange<Int>? {
        guard range.allSatisfy({ kept[$0] != nil }) else { return nil }
        guard !insertionsAfter.contains(where: { range.lowerBound <= $0 && $0 < range.upperBound }) else { return nil }
        guard let start = kept[range.lowerBound], let end = kept[range.upperBound] else { return nil }
        return start...end
    }
}
