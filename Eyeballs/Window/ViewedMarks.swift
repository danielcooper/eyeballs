import CryptoKit
import Foundation

/// Where Viewed marks are kept between launches, one set per stack.
///
/// The window asks for a stack's marks the first time it shows that stack, and saves them each
/// time you tick or clear a box.
@MainActor
protocol ViewedMarksStore: AnyObject {
    func marks(forStack stackID: Int) -> ViewedMarks
    func save(_ marks: ViewedMarks, forStack stackID: Int)
}

/// The files you ticked Viewed, by layer ID and then path, each with its diff's fingerprint then.
typealias ViewedMarks = [Int: [String: FileFingerprint]]

/// Keeps Viewed marks in the app's user defaults, under one key per stack.
@MainActor
final class UserDefaultsViewedMarks: ViewedMarksStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func marks(forStack stackID: Int) -> ViewedMarks {
        defaults.data(forKey: Self.key(forStack: stackID)).flatMap(Self.decode) ?? [:]
    }

    func save(_ marks: ViewedMarks, forStack stackID: Int) {
        let key = Self.key(forStack: stackID)
        if marks.values.allSatisfy(\.isEmpty) {
            defaults.removeObject(forKey: key)
        } else if let data = Self.encode(marks) {
            defaults.set(data, forKey: key)
        }
    }

    static func key(forStack stackID: Int) -> String { "ViewedFiles.stack.\(stackID)" }

    nonisolated static func encode(_ marks: ViewedMarks) -> Data? {
        try? JSONEncoder().encode(marks)
    }

    /// Nil when the data is not marks this version wrote, so a damaged entry only forgets marks.
    nonisolated static func decode(_ data: Data) -> ViewedMarks? {
        try? JSONDecoder().decode(ViewedMarks.self, from: data)
    }
}

/// A SHA-256 digest of everything a file's diff shows: its change, every hunk's lines, and the
/// bytes of an image. Any change to the diff, even `30` to `20`, gives a new fingerprint, so a
/// Viewed mark lapses as it does on GitHub.
///
/// A binary file that is not an image brings no bytes in `FileItem`, so its fingerprint cannot
/// see a change to it.
struct FileFingerprint: Hashable, Codable, Sendable {
    let digest: String

    init(_ file: FileItem) {
        var hash = SHA256()
        func add(_ text: String) {
            hash.update(data: Data(text.utf8))
            hash.update(data: Data([0]))
        }
        add(file.oldPath ?? "")
        add("\(file.change)")
        for hunk in file.hunks {
            add(hunk.header)
            for line in hunk.lines {
                add(Self.marker(for: line.kind) + line.text)
            }
        }
        for image in [file.oldImage, file.newImage] {
            add(image.map { "\($0.count)" } ?? "none")
            if let image { hash.update(data: image) }
        }
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func marker(for kind: LineKind) -> String {
        switch kind {
        case .context: " "
        case .added: "+"
        case .deleted: "-"
        }
    }
}
