#if DEBUG
import ArgumentParser
import EyeballsKit
import Foundation

/// Plays the reviewer for `Scripts/fake-agent.sh`. Debug builds only, and hidden from help.
struct DebugSubmitReviewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-submit-review",
        abstract: "Debug builds only: add a comment as the reviewer and submit it.",
        shouldDisplay: false)

    @Option(help: "The stack: its ID, such as s3, or the name of any branch in it.")
    var stack: String?

    @Option(help: "Reply to this thread instead of opening a new one.")
    var thread: String?

    @Option(help: "The file to comment on.")
    var path: String?

    @Option(help: "The first line of the comment's range.")
    var line: Int?

    @Option(name: .customLong("end-line"), help: "The last line of the range. Defaults to --line.")
    var endLine: Int?

    @Flag(help: "Comment on the base side of the diff instead of the head side.")
    var base = false

    @Option(help: "The comment's text.")
    var body: String

    @Option(help: "comment, changes_requested or approved.")
    var verdict = "changes_requested"

    @Option(help: "The review's summary.")
    var summary = ""

    @Flag(name: .customLong("send-now"), help: "Send the comment at once instead of submitting a review.")
    var sendNow = false

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        _ = try validatedStack(stack)
        if let thread, ThreadID(parsing: thread) == nil { throw ValidationError("A thread ID looks like t41 or 41.") }
        guard ["comment", "changes_requested", "approved"].contains(verdict) else {
            throw ValidationError("--verdict must be comment, changes_requested or approved.")
        }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let arguments = DebugSubmitReviewArguments(
                stack: try validatedStack(stack),
                thread: thread.flatMap(ThreadID.init(parsing:)),
                path: path,
                line: line,
                endLine: endLine,
                side: base ? .base : .head,
                body: body,
                verdict: Verdict(rawValue: verdict),
                summary: summary,
                sendNow: sendNow)
            try arguments.validate()
            let call = AppCall(operation: .debugSubmitReview, agent: agent, start: .never, timeout: .seconds(60))
            try call.send(arguments).print(json: output.json)
        }
    }
}

/// Draws the app's main window into a PNG. Debug builds only, and hidden from help.
struct DebugSnapshotWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug-snapshot-window",
        abstract: "Debug builds only: save a picture of the main window.",
        shouldDisplay: false)

    @Option(help: "Where to write the PNG.")
    var to: String

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func run() throws {
        try reportingErrors(json: output.json) {
            let path = URL(fileURLWithPath: to, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
            let arguments = DebugSnapshotWindowArguments(path: path)
            try arguments.validate()
            let call = AppCall(operation: .debugSnapshotWindow, agent: agent, start: .never, timeout: .seconds(30))
            try call.send(arguments).print(json: output.json)
        }
    }
}
#endif
