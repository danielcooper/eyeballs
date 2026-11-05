import Foundation

/// Every match of the find text in the shown layer, in diff order, and the one you are on.
///
/// Find searches the lines of every text file as if each file were open and loaded. A file you
/// folded as viewed, or a big file you have not loaded, still counts, and moving to a match there
/// opens it. Lines inside a folded gap are not part of the diff, so find skips them until you
/// expand the gap.
struct DiffFind {
    /// What a search depends on. The pane searches again only when one of these changes.
    struct Inputs: Equatable {
        var text: String
        var layerID: Int?
        var filesVersion: Int
        var expandedGaps: Set<GapID>
    }

    private(set) var inputs: Inputs?
    private(set) var matches: [FindMatch] = []
    /// The match you are on. Nil until you move to one.
    var current: Int?
    private var matchesByRow: [RowID: [Int]] = [:]
    private var lineOrder: [RowID: Int] = [:]
    private var firstLineOfFile: [String: Int] = [:]

    var currentMatch: FindMatch? { current.map { matches[$0] } }

    /// Finds every case-insensitive match of the text in `lines`, which must be in diff order.
    mutating func search(_ inputs: Inputs, in lines: [CodeRowContent]) {
        self.inputs = inputs
        matches = []
        current = nil
        matchesByRow = [:]
        lineOrder = [:]
        firstLineOfFile = [:]
        guard !inputs.text.isEmpty else { return }
        for (order, line) in lines.enumerated() {
            let row = RowID.line(line.path, line.line.oldNumber, line.line.newNumber)
            lineOrder[row] = order
            if firstLineOfFile[line.path] == nil { firstLineOfFile[line.path] = order }
            let text = line.displayText as NSString
            var searchFrom = 0
            while searchFrom < text.length {
                let found = text.range(of: inputs.text, options: .caseInsensitive,
                                       range: NSRange(location: searchFrom, length: text.length - searchFrom))
                guard found.location != NSNotFound, found.length > 0 else { break }
                matchesByRow[row, default: []].append(matches.count)
                matches.append(FindMatch(row: row, line: order, range: found))
                searchFrom = NSMaxRange(found)
            }
        }
    }

    /// The match on these characters of a row, or nil when they hold no match.
    func indexOfMatch(in row: RowID, at range: NSRange) -> Int? {
        matchesByRow[row]?.first { matches[$0].range == range }
    }

    func firstMatch(atOrAfter position: FindPosition) -> Int? {
        matches.firstIndex { $0.position >= position }
    }

    func lastMatch(before position: FindPosition) -> Int? {
        matches.lastIndex { $0.position < position }
    }

    /// Where a code row's line sits in the search, or nil when find did not search it.
    func position(ofLine row: RowID, offset: Int = 0) -> FindPosition? {
        lineOrder[row].map { FindPosition(line: $0, offset: offset) }
    }

    /// Where a file's first searched line sits, or nil for a file with no lines to search.
    func position(ofFile path: String) -> FindPosition? {
        firstLineOfFile[path].map { FindPosition(line: $0, offset: 0) }
    }

    /// The matches on one code row, for the row to draw.
    func highlights(in row: RowID) -> [FindHighlight] {
        (matchesByRow[row] ?? []).map { FindHighlight(range: matches[$0].range, isCurrent: $0 == current) }
    }

    var status: FindStatus { FindStatus(count: matches.count, current: current) }
}

/// One place the find text occurs: a code row, and the characters of its display text.
struct FindMatch: Equatable {
    var row: RowID
    /// The row's line in diff order, counting every searched line.
    var line: Int
    var range: NSRange

    var position: FindPosition { FindPosition(line: line, offset: range.location) }
}

/// A place in the searched lines: a line in diff order, and a character in it.
struct FindPosition: Comparable {
    static let end = FindPosition(line: .max, offset: 0)

    var line: Int
    var offset: Int

    static func < (lhs: FindPosition, rhs: FindPosition) -> Bool {
        (lhs.line, lhs.offset) < (rhs.line, rhs.offset)
    }
}

struct FindHighlight: Equatable {
    var range: NSRange
    var isCurrent: Bool
}

/// What the find bar says: how many matches there are, and which one you are on.
struct FindStatus: Equatable {
    var count = 0
    var current: Int?
}
