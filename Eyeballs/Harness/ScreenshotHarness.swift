#if DEBUG
import AppKit

/// `--render-screenshots <folder>`: draws the main window, with the demo backend, in a set of
/// states and in light and dark appearance, writes PNGs into the folder, then quits.
@MainActor
final class ScreenshotHarness {
    private let session: AppSession
    private var model: ReviewWindowModel { session.model }
    private var windowState: ReviewWindowState { session.windowState }

    init(session: AppSession) {
        self.session = session
    }

    func run(writingTo folder: URL) {
        Task {
            let written = await capture(into: folder)
            print("Wrote \(written) screenshots to \(folder.path)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private func capture(into folder: URL) async -> Int {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written = 0
        let window = HarnessWindow.make(model: model, windowState: windowState)
        await window.settle(600)

        func shoot(_ name: String) async {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
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

        model.selectLayer(atPosition: 2)
        await window.settle(400)
        await shoot("01-layer-overview")

        windowState.revealThread(42)
        await window.settle()
        if let pane = windowState.pane, let row = pane.lineRowIndex(path: "Sources/API/Client.swift", side: .head, line: 54) {
            pane.setHoveredRow(pane.rows[row].id)
        }
        await shoot("02-layer-threads")
        windowState.pane?.setHoveredRow(nil)

        if let range = lineRange(in: "Sources/API/Client.swift", from: "request.httpBody = body", to: "request.setValue(UUID().uuidString") {
            let key = DraftKey.newThread(.lines(range))
            model.saveDraft("Generate the idempotency key once per order, not per request. A retry that sends a new key could charge the card twice.", for: key)
            windowState.pane?.openComposer(.draft(key))
            await window.settle()
            await shoot("03-composer-on-range")
            windowState.pane?.closeComposer(.draft(key))
        }

        windowState.revealOverview()
        model.saveDraft("Yes, put it behind `checkoutV2`. Ship models and api-client first, then web-ui.", for: .reply(threadID: 38))
        windowState.pane?.openComposer(.draft(.reply(threadID: 38)))
        await window.settle()
        windowState.pane?.scroll(toY: 120)
        await shoot("04-reply-composer")
        windowState.pane?.closeComposer(.draft(.reply(threadID: 38)))

        windowState.pane?.expandGap(GapID(path: "Sources/API/Client.swift", index: 1))
        windowState.revealFile("Sources/API/Client.swift")
        await window.settle()
        if let pane = windowState.pane, let row = pane.lineRowIndex(path: "Sources/API/Client.swift", side: .head, line: 22) {
            pane.jump(toRow: row, leavingAbove: 60)
        }
        await shoot("05-expanded-unchanged-lines")

        windowState.revealFile("Sources/API/Generated/Schema.swift")
        if let pane = windowState.pane, let header = pane.indexByID[.fileHeader("Sources/API/Endpoints.swift")] {
            pane.jump(toRow: header + 3)
        }
        await shoot("06-collapsed-big-file")

        windowState.revealFile("Sources/API/Endpoints.swift")
        await shoot("07-outdated-thread")

        model.selectLayer(atPosition: 1)
        await window.settle(400)
        windowState.revealFile("Sources/Models/Money.swift")
        if let pane = windowState.pane, let row = pane.indexByID[.thread(40)] {
            pane.jump(toRow: max(0, row - 8))
        }
        await shoot("08-resolved-thread")

        model.selectLayer(atPosition: 3)
        await window.settle(400)
        windowState.middleTab = .threads
        windowState.revealThread(44)
        await shoot("09-threads-list")
        windowState.middleTab = .files

        windowState.revealFile("Web/assets/checkout-hero.png")
        await shoot("10-binary-and-rename")

        model.selectLayer(atPosition: 2)
        await window.settle(400)
        windowState.revealThread(46)
        windowState.summaryText = "Close. One real bug in the retry path, and a question about the timeout."
        windowState.verdict = .requestChanges
        await shoot("11-before-submit")
        windowState.submit(model)
        await shoot("12-submit-sent")
        try? await Task.sleep(for: .milliseconds(2_300))
        await shoot("13-submit-delivered")

        let shownLayer = model.layer
        model.layer = LayerContent(layerID: -1, commits: [], files: [], threads: [])
        await shoot("14-layer-without-changes")
        model.layer = nil
        model.isLoadingLayer = true
        await shoot("15-loading")
        model.isLoadingLayer = false
        model.layer = shownLayer

        window.close()
        let empty = ReviewWindowModel()
        let emptyWindow = HarnessWindow.make(model: empty, windowState: ReviewWindowState())
        await emptyWindow.settle(500)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            emptyWindow.appearance = NSAppearance(named: appearance)
            await emptyWindow.settle(300)
            if let data = emptyWindow.snapshot()?.representation(using: .png, properties: [:]),
               (try? data.write(to: folder.appendingPathComponent("16-nothing-to-review-\(suffix).png"))) != nil {
                written += 1
            }
        }
        emptyWindow.close()
        return written
    }

    private func lineRange(in path: String, from first: String, to last: String) -> LineRange? {
        guard let file = model.layer?.files.first(where: { $0.path == path }),
              let start = file.newLines.firstIndex(where: { $0.contains(first) }),
              let end = file.newLines[start...].firstIndex(where: { $0.contains(last) }) else { return nil }
        return LineRange(path: path, side: .head, start: start + 1, end: end + 1)
    }
}
#endif
