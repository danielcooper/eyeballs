import ArgumentParser
import EyeballsKit

struct ReplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reply",
        abstract: "Reply to threads: many at once with --file, or one with a thread and a status.",
        discussion: """
            Batch form, read from a file or - for standard input:

              ## t41 addressed
              at: Sources/App.swift:40-58
              What you changed, in one or two sentences.

              ## t42 declined
              Why you kept it as it is.

            Statuses are addressed, declined and question. Indent a body line that starts with "## t". \
            If any block is wrong, nothing is sent.
            """)

    @Argument(help: "The thread, such as t41, when you reply to one thread.")
    var thread: String?

    @Argument(help: "addressed, declined or question, when you reply to one thread.")
    var status: String?

    @Option(help: "Read ## t41 addressed blocks from a file, or - for standard input.")
    var file: String?

    @Option(name: .customLong("json-file"), help: #"Read [{"thread":"t41","status":"addressed","body":"…"}] from a file, or -."#)
    var jsonFile: String?

    @Option(help: "The reply text, for one thread.")
    var body: String?

    @Option(name: .customLong("body-file"), help: "Read the reply text from a file, or - for standard input.")
    var bodyFile: String?

    @Option(name: .customLong("at"), help: "Where the fix is, as PATH:A-B. Repeat it for several places.")
    var at: [String] = []

    @OptionGroup var output: OutputOptions
    @OptionGroup var agent: AgentOptions

    func validate() throws {
        if file != nil, jsonFile != nil {
            throw ValidationError("Use --file or --json-file, not both.")
        }
        if file != nil || jsonFile != nil {
            guard thread == nil, status == nil, body == nil, bodyFile == nil, at.isEmpty else {
                throw ValidationError("With --file or --json-file, put every reply in the file.")
            }
            return
        }
        guard let thread, let status else {
            throw ValidationError(#"Reply with --file - for many threads, or name one, as in: eyeballs reply t41 addressed --body "…"."#)
        }
        guard ThreadID(parsing: thread) != nil else { throw ValidationError("A thread ID looks like t41 or 41.") }
        guard ReplyStatus(rawValue: status.lowercased()) != nil else {
            throw ValidationError("The status must be addressed, declined or question.")
        }
        guard (body == nil) != (bodyFile == nil) else {
            throw ValidationError("Give the reply text with --body or --body-file.")
        }
    }

    func run() throws {
        try reportingErrors(json: output.json) {
            let arguments = ReplyArguments(replies: try replies())
            try arguments.validate()
            let call = AppCall(operation: .reply, agent: agent, start: .inBackground, timeout: .seconds(60))
            try call.send(arguments).print(json: output.json)
        }
    }

    private func replies() throws -> [ReplyItem] {
        if let file {
            return try ReplyBatch.parse(TextInput.read(file, option: "--file", limit: WireLimits.maximumRequestBytes))
        }
        if let jsonFile {
            return try ReplyBatch.parseJSON(TextInput.readData(jsonFile, option: "--json-file", limit: WireLimits.maximumRequestBytes))
        }
        guard let thread = thread.flatMap(ThreadID.init(parsing:)),
              let status = status.flatMap({ ReplyStatus(rawValue: $0.lowercased()) }) else {
            throw ValidationError("Name a thread and a status, as in: eyeballs reply t41 addressed --body \"…\".")
        }
        let text = try body ?? TextInput.read(bodyFile ?? "-", option: "--body-file", limit: WireLimits.maximumBodyBytes)
        return [ReplyItem(thread: thread, status: status, body: text, at: try at.map(LineSpan.init(parsing:)))]
    }
}
