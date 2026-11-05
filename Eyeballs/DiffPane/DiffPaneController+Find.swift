import AppKit

extension DiffPaneController {
    // MARK: The find bar

    /// Opens the find bar, or puts the cursor back in its field when it is already open.
    func showFind() {
        windowState.focusFindField()
        guard !windowState.isFindBarShown else { return }
        windowState.isFindBarShown = true
        if !windowState.findText.isEmpty { searchAndMoveToFirstMatch() }
    }

    /// Closes the find bar. The line cursor lands on the match you were on, so `c` comments on it.
    func closeFind() {
        guard windowState.isFindBarShown else { return }
        let landed = find.currentMatch
        windowState.isFindBarShown = false
        refreshFindIfNeeded()
        tableView.window?.makeFirstResponder(tableView)
        guard let landed, let index = indexByID[landed.row], let code = rows[index].code, let line = code.commentLine else { return }
        textSelection = nil
        lineSelection = LineSelection(path: code.path, side: code.commentSide, anchorLine: line, headLine: line)
        redrawVisibleCodeRows()
    }

    /// Searches as you type. You move to the first match at or after the one you were on, or
    /// after the top of the view when you were on none.
    func findTextDidChange(_ text: String) {
        guard text != windowState.findText else { return }
        windowState.findText = text
        searchAndMoveToFirstMatch()
    }

    /// Moves to the next match (`step` 1) or the previous one (`step` -1), wrapping round at the
    /// ends of the layer. With no match chosen yet, it starts from the top of the view.
    func moveFindMatch(by step: Int) {
        guard !windowState.findText.isEmpty else { return showFind() }
        if !windowState.isFindBarShown {
            windowState.isFindBarShown = true
            refreshFindIfNeeded()
        }
        let count = find.matches.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        if let current = find.current {
            find.current = (current + step + count) % count
        } else {
            let start = findPositionAtTopOfView()
            find.current = step > 0 ? find.firstMatch(atOrAfter: start) ?? 0 : find.lastMatch(before: start) ?? count - 1
        }
        showCurrentFindMatch()
    }

    /// Searches for the selected code, and makes the selection the match you are on, so ⌘G
    /// moves on to the next one.
    func useSelectionForFind() {
        guard let (start, end) = orderedTextSelection(), (start.index, start.offset) != (end.index, end.offset),
              let code = rows[start.index].code, let range = selectedCharacters(in: rows[start.index].id), range.length > 0 else {
            NSSound.beep()
            return
        }
        windowState.findText = (code.displayText as NSString).substring(with: range)
        windowState.isFindBarShown = true
        find.search(findInputs, in: searchableLines())
        find.current = find.indexOfMatch(in: rows[start.index].id, at: range)
        publishFindStatus()
    }

    /// Searches again when the text, the layer or its open gaps changed since the last search.
    /// You stay on the same match when it is still there.
    func refreshFindIfNeeded() {
        let inputs = findInputs
        guard inputs != find.inputs else { return }
        let previous = find.currentMatch
        find.search(inputs, in: inputs.text.isEmpty ? [] : searchableLines())
        find.current = previous.flatMap { find.indexOfMatch(in: $0.row, at: $0.range) }
        publishFindStatus()
    }

    // MARK: Searching and moving

    private var findInputs: DiffFind.Inputs {
        DiffFind.Inputs(text: windowState.isFindBarShown ? windowState.findText : "", layerID: shownLayerID,
                        filesVersion: filesVersion, expandedGaps: viewState.expandedGaps)
    }

    private func searchableLines() -> [CodeRowContent] {
        guard let shownLayer else { return [] }
        return DiffRowBuilder(prepared: prepared, layer: shownLayer, state: viewState, codeColumnInset: 0).searchableLines()
    }

    private func searchAndMoveToFirstMatch() {
        let previous = find.currentMatch
        find.search(findInputs, in: searchableLines())
        let start = previous.flatMap { find.position(ofLine: $0.row, offset: $0.range.location) } ?? findPositionAtTopOfView()
        find.current = find.firstMatch(atOrAfter: start) ?? (find.matches.isEmpty ? nil : 0)
        showCurrentFindMatch()
    }

    /// Where the first line below the floating file header sits in the search. A folded file
    /// at the top counts from its first line, so its matches are not skipped.
    private func findPositionAtTopOfView() -> FindPosition {
        var index = firstRowBelowHeader()
        while rows.indices.contains(index) {
            switch rows[index] {
            case .code: if let position = find.position(ofLine: rows[index].id) { return position }
            case .fileHeader(let header): if let position = find.position(ofFile: header.path) { return position }
            default: break
            }
            index += 1
        }
        return .end
    }

    /// Tells the find bar the new count, and redraws the highlights.
    private func publishFindStatus() {
        if windowState.findStatus != find.status { windowState.findStatus = find.status }
        redrawVisibleCodeRows()
    }

    /// Scrolls to the match you are on, opening its file first when it is folded or not loaded.
    private func showCurrentFindMatch() {
        defer { publishFindStatus() }
        guard let match = find.currentMatch, case .line(let path, _, _) = match.row else { return }
        if indexByID[match.row] == nil {
            viewState.collapsedFiles.remove(path)
            viewState.loadedBigFiles.insert(path)
            rebuild()
        }
        guard let index = indexByID[match.row] else { return }
        scrollToShowFindMatch(row: index)
        announce(match)
    }

    /// Leaves a row where it is when it shows in full. Otherwise puts it a third of the way down,
    /// so you see the code around it.
    private func scrollToShowFindMatch(row: Int) {
        tableView.layoutSubtreeIfNeeded()
        let rect = tableView.rect(ofRow: row)
        let visible = visibleRect
        let top = visible.minY + stickyHeaderHeight(above: row)
        guard rect.minY < top || rect.maxY > visible.maxY else { return }
        jump(toRow: row, leavingAbove: (visible.maxY - top) / 3)
    }

    private func announce(_ match: FindMatch) {
        guard let current = find.current, case .line(let path, let old, let new) = match.row else { return }
        let place = "line \(new ?? old ?? 0) of \((path as NSString).lastPathComponent)"
        NSAccessibility.post(element: tableView, notification: .announcementRequested, userInfo: [
            .announcement: "\(current + 1) of \(find.matches.count), \(place)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
}
