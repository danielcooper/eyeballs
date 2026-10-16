import Foundation

/// Where an `eyeballs://` URL asks the app to go.
///
/// URLs only ever navigate. They never carry paths or change anything, because any web page can
/// open one.
public enum NavigationCommand: Equatable, Sendable {
    case showMain
    case stack(Int)
    case thread(Int)

    /// Parses URLs such as `eyeballs://`, `eyeballs://stack/3` or `eyeballs://thread/41`.
    ///
    /// Returns nil when the scheme is not `scheme`, or the URL is anything else.
    public init?(url: URL, scheme: String) {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.query == nil, url.fragment == nil else { return nil }
        let parts = ([url.host()] + url.pathComponents)
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty && $0 != "/" }

        switch parts.count {
        case 0:
            self = .showMain
        case 2:
            guard let id = Int(parts[1]), id > 0, String(id) == parts[1] else { return nil }
            switch parts[0] {
            case "stack": self = .stack(id)
            case "thread": self = .thread(id)
            default: return nil
            }
        default:
            return nil
        }
    }
}
