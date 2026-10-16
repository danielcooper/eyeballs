import AppKit

/// Lines picked in the gutter, on one side of one file.
struct LineSelection: Equatable {
    var path: String
    var side: Side
    var anchorLine: Int
    var headLine: Int

    var lines: ClosedRange<Int> { min(anchorLine, headLine)...max(anchorLine, headLine) }
    var range: LineRange { LineRange(path: path, side: side, start: lines.lowerBound, end: lines.upperBound) }
}

/// Characters picked by dragging across code, as row and UTF-16 offset pairs.
struct TextSelection: Equatable {
    var anchor: TextPoint
    var head: TextPoint
}

struct TextPoint: Equatable {
    var row: RowID
    var offset: Int
}

/// What Edit > Undo needs to bring back a discarded composer.
final class DiscardedComposer: NSObject {
    let key: ComposerKey
    let text: String

    init(key: ComposerKey, text: String) {
        self.key = key
        self.text = text
    }
}

/// What Edit > Undo needs to bring back a pending comment you deleted.
final class DeletedComment: NSObject {
    let body: String
    let anchor: ThreadAnchor
    let layerID: Int
    /// Nil when deleting the comment removed its thread too, so Undo starts the thread again.
    let threadID: Int?

    init(body: String, anchor: ThreadAnchor, layerID: Int, threadID: Int?) {
        self.body = body
        self.anchor = anchor
        self.layerID = layerID
        self.threadID = threadID
    }
}

enum DragMode: Equatable {
    case none
    case lines(opensComposer: Bool)
    case text
}

extension CodeRowContent {
    func number(on side: Side) -> Int? {
        side == .head ? line.newNumber : line.oldNumber
    }
}

extension DiffPaneController {
    // MARK: Navigation from outside the pane

    func revealOverview() {
        scroll(toY: 0)
    }

    func revealFile(_ path: String) {
        if viewState.collapsedFiles.contains(path) {
            viewState.collapsedFiles.remove(path)
            rebuild()
        }
        guard let index = indexByID[.fileHeader(path)] else { return }
        jump(toRow: index)
        windowState.currentFilePath = path
    }

    /// Scrolls to a thread and focuses it, opening its file first when it is folded away.
    func revealThread(_ id: Int) {
        guard let thread = model.layer?.threads.first(where: { $0.id == id }) else { return }
        var state = viewState
        let path: String? = switch thread.anchor {
        case .lines(let range): range.path
        case .file(let path): path
        case .layer: nil
        }
        if let path {
            state.collapsedFiles.remove(path)
            if case .lines = thread.anchor { state.loadedBigFiles.insert(path) }
        }
        if thread.isResolved { state.expandedResolvedThreads.insert(id) }
        viewState = state
        rebuild()
        setFocusedThread(id)
        if let index = indexByID[.thread(id)] { revealThreadRow(index) }
    }

    /// Scrolls so the thread's own code shows above its card, never just the card under the header.
    private func revealThreadRow(_ index: Int) {
        guard case .thread(let content) = rows[index] else { return }
        tableView.layoutSubtreeIfNeeded()
        guard case .lines(let range) = content.thread.anchor, let start = firstCodeRow(of: range, above: index) else {
            jump(toRow: index)
            return
        }
        let context = 2 * metrics.lineHeight
        let threadRect = tableView.rect(ofRow: index)
        let startTop = tableView.rect(ofRow: start).minY
        let available = visibleRect.height - stickyHeaderHeight(above: start)
        if threadRect.maxY - startTop + context <= available || threadRect.minY - startTop <= available / 2 {
            jump(toRow: start, leavingAbove: context)
        } else {
            jump(toRow: codeRow(countingUp: 3, from: index) ?? start)
        }
    }

    /// The first row of `range` that the pane shows above the thread's card. When the range
    /// starts inside a folded gap, this is its first shown line; when none of it shows, the
    /// code row three above the card.
    func firstCodeRow(of range: LineRange, above threadRow: Int) -> Int? {
        guard let header = fileHeaderIndex(containing: threadRow), header + 1 < threadRow else { return nil }
        for index in (header + 1)..<threadRow {
            if let code = rows[index].code, code.path == range.path, let number = code.number(on: range.side),
               (range.start...range.end).contains(number) {
                return index
            }
        }
        return codeRow(countingUp: 3, from: threadRow)
    }

    /// The code row `count` code rows above `row`, or the highest one in the same file.
    private func codeRow(countingUp count: Int, from row: Int) -> Int? {
        var found: Int?
        var seen = 0
        var index = row - 1
        while index >= 0, !rows[index].isFileHeader, seen < count {
            if rows[index].code != nil {
                found = index
                seen += 1
            }
            index -= 1
        }
        return found
    }

    func lineRowIndex(path: String, side: Side, line: Int) -> Int? {
        guard let header = indexByID[.fileHeader(path)] else { return nil }
        var index = header + 1
        while index < rows.count, !rows[index].isFileHeader {
            if let code = rows[index].code, code.number(on: side) == line { return index }
            index += 1
        }
        return nil
    }

    // MARK: View state changes

    /// Ticks or clears a file's Viewed box. A viewed file folds away, as on GitHub.
    func setViewed(_ viewed: Bool, path: String) {
        guard let layer = model.layer, let file = layer.files.first(where: { $0.path == path }) else { return }
        windowState.setViewed(viewed, file: file, layerID: layer.layerID)
        setFile(path, collapsed: viewed)
    }

    func setFile(_ path: String, collapsed: Bool) {
        let headerWasPinned = indexByID[.fileHeader(path)].map { tableView.rect(ofRow: $0).minY < visibleRect.minY } ?? false
        if collapsed { viewState.collapsedFiles.insert(path) } else { viewState.collapsedFiles.remove(path) }
        rebuild()
        if collapsed, headerWasPinned, let index = indexByID[.fileHeader(path)] { jump(toRow: index) }
    }

    func expandGap(_ gap: GapID) {
        viewState.expandedGaps.insert(gap)
        rebuild()
    }

    func loadBigFile(_ path: String) {
        viewState.loadedBigFiles.insert(path)
        rebuild()
    }

    func toggleResolvedExpanded(_ threadID: Int) {
        if viewState.expandedResolvedThreads.contains(threadID) {
            viewState.expandedResolvedThreads.remove(threadID)
        } else {
            viewState.expandedResolvedThreads.insert(threadID)
        }
        rebuild()
    }

    // MARK: Composers

    func openComposer(_ key: ComposerKey) {
        var state = viewState
        if let attachedThread = threadID(attachedTo: key) {
            for other in state.openComposers where other != key && threadID(attachedTo: other) == attachedThread {
                flushDraft(for: other)
            }
            state.openComposers.removeAll { $0 != key && threadID(attachedTo: $0) == attachedThread }
            if let thread = model.layer?.threads.first(where: { $0.id == attachedThread }), case .lines(let range) = thread.anchor {
                state.collapsedFiles.remove(range.path)
            }
        }
        switch key {
        case .draft(.newThread(.file(let path))): state.collapsedFiles.remove(path)
        case .draft(.newThread(.lines(let range))): state.collapsedFiles.remove(range.path)
        default: break
        }
        if case .edit(let commentID) = key, liveDrafts[key] == nil {
            liveDrafts[key] = comment(commentID)?.body ?? ""
        }
        if !state.openComposers.contains(key) { state.openComposers.append(key) }
        viewState = state
        lineSelection = nil
        rebuild()
        redrawVisibleCodeRows()
        focusComposer(key)
    }

    /// Opens the layer comment the window asked for, such as a request to restack, once its
    /// layer shows. A draft you already started there is kept.
    func openLayerCommentWaitingForLoad() {
        guard let pending = windowState.layerCommentToOpenAfterLoad, pending.layerID == shownLayerID else { return }
        windowState.layerCommentToOpenAfterLoad = nil
        let key = ComposerKey.draft(.newThread(.layer))
        if draftText(for: key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            liveDrafts[key] = pending.text
            scheduleDraftSave(for: key)
        }
        openComposer(key)
    }

    func focusComposer(_ key: ComposerKey) {
        guard let index = indexByID[.composer(key)] else { return }
        scrollToShow(row: index)
        tableView.layoutSubtreeIfNeeded()
        guard let view = tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? ComposerRowView else { return }
        view.window?.makeFirstResponder(view.textView)
        view.textView.setSelectedRange(NSRange(location: (view.textView.string as NSString).length, length: 0))
    }

    func closeComposer(_ key: ComposerKey) {
        flushDraft(for: key)
        liveDrafts[key] = nil
        viewState.openComposers.removeAll { $0 == key }
        tableView.window?.makeFirstResponder(tableView)
        rebuild()
        redrawVisibleCodeRows()
    }

    /// Closes a composer and throws its draft away. Edit > Undo brings both back.
    func discardComposer(_ key: ComposerKey) {
        let text = draftText(for: key)
        draftSaves[key]?.cancel()
        draftSaves[key] = nil
        liveDrafts[key] = nil
        if case .draft(let draftKey) = key { model.saveDraft("", for: draftKey) }
        viewState.openComposers.removeAll { $0 == key }
        tableView.window?.makeFirstResponder(tableView)
        rebuild()
        redrawVisibleCodeRows()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let undo = tableView.window?.undoManager else { return }
        undo.registerUndo(withTarget: self, selector: #selector(restoreDiscardedComposer(_:)), object: DiscardedComposer(key: key, text: text))
        undo.setActionName("Discard Comment")
    }

    @objc private func restoreDiscardedComposer(_ discarded: DiscardedComposer) {
        liveDrafts[discarded.key] = discarded.text
        if case .draft(let draftKey) = discarded.key { model.saveDraft(discarded.text, for: draftKey) }
        openComposer(discarded.key)
    }

    func submitComposer(_ key: ComposerKey, sendNow: Bool) {
        let text = draftText(for: key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            NSSound.beep()
            return
        }
        draftSaves[key]?.cancel()
        draftSaves[key] = nil
        switch key {
        case .draft(.newThread(let anchor)): model.addComment(text, at: anchor, sendNow: sendNow)
        case .draft(.reply(let threadID)): model.reply(text, to: threadID, sendNow: sendNow)
        case .draft(.reviewSummary): windowState.summaryText = text
        case .edit(let commentID): model.editComment(commentID, body: text)
        }
        if case .draft(let draftKey) = key { model.saveDraft("", for: draftKey) }
        liveDrafts[key] = nil
        viewState.openComposers.removeAll { $0 == key }
        tableView.window?.makeFirstResponder(tableView)
        rebuild()
        redrawVisibleCodeRows()
    }

    func composerTextDidChange(_ text: String, for key: ComposerKey) {
        liveDrafts[key] = text
        if case .draft = key { scheduleDraftSave(for: key) }
        guard let index = indexByID[.composer(key)] else { return }
        let newHeight = height(of: rows[index])
        guard newHeight != heights[index] else { return }
        setHeight(newHeight, ofRow: index)
    }

    /// The composer's text: what you have typed so far, else the model's saved draft.
    func draftText(for key: ComposerKey) -> String {
        if let live = liveDrafts[key] { return live }
        switch key {
        case .draft(let draftKey): return model.draft(for: draftKey)
        case .edit(let commentID): return comment(commentID)?.body ?? ""
        }
    }

    /// Saves a draft 300 ms after typing stops.
    func scheduleDraftSave(for key: ComposerKey) {
        draftSaves[key]?.cancel()
        draftSaves[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.flushDraft(for: key)
        }
    }

    func flushDraft(for key: ComposerKey) {
        draftSaves[key]?.cancel()
        draftSaves[key] = nil
        guard case .draft(let draftKey) = key, let text = liveDrafts[key] else { return }
        model.saveDraft(text, for: draftKey)
    }

    /// Saves every open composer's draft at once, for example when the app quits.
    func flushAllDrafts() {
        for key in liveDrafts.keys { flushDraft(for: key) }
    }

    private func threadID(attachedTo key: ComposerKey) -> Int? {
        switch key {
        case .draft(.reply(let threadID)): threadID
        case .edit(let commentID): model.layer?.threads.first { $0.comments.contains { $0.id == commentID } }?.id
        default: nil
        }
    }

    private func comment(_ id: Int) -> CommentItem? {
        model.layer?.threads.lazy.flatMap(\.comments).first { $0.id == id }
    }

    // MARK: Thread cards

    func cardActions(for threadID: Int) -> ThreadCardActions {
        ThreadCardActions(
            focus: { [weak self] in
                self?.afterThisEvent { pane in
                    pane.setFocusedThread(threadID)
                    pane.tableView.window?.makeFirstResponder(pane.tableView)
                }
            },
            reply: { [weak self] in self?.afterThisEvent { $0.openComposer(.draft(.reply(threadID: threadID))) } },
            setResolved: { [weak self] resolved in
                self?.afterThisEvent { pane in
                    pane.model.setResolved(resolved, threadID: threadID)
                    if !resolved { pane.viewState.expandedResolvedThreads.remove(threadID) }
                    pane.rebuild()
                }
            },
            toggleExpanded: { [weak self] in self?.afterThisEvent { $0.toggleResolvedExpanded(threadID) } },
            edit: { [weak self] commentID in self?.afterThisEvent { $0.openComposer(.edit(commentID: commentID)) } },
            delete: { [weak self] commentID in self?.afterThisEvent { $0.deleteComment(commentID, inThread: threadID) } },
            deleteThread: { [weak self] in self?.afterThisEvent { $0.deleteThread(threadID) } })
    }

    func overviewActions() -> OverviewActions {
        OverviewActions(
            commentOnLayer: { [weak self] in self?.afterThisEvent { $0.openComposer(.draft(.newThread(.layer))) } },
            showLayer: { [weak self] position in self?.afterThisEvent { $0.model.selectLayer(atPosition: position) } })
    }

    func footerActions() -> FooterActions {
        FooterActions(
            showLayer: { [weak self] position in self?.afterThisEvent { $0.model.selectLayer(atPosition: position) } },
            finishReview: { [weak self] in self?.afterThisEvent { $0.windowState.finishReview($0.model) } })
    }

    // MARK: Deleting

    /// Deletes one of your comments. A pending one goes at once, and Edit > Undo brings it back.
    /// A sent one asks first, because the agent may already have read it.
    func deleteComment(_ commentID: Int, inThread threadID: Int) {
        guard let thread = model.layer?.threads.first(where: { $0.id == threadID }),
              let comment = thread.comments.first(where: { $0.id == commentID }) else { return }
        guard comment.isPending else {
            confirmDeletion(
                title: "Delete this comment?",
                message: "You've sent it, so \(agentName) may already have read it. Deleting it takes it out of the thread for you both.",
                button: "Delete Comment") { pane in
                    pane.model.deleteComment(commentID)
                    pane.rebuild()
                }
            return
        }
        model.deleteComment(commentID)
        rebuild()
        registerUndo(of: comment, in: thread, removesThread: thread.comments.count == 1)
    }

    /// Deletes a whole thread. A thread that is one pending comment goes at once, with Undo.
    /// Any other asks first, because it holds more than one comment or the agent may have read it.
    func deleteThread(_ threadID: Int) {
        guard let thread = model.layer?.threads.first(where: { $0.id == threadID }) else { return }
        if thread.comments.count == 1, let comment = thread.comments.first, comment.isPending {
            model.deleteThread(threadID)
            rebuild()
            registerUndo(of: comment, in: thread, removesThread: true)
            return
        }
        let message = thread.hasSentComments
            ? "You've sent it, so \(agentName) may already have read it. Every comment in it goes, the replies too."
            : "All \(thread.comments.count) comments in it go too."
        confirmDeletion(title: "Delete this thread?", message: message, button: "Delete Thread") { pane in
            pane.model.deleteThread(threadID)
            pane.rebuild()
        }
    }

    private var agentName: String { model.agent.agentName ?? "the agent" }

    private func registerUndo(of comment: CommentItem, in thread: ThreadItem, removesThread: Bool) {
        guard let undo = tableView.window?.undoManager, let layerID = model.layer?.layerID else { return }
        let deleted = DeletedComment(body: comment.body, anchor: thread.anchor, layerID: layerID, threadID: removesThread ? nil : thread.id)
        undo.registerUndo(withTarget: self, selector: #selector(restoreDeletedComment(_:)), object: deleted)
        undo.setActionName("Delete Comment")
    }

    @objc private func restoreDeletedComment(_ deleted: DeletedComment) {
        if model.selection?.layerID != deleted.layerID, let stack = model.selectedStack {
            model.select(LayerSelection(stackID: stack.id, layerID: deleted.layerID))
        }
        if let threadID = deleted.threadID, model.layer?.threads.contains(where: { $0.id == threadID }) == true {
            model.reply(deleted.body, to: threadID, sendNow: false)
        } else {
            model.addComment(deleted.body, at: deleted.anchor, sendNow: false)
        }
        rebuild()
    }

    private func confirmDeletion(title: String, message: String, button: String, then delete: @escaping @MainActor (DiffPaneController) -> Void) {
        guard let window = tableView.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                delete(self)
            }
        }
    }

    /// Runs work once the current click has finished, so a card never rebuilds under its own button.
    private func afterThisEvent(_ work: @escaping @MainActor (DiffPaneController) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            work(self)
        }
    }

    // MARK: Mouse

    var isDragging: Bool { dragMode != .none }

    func mouseDown(at point: NSPoint, extending: Bool, clickCount: Int) -> Bool {
        let index = tableView.row(at: point)
        guard rows.indices.contains(index), let code = rows[index].code else {
            clearTextSelection()
            return false
        }
        let rowRect = tableView.rect(ofRow: index)
        let local = NSPoint(x: point.x - rowRect.minX, y: point.y - rowRect.minY)
        let id = rows[index].id
        let gutterEnd = 2 * metrics.numberColumnWidth + metrics.markerWidth
        let buttonRect = NSRect(x: 2 * metrics.numberColumnWidth, y: 0, width: metrics.markerWidth + 2, height: metrics.lineHeight)
        let onCommentButton = hoveredRowID == id && buttonRect.contains(local)

        if let line = code.commentLine, onCommentButton || local.x < gutterEnd {
            textSelection = nil
            if extending, var selection = lineSelection, selection.path == code.path, let number = code.number(on: selection.side) {
                selection.headLine = number
                lineSelection = selection
            } else {
                lineSelection = LineSelection(path: code.path, side: code.commentSide, anchorLine: line, headLine: line)
            }
            dragMode = .lines(opensComposer: onCommentButton)
            redrawVisibleCodeRows()
            return true
        }

        if lineSelection != nil { lineSelection = nil }
        guard let point = textPoint(at: point) else { return false }
        if extending, var selection = textSelection {
            selection.head = point
            textSelection = selection
        } else {
            textSelection = TextSelection(anchor: point, head: point)
        }
        dragMode = .text
        redrawVisibleCodeRows()
        return true
    }

    func mouseDragged(to point: NSPoint) {
        switch dragMode {
        case .none:
            return
        case .lines:
            guard var selection = lineSelection else { return }
            let index = tableView.row(at: point)
            guard rows.indices.contains(index), let code = rows[index].code, code.path == selection.path,
                  let number = code.number(on: selection.side), number != selection.headLine else { return }
            selection.headLine = number
            lineSelection = selection
        case .text:
            guard var selection = textSelection, let head = textPoint(at: point) else { return }
            selection.head = head
            textSelection = selection
        }
        redrawVisibleCodeRows()
    }

    func mouseUp() {
        defer { dragMode = .none }
        switch dragMode {
        case .lines(opensComposer: true):
            if let selection = lineSelection { openComposer(.draft(.newThread(.lines(selection.range)))) }
        case .text:
            if let selection = textSelection, selection.anchor == selection.head { clearTextSelection() }
        default:
            break
        }
    }

    func hover(at point: NSPoint?) {
        guard let point else { return setHoveredRow(nil) }
        let index = tableView.row(at: point)
        if rows.indices.contains(index), let code = rows[index].code, code.commentLine != nil {
            setHoveredRow(rows[index].id)
        } else {
            setHoveredRow(nil)
        }
    }

    func textPoint(at point: NSPoint) -> TextPoint? {
        let index = tableView.row(at: point)
        guard rows.indices.contains(index), let code = rows[index].code else { return nil }
        let rowRect = tableView.rect(ofRow: index)
        let layout = metrics.layout(of: code.displayText, isPlainASCII: code.isPlainASCII, rowWidth: rowWidth)
        let lineIndex = min(layout.lines.count - 1, max(0, Int((point.y - rowRect.minY) / metrics.lineHeight)))
        let offset = metrics.offset(atX: point.x - rowRect.minX, line: lineIndex, in: layout, text: code.displayText)
        return TextPoint(row: rows[index].id, offset: offset)
    }

    // MARK: Selection

    func isLineSelected(_ id: RowID) -> Bool {
        guard case .line(let path, let old, let new) = id else { return false }
        if let selection = lineSelection, selection.path == path,
           let number = selection.side == .head ? new : old, selection.lines.contains(number) {
            return true
        }
        if let range = focusedRange, range.path == path, let number = range.side == .head ? new : old,
           (range.start...range.end).contains(number) {
            return true
        }
        for key in viewState.openComposers {
            guard case .draft(.newThread(.lines(let range))) = key, range.path == path,
                  let number = range.side == .head ? new : old else { continue }
            if (range.start...range.end).contains(number) { return true }
        }
        return false
    }

    func selectedCharacters(in id: RowID) -> NSRange? {
        guard let (start, end) = orderedTextSelection(), let index = indexByID[id],
              start.index <= index, index <= end.index, let code = rows[index].code else { return nil }
        let lower = index == start.index ? start.offset : 0
        let upper = index == end.index ? end.offset : code.displayText.utf16.count
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private func orderedTextSelection() -> (start: (index: Int, offset: Int), end: (index: Int, offset: Int))? {
        guard let selection = textSelection,
              let anchorIndex = indexByID[selection.anchor.row], let headIndex = indexByID[selection.head.row] else { return nil }
        let anchor = (index: anchorIndex, offset: selection.anchor.offset)
        let head = (index: headIndex, offset: selection.head.offset)
        return (anchor.index, anchor.offset) <= (head.index, head.offset) ? (anchor, head) : (head, anchor)
    }

    var isTableFocused: Bool { tableView.window?.firstResponder === tableView }

    var hasCopyableSelection: Bool {
        if let selection = textSelection, selection.anchor != selection.head { return true }
        return lineSelection != nil
    }

    func clearSelections() {
        lineSelection = nil
        setFocusedThread(nil)
        clearTextSelection()
        redrawVisibleCodeRows()
    }

    private func clearTextSelection() {
        guard textSelection != nil else { return }
        textSelection = nil
        redrawVisibleCodeRows()
    }

    /// The selected code without line numbers or markers, with tabs as they are in the file.
    func selectedText() -> String? {
        if let (start, end) = orderedTextSelection(), (start.index, start.offset) != (end.index, end.offset) {
            var lines: [String] = []
            for index in start.index...end.index {
                guard let code = rows[index].code, let range = selectedCharacters(in: rows[index].id) else { continue }
                lines.append(Self.sourceText(of: code, in: range))
            }
            return lines.joined(separator: "\n")
        }
        if let selection = lineSelection, let header = indexByID[.fileHeader(selection.path)] {
            var lines: [String] = []
            var index = header + 1
            while index < rows.count, !rows[index].isFileHeader {
                if let code = rows[index].code, let number = code.number(on: selection.side), selection.lines.contains(number) {
                    lines.append(code.line.text)
                }
                index += 1
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        return nil
    }

    func copySelection(to pasteboard: NSPasteboard) {
        guard let text = selectedText() else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func sourceText(of code: CodeRowContent, in range: NSRange) -> String {
        let source = code.line.text as NSString
        guard code.displayText != code.line.text else {
            return source.substring(with: NSRange(location: range.location, length: min(range.length, source.length - range.location)))
        }
        let start = DisplayText.sourceOffset(forDisplayOffset: range.location, in: code.line.text)
        let end = DisplayText.sourceOffset(forDisplayOffset: NSMaxRange(range), in: code.line.text)
        return source.substring(with: NSRange(location: start, length: max(0, end - start)))
    }

    // MARK: Keyboard

    /// Acts on a single-letter shortcut. Returns false for keys the pane does not use.
    func handleShortcut(_ character: Character) -> Bool {
        switch character {
        case "j": moveLineCursor(by: 1, extending: false)
        case "k": moveLineCursor(by: -1, extending: false)
        case "J": moveLineCursor(by: 1, extending: true)
        case "K": moveLineCursor(by: -1, extending: true)
        case "n": moveThreadFocus(by: 1, needingYouOnly: false)
        case "p": moveThreadFocus(by: -1, needingYouOnly: false)
        case "a": moveThreadFocus(by: 1, needingYouOnly: true)
        case "]": moveFile(by: 1)
        case "[": moveFile(by: -1)
        case "c": commentOnSelectedLines()
        case "r": replyToFocusedThread()
        case "e": toggleFocusedThreadResolved()
        case "v": toggleViewedOfCurrentFile()
        default: return false
        }
        shortcutsFired.append(character)
        return true
    }

    func moveLineCursor(by step: Int, extending: Bool) {
        let current: Int
        if let selection = lineSelection, let index = lineRowIndex(path: selection.path, side: selection.side, line: selection.headLine) {
            current = index
        } else {
            current = firstRowBelowHeader() - step
        }
        var index = current + step
        while rows.indices.contains(index) {
            if let code = rows[index].code {
                if extending, let selection = lineSelection {
                    if code.path == selection.path, code.number(on: selection.side) != nil { break }
                } else if code.commentLine != nil {
                    break
                }
            }
            index += step
        }
        guard rows.indices.contains(index), let code = rows[index].code else {
            NSSound.beep()
            return
        }
        if extending, var selection = lineSelection, let number = code.number(on: selection.side) {
            selection.headLine = number
            lineSelection = selection
        } else if let line = code.commentLine {
            lineSelection = LineSelection(path: code.path, side: code.commentSide, anchorLine: line, headLine: line)
        }
        textSelection = nil
        scrollToShow(row: index)
        redrawVisibleCodeRows()
    }

    /// Focuses the next or previous thread. Looking for threads that need you, it carries on
    /// to the next layer that has one once this layer has none left.
    func moveThreadFocus(by step: Int, needingYouOnly: Bool) {
        let candidates = rows.indices.filter { index in
            guard case .thread(let content) = rows[index] else { return false }
            return !needingYouOnly || content.thread.state.needsYou
        }
        let current = focusedThreadID.flatMap { indexByID[.thread($0)] } ?? (firstRowBelowHeader() - (step > 0 ? 1 : 0))
        let following = step > 0 ? candidates.first { $0 > current } : candidates.last { $0 < current }
        if needingYouOnly, following == nil, moveToNextLayerNeedingYou() { return }
        guard !candidates.isEmpty else {
            NSSound.beep()
            return
        }
        let next = following ?? (step > 0 ? candidates[0] : candidates[candidates.count - 1])
        guard let id = rows[next].threadID else { return }
        setFocusedThread(id)
        revealThreadRow(next)
    }

    /// Switches to the nearest layer above with a thread that needs you, wrapping round to the
    /// bottom of the stack, and focuses its first such thread once it loads. Returns false when
    /// no other layer has one.
    private func moveToNextLayerNeedingYou() -> Bool {
        guard let stack = model.selectedStack, let layer = model.selectedLayer else { return false }
        let ordered = stack.layers.filter { $0.id != layer.id }.sorted { lhs, rhs in
            (lhs.position < layer.position ? 1 : 0, lhs.position) < (rhs.position < layer.position ? 1 : 0, rhs.position)
        }
        let target = ordered.first { other in
            if let threads = model.threadsByLayer[other.id] { return threads.contains { $0.state.needsYou } }
            return other.needsYouCount > 0
        }
        guard let target else { return false }
        layerAwaitingFirstThreadNeedingYou = target.id
        model.select(LayerSelection(stackID: stack.id, layerID: target.id))
        return true
    }

    /// Focuses the first thread on the shown layer that needs you, after a jump from another layer.
    func revealFirstThreadNeedingYou() {
        layerAwaitingFirstThreadNeedingYou = nil
        guard let index = rows.indices.first(where: { rows[$0].thread?.state.needsYou == true }),
              let id = rows[index].threadID else { return }
        setFocusedThread(id)
        revealThreadRow(index)
    }

    func moveFile(by step: Int) {
        guard !fileHeaderRows.isEmpty else {
            NSSound.beep()
            return
        }
        let top = firstRowBelowHeader()
        let target: Int?
        if step > 0 {
            target = fileHeaderRows.first { $0 > top }
        } else {
            let current = fileHeaderIndex(containing: top)
            if let current, tableView.rect(ofRow: current).minY < visibleRect.minY - 1 {
                target = current
            } else {
                target = fileHeaderRows.last { $0 < (current ?? top) }
            }
        }
        guard let target else {
            NSSound.beep()
            return
        }
        jump(toRow: target)
    }

    private func commentOnSelectedLines() {
        guard let selection = lineSelection else {
            NSSound.beep()
            return
        }
        openComposer(.draft(.newThread(.lines(selection.range))))
    }

    private func replyToFocusedThread() {
        guard let id = focusedThreadID else {
            NSSound.beep()
            return
        }
        openComposer(.draft(.reply(threadID: id)))
    }

    private func toggleFocusedThreadResolved() {
        guard let id = focusedThreadID, let thread = model.layer?.threads.first(where: { $0.id == id }), thread.state != .draft else {
            NSSound.beep()
            return
        }
        model.setResolved(!thread.isResolved, threadID: id)
        if thread.isResolved { viewState.expandedResolvedThreads.remove(id) }
        rebuild()
    }

    private func toggleViewedOfCurrentFile() {
        guard let layer = model.layer, let path = lineSelection?.path ?? windowState.currentFilePath,
              let file = layer.files.first(where: { $0.path == path }) else {
            NSSound.beep()
            return
        }
        setViewed(!windowState.isViewed(file, layerID: layer.layerID), path: path)
    }

    /// The first row whose top is at or below the bottom of the floating header.
    private func firstRowBelowHeader() -> Int {
        let range = tableView.rows(in: visibleRect)
        guard range.length > 0 else { return 0 }
        for index in range.location..<range.location + range.length {
            if tableView.rect(ofRow: index).minY >= visibleRect.minY + stickyHeaderHeight(above: index) - 0.5 { return index }
        }
        return range.location
    }
}
