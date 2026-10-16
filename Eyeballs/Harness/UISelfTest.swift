#if DEBUG
import AppKit

/// `--ui-selftest`: runs the PR 0 spike's checks against the real diff pane, prints one JSON
/// object per check, then quits with status 0 when every check passes and 1 otherwise.
@MainActor
final class UISelfTest {
    private let session: AppSession
    private var window: HarnessWindow!
    private var results: [[String: Any]] = []
    private var model: ReviewWindowModel { session.model }
    private var pane: DiffPaneController { session.windowState.pane! }
    private var table: DiffTableView { pane.tableView }

    init(session: AppSession) {
        self.session = session
    }

    func run() {
        Task {
            await runChecks()
            let failed = results.filter { ($0["pass"] as? Bool) == false }.compactMap { $0["check"] as? String }
            record("summary", ["failed": failed, "pass": failed.isEmpty])
            exit(failed.isEmpty ? 0 : 1)
        }
    }

    private func runChecks() async {
        window = HarnessWindow.make(model: model, windowState: session.windowState)
        await window.settle(600)
        guard session.windowState.pane != nil else {
            record("setup", ["pass": false, "reason": "the diff pane never appeared"])
            return
        }
        let defaults = UserDefaults.standard
        record("setup", [
            "estimating_row_heights": defaults.object(forKey: "NSTableViewCanEstimateRowHeights") as? Bool ?? true,
            "pass": defaults.bool(forKey: "NSTableViewCanEstimateRowHeights") == false,
        ])

        checkRowsMatchTheModel()
        model.selectLayer(atPosition: 2)
        await window.settle(400)
        pane.loadBigFile("Sources/API/Generated/Schema.swift")
        await window.settle()
        checkHeights("startup_heights_match_width")
        await checkComposerSurvivesScrolling()
        await checkThreadGrowingAboveViewport()
        await checkJumpFarDown()
        await checkSelectionAcrossThreeRows()
        await checkReloadWithDifferentLayer()
        await checkResizeRewraps()
        await checkShortcutsNeedTableFocus()
    }

    // MARK: Checks

    /// Every thread on every layer appears exactly once, and expanding every gap of a modified
    /// file shows each of its new lines once, in order.
    private func checkRowsMatchTheModel() {
        var problems: [String] = []
        for position in 1...3 {
            model.selectLayer(atPosition: position)
            pane.refreshFromModel()
            guard let layer = model.layer else { continue }
            for file in layer.files where file.isBinary == false {
                pane.loadBigFile(file.path)
                for index in 0...file.hunks.count { pane.expandGap(GapID(path: file.path, index: index)) }
            }
            for file in layer.files where file.change == .modified || file.change == .renamed {
                let numbers = pane.rows.compactMap { row -> Int? in
                    guard let code = row.code, code.path == file.path, code.line.kind != .deleted else { return nil }
                    return code.line.newNumber
                }
                if numbers != Array(1...file.newLines.count) { problems.append("\(file.path) shows new lines out of order") }
                for row in pane.rows {
                    guard let code = row.code, code.path == file.path, let new = code.line.newNumber, code.line.kind != .deleted else { continue }
                    if file.newLines[new - 1] != code.line.text { problems.append("\(file.path):\(new) text differs") }
                }
            }
            let shown = pane.rows.compactMap(\.threadID)
            if shown.sorted() != layer.threads.map(\.id).sorted() { problems.append("layer \(position) shows threads \(shown) of \(layer.threads.map(\.id))") }
        }
        record("rows_match_the_model", ["problems": problems, "pass": problems.isEmpty])
    }

    private func checkComposerSurvivesScrolling() async {
        pane.shortcutsFired = []
        guard let range = lineRange(path: "Sources/API/Client.swift", containing: "private let retry: Retry") else {
            return record("composer_survives_scrolling", ["pass": false, "reason": "no line to comment on"])
        }
        let key = ComposerKey.draft(.newThread(.lines(range)))
        pane.openComposer(key)
        await window.settle()
        guard let row = pane.indexByID[.composer(key)],
              let composer = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ComposerRowView else {
            return record("composer_survives_scrolling", ["pass": false, "reason": "the composer row is not visible"])
        }
        window.makeKey()
        window.makeFirstResponder(composer.textView)
        type("Hello ")
        await window.settle()

        pane.scroll(toY: table.rect(ofRow: row).minY + 4_000)
        await window.settle()
        let stillInWindow = composer.textView.window != nil
        let firstResponder = window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "nil"
        type("e")
        await window.settle()

        if let back = pane.indexByID[.composer(key)] { pane.jump(toRow: max(0, back - 3)) }
        await window.settle(450)
        let shownRow = pane.indexByID[.composer(key)] ?? -1
        let shown = (table.view(atColumn: 0, row: shownRow, makeIfNecessary: false) as? ComposerRowView)?.textView.string
        let draft = pane.draftText(for: key)
        let saved = model.draft(for: .newThread(.lines(range)))
        record("composer_survives_scrolling", [
            "draft": draft, "shown": shown ?? "(row not visible)", "autosaved": saved,
            "text_view_still_in_window_while_off_screen": stillInWindow,
            "first_responder_while_off_screen": firstResponder,
            "shortcuts_fired": pane.shortcutsFired.map(String.init),
            "pass": draft == "Hello e" && shown == draft && saved == draft && pane.shortcutsFired.isEmpty,
        ])
        pane.closeComposer(key)
        model.saveDraft("", for: .newThread(.lines(range)))
        await window.settle()
    }

    private func checkThreadGrowingAboveViewport() async {
        guard let threadRow = pane.indexByID[.thread(42)] else {
            return record("thread_grows_above_viewport", ["pass": false, "reason": "thread t42 is not shown"])
        }
        let watched = pane.rows[threadRow + 12].id
        pane.jump(toRow: threadRow + 12)
        await window.settle()
        let before = screenY(of: watched)
        let heightBefore = pane.heights[threadRow]
        model.reply(String(repeating: "A long reply that wraps across several lines of the card. ", count: 10), to: 42, sendNow: false)
        await window.settle(400)
        let after = screenY(of: watched)
        let grew = (pane.indexByID[.thread(42)].map { pane.heights[$0] } ?? 0) - heightBefore
        record("thread_grows_above_viewport", ["moved_pt": after - before, "thread_grew_pt": grew, "pass": abs(after - before) < 0.5 && grew > 20])
    }

    private func checkJumpFarDown() async {
        guard let target = pane.lineRowIndex(path: "Sources/API/Generated/Schema.swift", side: .head, line: 400) else {
            return record("jump_far_down", ["pass": false, "reason": "Schema.swift line 400 is not shown"])
        }
        pane.jump(toRow: target)
        await window.settle()
        let error = pane.jumpError(target)
        let header = pane.stickyHeaderHeight(above: target)
        record("jump_far_down", ["row": target, "rows": pane.rows.count, "error_pt": error, "sticky_header_pt": header,
                                 "pass": abs(error) < 0.5 && header > 0])
    }

    private func checkSelectionAcrossThreeRows() async {
        let rows = pane.rows
        let metrics = pane.metrics
        let columns = metrics.columns(forRowWidth: pane.rowWidth)
        guard let start = rows.indices.dropLast(3).first(where: { index in
            (index..<index + 3).allSatisfy { row in
                guard let code = rows[row].code else { return false }
                return code.isPlainASCII && code.displayText == code.line.text && code.displayText.count >= 12 && code.displayText.count < columns
            }
        }) else {
            return record("select_across_3_rows", ["pass": false, "reason": "no three plain code rows in a row"])
        }
        pane.jump(toRow: start, leavingAbove: 40)
        await window.settle()

        let from = NSPoint(x: metrics.codeX + 4 * metrics.characterWidth + 1, y: table.rect(ofRow: start).minY + 4)
        let to = NSPoint(x: metrics.codeX + 10 * metrics.characterWidth + 1, y: table.rect(ofRow: start + 2).minY + 4)
        table.mouseDown(with: mouseEvent(.leftMouseDown, at: from))
        table.mouseDragged(with: mouseEvent(.leftMouseDragged, at: to))
        table.mouseUp(with: mouseEvent(.leftMouseUp, at: to))

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("coops.eyeballs.selftest"))
        pane.copySelection(to: pasteboard)
        let texts = (start..<start + 3).map { Array(rows[$0].code!.line.text) }
        let expected = [String(texts[0].dropFirst(4)), String(texts[1]), String(texts[2].prefix(10))].joined(separator: "\n")
        let copied = pasteboard.string(forType: .string)
        pasteboard.releaseGlobally()
        record("select_across_3_rows", ["copied_characters": copied?.count ?? 0, "expected_characters": expected.count, "pass": copied == expected])
        pane.clearSelections()
    }

    private func checkReloadWithDifferentLayer() async {
        model.selectLayer(atPosition: 3)
        await window.settle(400)
        pane.jump(toRow: min(pane.rows.count - 1, 60))
        await window.settle()
        let mismatches = heightMismatches()
        record("reload_other_layer_heights", ["layer": model.selectedLayer?.branch ?? "?", "visible_rows": visibleRows().count,
                                              "mismatches": mismatches, "pass": mismatches == 0 && model.selectedLayer?.position == 3])
    }

    private func checkResizeRewraps() async {
        model.selectLayer(atPosition: 1)
        await window.settle(400)
        pane.jump(toRow: min(pane.rows.count - 1, 40))
        await window.settle()
        let anchorBefore = pane.topVisibleAnchor()
        let widthBefore = table.bounds.width
        var frame = window.frame
        frame.size.width -= 300
        window.setFrame(frame, display: true)
        await window.settle(400)
        let mismatches = heightMismatches(allRows: true)
        let anchorAfter = pane.topVisibleAnchor()
        record("resize_rewraps", [
            "rewrap_ms": pane.lastRewrapMilliseconds, "mismatches": mismatches, "rows": pane.rows.count,
            "table_width_before": widthBefore, "table_width_after": table.bounds.width,
            "top_row_kept": anchorBefore?.row == anchorAfter?.row,
            "pass": mismatches == 0 && anchorBefore?.row == anchorAfter?.row && pane.lastRewrapMilliseconds < 250
                && table.bounds.width < widthBefore - 100,
        ])
        frame.size.width += 300
        window.setFrame(frame, display: true)
        await window.settle()
    }

    /// A letter typed into a composer types; the same letter with the table focused acts.
    private func checkShortcutsNeedTableFocus() async {
        pane.shortcutsFired = []
        window.makeFirstResponder(table)
        let threadsBefore = pane.focusedThreadID
        type("n")
        await window.settle()
        let fired = pane.shortcutsFired.map(String.init)
        record("shortcuts_need_table_focus", ["fired": fired, "focused_thread": pane.focusedThreadID ?? -1,
                                              "pass": fired == ["n"] && pane.focusedThreadID != nil && pane.focusedThreadID != threadsBefore])
    }

    private func checkHeights(_ name: String) {
        let mismatches = heightMismatches()
        record(name, ["table_width": table.bounds.width, "visible_rows": visibleRows().count, "mismatches": mismatches, "pass": mismatches == 0])
    }

    // MARK: Helpers

    private func visibleRows() -> Range<Int> {
        let range = table.rows(in: pane.visibleRect)
        return range.location..<range.location + range.length
    }

    /// Rows whose table height differs from a height worked out afresh from the model.
    private func heightMismatches(allRows: Bool = false) -> Int {
        let rows = allRows ? 0..<pane.rows.count : visibleRows()
        return rows.filter { index in
            abs(pane.height(of: pane.rows[index]) - table.rect(ofRow: index).height) > 0.5
        }.count
    }

    private func screenY(of id: RowID) -> CGFloat {
        guard let index = pane.indexByID[id] else { return .nan }
        return table.rect(ofRow: index).minY - pane.visibleRect.minY
    }

    private func lineRange(path: String, containing snippet: String) -> LineRange? {
        guard let file = model.layer?.files.first(where: { $0.path == path }),
              let index = file.newLines.firstIndex(where: { $0.contains(snippet) }) else { return nil }
        return LineRange(path: path, side: .head, start: index + 1, end: index + 1)
    }

    private func type(_ text: String) {
        for character in text {
            let string = String(character)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: string,
                charactersIgnoringModifiers: string, isARepeat: false, keyCode: 0) else { continue }
            window.sendEvent(event)
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at tablePoint: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: table.convert(tablePoint, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func record(_ check: String, _ values: [String: Any]) {
        var entry = values
        entry["check"] = check
        results.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }
}
#endif
