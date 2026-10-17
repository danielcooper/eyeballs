import EyeballsCore
import Foundation
import Testing

/// Feeds the parsers random and damaged input. Each one must return or throw, never crash or hang.
struct DiffFuzzTests {
    @Test func randomBytesNeverCrashTheParsers() {
        var random = SeededRandom(seed: 24495)
        for _ in 0..<3_000 {
            let bytes = (0..<Int.random(in: 0...600, using: &random)).map { _ in UInt8.random(in: 0...255, using: &random) }
            exercise(bytes)
        }
    }

    @Test func randomPatchShapedLinesNeverCrashTheParser() {
        var random = SeededRandom(seed: 9)
        let pieces = [
            "diff --git a/f b/f", "diff --git \"a/x\\", "--- a/f", "+++ b/f", "--- /dev/null", "+++ \"b/\\303",
            "@@ -1 +1 @@", "@@ -0,0 +1,3 @@", "@@ -5,2 +3,0 @@ section", "@@ -999999999,999999999 +1 @@", "@@ -1,",
            " context", "-deleted", "+added", "", "\\ No newline at end of file", "Binary files a/f and b/f differ",
            "GIT binary patch", "index 0000000..1111111 100644", "old mode 100644", "new mode 120000",
            "rename from \"q", "rename to b", "copy from a", "copy to b", "similarity index 99999999999%",
            "deleted file mode 160000", "new file mode 1007777777", "diff --cc f", "\u{0}\u{1}",
        ]
        for _ in 0..<3_000 {
            let lines = (0..<Int.random(in: 0...40, using: &random)).map { _ in pieces.randomElement(using: &random)! }
            exercise(Array(lines.joined(separator: "\n").utf8))
        }
    }

    @Test func damagedRealPatchesNeverCrashTheParser() async throws {
        let fixture = try GitFixture()
        try fixture.write("a.txt", (1...40).map { "line \($0)\n" }.joined())
        try fixture.write("b file.txt", "one\r\ntwo\r\n")
        let base = try fixture.commit("base")
        try fixture.write("a.txt", (1...40).map { $0 % 7 == 0 ? "changed \($0)\n" : "line \($0)\n" }.joined())
        try fixture.remove("b file.txt")
        try fixture.write("c.txt", "new\n")
        let head = try fixture.commit("head")
        let patch = Array(try fixture.gitData(["diff", "--full-index", "-M", base.hex, head.hex]))
        let raw = Array(try fixture.gitData(["diff", "--raw", "-z", "--no-abbrev", base.hex, head.hex]))
        let numstat = Array(try fixture.gitData(["diff", "--numstat", "-z", base.hex, head.hex]))
        #expect(try UnifiedDiffParser.parse(patch).count == 3)

        var random = SeededRandom(seed: 7)
        for _ in 0..<2_000 {
            for original in [patch, raw, numstat] {
                exercise(damaged(original, using: &random))
            }
        }
    }

    private func exercise(_ bytes: [UInt8]) {
        _ = try? UnifiedDiffParser.parse(bytes)
        _ = try? RawDiffParser.parse(Data(bytes))
        _ = try? NumstatParser.parse(Data(bytes))
        _ = FileText(Data(bytes))
    }

    /// Flips, drops, repeats or cuts a few bytes.
    private func damaged(_ original: [UInt8], using random: inout SeededRandom) -> [UInt8] {
        var bytes = original
        for _ in 0..<Int.random(in: 1...4, using: &random) where !bytes.isEmpty {
            let index = Int.random(in: 0..<bytes.count, using: &random)
            switch Int.random(in: 0..<4, using: &random) {
            case 0: bytes[index] = UInt8.random(in: 0...255, using: &random)
            case 1: bytes.remove(at: index)
            case 2: bytes.insert(contentsOf: bytes[index..<min(bytes.count, index + 20)], at: index)
            default: bytes.removeSubrange(index...)
            }
        }
        return bytes
    }
}

/// SplitMix64, so a failing run can be repeated exactly.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
