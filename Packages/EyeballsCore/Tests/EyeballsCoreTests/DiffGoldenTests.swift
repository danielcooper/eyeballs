@testable import EyeballsCore
import Foundation
import Testing

/// Diffs of a fixture repository that holds one of every kind of change, checked against a
/// summary written out by hand.
struct DiffGoldenTests {
    @Test func everyKindOfChangeBetweenTwoCommits() async throws {
        let fixture = try GitFixture()
        let (base, head) = try makeEveryKindOfChange(in: fixture)
        let repository = try await fixture.repository()

        let files = try await repository.changedFiles(from: base, to: head)
        let summary = files.map(Self.summary).joined(separator: "\n")
        #expect(summary == Self.expectedSummary, "Actual summary:\n\(summary)")
    }

    @Test func countsMatchNumstat() async throws {
        let fixture = try GitFixture()
        let (base, head) = try makeEveryKindOfChange(in: fixture)
        let repository = try await fixture.repository()

        let files = try await repository.changedFiles(from: base, to: head)
        let numstat = try await repository.numstat(from: base, to: head)
        #expect(numstat.count == files.count)
        for (file, counts) in zip(files, numstat) {
            #expect(counts.path == file.path)
            if file.isBinary {
                #expect(counts.additions == nil)
            } else {
                #expect(counts.additions == file.additions, "\(file.path)")
                #expect(counts.deletions == file.deletions, "\(file.path)")
            }
        }
    }

    @Test func readsCopiesWhenAskedToFindThem() async throws {
        let fixture = try GitFixture()
        let original = (1...12).map { "line \($0)\n" }.joined()
        try fixture.write("original.txt", original)
        let base = try fixture.commit("base")
        try fixture.write("copy.txt", original.replacingOccurrences(of: "line 12", with: "line twelve"))
        let head = try fixture.commit("copy")
        let repository = try await fixture.repository()

        let patch = try await repository.git.run(["diff"] + GitRepository.patchOptions + ["-C", "--find-copies-harder", base.hex, head.hex])
        let files = try UnifiedDiffParser.parse(patch.output)
        #expect(files.map(\.change) == [.copied])
        #expect(files.first?.oldPath == "original.txt")
        #expect(files.first?.newPath == "copy.txt")
        #expect(files.first?.additions == 1)

        let raw = try await repository.git.run(["diff", "--raw", "-z", "--no-abbrev", "-C", "--find-copies-harder", base.hex, head.hex])
        let entries = try RawDiffParser.parse(raw.output)
        #expect(entries.map(\.change) == [.copied])
        #expect(entries.first?.oldPath == "original.txt")
    }

    @Test func readsBothSidesOfAFileForContextExpansion() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", "one\ntwo\nthree\n")
        let base = try fixture.commit("base")
        try fixture.write("a.txt", "one\n2\nthree\nfour")
        let head = try fixture.commit("head")
        let repository = try await fixture.repository()

        let file = try #require(try await repository.changedFiles(from: base, to: head).first)
        let (old, new) = try await repository.fileTexts(for: file)
        #expect(old?.strings == ["one", "two", "three"])
        #expect(new?.strings == ["one", "2", "three", "four"])
        #expect(new?.endsWithNewline == false)
    }

    @Test func diffsTwoBlobsWithoutContext() async throws {
        let fixture = try GitFixture()
        let old = try fixture.blob(Data("a\nb\nc\nd\n".utf8))
        let new = try fixture.blob(Data("a\nx\ny\nb\nc\n".utf8))
        let repository = try await fixture.repository()

        let diff = try await repository.diffBlobs(old, new)
        #expect(diff.hunks.map { [$0.oldStart, $0.oldCount, $0.newStart, $0.newCount] } == [[1, 0, 2, 2], [4, 1, 5, 0]])
        #expect(try await repository.diffBlobs(old, old).hunks.isEmpty)
    }

    // MARK: Fixture

    /// Builds the two commits with plumbing, so it can hold paths and modes macOS cannot write to disk.
    private func makeEveryKindOfChange(in fixture: GitFixture) throws -> (base: ObjectID, head: ObjectID) {
        let nonUTF8 = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
        let submoduleBefore = try #require(ObjectID(String(repeating: "1", count: 40)))
        let submoduleAfter = try #require(ObjectID(String(repeating: "2", count: 40)))
        let movedBefore = (1...10).map { "moved line \($0)\n" }.joined()
        let movedAfter = movedBefore.replacingOccurrences(of: "moved line 10", with: "moved line ten")

        let base = try fixture.commitTree([
            ("100644", try fixture.blob("a\nb\nc\n"), Array("f.txt".utf8)),
            ("100644", try fixture.blob("x\n"), Array("target".utf8)),
            ("100644", try fixture.blob("hello\n"), Array("sp ace.txt".utf8)),
            ("100644", try fixture.blob(movedBefore), Array("moved.txt".utf8)),
            ("100644", try fixture.blob("one\r\ntwo\r\n"), Array("crlf.txt".utf8)),
            ("100644", try fixture.blob(Data([0, 1, 0x62, 0x69, 0x6E])), Array("b.bin".utf8)),
            ("100644", try fixture.blob("mode\n"), Array("m.sh".utf8)),
            ("100644", try fixture.blob("q\n"), nonUTF8),
            ("100644", try fixture.blob("tab\n"), Array("ta\tb.txt".utf8)),
            ("160000", submoduleBefore, Array("sub".utf8)),
            ("120000", try fixture.blob("f.txt"), Array("link".utf8)),
            ("100644", try fixture.blob("bye\n"), Array("gone.txt".utf8)),
        ], parent: nil, message: "base")

        let head = try fixture.commitTree([
            ("100644", try fixture.blob("a\nB\nc\nd"), Array("f.txt".utf8)),
            ("120000", try fixture.blob("f.txt"), Array("target".utf8)),
            ("100644", try fixture.blob("hello\n"), Array("sp ace2.txt".utf8)),
            ("100644", try fixture.blob(movedAfter), Array("moved2.txt".utf8)),
            ("100644", try fixture.blob("one\r\nTWO\r\n"), Array("crlf.txt".utf8)),
            ("100644", try fixture.blob(Data([0, 2, 0x62, 0x69, 0x6E])), Array("b.bin".utf8)),
            ("100755", try fixture.blob("mode\n"), Array("m.sh".utf8)),
            ("100644", try fixture.blob("q2\n"), nonUTF8),
            ("100644", try fixture.blob("new\n"), Array("quote\"d.txt".utf8)),
            ("160000", submoduleAfter, Array("sub".utf8)),
            ("120000", try fixture.blob("m.sh"), Array("link".utf8)),
            ("100644", try fixture.blob(""), Array("empty.txt".utf8)),
        ], parent: base, message: "head")
        return (base, head)
    }

    // MARK: Summary

    /// One block per file: the change, paths, modes, counts, then each hunk's header and lines.
    static func summary(_ file: DiffFile) -> String {
        var header = file.change.letter + (file.similarity.map(String.init) ?? "")
        header += " " + (file.oldPath.map(escaped) ?? "-") + " -> " + (file.newPath.map(escaped) ?? "-")
        header += " " + (file.oldMode?.description ?? "-") + "->" + (file.newMode?.description ?? "-")
        header += " blobs " + (file.oldBlob?.short ?? "-") + ".." + (file.newBlob?.short ?? "-")
        header += file.isBinary ? " binary" : " +\(file.additions) -\(file.deletions)"
        var lines = [header]
        for hunk in file.hunks {
            lines.append("  " + hunk.header)
            for line in hunk.lines {
                let marker = switch line.kind {
                case .context: " "
                case .added: "+"
                case .deleted: "-"
                }
                let numbers = "\(line.oldNumber.map(String.init) ?? "_"),\(line.newNumber.map(String.init) ?? "_")"
                lines.append("    \(numbers) \(marker)\(escaped(GitPath(bytes: line.content)))\(line.hasNoNewline ? " [no newline]" : "")")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func escaped(_ path: GitPath) -> String {
        path.bytes.map { byte in
            (0x20..<0x7F).contains(byte) && byte != 0x5C ? String(UnicodeScalar(byte)) : String(format: "\\x%02X", byte)
        }.joined()
    }

    static let expectedSummary = #"""
        M b.bin -> b.bin 100644->100644 blobs 88768ef..3e3315e binary
        M caf\xE9.txt -> caf\xE9.txt 100644->100644 blobs bca70f3..d169a2f +1 -1
          @@ -1 +1 @@
            1,_ -q
            _,1 +q2
        M crlf.txt -> crlf.txt 100644->100644 blobs 4e349b5..24fe5dc +1 -1
          @@ -1,2 +1,2 @@
            1,1  one\x0D
            2,_ -two\x0D
            _,2 +TWO\x0D
        A - -> empty.txt -->100644 blobs -..e69de29 +0 -0
        M f.txt -> f.txt 100644->100644 blobs de98044..f8f7a32 +2 -1
          @@ -1,3 +1,4 @@
            1,1  a
            2,_ -b
            _,2 +B
            3,3  c
            _,4 +d [no newline]
        D gone.txt -> - 100644->- blobs b023018..- +0 -1
          @@ -1 +0,0 @@
            1,_ -bye
        M link -> link 120000->120000 blobs 7f66e4f..01956d1 +1 -1
          @@ -1 +1 @@
            1,_ -f.txt [no newline]
            _,1 +m.sh [no newline]
        M m.sh -> m.sh 100644->100755 blobs 17ab372..17ab372 +0 -0
        R88 moved.txt -> moved2.txt 100644->100644 blobs e319fa5..cdf9e09 +1 -1
          @@ -7,4 +7,4 @@ moved line 6
            7,7  moved line 7
            8,8  moved line 8
            9,9  moved line 9
            10,_ -moved line 10
            _,10 +moved line ten
        A - -> quote"d.txt -->100644 blobs -..3e75765 +1 -0
          @@ -0,0 +1 @@
            _,1 +new
        R100 sp ace.txt -> sp ace2.txt 100644->100644 blobs ce01362..ce01362 +0 -0
        M sub -> sub 160000->160000 blobs 1111111..2222222 +1 -1
          @@ -1 +1 @@
            1,_ -Subproject commit 1111111111111111111111111111111111111111
            _,1 +Subproject commit 2222222222222222222222222222222222222222
        D ta\x09b.txt -> - 100644->- blobs 8cc35a3..- +0 -1
          @@ -1 +0,0 @@
            1,_ -tab
        T target -> target 100644->120000 blobs 587be6b..7f66e4f +1 -1
          @@ -1 +0,0 @@
            1,_ -x
          @@ -0,0 +1 @@
            _,1 +f.txt [no newline]
        """#
}
