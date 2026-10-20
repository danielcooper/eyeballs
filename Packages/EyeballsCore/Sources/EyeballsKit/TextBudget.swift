/// Token budgets for what the agent reads. Golden tests fail when a fixture's output grows past one.
public enum TextBudget {
    /// A monitor or `wait` line, in characters.
    public static let eventLine = 200
    /// A Stop hook's reason, in characters.
    public static let stopReason = 300
    /// SessionStart's `additionalContext`, in characters.
    public static let sessionStartContext = 600
    /// `eyeballs review` output, in lines.
    public static let reviewLines = 6
    /// `eyeballs reply` output, in lines.
    public static let replyLines = 3
    /// One `eyeballs inbox` page, in characters.
    public static let inboxPage = 20_000
    /// Covered code lines shown per thread in the inbox.
    public static let codeLinesPerThread = 12
    /// An older comment in a thread's history, in characters. The reviewer's newest comment is
    /// always shown in full.
    public static let historyComment = 300
}
