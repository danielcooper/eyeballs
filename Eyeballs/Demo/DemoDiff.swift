#if DEBUG
import AppKit

/// Builds a `FileItem` from a file's old and new text, with three lines of context per hunk,
/// so the demo's line numbers, hunks and full texts always agree.
enum DemoDiff {
    static func file(path: String, oldPath: String? = nil, old: String?, new: String?) -> FileItem {
        let oldLines = old.map(lines(of:)) ?? []
        let newLines = new.map(lines(of:)) ?? []
        let change: FileChange = if old == nil { .added } else if new == nil { .deleted } else if oldPath != nil { .renamed } else { .modified }
        let hunks = makeHunks(old: oldLines, new: newLines)
        let additions = hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count }
        let deletions = hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deleted }.count }
        return FileItem(path: path, oldPath: oldPath, change: change, additions: additions, deletions: deletions,
                        isBinary: false, hunks: hunks, newLines: newLines, oldLines: oldLines)
    }

    static func binary(path: String, change: FileChange, old: Data? = nil, new: Data? = nil) -> FileItem {
        FileItem(path: path, oldPath: nil, change: change, additions: 0, deletions: 0, isBinary: true, hunks: [], newLines: [], oldLines: [],
                 newImage: new, oldImage: old)
    }

    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The 1-based number of the first new-side line that contains `snippet`.
    static func line(containing snippet: String, in text: String, after earlier: String? = nil) -> Int {
        let lines = lines(of: text)
        var start = 0
        if let earlier, let index = lines.firstIndex(where: { $0.contains(earlier) }) { start = index }
        guard let index = lines[start...].firstIndex(where: { $0.contains(snippet) }) else {
            preconditionFailure("Demo content has no line containing the expected snippet")
        }
        return index + 1
    }

    /// A PNG drawn in code, so the demo can show image previews without shipping images.
    @MainActor
    static func png(width: Int, height: Int, draw: (NSRect) -> Void) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    @MainActor
    static func heroImage() -> Data? {
        png(width: 960, height: 400) { rect in
            NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.62, blue: 0.36, alpha: 1),
                       ending: NSColor(srgbRed: 0.84, green: 0.27, blue: 0.42, alpha: 1))?.draw(in: rect, angle: -20)
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: 80, y: 120, width: 420, height: 160), xRadius: 24, yRadius: 24).fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56, weight: .bold),
                                                        .foregroundColor: NSColor(srgbRed: 0.84, green: 0.27, blue: 0.42, alpha: 1)]
            ("Checkout" as NSString).draw(at: NSPoint(x: 120, y: 166), withAttributes: title)
        }
    }

    @MainActor
    static func logoImage(fill: NSColor) -> Data? {
        png(width: 128, height: 128) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 12, dy: 12)).fill()
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 40, height: 40), xRadius: 8, yRadius: 8).fill()
        }
    }

    private enum Step {
        case same(old: Int, new: Int)
        case deleted(old: Int)
        case added(new: Int)

        var isChange: Bool {
            if case .same = self { false } else { true }
        }
    }

    private static func makeHunks(old: [String], new: [String], context: Int = 3) -> [HunkItem] {
        let difference = new.difference(from: old)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var steps: [Step] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                steps.append(.deleted(old: oldIndex))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                steps.append(.added(new: newIndex))
                newIndex += 1
            } else {
                steps.append(.same(old: oldIndex, new: newIndex))
                oldIndex += 1
                newIndex += 1
            }
        }

        var ranges: [ClosedRange<Int>] = []
        for (index, step) in steps.enumerated() where step.isChange {
            let range = max(0, index - context)...min(steps.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }

        return ranges.map { range in
            var lines: [LineItem] = []
            var firstOld: Int?
            var firstNew: Int?
            for step in steps[range] {
                switch step {
                case .same(let o, let n):
                    firstOld = firstOld ?? o
                    firstNew = firstNew ?? n
                    lines.append(LineItem(kind: .context, oldNumber: o + 1, newNumber: n + 1, text: new[n]))
                case .deleted(let o):
                    firstOld = firstOld ?? o
                    lines.append(LineItem(kind: .deleted, oldNumber: o + 1, newNumber: nil, text: old[o]))
                case .added(let n):
                    firstNew = firstNew ?? n
                    lines.append(LineItem(kind: .added, oldNumber: nil, newNumber: n + 1, text: new[n]))
                }
            }
            let oldCount = lines.filter { $0.kind != .added }.count
            let newCount = lines.filter { $0.kind != .deleted }.count
            let oldStart = oldCount == 0 ? 0 : (firstOld ?? 0) + 1
            let newStart = newCount == 0 ? 0 : (firstNew ?? 0) + 1
            let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" + scopeName(before: oldStart - 1, in: old)
            return HunkItem(header: header, oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, lines: lines)
        }
    }

    /// The nearest declaration above a hunk, as git shows it after the `@@` marks.
    private static func scopeName(before index: Int, in lines: [String]) -> String {
        let starts = ["struct ", "final class ", "class ", "enum ", "extension ", "protocol ", "export function ",
                      "function ", "def ", "jobs:", "init("]
        var position = min(index, lines.count) - 1
        while position >= 0 {
            let trimmed = lines[position].trimmingCharacters(in: .whitespaces)
            let isFunction = trimmed.contains("func ") && trimmed.hasSuffix("{")
            if isFunction || starts.contains(where: { trimmed.hasPrefix($0) }) {
                return " " + String(trimmed.prefix(70))
            }
            position -= 1
        }
        return ""
    }
}
#endif
