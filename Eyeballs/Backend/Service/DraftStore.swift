import Foundation

/// Composer text you have not added or sent yet, kept in `drafts.json` in the Eyeballs home so
/// it survives a relaunch.
///
/// Schema 1 has no table for unsent text, so it lives in this file instead. A draft is keyed by
/// stack, layer and composer. A reply draft and the review summary need no layer, because a
/// thread ID and a stack already say where they belong. Writes go to disk off the main thread,
/// in order, and `flush()` waits for them, as quitting does.
@MainActor
final class DraftStore {
    private let file: URL
    private var drafts: [StoredDraftKey: String]
    private let writer = DispatchQueue(label: "coops.eyeballs.drafts")

    init(file: URL) {
        self.file = file
        drafts = Self.read(file)
    }

    func text(for key: DraftKey, stack: Int, layer: Int?) -> String {
        drafts[StoredDraftKey(key, stack: stack, layer: layer)] ?? ""
    }

    /// Saves a draft. Empty text deletes it.
    func set(_ text: String, for key: DraftKey, stack: Int, layer: Int?) {
        let stored = StoredDraftKey(key, stack: stack, layer: layer)
        guard drafts[stored] != (text.isEmpty ? nil : text) else { return }
        drafts[stored] = text.isEmpty ? nil : text
        let snapshot = drafts
        let file = file
        writer.async { Self.write(snapshot, to: file) }
    }

    /// Waits until every draft saved so far is on disk.
    func flush() {
        writer.sync {}
    }

    private nonisolated static func read(_ file: URL) -> [StoredDraftKey: String] {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(DraftFile.self, from: data) else { return [:] }
        return Dictionary(saved.drafts.map { ($0.key, $0.text) }, uniquingKeysWith: { _, newer in newer })
    }

    private nonisolated static func write(_ drafts: [StoredDraftKey: String], to file: URL) {
        let saved = DraftFile(version: 1, drafts: drafts.map { DraftFile.Entry(key: $0.key, text: $0.value) }.sorted { $0.key < $1.key })
        do {
            let data = try JSONEncoder().encode(saved)
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.app.error("Could not save drafts: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private struct DraftFile: Codable {
    var version: Int
    var drafts: [Entry]

    struct Entry: Codable {
        var key: StoredDraftKey
        var text: String
    }
}

/// A `DraftKey` with the stack and layer it belongs to, in a shape JSON can hold.
struct StoredDraftKey: Codable, Hashable, Sendable, Comparable {
    var stack: Int
    var layer: Int?
    /// `new_thread`, `reply` or `summary`.
    var kind: String
    /// For a new thread: `layer`, `file` or `lines`.
    var anchor: String?
    var path: String?
    var side: String?
    var start: Int?
    var end: Int?
    var thread: Int?

    init(_ key: DraftKey, stack: Int, layer: Int?) {
        self.stack = stack
        switch key {
        case .reviewSummary:
            kind = "summary"
        case .reply(let threadID):
            kind = "reply"
            thread = threadID
        case .newThread(let anchor):
            kind = "new_thread"
            self.layer = layer
            switch anchor {
            case .layer:
                self.anchor = "layer"
            case .file(let path):
                self.anchor = "file"
                self.path = path
            case .lines(let range):
                self.anchor = "lines"
                path = range.path
                side = range.side == .base ? "base" : "head"
                start = range.start
                end = range.end
            }
        }
    }

    static func < (a: StoredDraftKey, b: StoredDraftKey) -> Bool {
        (a.stack, a.layer ?? 0, a.kind, a.path ?? "", a.start ?? 0, a.thread ?? 0)
            < (b.stack, b.layer ?? 0, b.kind, b.path ?? "", b.start ?? 0, b.thread ?? 0)
    }
}
