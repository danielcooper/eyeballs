import AppKit
import EyeballsKit
import EyeballsStore

/// The real app's moving parts: the instance lock, the store, the socket and the backend.
///
/// `start` works in the order design A's security rules give: take the lock, open the store,
/// then listen. Demo and harness runs never start these.
@MainActor
final class LiveServices {
    let home: EyeballsHome
    let store: Store
    let service: ReviewService
    let backend: LiveReviewBackend
    private let lock: InstanceLock
    private let server: SocketServer
    private var backups: Task<Void, Never>?
    private var streams: Task<Void, Never>?

    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif

    /// Starts everything, or shows why it cannot and quits.
    static func start(in session: AppSession) {
        Task { @MainActor in
            do {
                session.live = try await LiveServices(session: session)
            } catch {
                Log.app.error("Eyeballs could not start: \(String(describing: error), privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Eyeballs can't start"
                alert.informativeText = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                alert.alertStyle = .critical
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    private init(session: AppSession) async throws {
        let home = EyeballsHome.current(debug: Self.isDebug)
        Log.app.info("Eyeballs home: \(home.root.path, privacy: .public)")
        let lock = try InstanceLock.acquire(in: home)

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let store = try await Task.detached { try Store.open(home: home, appVersion: version) }.value

        let facts = AppFacts(version: version, build: build, bundlePath: Bundle.main.bundlePath, home: home)
        let service = ReviewService(store: store, app: facts)
        let server = SocketServer(home: home, handler: AgentRequestHandler(service: service))
        try server.start(holdingInstanceLock: true)
        service.connect(server)

        let drafts = DraftStore(file: home.root.appendingPathComponent("drafts.json"))
        let backend = LiveReviewBackend(model: session.model, service: service, drafts: drafts)
        self.home = home
        self.lock = lock
        self.store = store
        self.service = service
        self.server = server
        self.backend = backend

        backend.presentWindow = { [weak session] focus in session?.showMainWindow(focus: focus) }
        service.setObserver(backend)
        session.install(backend)
        backend.start()

        let changes = server.liveStreamChanges
        streams = Task.detached { await service.followLiveStreams(changes) }
        backups = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                do {
                    try store.backUpIfDue()
                } catch {
                    Log.store.error("The daily backup failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        CommandLineTool.repairLink()
    }

    /// Saves drafts, closes the socket and the store. The lock goes when the process exits.
    func stop() {
        backend.flushDrafts()
        backups?.cancel()
        streams?.cancel()
        server.stop()
        try? store.close()
    }
}

/// Install Command Line Tool… and the link repair at launch (fix 8).
@MainActor
enum CommandLineTool {
    static var link: CommandLineToolLink { .standard(debug: LiveServices.isDebug) }

    static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/eyeballs")
    }

    /// Points `~/.local/bin/eyeballs` (Debug: `eyeballs-debug`) at this app's helper.
    static func install() {
        let alert = NSAlert()
        do {
            try link.install(pointingTo: helper)
            alert.messageText = "Installed \(link.name)"
            alert.informativeText = "~/.local/bin/\(link.name) now runs the command inside this copy of Eyeballs. "
                + "If your shell can't find it, add ~/.local/bin to your PATH. Run \(link.name) doctor to check the rest."
        } catch {
            alert.messageText = "Couldn't install \(link.name)"
            alert.informativeText = (error as? EyeballsError).map { [$0.message, $0.hint].compactMap { $0 }.joined(separator: " ") }
                ?? error.localizedDescription
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    /// Repoints a link that leads into a deleted app, or into another build of Eyeballs.
    static func repairLink() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        do {
            if try link.repairIfNeeded(helper: helper, expectedIdentifier: identifier) == .repaired {
                Log.app.info("Repaired ~/.local/bin/\(link.name, privacy: .public)")
            }
        } catch {
            Log.app.error("Could not repair ~/.local/bin/\(link.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
