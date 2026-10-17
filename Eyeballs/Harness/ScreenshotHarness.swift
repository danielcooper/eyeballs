#if DEBUG
import AppKit
import SwiftUI

/// `--render-screenshots <folder>`: draws the main window, with the demo backend, in a set of
/// states and in light and dark appearance, writes PNGs into the folder, then quits.
@MainActor
final class ScreenshotHarness {
    private let session: AppSession
    private var model: ReviewWindowModel { session.model }
    private var windowState: ReviewWindowState { session.windowState }
    private var pane: DiffPaneController? { windowState.pane }
    private var written = 0
    private var folder = URL(fileURLWithPath: NSTemporaryDirectory())

    init(session: AppSession) {
        self.session = session
    }

    func run(writingTo folder: URL) {
        self.folder = folder
        Task {
            await capture()
            print("Wrote \(written) screenshots to \(folder.path)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private func capture() async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        HarnessWindow.lendKeyAppearanceToPopovers()
        let window = HarnessWindow.make(model: model, windowState: windowState)
        await window.settle(600)

        model.selectLayer(atPosition: 2)
        await window.settle(400)
        await shoot("01-layer-overview", window)

        windowState.revealThread(42)
        await window.settle()
        if let pane, let row = pane.lineRowIndex(path: "Sources/API/Client.swift", side: .head, line: 54) {
            pane.setHoveredRow(pane.rows[row].id)
        }
        await shoot("02-layer-threads", window)
        pane?.setHoveredRow(nil)
        pane?.clearSelections()

        if let range = lineRange(in: "Sources/API/Client.swift", from: "request.httpBody = body", to: "request.setValue(UUID().uuidString") {
            let key = DraftKey.newThread(.lines(range))
            model.saveDraft("Generate the idempotency key once per order, not per request. A retry that sends a new key could charge the card twice.", for: key)
            pane?.openComposer(.draft(key))
            await window.settle()
            await shoot("03-composer-on-range", window)
            model.saveDraft("Generate the idempotency key **once per order**, not per request:\n\n- a retry reuses it\n- a new order gets a new one", for: key)
            pane?.closeComposer(.draft(key))
            pane?.openComposer(.draft(key))
            pane?.setComposer(.draft(key), previewing: true)
            await window.settle()
            await shoot("31-composer-preview", window)
            pane?.closeComposer(.draft(key))
        }

        windowState.revealOverview()
        model.saveDraft("Yes, put it behind `checkoutV2`. Ship models and api-client first, then web-ui.", for: .reply(threadID: 38))
        pane?.openComposer(.draft(.reply(threadID: 38)))
        await window.settle()
        pane?.scroll(toY: 120)
        await shoot("04-reply-composer", window)
        pane?.closeComposer(.draft(.reply(threadID: 38)))

        pane?.expandGap(GapID(path: "Sources/API/Client.swift", index: 1))
        windowState.revealFile("Sources/API/Client.swift")
        await window.settle()
        if let pane, let row = pane.lineRowIndex(path: "Sources/API/Client.swift", side: .head, line: 22) {
            pane.jump(toRow: row, leavingAbove: 60)
        }
        await shoot("05-expanded-unchanged-lines", window)

        windowState.revealFile("Sources/API/Generated/Schema.swift")
        if let pane, let header = pane.indexByID[.fileHeader("Sources/API/Endpoints.swift")] {
            pane.jump(toRow: header + 3)
        }
        await shoot("06-collapsed-big-file", window)

        windowState.revealFile("Sources/API/Endpoints.swift")
        await shoot("07-outdated-thread", window)

        model.selectLayer(atPosition: 1)
        await window.settle(400)
        windowState.revealFile("Sources/Models/Money.swift")
        if let pane, let row = pane.indexByID[.thread(40)] {
            pane.jump(toRow: max(0, row - 8))
        }
        await shoot("08-resolved-thread", window)

        model.selectLayer(atPosition: 3)
        await window.settle(400)
        windowState.middleTab = .threads
        windowState.revealThread(44)
        await shoot("09-threads-list", window)

        windowState.threadScope = .wholeStack
        await shoot("17-threads-whole-stack", window)
        windowState.threadFilter = .outdated
        await shoot("18-threads-filter-outdated", window)
        windowState.threadFilter = .all
        windowState.threadScope = .thisLayer
        windowState.middleTab = .files

        windowState.revealFile("Web/assets/checkout-hero.png")
        await shoot("10-images-and-rename", window)

        await shootThreadNotes(window)
        await shootViewedAndFooter(window)

        if let webUI = model.selectedStack?.layers.first(where: { $0.position == 3 }) {
            windowState.askToRestack(webUI, in: model)
            await window.settle()
            await shoot("27-ask-to-restack", window)
            pane?.discardComposer(.draft(.newThread(.layer)))
        }

        model.selectLayer(atPosition: 2)
        await window.settle(400)
        windowState.revealThread(46)
        windowState.summaryText = "Close. One real bug in the retry path, and a question about the timeout.\n\nThe rest is ready to go."
        windowState.verdict = .requestChanges
        windowState.finishReview(model)
        await window.settle(500)
        await shoot("11-finish-review", window)
        windowState.submit(model)
        await window.settle(400)
        await shoot("12-submit-sent", window)
        try? await Task.sleep(for: .milliseconds(2_300))
        await shoot("13-submit-delivered", window)

        await shootEmptyStates(window)
        await shootLayerStates(window)
        await shootNarrowWindow(window)

        window.close()
        await shootKeyboardShortcuts()
        await shootNothingToReview()
    }

    // MARK: States the demo does not reach by itself

    /// Moved, whitespace, relocated and "isn't in this diff" notes, on threads added to the
    /// web-ui layer for the shot only.
    private func shootThreadNotes(_ window: HarnessWindow) async {
        guard var layer = model.layer, let checkout = layer.files.first(where: { $0.path == "Web/Checkout.tsx" }) else { return }
        func line(_ snippet: String) -> Int { (checkout.newLines.firstIndex { $0.contains(snippet) } ?? 0) + 1 }
        func anchor(_ snippet: String) -> ThreadAnchor {
            .lines(LineRange(path: checkout.path, side: .head, start: line(snippet), end: line(snippet)))
        }
        let hiddenLine = (1...max(1, checkout.newLines.count)).first { pane?.lineRowIndex(path: checkout.path, side: .head, line: $0) == nil } ?? 1
        let you = Author.you(name: DemoState.reviewer)
        let claude = Author.agent(name: "Claude")
        let now = Date()
        layer.threads += [
            ThreadItem(id: 90, anchor: anchor("const isSubmitting = state"), comments: [
                CommentItem(id: 900, author: you, body: "Derive this from `state` in one place, so the two can never disagree.",
                            date: now.addingTimeInterval(-7_200), isPending: false, isEdited: false),
            ], isResolved: false, state: .waitingOnAgent, anchorNote: "Whitespace changed since this comment", originalLines: []),
            ThreadItem(id: 91, anchor: anchor("setState(\"submitting\")"), comments: [
                CommentItem(id: 910, author: you, body: "Clear the old error before you start submitting again.",
                            date: now.addingTimeInterval(-9_000), isPending: false, isEdited: false),
                CommentItem(id: 911, author: claude, replyStatus: .addressed, body: "`setError(null)` now runs first.",
                            date: now.addingTimeInterval(-1_800), isPending: false, isEdited: false),
            ], isResolved: false, state: .checkTheFix, anchorNote: "Found by content search. It was on line 30 in revision 3.", originalLines: []),
            ThreadItem(id: 92, anchor: .lines(LineRange(path: checkout.path, side: .head, start: hiddenLine, end: hiddenLine)), comments: [
                CommentItem(id: 920, author: you, body: "This line moved out of the diff. The note above says so, and the thread stays at the top of its file.",
                            date: now.addingTimeInterval(-5_400), isPending: false, isEdited: false),
            ], isResolved: false, state: .waitingOnAgent, anchorNote: nil, originalLines: []),
        ]
        let shown = model.layer
        model.layer = layer
        await window.settle()
        windowState.revealThread(45)
        await window.settle()
        await shoot("22-thread-notes-moved-and-whitespace", window)
        windowState.revealThread(91)
        await window.settle()
        await shoot("23-thread-notes-relocated", window)
        windowState.revealThread(92)
        await window.settle()
        await shoot("24-thread-not-in-this-diff", window)
        model.layer = shown
        await window.settle()
    }

    private func shootViewedAndFooter(_ window: HarnessWindow) async {
        model.selectLayer(atPosition: 2)
        await window.settle(400)
        pane?.setViewed(true, path: "Sources/API/Retry.swift")
        pane?.setViewed(true, path: "Sources/API/Endpoints.swift")
        windowState.revealFile("Sources/API/Retry.swift")
        await window.settle()
        await shoot("25-viewed-files", window)
        pane?.setViewed(false, path: "Sources/API/Retry.swift")
        pane?.setViewed(false, path: "Sources/API/Endpoints.swift")

        pane?.scroll(toY: .greatestFiniteMagnitude)
        await window.settle()
        await shoot("26-end-of-layer", window)
        model.selectLayer(atPosition: 3)
        await window.settle(400)
        pane?.scroll(toY: .greatestFiniteMagnitude)
        await window.settle()
        await shoot("26-end-of-stack", window)
    }

    private func shootEmptyStates(_ window: HarnessWindow) async {
        let shownLayer = model.layer
        model.layer = LayerContent(layerID: -1, commits: [], files: [], threads: [])
        await shoot("14-layer-without-changes", window)
        windowState.middleTab = .threads
        await shoot("19-no-threads-yet", window)
        windowState.middleTab = .files
        model.layer = nil
        model.isLoadingLayer = true
        await shoot("15-loading", window)
        model.isLoadingLayer = false
        model.layer = shownLayer

        let selection = model.selection
        model.selection = nil
        model.layer = nil
        await shoot("20-pick-a-layer", window)
        if let selection { model.select(selection) }
        await window.settle(400)

        model.errorMessage = "Couldn't read the stack: git exited with status 128. Check that the repository still exists."
        await shoot("21-error-notice", window)
        model.errorMessage = nil
    }

    /// A merged layer, an empty layer, and a review with no agent listening.
    private func shootLayerStates(_ window: HarnessWindow) async {
        let repositories = model.repositories
        let agent = model.agent
        if var stack = model.repositories.first?.stacks.first {
            if let index = stack.layers.firstIndex(where: { $0.position == 1 }) { stack.layers[index].status = .merged }
            stack.layers.append(LayerItem(id: 14, position: 4, branch: "cleanup", prNumber: nil, fileCount: 0, additions: 0,
                                          deletions: 0, openThreadCount: 0, status: .empty))
            model.repositories[0].stacks[0] = stack
        }
        model.agent = .notListening
        await window.settle()
        await shoot("28-merged-empty-and-no-agent", window)
        model.repositories = repositories
        model.agent = agent
        await window.settle()
    }

    /// The window at its smallest, 1000 points wide.
    private func shootNarrowWindow(_ window: HarnessWindow) async {
        let frame = window.frame
        window.setFrame(NSRect(origin: frame.origin, size: NSSize(width: 1000, height: 700)), display: true)
        await window.settle(500)
        windowState.revealThread(42)
        model.errorMessage = "Couldn't read the stack: git exited with status 128. Check that the repository still exists."
        await window.settle()
        await shoot("29-narrow-window", window)
        model.errorMessage = nil
        window.setFrame(frame, display: true)
        await window.settle()
    }

    private func shootKeyboardShortcuts() async {
        let table = KeyboardShortcutsTable()
            .frame(width: 440, alignment: .top)
            .padding(.top, 28)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        let window = HarnessWindow.make(table, size: NSSize(width: 440, height: 660))
        await window.settle(400)
        await shoot("30-keyboard-shortcuts", window)
        window.close()
    }

    private func shootNothingToReview() async {
        let empty = ReviewWindowModel()
        let window = HarnessWindow.make(model: empty, windowState: ReviewWindowState())
        await window.settle(500)
        await shoot("16-nothing-to-review", window)
        window.close()
    }

    // MARK: Helpers

    private func shoot(_ name: String, _ window: HarnessWindow) async {
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for popover in NSApp.windows where String(describing: type(of: popover)).contains("Popover") {
                popover.appearance = window.appearance
            }
            await window.settle(350)
            guard let bitmap = window.snapshot(), let data = bitmap.representation(using: .png, properties: [:]) else { continue }
            do {
                try data.write(to: folder.appendingPathComponent("\(name)-\(suffix).png"))
                written += 1
            } catch {
                print("Could not write \(name)-\(suffix).png: \(error.localizedDescription)")
            }
        }
    }

    private func lineRange(in path: String, from first: String, to last: String) -> LineRange? {
        guard let file = model.layer?.files.first(where: { $0.path == path }),
              let start = file.newLines.firstIndex(where: { $0.contains(first) }),
              let end = file.newLines[start...].firstIndex(where: { $0.contains(last) }) else { return nil }
        return LineRange(path: path, side: .head, start: start + 1, end: end + 1)
    }
}
#endif
