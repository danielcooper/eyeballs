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
        if ProcessInfo.processInfo.environment["EYEBALLS_DUMP_VIEWS"] != nil, let frame = window.contentView?.superview { probe(frame) }
        await shoot("01-layer-overview")

        windowState.revealThread(42)
        await window.settle()
        await shoot("02-layer-threads")

        if let range = lineRange(in: "Sources/API/Client.swift", from: "request.httpBody = body", to: "request.setValue(UUID().uuidString") {
            let key = DraftKey.newThread(.lines(range))
            model.saveDraft("Generate the idempotency key once per order, not per request. A retry that sends a new key could charge the card twice.", for: key)
            windowState.pane?.openComposer(.draft(key))
            await window.settle()
            await shoot("03-composer-on-range")
            windowState.pane?.closeComposer(.draft(key))
        }

        windowState.pane?.expandGap(GapID(path: "Sources/API/Client.swift", index: 1))
        windowState.revealFile("Sources/API/Client.swift")
        await window.settle()
        if let pane = windowState.pane, let row = pane.lineRowIndex(path: "Sources/API/Client.swift", side: .head, line: 22) {
            pane.jump(toRow: row, leavingAbove: 60)
        }
        await window.settle()
        await shoot("04-expanded-unchanged-lines")

        windowState.revealFile("Sources/API/Generated/Schema.swift")
        if let pane = windowState.pane, let header = pane.indexByID[.fileHeader("Sources/API/Endpoints.swift")] {
            pane.jump(toRow: header + 3)
        }
        await window.settle()
        await shoot("05-collapsed-big-file")

        model.selectLayer(atPosition: 3)
        await window.settle(400)
        windowState.middleTab = .threads
        windowState.revealThread(44)
        await window.settle()
        await shoot("06-threads-list")
        windowState.middleTab = .files

        model.selectLayer(atPosition: 2)
        await window.settle(400)
        windowState.revealThread(46)
        windowState.summaryText = "Close. One real bug in the retry path, and a question about the timeout."
        windowState.verdict = .requestChanges
        await window.settle()
        await shoot("07-before-submit")
        windowState.submit(model)
        await window.settle()
        await shoot("08-submit-sent")
        try? await Task.sleep(for: .milliseconds(2_300))
        await window.settle()
        await shoot("09-submit-delivered")

        window.close()
        let empty = ReviewWindowModel()
        let emptyWindow = HarnessWindow.make(model: empty, windowState: ReviewWindowState())
        await emptyWindow.settle(500)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            emptyWindow.appearance = NSAppearance(named: appearance)
            await emptyWindow.settle(300)
            if let data = emptyWindow.snapshot()?.representation(using: .png, properties: [:]),
               (try? data.write(to: folder.appendingPathComponent("10-nothing-to-review-\(suffix).png"))) != nil {
                written += 1
            }
        }
        emptyWindow.close()
        return written
    }

    private func probe(_ view: NSView) {
        if let table = view as? NSTableView {
            print("TABLE \(type(of: table)) rows=\(table.numberOfRows) frame=\(table.frame) visible=\(table.visibleRect) window=\(table.window != nil)")
        }
        for child in view.subviews { probe(child) }
    }

    private func lineRange(in path: String, from first: String, to last: String) -> LineRange? {
        guard let file = model.layer?.files.first(where: { $0.path == path }),
              let start = file.newLines.firstIndex(where: { $0.contains(first) }),
              let end = file.newLines[start...].firstIndex(where: { $0.contains(last) }) else { return nil }
        return LineRange(path: path, side: .head, start: start + 1, end: end + 1)
    }
}
#endif
