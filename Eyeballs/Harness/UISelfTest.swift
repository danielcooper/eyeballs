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
        checkTextLogic()
        await checkMenuShortcuts()
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
        await checkReviewLoop()
        await checkCancelCanBeUndone()
        await checkComposerButtonsMatchTheKeys()
        checkSmallGapsShowInline()
        await checkThreadJumpShowsItsCode()
        await checkDeletingPendingCanBeUndone()
        await checkArrowKeysMoveTheLineCursor()
        await checkViewedFoldsTheFile()
        await checkNeedsYouCrossesLayers()
        await checkFinishReviewNeverSendsByItself()
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
            for file in layer.files where !file.isBinary && (file.change == .modified || file.change == .renamed) {
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
            if table.numberOfRows != pane.rows.count { problems.append("layer \(position): the table has \(table.numberOfRows) rows, the pane \(pane.rows.count)") }
            let wrong = heightMismatches(allRows: true)
            if wrong > 0 { problems.append("layer \(position): \(wrong) rows have the wrong height after inserts") }
        }
        record("rows_match_the_model", ["problems": problems, "pass": problems.isEmpty])
    }

    /// The highlighter and the intraline pairing give the expected spans for known lines.
    private func checkTextLogic() {
        var problems: [String] = []
        func kinds(_ line: String, _ language: CodeLanguage) -> [String: TokenKind] {
            var result: [String: TokenKind] = [:]
            for token in SyntaxHighlighter.tokens(in: line, language: language) {
                result[(line as NSString).substring(with: token.range)] = token.kind
            }
            return result
        }
        let swift = kinds(#"    let name = "Alex" // greet 42"#, .swift)
        if swift["let"] != .keyword || swift[#""Alex""#] != .string || swift["// greet 42"] != .comment { problems.append("swift") }
        let json = kinds(#"  "amount": 9.35,"#, .json)
        if json[#""amount""#] != .key || json["9.35"] != .number { problems.append("json") }
        let yaml = kinds("    runs-on: macos-15 # pinned", .yaml)
        if yaml["runs-on"] != .key || yaml["# pinned"] != .comment { problems.append("yaml") }
        let shell = kinds(#"echo "Port $PORT" ${WEB_PORT:-3000}"#, .shell)
        if shell["echo"] != .keyword || shell["${WEB_PORT:-3000}"] != .variable { problems.append("shell") }
        let python = kinds("def make_order(customer_id: str) -> dict:", .python)
        if python["def"] != .keyword || python["make_order"] != .function { problems.append("python") }

        let pairs = IntralineDiff.changedRanges(in: [
            (.deleted, "        if attempt >= 3 { throw error }"),
            (.deleted, "        try await Task.sleep(for: .seconds(attempt))"),
            (.added, "        try await Task.sleep(for: retry.delay(after: attempt))"),
        ])
        if pairs[0] != nil || pairs[1] == nil || pairs[2] == nil { problems.append("intraline pairs the wrong lines") }
        if let added = pairs[2], ("        try await Task.sleep(for: retry.delay(after: attempt))" as NSString).substring(with: added) != "retry.delay(after: " {
            problems.append("intraline highlights the wrong span")
        }
        let wrapped = pane.metrics.layout(of: String(repeating: "word ", count: 60), isPlainASCII: true, rowWidth: 600)
        if wrapped.lines.count < 2 || wrapped.lines.dropLast().contains(where: { ($0.location + $0.length) % 5 != 0 }) {
            problems.append("long lines do not break after a space")
        }
        record("text_logic", ["problems": problems, "pass": problems.isEmpty])
    }

    /// The menus carry the window's shortcuts, and ⌘2 selects layer 2 from anywhere.
    private func checkMenuShortcuts() async {
        let items = NSApp.mainMenu.map(menuItems(in:)) ?? []
        func has(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            items.contains { $0.title.hasPrefix(title) && $0.keyEquivalent.lowercased() == key && $0.keyEquivalentModifierMask == modifiers }
        }
        var missing: [String] = []
        if !has("Open Repository", "o", .command) { missing.append("⌘O") }
        if !has("Layer 1", "1", .command) || !has("Layer 9", "9", .command) { missing.append("⌘1 to ⌘9") }
        if !has("Layer Above", "]", [.command, .shift]) && !has("Layer Above", "}", .command) { missing.append("⇧⌘]") }
        if !has("Layer Below", "[", [.command, .shift]) && !has("Layer Below", "{", .command) { missing.append("⇧⌘[") }
        if !has("Finish Review", "\r", [.command, .shift]) { missing.append("⇧⌘↩") }
        if !has("Next File", "]", .command) || !has("Previous File", "[", .command) { missing.append("⌘] and ⌘[") }
        if !has("Next Thread", "]", [.command, .option]) || !has("Previous Thread", "[", [.command, .option]) { missing.append("⌥⌘] and ⌥⌘[") }
        if !has("Next Thread That Needs You", "a", [.command, .shift]) { missing.append("⇧⌘A") }
        if !has("Keyboard Shortcuts", "/", .command) { missing.append("⌘/") }

        model.selectLayer(atPosition: 1)
        await window.settle()
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "2", charactersIgnoringModifiers: "2",
                                        isARepeat: false, keyCode: 19) {
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        }
        await window.settle(400)
        record("menu_shortcuts", ["missing": missing, "layer_after_command_2": model.selectedLayer?.position ?? 0,
                                  "pass": missing.isEmpty && model.selectedLayer?.position == 2])
    }

    private func menuItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(menuItems(in:)) ?? []) }
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

    /// The whole loop by keyboard: j picks a line, c opens a composer, ⌘↩ adds the comment,
    /// r and ⌥⌘↩ reply at once, the pretend agent answers, e resolves, and a submit is delivered.
    private func checkReviewLoop() async {
        (session.backend as? DemoReviewBackend)?.agentDelay = .milliseconds(300)
        model.selectLayer(atPosition: 1)
        await window.settle(400)
        let pendingBefore = model.review.pendingCommentCount
        window.makeFirstResponder(table)
        type("j")
        type("c")
        await window.settle()
        let composerOpened = window.firstResponder is ComposerTextView
        type("Please rename this.")
        press(keyCode: 36, characters: "\r", modifiers: .command)
        await window.settle()
        let created = model.layer?.threads.first { $0.comments.first?.body == "Please rename this." }
        let added = created?.state == .draft && model.review.pendingCommentCount == pendingBefore + 1
            && window.firstResponder === table && !pane.rows.contains { if case .composer = $0 { true } else { false } }

        var repliedNow = false
        var agentAnswered = false
        var resolved = false
        if let id = created?.id {
            pane.setFocusedThread(id)
            window.makeFirstResponder(table)
            type("r")
            await window.settle()
            type("Actually, send it now.")
            press(keyCode: 36, characters: "\r", modifiers: [.command, .option])
            await window.settle()
            let thread = model.layer?.threads.first { $0.id == id }
            repliedNow = thread?.comments.last?.body == "Actually, send it now." && thread?.comments.last?.isPending == false
            try? await Task.sleep(for: .milliseconds(500))
            agentAnswered = model.layer?.threads.first { $0.id == id }?.comments.last?.author.isAgent == true
            pane.setFocusedThread(id)
            window.makeFirstResponder(table)
            type("e")
            await window.settle()
            resolved = model.layer?.threads.first { $0.id == id }?.isResolved == true
        }

        session.windowState.summaryText = "Thanks, nearly there."
        session.windowState.submit(model)
        let submitted = model.review.lastSubmitted != nil && model.review.pendingCommentCount == 0
        try? await Task.sleep(for: .milliseconds(500))
        let delivered = model.review.lastSubmitted?.deliveredAt != nil
        record("review_loop_by_keyboard", [
            "composer_opened_by_c": composerOpened, "added_to_review": added, "replied_now": repliedNow,
            "agent_answered": agentAnswered, "resolved_by_e": resolved, "submitted": submitted, "delivered": delivered,
            "pass": composerOpened && added && repliedNow && agentAnswered && resolved && submitted && delivered,
        ])
    }

    /// Cancel throws a draft away, Edit > Undo brings it back, and Esc closes and keeps it.
    private func checkCancelCanBeUndone() async {
        guard let range = lineRange(path: "Sources/Models/Order.swift", containing: "var total: Money") else {
            return record("cancel_can_be_undone", ["pass": false, "reason": "no line to comment on"])
        }
        let key = ComposerKey.draft(.newThread(.lines(range)))
        pane.openComposer(key)
        await window.settle()
        type("Throw this away")
        pane.discardComposer(key)
        await window.settle()
        let discarded = model.draft(for: .newThread(.lines(range))).isEmpty && pane.indexByID[.composer(key)] == nil
        window.makeFirstResponder(table)
        // Ending the group by hand would leave the undo manager unable to open the next one.
        let canUndo = window.undoManager?.canUndo == true
        if canUndo { window.undoManager?.undo() }
        await window.settle()
        let restored = pane.indexByID[.composer(key)] != nil && pane.draftText(for: key) == "Throw this away"
        press(keyCode: 53, characters: "\u{1b}", modifiers: [])
        await window.settle(450)
        let keptAfterEscape = pane.indexByID[.composer(key)] == nil && model.draft(for: .newThread(.lines(range))) == "Throw this away"
        record("cancel_can_be_undone", ["discarded": discarded, "restored_by_undo": restored, "esc_keeps_draft": keptAfterEscape,
                                        "pass": discarded && restored && keptAfterEscape])
        model.saveDraft("", for: .newThread(.lines(range)))
    }

    /// Answering the agent's question, the buttons still run Cancel, Send now, Add to review, and
    /// the blue one is Add to review, as ⌘↩ is. ⇧⌘P shows the preview and goes back to the text.
    private func checkComposerButtonsMatchTheKeys() async {
        model.selectLayer(atPosition: 2)
        await window.settle(400)
        let key = ComposerKey.draft(.reply(threadID: 38))
        pane.openComposer(key)
        await window.settle()
        guard let index = pane.indexByID[.composer(key)],
              let row = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? ComposerRowView else {
            return record("composer_buttons_match_the_keys", ["pass": false, "reason": "the reply composer did not open"])
        }
        let order = row.buttonTitlesInOrder
        let primary = row.primaryButtonTitle
        let body = "**Yes**, put it behind the flag."
        type(body)
        press(keyCode: 35, characters: "P", modifiers: [.command, .shift])
        await window.settle()
        let previewed = row.content?.isPreviewing == true && row.textView.isHidden && window.firstResponder === row
        press(keyCode: 35, characters: "P", modifiers: [.command, .shift])
        await window.settle()
        let wroteAgain = row.content?.isPreviewing == false && window.firstResponder === row.textView
        press(keyCode: 36, characters: "\r", modifiers: .command)
        await window.settle()
        let reply = model.layer?.threads.first { $0.id == 38 }?.comments.last
        let addedToReview = reply?.body == body && reply?.isPending == true
        record("composer_buttons_match_the_keys", [
            "buttons": order, "blue_button": primary, "preview_by_shift_command_p": previewed, "back_to_writing": wroteAgain,
            "command_return_added_to_review": addedToReview,
            "pass": order == ["Cancel", ComposerRowView.sendNowTitle, "Add to review"] && primary == "Add to review"
                && previewed && wroteAgain && addedToReview,
        ])
        if let reply, reply.isPending { model.deleteComment(reply.id) }
        await window.settle()
    }

    // MARK: Checks from the design review

    /// Runs of three unchanged lines or fewer show in place, never behind a "Show" row.
    private func checkSmallGapsShowInline() {
        var problems: [String] = []
        for layer in (model.selectedStack?.layers ?? []).sorted(by: { $0.position < $1.position }) {
            model.selectLayer(atPosition: layer.position)
            guard let content = model.layer else { continue }
            let rows = DiffRowBuilder(prepared: PreparedLayer(files: content.files), layer: content, layerItem: layer,
                                      stack: model.selectedStack, state: LayerViewState(), codeColumnInset: 100).build()
            for row in rows {
                if case .gap(let gap) = row, gap.canExpand, gap.hiddenCount <= DiffRowBuilder.inlineGapLimit {
                    problems.append("\(gap.path) hides \(gap.hiddenCount) lines")
                }
            }
        }
        record("small_gaps_show_inline", ["problems": problems, "pass": problems.isEmpty])
    }

    /// Jumping to t42, whose range starts inside a folded gap, still shows its code above the
    /// card, and focusing it tints those lines.
    private func checkThreadJumpShowsItsCode() async {
        model.selectLayer(atPosition: 2)
        await window.settle(400)
        session.windowState.revealThread(42)
        await window.settle()
        guard let threadRow = pane.indexByID[.thread(42)],
              case .lines(let range) = model.layer?.threads.first(where: { $0.id == 42 })?.anchor,
              let codeRow = pane.firstCodeRow(of: range, above: threadRow) else {
            return record("thread_jump_shows_its_code", ["pass": false, "reason": "t42 or its code is not shown"])
        }
        let visible = pane.visibleRect
        let codeTop = table.rect(ofRow: codeRow).minY
        let codeIsVisible = codeTop >= visible.minY + pane.stickyHeaderHeight(above: codeRow) - 0.5 && codeTop < visible.maxY
        let tinted = pane.isLineSelected(pane.rows[codeRow].id)
        record("thread_jump_shows_its_code", ["code_row_visible": codeIsVisible, "lines_tinted": tinted,
                                              "pass": codeIsVisible && tinted && pane.focusedThreadID == 42])
        pane.clearSelections()
    }

    /// Deleting a pending comment needs no confirmation, and Edit > Undo brings it back.
    private func checkDeletingPendingCanBeUndone() async {
        model.selectLayer(atPosition: 2)
        await window.settle(400)
        guard let range = lineRange(path: "Sources/API/Client.swift", containing: "request.httpMethod = method") else {
            return record("delete_pending_can_be_undone", ["pass": false, "reason": "no line to comment on"])
        }
        let body = "Throwaway comment for the undo check."
        print("TRACE add"); fflush(stdout)
        model.addComment(body, at: .lines(range), sendNow: false)
        await window.settle()
        print("TRACE added"); fflush(stdout)
        guard let draft = model.layer?.threads.first(where: { $0.comments.first?.body == body }) else {
            return record("delete_pending_can_be_undone", ["pass": false, "reason": "the draft was not added"])
        }
        let pendingBefore = model.review.pendingCommentCount
        print("TRACE before delete"); fflush(stdout)
        pane.deleteThread(draft.id)
        await window.settle()
        let deleted = model.layer?.threads.contains { $0.id == draft.id } == false && model.review.pendingCommentCount == pendingBefore - 1
        window.makeFirstResponder(table)
        let actionName = window.undoManager?.undoActionName ?? ""
        print("TRACE before undo"); fflush(stdout)
        window.undoManager?.undo()
        print("TRACE after undo"); fflush(stdout)
        await window.settle()
        print("TRACE settled"); fflush(stdout)
        let restored = model.layer?.threads.first { $0.comments.first?.body == body && $0.anchor == draft.anchor }
        let draftCannotResolve: Bool
        if let restored {
            pane.setFocusedThread(restored.id)
            window.makeFirstResponder(table)
            type("e")
            await window.settle()
            draftCannotResolve = model.layer?.threads.first { $0.id == restored.id }?.isResolved == false
        } else {
            draftCannotResolve = false
        }
        record("delete_pending_can_be_undone", [
            "deleted_at_once": deleted, "undo_action": actionName, "restored_by_undo": restored?.state == .draft,
            "pending_count_restored": model.review.pendingCommentCount == pendingBefore, "e_leaves_a_draft_open": draftCannotResolve,
            "pass": deleted && actionName == "Delete Comment" && restored?.state == .draft
                && model.review.pendingCommentCount == pendingBefore && draftCannotResolve,
        ])
        pane.clearSelections()
    }

    /// ↓ and ↑ move the line cursor, as j and k do.
    private func checkArrowKeysMoveTheLineCursor() async {
        pane.clearSelections()
        window.makeFirstResponder(table)
        press(keyCode: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.numericPad, .function])
        let first = pane.lineSelection?.headLine
        press(keyCode: 125, characters: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: [.numericPad, .function])
        let second = pane.lineSelection
        press(keyCode: 126, characters: String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.numericPad, .function])
        let back = pane.lineSelection?.headLine
        await window.settle()
        let moved = first != nil && second != nil && (second?.headLine != first || second?.path != pane.lineSelection?.path)
        record("arrow_keys_move_the_line_cursor", ["first": first ?? -1, "second": second?.headLine ?? -1, "back": back ?? -1,
                                                   "pass": moved && back == first])
        pane.clearSelections()
    }

    /// Ticking Viewed folds the file and counts it; clearing it unfolds the file again.
    private func checkViewedFoldsTheFile() async {
        guard let layer = model.layer, let file = layer.files.first(where: { !$0.isBinary }) else {
            return record("viewed_folds_the_file", ["pass": false, "reason": "no file to view"])
        }
        pane.setViewed(true, path: file.path)
        await window.settle()
        let header = pane.indexByID[.fileHeader(file.path)].flatMap { index -> FileHeaderContent? in
            if case .fileHeader(let content) = pane.rows[index] { content } else { nil }
        }
        let folded = header?.isViewed == true && header?.isCollapsed == true && session.windowState.viewedCount(in: layer) == 1
        pane.setViewed(false, path: file.path)
        await window.settle()
        let unfolded = pane.rows.contains { $0.code?.path == file.path } && session.windowState.viewedCount(in: layer) == 0
        record("viewed_folds_the_file", ["folded_and_counted": folded, "unfolded_again": unfolded, "pass": folded && unfolded])
    }

    /// Past the last thread that needs you on a layer, `a` moves on to the next layer that has one.
    private func checkNeedsYouCrossesLayers() async {
        model.selectLayer(atPosition: 1)
        await window.settle(400)
        let lastNeedingYou = pane.rows.last { $0.thread?.state.needsYou == true }?.threadID
        guard let lastNeedingYou else {
            return record("needs_you_crosses_layers", ["pass": false, "reason": "layer 1 has no thread that needs you"])
        }
        pane.setFocusedThread(lastNeedingYou)
        window.makeFirstResponder(table)
        type("a")
        await window.settle(450)
        let position = model.selectedLayer?.position ?? 0
        let focused = pane.focusedThreadID.flatMap { id in model.layer?.threads.first { $0.id == id } }
        record("needs_you_crosses_layers", ["layer_after_a": position, "focused_thread": focused?.id ?? -1,
                                            "pass": position != 1 && focused?.state.needsYou == true])
    }

    /// ⇧⌘↩ opens Finish review and sends nothing; only Submit sends.
    private func checkFinishReviewNeverSendsByItself() async {
        let reviewBefore = model.review.lastSubmitted?.number
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                        isARepeat: false, keyCode: 36) {
            _ = NSApp.mainMenu?.performKeyEquivalent(with: event)
        }
        await window.settle(400)
        let opened = session.windowState.isFinishingReview
        let sent = model.review.lastSubmitted?.number != reviewBefore
        session.windowState.isFinishingReview = false
        await window.settle()
        record("finish_review_never_sends_by_itself", ["popover_opened": opened, "sent": sent, "pass": opened && !sent])
    }

    private func press(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        window.sendEvent(event)
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
