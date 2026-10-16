import Foundation

/// One row of the diff table. Each case carries everything its row view draws, so two rows
/// that compare equal look the same.
enum DiffRow: Equatable {
    case overview(OverviewContent)
    case fileHeader(FileHeaderContent)
    case hunkHeader(HunkHeaderContent)
    case gap(GapContent)
    case code(CodeRowContent)
    case notice(NoticeContent)
    case bigFile(BigFileContent)
    case thread(ThreadRowContent)
    case composer(ComposerRowContent)
    case footer

    var id: RowID {
        switch self {
        case .overview: .overview
        case .fileHeader(let header): .fileHeader(header.path)
        case .hunkHeader(let hunk): .hunk(hunk.path, hunk.index)
        case .gap(let gap): .gap(gap.path, gap.index)
        case .code(let code): .line(code.path, code.line.oldNumber, code.line.newNumber)
        case .notice(let notice): .notice(notice.path)
        case .bigFile(let file): .bigFile(file.path)
        case .thread(let thread): .thread(thread.thread.id)
        case .composer(let composer): .composer(composer.key)
        case .footer: .footer
        }
    }

    var isFileHeader: Bool {
        if case .fileHeader = self { true } else { false }
    }

    var code: CodeRowContent? {
        if case .code(let code) = self { code } else { nil }
    }

    var threadID: Int? {
        if case .thread(let thread) = self { thread.thread.id } else { nil }
    }
}

/// A row's identity across rebuilds, so the table can insert and remove rows without reloading.
enum RowID: Hashable {
    case overview
    case fileHeader(String)
    case hunk(String, Int)
    case gap(String, Int)
    case line(String, Int?, Int?)
    case notice(String)
    case bigFile(String)
    case thread(Int)
    case composer(ComposerKey)
    case footer
}

/// Names a composer. Drafts use the model's `DraftKey`; an edit of a sent comment needs its own.
enum ComposerKey: Hashable {
    case draft(DraftKey)
    case edit(commentID: Int)
}

struct OverviewContent: Equatable {
    var layer: LayerItem?
    var layerCount: Int
    var parentBranch: String?
    var commits: [CommitItem]
    var fileCount: Int
    var additions: Int
    var deletions: Int
    var threadCount: Int
}

struct FileHeaderContent: Equatable {
    var path: String
    var oldPath: String?
    var change: FileChange
    var additions: Int
    var deletions: Int
    var isBinary: Bool
    var threadCount: Int
    var isCollapsed: Bool
}

struct HunkHeaderContent: Equatable {
    var path: String
    var index: Int
    var text: String
}

struct GapContent: Equatable {
    var path: String
    /// The hunk this gap sits above; the trailing gap uses the hunk count.
    var index: Int
    var hiddenCount: Int
    var canExpand: Bool
}

struct CodeRowContent: Equatable {
    var path: String
    var line: LineItem
    var displayText: String
    var isPlainASCII: Bool
    var language: CodeLanguage
    /// The changed part of a paired deleted or added line, in UTF-16 offsets of `displayText`.
    var changedRange: NSRange?

    var commentSide: Side { line.kind == .deleted ? .base : .head }

    var commentLine: Int? { line.kind == .deleted ? line.oldNumber : line.newNumber }
}

struct NoticeContent: Equatable {
    var path: String
    var text: String
    var symbol: String
}

struct BigFileContent: Equatable {
    var path: String
    var lineCount: Int
    var additions: Int
    var deletions: Int
}

struct ThreadRowContent: Equatable {
    var thread: ThreadItem
    /// For example "Client.swift:40–44", "Client.swift" or "This layer".
    var anchorText: String
    /// Set when the thread cannot sit on its lines, for example "Line 88 isn't in this diff".
    var placementNote: String?
    var isCollapsed: Bool
    var hasComposerBelow: Bool
    var leadingInset: Double
}

struct ComposerRowContent: Equatable {
    var key: ComposerKey
    var title: String
    var submitTitle: String
    /// Nil for an edit, which has no "send now".
    var sendNowTitle: String?
    var attachedToCard: Bool
    var leadingInset: Double
}

/// What the pane remembers about one layer while you read it: what you collapsed, expanded and
/// left open. It is view state, so the composers' text is not here; drafts live in the model.
struct LayerViewState {
    var collapsedFiles: Set<String> = []
    var loadedBigFiles: Set<String> = []
    var expandedGaps: Set<GapID> = []
    var openComposers: [ComposerKey] = []
    var expandedResolvedThreads: Set<Int> = []
    var savedScroll: ScrollAnchor?
}

struct GapID: Hashable {
    var path: String
    var index: Int
}

struct ScrollAnchor: Equatable {
    var row: RowID
    var offset: CGFloat
}

/// A layer's files with each line's display text, highlight pairing and size worked out once.
///
/// Thread and composer changes rebuild rows often; this keeps that cheap.
struct PreparedLayer {
    var files: [PreparedFile]
    var largestLineNumber: Int

    init(files: [FileItem]) {
        var largest = 1
        self.files = files.map { file in
            let prepared = PreparedFile(file: file)
            largest = max(largest, prepared.largestLineNumber)
            return prepared
        }
        largestLineNumber = largest
    }
}

struct PreparedFile {
    static let bigFileLineLimit = 400
    static let bigFileByteLimit = 20_000

    var file: FileItem
    var language: CodeLanguage
    var hunks: [[PreparedLine]]
    var isBig: Bool
    var largestLineNumber: Int

    init(file: FileItem) {
        self.file = file
        language = CodeLanguage(path: file.path)
        var lineCount = 0
        var byteCount = 0
        var largest = max(file.newLines.count, file.oldLines.count)
        hunks = file.hunks.map { hunk in
            let displays = hunk.lines.map { DisplayText.make($0.text) }
            let pairs = IntralineDiff.changedRanges(in: zip(hunk.lines, displays).map { ($0.kind, $1.text) })
            return hunk.lines.enumerated().map { index, line in
                lineCount += 1
                byteCount += line.text.utf8.count + 1
                largest = max(largest, line.oldNumber ?? 0, line.newNumber ?? 0)
                return PreparedLine(
                    line: line, displayText: displays[index].text, isPlainASCII: displays[index].isPlainASCII,
                    changedRange: pairs[index])
            }
        }
        isBig = lineCount > Self.bigFileLineLimit || byteCount > Self.bigFileByteLimit
        largestLineNumber = largest
    }
}

struct PreparedLine {
    var line: LineItem
    var displayText: String
    var isPlainASCII: Bool
    var changedRange: NSRange?
}

struct DiffRowBuilder {
    var prepared: PreparedLayer
    var layer: LayerContent
    var layerItem: LayerItem?
    var stack: StackItem?
    var state: LayerViewState
    /// Where thread cards and composers start, so they line up with the code column.
    var codeColumnInset: Double

    func build() -> [DiffRow] {
        var rows: [DiffRow] = [.overview(overview)]
        let placement = ThreadPlacement(threads: layer.threads, files: prepared.files.map(\.file))
        appendThreads(placement.layerThreads, notes: [:], inset: overviewInset, to: &rows)
        appendThreads(placement.threadsOutsideFiles, notes: [:], inset: overviewInset, to: &rows)
        appendNewThreadComposer(for: .layer, inset: overviewInset, to: &rows)

        for file in prepared.files {
            appendFile(file, placement: placement, to: &rows)
        }
        rows.append(.footer)
        return rows
    }

    private var overviewInset: Double { 16 }

    private var overview: OverviewContent {
        let position = layerItem?.position ?? 0
        let parent = stack.flatMap { stack in
            position <= 1 ? stack.trunk : stack.layers.first { $0.position == position - 1 }?.branch
        }
        return OverviewContent(
            layer: layerItem,
            layerCount: stack?.layers.count ?? 0,
            parentBranch: parent,
            commits: layer.commits,
            fileCount: layer.files.count,
            additions: layer.files.reduce(0) { $0 + $1.additions },
            deletions: layer.files.reduce(0) { $0 + $1.deletions },
            threadCount: layer.threads.filter { !$0.isResolved }.count)
    }

    private func appendFile(_ prepared: PreparedFile, placement: ThreadPlacement, to rows: inout [DiffRow]) {
        let file = prepared.file
        let isCollapsed = state.collapsedFiles.contains(file.path)
        rows.append(.fileHeader(FileHeaderContent(
            path: file.path, oldPath: file.oldPath, change: file.change,
            additions: file.additions, deletions: file.deletions, isBinary: file.isBinary,
            threadCount: placement.threadCount(inFile: file.path), isCollapsed: isCollapsed)))
        guard !isCollapsed else { return }

        let showsLines = !file.isBinary && !(prepared.isBig && !state.loadedBigFiles.contains(file.path))
        let lineRows = showsLines ? lineRows(for: prepared) : []
        let shownLines = Set(lineRows.compactMap { row -> LineKey? in
            guard case .code(let code) = row else { return nil }
            return code.commentLine.map { LineKey(path: file.path, side: code.commentSide, line: $0) }
        }).union(lineRows.compactMap { row -> LineKey? in
            guard case .code(let code) = row, code.line.kind == .context, let old = code.line.oldNumber else { return nil }
            return LineKey(path: file.path, side: .base, line: old)
        })

        var notes: [Int: String] = [:]
        var topThreads = placement.fileThreads[file.path] ?? []
        for thread in placement.lineThreads(inFile: file.path) {
            guard let key = placement.key(of: thread), !shownLines.contains(key) else { continue }
            topThreads.append(thread)
            if showsLines {
                notes[thread.id] = "Line \(key.line) isn't in this diff"
            } else if !file.isBinary {
                notes[thread.id] = "On line \(key.line). Load the diff to see it in place."
            }
        }
        topThreads.sort { $0.id < $1.id }
        appendThreads(topThreads, notes: notes, inset: codeColumnInset, to: &rows)
        appendNewThreadComposer(for: .file(path: file.path), inset: codeColumnInset, to: &rows)

        if file.isBinary {
            rows.append(.notice(NoticeContent(path: file.path, text: "Binary file not shown", symbol: "photo")))
            return
        }
        if prepared.isBig, !state.loadedBigFiles.contains(file.path) {
            let lineCount = prepared.hunks.reduce(0) { $0 + $1.count }
            rows.append(.bigFile(BigFileContent(path: file.path, lineCount: lineCount, additions: file.additions, deletions: file.deletions)))
            return
        }
        if file.hunks.isEmpty {
            let text = switch file.change {
            case .renamed: "File renamed without changes"
            case .copied: "File copied without changes"
            case .typeChanged: "File type changed"
            default: "No changes to show"
            }
            rows.append(.notice(NoticeContent(path: file.path, text: text, symbol: "doc.plaintext")))
            return
        }

        for row in lineRows {
            rows.append(row)
            guard case .code(let code) = row else { continue }
            var keys: [LineKey] = []
            if let line = code.commentLine { keys.append(LineKey(path: file.path, side: code.commentSide, line: line)) }
            if code.line.kind == .context, let old = code.line.oldNumber { keys.append(LineKey(path: file.path, side: .base, line: old)) }
            for key in keys {
                appendThreads(placement.threads(at: key), notes: [:], inset: codeColumnInset, to: &rows)
                appendNewThreadComposers(endingAt: key, to: &rows)
            }
        }
    }

    /// The hunk headers, gaps and code rows of one file, in order, without threads.
    private func lineRows(for prepared: PreparedFile) -> [DiffRow] {
        let file = prepared.file
        var rows: [DiffRow] = []
        var nextOld = 1
        var nextNew = 1
        let canExpand = !file.newLines.isEmpty || !file.oldLines.isEmpty

        for (index, hunk) in file.hunks.enumerated() {
            let firstOld = hunk.oldCount == 0 ? hunk.oldStart + 1 : hunk.oldStart
            let firstNew = hunk.newCount == 0 ? hunk.newStart + 1 : hunk.newStart
            let hidden = max(0, min(firstOld - nextOld, firstNew - nextNew))
            let gapIsOpen = state.expandedGaps.contains(GapID(path: file.path, index: index))
            if hidden > 0 {
                if gapIsOpen, canExpand {
                    rows += contextRows(for: prepared, oldStart: nextOld, newStart: nextNew, count: hidden)
                } else {
                    rows.append(.gap(GapContent(path: file.path, index: index, hiddenCount: hidden, canExpand: canExpand)))
                }
            }
            if !(gapIsOpen && hidden > 0) {
                rows.append(.hunkHeader(HunkHeaderContent(path: file.path, index: index, text: hunk.header)))
            }
            for line in prepared.hunks[index] {
                rows.append(.code(CodeRowContent(
                    path: file.path, line: line.line, displayText: line.displayText,
                    isPlainASCII: line.isPlainASCII, language: prepared.language, changedRange: line.changedRange)))
            }
            nextOld = firstOld + hunk.oldCount
            nextNew = firstNew + hunk.newCount
        }

        let lastLine = file.newLines.isEmpty ? file.oldLines.count : file.newLines.count
        let lastNext = file.newLines.isEmpty ? nextOld : nextNew
        let trailing = lastLine - lastNext + 1
        if canExpand, trailing > 0, file.change != .deleted, file.change != .added {
            let index = file.hunks.count
            if state.expandedGaps.contains(GapID(path: file.path, index: index)) {
                rows += contextRows(for: prepared, oldStart: nextOld, newStart: nextNew, count: trailing)
            } else {
                rows.append(.gap(GapContent(path: file.path, index: index, hiddenCount: trailing, canExpand: true)))
            }
        }
        return rows
    }

    private func contextRows(for prepared: PreparedFile, oldStart: Int, newStart: Int, count: Int) -> [DiffRow] {
        let file = prepared.file
        return (0..<count).compactMap { offset in
            let old = oldStart + offset
            let new = newStart + offset
            let text: String
            if file.newLines.indices.contains(new - 1) {
                text = file.newLines[new - 1]
            } else if file.oldLines.indices.contains(old - 1) {
                text = file.oldLines[old - 1]
            } else {
                return nil
            }
            let display = DisplayText.make(text)
            return .code(CodeRowContent(
                path: file.path, line: LineItem(kind: .context, oldNumber: old, newNumber: new, text: text),
                displayText: display.text, isPlainASCII: display.isPlainASCII, language: prepared.language, changedRange: nil))
        }
    }

    private func appendThreads(_ threads: [ThreadItem], notes: [Int: String], inset: Double, to rows: inout [DiffRow]) {
        for thread in threads {
            let composer = attachedComposer(for: thread)
            let isCollapsed = thread.isResolved && !state.expandedResolvedThreads.contains(thread.id) && composer == nil
            rows.append(.thread(ThreadRowContent(
                thread: thread, anchorText: Self.anchorText(for: thread.anchor), placementNote: notes[thread.id],
                isCollapsed: isCollapsed, hasComposerBelow: composer != nil, leadingInset: inset)))
            if let composer {
                rows.append(.composer(composerContent(for: composer, attachedToCard: true, inset: inset)))
            }
        }
    }

    private func attachedComposer(for thread: ThreadItem) -> ComposerKey? {
        let commentIDs = Set(thread.comments.map(\.id))
        return state.openComposers.first { key in
            switch key {
            case .draft(.reply(let threadID)): threadID == thread.id
            case .edit(let commentID): commentIDs.contains(commentID)
            default: false
            }
        }
    }

    private func appendNewThreadComposer(for anchor: ThreadAnchor, inset: Double, to rows: inout [DiffRow]) {
        let key = ComposerKey.draft(.newThread(anchor))
        guard state.openComposers.contains(key) else { return }
        rows.append(.composer(composerContent(for: key, attachedToCard: false, inset: inset)))
    }

    private func appendNewThreadComposers(endingAt line: LineKey, to rows: inout [DiffRow]) {
        for key in state.openComposers {
            guard case .draft(.newThread(.lines(let range))) = key,
                  range.path == line.path, range.side == line.side, range.end == line.line else { continue }
            rows.append(.composer(composerContent(for: key, attachedToCard: false, inset: codeColumnInset)))
        }
    }

    private func composerContent(for key: ComposerKey, attachedToCard: Bool, inset: Double) -> ComposerRowContent {
        switch key {
        case .draft(.newThread(let anchor)):
            ComposerRowContent(key: key, title: Self.composerTitle(for: anchor), submitTitle: "Add to review",
                               sendNowTitle: "Comment now", attachedToCard: attachedToCard, leadingInset: inset)
        case .draft(.reply(let threadID)):
            ComposerRowContent(key: key, title: "Reply to t\(threadID)", submitTitle: "Add to review",
                               sendNowTitle: "Reply now", attachedToCard: attachedToCard, leadingInset: inset)
        case .draft(.reviewSummary):
            ComposerRowContent(key: key, title: "Review summary", submitTitle: "Save",
                               sendNowTitle: nil, attachedToCard: attachedToCard, leadingInset: inset)
        case .edit:
            ComposerRowContent(key: key, title: "Edit comment", submitTitle: "Save",
                               sendNowTitle: nil, attachedToCard: attachedToCard, leadingInset: inset)
        }
    }

    static func anchorText(for anchor: ThreadAnchor) -> String {
        switch anchor {
        case .layer:
            return "This layer"
        case .file(let path):
            return (path as NSString).lastPathComponent
        case .lines(let range):
            let name = (range.path as NSString).lastPathComponent
            let side = range.side == .base ? " (old)" : ""
            return range.start == range.end ? "\(name):\(range.start)\(side)" : "\(name):\(range.start)–\(range.end)\(side)"
        }
    }

    static func composerTitle(for anchor: ThreadAnchor) -> String {
        switch anchor {
        case .layer:
            return "Comment on this layer"
        case .file(let path):
            return "Comment on \((path as NSString).lastPathComponent)"
        case .lines(let range):
            let side = range.side == .base ? " of the old file" : ""
            return range.start == range.end ? "Comment on line \(range.start)\(side)" : "Comment on lines \(range.start) to \(range.end)\(side)"
        }
    }
}

struct LineKey: Hashable {
    var path: String
    var side: Side
    var line: Int
}

/// Sorts a layer's threads by where they sit: the layer, a file, or the last line of a range.
struct ThreadPlacement {
    private(set) var layerThreads: [ThreadItem] = []
    private(set) var threadsOutsideFiles: [ThreadItem] = []
    private(set) var fileThreads: [String: [ThreadItem]] = [:]
    private var byLine: [LineKey: [ThreadItem]] = [:]
    private var lineThreadsByFile: [String: [ThreadItem]] = [:]

    init(threads: [ThreadItem], files: [FileItem]) {
        let paths = Set(files.map(\.path))
        for thread in threads.sorted(by: { $0.id < $1.id }) {
            switch thread.anchor {
            case .layer:
                layerThreads.append(thread)
            case .file(let path):
                if paths.contains(path) { fileThreads[path, default: []].append(thread) } else { threadsOutsideFiles.append(thread) }
            case .lines(let range):
                guard paths.contains(range.path) else {
                    threadsOutsideFiles.append(thread)
                    continue
                }
                byLine[LineKey(path: range.path, side: range.side, line: range.end), default: []].append(thread)
                lineThreadsByFile[range.path, default: []].append(thread)
            }
        }
    }

    func threads(at key: LineKey) -> [ThreadItem] { byLine[key] ?? [] }

    func lineThreads(inFile path: String) -> [ThreadItem] { lineThreadsByFile[path] ?? [] }

    func key(of thread: ThreadItem) -> LineKey? {
        guard case .lines(let range) = thread.anchor else { return nil }
        return LineKey(path: range.path, side: range.side, line: range.end)
    }

    func threadCount(inFile path: String) -> Int {
        (fileThreads[path] ?? []).count + lineThreads(inFile: path).count
    }
}
