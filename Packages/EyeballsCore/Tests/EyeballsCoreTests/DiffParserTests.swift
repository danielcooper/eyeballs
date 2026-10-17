@testable import EyeballsCore
import Foundation
import Testing

struct DiffParserTests {
    @Test func numbersEveryLineOnBothSides() throws {
        let file = try onlyFile("""
        diff --git a/f.txt b/f.txt
        index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -10,4 +10,5 @@ func get()
         keep
        -old
        +new one
        +new two
         keep too
         last

        """)
        #expect(file.change == .modified)
        #expect(file.oldPath == "f.txt")
        #expect(file.newPath == "f.txt")
        #expect(file.oldBlob == ObjectID(String(repeating: "1", count: 40)))
        #expect(file.newBlob == ObjectID(String(repeating: "2", count: 40)))
        #expect(file.oldMode == .regular)
        #expect(file.newMode == .regular)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -10,4 +10,5 @@ func get()")
        #expect(hunk.section == "func get()")
        #expect((hunk.oldStart, hunk.oldCount, hunk.newStart, hunk.newCount) == (10, 4, 10, 5))
        #expect(hunk.lines.map(\.kind) == [.context, .deleted, .added, .added, .context, .context])
        #expect(hunk.lines.map(\.oldNumber) == [10, 11, nil, nil, 12, 13])
        #expect(hunk.lines.map(\.newNumber) == [10, nil, 11, 12, 13, 14])
        #expect(hunk.lines.map(\.text) == ["keep", "old", "new one", "new two", "keep too", "last"])
        #expect(file.additions == 2)
        #expect(file.deletions == 1)
    }

    @Test func readsHunkHeadersWithoutCountsAndWithZeroCounts() throws {
        let files = try UnifiedDiffParser.parse(Data("""
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -1 +1 @@
        -x
        +y
        @@ -3,0 +4,2 @@
        +inserted
        +inserted
        @@ -7,2 +8,0 @@
        -gone
        -gone

        """.utf8))
        let hunks = try #require(files.first?.hunks)
        #expect(hunks.map { [$0.oldStart, $0.oldCount, $0.newStart, $0.newCount] } == [[1, 1, 1, 1], [3, 0, 4, 2], [7, 2, 8, 0]])
        #expect(hunks[1].lines.map(\.newNumber) == [4, 5])
        #expect(hunks[2].lines.map(\.oldNumber) == [7, 8])
    }

    @Test func marksLinesThatHaveNoNewline() throws {
        let file = try onlyFile("""
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
         a
        -b
        \\ No newline at end of file
        +b
        \\ No newline at end of file

        """)
        let lines = try #require(file.hunks.first?.lines)
        #expect(lines.map(\.hasNoNewline) == [false, true, true])
    }

    @Test func readsAnEmptyLineAsEmptyContext() throws {
        let file = try onlyFile("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n")
        let lines = try #require(file.hunks.first?.lines)
        #expect(lines.map(\.kind) == [.context, .context, .deleted, .added])
        #expect(lines[1].content.isEmpty)
    }

    @Test func keepsCarriageReturnsInTheBytesButNotTheText() throws {
        let file = try onlyFile("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-one\r\n+two\r\n")
        let added = try #require(file.hunks.first?.lines.last)
        #expect(added.content == Array("two\r".utf8))
        #expect(added.text == "two")
        #expect(added.hasCarriageReturn)
    }

    @Test func keepsBytesThatAreNotUTF8() throws {
        var patch = Array("diff --git a/caf".utf8) + [0xE9] + Array(" b/caf".utf8) + [0xE9] + [0x0A]
        patch += Array("--- a/caf".utf8) + [0xE9] + Array("\n+++ b/caf".utf8) + [0xE9] + Array("\n@@ -1 +1 @@\n-".utf8)
        patch += [0xFF, 0xFE] + Array("\n+ok\n".utf8)
        let file = try #require(try UnifiedDiffParser.parse(patch).first)
        #expect(file.path.bytes == Array("caf".utf8) + [0xE9])
        #expect(file.path.exactString == nil)
        #expect(file.hunks.first?.lines.first?.content == [0xFF, 0xFE])
    }

    @Test func readsQuotedPaths() throws {
        let file = try onlyFile(#"""
        diff --git "a/ta\tb \"q\"\\.txt" "b/ta\tb \"q\"\\.txt"
        --- "a/ta\tb \"q\"\\.txt"
        +++ "b/ta\tb \"q\"\\.txt"
        @@ -1 +1 @@
        -a
        +b

        """#)
        #expect(file.path == GitPath("ta\tb \"q\"\\.txt"))
    }

    @Test func readsOctalEscapesAsBytes() throws {
        let file = try onlyFile(#"""
        diff --git "a/caf\303\251.txt" "b/caf\303\251.txt"
        old mode 100644
        new mode 100755

        """#)
        #expect(file.path == GitPath("café.txt"))
        #expect(file.isModeChangeOnly)
        #expect((file.oldMode, file.newMode) == (.regular, .executable))
    }

    @Test func readsAPathWithSpacesFromTheDiffGitLineAndDropsTheTab() throws {
        let modeOnly = try onlyFile("diff --git a/my file.txt b/my file.txt\nold mode 100644\nnew mode 100755\n")
        #expect(modeOnly.path == "my file.txt")

        let edited = try onlyFile("diff --git a/my file.txt b/my file.txt\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-a\n+b\n")
        #expect(edited.path == "my file.txt")
    }

    @Test func readsRenamesCopiesAdditionsAndDeletions() throws {
        let files = try UnifiedDiffParser.parse(Data("""
        diff --git a/old name.txt b/new name.txt
        similarity index 100%
        rename from old name.txt
        rename to new name.txt
        diff --git a/a.txt b/c.txt
        similarity index 90%
        copy from a.txt
        copy to c.txt
        --- a/a.txt
        +++ b/c.txt
        @@ -1 +1 @@
        -a
        +c
        diff --git a/empty b/empty
        new file mode 100644
        index 0000000000000000000000000000000000000000..e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
        diff --git a/gone b/gone
        deleted file mode 100755
        index 3333333333333333333333333333333333333333..0000000000000000000000000000000000000000
        --- a/gone
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye

        """.utf8))
        #expect(files.map(\.change) == [.renamed, .copied, .added, .deleted])
        #expect(files[0].oldPath == "old name.txt" && files[0].newPath == "new name.txt" && files[0].similarity == 100)
        #expect(files[1].oldPath == "a.txt" && files[1].newPath == "c.txt" && files[1].similarity == 90)
        #expect(files[2].oldPath == nil && files[2].newPath == "empty" && files[2].oldBlob == nil && files[2].newMode == .regular)
        #expect(files[3].oldPath == "gone" && files[3].newPath == nil && files[3].newBlob == nil && files[3].oldMode == .executable)
    }

    @Test func readsBinaryFilesBothWays() throws {
        let files = try UnifiedDiffParser.parse(Data("""
        diff --git a/a.png b/a.png
        index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
        Binary files a/a.png and b/a.png differ
        diff --git a/b.png b/b.png
        index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
        GIT binary patch
        literal 5
        McmZQzWMXCm0004i

        literal 5
        McmZQzWMXCm0004i

        diff --git a/c.txt b/c.txt
        --- a/c.txt
        +++ b/c.txt
        @@ -1 +1 @@
        -a
        +b

        """.utf8))
        #expect(files.map(\.isBinary) == [true, true, false])
        #expect(files.map { $0.hunks.count } == [0, 0, 1])
    }

    @Test func treatsALineStartingWithDashesInsideAHunkAsADeletion() throws {
        let files = try UnifiedDiffParser.parse(Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1 @@\n--- not a header\n keep\n".utf8))
        #expect(files.count == 1)
        #expect(files[0].hunks[0].lines.map(\.kind) == [.deleted, .context])
        #expect(files[0].hunks[0].lines[0].text == "-- not a header")
    }

    @Test func skipsTextBeforeTheFirstFile() throws {
        let files = try UnifiedDiffParser.parse(Data("commit 1234\nAuthor: x\n\n    diff --git in a message\n\ndiff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n".utf8))
        #expect(files.count == 1)
        #expect(try UnifiedDiffParser.parse(Data()).isEmpty)
    }

    @Test(arguments: [
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n-b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -x +1 @@\n-a\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n*a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n@@ -1 +1 @@\n-a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n\\ No newline at end of file\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -9999999999 +1 @@\n-a\n+b\n",
        "diff --cc f\nindex 1,2..3\n",
        "diff --git a\n",
    ])
    func refusesBrokenPatches(patch: String) {
        #expect(throws: DiffParseError.self) { try UnifiedDiffParser.parse(Data(patch.utf8)) }
    }

    @Test func splitsFilesIntoLines() {
        #expect(FileText(Data("a\nb\n".utf8)).lines == [Array("a".utf8), Array("b".utf8)])
        #expect(FileText(Data("a\nb".utf8)).lines.count == 2)
        #expect(!FileText(Data("a\nb".utf8)).endsWithNewline)
        #expect(FileText(Data()).lines.isEmpty)
        #expect(FileText(Data("\n".utf8)).lines == [[]])
        #expect(FileText(Data("one\r\ntwo\r\n".utf8)).strings == ["one", "two"])
        #expect(FileText(Data("a\nb\nc\n".utf8)).lines(in: 2...3) == [Array("b".utf8), Array("c".utf8)])
        #expect(FileText(Data("a\n".utf8)).lines(in: 1...2) == nil)
    }

    private func onlyFile(_ patch: String) throws -> DiffFile {
        let files = try UnifiedDiffParser.parse(Data(patch.utf8))
        try #require(files.count == 1)
        return files[0]
    }
}

struct DiffRawParserTests {
    @Test func readsRawRecords() throws {
        let a = String(repeating: "a", count: 40)
        let b = String(repeating: "b", count: 40)
        let zero = String(repeating: "0", count: 40)
        let raw = ":100644 100755 \(a) \(b) M\0m.sh\0:000000 100644 \(zero) \(b) A\0new file\0"
            + ":100644 100644 \(a) \(a) R087\0old\0new\0:100644 120000 \(a) \(b) T\0link\0:160000 000000 \(a) \(zero) D\0sub\0"
        let entries = try RawDiffParser.parse(Data(raw.utf8))
        #expect(entries.map(\.change) == [.modified, .added, .renamed, .typeChanged, .deleted])
        #expect(entries[0].oldMode == .regular && entries[0].newMode == .executable)
        #expect(entries[1].oldPath == nil && entries[1].newPath == "new file" && entries[1].oldBlob == nil && entries[1].oldMode == nil)
        #expect(entries[2].oldPath == "old" && entries[2].newPath == "new" && entries[2].score == 87)
        #expect(entries[3].oldPath == "link" && entries[3].newPath == "link" && entries[3].newMode == .symlink)
        #expect(entries[4].newPath == nil && entries[4].oldMode == .submodule && entries[4].newBlob == nil)
        #expect(try RawDiffParser.parse(Data()).isEmpty)
    }

    @Test(arguments: [
        ":100644 100644 abc def M\0f\0",
        ":100644 100644 \(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40)) R100\0only-one\0",
        ":100644 100644 \(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40)) U\0f\0",
        "f\0",
    ])
    func refusesBrokenRawRecords(raw: String) {
        #expect(throws: DiffParseError.self) { try RawDiffParser.parse(Data(raw.utf8)) }
    }

    @Test func readsNumstatRecords() throws {
        let entries = try NumstatParser.parse(Data("3\t1\tf.txt\0-\t-\tb.bin\0".utf8) + Data("0\t0\t\0old name\0new name\0".utf8))
        #expect(entries == [
            NumstatEntry(additions: 3, deletions: 1, oldPath: nil, path: "f.txt"),
            NumstatEntry(additions: nil, deletions: nil, oldPath: nil, path: "b.bin"),
            NumstatEntry(additions: 0, deletions: 0, oldPath: "old name", path: "new name"),
        ])
    }

    @Test(arguments: ["3\t1\tf.txt", "x\t1\tf\0", "3\t1\t\0only-old\0", "3\0"])
    func refusesBrokenNumstatRecords(numstat: String) {
        #expect(throws: DiffParseError.self) { try NumstatParser.parse(Data(numstat.utf8)) }
    }
}
