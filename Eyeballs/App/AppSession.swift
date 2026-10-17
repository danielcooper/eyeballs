import AppKit
import EyeballsCore

/// Everything one run of the app shares: the window's model, its view state and the backend.
@MainActor
final class AppSession {
    let model = ReviewWindowModel()
    let windowState = ReviewWindowState()
    let launch = LaunchOptions(arguments: CommandLine.arguments, defaults: .standard)
    private(set) var backend: (any ReviewBackend)?
    /// The store, socket and backend of a real run. Nil in demo and harness runs.
    var live: LiveServices?
    /// Opens the main window after you closed it. The window sets this when it first appears.
    var openMainWindow: (() -> Void)?

    /// True when this run uses the store and the socket, rather than the demo or a harness.
    var usesLiveServices: Bool { !launch.usesDemoBackend && !launch.isHarnessRun }

    init() {
        AppDefaults.register()
        if !launch.isHarnessRun { windowState.viewedMarksStore = UserDefaultsViewedMarks() }
        #if DEBUG
        if launch.usesDemoBackend { install(DemoReviewBackend(model: model)) }
        #endif
    }

    /// Connects the window to the backend that does its work. The model holds it weakly.
    func install(_ backend: any ReviewBackend) {
        self.backend = backend
        model.backend = backend
    }

    /// Brings the main window to the front, opening it if you closed it. Without `focus` it does
    /// not take keyboard focus, because an agent may run `eyeballs review` while you type.
    func showMainWindow(focus: Bool) {
        guard let window = mainWindow else {
            openMainWindow?()
            Task { @MainActor [weak self] in
                guard let self, let window = self.mainWindow else { return }
                self.raise(window, focus: focus)
            }
            return
        }
        raise(window, focus: focus)
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && ($0.isVisible || $0.isMiniaturized) }
    }

    private func raise(_ window: NSWindow, focus: Bool) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if focus {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    /// Follows an `eyeballs://` URL. URLs only ever navigate.
    func open(_ url: URL) {
        let scheme = Bundle.main.urlScheme
        guard let command = NavigationCommand(url: url, scheme: scheme) else {
            Log.app.error("Ignored a URL that is not \(scheme, privacy: .public)://, \(scheme, privacy: .public)://stack/<number> or \(scheme, privacy: .public)://thread/<number> (\(url.absoluteString.count, privacy: .public) characters)")
            return
        }
        Log.app.info("Asked to show \(String(describing: command), privacy: .public)")
        switch command {
        case .showMain:
            NSApp.activate()
        case .stack(let id):
            showStack(id)
        case .thread(let id):
            showThread(id)
        }
    }

    private func showStack(_ id: Int) {
        guard let stack = model.repositories.lazy.flatMap(\.stacks).first(where: { $0.id == id }) else {
            Log.app.info("No stack s\(id, privacy: .public) is open, so the URL changed nothing")
            return
        }
        guard model.selection?.stackID != id,
              let layer = stack.layers.first(where: { $0.position == 1 }) ?? stack.layers.first else { return }
        model.select(LayerSelection(stackID: id, layerID: layer.id))
    }

    private func showThread(_ id: Int) {
        guard model.layer?.threads.contains(where: { $0.id == id }) == true else {
            Log.app.info("Thread t\(id, privacy: .public) is not on the layer shown, so the URL changed nothing")
            return
        }
        windowState.revealThread(id)
    }
}

/// App-wide defaults that must be in place before any window opens.
enum AppDefaults {
    static func register() {
        // With estimation on, a row's position in the diff table can be thousands of points off.
        UserDefaults.standard.register(defaults: ["NSTableViewCanEstimateRowHeights": false])
    }
}

/// What the command line asked this run to do.
struct LaunchOptions {
    /// `-EyeballsDemo YES` fills the window from the in-memory demo backend. Debug builds only.
    var usesDemoBackend = false
    /// `--render-screenshots <folder>` draws the window in set states into PNGs, then quits.
    var screenshotFolder: URL?
    /// `--ui-selftest` runs the diff pane checks, prints JSON, then quits.
    var runsUISelfTest = false

    var isHarnessRun: Bool { screenshotFolder != nil || runsUISelfTest }

    init(arguments: [String], defaults: UserDefaults) {
        #if DEBUG
        if let index = arguments.firstIndex(of: "--render-screenshots"), arguments.indices.contains(index + 1) {
            screenshotFolder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        runsUISelfTest = arguments.contains("--ui-selftest")
        usesDemoBackend = defaults.bool(forKey: "EyeballsDemo") || isHarnessRun
        #endif
    }
}

extension Bundle {
    /// `eyeballs`, or `eyeballs-debug` in a Debug build.
    var urlScheme: String {
        object(forInfoDictionaryKey: "EyeballsURLScheme") as? String ?? "eyeballs"
    }
}
