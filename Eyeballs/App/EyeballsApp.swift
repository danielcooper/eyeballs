import EyeballsCore
import SwiftUI

@main
struct EyeballsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Eyeballs", id: "main") {
            MainView()
                .onOpenURL { open($0) }
        }
        .defaultSize(width: 1180, height: 760)
    }

    private func open(_ url: URL) {
        let scheme = Bundle.main.urlScheme
        guard let command = NavigationCommand(url: url, scheme: scheme) else {
            Log.app.error("Ignored a URL that is not \(scheme, privacy: .public)://, \(scheme, privacy: .public)://stack/<number> or \(scheme, privacy: .public)://thread/<number> (\(url.absoluteString.count, privacy: .public) characters)")
            return
        }
        Log.app.info("Asked to show \(String(describing: command), privacy: .public)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Agents reach the app while its window is closed, so it keeps running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension Bundle {
    /// `eyeballs`, or `eyeballs-debug` in a Debug build.
    var urlScheme: String {
        object(forInfoDictionaryKey: "EyeballsURLScheme") as? String ?? "eyeballs"
    }
}
