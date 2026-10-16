/// The version of the messages the `eyeballs` command and the app send each other.
///
/// Raise it whenever a change would stop an older command or an older app understanding a message.
public enum WireProtocol {
    public static let version = 1
}
