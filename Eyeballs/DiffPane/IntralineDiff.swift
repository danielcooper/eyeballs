import Foundation

/// Finds the changed part of a deleted line and the added line that replaced it.
///
/// It keeps the common prefix and suffix plain and returns the middle of each line, in UTF-16
/// offsets. Shared indentation does not count as shared text, and lines that share too little
/// return nil, because highlighting nearly all of a line says nothing its colour does not.
enum IntralineDiff {
    static func changedRanges(deleted: String, added: String) -> (deleted: NSRange, added: NSRange)? {
        match(Array(deleted.utf16), Array(added.utf16)).map { ($0.deleted, $0.added) }
    }

    /// Pairs each run of deleted lines with the run of added lines right after it, matching the
    /// most similar lines in order rather than simply the first with the first.
    ///
    /// Returns the changed range for each paired line, keyed by its index in `lines`.
    static func changedRanges(in lines: [(kind: LineKind, text: String)]) -> [Int: NSRange] {
        var result: [Int: NSRange] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deleted else {
                index += 1
                continue
            }
            let deletedStart = index
            while index < lines.count, lines[index].kind == .deleted { index += 1 }
            let addedStart = index
            while index < lines.count, lines[index].kind == .added { index += 1 }
            let deleted = (deletedStart..<addedStart).map { Array(lines[$0].text.utf16) }
            let added = (addedStart..<index).map { Array(lines[$0].text.utf16) }
            for (old, new, ranges) in pairs(deleted, added) {
                result[deletedStart + old] = ranges.deleted
                result[addedStart + new] = ranges.added
            }
        }
        return result
    }

    private struct Match {
        var score: Int
        var deleted: NSRange
        var added: NSRange
    }

    /// The best in-order pairing of two runs of lines, by total shared text.
    private static func pairs(_ deleted: [[UInt16]], _ added: [[UInt16]]) -> [(Int, Int, Match)] {
        guard !deleted.isEmpty, !added.isEmpty else { return [] }
        guard deleted.count * added.count <= 400 else {
            return (0..<min(deleted.count, added.count)).compactMap { offset in
                match(deleted[offset], added[offset]).map { (offset, offset, $0) }
            }
        }
        let matches = deleted.map { old in added.map { new in match(old, new) } }
        var best = Array(repeating: Array(repeating: 0, count: added.count + 1), count: deleted.count + 1)
        for old in 1...deleted.count {
            for new in 1...added.count {
                let paired = matches[old - 1][new - 1].map { best[old - 1][new - 1] + $0.score } ?? 0
                best[old][new] = max(best[old - 1][new], best[old][new - 1], paired)
            }
        }
        var result: [(Int, Int, Match)] = []
        var old = deleted.count
        var new = added.count
        while old > 0, new > 0 {
            if let match = matches[old - 1][new - 1], best[old][new] == best[old - 1][new - 1] + match.score {
                result.append((old - 1, new - 1, match))
                old -= 1
                new -= 1
            } else if best[old][new] == best[old - 1][new] {
                old -= 1
            } else {
                new -= 1
            }
        }
        return result.reversed()
    }

    private static func match(_ old: [UInt16], _ new: [UInt16]) -> Match? {
        guard !old.isEmpty, !new.isEmpty, old != new else { return nil }
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        while prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        while suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }

        let indent = old.prefix(prefix).prefix { $0 == 0x20 || $0 == 0x09 }.count
        let shared = prefix + suffix - indent
        let longest = max(old.count, new.count) - indent
        let shortest = min(old.count, new.count) - indent
        guard shared >= 3, longest > 0, shortest > 0,
              Double(shared) / Double(longest) >= 0.3 || Double(shared) / Double(shortest) >= 0.6 else { return nil }

        let deleted = NSRange(location: prefix, length: old.count - prefix - suffix)
        let added = NSRange(location: prefix, length: new.count - prefix - suffix)
        guard deleted.length > 0 || added.length > 0 else { return nil }
        return Match(score: shared, deleted: deleted, added: added)
    }
}
