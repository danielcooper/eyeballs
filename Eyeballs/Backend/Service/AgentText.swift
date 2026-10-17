import EyeballsKit
import Foundation

/// The one-line events that `wait` prints and `watch` streams. Each is 200 characters or fewer.
enum AgentEvents {
    static func reviewSubmitted(review: Int, verdict: ReviewVerdictWords, stack: Int, name: String, revision: Int,
                                reviewer: ReviewerName, threads: Int) -> StreamEvent {
        let kind: WaitEventKind = verdict.isApproval ? .reviewApproved : .reviewSubmitted
        let text: String
        if verdict.isApproval, threads == 0 {
            text = "eyeballs: \(reviewer.startingSentence) approved \(name) (s\(stack), r\(revision)). Run: eyeballs inbox"
        } else {
            var counts = AgentText.count(threads, "thread")
            if verdict.words != "comments" { counts += ", \(verdict.words)" }
            text = "eyeballs: \(reviewer.startingSentence) submitted review \(review) on \(name) (s\(stack), r\(revision)): \(counts). Run: eyeballs inbox"
        }
        let event = WaitEvent(event: kind, stack: StackID(stack), review: review, threads: threads, verdict: verdict.wire, next: .runInbox)
        return make(event, text: text, stack: stack)
    }

    static func commentSent(thread: Int, stack: Int, name: String, revision: Int, reviewer: ReviewerName) -> StreamEvent {
        let text = "eyeballs: \(reviewer.startingSentence) sent a comment on t\(thread) in \(name) (s\(stack), r\(revision)). Run: eyeballs inbox"
        return make(WaitEvent(event: .commentSent, stack: StackID(stack), threads: 1, next: .runInbox), text: text, stack: stack)
    }

    static func rebound(stack: Int, label: String) -> StreamEvent {
        let text = "eyeballs: Another session now drives \(label). Stop, or run eyeballs attach."
        return make(WaitEvent(event: .rebound, stack: StackID(stack), next: .stop), text: text, stack: stack)
    }

    static func notDriver(stack: Int, label: String) -> StreamEvent {
        let text = "eyeballs: Another session drives \(label). Stop, or run eyeballs attach."
        return make(WaitEvent(event: .notDriver, stack: StackID(stack), next: .stop), text: text, stack: stack)
    }

    private static func make(_ event: WaitEvent, text: String, stack: Int) -> StreamEvent {
        let line = AgentText.oneLine(text, limit: TextBudget.eventLine)
        // Encoding cannot fail: WaitEvent holds only strings, integers and booleans.
        return (try? StreamEvent(event, text: line, stack: StackID(stack))) ?? StreamEvent(result: .null, text: line, stack: StackID(stack))
    }
}

/// A verdict as packets and events say it.
struct ReviewVerdictWords: Sendable, Hashable {
    var wire: WireVerdict

    var isApproval: Bool { wire == .approved }

    /// "changes requested", "approved" or "comments".
    var words: String {
        switch wire {
        case .changesRequested: "changes requested"
        case .approved: "approved"
        case .comment: "comments"
        default: wire.rawValue.replacingOccurrences(of: "_", with: " ")
        }
    }
}

/// Small helpers for the text every command prints.
enum AgentText {
    /// "1 thread" or "5 threads".
    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }

    /// The text on one line, cut to `limit` characters.
    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = String(text.map { $0.isNewline ? " " : $0 })
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    /// "t44", "t44 and t45", or "t44, t45 and t46". Long lists end with "and 3 more".
    static func list(_ items: [String], limit: Int = 6) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        if items.count > limit {
            return items.prefix(limit - 1).joined(separator: ", ") + " and \(items.count - limit + 1) more"
        }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    /// A line range as packets write it: `12-14`, or `12` for one line.
    static func range(_ start: Int, _ end: Int) -> String {
        start == end ? "\(start)" : "\(start)-\(end)"
    }

    /// A code line with its number: `   12 | text`.
    static func codeLine(_ number: Int, _ text: String) -> String {
        String(format: "%5d", number) + " | " + text
    }

    /// The first `limit` characters of a comment, marking a cut with "…".
    static func cut(_ body: String, to limit: Int) -> (text: String, truncated: Bool) {
        guard body.count > limit else { return (body, false) }
        return (String(body.prefix(limit - 1)) + "…", true)
    }
}

/// What `eyeballs review` prints: at most 6 lines, the last one saying what to do next.
enum ReviewText {
    static func render(_ result: ReviewResult, reviewer: ReviewerName) -> String {
        let label = "\(result.stack.name) (\(result.stack.id))"
        var head: [String] = []
        if result.created {
            let files = result.layers.reduce(0) { $0 + $1.files }
            let additions = result.layers.reduce(0) { $0 + $1.additions }
            let deletions = result.layers.reduce(0) { $0 + $1.deletions }
            head.append("Opened \(label) r\(result.revision) in Eyeballs: \(AgentText.count(result.layers.count, "layer")), "
                        + "\(AgentText.count(files, "file")), +\(additions) -\(deletions).")
        } else {
            head.append("Nothing changed since r\(result.revision) of \(label), so Eyeballs made no new revision.")
        }
        let carried = portedWords(result.ported)
        if !carried.isEmpty { head.append("Threads carried over: \(carried).") }

        var tail = ["Waiting on \(reviewer.inSentence): \(AgentText.count(result.waitingOnReviewer, "thread")). Waiting on you: \(result.waitingOnYou.count)."]
        tail.append(nextLine(result.next))

        let room = TextBudget.reviewLines - head.count - tail.count
        var warnings = result.warnings.map { "Warning: \($0.message)" }
        if warnings.count > room {
            let shown = max(0, room - 1)
            let hidden = warnings.count - shown
            warnings = Array(warnings.prefix(shown)) + ["Warning: \(AgentText.count(hidden, "more warning")). Run eyeballs review --json to see them."]
        }
        return (head + warnings + tail).joined(separator: "\n")
    }

    static func nextLine(_ next: NextStep) -> String {
        switch next {
        case .runInbox: "Next: run `eyeballs inbox`. Threads already wait on you."
        case .endTurn: "Next: end your turn. An \"eyeballs:\" line will wake you."
        default: "Next: run `eyeballs wait` with run_in_background: true, then end your turn."
        }
    }

    /// "3 current, 1 moved, 1 outdated", leaving out states with no threads.
    static func portedWords(_ counts: PortCounts) -> String {
        let parts: [(Int, String)] = [
            (counts.current, "current"), (counts.moved, "moved"), (counts.whitespace, "whitespace"), (counts.changed, "changed"),
            (counts.relocated, "relocated"), (counts.outdated, "outdated"), (counts.gone, "gone"),
        ]
        return parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }
}

/// One thread of an inbox packet, with the facts its header needs that the JSON leaves out.
struct PacketThread: Sendable, Hashable {
    var wire: InboxThread
    /// For a moved anchor: where it was, such as `98-99 since r3`.
    var movedFrom: String?
    /// Covered lines left out after the first 12.
    var hiddenCodeLines: Int
    /// The line number of `wire.original`'s first line.
    var originalStart: Int?
}

/// The inbox packet, split into pages of at most 20,000 characters.
struct InboxPacket: Sendable {
    var reviewer: ReviewerName
    var stackLabel: String
    var revision: Int
    /// The reviews the threads belong to, oldest first.
    var reviews: [InboxReview]
    var threads: [PacketThread]

    struct Page: Sendable {
        var text: String
        var threads: [PacketThread]
        var more: Bool
        var nextPage: Int?
    }

    /// Page `number`, counting from 1. A page past the end holds no threads.
    func page(_ number: Int) -> Page {
        let pages = splitIntoPages()
        let index = number - 1
        guard pages.indices.contains(index) else {
            return Page(text: "\(headerLine) · page \(number)\nThere is no page \(number). The inbox has \(AgentText.count(pages.count, "page")).",
                        threads: [], more: false, nextPage: nil)
        }
        let shown = pages[index]
        var parts: [String] = [index == 0 ? openingText : "\(headerLine) · page \(number)"]
        var layersNamed = Set<Int>()
        for thread in shown {
            parts.append(Self.block(thread, reviewer: reviewer, namesPR: layersNamed.insert(thread.wire.layer.position).inserted))
        }
        let remaining = pages[(index + 1)...].reduce(0) { $0 + $1.count }
        parts.append(remaining > 0 ? "\(AgentText.count(remaining, "more thread")): run eyeballs inbox --page \(number + 1)." : nextText)
        return Page(text: parts.joined(separator: "\n\n"), threads: shown, more: remaining > 0, nextPage: remaining > 0 ? number + 1 : nil)
    }

    var headerLine: String {
        var parts: [String] = []
        switch reviews.count {
        case 0: parts.append("Eyeballs")
        case 1: parts.append("Eyeballs review \(reviews[0].id)")
        default: parts.append("Eyeballs reviews \(AgentText.list(reviews.map { "\($0.id)" }))")
        }
        parts.append(stackLabel)
        parts.append("r\(revision)")
        if let newest = reviews.last { parts.append(ReviewVerdictWords(wire: newest.verdict).words) }
        return parts.joined(separator: " · ")
    }

    var openingText: String {
        var lines = [headerLine]
        let shownBefore = threads.filter(\.wire.shownBefore).count
        var summary: String
        switch threads.count {
        case 0: summary = "No threads, only a summary. Act on it, then run `eyeballs review --note \"…\"`."
        case 1: summary = "1 thread for you."
        default: summary = "\(threads.count) threads for you, bottom layer first."
        }
        if shownBefore > 0 { summary += " \(shownBefore) \(shownBefore == 1 ? "was" : "were") shown before." }
        if threads.count == 1 { summary += " Reply to it with `eyeballs reply --file -`." }
        if threads.count > 1 { summary += " Reply to all of them in one `eyeballs reply --file -`." }
        lines.append(summary)
        var text = lines.joined(separator: "\n")
        for review in reviews where !review.body.isEmpty {
            text += "\n\n\(reviewer.startingSentence): \(review.body)"
        }
        return text
    }

    var nextText: String {
        threads.isEmpty
            ? "Next: make the changes, then run `eyeballs review --note \"…\"`."
            : "Next: fix the code bottom layer first, reply with `eyeballs reply --file -`, then run `eyeballs review --note \"…\"`."
    }

    /// Threads per page. A thread too big for a page of its own still gets one.
    private func splitIntoPages() -> [[PacketThread]] {
        let budget = TextBudget.inboxPage - 200
        var pages: [[PacketThread]] = []
        var current: [PacketThread] = []
        var size = openingText.count
        for thread in threads {
            let blockSize = Self.block(thread, reviewer: reviewer, namesPR: true).count + 2
            if !current.isEmpty, size + blockSize > budget {
                pages.append(current)
                current = []
                size = headerLine.count + 10
            }
            current.append(thread)
            size += blockSize
        }
        if !current.isEmpty || pages.isEmpty { pages.append(current) }
        return pages
    }

    /// One thread's text. `namesPR` is true for the first thread of its layer on the page.
    static func block(_ thread: PacketThread, reviewer: ReviewerName, namesPR: Bool) -> String {
        let wire = thread.wire
        var header = ["## \(wire.id)", wire.kind.rawValue]
        if wire.shownBefore { header.append("shown before") }
        var layer = "layer \(wire.layer.position) \(wire.layer.branch)"
        if namesPR, let pr = wire.layer.pr { layer += " (PR #\(pr))" }
        header.append(layer)
        header.append(location(of: wire))
        if let note = anchorNote(thread) { header.append(note) }

        var lines = [header.joined(separator: " · ")]
        if let checkout = wire.layer.checkout { lines.append("checkout: \(checkout)") }
        if let start = wire.start {
            for (offset, text) in wire.code.enumerated() { lines.append(AgentText.codeLine(start + offset, text)) }
        }
        if thread.hiddenCodeLines > 0 {
            lines.append("(… \(AgentText.count(thread.hiddenCodeLines, "more line")); run eyeballs show \(wire.id))")
        }
        if let original = wire.original, !original.isEmpty {
            lines.append("Originally:")
            let start = thread.originalStart ?? 1
            for (offset, text) in original.enumerated() { lines.append(AgentText.codeLine(start + offset, text)) }
        }
        for comment in wire.history {
            lines.append("\(historyAuthor(comment, reviewer: reviewer)): \(comment.body)")
        }
        lines.append("\(reviewer.startingSentence): \(wire.comment.body)")
        return lines.joined(separator: "\n")
    }

    /// `path:12-14`, `path (file)`, or `whole layer`.
    static func location(of thread: InboxThread) -> String {
        guard let path = thread.path else { return "whole layer" }
        if thread.subject == .file { return "\(path) (file)" }
        guard let start = thread.start, let end = thread.end else { return "\(path) (lines gone)" }
        return "\(path):\(AgentText.range(start, end))"
    }

    static func anchorNote(_ thread: PacketThread) -> String? {
        switch thread.wire.anchor {
        case .current, .original: nil
        case .moved: thread.movedFrom.map { "moved from \($0)" } ?? "moved"
        case .whitespace: "whitespace changed"
        case .changed: "lines changed"
        case .relocated: "found by content search"
        case .outdated: "outdated"
        case .gone: "gone"
        default: thread.wire.anchor.rawValue
        }
    }

    /// "Alex (r3)" for your older comments, "You (r3, declined)" for the agent's own replies.
    static func historyAuthor(_ comment: HistoryComment, reviewer: ReviewerName) -> String {
        if comment.author == .agent {
            return comment.replyStatus.map { "You (r\(comment.revision), \($0.rawValue))" } ?? "You (r\(comment.revision))"
        }
        return "\(reviewer.startingSentence) (r\(comment.revision))"
    }
}

/// The other answers `eyeballs inbox` gives.
enum InboxText {
    static func approved(reviewer: ReviewerName, name: String, revision: Int) -> String {
        "\(reviewer.startingSentence) approved \(name) r\(revision). No changes needed. Tell \(reviewer.inSentence). "
            + "Push or merge only if \(reviewer.inSentence) asks you in the terminal."
    }

    static func closed(reviewer: ReviewerName, label: String) -> String {
        "\(reviewer.startingSentence) closed \(label). Stop."
    }

    static func notDriver(label: String) -> String {
        "Another session now drives \(label). Stop, or run eyeballs attach."
    }

    static let nothing = "Nothing waiting on you. Next: run eyeballs wait with run_in_background: true, then end your turn."
}

/// What `eyeballs reply` prints: at most 3 lines.
enum ReplyText {
    static func render(_ result: ReplyResult, reviews: [Int], waitingKinds: [ThreadID: ThreadKind], stackLabels: [String]) -> String {
        let statuses: [(WireReplyStatus, String)] = [(.addressed, "addressed"), (.declined, "declined"), (.question, "question")]
        let counts = statuses.compactMap { status, word -> String? in
            let number = result.replied.filter { $0.status == status }.count
            return number > 0 ? "\(number) \(word)" : nil
        }
        var first = "Sent \(AgentText.count(result.replied.count, "reply", "replies"))"
        switch reviews.count {
        case 0: break
        case 1: first += " on review \(reviews[0])"
        default: first += " on reviews \(AgentText.list(reviews.map(String.init)))"
        }
        first += ": \(counts.joined(separator: ", "))."
        var lines = [first]

        let notes = result.warnings.compactMap { warning -> String? in
            switch warning.code {
            case .notDriver: "another session drives \(AgentText.list(stackLabels)), so these replies are saved but its agent gets the wake-ups"
            case .threadResolved: warning.thread.map { "\($0) is resolved" }
            default: warning.message
            }
        }
        if !notes.isEmpty { lines.append("Warning: \(AgentText.list(notes)).") }

        if result.waitingOnYou.isEmpty {
            lines.append("Next: run `eyeballs review --note \"…\"` so the reviewer sees your fixes.")
        } else {
            let waiting = result.waitingOnYou.map { id in waitingKinds[id].map { "\(id) (\($0.rawValue))" } ?? id.description }
            let ids = AgentText.list(result.waitingOnYou.map(\.description))
            lines.append("Still waiting on you: \(AgentText.list(waiting)). Next: fix \(ids), reply, then run `eyeballs review --note \"…\"`.")
        }
        return lines.joined(separator: "\n")
    }
}

/// What `eyeballs threads` prints: one line per thread.
enum ThreadsText {
    static func line(_ thread: ThreadLine, reviewer: ReviewerName) -> String {
        var location = "whole layer"
        if let path = thread.path {
            location = path
            if let start = thread.start, let end = thread.end { location += ":\(AgentText.range(start, end))" }
        }
        let who: String
        switch thread.waitingOn {
        case .agent: who = "waiting on you"
        case .reviewer: who = "waiting on \(reviewer.inSentence)" + (thread.lastReply.map { " (you: \($0.rawValue))" } ?? "")
        default: who = thread.status == .resolved ? "resolved" : thread.state.lowercased()
        }
        return "\(thread.id)  \(thread.layer.branch)  \(location)  \(who)"
    }

    static func render(_ lines: [ThreadLine], reviewer: (ThreadLine) -> ReviewerName) -> String {
        guard !lines.isEmpty else { return "No threads." }
        return lines.map { line($0, reviewer: reviewer($0)) }.joined(separator: "\n")
    }
}

/// What `eyeballs show` prints: the whole thread.
enum ShowText {
    static func render(_ shown: ShownThread, label: String) -> String {
        var header = ["\(shown.id)", shown.state]
        var layer = "layer \(shown.layer.position) \(shown.layer.branch)"
        if let pr = shown.layer.pr { layer += " (PR #\(pr))" }
        header.append(layer)
        if let path = shown.path {
            if let start = shown.start, let end = shown.end {
                header.append("\(path):\(AgentText.range(start, end))")
            } else {
                header.append(shown.subject == .file ? "\(path) (file)" : "\(path) (lines gone)")
            }
        } else {
            header.append("whole layer")
        }
        header.append("r\(shown.revision) \(shown.anchor.rawValue)")
        var lines = [header.joined(separator: " · "), "Stack: \(label)"]
        if let checkout = shown.layer.checkout { lines.append("checkout: \(checkout)") }
        for code in shown.code {
            lines.append((code.covered ? ">" : " ") + AgentText.codeLine(code.line, code.text))
        }
        if let original = shown.original, !original.isEmpty {
            lines.append("Originally:")
            lines += original.map { "       | \($0)" }
        }
        if !shown.anchors.isEmpty {
            let steps = shown.anchors.map { step -> String in
                let lines = step.start.flatMap { start in step.end.map { AgentText.range(start, $0) } }
                return ["r\(step.revision)", lines, step.state.rawValue].compactMap { $0 }.joined(separator: " ")
            }
            lines.append("Anchors: " + steps.joined(separator: " → "))
        }
        for comment in shown.comments {
            lines.append("")
            let who = comment.author == .agent
                ? "\(comment.name) (r\(comment.revision)\(comment.replyStatus.map { ", \($0.rawValue)" } ?? ""))"
                : "\(comment.name) (r\(comment.revision))"
            lines.append("\(who): \(comment.body)")
            for span in comment.at { lines.append("  at: \(span)") }
        }
        return lines.joined(separator: "\n")
    }
}
